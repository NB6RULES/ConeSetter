import SwiftUI

/// Maps layout metres (x forward, y left) to view points (forward = right, left = up).
struct PreviewMapper {
    let scale: Double
    let minX: Double
    let maxY: Double
    let ox: Double
    let oy: Double

    init(layout: ConeLayout, size: CGSize, padding: Double = 16) {
        let xs = layout.cones.map(\.x) + [layout.refA.x, layout.refB.x]
        let ys = layout.cones.map(\.y) + [layout.refA.y, layout.refB.y]
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let w = max(maxX - minX, 1)
        let h = max(maxY - minY, 1)
        let availW = max(Double(size.width) - 2 * padding, 10)
        let availH = max(Double(size.height) - 2 * padding, 10)
        let s = min(availW / w, availH / h)
        self.scale = s
        self.minX = minX
        self.maxY = maxY
        self.ox = padding + (availW - w * s) / 2
        self.oy = padding + (availH - h * s) / 2
    }

    func point(_ p: Vec2) -> CGPoint {
        CGPoint(x: ox + (p.x - minX) * scale, y: oy + (maxY - p.y) * scale)
    }
}

struct LayoutPreview: View {
    let layout: ConeLayout
    var progress: [Int: ConeProgress] = [:]
    var targetID: Int?
    var live = false
    var camera: Vec2?
    var cameraHeading: Double?
    var onTapCone: ((Int) -> Void)?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let m = PreviewMapper(layout: layout, size: size)
                let r = max(2.0, min(6.0, 0.12 * m.scale))

                for cone in layout.cones {
                    let pt = m.point(cone.pos)
                    let status = progress[cone.id]?.status ?? .pending
                    let rect = CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)
                    let base: Color = status == .skipped ? .gray : cone.color.color
                    let opacity = (live && status == .pending) ? 0.45 : 1.0
                    ctx.fill(Path(ellipseIn: rect), with: .color(base.opacity(opacity)))
                    if status == .placed || status == .accepted {
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white), lineWidth: 1.2)
                    }
                    if cone.id == targetID {
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.white), lineWidth: 2)
                    }
                }

                for (p, label, color) in [(layout.refA, "A", Color.pink), (layout.refB, "B", Color.teal)] {
                    let pt = m.point(p)
                    let rect = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    ctx.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: pt)
                }

                if let cam = camera {
                    let pt = m.point(cam)
                    let heading = cameraHeading ?? 0
                    let dir = CGPoint(x: cos(heading), y: -sin(heading))
                    let side = CGPoint(x: -dir.y, y: dir.x)
                    var tri = Path()
                    tri.move(to: CGPoint(x: pt.x + dir.x * 10, y: pt.y + dir.y * 10))
                    tri.addLine(to: CGPoint(x: pt.x - dir.x * 6 + side.x * 6, y: pt.y - dir.y * 6 + side.y * 6))
                    tri.addLine(to: CGPoint(x: pt.x - dir.x * 6 - side.x * 6, y: pt.y - dir.y * 6 - side.y * 6))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(.white))
                    ctx.stroke(tri, with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard let onTapCone else { return }
                    let m = PreviewMapper(layout: layout, size: geo.size)
                    var best: (id: Int, d: Double)?
                    for cone in layout.cones {
                        let pt = m.point(cone.pos)
                        let d = hypot(Double(pt.x - value.location.x), Double(pt.y - value.location.y))
                        if best == nil || d < best!.d { best = (cone.id, d) }
                    }
                    if let b = best, b.d < 24 { onTapCone(b.id) }
                }
            )
        }
    }
}
