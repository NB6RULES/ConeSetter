"""Run model and loaders for the files OBRA Essentials exports (.zip, .csv, .xlsx, .gpx)."""

from __future__ import annotations

import csv
import io
import math
import os
import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from xml.etree import ElementTree

import numpy as np

G = 9.80665
EARTH_RADIUS = 6_371_008.8


class LoadError(Exception):
    pass


@dataclass
class Run:
    name: str
    t: np.ndarray          # seconds since the start of the run
    lat: np.ndarray
    lon: np.ndarray
    alt: np.ndarray        # metres
    speed: np.ndarray      # m/s
    long_acc: np.ndarray   # m/s², + = speeding up
    lat_acc: np.ndarray    # m/s², + = to the left
    dist: np.ndarray       # metres from the start
    heading: np.ndarray    # degrees from true north
    start: datetime | None = None
    driver: str = ""
    run_type: str = ""
    notes: str = ""
    source: str = ""
    x: np.ndarray = field(default=None, repr=False)   # metres east of the first point
    y: np.ndarray = field(default=None, repr=False)   # metres north of the first point

    def __post_init__(self):
        if self.x is None:
            self.x, self.y = to_local(self.lat, self.lon, self.lat[0], self.lon[0])

    @property
    def duration(self) -> float:
        return float(self.t[-1] - self.t[0])

    @property
    def distance(self) -> float:
        return float(self.dist[-1] - self.dist[0])

    @property
    def top_speed(self) -> float:
        return float(np.max(self.speed))

    @property
    def sample_rate(self) -> float:
        return (len(self.t) - 1) / self.duration if self.duration > 0 else 0.0

    def index_at(self, t: float) -> int:
        i = int(np.searchsorted(self.t, t))
        if i <= 0:
            return 0
        if i >= len(self.t):
            return len(self.t) - 1
        return i if (self.t[i] - t) < (t - self.t[i - 1]) else i - 1

    def value_at(self, arr: np.ndarray, t: float) -> float:
        return float(np.interp(t, self.t, arr))


def to_local(lat, lon, lat0: float, lon0: float):
    """Equirectangular metres east / north of (lat0, lon0). Fine over a few km."""
    m_lat = EARTH_RADIUS * math.pi / 180.0
    m_lon = m_lat * math.cos(math.radians(lat0))
    return (np.asarray(lon) - lon0) * m_lon, (np.asarray(lat) - lat0) * m_lat


def to_geo(x, y, lat0: float, lon0: float):
    m_lat = EARTH_RADIUS * math.pi / 180.0
    m_lon = max(m_lat * math.cos(math.radians(lat0)), 1e-9)
    return lat0 + np.asarray(y) / m_lat, lon0 + np.asarray(x) / m_lon


# ---------------------------------------------------------------- helpers

def _parse_time(s: str) -> datetime | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _derive(t, lat, lon, speed=None):
    """Distance, heading, speed and accelerations from positions, for files that lack them."""
    x, y = to_local(lat, lon, lat[0], lon[0])
    step = np.hypot(np.diff(x), np.diff(y))
    dist = np.concatenate([[0.0], np.cumsum(step)])
    dt = np.maximum(np.diff(t), 1e-3)
    if speed is None or not np.any(speed > 0):
        v = step / dt
        speed = np.concatenate([[v[0] if len(v) else 0.0], v])
        if len(speed) >= 5:
            speed = np.convolve(np.pad(speed, 2, mode="edge"), np.ones(5) / 5, mode="valid")
    head = np.degrees(np.arctan2(np.gradient(x), np.gradient(y))) % 360.0
    if len(t) >= 3:
        long_acc = np.gradient(speed, t)
        yaw = np.gradient(np.unwrap(np.radians(head)), t)      # rad/s, clockwise positive
        lat_acc = -speed * yaw                                   # + = to the left
        lat_acc[speed < 1.0] = 0.0
    else:
        long_acc = np.zeros_like(t)
        lat_acc = np.zeros_like(t)
    return dist, head, speed, long_acc, lat_acc


