"""Start / finish lines and lap timing."""

from __future__ import annotations

import math
from dataclasses import dataclass, asdict

import numpy as np

from .data import G, Run, to_geo, to_local


@dataclass
class Gate:
    """A timing line: centre point, the direction the car travels through it, and its width."""
    lat: float
    lon: float
    heading: float       # degrees from north, direction of travel
    width: float = 12.0  # metres, total

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "Gate":
        return Gate(float(d["lat"]), float(d["lon"]), float(d["heading"]), float(d.get("width", 12.0)))

    @staticmethod
    def at_sample(run: Run, i: int, width: float = 12.0) -> "Gate":
        """A line across the track at sample i, square to the direction of travel there."""
        i = max(0, min(int(i), len(run.t) - 1))
        # Direction from the positions around i; steadier than one heading value.
        k = max(1, int(round(run.sample_rate * 0.5)))
        a, b = max(0, i - k), min(len(run.t) - 1, i + k)
        dx, dy = run.x[b] - run.x[a], run.y[b] - run.y[a]
        if math.hypot(dx, dy) < 0.5:
            heading = float(run.heading[i])
        else:
            heading = math.degrees(math.atan2(dx, dy)) % 360.0
        return Gate(float(run.lat[i]), float(run.lon[i]), heading, width)

    def endpoints(self, run: Run):
        """((x1, y1), (x2, y2), (dirx, diry)) in the run's local metres."""
        cx, cy = to_local(np.array([self.lat]), np.array([self.lon]), run.lat[0], run.lon[0])
        cx, cy = float(cx[0]), float(cy[0])
        h = math.radians(self.heading)
        dx, dy = math.sin(h), math.cos(h)          # travel direction
        px, py = -dy, dx                           # along the line
        w = self.width / 2
        return (cx - px * w, cy - py * w), (cx + px * w, cy + py * w), (dx, dy)


@dataclass
class Crossing:
    t: float
    dist: float
    index: int   # sample just before the crossing


def crossings(run: Run, gate: Gate, one_way: bool = True, min_gap: float = 2.0) -> list[Crossing]:
    """Every time the car crosses the gate, with time interpolated between samples."""
    (x1, y1), (x2, y2), (dx, dy) = gate.endpoints(run)
    x, y = run.x, run.y
    if len(x) < 2:
        return []
    # Signed distance of each sample ahead of the line; a crossing is a sign change within the line's width.
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    ahead = (x - cx) * dx + (y - cy) * dy
    a0, a1 = ahead[:-1], ahead[1:]
    forward = (a0 < 0) & (a1 >= 0)
    backward = (a0 >= 0) & (a1 < 0)
    cand = np.nonzero(forward if one_way else (forward | backward))[0]
    out: list[Crossing] = []
    half = gate.width / 2
    for i in cand:
        denom = a1[i] - a0[i]
        f = float(-a0[i] / denom) if denom != 0 else 0.0
        px = x[i] + f * (x[i + 1] - x[i])
        py = y[i] + f * (y[i + 1] - y[i])
        along = (px - cx) * -dy + (py - cy) * dx
        if abs(along) > half:
            continue
        t = float(run.t[i] + f * (run.t[i + 1] - run.t[i]))
        d = float(run.dist[i] + f * (run.dist[i + 1] - run.dist[i]))
        if out and t - out[-1].t < min_gap:
            continue
        out.append(Crossing(t, d, int(i)))
    return out


@dataclass
class Lap:
    number: int
    t0: float
    t1: float
    d0: float
    d1: float
    time: float
    distance: float
    top_speed: float
    avg_speed: float
    min_speed: float
    max_accel_g: float
    max_brake_g: float
    max_lat_g: float


def _lap(run: Run, n: int, a: Crossing, b: Crossing) -> Lap:
    i0 = int(np.searchsorted(run.t, a.t))
    i1 = int(np.searchsorted(run.t, b.t, side="right"))
    sl = slice(i0, max(i1, i0 + 1))
    sp = run.speed[sl] if i1 > i0 else np.array([run.value_at(run.speed, a.t)])
    la = run.long_acc[sl] if i1 > i0 else np.array([0.0])
    lt = run.lat_acc[sl] if i1 > i0 else np.array([0.0])
    time = b.t - a.t
    dist = b.dist - a.dist
    return Lap(number=n, t0=a.t, t1=b.t, d0=a.dist, d1=b.dist, time=time, distance=dist,
               top_speed=float(sp.max()), avg_speed=dist / time if time > 0 else 0.0, min_speed=float(sp.min()),
               max_accel_g=float(max(la.max(), 0.0) / G), max_brake_g=float(max(-la.min(), 0.0) / G),
               max_lat_g=float(np.abs(lt).max() / G))


