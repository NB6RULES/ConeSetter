import Foundation
import SwiftUI
import UIKit

enum ConeColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case blue, yellow, orange, bigOrange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .orange: return "Small orange"
        case .bigOrange: return "Big orange"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .blue: return UIColor(red: 0.12, green: 0.45, blue: 1.00, alpha: 1)
        case .yellow: return UIColor(red: 1.00, green: 0.85, blue: 0.05, alpha: 1)
        case .orange: return UIColor(red: 1.00, green: 0.52, blue: 0.10, alpha: 1)
        case .bigOrange: return UIColor(red: 1.00, green: 0.36, blue: 0.00, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// FS cones: small 228 x 228 x 325 mm, big 285 x 285 x 505 mm.
    var height: Float { self == .bigOrange ? 0.505 : 0.325 }
    var baseRadius: Float { self == .bigOrange ? 0.1425 : 0.114 }

    static func parse(_ raw: String) -> ConeColor? {
        let t = raw.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch t {
        case "blue", "b", "left", "bluecone": return .blue
        case "yellow", "y", "right", "yellowcone": return .yellow
        case "orange", "o", "smallorange", "orangesmall", "orangecone": return .orange
        case "bigorange", "orangebig", "largeorange", "big", "bo", "bigorangecone": return .bigOrange
        default: return nil
        }
    }
}

enum LayoutKind: String, Codable, Hashable {
    case skidpad, acceleration, custom
}

struct PlannedCone: Identifiable, Codable, Hashable {
    let id: Int
    var x: Double
    var y: Double
    var color: ConeColor
    var group: String

    var pos: Vec2 { Vec2(x, y) }
}

