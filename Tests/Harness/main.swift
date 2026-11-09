// Logic tests for the speed logger, compiled with the pure-Foundation core on the macOS CI runner:
//   swiftc -O ConeSetter/Speed/Core/*.swift Tests/Harness/main.swift -o harness && ./harness out
// Simulates a car lapping an oval with the phone mounted at an arbitrary angle, feeds noisy
// 1 Hz GPS (with latency) and 100 Hz IMU into FusionEngine, checks the results and writes a
// sample .xlsx export.

import Foundation
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var failures: [String] = []
func check(_ ok: Bool, _ message: String) {
    print((ok ? "  PASS " : "  FAIL ") + message)
    if !ok { failures.append(message) }
}

// MARK: - Seeded noise

struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

// MARK: - Track & speed profile

struct Oval {
    let L = 75.0
    let R = 15.0
    var perimeter: Double { 2 * L + 2 * .pi * R }

    /// Position (x east, y north), heading (rad, CCW from east) and curvature at arc length s.
    func at(_ sIn: Double) -> (x: Double, y: Double, psi: Double, kappa: Double) {
        let s = sIn.truncatingRemainder(dividingBy: perimeter)
        let arc = .pi * R
        if s < L { return (s, 0, 0, 0) }
        if s < L + arc {
            let a = (s - L) / R
            return (L + R * sin(a), R - R * cos(a), a, 1 / R)
        }
        if s < 2 * L + arc {
            let d = s - L - arc
            return (L - d, 2 * R, .pi, 0)
        }
        let a = (s - 2 * L - arc) / R
        return (-R * sin(a), R + R * cos(a), .pi + a, 1 / R)
    }
}

struct Truth {
    var t: [Double] = []
    var s: [Double] = []
    var v: [Double] = []
    var aLong: [Double] = []
    var kappa: [Double] = []
    var x: [Double] = []
    var y: [Double] = []
    var psi: [Double] = []
    var z: [Double] = []

    func value(_ arr: [Double], at time: Double) -> Double { RunPostProcessor.interp(t, arr, time) }
}

func makeTruth(laps: Double, preRoll: Double, postRoll: Double, rate: Double) -> Truth {
    let oval = Oval()
    let total = oval.perimeter * laps + 30
    let ds = 0.05
    let n = Int(total / ds) + 1
    var vlim = (0..<n).map { i -> Double in
        oval.at(Double(i) * ds).kappa > 0 ? (11.5 * oval.R).squareRoot() : 26
    }
    vlim[0] = 0
    vlim[n - 1] = 0
    var v = vlim
    for i in 1..<n { v[i] = min(v[i], (v[i - 1] * v[i - 1] + 2 * 6.5 * ds).squareRoot()) }
    for i in stride(from: n - 2, through: 0, by: -1) { v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * 8.5 * ds).squareRoot()) }

    var tAt = [Double](repeating: 0, count: n)
    for i in 1..<n {
        let vm = max((v[i] + v[i - 1]) / 2, 0.05)
        tAt[i] = tAt[i - 1] + ds / vm
    }

    var tr = Truth()
    let dt = 1 / rate
    let moveEnd = tAt[n - 1]
    var time = 0.0
    var j = 0
    while time <= preRoll + moveEnd + postRoll {
        let tm = time - preRoll
        var s = 0.0, vv = 0.0
        if tm <= 0 {
            s = 0; vv = 0
        } else if tm >= moveEnd {
            s = total; vv = 0
        } else {
            while j + 1 < n && tAt[j + 1] < tm { j += 1 }
            let f = (tm - tAt[j]) / max(tAt[j + 1] - tAt[j], 1e-9)
            s = (Double(j) + f) * ds
            vv = v[j] + (v[j + 1] - v[j]) * f
        }
        let p = oval.at(s)
        tr.t.append(time); tr.s.append(s); tr.v.append(vv); tr.kappa.append(p.kappa)
        tr.x.append(p.x); tr.y.append(p.y); tr.psi.append(p.psi)
        tr.z.append(80 + 4 * sin(2 * .pi * s / oval.perimeter))
        time += dt
    }
    tr.aLong = tr.v.indices.map { i in
        let a = max(i - 1, 0), b = min(i + 1, tr.v.count - 1)
        return (tr.v[b] - tr.v[a]) / max(tr.t[b] - tr.t[a], 1e-9)
    }
    return tr
}

