import Foundation
import RealityKit
import UIKit

@MainActor
enum EntityFactory {
    static func material(_ color: UIColor, opacity: Float = 1) -> UnlitMaterial {
        var m = UnlitMaterial(color: color)
        if opacity < 1 {
            m.blending = .transparent(opacity: .init(scale: opacity))
        }
        return m
    }

    static func dot(color: UIColor, radius: Float) -> ModelEntity {
        ModelEntity(mesh: .generateSphere(radius: radius), materials: [material(color)])
    }

    /// Reference point marker: a ball on a short pole.
    static func refMarker(color: UIColor) -> Entity {
        let root = Entity()
        let pole = ModelEntity(mesh: .generateCylinder(height: 0.8, radius: 0.008), materials: [material(color, opacity: 0.85)])
        pole.position.y = 0.4
        let ball = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [material(color)])
        ball.position.y = 0.82
        let foot = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.06), materials: [material(color, opacity: 0.7)])
        foot.position.y = 0.002
        root.addChild(pole)
        root.addChild(ball)
        root.addChild(foot)
        return root
    }

    // MARK: Cone markers for every cone in the layout

    private static let pendingDisc = MeshResource.generateCylinder(height: 0.008, radius: 0.09)
    private static let acceptedDisc = MeshResource.generateCylinder(height: 0.012, radius: 0.07)
    private static let placedCone = MeshResource.generateCone(height: 0.16, radius: 0.07)

    static func markerModel(key: String, color: ConeColor) -> ModelComponent {
        if key == "flag" {
            return ModelComponent(mesh: placedCone, materials: [material(.systemRed)])
        }
        if key.hasPrefix("placed") {
            return ModelComponent(mesh: placedCone, materials: [material(color.uiColor)])
        }
        if key.hasPrefix("accepted") {
            return ModelComponent(mesh: acceptedDisc, materials: [material(color.uiColor)])
        }
        if key.hasPrefix("skipped") {
            return ModelComponent(mesh: pendingDisc, materials: [material(.systemGray, opacity: 0.6)])
        }
        return ModelComponent(mesh: pendingDisc, materials: [material(color.uiColor, opacity: 0.5)])
    }

    static func markerYOffset(key: String) -> Float {
        if key == "flag" || key.hasPrefix("placed") { return 0.08 }
        return 0.006
    }
}

/// The highlighted "put the cone here" target: a translucent full-size cone,
/// a beam so you can spot it from far away, a tolerance ring and dots at the
/// exact base centre and tip.
@MainActor
final class GhostEntity {
    let root = Entity()

    init(color: ConeColor, tolerance: Float) {
        let h = color.height
        let r = color.baseRadius

        let cone = ModelEntity(mesh: .generateCone(height: h, radius: r),
                               materials: [EntityFactory.material(color.uiColor, opacity: 0.55)])
        cone.position.y = h / 2
        root.addChild(cone)

        let beam = ModelEntity(mesh: .generateCylinder(height: 1.6, radius: 0.012),
                               materials: [EntityFactory.material(color.uiColor, opacity: 0.85)])
        beam.position.y = h + 0.85
        root.addChild(beam)

        let topBall = ModelEntity(mesh: .generateSphere(radius: 0.07),
                                  materials: [EntityFactory.material(color.uiColor)])
        topBall.position.y = h + 1.7
        root.addChild(topBall)

        let ring = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: max(tolerance, 0.01) + 0.004),
                               materials: [EntityFactory.material(.systemGreen, opacity: 0.45)])
        ring.position.y = 0.002
        root.addChild(ring)

        let footprint = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: r),
                                    materials: [EntityFactory.material(.white, opacity: 0.25)])
        footprint.position.y = 0.001
        root.addChild(footprint)

        let centre = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [EntityFactory.material(.white)])
        centre.position.y = 0.008
        root.addChild(centre)

        let tip = ModelEntity(mesh: .generateSphere(radius: 0.014), materials: [EntityFactory.material(.white)])
        tip.position.y = h
        root.addChild(tip)
    }
}
