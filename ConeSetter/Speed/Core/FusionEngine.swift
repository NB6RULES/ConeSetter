import Foundation
import simd

enum IMUState: Equatable {
    case off
    case waiting
    case calibrating(Double)
    case fused
    case moved

    var label: String {
        switch self {
        case .off: return "GPS only"
        case .waiting: return "IMU starting"
        case .calibrating(let p): return "IMU calibrating \(Int(p * 100))%"
        case .fused: return "GPS + IMU 10 Hz"
        case .moved: return "Phone moved · recalibrating"
        }
    }

    var isFused: Bool { self == .fused }
}

/// Fuses 1 Hz GPS with 50–100 Hz Core Motion data into a 10 Hz speed / acceleration trace.
///
/// The phone must be fixed to the car. The forward axis of the car, as seen by the phone,
/// is learned automatically by least squares from
///   • GPS speed changes vs. integrated horizontal acceleration (longitudinal), and
///   • gyro yaw rate × speed vs. horizontal acceleration (lateral),
/// so the phone can be mounted in any orientation. Lateral acceleration (v · yaw rate)
/// needs no calibration at all. Without IMU data the engine falls back to GPS only.
final class FusionEngine {
    let useIMU: Bool
    private(set) var samples: [SpeedSample] = []
    private(set) var fixes: [GPSFix] = []
    private(set) var baro: [BaroSample] = []
    private(set) var state: IMUState
    private(set) var liveAltitude: Double?
    private var baroOffset: Double?

    // Live outputs
    private(set) var liveSpeed: Double = 0
    private(set) var liveLongAccel: Double = 0
    private(set) var liveLatAccel: Double = 0
    private(set) var liveDistance: Double = 0
    private(set) var topSpeed: Double = 0

    // Gravity / horizontal basis (device frame)
    private var gravityWarmup: [SIMD3<Double>] = []
    private var gRef: SIMD3<Double>?
    private var gLP: SIMD3<Double>?
    private var e1 = SIMD3<Double>(1, 0, 0)
    private var e2 = SIMD3<Double>(0, 1, 0)

    // Calibration (2x2 ridge least squares for the forward axis)
    private var normal = simd_double2x2(0)
    private var rhs = SIMD2<Double>(0, 0)
    private var longExcitation = 0.0
    private var latExcitation = 0.0
    private(set) var forward: SIMD2<Double>?
    private var badInnovations = 0

    // Fusion
    private var vF = 0.0
    private var bias = 0.0
    private var lastMotionT: Double?
    private var history: [(t: Double, dt: Double, h: SIMD2<Double>, v: Double)] = []
    private var latWinH = SIMD2<Double>(0, 0)
    private var latWinTarget = 0.0
    private var latWinDt = 0.0
    private var longLP = 0.0
    private var latLP = 0.0
    private var emitAccum = 0.0
    private var prevSpeedFix: (t: Double, v: Double)?
    private var gpsSpeed: (t: Double, v: Double)?

    // Raw IMU stream kept for the offline (whole-run) re-fusion in finalize().
    private struct IMURecord {
        var t: Double
        var dt: Float
        var hx: Float
        var hy: Float
        var yaw: Float
        var seg: Int32
    }
    private var records: [IMURecord] = []
    private var segment = 0
    private var segmentForward: [Int: SIMD2<Double>] = [:]

    static let calibrationTarget = 8.0
    private let emitInterval = 0.1

    init(useIMU: Bool) {
        self.useIMU = useIMU
        self.state = useIMU ? .waiting : .off
    }

    var hasRecentMotion: Bool { lastMotionT != nil }

    // MARK: - Motion input

