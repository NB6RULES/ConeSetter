"""Car data logs: read CAN frames from an MF4 file and decode them with a DBC file."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

import numpy as np


class CanLogError(Exception):
    pass


# ---------------------------------------------------------------- DBC

@dataclass
class DbcSignal:
    name: str
    start: int
    length: int
    little_endian: bool
    signed: bool
    factor: float
    offset: float
    unit: str = ""
    choices: dict[int, str] = field(default_factory=dict)
    comment: str = ""
    mux: str = ""            # "" = always present, "M" = the multiplexer, "m3" = present when multiplexer == 3
    scale_missing: bool = False


@dataclass
class DbcMessage:
    frame_id: int
    extended: bool
    name: str
    length: int
    signals: list[DbcSignal] = field(default_factory=list)
    comment: str = ""


@dataclass
class Dbc:
    name: str
    messages: dict[tuple[int, bool], DbcMessage] = field(default_factory=dict)

    def find(self, frame_id: int, extended: bool) -> DbcMessage | None:
        return self.messages.get((frame_id, extended))


_BO = re.compile(r"^BO_\s+(\d+)\s+(\w+)\s*:\s*(\d+)")
_SG = re.compile(r"^\s*SG_\s+(\w+)\s*(M|m\d+M?)?\s*:\s*(\d+)\|(\d+)@([01])([+-])\s*\(\s*([^,]+),\s*([^)]+)\)"
                 r"\s*\[[^\]]*\]\s*\"([^\"]*)\"")
_VAL = re.compile(r"^\s*VAL_\s+(\d+)\s+(\w+)\s+(.*);")
_VAL_PAIR = re.compile(r"(-?\d+)\s+\"([^\"]*)\"")
_CM_SG = re.compile(r"^CM_\s+SG_\s+(\d+)\s+(\w+)\s+\"(.*)\"\s*;", re.S)
_CM_BO = re.compile(r"^CM_\s+BO_\s+(\d+)\s+\"(.*)\"\s*;", re.S)


def _split_id(raw: int) -> tuple[int, bool]:
    ext = bool(raw & 0x8000_0000)
    return (raw & 0x1FFF_FFFF, True) if ext else (raw & 0x7FF, False)


def parse_dbc(text: str, name: str = "") -> Dbc:
    dbc = Dbc(name)
    by_raw: dict[int, DbcMessage] = {}
    current: DbcMessage | None = None
    for line in text.splitlines():
        m = _BO.match(line)
        if m:
            raw = int(m.group(1))
            fid, ext = _split_id(raw)
            current = DbcMessage(fid, ext, m.group(2), int(m.group(3)))
            if m.group(2) != "VECTOR__INDEPENDENT_SIG_MSG":
                dbc.messages[(fid, ext)] = current
                by_raw[raw] = current
            continue
        m = _SG.match(line)
        if m and current is not None:
            try:
                factor, offset = float(m.group(7)), float(m.group(8))
            except ValueError:
                continue
            sig = DbcSignal(name=m.group(1), mux=m.group(2) or "", start=int(m.group(3)), length=int(m.group(4)),
                            little_endian=m.group(5) == "1", signed=m.group(6) == "-", factor=factor, offset=offset,
                            unit=m.group(9))
            if sig.length == 1:
                # A signed single bit would read as -1 for "on"; flags are meant as 0 / 1.
                sig.signed = False
            if sig.factor == 0:
                # A scale of 0 would turn every value into 0. Show the raw number instead.
                sig.factor, sig.scale_missing = 1.0, True
            current.signals.append(sig)
            continue
    # Value tables and comments can span lines, so match them over the whole text.
    for m in re.finditer(r"^\s*VAL_\s+(\d+)\s+(\w+)\s+(.*?);", text, re.M | re.S):
        msg = by_raw.get(int(m.group(1)))
        if msg:
            for s in msg.signals:
                if s.name == m.group(2):
                    s.choices = {int(k): v for k, v in _VAL_PAIR.findall(m.group(3))}
    for m in re.finditer(r"^CM_\s+SG_\s+(\d+)\s+(\w+)\s+\"(.*?)\"\s*;", text, re.M | re.S):
        msg = by_raw.get(int(m.group(1)))
        if msg:
            for s in msg.signals:
                if s.name == m.group(2):
                    s.comment = m.group(3).replace('\\"', '"').strip()
    for m in re.finditer(r"^CM_\s+BO_\s+(\d+)\s+\"(.*?)\"\s*;", text, re.M | re.S):
        msg = by_raw.get(int(m.group(1)))
        if msg:
            msg.comment = m.group(2).strip()
    if not dbc.messages:
        raise CanLogError(f"{name or 'This file'} has no messages in it, so it isn't a usable DBC.")
    return dbc


def load_dbc(path: str) -> Dbc:
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return parse_dbc(raw.decode(enc), os.path.basename(path))
        except UnicodeDecodeError:
            continue
    raise CanLogError(f"{os.path.basename(path)}: can't read this file")


# ---------------------------------------------------------------- frames

@dataclass
class Frames:
    """Raw CAN frames, sorted by time."""
    t: np.ndarray         # seconds from the start of the log
    frame_id: np.ndarray  # uint32, without the extended flag
    extended: np.ndarray  # bool
    data: np.ndarray      # uint8, N x 8 (longer CAN FD payloads are cut to 8 bytes)
    length: np.ndarray    # payload bytes actually sent
    bus: np.ndarray       # bus channel number
    start: datetime | None = None

    def __len__(self) -> int:
        return len(self.t)


@dataclass
class Series:
    name: str
    group: str            # message name, or "0x123 (not in DBC)"
    t: np.ndarray
    values: np.ndarray
    unit: str = ""
    choices: dict[int, str] = field(default_factory=dict)
    comment: str = ""
    decoded: bool = True  # False for raw bytes of a message the DBC doesn't describe

    @property
    def key(self) -> str:
        return f"{self.group}.{self.name}"

    @property
    def is_state(self) -> bool:
        return bool(self.choices)

    def value_at(self, t: float) -> float:
        """Last value at or before t (signals hold their value between frames)."""
        if len(self.t) == 0:
            return float("nan")
        i = int(np.searchsorted(self.t, t, side="right")) - 1
        return float(self.values[max(i, 0)])

    def text_at(self, t: float) -> str:
        v = self.value_at(t)
        if not np.isfinite(v):
            return "–"
        if self.choices:
            label = self.choices.get(int(round(v)))
            return f"{label} ({int(round(v))})" if label else f"{int(round(v))}"
        if abs(v - round(v)) < 1e-9 and abs(v) < 1e12:
            return f"{int(round(v))} {self.unit}".strip()
        return f"{v:.3f}".rstrip("0").rstrip(".") + (f" {self.unit}" if self.unit else "")


@dataclass
class CarLog:
    name: str
    start: datetime | None
    duration: float
    series: list[Series]
    frame_count: int = 0
    dbc_name: str = ""
    notes: list[str] = field(default_factory=list)
    frames: Frames | None = field(default=None, repr=False)

    def find(self, key: str) -> Series | None:
        return next((s for s in self.series if s.key == key), None)


def _raw_field(sig, shift: int, mask: int, signed: bool, length: int, word: np.ndarray) -> np.ndarray:
    raw = (word >> np.uint64(shift)) & np.uint64(mask)
    if signed and length < 64:
        raw = raw.astype(np.int64)
        raw = np.where(raw >= (1 << (length - 1)), raw - (1 << length), raw)
        return raw.astype(np.float64)
    if signed:
        return raw.astype(np.int64).astype(np.float64)
    return raw.astype(np.float64)


def decode_signal(sig: DbcSignal, data: np.ndarray) -> np.ndarray | None:
    """Physical values of one signal for an N x 8 block of payloads. None if it doesn't fit in 8 bytes."""
    if sig.length < 1 or sig.length > 64:
        return None
    mask = (1 << sig.length) - 1
    if sig.little_endian:
        if sig.start + sig.length > 64:
            return None
        word = np.ascontiguousarray(data).view("<u8").reshape(-1)
        raw = _raw_field(sig, sig.start, mask, sig.signed, sig.length, word)
    else:
        # Motorola: the DBC start bit is the most significant bit, numbered 7..0 within each byte.
        msb = (sig.start // 8) * 8 + (7 - sig.start % 8)
        if msb + sig.length > 64:
            return None
        word = np.ascontiguousarray(data).view(">u8").reshape(-1)
        raw = _raw_field(sig, 64 - (msb + sig.length), mask, sig.signed, sig.length, word)
    return raw * sig.factor + sig.offset


def decode(frames: Frames, dbc: Dbc | None, name: str = "") -> CarLog:
    """Turns raw frames into named signals. Messages the DBC doesn't know are kept as raw bytes."""
    log = CarLog(name=name, start=frames.start, duration=float(frames.t[-1] - frames.t[0]) if len(frames) else 0.0,
                 series=[], frame_count=len(frames), dbc_name=dbc.name if dbc else "", frames=frames)
    if len(frames) == 0:
        log.notes.append("The log has no CAN frames in it.")
        return log
    key = frames.frame_id.astype(np.uint64) | (frames.extended.astype(np.uint64) << np.uint64(32))
    order = np.argsort(key, kind="stable")
    uniq, first = np.unique(key[order], return_index=True)
    bounds = list(first) + [len(order)]
    known, unknown = [], []
    raw_series: list[Series] = []      # undecoded messages go after the named signals
    for k, (u, a, b) in enumerate(zip(uniq, bounds[:-1], bounds[1:])):
        rows = np.sort(order[a:b])
        fid, ext = int(u & np.uint64(0xFFFF_FFFF)), bool(int(u) >> 32)
        t = frames.t[rows]
        data = frames.data[rows]
        msg = dbc.find(fid, ext) if dbc else None
        label = f"0x{fid:X}" + ("x" if ext else "")
        rate = (len(rows) - 1) / (t[-1] - t[0]) if len(rows) > 1 and t[-1] > t[0] else 0.0
        if msg is None:
            unknown.append((label, len(rows), rate))
            width = int(min(8, max(int(frames.length[rows].max()), 1)))
            group = f"{label} (not in DBC)"
            for byte in range(width):
                raw_series.append(Series(f"byte {byte}", group, t, data[:, byte].astype(np.float64), decoded=False,
                                         comment=f"Raw byte {byte} of message {label}"))
            continue
        known.append(msg.name)
        mux_sig = next((s for s in msg.signals if s.mux.startswith("M") or s.mux.endswith("M")), None)
        mux_vals = decode_signal(mux_sig, data) if mux_sig else None
        group = f"{msg.name} ({label})"
        for sig in msg.signals:
            vals = decode_signal(sig, data)
            if vals is None:
                log.notes.append(f"{msg.name}.{sig.name} sits beyond the first 8 bytes and was skipped.")
                continue
            ts = t
            if sig.mux.startswith("m") and mux_vals is not None:
                try:
                    want = int(sig.mux[1:].rstrip("M"))
                except ValueError:
                    want = None
                if want is not None:
                    keep = mux_vals == want
                    ts, vals = t[keep], vals[keep]
            comment = sig.comment
            if sig.scale_missing:
                comment = (comment + " " if comment else "") + "The DBC gives this signal a scale of 0, so the raw value is shown."
            log.series.append(Series(sig.name, group, ts, vals, sig.unit, sig.choices, comment))
    log.series += raw_series
    if dbc is None:
        log.notes.append("No DBC loaded: showing raw bytes. Open the DBC to see named signals.")
    else:
        if unknown:
            listed = ", ".join(f"{l} ({n} frames, {r:.0f} Hz)" for l, n, r in unknown)
            log.notes.append(f"Not described by {dbc.name}, shown as raw bytes: {listed}.")
        if not known:
            log.notes.append(f"None of the messages in this log are in {dbc.name}. Is it the right DBC?")
    return log


# ---------------------------------------------------------------- MF4

def read_mf4(path: str) -> tuple[Frames | None, list[Series], datetime | None]:
    """Reads an MF4 file. Returns (CAN frames or None, already-decoded channels, start time).
    Bus-logging files (CANedge, Vector, PEAK…) give frames; measurement files give channels."""
    try:
        from asammdf import MDF
    except Exception as e:  # noqa: BLE001
        raise CanLogError(f"MF4 support isn't available in this copy ({e}).") from e
    import logging
    logging.getLogger("asammdf").setLevel(logging.CRITICAL)
    try:
        mdf = MDF(path)
    except Exception as e:  # noqa: BLE001
        raise CanLogError(f"{os.path.basename(path)}: not a readable MF4 file ({e})") from e
    try:
        start = mdf.header.start_time
        if start is not None and start.tzinfo is None:
            start = start.replace(tzinfo=timezone.utc)
        parts = []
        plain: list[Series] = []
        for gi, group in enumerate(mdf.groups):
            names = [c.name for c in group.channels]
            if "CAN_DataFrame.ID" in names and "CAN_DataFrame.DataBytes" in names:
                try:
                    ids = mdf.get("CAN_DataFrame.ID", group=gi)
                    if len(ids.timestamps) == 0:
                        continue
                    payload = mdf.get("CAN_DataFrame.DataBytes", group=gi, raw=True).samples
                except Exception:  # noqa: BLE001 - one unreadable group must not lose the rest
                    continue
                # Flag fields (IDE, bus channel) are stored as constants, so their physical values are read.
                n = len(ids.timestamps)
                raw_id = np.asarray(ids.samples).astype(np.uint32)
                ext = (raw_id & np.uint32(0x8000_0000)) != 0
                if "CAN_DataFrame.IDE" in names:
                    try:
                        ext = ext | (np.asarray(mdf.get("CAN_DataFrame.IDE", group=gi).samples) != 0)
                    except Exception:  # noqa: BLE001
                        pass
                payload = np.asarray(payload)
                if payload.ndim == 1:
                    payload = payload.reshape(n, -1) if payload.dtype == np.uint8 else np.zeros((n, 8), np.uint8)
                data = np.zeros((n, 8), np.uint8)
                w = min(8, payload.shape[1])
                data[:, :w] = payload[:, :w]
                length = np.full(n, w, np.uint8)
                for field_name in ("CAN_DataFrame.DataLength", "CAN_DataFrame.DLC"):
                    if field_name in names:
                        try:
                            length = np.minimum(np.asarray(mdf.get(field_name, group=gi).samples), 64).astype(np.uint8)
                            break
                        except Exception:  # noqa: BLE001
                            pass
                bus = np.zeros(n, np.uint8)
                if "CAN_DataFrame.BusChannel" in names:
                    try:
                        bus = np.asarray(mdf.get("CAN_DataFrame.BusChannel", group=gi).samples).astype(np.uint8)
                    except Exception:  # noqa: BLE001
                        pass
                parts.append((np.asarray(ids.timestamps, float), raw_id & np.uint32(0x1FFF_FFFF), ext, data, length, bus))
            elif not any(n.startswith(("CAN_", "LIN_", "FLX_", "ETH_")) for n in names):
                for ci, ch in enumerate(group.channels):
                    if ci == 0 and ch.channel_type in (2, 3):      # the group's time channel
                        continue
                    try:
                        s = mdf.get(ch.name, group=gi, index=ci)
                    except Exception:  # noqa: BLE001
                        continue
                    vals = np.asarray(s.samples)
                    if vals.ndim != 1 or len(vals) == 0 or vals.dtype.kind not in "iufb":
                        continue
                    plain.append(Series(ch.name, group.channel_group.acq_name or f"Group {gi + 1}",
                                        np.asarray(s.timestamps, float), vals.astype(np.float64), str(s.unit or ""),
                                        comment=str(s.comment or "")[:200]))
        frames = None
        if parts:
            t = np.concatenate([p[0] for p in parts])
            order = np.argsort(t, kind="stable")
            frames = Frames(t=t[order], frame_id=np.concatenate([p[1] for p in parts])[order],
                            extended=np.concatenate([p[2] for p in parts])[order],
                            data=np.concatenate([p[3] for p in parts])[order],
                            length=np.concatenate([p[4] for p in parts])[order],
                            bus=np.concatenate([p[5] for p in parts])[order], start=start)
        return frames, plain, start
    finally:
        try:
            mdf.close()
        except Exception:  # noqa: BLE001
            pass


def load_car_log(mf4_path: str, dbc: Dbc | None) -> CarLog:
    frames, plain, start = read_mf4(mf4_path)
    name = os.path.splitext(os.path.basename(mf4_path))[0]
    if frames is not None:
        log = decode(frames, dbc, name)
        log.series += plain
        return log
    if plain:
        t0 = min(float(s.t[0]) for s in plain)
        t1 = max(float(s.t[-1]) for s in plain)
        return CarLog(name=name, start=start, duration=t1 - t0, series=plain, frame_count=0,
                      notes=["This MF4 holds measured channels rather than CAN frames, so no DBC is needed."])
    raise CanLogError(f"{os.path.basename(mf4_path)}: no CAN frames or numeric channels found in this file")


# ---------------------------------------------------------------- time alignment

def clock_offset(log_start: datetime | None, run_start: datetime | None) -> float | None:
    """Seconds to add to log time to get run time, from the two recorders' clocks."""
    if log_start is None or run_start is None:
        return None
    a = log_start if log_start.tzinfo else log_start.replace(tzinfo=timezone.utc)
    b = run_start if run_start.tzinfo else run_start.replace(tzinfo=timezone.utc)
    return (a - b).total_seconds()


def overlap(log: CarLog, offset: float, run_t0: float, run_t1: float) -> float:
    """Seconds of the run covered by the log at this offset."""
    return max(0.0, min(run_t1, offset + log.duration) - max(run_t0, offset))


def align_by_signal(series: Series, run_t: np.ndarray, run_speed: np.ndarray, hz: float = 10.0) -> tuple[float, float] | None:
    """Finds the offset that best matches a speed-like car signal (vehicle or wheel speed) to GPS speed.
    Returns (offset seconds, correlation 0..1), or None if there is nothing to match."""
    if len(series.t) < 20 or len(run_t) < 20:
        return None
    dt = 1.0 / hz
    lt = np.arange(series.t[0], series.t[-1], dt)
    rt = np.arange(run_t[0], run_t[-1], dt)
    if len(lt) < 20 or len(rt) < 20:
        return None
    a = np.interp(lt, series.t, np.abs(series.values))
    b = np.interp(rt, run_t, run_speed)
    a = a - a.mean()
    b = b - b.mean()
    if not a.any() or not b.any():
        return None
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    corr = np.fft.irfft(np.fft.rfft(b, n) * np.conj(np.fft.rfft(a, n)), n)
    lag_index = np.arange(n)
    lag_index[lag_index > n // 2] -= n
    valid = (lag_index > -len(a)) & (lag_index < len(b))
    # Normalise by the energy of the overlapping parts so short overlaps can't win by accident.
    ca, cb = np.cumsum(a ** 2), np.cumsum(b ** 2)

    def energy(c, i0, i1):
        return c[i1 - 1] - (c[i0 - 1] if i0 > 0 else 0.0)

    best, best_score = None, 0.0
    min_overlap = max(20, int(0.25 * min(len(a), len(b))))
    for k in np.argsort(corr * valid)[::-1][:400]:
        lag = int(lag_index[k])
        if not valid[k]:
            continue
        a0, a1 = max(0, -lag), min(len(a), len(b) - lag)
        if a1 - a0 < min_overlap:
            continue
        ea, eb = energy(ca, a0, a1), energy(cb, a0 + lag, a1 + lag)
        if ea <= 0 or eb <= 0:
            continue
        score = float(corr[k] / np.sqrt(ea * eb))
        if score > best_score:
            best, best_score = lag, score
    if best is None:
        return None
    # log sample i sits at lt[0] + i*dt and matches run sample i + lag at rt[0] + (i + lag)*dt
    return float(rt[0] + best * dt - lt[0]), min(best_score, 1.0)
