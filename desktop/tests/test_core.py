"""Core checks: run with `python tests/test_core.py [folder with Cone Setter sample exports]`."""

import math
import os
import sys
import tempfile
import zipfile

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from analyzer import data, laps  # noqa: E402

failures = []


def check(ok, msg):
    print(("  PASS " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def synthetic(laps_n=5, hz=10.0, radius=30.0, straight=80.0, v=12.0, lat0=51.755, lon0=-1.224, offset=0.37):
    """Stadium-shaped circuit driven clockwise at constant speed, starting part-way down a straight."""
    per = 2 * straight + 2 * math.pi * radius
    total = per * laps_n + 60.0
    t = np.arange(0, total / v, 1 / hz)
    s = (v * t + offset * per) % per
    x, y, hd = np.empty_like(s), np.empty_like(s), np.empty_like(s)
    for i, d in enumerate(s):
        if d < straight:                                   # north-going straight at x = -R
            x[i], y[i], hd[i] = -radius, d - straight / 2, 0.0
        elif d < straight + math.pi * radius:              # top turn, clockwise
            a = (d - straight) / radius
            x[i], y[i], hd[i] = -radius * math.cos(a), straight / 2 + radius * math.sin(a), math.degrees(a)
        elif d < 2 * straight + math.pi * radius:          # south-going straight at x = +R
            x[i], y[i], hd[i] = radius, straight / 2 - (d - straight - math.pi * radius), 180.0
        else:
            a = (d - 2 * straight - math.pi * radius) / radius
            x[i], y[i], hd[i] = radius * math.cos(a), -straight / 2 - radius * math.sin(a), 180.0 + math.degrees(a)
    lat, lon = data.to_geo(x, y, lat0, lon0)
    run = data.Run(name="Synthetic", t=t, lat=lat, lon=lon, alt=np.full_like(t, 80.0), speed=np.full_like(t, v),
                   long_acc=np.zeros_like(t), lat_acc=np.zeros_like(t), dist=v * t, heading=hd % 360)
    return run, per


print("== Lap timing")
run, per = synthetic()
expected = per / 12.0
gx, gy = data.to_local(run.lat, run.lon, 51.755, -1.224)                  # circuit coordinates
i = int(np.argmin(np.hypot(gx + 30, gy)))                                  # middle of the north-going straight
gate = laps.Gate.at_sample(run, i)
check(abs(gate.heading) < 2 or abs(gate.heading - 360) < 2, f"gate squares to the track (heading {gate.heading:.1f}°)")
found = laps.find_laps(run, gate)
check(len(found) == 4, f"circuit laps found: {len(found)}")
err = max(abs(l.time - expected) for l in found)
check(err < 0.005, f"lap times within 5 ms of {expected:.3f} s (worst error {err * 1000:.2f} ms)")
check(all(abs(l.distance - per) < 0.2 for l in found), "lap distance matches the circuit length")
check(len(laps.crossings(run, gate, one_way=True)) == len(found) + 1, "one crossing per pass")

rev = laps.Gate(gate.lat, gate.lon, (gate.heading + 180) % 360, gate.width)
check(laps.find_laps(run, rev) == [], "driving the wrong way through a one-way line doesn't count")
check(len(laps.find_laps(run, rev, one_way=False)) == len(found), "either-direction line counts both ways")

narrow = laps.Gate(gate.lat, gate.lon, gate.heading, 12.0)
other = laps.crossings(run, narrow)
check(all(abs(run.x[c.index] - run.x[i]) < 6 for c in other), "the far straight (60 m away) isn't picked up by a 12 m line")

j = int(np.argmin(np.hypot(gx - 30, gy)))                                  # middle of the other straight
finish = laps.Gate.at_sample(run, j)
p2p = laps.find_laps(run, gate, finish)
check(len(p2p) == 4, f"start-to-finish passes found: {len(p2p)}")
exp_p2p = ((run.dist[j] - run.dist[i]) % per) / 12.0     # the lines sit on the nearest samples
check(all(abs(l.time - exp_p2p) < 0.005 for l in p2p), f"start-to-finish times within 5 ms of {exp_p2p:.3f} s: {[round(l.time, 3) for l in p2p]}")

d, dt = laps.delta_to(run, found[1], run, found[0])
check(float(np.abs(dt).max()) < 0.01, "delta between two identical laps is zero")
d, sp = laps.lap_trace(run, found[0], run.speed)
check(len(d) == 800 and abs(float(sp.mean()) - 12.0) < 1e-6, "lap trace resamples over lap distance")
csv_text = laps.laps_csv(run, found, "km/h", 3.6)
check(csv_text.count("\r\n") == len(found) + 1 and "top_speed_kmh" in csv_text, "laps CSV")
g2 = laps.Gate.from_dict(gate.to_dict())
check(g2 == gate, "gate save / load round trip")
check(laps.format_lap_time(83.4567) == "1:23.457" and laps.format_lap_time(9.5) == "9.500", "lap time formatting")

print("== Loaders")
with tempfile.TemporaryDirectory() as tmp:
    # A zip shaped like the app's export, built from the synthetic run.
    iso = "2026-11-15T14:30:{:06.3f}Z"
    lines = ["time_utc,elapsed_s,lat,lon,alt_m,speed_kmh,speed_ms,long_accel_ms2,lat_accel_ms2,distance_m,heading_deg,gps_acc_m,source"]
    for k in range(0, len(run.t), 1):
        lines.append(f"{iso.format(run.t[k] % 60)},{run.t[k]:.3f},{run.lat[k]:.8f},{run.lon[k]:.8f},80.0,"
                     f"{run.speed[k] * 3.6:.2f},{run.speed[k]:.3f},0.000,0.000,{run.dist[k]:.2f},{run.heading[k]:.1f},3.5,fused")
    body = "\n".join(lines) + "\n"
    zpath = os.path.join(tmp, "runs.zip")
    with zipfile.ZipFile(zpath, "w") as z:
        z.writestr("Runs.csv", "﻿file,name,recorded_local,driver,run_type,notes\r\n"
                               'Run A,Run · A,2026-11-15 14:30:00,Machu,Autocross,"Line 1, with comma\nLine 2"\r\n')
        z.writestr("Run A.csv", body)
        z.writestr("Stray.txt", "ignore me")
    runs, problems = data.load_path(zpath)
    check(len(runs) == 1 and not problems, f"zip loads ({problems})")
    r = runs[0]
    check(r.name == "Run · A" and r.driver == "Machu" and r.run_type == "Autocross" and "Line 2" in r.notes, "zip index details applied")
    check(len(r.t) == len(run.t) and r.source == "GPS + IMU fusion", "CSV samples and source read")
    got = laps.find_laps(r, gate)
    check(len(got) == len(found) and max(abs(a.time - b.time) for a, b in zip(got, found)) < 0.02,
          "lap times survive the CSV round trip")
    bad = os.path.join(tmp, "bad.csv")
    open(bad, "w").write("a,b\n1,2\n3,4\n")
    runs, problems = data.load_path(bad)
    check(not runs and len(problems) == 1, f"wrong CSV gives a clear message: {problems}")
    notzip = os.path.join(tmp, "x.zip")
    open(notzip, "w").write("nope")
    runs, problems = data.load_path(notzip)
    check(not runs and len(problems) == 1, f"broken zip gives a clear message: {problems}")

print("== Updates")
from analyzer import updater  # noqa: E402
rel = updater.parse_manifest('{"version": "1.2.0", "build": 14, "url": "https://example.invalid/a.exe", "notes": "n", "size": "5"}')
check(rel.build == 14 and rel.size == 5 and rel.label == "1.2.0 (build 14)", "update manifest parsed")
check(updater.is_newer(rel, build=13) and not updater.is_newer(rel, build=14) and not updater.is_newer(rel, build=15), "newer build detected")
check(not updater.is_newer(rel, build=0), "a copy run from source never prompts")
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "latest.json")
if os.path.exists(here):
    live = updater.parse_manifest(open(here, encoding="utf-8").read())
    check(live.url.startswith("https://github.com/NB6RULES/ConeSetter/releases/download/"), "latest.json points at the release")

samples = sys.argv[1] if len(sys.argv) > 1 else None
if samples and os.path.isdir(samples):
    print("== Real Cone Setter exports")
    runs, problems = data.load_path(os.path.join(samples, "Sample-runs.zip"))
    check(len(runs) == 3 and not problems, f"app zip: {len(runs)} runs ({problems})")
    check(runs[0].driver == "Machu" and runs[0].run_type == "Skidpad" and "damp" in runs[0].notes, "app zip details")
    c, _ = data.load_path(os.path.join(samples, "sample.csv"))
    x, _ = data.load_path(os.path.join(samples, "Sample-export-details.xlsx"))
    g, _ = data.load_path(os.path.join(samples, "sample.gpx"))
    check(len(c) == 1 and len(x) == 1 and len(g) == 1, "CSV, Excel and GPX all open")
    check(len(c[0].t) == len(x[0].t) == len(g[0].t), f"same sample count in all three ({len(c[0].t)})")
    check(abs(c[0].top_speed - x[0].top_speed) < 0.01 and abs(c[0].top_speed - g[0].top_speed) < 0.01, "same top speed in all three")
    with zipfile.ZipFile(os.path.join(samples, "Sample-runs.zip")) as z, tempfile.TemporaryDirectory() as tmp:
        member = next(n for n in z.namelist() if n.endswith("Skidpad.gpx"))
        z.extract(member, tmp)
        gd, _ = data.load_path(os.path.join(tmp, member))
    check(x[0].driver == "Machu" and x[0].run_type == "Skidpad" and "damp" in x[0].notes, "Excel carries driver / type / notes")
    check(len(gd) == 1 and gd[0].driver == "Machu" and gd[0].run_type == "Skidpad" and "damp" in gd[0].notes, "GPX carries driver / type / notes")
    gate = laps.Gate.at_sample(c[0], c[0].index_at(8.0))
    lc, lx, lg = (laps.find_laps(r[0], gate) for r in (c, x, g))
    print("   laps:", [round(l.time, 3) for l in lc], [round(l.time, 3) for l in lx], [round(l.time, 3) for l in lg])
    check(len(lc) >= 1 and len(lc) == len(lx) == len(lg), "same laps from CSV, Excel and GPX")
    check(all(abs(a.time - b.time) < 0.05 for a, b in zip(lc, lx)), "Excel lap times match CSV")

print("\nALL CHECKS PASSED" if not failures else f"\n{len(failures)} CHECK(S) FAILED")
sys.exit(1 if failures else 0)