    /// - Parameters:
    ///   - t: seconds since the run started
    ///   - gravity: Core Motion gravity, device frame, in g
    ///   - userAccel: Core Motion user acceleration, device frame, in g
    ///   - rotationRate: rad/s, device frame
    func addMotion(t: Double, gravity: SIMD3<Double>, userAccel: SIMD3<Double>, rotationRate: SIMD3<Double>) {
        guard useIMU else { return }
        let gLen = simd_length(gravity)
        guard gLen > 0.3, gLen.isFinite else { return }
        let gUnit = gravity / gLen

        let dt: Double
        if let last = lastMotionT {
            dt = t - last
            guard dt > 0 else { return }
        } else {
            dt = 0
        }
        lastMotionT = t
        let step = min(dt, 0.1)

        // Establish the horizontal basis from the first half second of gravity.
        guard let ref = gRef else {
            gravityWarmup.append(gUnit)
            if gravityWarmup.count >= 25 {
                let mean = gravityWarmup.reduce(SIMD3<Double>(0, 0, 0), +) / Double(gravityWarmup.count)
                setBasis(simd_normalize(mean))
                gravityWarmup.removeAll()
                state = .calibrating(0)
            }
            return
        }

        // Detect the phone being moved relative to the car.
        let lpAlpha = step / (1.0 + step)
        let lp = simd_normalize((gLP ?? ref) * (1 - lpAlpha) + gUnit * lpAlpha)
        gLP = lp
        if simd_dot(lp, ref) < cos(20.0 * .pi / 180) {
            setBasis(lp)
            resetCalibration()
            state = .moved
            return
        }

        let up = -ref
        let a3 = userAccel * Geo.g
        let h = SIMD2<Double>(simd_dot(a3, e1), simd_dot(a3, e2))
        let yawRate = simd_dot(rotationRate, up)
        let vNow = forward != nil ? vF : currentGPSSpeed(at: t)
        if step > 0 {
            records.append(IMURecord(t: t, dt: Float(step), hx: Float(h.x), hy: Float(h.y),
                                     yaw: Float(yawRate), seg: Int32(segment)))
        }

        // Lateral calibration rows, averaged over 0.1 s windows.
        latWinH += h * step
        latWinTarget += vNow * yawRate * step
        latWinDt += step
        if latWinDt >= 0.1 {
            let hAvg = latWinH / latWinDt
            let target = latWinTarget / latWinDt
            if vNow > 3, abs(target) > 0.4 {
                let q = SIMD2<Double>(hAvg.y, -hAvg.x)
                addRow(q, target, weight: latWinDt)
                latExcitation += abs(target) * latWinDt
            }
            latWinH = .zero
            latWinTarget = 0
            latWinDt = 0
            solveCalibration()
        }

        // Prediction
        var aLong = 0.0
        if let f = forward {
            aLong = simd_dot(h, f) - bias
            vF = max(0, vF + aLong * step)
        } else {
            vF = currentGPSSpeed(at: t)
        }

        history.append((t, step, h, vF))
        if let first = history.first, t - first.t > 8 {
            history.removeFirst(min(history.count, 50))
        }

        let k = step / (0.12 + step)
        if forward != nil { longLP += (aLong - longLP) * k }
        latLP += (vNow * yawRate - latLP) * k

        liveSpeed = vF
        liveLongAccel = forward != nil ? longLP : 0
        liveLatAccel = latLP
        liveDistance += vF * step
        topSpeed = max(topSpeed, vF)

        emitAccum += step
        if emitAccum >= emitInterval {
            emitAccum = emitAccum.truncatingRemainder(dividingBy: emitInterval)
            emitSample(t: t, fused: forward != nil)
        }
    }

    // MARK: - Barometer input

    /// - Parameters:
    ///   - t: seconds since the run started
    ///   - rel: barometric altitude change since the altimeter started, metres
    func addBaro(t: Double, rel: Double) {
        guard rel.isFinite else { return }
        if let last = baro.last, t <= last.t { return }
        baro.append(BaroSample(t: t, rel: rel))
        if let off = baroOffset { liveAltitude = off + rel }
    }

    // MARK: - GPS input

