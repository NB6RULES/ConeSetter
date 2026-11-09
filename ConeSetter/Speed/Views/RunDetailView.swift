import SwiftUI
import MapKit

struct RunDetailView: View {
    let summary: RunSummary

    @AppStorage("speedUnit") private var unitRaw = SpeedUnit.kmh.rawValue
    @AppStorage("skipStops") private var skipStops = false
    @AppStorage("skipBelowMS") private var skipBelowMS = 1.0
    @AppStorage("skipMinDuration") private var skipMinDuration = 3.0
    @AppStorage("skipPadding") private var skipPadding = 1.0
    @Environment(\.dismiss) private var dismiss

    @State private var run: SpeedRun?
    @State private var stats: RunStats?
    @State private var series = ChartSeries()
    @State private var mapCoords: [CLLocationCoordinate2D] = []
    @State private var mapSpeeds: [Double] = []
    @State private var selection: Double?
    @State private var accelSelection: Double?
    @State private var elevSelection: Double?
    @State private var xMode: ChartXMode = .time
    @State private var showAdvanced = false
    @State private var exporting: String?
    @State private var share: ShareItem?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }

    private var skip: IdleSkip {
        IdleSkip(enabled: skipStops, speedBelow: skipBelowMS, minDuration: skipMinDuration, padding: skipPadding)
    }

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
        .onChange(of: unitRaw) { _, _ in rebuildSeries() }
        .onChange(of: skip) { _, _ in rebuildSeries() }
    }

    // MARK: Content

    private func content(_ run: SpeedRun, _ st: RunStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HeatmapMap(coords: mapCoords, speeds: mapSpeeds, top: st.topSpeed, marker: markerCoordinate)
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
                    StatTile(title: "Elevation range", value: elevationRange(st), unit: st.minElevation == nil ? "" : "m")
                    StatTile(title: "Climb / descent", value: String(format: "+%.0f / −%.0f", st.climb, st.descent), unit: "m")
                }

                skipCard

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
                    SpeedChart(series: series, unit: unit, mode: xMode, selection: $selection)
                        .frame(height: 230)
                    Text("Drag on a graph to find that moment on the map.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                card {
                    Text("Acceleration").font(.headline)
                    AccelChart(series: series, selection: $accelSelection)
                        .frame(height: 220)
                    Text("Longitudinal: + speeding up, − braking. Lateral: + left, − right.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                card {
                    HStack {
                        Text("Elevation").font(.headline)
                        Spacer()
                        Text(st.barometer ? "Barometer + GPS" : "GPS altitude")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ElevationChart(series: series, mode: xMode, selection: $elevSelection)
                        .frame(height: 200)
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
                if skipStops {
                    Text("Excel charts follow the skip-stops setting. The Data sheet always keeps every sample.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

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

    private var skipCard: some View {
        card {
            Toggle(isOn: $skipStops.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip stops").font(.headline)
                    Text(skipStops
                         ? (series.stopsSkipped == 0 && series.skippedTime < 0.5
                            ? "No stops matched"
                            : "Hiding \(RunAnalysis.formatDuration(series.skippedTime)) of standing still")
                         : "Cut out periods without movement from the graphs")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.orange)

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Skip when slower than")
                            Spacer()
                            Text(String(format: "%.1f %@", unit.convert(skipBelowMS), unit.label))
                                .monospacedDigit().foregroundStyle(.orange)
                        }
                        Slider(value: Binding(get: { unit.convert(skipBelowMS) },
                                              set: { skipBelowMS = $0 / unit.factor }),
                               in: 0.5...unit.convert(10), step: unit == .ms ? 0.1 : 0.5)
                    }
                    Stepper(value: $skipMinDuration, in: 1...120, step: 1) {
                        HStack {
                            Text("Only stops longer than")
                            Spacer()
                            Text("\(Int(skipMinDuration)) s").monospacedDigit().foregroundStyle(.orange)
                        }
                    }
                    Stepper(value: $skipPadding, in: 0...10, step: 0.5) {
                        HStack {
                            Text("Keep either side")
                            Spacer()
                            Text(String(format: "%.1f s", skipPadding)).monospacedDigit().foregroundStyle(.orange)
                        }
                    }
                    Button("Reset to defaults") {
                        skipBelowMS = 1
                        skipMinDuration = 3
                        skipPadding = 1
                    }
                    .font(.subheadline)
                    Text("Samples below the speed, for at least the stop length, are hidden. The time either side is kept so launches and stops still show.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .disabled(!skipStops)
            .opacity(skipStops ? 1 : 0.5)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func elevationRange(_ st: RunStats) -> String {
        guard let lo = st.minElevation, let hi = st.maxElevation else { return "–" }
        return String(format: "%.0f–%.0f", lo, hi)
    }

    private var markerCoordinate: CLLocationCoordinate2D? {
        let p: ChartPoint?
        if let s = selection {
            p = series.nearest(s, mode: xMode)
        } else if let a = accelSelection {
            p = series.nearest(a, mode: .time)
        } else if let e = elevSelection {
            p = series.nearest(e, mode: xMode)
        } else {
            p = nil
        }
        return p.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    // MARK: Loading & export

    private func load() async {
        guard run == nil, let r = await RunStore.shared.load(summary.id) else { return }
        let st = RunAnalysis.stats(r)
        let idx = RunAnalysis.strideIndices(count: r.samples.count, max: 2500)
        mapCoords = idx.map { CLLocationCoordinate2D(latitude: r.samples[$0].lat, longitude: r.samples[$0].lon) }
        mapSpeeds = idx.map { r.samples[$0].speed }
        series = ChartData.build(r, unit: unit, skip: skip)
        stats = st
        run = r
    }

    private func rebuildSeries() {
        guard let run else { return }
        selection = nil
        accelSelection = nil
        elevSelection = nil
        series = ChartData.build(run, unit: unit, skip: skip)
    }

    private enum ExportKind { case xlsx, csv, gpx }

    private func export(_ kind: ExportKind) {
        guard let run else { return }
        let unit = self.unit
        let skip = self.skip
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
                    let images = await RunImageRenderer.exportImages(run: run, unit: unit, skip: skip)
                    let data = await Task.detached(priority: .userInitiated) {
                        RunExcelExporter.workbook(run: run, unit: unit, images: images, skip: skip)
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