def find_laps(run: Run, start: Gate | None, finish: Gate | None = None, one_way: bool = True) -> list[Lap]:
    """Circuit laps when only a start line is set (each crossing ends one lap and starts the next);
    start-to-finish passes when a separate finish line is set."""
    if start is None:
        return []
    starts = crossings(run, start, one_way)
    laps: list[Lap] = []
    if finish is None:
        for n, (a, b) in enumerate(zip(starts, starts[1:]), 1):
            laps.append(_lap(run, n, a, b))
        return laps
    finishes = crossings(run, finish, one_way)
    n = 1
    for k, a in enumerate(starts):
        nxt = starts[k + 1].t if k + 1 < len(starts) else math.inf
        b = next((f for f in finishes if f.t > a.t), None)
        # If the start line is crossed again before the finish, the later start is the real one.
        if b is None or b.t > nxt:
            continue
        laps.append(_lap(run, n, a, b))
        n += 1
    return laps


def best_lap(laps: list[Lap]) -> Lap | None:
    return min(laps, key=lambda l: l.time) if laps else None


def lap_trace(run: Run, lap: Lap, arr: np.ndarray, points: int = 800):
    """(lap distance, value) resampled evenly over the lap distance."""
    d = np.linspace(0.0, lap.distance, points)
    t = lap_time_at_distance(run, lap, d)
    return d, np.interp(lap.t0 + t, run.t, arr)


def lap_time_at_distance(run: Run, lap: Lap, d: np.ndarray) -> np.ndarray:
    """Seconds into the lap at each lap distance d."""
    i0 = int(np.searchsorted(run.t, lap.t0))
    i1 = int(np.searchsorted(run.t, lap.t1, side="right"))
    dd = np.concatenate([[lap.d0], run.dist[i0:i1], [lap.d1]]) - lap.d0
    tt = np.concatenate([[lap.t0], run.t[i0:i1], [lap.t1]]) - lap.t0
    dd = np.maximum.accumulate(dd)
    return np.interp(d, dd, tt)


def delta_to(run: Run, lap: Lap, ref_run: Run, ref: Lap, points: int = 800):
    """(reference lap distance, seconds gained (+) or lost... positive = slower than the reference)."""
    frac = np.linspace(0.0, 1.0, points)
    t_lap = lap_time_at_distance(run, lap, frac * lap.distance)
    t_ref = lap_time_at_distance(ref_run, ref, frac * ref.distance)
    return frac * ref.distance, t_lap - t_ref


def gate_from_xy(run: Run, x: float, y: float, width: float = 12.0) -> tuple[Gate, int]:
    """Gate at the track point nearest to (x, y) in the run's local metres."""
    i = int(np.argmin((run.x - x) ** 2 + (run.y - y) ** 2))
    return Gate.at_sample(run, i, width), i


def laps_csv(run: Run, laps: list[Lap], unit_label: str, unit_factor: float) -> str:
    best = best_lap(laps)
    u = unit_label.replace("/", "")
    rows = [f"run,driver,run_type,lap,time_s,delta_to_best_s,distance_m,top_speed_{u},avg_speed_{u},min_speed_{u},"
            "max_accel_g,max_braking_g,max_lateral_g,start_s,end_s"]

    def q(s: str) -> str:
        return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n\r') else s

    for l in laps:
        rows.append(",".join([
            q(run.name), q(run.driver), q(run.run_type), str(l.number), f"{l.time:.3f}",
            f"{l.time - best.time:.3f}", f"{l.distance:.1f}", f"{l.top_speed * unit_factor:.2f}",
            f"{l.avg_speed * unit_factor:.2f}", f"{l.min_speed * unit_factor:.2f}",
            f"{l.max_accel_g:.3f}", f"{l.max_brake_g:.3f}", f"{l.max_lat_g:.3f}", f"{l.t0:.3f}", f"{l.t1:.3f}",
        ]))
    return "\r\n".join(rows) + "\r\n"


def format_lap_time(s: float) -> str:
    if not math.isfinite(s):
        return "–"
    m, sec = divmod(abs(s), 60.0)
    return f"{int(m)}:{sec:06.3f}" if m >= 1 else f"{sec:.3f}"
