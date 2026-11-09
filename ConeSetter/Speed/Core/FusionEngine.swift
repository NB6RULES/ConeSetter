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
    private(set) var state: IMUState

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

    static let calibrationTarget = 6.0
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
        guard excitation >= Self.calibrationTarget, longExcitation >= 2 else { return }

        let trace = normal[0][0] + normal[1][1]
        guard trace > 0 else { return }
        let lambda = 0.02 * trace
        let m = normal + simd_double2x2(diagonal: SIMD2(lambda, lambda))
        guard abs(m.determinant) > 1e-12 else { return }
        let f = m.inverse * rhs
        let n = simd_length(f)
        guard n > 0.7, n < 1.3 else { return }

        let wasNil = forward == nil
        forward = f / n
        if wasNil {
            vF = gpsSpeed?.v ?? vF
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
        RunPostProcessor.process(samples: samples, fixes: fixes)
    }
}

enum RunPostProcessor {
    static func process(samples input: [SpeedSample], fixes: [GPSFix]) -> [SpeedSample] {
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
        return s
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