    /// - Parameters:
    ///   - fix: the fix, with `t` = fix timestamp in run seconds
    ///   - arrival: run seconds when the fix was delivered (for latency compensation)
    func addFix(_ fix: GPSFix) {
        guard fix.hAcc >= 0, fix.hAcc <= 50 else { return }
        if let last = fixes.last, fix.t <= last.t { return }

        var v: Double?
        if fix.hasSpeed {
            v = fix.speed
        } else if let last = fixes.last {
            let dt = fix.t - last.t
            if dt > 0.2, dt < 5, fix.hAcc < 15, last.hAcc < 15 {
                v = Geo.haversine(last.lat, last.lon, fix.lat, fix.lon) / dt
            }
        }
        fixes.append(fix)
        if let b = baro.last, fix.vAcc >= 0, fix.vAcc < 30 {
            let est = fix.alt - b.rel
            baroOffset = baroOffset.map { $0 + (est - $0) * 0.1 } ?? est
            liveAltitude = (baroOffset ?? est) + b.rel
        } else if baro.isEmpty {
            liveAltitude = fix.alt
        }
        guard let vg = v else {
            if !useIMU || lastMotionT == nil { emitGPSSample(fix, speed: currentGPSSpeed(at: fix.t)) }
            return
        }

        if useIMU, lastMotionT != nil {
            if forward != nil {
                let e = vg - speedInHistory(at: fix.t)
                let dtFix = prevSpeedFix.map { fix.t - $0.t } ?? 1
                vF = max(0, vF + 0.6 * e)
                bias = min(1.5, max(-1.5, bias - 0.12 * e / max(dtFix, 0.3)))
                if abs(e) > 4 {
                    badInnovations += 1
                    if badInnovations >= 3 {
                        resetCalibration()
                        state = .calibrating(0)
                    }
                } else {
                    badInnovations = 0
                }
            }

            // Longitudinal calibration row: Δv over the fix interval vs ∫h dt.
            if let prev = prevSpeedFix, gRef != nil {
                let dt = fix.t - prev.t
                if dt > 0.3, dt < 3, max(prev.v, vg) > 1.5,
                   let first = history.first, first.t <= prev.t + 0.05 {
                    let H = integrateH(from: prev.t, to: fix.t)
                    let dv = vg - prev.v
                    addRow(H, dv, weight: 1)
                    longExcitation += abs(dv)
                    solveCalibration()
                }
            }
        }

        prevSpeedFix = (fix.t, vg)
        gpsSpeed = (fix.t, vg)

        if !useIMU || lastMotionT == nil {
            emitGPSSample(fix, speed: vg)
            liveSpeed = vg
            topSpeed = max(topSpeed, vg)
            if fixes.count >= 2 {
                let a = fixes[fixes.count - 2]
                liveDistance += vg > 0.5 ? Geo.haversine(a.lat, a.lon, fix.lat, fix.lon) : 0
            }
        }
    }

    // MARK: - Calibration

