import Foundation
import simd

/// 2D vector in metres. Layout frame: x = forward (driving direction), y = left.
typealias Vec2 = SIMD2<Double>

@inline(__always) func dot2(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) func cross2(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }
@inline(__always) func norm2(_ a: Vec2) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) func dist2(_ a: Vec2, _ b: Vec2) -> Double { norm2(a - b) }

func rotate2(_ v: Vec2, _ theta: Double) -> Vec2 {
    let c = cos(theta), s = sin(theta)
    return Vec2(c * v.x - s * v.y, s * v.x + c * v.y)
}

extension SIMD3 where Scalar == Float {
    /// Horizontal position in a right-handed ground frame seen from above:
    /// x = ARKit world X, y = ARKit world -Z. Using -Z keeps the mapping from the
    /// layout frame (forward, left) a pure rotation instead of a mirror.
    var ground2D: Vec2 { Vec2(Double(x), Double(-z)) }
}

/// Inverse of `ground2D`, at a given world height.
func worldPoint(_ p: Vec2, height: Float) -> SIMD3<Float> {
    SIMD3<Float>(Float(p.x), height, Float(-p.y))
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }

    var position: SIMD3<Float> { SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z) }
}

/// Rotation + translation in the ground plane (no scale: a tape-measured layout is metric).
struct Transform2D: Equatable {
    var theta: Double
    var t: Vec2

    func apply(_ p: Vec2) -> Vec2 { rotate2(p, theta) + t }
    func inverse(_ q: Vec2) -> Vec2 { rotate2(q - t, -theta) }
    func inverseVector(_ v: Vec2) -> Vec2 { rotate2(v, -theta) }
}

struct FitPair {
    var layout: Vec2
    var world: Vec2
    var weight: Double
}

enum RigidFit {
    /// Weighted least-squares rigid fit (2D Kabsch) mapping layout points onto measured world points.
    static func fit(_ pairs: [FitPair]) -> Transform2D? {
        let total = pairs.reduce(0.0) { $0 + $1.weight }
        guard pairs.count >= 2, total > 0 else { return nil }

        var pc = Vec2.zero
        var qc = Vec2.zero
        for p in pairs {
            pc += p.weight * p.layout
            qc += p.weight * p.world
        }
        pc /= total
        qc /= total

        var sCos = 0.0
        var sSin = 0.0
        for p in pairs {
            let a = p.layout - pc
            let b = p.world - qc
            sCos += p.weight * dot2(a, b)
            sSin += p.weight * cross2(a, b)
        }
        guard abs(sCos) + abs(sSin) > 1e-9 else { return nil }

        let theta = atan2(sSin, sCos)
        return Transform2D(theta: theta, t: qc - rotate2(pc, theta))
    }
}
