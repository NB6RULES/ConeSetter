"""Core checks: run with `python tests/test_core.py [folder with OBRA Essentials sample exports]`."""

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
    import json as _json
    backup = {"id": "X", "name": "Backup run", "startDate": "2026-11-15T14:30:00Z", "driver": "Machu", "runType": "Skidpad",
              "notes": "n", "imuUsed": True, "fixes": [],
              "samples": [{"t": float(run.t[k]), "lat": float(run.lat[k]), "lon": float(run.lon[k]), "alt": 80.0,
                           "speed": float(run.speed[k]), "longAccel": 0.0, "latAccel": 0.0, "heading": float(run.heading[k]),
                           "distance": float(run.dist[k]), "hAcc": 3.5, "fused": True} for k in range(len(run.t))]}
    bz = os.path.join(tmp, "backup.zip")
    with zipfile.ZipFile(bz, "w") as z:
        z.writestr("Backup run.json", _json.dumps(backup))
    runs, problems = data.load_path(bz)
    check(len(runs) == 1 and not problems and runs[0].driver == "Machu" and runs[0].source == "GPS + IMU fusion"
          and len(laps.find_laps(runs[0], gate)) == len(found), f"full-backup zip from the phone opens ({problems})")
    bad = os.path.join(tmp, "bad.csv")
    open(bad, "w").write("a,b\n1,2\n3,4\n")
    runs, problems = data.load_path(bad)
    check(not runs and len(problems) == 1, f"wrong CSV gives a clear message: {problems}")
    notzip = os.path.join(tmp, "x.zip")
    open(notzip, "w").write("nope")
    runs, problems = data.load_path(notzip)
    check(not runs and len(problems) == 1, f"broken zip gives a clear message: {problems}")

print("== Satellite tiles")
from analyzer import tiles  # noqa: E402
lx, ly = tiles.tile_xy(51.5074, -0.1278, 10)
check((int(lx), int(ly)) == (511, 340), f"Web Mercator tile for central London at zoom 10: {int(lx)}, {int(ly)}")
tx, ty = tiles.tile_xy(51.7551, -1.2242, 17)
la, lo = tiles.tile_latlon(tx, ty, 17)
check(abs(la - 51.7551) < 1e-9 and abs(lo + 1.2242) < 1e-9, "tile coordinates round trip")
box = tiles.padded_box(51.7545, 51.7557, -1.2252, -1.2232)
rng = tiles.range_for(*box)
s_, w_, n_, e_ = rng.bounds()
check(rng.count <= tiles.MAX_TILES and rng.z >= 17, f"zoom chosen for a 140 m site: z{rng.z}, {rng.cols}x{rng.rows} tiles")
check(s_ <= box[0] and w_ <= box[1] and n_ >= box[2] and e_ >= box[3], "tiles cover the whole padded track")
calls = []
def fake(z, x, y, cache, timeout):                       # deepest level has no imagery: same placeholder everywhere
    calls.append(z)
    return b"placeholder" if z == rng.z else f"{z}/{x}/{y}".encode()
used, blobs = tiles.fetch(rng, None, fetcher=fake)
check(used.z == rng.z - 1 and len(blobs) == used.count and len(set(blobs.values())) == used.count,
      "steps out a zoom level when the service has no imagery at full depth")
us, uw, un, ue = used.bounds()
check(us <= box[0] and uw <= box[1] and un >= box[2] and ue >= box[3], "the shallower tiles still cover the track")

print("== Car logs (DBC + MF4)")
from analyzer import canlog  # noqa: E402
dbc = canlog.parse_dbc("""
BO_ 256 Msg_A: 8 X
 SG_ U8_le : 0|8@1+ (0.5,10) [0|0] "V" X
 SG_ S16_le : 8|16@1- (0.1,0) [0|0] "deg" X
 SG_ Bits_le : 28|3@1+ (1,0) [0|0] "" X
 SG_ U16_be : 39|16@0+ (1,0) [0|0] "rpm" X
 SG_ S12_be : 55|12@0- (1,0) [0|0] "" X
 SG_ Flag : 63|1@1- (1,0) [0|1] "" X
 SG_ Raw_only : 56|4@1+ (0,0) [0|0] "" X
BO_ 2566844926 Msg_ext: 8 X
 SG_ Val : 0|32@1+ (1,0) [0|0] "" X
CM_ SG_ 256 U8_le "eight bits";
VAL_ 256 Bits_le 5 "FIVE" 2 "TWO" ;
""", "t.dbc")
msg = dbc.find(256, False)
payload = np.array([[0x10, 0x9C, 0xFF, 0x50, 0x12, 0x34, 0x8F, 0xF5]], dtype=np.uint8)
vals = {sg.name: float(canlog.decode_signal(sg, payload)[0]) for sg in msg.signals}
check(vals["U8_le"] == 18.0, f"unsigned little-endian with scale and offset ({vals['U8_le']})")
check(abs(vals["S16_le"] + 10.0) < 1e-9, f"signed little-endian (0xFF9C = -100 -> {vals['S16_le']})")
check(vals["Bits_le"] == 5.0, f"bit field inside a byte ({vals['Bits_le']})")
check(vals["U16_be"] == 0x1234, f"big-endian 16-bit (0x1234 -> {vals['U16_be']:.0f})")
check(vals["S12_be"] == -1793.0, f"signed big-endian 12-bit across a byte boundary ({vals['S12_be']})")
check(vals["Flag"] == 1.0, "a 1-bit signal marked signed still reads 1, not -1")
check(vals["Raw_only"] == 5.0 and next(sg for sg in msg.signals if sg.name == "Raw_only").scale_missing,
      "a scale of 0 in the DBC falls back to the raw value")