    private func setBasis(_ gUnit: SIMD3<Double>) {
        gRef = gUnit
        gLP = gUnit
        let up = -gUnit
        let candidates = [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)]
        let helper = candidates.min { abs(simd_dot($0, up)) < abs(simd_dot($1, up)) }!
        e1 = simd_normalize(helper - simd_dot(helper, up) * up)
        e2 = simd_cross(up, e1)
    }

    private func resetCalibration() {
        if let f = forward { segmentForward[segment] = f }
        segment += 1
        normal = simd_double2x2(0)
        rhs = .zero
        longExcitation = 0
        latExcitation = 0
        forward = nil
        bias = 0
        badInnovations = 0
        history.removeAll()
        latWinH = .zero
        latWinTarget = 0
        latWinDt = 0
    }

    private func addRow(_ q: SIMD2<Double>, _ target: Double, weight: Double) {
        guard q.x.isFinite, q.y.isFinite, target.isFinite else { return }
        normal = normal + simd_double2x2(rows: [
            SIMD2(q.x * q.x, q.x * q.y),
            SIMD2(q.y * q.x, q.y * q.y),
        ]) * weight
        rhs += q * target * weight
    }

    private func solveCalibration() {
        let excitation = longExcitation + latExcitation
        if forward == nil {
            state = .calibrating(min(0.99, excitation / Self.calibrationTarget))
        }
        guard excitation >= Self.calibrationTarget, longExcitation >= 3 else { return }

        let trace = normal[0][0] + normal[1][1]
        guard trace > 0 else { return }
        let lambda = 0.02 * trace
        let m = normal + simd_double2x2(diagonal: SIMD2(lambda, lambda))
        guard abs(m.determinant) > 1e-12 else { return }
        let f = m.inverse * rhs
        let n = simd_length(f)
        guard n > 0.7, n < 1.3 else { return }

        let wasNil = forward == nil
        let fu = f / n
        forward = fu
        if wasNil {
            // Start from the last GPS speed plus the IMU-integrated change since that fix.
            if let g = gpsSpeed {
                var dv = 0.0
                for e in history where e.t > g.t { dv += simd_dot(e.h, fu) * e.dt }
                vF = max(0, g.v + dv)
            }
            bias = 0
            longLP = 0
        }
        state = .fused
    }

    // MARK: - Helpers

    private func currentGPSSpeed(at t: Double) -> Double {
        gpsSpeed?.v ?? 0
    }

    private func speedInHistory(at t: Double) -> Double {
        guard let idx = history.lastIndex(where: { $0.t <= t }) else { return vF }
        return history[idx].v
    }

    private func integrateH(from t0: Double, to t1: Double) -> SIMD2<Double> {
        var s = SIMD2<Double>(0, 0)
        for e in history where e.t > t0 && e.t <= t1 {
            s += e.h * e.dt
        }
        return s
    }

    private func emitSample(t: Double, fused: Bool) {
        guard let fix = fixes.last else { return }
        samples.append(SpeedSample(
            t: t, lat: fix.lat, lon: fix.lon, alt: fix.alt,
            speed: vF,
            longAccel: fused ? longLP : 0,
            latAccel: latLP,
            heading: fix.hasCourse ? fix.course : 0,
            distance: liveDistance,
            hAcc: fix.hAcc,
            fused: fused
        ))
    }

    private func emitGPSSample(_ fix: GPSFix, speed: Double) {
        samples.append(SpeedSample(
            t: fix.t, lat: fix.lat, lon: fix.lon, alt: fix.alt,
            speed: speed, longAccel: 0, latAccel: 0,
            heading: fix.hasCourse ? fix.course : 0,
            distance: liveDistance, hAcc: fix.hAcc, fused: false
        ))
    }

    // MARK: - Post-processing

    /// Fills in GPS-only stretches, interpolates positions between fixes (weighted by
    /// distance travelled), recomputes distance and derives any missing accelerations.
    func finalize() -> [SpeedSample] {
        if let f = forward { segmentForward[segment] = f }
        var s = samples
        if useIMU, !segmentForward.isEmpty { refineOffline(&s) }
        return RunPostProcessor.process(samples: s, fixes: fixes, baro: baro)
    }

    /// Whole-run re-fusion with the final forward axis of each calibration segment:
    /// v(t) = ∫IMU + e(t), where e is the GPS − IMU difference at each fix, interpolated
    /// linearly between fixes. Keeps the IMU's 10 Hz shape (launches!) and GPS's level.
    private func refineOffline(_ s: inout [SpeedSample]) {
        for i in s.indices { s[i].fused = false }
        var gT: [Double] = [], gV: [Double] = []
        for (i, f) in fixes.enumerated() {
            if f.hasSpeed {
                gT.append(f.t); gV.append(f.speed)
            } else if i > 0 {
                let p = fixes[i - 1], dt = f.t - p.t
                if dt > 0.2 { gT.append(f.t); gV.append(Geo.haversine(p.lat, p.lon, f.lat, f.lon) / dt) }
            }
        }
        guard gT.count >= 2, !records.isEmpty else { return }
        let interp = RunPostProcessor.interp

        var start = 0
        while start < records.count {
            let seg = records[start].seg
            var end = start
            while end + 1 < records.count && records[end + 1].seg == seg { end += 1 }
            let next = end + 1
            defer { start = next }
            guard let f = segmentForward[Int(seg)] else { continue }

            let n = end - start + 1
            var tr = [Double](repeating: 0, count: n)
            var vi = [Double](repeating: 0, count: n)
            var ps = [Double](repeating: 0, count: n)
            var accV = 0.0, accP = 0.0
            for k in 0..<n {
                let r = records[start + k]
                let dt = Double(r.dt)
                accV += (Double(r.hx) * f.x + Double(r.hy) * f.y) * dt
                accP += Double(r.yaw) * dt
                tr[k] = r.t; vi[k] = accV; ps[k] = accP
            }
            let t0 = tr[0], t1 = tr[n - 1]

            var eT: [Double] = [], eV: [Double] = [], eG: [Double] = []
            for j in gT.indices where gT[j] >= t0 && gT[j] <= t1 {
                eT.append(gT[j]); eG.append(gV[j]); eV.append(gV[j] - interp(tr, vi, gT[j]))
            }
            guard eT.count >= 2 else { continue }

            // A wrong forward axis shows up as a large, persistent GPS correction slope.
            var slopes: [Double] = []
            for j in 1..<eT.count where eT[j] > eT[j - 1] {
                slopes.append(abs((eV[j] - eV[j - 1]) / (eT[j] - eT[j - 1])))
            }
            slopes.sort()
            if !slopes.isEmpty && slopes[slopes.count / 2] > 1.0 { continue }

            let lo = max(t0, eT[0]) - 0.5, hi = min(t1, eT[eT.count - 1]) + 0.5
            let w = 0.1
            for i in s.indices where s[i].t >= lo && s[i].t <= hi {
                let t = s[i].t
                var j = 0, k = eT.count - 1
                if t <= eT[0] { k = 0 } else if t >= eT[eT.count - 1] { j = eT.count - 1 } else {
                    while k - j > 1 { let m = (j + k) / 2; if eT[m] <= t { j = m } else { k = m } }
                }
                let slope = (k > j) ? (eV[k] - eV[j]) / (eT[k] - eT[j]) : 0
                let stationary = eG[j] < 0.25 && eG[k] < 0.25
                var v = interp(tr, vi, t) + interp(eT, eV, t)
                var a = (interp(tr, vi, t + w) - interp(tr, vi, t - w)) / (2 * w) + slope
                if stationary { v = 0; a = 0 }
                v = max(0, v)
                let yaw = (interp(tr, ps, t + w) - interp(tr, ps, t - w)) / (2 * w)
                s[i].speed = v
                s[i].longAccel = a
                s[i].latAccel = v * yaw
                s[i].fused = true
            }
        }
    }
}