// MARK: - Simulation

struct SimResult {
    var run: SpeedRun
    var truth: Truth
    var finalState: IMUState
    var calibratedAt: Double?
}

func simulate(useIMU: Bool, flipAccelSign: Bool, seed: UInt64, mount: simd_quatd, barometer: Bool = true,
              gravityLeak: Double = 0) -> SimResult {
    var rng = RNG(state: seed)
    let truth = makeTruth(laps: 2, preRoll: 4, postRoll: 4, rate: 100)
    let engine = FusionEngine(useIMU: useIMU)
    let frame = Geo.LocalFrame(lat0: 51.7550, lon0: -1.2240)  // Headington-ish

    let accBias = SIMD3<Double>(0.012, -0.008, 0.006)
    var gpsNoise = SIMD2<Double>(0, 0)
    var nextFix = 0.37
    var nextBaro = 0.2
    var altNoise = 0.0
    let z0 = 80.0
    var pending: [(arrive: Double, fix: GPSFix)] = []
    var calibratedAt: Double?
    var leak = SIMD3<Double>(0, 0, 0)

    for i in truth.t.indices {
        let t = truth.t[i]

        // GPS fix generated at its timestamp, delivered 0.25 s later.
        if t >= nextFix {
            let tf = nextFix
            gpsNoise = gpsNoise * 0.85 + SIMD2(rng.gauss(), rng.gauss()) * 0.55
            let px = truth.value(truth.x, at: tf) + gpsNoise.x
            let py = truth.value(truth.y, at: tf) + gpsNoise.y
            let ll = frame.latLon(x: px, y: py)
            let vt = truth.value(truth.v, at: tf)
            let speed = max(0, vt + rng.gauss() * 0.15)
            let psi = truth.value(truth.psi, at: tf)
            let course = Geo.normDeg(90 - psi * 180 / .pi + rng.gauss() * 1.0)
            altNoise = altNoise * 0.9 + rng.gauss() * 1.2
            pending.append((tf + 0.25, GPSFix(
                t: tf, lat: ll.lat, lon: ll.lon, alt: truth.value(truth.z, at: tf) + altNoise,
                hAcc: 3.5, vAcc: 4, speed: speed, speedAcc: 0.3,
                course: vt > 1 ? course : -1, courseAcc: vt > 1 ? 5 : -1)))
            nextFix += 1.0
        }
        if barometer, t >= nextBaro {
            engine.addBaro(t: nextBaro, rel: truth.value(truth.z, at: nextBaro) - z0 + rng.gauss() * 0.05 + 0.002 * nextBaro)
            nextBaro += 1.0
        }
        while let p = pending.first, p.arrive <= t {
            engine.addFix(p.fix)
            pending.removeFirst()
        }

        if useIMU {
            let v = truth.v[i]
            let k = truth.kappa[i]
            let aCar = SIMD3<Double>(truth.aLong[i], v * v * k, 0) / Geo.g
            let wCar = SIMD3<Double>(0, 0, v * k)
            let gCar = SIMD3<Double>(0, 0, -1)
            let vib = SIMD3<Double>(sin(t * 2 * .pi * 23), cos(t * 2 * .pi * 31), sin(t * 2 * .pi * 17)) * 0.04
            // Optional: the gravity estimate slowly absorbs part of any sustained acceleration
            // (as Core Motion's does), so the reported user acceleration loses that part.
            leak += (aCar * gravityLeak - leak) * (0.01 / 4.0)
            var acc = mount.act(aCar - leak) + accBias + vib + SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.03
            if flipAccelSign { acc = -acc }
            let grav = mount.act(simd_normalize(gCar - leak)) + SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.002
            let gyro = mount.act(wCar) + SIMD3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.01
            engine.addMotion(t: t, gravity: grav, userAccel: acc, rotationRate: gyro)
            if calibratedAt == nil, engine.state.isFused { calibratedAt = t }
        }
    }

    let samples = engine.finalize()
    let run = SpeedRun(id: UUID(), name: "Simulated oval", startDate: Date(timeIntervalSince1970: 1_793_000_000),
                       samples: samples, fixes: engine.fixes, imuUsed: useIMU, baro: engine.baro)
    return SimResult(run: run, truth: truth, finalState: engine.state, calibratedAt: calibratedAt)
}

