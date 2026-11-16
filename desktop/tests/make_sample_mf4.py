"""Builds sample/demo-car-log.mf4: a CAN bus log that goes with the first run in sample/demo-runs.zip.
Decoded with sample/demo-car.dbc. Run from the desktop folder: python tests/make_sample_mf4.py"""

import os
import sys
from datetime import timedelta

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from analyzer import data  # noqa: E402

LEAD_IN = 6.0   # the logger starts this long before the phone


def frames_for(run):
    hz = 50.0
    t = np.arange(0.0, run.duration + LEAD_IN + 4.0, 1 / hz)
    rt = t - LEAD_IN
    v = np.interp(rt, run.t, run.speed, left=0.0, right=0.0)
    long_acc = np.interp(rt, run.t, run.long_acc, left=0.0, right=0.0)
    lat_acc = np.interp(rt, run.t, run.lat_acc, left=0.0, right=0.0)
    rpm = v / (2 * np.pi * 0.253) * 60.0
    yaw = np.where(v > 1.0, lat_acc / np.maximum(v, 1.0), 0.0)                 # rad/s
    steer = np.degrees(np.arctan(1.53 * yaw / np.maximum(v, 1.0)))             # bicycle model, 1.53 m wheelbase
    half_track = 0.6
    out = []

    def u16(x):
        x = np.clip(np.round(x), 0, 65535).astype("<u2")
        return x.view(np.uint8).reshape(-1, 2)

    def s16(x):
        x = np.clip(np.round(x), -32768, 32767).astype("<i2")
        return x.view(np.uint8).reshape(-1, 2)

    def u8(x):
        return np.clip(np.round(x), 0, 255).astype(np.uint8).reshape(-1, 1)

    inner = 1 - half_track * yaw / np.maximum(v, 1.0)
    outer = 1 + half_track * yaw / np.maximum(v, 1.0)
    wheels = np.hstack([u16(rpm * inner * 10), u16(rpm * outer * 10), u16(rpm * inner * 10.02), u16(rpm * outer * 10.02)])
    inputs = np.hstack([s16(steer * 10), u8(np.clip(-long_acc / 9.0, 0, 1) * 200), u8(np.clip(long_acc / 5.0, 0, 1) * 200),
                        u16(v * 3.6 * 100), np.zeros((len(t), 2), np.uint8)])
    state = np.where(rt < 0, 2, np.where(rt > run.duration, 5, 3))
    brake_light = (long_acc < -1.0).astype(int)
    volts = np.round((13.1 - 0.4 * np.clip(long_acc / 5.0, 0, 1)) * 100).astype(">u2").view(np.uint8).reshape(-1, 2)
    status = np.hstack([u8(state | (brake_light << 4)), volts, np.zeros((len(t), 5), np.uint8)])
    unknown = np.hstack([u8((np.arange(len(t)) % 256)), np.zeros((len(t), 7), np.uint8)])
    for fid, payload, phase, every, dlc in ((256, wheels, 0.000, 1, 8), (257, inputs, 0.004, 1, 8),
                                            (258, status, 0.008, 5, 4), (0x300, unknown, 0.012, 5, 8)):
        sel = slice(None, None, every)
        out.append((t[sel] + phase, np.full(len(t[sel]), fid, np.uint32), payload[sel], dlc))
    ts = np.concatenate([o[0] for o in out])
    order = np.argsort(ts, kind="stable")
    return (ts[order], np.concatenate([o[1] for o in out])[order], np.concatenate([o[2] for o in out])[order],
            np.concatenate([np.full(len(o[0]), o[3], np.uint8) for o in out])[order])


def write_mf4(path, t, ids, payload, dlc, start):
    from asammdf import MDF, Signal

    rec = np.zeros(len(t), dtype=[("CAN_DataFrame.BusChannel", "<u1"), ("CAN_DataFrame.ID", "<u4"),
                                  ("CAN_DataFrame.IDE", "<u1"), ("CAN_DataFrame.DLC", "<u1"),
                                  ("CAN_DataFrame.DataLength", "<u1"), ("CAN_DataFrame.DataBytes", "<u1", (8,)),
                                  ("CAN_DataFrame.Dir", "<u1")])
    rec["CAN_DataFrame.BusChannel"] = 1
    rec["CAN_DataFrame.ID"] = ids
    rec["CAN_DataFrame.DLC"] = dlc
    rec["CAN_DataFrame.DataLength"] = dlc
    rec["CAN_DataFrame.DataBytes"] = payload
    mdf = MDF(version="4.10")
    mdf.header.start_time = start
    mdf.append([Signal(samples=rec, timestamps=t, name="CAN_DataFrame")], comment="CAN1", acq_name="CAN1_Rx")
    mdf.save(path, overwrite=True, compression=2)
    mdf.close()


def main():
    runs, problems = data.load_path(os.path.join(HERE, "..", "sample", "demo-runs.zip"))
    assert runs and not problems, problems
    run = runs[0]
    t, ids, payload, dlc = frames_for(run)
    out = os.path.join(HERE, "..", "sample", "demo-car-log.mf4")
    write_mf4(out, t, ids, payload, dlc, run.start - timedelta(seconds=LEAD_IN))
    print(f"wrote {out}: {len(t)} frames over {t[-1]:.1f} s, {os.path.getsize(out) / 1024:.0f} KB")


if __name__ == "__main__":
    main()