check(msg.signals[2].choices == {5: "FIVE", 2: "TWO"} and msg.signals[0].comment == "eight bits", "value table and comment read")
check(dbc.find(0x18FEF1FE, True) is not None and dbc.find(0x18FEF1FE, False) is None, "extended (29-bit) ID recognised")

sample = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sample")
demo_dbc = canlog.load_dbc(os.path.join(sample, "demo-car.dbc"))
car = canlog.load_car_log(os.path.join(sample, "demo-car-log.mf4"), demo_dbc)
gps = data.load_path(os.path.join(sample, "demo-runs.zip"))[0][0]
check(car.frame_count == 14112 and len([s for s in car.series if s.decoded]) == 11, f"demo MF4 read: {car.frame_count} frames, {len(car.series)} signals")
check(any("0x300" in n for n in car.notes) and car.series[-1].decoded is False, "message missing from the DBC kept as raw bytes, listed last")
volts = car.find("Vehicle_status (0x102).Battery_voltage_V")
check(volts is not None and 12.6 < volts.value_at(30) < 13.2, f"big-endian signal from the MF4 ({volts.value_at(30):.2f} V)")
state = car.find("Vehicle_status (0x102).AS_state")
check(state.text_at(1.0) == "AS_READY (2)" and state.text_at(40.0) == "AS_DRIVING (3)", "state names shown from the value table")
off = canlog.clock_offset(car.start, gps.start)
check(off is not None and abs(off + 6.0) < 1e-6, f"clock offset between logger and phone: {off:+.2f} s")
check(abs(canlog.overlap(car, off, gps.t[0], gps.t[-1]) - gps.duration) < 0.2, "log covers the whole run at that offset")
spd = car.find("Driver_inputs (0x101).Vehicle_speed_kmh")
worst = max(abs(spd.value_at(tt - off) - gps.value_at(gps.speed, tt) * 3.6) for tt in np.arange(5, 80, 1.7))
check(worst < 1.5, f"CAN speed lines up with GPS speed at the clock offset (worst {worst:.2f} km/h)")
found_off = canlog.align_by_signal(car.find("Wheel_speeds (0x100).RR_wheel_speed_rpm"), gps.t, gps.speed)
check(found_off is not None and abs(found_off[0] + 6.0) < 0.15 and found_off[1] > 0.8,
      f"offset recovered from a wheel-speed signal alone: {found_off[0]:+.2f} s, match {found_off[1]:.0%}")
weak = canlog.align_by_signal(volts, gps.t, gps.speed)
check(weak is None or weak[1] < 0.8, "a signal unrelated to speed gives a poor match score")
raw = canlog.decode(car.frames, None, "x")
check(all(not s.decoded for s in raw.series) and len(raw.series) == 8 * 3 + 4, "without a DBC every message shows as raw bytes")
with tempfile.TemporaryDirectory() as tmp:
    junk = os.path.join(tmp, "junk.mf4")
    open(junk, "wb").write(b"not an mf4 file at all")
    try:
        canlog.load_car_log(junk, None)
        check(False, "a broken MF4 is refused")
    except canlog.CanLogError as e:
        check(True, f"a broken MF4 is refused with a message: {str(e)[:60]}")
    try:
        canlog.parse_dbc("hello world", "x.dbc")
        check(False, "an empty DBC is refused")
    except canlog.CanLogError:
        check(True, "a file that isn't a DBC is refused")

print("== Updates")
from analyzer import updater  # noqa: E402
rel = updater.parse_manifest('{"version": "1.2.0", "build": 14, "url": "https://example.invalid/a.exe", "notes": "n", "size": "5"}')
check(rel.build == 14 and rel.size == 5 and rel.label == "1.2.0 (build 14)", "update manifest parsed")
check(updater.is_newer(rel, build=13) and not updater.is_newer(rel, build=14) and not updater.is_newer(rel, build=15), "newer build detected")
check(not updater.is_newer(rel, build=0), "a copy run from source never prompts")
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "latest.json")
if os.path.exists(here):
    live = updater.parse_manifest(open(here, encoding="utf-8").read())
    check(live.url.startswith("https://github.com/NB6RULES/"), "latest.json points at the release")

samples = sys.argv[1] if len(sys.argv) > 1 else None
if samples and os.path.isdir(samples):
    print("== Real OBRA Essentials exports")
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