def _clean(run: Run) -> Run:
    """Drops rows with bad numbers and makes time strictly increasing."""
    cols = [run.t, run.lat, run.lon, run.alt, run.speed, run.long_acc, run.lat_acc, run.dist, run.heading]
    ok = np.all(np.isfinite(np.vstack(cols)), axis=0)
    ok &= np.concatenate([[True], np.diff(run.t) > 0]) if len(run.t) > 1 else True
    if ok.sum() < 2:
        raise LoadError(f"{run.name}: fewer than two usable samples")
    if not ok.all():
        run.t, run.lat, run.lon, run.alt, run.speed, run.long_acc, run.lat_acc, run.dist, run.heading = (c[ok] for c in cols)
        run.x, run.y = to_local(run.lat, run.lon, run.lat[0], run.lon[0])
    return run


def _floats(values) -> np.ndarray:
    out = np.empty(len(values))
    for i, v in enumerate(values):
        try:
            out[i] = float(v)
        except (TypeError, ValueError):
            out[i] = np.nan
    return out


# ---------------------------------------------------------------- CSV

def load_csv_text(text: str, name: str) -> Run:
    text = text.lstrip("﻿")
    rows = list(csv.reader(io.StringIO(text, newline="")))
    if len(rows) < 3:
        raise LoadError(f"{name}: no samples")
    head = [h.strip().lower() for h in rows[0]]
    body = [r for r in rows[1:] if len(r) >= len(head) - 1 and any(c.strip() for c in r)]

    def col(*names):
        for n in names:
            if n in head:
                i = head.index(n)
                return _floats([r[i] if i < len(r) else "" for r in body])
        return None

    t, lat, lon = col("elapsed_s"), col("lat", "latitude"), col("lon", "longitude", "lng")
    if t is None or lat is None or lon is None:
        raise LoadError(f"{name}: this isn't an OBRA Essentials run CSV (needs elapsed_s, lat and lon columns)")
    speed = col("speed_ms")
    if speed is None:
        for unit, f in (("speed_kmh", 3.6), ("speed_mph", 2.2369362921)):
            c = col(unit)
            if c is not None:
                speed = c / f
    alt = col("alt_m")
    dist, head_deg, long_acc, lat_acc = col("distance_m"), col("heading_deg"), col("long_accel_ms2"), col("lat_accel_ms2")
    if dist is None or head_deg is None or speed is None or long_acc is None or lat_acc is None:
        d2, h2, s2, la2, lt2 = _derive(t, lat, lon, speed)
        dist = d2 if dist is None else dist
        head_deg = h2 if head_deg is None else head_deg
        speed = s2 if speed is None else speed
        long_acc = la2 if long_acc is None else long_acc
        lat_acc = lt2 if lat_acc is None else lat_acc
    start = None
    if "time_utc" in head and body:
        first = _parse_time(body[0][head.index("time_utc")])
        if first is not None:
            start = first
    src = ""
    if "source" in head and body:
        i = head.index("source")
        fused = sum(1 for r in body if i < len(r) and r[i].strip() == "fused")
        src = "GPS + IMU fusion" if fused > len(body) / 2 else "GPS only"
    return _clean(Run(name=name, t=t, lat=lat, lon=lon, alt=alt if alt is not None else np.zeros_like(t),
                      speed=speed, long_acc=long_acc, lat_acc=lat_acc, dist=dist, heading=head_deg,
                      start=start, source=src))


# ---------------------------------------------------------------- XLSX