enum RunPostProcessor {
    static func process(samples input: [SpeedSample], fixes: [GPSFix], baro: [BaroSample] = []) -> [SpeedSample] {
        var s = input.sorted { $0.t < $1.t }
        guard !s.isEmpty, !fixes.isEmpty else { return s }

        // Speed at fixes (Doppler if valid, else from positions).
        var speedT: [Double] = []
        var speedV: [Double] = []
        for (i, f) in fixes.enumerated() {
            if f.hasSpeed {
                speedT.append(f.t)
                speedV.append(f.speed)
            } else if i > 0 {
                let p = fixes[i - 1]
                let dt = f.t - p.t
                if dt > 0.2 {
                    speedT.append(f.t)
                    speedV.append(Geo.haversine(p.lat, p.lon, f.lat, f.lon) / dt)
                }
            }
        }

        let anyFused = s.contains { $0.fused }

        // 1. Speeds for non-fused samples.
        if !speedT.isEmpty {
            for i in s.indices where !s[i].fused {
                s[i].speed = interp(speedT, speedV, s[i].t)
            }
        }

        // 2. Distance by trapezoid integration of speed.
        var dist = 0.0
        s[0].distance = 0
        for i in 1..<s.count {
            let dt = s[i].t - s[i - 1].t
            if dt > 0 && dt < 5 {
                dist += 0.5 * (s[i].speed + s[i - 1].speed) * dt
            }
            s[i].distance = dist
        }

        // 3. Positions: between fixes, place each sample by fraction of distance travelled.
        let ts = s.map(\.t)
        let ds = s.map(\.distance)
        let fixD = fixes.map { interp(ts, ds, $0.t) }
        var k = 0
        for i in s.indices {
            let t = s[i].t
            while k + 1 < fixes.count && fixes[k + 1].t < t { k += 1 }
            let a = fixes[k]
            if t <= fixes[0].t {
                set(&s[i], from: fixes[0])
            } else if k + 1 >= fixes.count {
                set(&s[i], from: fixes[fixes.count - 1])
            } else {
                let b = fixes[k + 1]
                let span = fixD[k + 1] - fixD[k]
                var frac: Double
                if span > 0.05 {
                    frac = (s[i].distance - fixD[k]) / span
                } else {
                    frac = (t - a.t) / max(b.t - a.t, 1e-6)
                }
                frac = min(max(frac, 0), 1)
                s[i].lat = a.lat + (b.lat - a.lat) * frac
                s[i].lon = a.lon + (b.lon - a.lon) * frac
                s[i].alt = a.alt + (b.alt - a.alt) * frac
                s[i].hAcc = frac < 0.5 ? a.hAcc : b.hAcc
            }
        }

        // 4. Heading: course when moving, else bearing of travel; held when stopped.
        var courseT: [Double] = []
        var courseD: [Double] = []
        var unwrapped = 0.0
        var prevCourse: Double?
        for (i, f) in fixes.enumerated() {
            var c: Double?
            if f.hasCourse && (f.speed < 0 || f.speed > 1) {
                c = f.course
            } else if i > 0 {
                let p = fixes[i - 1]
                if Geo.haversine(p.lat, p.lon, f.lat, f.lon) > 2 {
                    c = Geo.bearing(p.lat, p.lon, f.lat, f.lon)
                }
            }
            guard let cc = c else { continue }
            if let pc = prevCourse {
                unwrapped += Geo.angleDiff(pc, cc)
            } else {
                unwrapped = cc
            }
            prevCourse = cc
            courseT.append(f.t)
            courseD.append(unwrapped)
        }
        if !courseT.isEmpty {
            for i in s.indices {
                s[i].heading = Geo.normDeg(interp(courseT, courseD, s[i].t))
            }
        }

        // 5. Accelerations derived from GPS where IMU data wasn't fused.
        if speedT.count >= 3 {
            var accT: [Double] = []
            var accV: [Double] = []
            for i in 1..<(speedT.count - 1) {
                let dt = speedT[i + 1] - speedT[i - 1]
                if dt > 0.2 && dt < 6 {
                    accT.append(speedT[i])
                    accV.append((speedV[i + 1] - speedV[i - 1]) / dt)
                }
            }
            if !accT.isEmpty {
                for i in s.indices where !s[i].fused {
                    s[i].longAccel = interp(accT, accV, s[i].t)
                }
            }
        }
        if !anyFused && courseT.count >= 3 {
            var latT: [Double] = []
            var latV: [Double] = []
            for i in 1..<(courseT.count - 1) {
                let dt = courseT[i + 1] - courseT[i - 1]
                if dt > 0.2 && dt < 6 {
                    let yawRate = -(courseD[i + 1] - courseD[i - 1]) * .pi / 180 / dt
                    let v = interp(speedT, speedV, courseT[i])
                    latT.append(courseT[i])
                    latV.append(v * yawRate)
                }
            }
            if !latT.isEmpty {
                for i in s.indices {
                    s[i].latAccel = interp(latT, latV, s[i].t)
                }
            }
        }

        applyElevation(&s, fixes: fixes, baro: baro)
        return s
    }

