import Foundation
import MapKit
import SwiftUI
import UIKit

/// PNG renderings embedded in the Excel export: the heatmap track (on satellite imagery
/// when available) and the speed / acceleration graphs.
@MainActor
enum RunImageRenderer {
    static func exportImages(run: SpeedRun, unit: SpeedUnit) async -> RunExportImages {
        var images = RunExportImages()
        images.trackSize = (560, 560)
        images.chartSize = (720, 320)
        images.track = await trackPNG(run: run, unit: unit, points: 1120)
        images.speedChart = chartPNG(SpeedChartImage(run: run, unit: unit), size: CGSize(width: 720, height: 320))
        images.accelChart = chartPNG(AccelChartImage(run: run), size: CGSize(width: 720, height: 320))
        return images
    }

    // MARK: Track

    static func trackPNG(run: SpeedRun, unit: SpeedUnit, points px: CGFloat) async -> Data? {
        let s = run.samples
        guard s.count > 1 else { return nil }
        let idx = RunAnalysis.strideIndices(count: s.count, max: 4000)
        let coords = idx.map { CLLocationCoordinate2D(latitude: s[$0].lat, longitude: s[$0].lon) }
        let speeds = idx.map { s[$0].speed }
        let top = max(speeds.max() ?? 1, 0.1)

        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0.1, height: 0.1))
        }
        let side = max(rect.width, rect.height, MKMapPointsPerMeterAtLatitude(coords[0].latitude) * 40) * 1.18
        let square = MKMapRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)

        let size = CGSize(width: px, height: px)
        let snapshot = await satelliteSnapshot(rect: square, size: size)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let toPoint: (CLLocationCoordinate2D) -> CGPoint
            if let snap = snapshot {
                snap.image.draw(in: CGRect(origin: .zero, size: size))
                UIColor.black.withAlphaComponent(0.25).setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                toPoint = { snap.point(for: $0) }
            } else {
                UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                drawGrid(cg, size: size, metres: side / MKMapPointsPerMeterAtLatitude(coords[0].latitude))
                toPoint = { c in
                    let p = MKMapPoint(c)
                    return CGPoint(x: (p.x - square.minX) / square.width * size.width,
                                   y: (p.y - square.minY) / square.height * size.height)
                }
            }

            let pts = coords.map(toPoint)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // Dark casing under the coloured line.
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(px / 90)
            cg.addLines(between: pts)
            cg.strokePath()
            cg.setLineWidth(px / 150)
            for i in 1..<pts.count {
                let c = HeatColor.rgb((speeds[i] + speeds[i - 1]) / 2 / top)
                cg.setStrokeColor(UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1).cgColor)
                cg.move(to: pts[i - 1])
                cg.addLine(to: pts[i])
                cg.strokePath()
            }

            // Start / finish markers
            drawDot(cg, pts.first!, color: .systemGreen, r: px / 70)
            drawDot(cg, pts.last!, color: .white, r: px / 70)

            drawLegend(cg, size: size, top: top, unit: unit)
            let title = "\(run.name) · top \(String(format: "%.1f", unit.convert(top))) \(unit.label)"
            drawLabel(cg, title, at: CGPoint(x: px * 0.03, y: px * 0.03), size: px / 34, bold: true)
        }
        return image.pngData()
    }

    private static func satelliteSnapshot(rect: MKMapRect, size: CGSize) async -> MKMapSnapshotter.Snapshot? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = 1
        options.mapType = .satellite
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKMapSnapshotter(options: options)
        let flag = OnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<MKMapSnapshotter.Snapshot?, Never>) in
            snapshotter.start(with: .main) { snap, _ in
                guard flag.claim() else { return }
                cont.resume(returning: snap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard flag.claim() else { return }
                snapshotter.cancel()
                cont.resume(returning: nil)
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private static func drawGrid(_ cg: CGContext, size: CGSize, metres: Double) {
        let step = niceStep(metres / 6)
        let pxPerM = size.width / metres
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.08).cgColor)
        cg.setLineWidth(1)
        var x = 0.0
        while x < size.width {
            cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height))
            x += step * pxPerM
        }
        var y = 0.0
        while y < size.height {
            cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
            y += step * pxPerM
        }
        cg.strokePath()
        let barW = step * pxPerM
        let y0 = size.height * 0.95
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(3)
        cg.move(to: CGPoint(x: size.width * 0.04, y: y0))
        cg.addLine(to: CGPoint(x: size.width * 0.04 + barW, y: y0))
        cg.strokePath()
        drawLabel(cg, "\(Int(step)) m", at: CGPoint(x: size.width * 0.04, y: y0 - size.width / 28), size: size.width / 40, bold: false)
    }

    private static func drawLegend(_ cg: CGContext, size: CGSize, top: Double, unit: SpeedUnit) {
        let w = size.width * 0.34, h = size.width / 60
        let x0 = size.width - w - size.width * 0.04, y0 = size.height * 0.93
        let bg = CGRect(x: x0 - 10, y: y0 - size.width / 22, width: w + 20, height: h + size.width / 14)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        cg.addPath(UIBezierPath(roundedRect: bg, cornerRadius: 8).cgPath)
        cg.fillPath()
        let steps = 60
        for i in 0..<steps {
            let c = HeatColor.rgb(Double(i) / Double(steps - 1))
            cg.setFillColor(UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1).cgColor)
            cg.fill(CGRect(x: x0 + w * CGFloat(i) / CGFloat(steps), y: y0, width: w / CGFloat(steps) + 1, height: h))
        }
        let fs = size.width / 45
        drawLabel(cg, "0", at: CGPoint(x: x0, y: y0 - fs * 1.4), size: fs, bold: false)
        let topText = "\(Int(unit.convert(top).rounded())) \(unit.label)"
        let tw = (topText as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fs)]).width
        drawLabel(cg, topText, at: CGPoint(x: x0 + w - tw, y: y0 - fs * 1.4), size: fs, bold: false)
    }

    private static func drawDot(_ cg: CGContext, _ p: CGPoint, color: UIColor, r: CGFloat) {
        cg.setFillColor(UIColor.black.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: 2 * r + 4, height: 2 * r + 4))
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    private static func drawLabel(_ cg: CGContext, _ text: String, at p: CGPoint, size: CGFloat, bold: Bool) {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ]
        (text as NSString).draw(at: p, withAttributes: attrs)
    }

    private static func niceStep(_ raw: Double) -> Double {
        let mag = pow(10, floor(log10(max(raw, 1))))
        let n = raw / mag
        return (n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10) * mag
    }

    // MARK: Charts

    static func chartPNG<V: View>(_ view: V, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage?.pngData()
    }
}
