import SwiftUI
import MapKit

struct RunDetailView: View {
    let summary: RunSummary

    @AppStorage("speedUnit") private var unitRaw = SpeedUnit.kmh.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var run: SpeedRun?
    @State private var stats: RunStats?
    @State private var points: [ChartPoint] = []
    @State private var mapCoords: [CLLocationCoordinate2D] = []
    @State private var mapSpeeds: [Double] = []
    @State private var selection: Double?
    @State private var accelSelection: Double?
    @State private var xMode: ChartXMode = .time
    @State private var exporting: String?
    @State private var share: ShareItem?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var loadedUnit: SpeedUnit?

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }

    var body: some View {
        Group {
            if let run, let stats {
                content(run, stats)
            } else {
                ProgressView("Loading run…")
            }
        }
        .navigationTitle(run?.name ?? summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { export(.xlsx) } label: { Label("Export Excel (.xlsx)", systemImage: "tablecells") }
                    Button { export(.csv) } label: { Label("Export CSV", systemImage: "doc.plaintext") }
                    Button { export(.gpx) } label: { Label("Export GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    Divider()
                    Button {
                        newName = run?.name ?? summary.name
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(run == nil || exporting != nil)
            }
        }
        .overlay {
            if let msg = exporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(msg).font(.subheadline)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .alert("Rename run", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                run?.name = name
                Task { await RunStore.shared.rename(summary.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                RunStore.shared.delete(summary.id)
                dismiss()
            }
        }
        .task { await load() }
        .onChange(of: unitRaw) { _, _ in
            if let run { points = ChartData.points(run, unit: unit) }
        }
    }

    // MARK: Content

    private func content(_ run: SpeedRun, _ st: RunStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HeatmapMap(coords: mapCoords, speeds: mapSpeeds, top: st.topSpeed, marker: markerCoordinate(run))
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    HeatLegend(top: st.topSpeed, unit: unit)
                        .padding(.horizontal, 4)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(title: "Top speed", value: String(format: "%.1f", unit.convert(st.topSpeed)), unit: unit.label, tint: Heat.color(1))
                    StatTile(title: "Average speed", value: String(format: "%.1f", unit.convert(st.avgSpeed)), unit: unit.label)
                    StatTile(title: "Distance", value: st.distance >= 1000 ? String(format: "%.2f", st.distance / 1000) : String(format: "%.0f", st.distance),
                             unit: st.distance >= 1000 ? "km" : "m")
                    StatTile(title: "Duration", value: RunAnalysis.formatDuration(st.duration))
                    StatTile(title: "Moving average", value: String(format: "%.1f", unit.convert(st.movingAvgSpeed)), unit: unit.label)
                    StatTile(title: "Moving time", value: RunAnalysis.formatDuration(st.movingTime))
                    StatTile(title: "Max acceleration", value: String(format: "%.2f", st.maxAccel / Geo.g), unit: "g", tint: .green)
                    StatTile(title: "Max braking", value: String(format: "%.2f", st.maxBraking / Geo.g), unit: "g", tint: .red)
                    StatTile(title: "Max lateral", value: String(format: "%.2f", st.maxLateral / Geo.g), unit: "g")
                    StatTile(title: "0–100 km/h", value: st.zeroTo100.map { String(format: "%.2f", $0) } ?? "–", unit: st.zeroTo100 == nil ? "" : "s")
                    StatTile(title: "75 m from launch", value: st.best75m.map { String(format: "%.2f", $0) } ?? "–", unit: st.best75m == nil ? "" : "s")
                    StatTile(title: "75 m trap speed", value: st.best75mTrapSpeed.map { String(format: "%.1f", unit.convert($0)) } ?? "–",
                             unit: st.best75mTrapSpeed == nil ? "" : unit.label)
                }

                card {
                    HStack {
                        Text("Speed").font(.headline)
                        Spacer()
                        Picker("X axis", selection: $xMode) {
                            ForEach(ChartXMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    SpeedChart(points: points, unit: unit, mode: xMode, selection: $selection)
                        .frame(height: 230)
                    Text("Drag on the graph to find that moment on the map.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                card {
                    Text("Acceleration").font(.headline)
                    AccelChart(points: points, selection: $accelSelection)
                        .frame(height: 220)
                    Text("Longitudinal: + speeding up, − braking. Lateral: + left, − right.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button { export(.xlsx) } label: { Label("Excel", systemImage: "tablecells") }
                        .buttonStyle(FilledButtonStyle(color: .green))
                    Button { export(.csv) } label: { Label("CSV", systemImage: "doc.plaintext") }
                        .buttonStyle(FilledButtonStyle(color: .indigo))
                    Button { export(.gpx) } label: { Label("GPX", systemImage: "map") }
                        .buttonStyle(FilledButtonStyle(color: .gray))
                }
                .disabled(exporting != nil)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(st.sampleCount) samples · \(String(format: "%.1f", st.sampleRate)) Hz · \(st.fixCount) GPS fixes")
                    Text(st.fusedFraction > 0.5
                         ? "Source: GPS + IMU fusion (\(Int(st.fusedFraction * 100))% of samples)"
                         : "Source: GPS only")
                    Text("Recorded \(run.startDate.formatted(date: .complete, time: .standard))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func markerCoordinate(_ run: SpeedRun) -> CLLocationCoordinate2D? {
        let x: Double?
        let byTime: Bool
        if let s = selection {
            x = s
            byTime = xMode == .time
        } else if let a = accelSelection {
            x = a
            byTime = true
        } else {
            return nil
        }
        guard let target = x, !run.samples.isEmpty else { return nil }
        let s = run.samples
        var lo = 0, hi = s.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if (byTime ? s[mid].t : s[mid].distance) <= target { lo = mid } else { hi = mid }
        }
        return CLLocationCoordinate2D(latitude: s[lo].lat, longitude: s[lo].lon)
    }

    // MARK: Loading & export

    private func load() async {
        guard run == nil, let r = await RunStore.shared.load(summary.id) else { return }
        let st = RunAnalysis.stats(r)
        let idx = RunAnalysis.strideIndices(count: r.samples.count, max: 2500)
        mapCoords = idx.map { CLLocationCoordinate2D(latitude: r.samples[$0].lat, longitude: r.samples[$0].lon) }
        mapSpeeds = idx.map { r.samples[$0].speed }
        points = ChartData.points(r, unit: unit)
        stats = st
        run = r
    }

    private enum ExportKind { case xlsx, csv, gpx }

    private func export(_ kind: ExportKind) {
        guard let run else { return }
        let unit = self.unit
        let base = run.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "·", with: "-")
        Task {
            exporting = kind == .xlsx ? "Building Excel workbook…" : "Exporting…"
            defer { exporting = nil }
            let dir = FileManager.default.temporaryDirectory
            do {
                switch kind {
                case .xlsx:
                    let images = await RunImageRenderer.exportImages(run: run, unit: unit)
                    let data = await Task.detached(priority: .userInitiated) {
                        RunExcelExporter.workbook(run: run, unit: unit, images: images)
                    }.value
                    let url = dir.appendingPathComponent("\(base).xlsx")
                    try data.write(to: url, options: .atomic)
                    share = ShareItem(url: url)
                case .csv:
                    let url = dir.appendingPathComponent("\(base).csv")
                    try RunExcelExporter.csv(run: run, unit: unit).write(to: url, atomically: true, encoding: .utf8)
                    share = ShareItem(url: url)
                case .gpx:
                    let url = dir.appendingPathComponent("\(base).gpx")
                    try RunExcelExporter.gpx(run: run).write(to: url, atomically: true, encoding: .utf8)
                    share = ShareItem(url: url)
                }
            } catch {
                exporting = nil
            }
        }
    }
}