func rms(_ x: [Double]) -> Double { x.isEmpty ? .infinity : (x.map { $0 * $0 }.reduce(0, +) / Double(x.count)).squareRoot() }

func truthStats(_ tr: Truth) -> (distance: Double, top: Double, t75: Double) {
    let launch = tr.t[tr.v.firstIndex { $0 >= 0.5 }!]
    let i75 = tr.s.firstIndex { $0 >= 75 }!
    let s0 = RunPostProcessor.interp(tr.t, tr.s, launch)
    let i75b = tr.s.firstIndex { $0 >= s0 + 75 } ?? i75
    return (tr.s.last! - tr.s.first!, tr.v.max()!, tr.t[i75b] - launch)
}

func evaluate(_ name: String, _ r: SimResult, expectFused: Bool, relaxed: Bool = false) {
    print("\n== \(name)")
    let s = r.run.samples
    let st = RunAnalysis.stats(r.run)
    let tru = truthStats(r.truth)
    print(String(format: "  samples %d  fixes %d  rate %.1f Hz  fused %.0f%%  state %@  calibrated at %@",
                 s.count, r.run.fixes.count, st.sampleRate, st.fusedFraction * 100, r.finalState.label,
                 r.calibratedAt.map { String(format: "%.1f s", $0) } ?? "never"))

    let fused = s.filter(\.fused)
    if expectFused {
        check(r.finalState.isFused, "engine ends fused")
        check((r.calibratedAt ?? 999) < 20, "calibrates within 20 s")
        let ev = fused.map { $0.speed - r.truth.value(r.truth.v, at: $0.t) }
        let ea = fused.map { $0.longAccel - r.truth.value(r.truth.aLong, at: $0.t) }
        let el = fused.map { s -> Double in
            let v = r.truth.value(r.truth.v, at: s.t), k = r.truth.value(r.truth.kappa, at: s.t)
            return s.latAccel - v * v * k
        }
        print(String(format: "  speed RMS err %.3f m/s  max %.3f  | long accel RMS %.3f m/s²  | lat accel RMS %.3f m/s²",
                     rms(ev), ev.map(abs).max() ?? 0, rms(ea), rms(el)))
        check(rms(ev) < (relaxed ? 0.8 : 0.45), "fused speed RMS error < \(relaxed ? 0.8 : 0.45) m/s")
        check(rms(ea) < (relaxed ? 2.0 : 1.2), "long accel RMS error < \(relaxed ? 2.0 : 1.2) m/s²")
        check(rms(el) < 1.2, "lat accel RMS error < 1.2 m/s²")
        check(st.fusedFraction > 0.9, "stays fused for the whole run (no false 'phone moved')")
        check(st.sampleRate > 9, "~10 Hz output")
    }

    // Positions should lie close to the true track.
    let frame = Geo.LocalFrame(lat0: 51.7550, lon0: -1.2240)
    let posErr = s.map { p -> Double in
        let xy = frame.xy(p.lat, p.lon)
        return hypot(xy.x - r.truth.value(r.truth.x, at: p.t), xy.y - r.truth.value(r.truth.y, at: p.t))
    }
    print(String(format: "  position RMS err %.2f m", rms(posErr)))
    check(rms(posErr) < 4, "position RMS error < 4 m")

    print(String(format: "  distance %.1f m (truth %.1f)  top %.2f m/s (truth %.2f)  75 m %@ s (truth %.3f)  0-100 %@",
                 st.distance, tru.distance, st.topSpeed, tru.top,
                 st.best75m.map { String(format: "%.3f", $0) } ?? "–", tru.t75,
                 st.zeroTo100.map { String(format: "%.2f s", $0) } ?? "–"))
    check(abs(st.distance - tru.distance) / tru.distance < (expectFused ? 0.03 : 0.05), "distance within tolerance")
    check(abs(st.topSpeed - tru.top) < (expectFused ? 0.8 : 1.2), "top speed within tolerance")
    if expectFused {
        check(st.best75m.map { abs($0 - tru.t75) < (relaxed ? 0.4 : 0.25) } ?? false, "75 m time within tolerance")
    }
    check(st.maxLateral > 0.5 * Geo.g, "lateral g detected in corners")

    // Elevation
    let ez = s.map { $0.alt - r.truth.value(r.truth.z, at: $0.t) }
    var truthClimb = 0.0
    var ref = r.truth.z[0]
    for z in r.truth.z where z - ref >= 0.3 || ref - z >= 0.3 {
        if z > ref { truthClimb += z - ref }
        ref = z
    }
    print(String(format: "  elevation RMS err %.2f m  climb %.1f m (truth %.1f)  range %.1f–%.1f m  baro %@",
                 rms(ez), st.climb, truthClimb, st.minElevation ?? .nan, st.maxElevation ?? .nan, r.run.hasBarometer ? "yes" : "no"))
    let offset = ez.reduce(0, +) / Double(max(ez.count, 1))
    let shape = ez.map { $0 - offset }
    print(String(format: "  elevation shape RMS err %.2f m, absolute offset %+.2f m (GPS-limited)", rms(shape), offset))
    if r.run.hasBarometer {
        check(rms(shape) < 0.4, "barometric elevation shape RMS error < 0.4 m")
        check(abs(offset) < 4, "absolute elevation within GPS error (< 4 m)")
        check(abs(st.climb - truthClimb) < 0.3 * truthClimb + 1, "total climb within 30%")
    } else {
        check(rms(ez) < 4, "GPS elevation RMS error < 4 m")
    }

    // Skip stops
    let idle = IdleFilter.apply(s, IdleSkip(enabled: true, speedBelow: 1, minDuration: 3, padding: 1))
    let shownSpan = (idle.activeT.last ?? 0)
    print(String(format: "  skip stops: skipped %.1f s, %d/%d samples shown, active span %.1f s of %.1f s, %d cut(s)",
                 idle.skippedTime, idle.keptCount, s.count, shownSpan, st.duration, idle.cuts.count))
    check(idle.skippedTime > 4.5 && idle.skippedTime < 8, "skip stops removes the ~6 s standing at start/end")
    check(abs(shownSpan + idle.skippedTime - st.duration) < 0.5, "active time + skipped = duration")
    let off = IdleFilter.apply(s, IdleSkip(enabled: false))
    check(off.keptCount == s.count && off.skippedTime == 0, "skip disabled keeps everything")
}

