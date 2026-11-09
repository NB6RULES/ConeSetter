import Foundation

struct RunStats: Equatable {
    var duration: Double = 0
    var distance: Double = 0
    var topSpeed: Double = 0
    var topSpeedTime: Double = 0
    var avgSpeed: Double = 0
    var movingAvgSpeed: Double = 0
    var movingTime: Double = 0
    var maxAccel: Double = 0
    var maxBraking: Double = 0
    var maxLateral: Double = 0
    var zeroTo100: Double?
    var best75m: Double?
    var best75mTrapSpeed: Double?
    var sampleCount = 0
    var fixCount = 0
    var fusedFraction: Double = 0
    var sampleRate: Double = 0
}

struct SpeedBand {
    var index: Int
    var lower: Double
    var upper: Double
    /// 0…1 position used for the colour.
    var heat: Double
}

enum RunAnalysis {
    static let movingThreshold = 1.0
    static let launchThreshold = 0.5

    static func stats(_ run: SpeedRun) -> RunStats {
        var r = RunStats()
        let s = run.samples
        r.sampleCount = s.count
        r.fixCount = run.fixes.count
        guard let first = s.first, let last = s.last else { return r }

        r.duration = max(last.t - first.t, 0)
        r.distance = last.distance - first.distance
        if r.duration > 0 {
            r.avgSpeed = r.distance / r.duration
            r.sampleRate = Double(s.count - 1) / r.duration
        }
        r.fusedFraction = Double(s.filter(\.fused).count) / Double(s.count)

        var movingDist = 0.0
        for i in s.indices {
            if s[i].speed > r.topSpeed {
                r.topSpeed = s[i].speed
                r.topSpeedTime = s[i].t
            }
            if i > 0 {
                let dt = s[i].t - s[i - 1].t
                if dt > 0, dt < 5, max(s[i].speed, s[i - 1].speed) >= movingThreshold {
                    r.movingTime += dt
                    movingDist += s[i].distance - s[i - 1].distance
                }
            }
        }
        if r.movingTime > 0 { r.movingAvgSpeed = movingDist / r.movingTime }

        // Peak accelerations on a lightly smoothed trace (0.3 s window at 10 Hz).
        let window = r.sampleRate > 5 ? 3 : 1
        let longS = movingAverage(s.map(\.longAccel), window)
        let latS = movingAverage(s.map(\.latAccel), window)
        r.maxAccel = max(0, longS.max() ?? 0)
        r.maxBraking = max(0, -(longS.min() ?? 0))
        r.maxLateral = latS.map(abs).max() ?? 0

        // Launch-based times: 0–100 km/h and 75 m (FS acceleration event length).
        for launch in launches(s) {
            if let t100 = timeToSpeed(s, from: launch, speed: 100 / 3.6) {
                r.zeroTo100 = min(r.zeroTo100 ?? .infinity, t100)
            }
            if let (t75, v75) = timeToDistance(s, from: launch, metres: 75) {
                if t75 < (r.best75m ?? .infinity) {
                    r.best75m = t75
                    r.best75mTrapSpeed = v75
                }
            }
        }
        return r
    }

    /// Times at which the car pulls away from (near) standstill.
    static func launches(_ s: [SpeedSample]) -> [Double] {
        var out: [Double] = []
        guard s.count > 1 else { return out }
        for i in 1..<s.count where s[i - 1].speed < launchThreshold && s[i].speed >= launchThreshold {
            let a = s[i - 1], b = s[i]
            let f = (launchThreshold - a.speed) / max(b.speed - a.speed, 1e-6)
            out.append(a.t + (b.t - a.t) * f)
        }
        return out
    }

    private static func timeToSpeed(_ s: [SpeedSample], from t0: Double, speed target: Double) -> Double? {
        guard let start = s.firstIndex(where: { $0.t >= t0 }) else { return nil }
        for i in max(start, 1)..<s.count {
            if s[i].t - t0 > 30 || s[i].speed < launchThreshold * 0.5 { return nil }
            if s[i].speed >= target {
                let a = s[i - 1], b = s[i]
                let f = (target - a.speed) / max(b.speed - a.speed, 1e-6)
                return a.t + (b.t - a.t) * min(max(f, 0), 1) - t0
            }
        }
        return nil
    }

    private static func timeToDistance(_ s: [SpeedSample], from t0: Double, metres: Double) -> (Double, Double)? {
        guard let start = s.firstIndex(where: { $0.t >= t0 }), start > 0 else { return nil }
        let d0 = RunPostProcessor.interp(s.map(\.t), s.map(\.distance), t0)
        for i in start..<s.count {
            if s[i].t - t0 > 30 || s[i].speed < launchThreshold * 0.5 { return nil }
            if s[i].distance - d0 >= metres {
                let a = s[i - 1], b = s[i]
                let f = (d0 + metres - a.distance) / max(b.distance - a.distance, 1e-6)
                let ff = min(max(f, 0), 1)
                return (a.t + (b.t - a.t) * ff - t0, a.speed + (b.speed - a.speed) * ff)
            }
        }
        return nil
    }

    static func movingAverage(_ x: [Double], _ w: Int) -> [Double] {
        guard w > 1, x.count > w else { return x }
        var out = [Double](repeating: 0, count: x.count)
        let half = w / 2
        var sum = 0.0
        var lo = 0, hi = -1
        for i in x.indices {
            let a = max(0, i - half), b = min(x.count - 1, i + half)
            while hi < b { hi += 1; sum += x[hi] }
            while lo < a { sum -= x[lo]; lo += 1 }
            out[i] = sum / Double(hi - lo + 1)
        }
        return out
    }

    /// Evenly strided indices, always keeping the first and last point.
    static func strideIndices(count: Int, max n: Int) -> [Int] {
        guard count > n, n > 1 else { return Array(0..<count) }
        let step = Double(count - 1) / Double(n - 1)
        var out: [Int] = []
        var last = -1
        for k in 0..<n {
            let i = Int((Double(k) * step).rounded())
            if i != last { out.append(i); last = i }
        }
        return out
    }

    static func bands(top: Double, count: Int = 6) -> [SpeedBand] {
        let topV = max(top, 1)
        return (0..<count).map { i in
            SpeedBand(index: i,
                      lower: topV * Double(i) / Double(count),
                      upper: topV * Double(i + 1) / Double(count),
                      heat: count > 1 ? Double(i) / Double(count - 1) : 1)
        }
    }

    static func bandIndex(speed: Double, top: Double, count: Int = 6) -> Int {
        let topV = max(top, 1)
        return min(count - 1, max(0, Int(speed / topV * Double(count))))
    }

    static func formatDuration(_ s: Double) -> String {
        let total = max(0, s)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let sec = total - Double(h * 3600 + m * 60)
        if h > 0 { return String(format: "%d:%02d:%04.1f", h, m, sec) }
        return String(format: "%d:%04.1f", m, sec)
    }
}