    /// Elevation: barometer (smooth, ~0.1 m resolution) anchored to the median GPS altitude;
    /// without a barometer, GPS altitude smoothed over ±2 fixes.
    static func applyElevation(_ s: inout [SpeedSample], fixes: [GPSFix], baro: [BaroSample]) {
        guard !s.isEmpty, !fixes.isEmpty else { return }
        if baro.count >= 2 {
            let bt = baro.map(\.t), br = baro.map(\.rel)
            let good = fixes.filter { $0.vAcc >= 0 && $0.vAcc < 30 }
            let use = good.isEmpty ? fixes : good
            var offsets = use.map { $0.alt - interp(bt, br, $0.t) }.sorted()
            if offsets.isEmpty { offsets = [0] }
            let offset = offsets[offsets.count / 2]
            for i in s.indices { s[i].alt = offset + interp(bt, br, s[i].t) }
        } else {
            let ft = fixes.map(\.t)
            let fa = fixes.map(\.alt)
            let smooth = RunAnalysis.movingAverage(fa, 5)
            for i in s.indices { s[i].alt = interp(ft, smooth, s[i].t) }
        }
    }

    private static func set(_ s: inout SpeedSample, from f: GPSFix) {
        s.lat = f.lat
        s.lon = f.lon
        s.alt = f.alt
        s.hAcc = f.hAcc
    }

    /// Linear interpolation on sorted x, clamped at the ends.
    static func interp(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = xs[hi] - xs[lo]
        guard span > 0 else { return ys[lo] }
        return ys[lo] + (ys[hi] - ys[lo]) * (x - xs[lo]) / span
    }
}