def load_xlsx_bytes(data: bytes, name: str) -> Run:
    import openpyxl

    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as e:  # noqa: BLE001
        raise LoadError(f"{name}: can't read this workbook ({e})") from e
    if "Data" not in wb.sheetnames:
        raise LoadError(f"{name}: no Data sheet, so this isn't an OBRA Essentials export")
    rows = list(wb["Data"].iter_rows(values_only=True))
    if len(rows) < 3:
        raise LoadError(f"{name}: no samples")
    head = [str(h or "").strip().lower() for h in rows[0]]
    body = [r for r in rows[1:] if r and r[0] is not None]

    def col(prefix):
        for i, h in enumerate(head):
            if h.startswith(prefix):
                return _floats([r[i] if i < len(r) else None for r in body])
        return None

    t, lat, lon = col("elapsed"), col("latitude"), col("longitude")
    speed, dist = col("speed (m/s)"), col("distance")
    if any(c is None for c in (t, lat, lon, speed, dist)):
        raise LoadError(f"{name}: the Data sheet is missing columns")
    alt, head_deg = col("altitude"), col("heading")
    long_acc, lat_acc = col("long accel (m/s"), col("lat accel (m/s")
    run = Run(name=name, t=t, lat=lat, lon=lon, alt=alt if alt is not None else np.zeros_like(t), speed=speed,
              long_acc=long_acc if long_acc is not None else np.zeros_like(t),
              lat_acc=lat_acc if lat_acc is not None else np.zeros_like(t),
              dist=dist, heading=head_deg if head_deg is not None else np.zeros_like(t))
    if isinstance(body[0][0], datetime):
        run.start = body[0][0]
    if "Summary" in wb.sheetnames:
        for r in wb["Summary"].iter_rows(min_row=1, max_row=12, max_col=2, values_only=True):
            key, val = (str(r[0] or "").strip().lower(), r[1]) if r else ("", None)
            if val is None:
                continue
            if key == "driver":
                run.driver = str(val)
            elif key == "run type":
                run.run_type = str(val)
            elif key == "notes":
                run.notes = str(val)
            elif key == "data source":
                run.source = str(val)
    return _clean(run)


# ---------------------------------------------------------------- GPX

def load_gpx_text(text: str, name: str) -> Run:
    try:
        root = ElementTree.fromstring(text.lstrip("﻿"))
    except ElementTree.ParseError as e:
        raise LoadError(f"{name}: not a valid GPX file ({e})") from e

    def local(tag):
        return tag.rsplit("}", 1)[-1]

    lat, lon, alt, times, speed = [], [], [], [], []
    desc = ""
    trk_name = ""
    for el in root.iter():
        tag = local(el.tag)
        if tag == "desc" and not desc:
            desc = (el.text or "").strip()
        elif tag == "name" and not trk_name:
            trk_name = (el.text or "").strip()
        elif tag == "trkpt":
            try:
                la, lo = float(el.get("lat")), float(el.get("lon"))
            except (TypeError, ValueError):
                continue
            e = tm = sp = None
            for child in el.iter():
                ct = local(child.tag)
                if ct == "ele":
                    e = child.text
                elif ct == "time":
                    tm = _parse_time(child.text or "")
                elif ct == "speed":
                    sp = child.text
            lat.append(la); lon.append(lo); alt.append(e); times.append(tm); speed.append(sp)
    if len(lat) < 2:
        raise LoadError(f"{name}: no track points")
    if any(tm is None for tm in times):
        raise LoadError(f"{name}: the track has no timestamps, so there is nothing to play back")
    t = np.array([(tm - times[0]).total_seconds() for tm in times])
    lat, lon = np.array(lat), np.array(lon)
    alt = np.nan_to_num(_floats(alt))
    sp = _floats(speed)
    dist, head_deg, sp2, long_acc, lat_acc = _derive(t, lat, lon, None if np.isnan(sp).any() else sp)
    run = Run(name=trk_name or name, t=t, lat=lat, lon=lon, alt=alt, speed=sp2, long_acc=long_acc, lat_acc=lat_acc,
              dist=dist, heading=head_deg, start=times[0], source="GPX track (accelerations estimated)")
    for part in desc.split(" | "):
        if part.startswith("Driver: "):
            run.driver = part[8:]
        elif part.startswith("Type: "):
            run.run_type = part[6:]
        elif part:
            run.notes = part
    return _clean(run)


# ---------------------------------------------------------------- JSON (full backup)

def load_json_bytes(data: bytes, name: str) -> Run:
    import json

    try:
        d = json.loads(data.decode("utf-8-sig"))
        samples = d["samples"]
    except Exception as e:  # noqa: BLE001
        raise LoadError(f"{name}: not a run backup") from e
    if not isinstance(samples, list) or len(samples) < 2:
        raise LoadError(f"{name}: no samples")

    def col(key):
        return _floats([s.get(key) for s in samples])

    fused = sum(1 for s in samples if s.get("fused"))
    return _clean(Run(name=str(d.get("name") or name), t=col("t"), lat=col("lat"), lon=col("lon"), alt=col("alt"),
                      speed=col("speed"), long_acc=col("longAccel"), lat_acc=col("latAccel"), dist=col("distance"),
                      heading=col("heading"), start=_parse_time(str(d.get("startDate") or "")),
                      driver=str(d.get("driver") or ""), run_type=str(d.get("runType") or ""),
                      notes=str(d.get("notes") or ""),
                      source="GPS + IMU fusion" if fused > len(samples) / 2 else "GPS only"))


