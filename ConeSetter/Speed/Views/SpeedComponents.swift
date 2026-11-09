import SwiftUI
import MapKit
import Charts

// MARK: - Colours

enum Heat {
    static func color(_ t: Double) -> Color {
        let c = HeatColor.rgb(t)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static let gradientColors: [Color] = (0...8).map { color(Double($0) / 8) }
    static let gradient = Gradient(colors: gradientColors)
}

struct HeatLegend: View {
    var top: Double
    var unit: SpeedUnit

    var body: some View {
        HStack(spacing: 8) {
            Text("0").font(.caption2.monospacedDigit())
            LinearGradient(gradient: Heat.gradient, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
            Text("\(Int(unit.convert(top).rounded())) \(unit.label)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Gauge

struct SpeedGauge: View {
    var speed: Double
    var unit: SpeedUnit
    var maxScale: Double
    var active: Bool

    var body: some View {
        let frac = min(max(speed / max(maxScale, 1), 0), 1)
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * frac)
                .stroke(AngularGradient(gradient: Heat.gradient, center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.15), value: frac)
            ForEach(0..<5) { i in
                let v = maxScale * Double(i) / 4
                let angle = (135 + 270 * Double(i) / 4) * Double.pi / 180
                Text("\(Int(v))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: cos(angle) * 82, y: sin(angle) * 82)
            }
            VStack(spacing: -4) {
                Text("\(Int(speed.rounded()))")
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(active ? .primary : .secondary)
                Text(unit.label)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 210, height: 210)
    }

    static func scale(for top: Double, unit: SpeedUnit) -> Double {
        let base: Double = unit == .kmh ? 120 : unit == .mph ? 80 : 40
        let step: Double = unit == .ms ? 10 : 20
        let needed = unit.convert(top) * 1.1
        return max(base, (needed / step).rounded(.up) * step)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var unit: String = ""
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Heatmap map

struct HeatSegment: Identifiable {
    let id: Int
    let coords: [CLLocationCoordinate2D]
    let color: Color
}

enum HeatPath {
    static func segments(coords: [CLLocationCoordinate2D], speeds: [Double], top: Double, buckets: Int = 24) -> [HeatSegment] {
        guard coords.count > 1 else { return [] }
        let topV = max(top, 0.1)
        func bucket(_ i: Int) -> Int { min(buckets - 1, Int(speeds[i] / topV * Double(buckets))) }
        var out: [HeatSegment] = []
        var current: [CLLocationCoordinate2D] = [coords[0]]
        var b = bucket(1)
        for i in 1..<coords.count {
            let nb = bucket(i)
            if nb != b && current.count > 1 {
                out.append(HeatSegment(id: out.count, coords: current, color: Heat.color((Double(b) + 0.5) / Double(buckets))))
                current = [coords[i - 1]]
                b = nb
            }
            current.append(coords[i])
        }
        out.append(HeatSegment(id: out.count, coords: current, color: Heat.color((Double(b) + 0.5) / Double(buckets))))
        return out
    }

    static func region(_ coords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard !coords.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        let minSide = MKMapPointsPerMeterAtLatitude(coords[0].latitude) * 60
        let side = max(rect.width, rect.height, minSide)
        let padded = MKMapRect(x: rect.midX - side * 0.6, y: rect.midY - side * 0.6, width: side * 1.2, height: side * 1.2)
        return .rect(padded)
    }
}

struct HeatmapMap: View {
    var coords: [CLLocationCoordinate2D]
    var speeds: [Double]
    var top: Double
    var marker: CLLocationCoordinate2D?
    var followUser = false

    @State private var position: MapCameraPosition = .automatic
    @State private var segments: [HeatSegment] = []
    @State private var builtFor = -1

    var body: some View {
        Map(position: $position) {
            if coords.count > 1 {
                MapPolyline(coordinates: coords)
                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            ForEach(segments) { seg in
                MapPolyline(coordinates: seg.coords)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = coords.first, !followUser {
                Annotation("Start", coordinate: first) {
                    Circle().fill(.green).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 2))
                }
            }
            if let last = coords.last, coords.count > 1, !followUser {
                Annotation("Finish", coordinate: last) {
                    Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 2))
                }
            }
            if let m = marker {
                Annotation("", coordinate: m) {
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.black, lineWidth: 3))
                        .shadow(radius: 3)
                }
            }
            if followUser { UserAnnotation() }
        }
        .mapStyle(.hybrid(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onAppear {
            rebuild()
            position = followUser ? .userLocation(fallback: .automatic) : HeatPath.region(coords)
        }
        .onChange(of: coords.count) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard builtFor != coords.count else { return }
        builtFor = coords.count
        segments = HeatPath.segments(coords: coords, speeds: speeds, top: top)
    }
}

// MARK: - Charts

struct ChartPoint: Identifiable {
    let id: Int
    let t: Double
    let d: Double
    let v: Double
    let aLong: Double
    let aLat: Double
}

enum ChartData {
    static func points(_ run: SpeedRun, unit: SpeedUnit, max n: Int = 1500) -> [ChartPoint] {
        let s = run.samples
        let rate = s.count > 1 ? Double(s.count - 1) / max(s.last!.t - s.first!.t, 0.1) : 1
        let w = rate > 5 ? 3 : 1
        let longS = RunAnalysis.movingAverage(s.map(\.longAccel), w)
        let latS = RunAnalysis.movingAverage(s.map(\.latAccel), w)
        return RunAnalysis.strideIndices(count: s.count, max: n).map { i in
            ChartPoint(id: i, t: s[i].t, d: s[i].distance, v: unit.convert(s[i].speed),
                       aLong: longS[i] / Geo.g, aLat: latS[i] / Geo.g)
        }
    }
}

enum ChartXMode: String, CaseIterable, Identifiable {
    case time = "Time"
    case distance = "Distance"
    var id: String { rawValue }
}

struct SpeedChart: View {
    var points: [ChartPoint]
    var unit: SpeedUnit
    var mode: ChartXMode
    @Binding var selection: Double?

    var body: some View {
        let top = max(points.map(\.v).max() ?? 1, 1)
        Chart {
            ForEach(points) { p in
                LineMark(x: .value(mode == .time ? "Time (s)" : "Distance (m)", mode == .time ? p.t : p.d),
                         y: .value("Speed", p.v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .foregroundStyle(LinearGradient(gradient: Heat.gradient, startPoint: .bottom, endPoint: .top))
            }
            if let sel = selection, let p = nearest(sel) {
                RuleMark(x: .value("Selected", mode == .time ? p.t : p.d))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(String(format: "%.1f %@ · %.1f s", p.v, unit.label, p.t))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
            }
        }
        .chartYScale(domain: 0...(top * 1.08))
        .chartXAxisLabel(mode == .time ? "Time (s)" : "Distance (m)")
        .chartYAxisLabel(unit.label)
        .chartXSelection(value: $selection)
    }

    func nearest(_ x: Double) -> ChartPoint? {
        points.min { abs((mode == .time ? $0.t : $0.d) - x) < abs((mode == .time ? $1.t : $1.d) - x) }
    }
}

struct AccelChart: View {
    var points: [ChartPoint]
    @Binding var selection: Double?

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time (s)", p.t), y: .value("g", p.aLong), series: .value("Axis", "Longitudinal"))
                    .foregroundStyle(by: .value("Axis", "Longitudinal"))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                LineMark(x: .value("Time (s)", p.t), y: .value("g", p.aLat), series: .value("Axis", "Lateral"))
                    .foregroundStyle(by: .value("Axis", "Lateral"))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
            if let sel = selection {
                RuleMark(x: .value("Selected", sel))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(["Longitudinal": Color.blue, "Lateral": Color.green])
        .chartXAxisLabel("Time (s)")
        .chartYAxisLabel("g")
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $selection)
    }
}

// MARK: - Static chart views for the Excel export

struct SpeedChartImage: View {
    var run: SpeedRun
    var unit: SpeedUnit

    var body: some View {
        let pts = ChartData.points(run, unit: unit, max: 1200)
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed vs time").font(.headline)
            SpeedChart(points: pts, unit: unit, mode: .time, selection: .constant(nil))
        }
        .padding(16)
        .environment(\.colorScheme, .light)
    }
}

struct AccelChartImage: View {
    var run: SpeedRun

    var body: some View {
        let pts = ChartData.points(run, unit: .kmh, max: 1200)
        VStack(alignment: .leading, spacing: 6) {
            Text("Acceleration vs time (g)").font(.headline)
            AccelChart(points: pts, selection: .constant(nil))
        }
        .padding(16)
        .environment(\.colorScheme, .light)
    }
}
