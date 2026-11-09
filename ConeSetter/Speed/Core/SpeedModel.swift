import Foundation

// Pure-Foundation model shared by the app and the CI test harness.

/// One processed data point (10 Hz with IMU fusion, otherwise one per GPS fix).
struct SpeedSample: Codable, Equatable {
    /// Seconds since the run started.
    var t: Double
    var lat: Double
    var lon: Double
    var alt: Double
    /// m/s
    var speed: Double
    /// Longitudinal acceleration, m/s², positive = speeding up.
    var longAccel: Double
    /// Lateral acceleration, m/s², positive = to the left.
    var latAccel: Double
    /// Course over ground, degrees from true north (0–360).
    var heading: Double
    /// Distance travelled since the start, metres.
    var distance: Double
    /// Horizontal accuracy of the nearest GPS fix, metres.
    var hAcc: Double
    /// true when speed/acceleration come from GPS + IMU fusion.
    var fused: Bool
}

/// Raw fix as delivered by Core Location.
struct GPSFix: Codable, Equatable {
    var t: Double
    var lat: Double
    var lon: Double
    var alt: Double
    var hAcc: Double
    var vAcc: Double
    /// m/s, -1 when invalid
    var speed: Double
    /// m/s, -1 when invalid
    var speedAcc: Double
    /// degrees, -1 when invalid
    var course: Double
    var courseAcc: Double

    var hasSpeed: Bool { speed >= 0 && speedAcc >= 0 && speedAcc < 3 }
    var hasCourse: Bool { course >= 0 && courseAcc >= 0 && courseAcc < 45 }
}

/// Barometric relative altitude (Core Motion altimeter), metres since recording started.
struct BaroSample: Codable, Equatable {
    var t: Double
    var rel: Double
}

struct SpeedRun: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var startDate: Date
    var samples: [SpeedSample]
    var fixes: [GPSFix]
    var imuUsed: Bool
    var notes: String = ""
    var baro: [BaroSample]? = nil

    var hasBarometer: Bool { (baro?.count ?? 0) > 1 }

    var duration: Double { max(samples.last?.t ?? 0, fixes.last?.t ?? 0) }
}

enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
    case kmh, mph, ms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .mph: return "mph"
        case .ms: return "m/s"
        }
    }

    var factor: Double {
        switch self {
        case .kmh: return 3.6
        case .mph: return 2.2369362921
        case .ms: return 1
        }
    }

    func convert(_ metresPerSecond: Double) -> Double { metresPerSecond * factor }
}

// MARK: - Geodesy

enum Geo {
    static let earthRadius = 6_371_008.8
    static let g = 9.80665

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Bearing from point 1 to point 2, degrees from true north.
    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normDeg(atan2(y, x) * 180 / .pi)
    }

    static func normDeg(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Signed smallest difference b - a in degrees (-180, 180].
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Local east/north metres around an origin (equirectangular, fine for a few km).
    struct LocalFrame {
        let lat0: Double
        let lon0: Double
        let mPerDegLat: Double
        let mPerDegLon: Double

        init(lat0: Double, lon0: Double) {
            self.lat0 = lat0
            self.lon0 = lon0
            mPerDegLat = Geo.earthRadius * .pi / 180
            mPerDegLon = mPerDegLat * cos(lat0 * .pi / 180)
        }

        func xy(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
            ((lon - lon0) * mPerDegLon, (lat - lat0) * mPerDegLat)
        }

        func latLon(x: Double, y: Double) -> (lat: Double, lon: Double) {
            (lat0 + y / mPerDegLat, lon0 + x / max(mPerDegLon, 1e-9))
        }
    }
}

// MARK: - Heat colours

enum HeatColor {
    /// 0 → blue, 0.25 → cyan, 0.5 → green, 0.75 → yellow, 1 → red.
    static func rgb(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let x = min(max(t.isFinite ? t : 0, 0), 1)
        let hue = (1 - x) * 240.0 / 360.0
        return hsv(h: hue, s: 0.92, v: 1.0)
    }

    static func hex(_ t: Double) -> String {
        let c = rgb(t)
        return String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    static func hsv(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