# ---------------------------------------------------------------- dispatch

def _apply_index(run: Run, meta: dict | None):
    if not meta:
        return
    run.name = meta.get("name") or run.name
    run.driver = meta.get("driver") or run.driver
    run.run_type = meta.get("run_type") or run.run_type
    run.notes = meta.get("notes") or run.notes


def _load_member(ext: str, data: bytes, name: str) -> Run:
    if ext == ".csv":
        return load_csv_text(data.decode("utf-8", errors="replace"), name)
    if ext == ".xlsx":
        return load_xlsx_bytes(data, name)
    if ext == ".gpx":
        return load_gpx_text(data.decode("utf-8", errors="replace"), name)
    if ext == ".json":
        return load_json_bytes(data, name)
    raise LoadError(f"{name}: unsupported file type")


def load_zip(path: str) -> tuple[list[Run], list[str]]:
    """Loads every run in a OBRA Essentials zip. Returns (runs, problems)."""
    runs, problems = [], []
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise LoadError(f"{os.path.basename(path)}: not a zip file") from e
    with z:
        members: dict[str, dict[str, str]] = {}
        index: dict[str, dict] = {}
        for info in z.infolist():
            if info.is_dir():
                continue
            base = os.path.basename(info.filename)
            if base.startswith(".") or "__MACOSX" in info.filename:
                continue
            stem, ext = os.path.splitext(base)
            ext = ext.lower()
            if base.lower() == "runs.csv":
                text = z.read(info).decode("utf-8-sig", errors="replace")
                for row in csv.DictReader(io.StringIO(text, newline="")):
                    if row.get("file"):
                        index[row["file"]] = row
            elif ext in (".csv", ".json", ".xlsx", ".gpx"):
                members.setdefault(stem, {})[ext] = info.filename
        if not members:
            raise LoadError(f"{os.path.basename(path)}: no runs inside")
        order = [s for s in index if s in members] + [s for s in members if s not in index]
        for stem in order:
            exts = members[stem]
            ext = next(e for e in (".csv", ".json", ".xlsx", ".gpx") if e in exts)
            try:
                run = _load_member(ext, z.read(exts[ext]), stem)
                _apply_index(run, index.get(stem))
                runs.append(run)
            except LoadError as e:
                problems.append(str(e))
            except Exception as e:  # noqa: BLE001
                problems.append(f"{stem}: {e}")
    return runs, problems


def load_path(path: str) -> tuple[list[Run], list[str]]:
    """Loads a .zip, .csv, .xlsx or .gpx. Returns (runs, problems); never raises for bad content."""
    ext = os.path.splitext(path)[1].lower()
    name = os.path.splitext(os.path.basename(path))[0]
    try:
        if ext == ".zip":
            return load_zip(path)
        with open(path, "rb") as f:
            data = f.read()
        if ext in (".csv", ".json", ".xlsx", ".gpx"):
            return [_load_member(ext, data, name)], []
        return [], [f"{os.path.basename(path)}: open a .zip, .csv, .xlsx, .gpx or backup .json exported from OBRA Essentials"]
    except LoadError as e:
        return [], [str(e)]
    except OSError as e:
        return [], [f"{os.path.basename(path)}: {e.strerror or e}"]
    except Exception as e:  # noqa: BLE001
        return [], [f"{os.path.basename(path)}: {e}"]


def site_key(run: Run) -> str:
    """Runs within ~1 km share a key, so start/finish lines are remembered per test site."""
    return f"{round(float(np.mean(run.lat)), 2):.2f},{round(float(np.mean(run.lon)), 2):.2f}"


def safe_filename(s: str) -> str:
    return re.sub(r'[\\/:*?"<>|]+', "-", s).strip() or "run"