struct ConeLayout: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: LayoutKind
    var cones: [PlannedCone]
    /// Two taped reference points, in layout coordinates, used to align the layout to the ground.
    var refA: Vec2
    var refB: Vec2
    var refAHint: String
    var refBHint: String

    var baselineLength: Double { dist2(refA, refB) }

    struct ColorCount: Identifiable {
        let color: ConeColor
        let count: Int
        var id: String { color.rawValue }
    }

    var colorCounts: [ColorCount] {
        ConeColor.allCases.compactMap { c in
            let n = cones.filter { $0.color == c }.count
            return n > 0 ? ColorCount(color: c, count: n) : nil
        }
    }

    var extent: (width: Double, depth: Double) {
        let xs = cones.map(\.x) + [refA.x, refB.x]
        let ys = cones.map(\.y) + [refA.y, refB.y]
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    func csv() -> String {
        var lines = ["# Cone Setter layout: \(name)", "# x = forward (m), y = left (m)", "colour,x,y"]
        lines.append(String(format: "refA,%.3f,%.3f", refA.x, refA.y))
        lines.append(String(format: "refB,%.3f,%.3f", refB.x, refB.y))
        for c in cones {
            lines.append(c.color.rawValue + "," + String(format: "%.3f,%.3f", c.x, c.y))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Parameters

struct SkidpadParams: Codable, Equatable {
    var innerDiameter: Double = 15.25
    var outerDiameter: Double = 21.25
    var centreDistance: Double = 18.25
    var innerCount: Int = 16
    var outerCount: Int = 13
    var entryLength: Double = 15
    var exitLength: Double = 25
    var laneSpacing: Double = 5
    var timingCones: Bool = true
}

struct AccelParams: Codable, Equatable {
    var length: Double = 75
    var width: Double = 3
    var spacing: Double = 5
    var stopLength: Double = 100
    var stopSpacing: Double = 5
    var timingCones: Bool = true
}

// MARK: - Generators

enum LayoutFactory {
    /// Figure of eight. Origin = crossing point of the two circles, +x = driving direction
    /// along the entry/exit lane, right circle (driven first, clockwise) at negative y.
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : lo
    }

    static func skidpad(_ input: SkidpadParams) -> ConeLayout {
        var p = input
        p.innerDiameter = clamp(p.innerDiameter, 2, 100)
        p.outerDiameter = clamp(p.outerDiameter, p.innerDiameter + 1, 120)
        p.centreDistance = clamp(p.centreDistance, p.innerDiameter + 0.5, 150)
        p.entryLength = clamp(p.entryLength, 0, 200)
        p.exitLength = clamp(p.exitLength, 0, 200)
        p.laneSpacing = clamp(p.laneSpacing, 1, 50)
        p.innerCount = min(max(p.innerCount, 4), 60)
        p.outerCount = min(max(p.outerCount, 4), 60)
        var cones: [PlannedCone] = []
        func add(_ x: Double, _ y: Double, _ c: ConeColor, _ g: String) {
            cones.append(PlannedCone(id: cones.count, x: x, y: y, color: c, group: g))
        }

        let rC = p.centreDistance / 2
        let rI = p.innerDiameter / 2
        let rO = p.outerDiameter / 2
        let rightCentre = Vec2(0, -rC)
        let leftCentre = Vec2(0, rC)
        let twoPi = 2 * Double.pi

        // Inner circles: first cone sits at the lane edge facing the crossing.
        let nI = max(p.innerCount, 3)
        for k in 0..<nI {
            let th = Double.pi / 2 + twoPi * Double(k) / Double(nI)
            add(rightCentre.x + rI * cos(th), rightCentre.y + rI * sin(th), .yellow, "Right circle · inner")
        }
        for k in 0..<nI {
            let th = -Double.pi / 2 + twoPi * Double(k) / Double(nI)
            add(leftCentre.x + rI * cos(th), leftCentre.y + rI * sin(th), .blue, "Left circle · inner")
        }

        // Outer circles: skip the arc that lies inside the other circle (the crossing).
        let nO = max(p.outerCount, 3)
        func outerRing(centre: Vec2, facing: Double, colour: ConeColor, group: String) {
            if rO > rC {
                let alpha = asin(min(1, (rO * rO - rC * rC).squareRoot() / rO))
                let span = twoPi - 2 * alpha
                for j in 0..<nO {
                    let th = facing + alpha + span * Double(j + 1) / Double(nO + 1)
                    add(centre.x + rO * cos(th), centre.y + rO * sin(th), colour, group)
                }
            } else {
                for j in 0..<nO {
                    let th = facing + twoPi * (Double(j) + 0.5) / Double(nO)
                    add(centre.x + rO * cos(th), centre.y + rO * sin(th), colour, group)
                }
            }
        }
        outerRing(centre: rightCentre, facing: Double.pi / 2, colour: .blue, group: "Right circle · outer")
        outerRing(centre: leftCentre, facing: -Double.pi / 2, colour: .yellow, group: "Left circle · outer")

        // Entry / exit lanes start where the outer circles clear the lane edge.
        let laneHalf = rC - rI
        let clear = (max(0, rO * rO - rI * rI)).squareRoot() + 0.5
        let spacing = max(p.laneSpacing, 1)
        var d = clear
        while d <= clear + p.entryLength + 1e-6 {
            add(-d, laneHalf, .orange, "Entry lane")
            add(-d, -laneHalf, .orange, "Entry lane")
            d += spacing
        }
        d = clear
        while d <= clear + p.exitLength + 1e-6 {
            add(d, laneHalf, .orange, "Exit lane")
            add(d, -laneHalf, .orange, "Exit lane")
            d += spacing
        }

        if p.timingCones, rI > 1 {
            let yEdge = rC - (rI * rI - 1).squareRoot()
            for x in [-1.0, 1.0] {
                add(x, yEdge, .bigOrange, "Timing line")
                add(x, -yEdge, .bigOrange, "Timing line")
            }
        }

        return ConeLayout(
            name: "Skidpad",
            kind: .skidpad,
            cones: cones,
            refA: rightCentre,
            refB: leftCentre,
            refAHint: "Centre of the RIGHT circle (driven first, clockwise)",
            refBHint: String(format: "Centre of the LEFT circle — %.2f m from A", p.centreDistance)
        )
    }

    /// Straight. Origin = centre of the start line, +x = driving direction.
    static func acceleration(_ input: AccelParams) -> ConeLayout {
        var p = input
        p.length = clamp(p.length, 5, 500)
        p.width = clamp(p.width, 1, 30)
        p.spacing = clamp(p.spacing, 1, 100)
        p.stopLength = clamp(p.stopLength, 0, 500)
        p.stopSpacing = clamp(p.stopSpacing, 1, 100)
        var cones: [PlannedCone] = []
        func add(_ x: Double, _ y: Double, _ c: ConeColor, _ g: String) {
            cones.append(PlannedCone(id: cones.count, x: x, y: y, color: c, group: g))
        }

        let half = p.width / 2
        let L = max(p.length, 5)
        let spacing = max(p.spacing, 1)

        if p.timingCones {
            for x in [-0.5, 0.5] {
                add(x, half, .bigOrange, "Start line")
                add(x, -half, .bigOrange, "Start line")
            }
        }

        let first = p.timingCones ? spacing : 0
        let last = p.timingCones ? L - 1.0 : L + 1e-6
        var x = first
        while x <= last {
            add(x, half, .blue, "Left edge")
            add(x, -half, .yellow, "Right edge")
            x += spacing
        }

        if p.timingCones {
            for x in [L - 0.5, L + 0.5] {
                add(x, half, .bigOrange, "Finish line")
                add(x, -half, .bigOrange, "Finish line")
            }
        }

        let stopSpacing = max(p.stopSpacing, 1)
        var s = L + stopSpacing
        while s <= L + p.stopLength + 1e-6 {
            add(s, half, .orange, "Stop area")
            add(s, -half, .orange, "Stop area")
            s += stopSpacing
        }

        return ConeLayout(
            name: "Acceleration",
            kind: .acceleration,
            cones: cones,
            refA: Vec2(0, 0),
            refB: Vec2(L, 0),
            refAHint: "Centre of the START line",
            refBHint: String(format: "Centre of the FINISH line — %.1f m taped from A", L)
        )
    }
}