// MARK: - Image for the export test

func testPNG(run: SpeedRun, size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let s = run.samples
    guard let f = s.first else { return nil }
    let frame = Geo.LocalFrame(lat0: f.lat, lon0: f.lon)
    let pts = s.map { frame.xy($0.lat, $0.lon) }
    let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
    let span = max(maxX - minX, maxY - minY) * 1.1
    let sc = Double(size) / span
    let top = s.map(\.speed).max() ?? 1
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    for i in 1..<pts.count {
        let c = HeatColor.rgb(s[i].speed / top)
        ctx.setStrokeColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
        ctx.move(to: CGPoint(x: (pts[i - 1].x - (minX + maxX) / 2) * sc + Double(size) / 2, y: (pts[i - 1].y - (minY + maxY) / 2) * sc + Double(size) / 2))
        ctx.addLine(to: CGPoint(x: (pts[i].x - (minX + maxX) / 2) * sc + Double(size) / 2, y: (pts[i].y - (minY + maxY) / 2) * sc + Double(size) / 2))
        ctx.strokePath()
    }
    guard let img = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - Run

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "harness-out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let mountA = simd_quatd(angle: 1.2, axis: simd_normalize(SIMD3<Double>(0.3, 1, 0.2)))
    * simd_quatd(angle: 0.65, axis: SIMD3<Double>(0, 0, 1))
let mountB = simd_quatd(angle: .pi / 2, axis: SIMD3<Double>(1, 0, 0))
    * simd_quatd(angle: -2.4, axis: SIMD3<Double>(0, 0, 1))

let fusedA = simulate(useIMU: true, flipAccelSign: false, seed: 42, mount: mountA)
evaluate("IMU fusion · tilted mount", fusedA, expectFused: true)

let fusedB = simulate(useIMU: true, flipAccelSign: true, seed: 7, mount: mountB)
evaluate("IMU fusion · upright mount, opposite accel sign convention", fusedB, expectFused: true)

let leaky = simulate(useIMU: true, flipAccelSign: false, seed: 11, mount: mountA, gravityLeak: 0.6)
evaluate("IMU fusion · gravity estimate leaning in corners (Core Motion-like)", leaky, expectFused: true, relaxed: true)

let gpsOnly = simulate(useIMU: false, flipAccelSign: false, seed: 99, mount: mountA, barometer: false)
evaluate("GPS only", gpsOnly, expectFused: false)

// Codable round trip
do {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(fusedA.run)
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let back = try dec.decode(SpeedRun.self, from: data)
    check(back.samples.count == fusedA.run.samples.count, "run JSON round trip")
    try data.write(to: outDir.appendingPathComponent("sample-run.json"))
} catch {
    check(false, "run JSON round trip: \(error)")
}

// Excel export
print("\n== Excel export")
let t0 = Date()
var images = RunExportImages()
images.track = testPNG(run: fusedA.run, size: 560)
images.speedChart = testPNG(run: fusedA.run, size: 320)
images.chartSize = (320, 320)
images.elevationChart = testPNG(run: fusedA.run, size: 320)
let xlsx = RunExcelExporter.workbook(run: fusedA.run, unit: .kmh, images: images,
                                     skip: IdleSkip(enabled: true, speedBelow: 1, minDuration: 3, padding: 1))
print(String(format: "  %d bytes in %.2f s", xlsx.count, Date().timeIntervalSince(t0)))
check(xlsx.count > 10_000, "xlsx generated")
try? xlsx.write(to: outDir.appendingPathComponent("Sample-export.xlsx"))
let gpsXlsx = RunExcelExporter.workbook(run: gpsOnly.run, unit: .mph)
try? gpsXlsx.write(to: outDir.appendingPathComponent("Sample-export-gps-only.xlsx"))
try? RunExcelExporter.csv(run: fusedA.run, unit: .kmh).write(to: outDir.appendingPathComponent("sample.csv"), atomically: true, encoding: .utf8)
try? RunExcelExporter.gpx(run: fusedA.run).write(to: outDir.appendingPathComponent("sample.gpx"), atomically: true, encoding: .utf8)

print(failures.isEmpty ? "\nALL CHECKS PASSED" : "\n\(failures.count) CHECK(S) FAILED")
exit(failures.isEmpty ? 0 : 1)
