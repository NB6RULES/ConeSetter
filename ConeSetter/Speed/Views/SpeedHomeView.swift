import SwiftUI
import CoreLocation

struct SpeedHomeView: View {
    @ObservedObject private var rec = SpeedRecorder.shared
    @ObservedObject private var store = RunStore.shared
    @AppStorage("speedUnit") private var unitRaw = SpeedUnit.kmh.rawValue
    @State private var path: [RunSummary] = []
    @State private var confirmStop = false
    @State private var recovered = false
    @State private var deleteTarget: RunSummary?
    @State private var editTarget: RunSummary?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var bulkStatus: String?
    @State private var share: ShareItem?
    @State private var exportError: String?
    @State private var confirmBulkDelete = false
    @AppStorage("skipStops") private var skipStops = false
    @AppStorage("skipBelowMS") private var skipBelowMS = 1.0
    @AppStorage("skipMinDuration") private var skipMinDuration = 3.0
    @AppStorage("skipPadding") private var skipPadding = 1.0

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdateBanner()
                    dashboard

                    if rec.authorization == .denied || rec.authorization == .restricted {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Location access is off. Turn it on in Settings › OBRA Essentials to record speed.",
                                  systemImage: "location.slash.fill")
                                .font(.subheadline)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .card()
                    }

                    if rec.isRecording {
                        SectionTitle(text: "Live", systemImage: "dot.radiowaves.left.and.right")
                        liveStats
                        LiveTrailMap(trail: rec.trail)
                            .equatable()
                            .frame(height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                    }

                    HStack {
                        SectionTitle(text: "Runs", systemImage: "flag.checkered")
                        Spacer()
                        if selecting {
                            Button(allSelected ? "Deselect all" : "Select all") {
                                selected = allSelected ? [] : Set(store.summaries.map(\.id))
                            }
                            .font(.subheadline)
                            Button("Done") { endSelecting() }
                                .font(.subheadline.weight(.semibold))
                                .padding(.leading, 10)
                        } else if !store.summaries.isEmpty {
                            Button("Select") { withAnimation { selecting = true } }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    if store.summaries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "road.lanes.curved.right")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                            Text("No runs yet").font(.headline)
                            Text("Mount the phone firmly in the car, start recording, then drive.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .card()
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.summaries) { s in
                                if selecting {
                                    Button { toggle(s.id) } label: { runRow(s, picked: selected.contains(s.id)) }
                                        .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: s) { runRow(s, picked: nil) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button { editTarget = s } label: {
                                                Label("Driver, type and notes", systemImage: "square.and.pencil")
                                            }
                                            Button {
                                                selected = [s.id]
                                                withAnimation { selecting = true }
                                            } label: {
                                                Label("Select runs", systemImage: "checkmark.circle")
                                            }
                                            Button(role: .destructive) { deleteTarget = s } label: {
                                                Label("Delete run", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                        Text(selecting
                             ? "Tap runs to pick them, then save them together as one zip."
                             : recovered
                             ? "A run interrupted by the app closing was recovered. Touch and hold a run to add notes, select or delete."
                             : "Touch and hold a run to add notes, select or delete. Select saves several runs as one zip.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    SectionTitle(text: "Tips", systemImage: "lightbulb.fill")
                    VStack(alignment: .leading, spacing: 12) {
                        tip("Fix the phone to the car, in any orientation. A loose phone breaks the 10 Hz fusion and it falls back to GPS only.", "iphone.gen3.radiowaves.left.and.right")
                        tip("Start with a firm launch and a brake on a short straight. That calibrates the fusion.", "arrow.up.forward")
                        tip("Wait for GPS ±5 m or better before starting. Recording continues with the screen locked.", "location.fill")
                    }
                    .card()
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .overlay {
                if let msg = bulkStatus {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(msg).font(.subheadline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .sheet(item: $editTarget) { s in
                RunDetailsSheet(details: RunDetails(name: s.name, driver: s.driver ?? "", runType: s.runType ?? "", notes: s.notes ?? "")) { d in
                    Task { await store.updateDetails(s.id, d) }
                }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .confirmationDialog("Delete \(selected.count) run\(selected.count == 1 ? "" : "s")?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.delete(Array(selected))
                    endSelecting()
                }
            }
            .onChange(of: store.summaries) { _, list in
                selected.formIntersection(list.map(\.id))
                if list.isEmpty { selecting = false }
            }
            .navigationTitle("GPS speed")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Units", selection: $unitRaw) {
                            ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        Toggle("IMU fusion (10 Hz)", isOn: Binding(get: { rec.useIMU }, set: { rec.useIMU = $0 }))
                            .disabled(rec.isRecording || !rec.motionAvailable)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .navigationDestination(for: RunSummary.self) { s in
                RunDetailView(summary: s)
            }
            .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop and save") {
                    if let run = rec.stop() { path.append(RunSummary(run: run)) }
                }
                Button("Discard run", role: .destructive) { rec.discard() }
                Button("Keep recording", role: .cancel) {}
            }
            .confirmationDialog("Delete this run?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = deleteTarget { store.delete(s.id) }
                    deleteTarget = nil
                }
            }
            .onAppear {
                rec.beginPreview()
                if !rec.isRecording, store.recoverCheckpoint() { recovered = true }
            }
            .onDisappear { rec.endPreview() }
        }
    }

    // MARK: Selection

    private var allSelected: Bool { !store.summaries.isEmpty && selected.count == store.summaries.count }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func endSelecting() {
        withAnimation { selecting = false }
        selected = []
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button { exportZip([.xlsx]) } label: { Label("Excel workbooks", systemImage: "tablecells") }
                Button { exportZip([.csv]) } label: { Label("CSV files", systemImage: "doc.plaintext") }
                Button { exportZip([.gpx]) } label: { Label("GPX tracks", systemImage: "map") }
                Button { exportZip(RunExportFormat.allCases) } label: { Label("All three formats", systemImage: "square.stack.3d.up") }
            } label: {
                Label(selected.isEmpty ? "Save as zip" : "Save \(selected.count) as zip", systemImage: "doc.zipper")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            Button { confirmBulkDelete = true } label: {
                Image(systemName: "trash")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 60)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .disabled(selected.isEmpty || bulkStatus != nil)
        .opacity(selected.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func exportZip(_ formats: [RunExportFormat]) {
        // Oldest first, so the files and the index read in the order the runs were driven.
        let ids = store.summaries.filter { selected.contains($0.id) }.sorted { $0.startDate < $1.startDate }.map(\.id)
        guard !ids.isEmpty else { return }
        let unit = self.unit
        let skip = IdleSkip(enabled: skipStops, speedBelow: skipBelowMS, minDuration: skipMinDuration, padding: skipPadding)
        Task {
            bulkStatus = "Exporting…"
            defer { bulkStatus = nil }
            do {
                let url = try await RunBulkExport.zip(ids: ids, formats: formats, unit: unit, skip: skip) { bulkStatus = $0 }
                share = ShareItem(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        VStack(spacing: 14) {
            statusChips
            SpeedGauge(speed: unit.convert(rec.speed), unit: unit,
                       maxScale: SpeedGauge.scale(for: max(rec.topSpeed, rec.speed), unit: unit),
                       active: rec.isRecording,
                       peak: rec.isRecording ? unit.convert(rec.topSpeed) : 0)
            recordButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(rec.isRecording ? Color.red.opacity(0.55) : Theme.stroke, lineWidth: rec.isRecording ? 1.5 : 1)
        )
        .shadow(color: rec.isRecording ? Color.red.opacity(0.25) : .black.opacity(0.4), radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.3), value: rec.isRecording)
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            if let acc = rec.gpsAccuracy, rec.gpsAge < 5 {
                Chip(text: String(format: "GPS ±%.0f m", acc), systemImage: "location.fill",
                     tint: acc <= 5 ? .green : acc <= 15 ? .yellow : .red)
            } else {
                Chip(text: "Waiting for GPS", systemImage: "location.slash", tint: .orange)
            }
            if rec.isRecording {
                Chip(text: rec.imuState.label, systemImage: rec.imuState.isFused ? "gyroscope" : "dot.radiowaves.up.forward",
                     tint: rec.imuState.isFused ? .green : .secondary)
            } else {
                Chip(text: rec.useIMU && rec.motionAvailable ? "IMU fusion on" : "GPS only", systemImage: "gyroscope")
            }
        }
    }

    private var recordButton: some View {
        Button {
            if rec.isRecording { confirmStop = true } else { rec.start() }
        } label: {
            HStack(spacing: 10) {
                if rec.isRecording {
                    PulsingDot()
                    Text("Stop · \(RunAnalysis.formatDuration(rec.elapsed))").monospacedDigit()
                } else {
                    Image(systemName: "record.circle.fill")
                    Text("Start recording")
                }
            }
            .font(.system(.title3, design: .rounded).weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                rec.isRecording
                    ? LinearGradient(colors: [Color.red, Color(red: 0.6, green: 0.05, blue: 0.1)], startPoint: .top, endPoint: .bottom)
                    : Theme.accentGradient,
                in: Capsule()
            )
            .foregroundStyle(.white)
            .shadow(color: (rec.isRecording ? Color.red : Theme.accent).opacity(0.45), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(rec.authorization == .denied || rec.authorization == .restricted)
        .opacity(rec.authorization == .denied || rec.authorization == .restricted ? 0.5 : 1)
    }

    // MARK: Live

    private var liveStats: some View {
        let avg = rec.elapsed > 0 ? rec.distance / rec.elapsed : 0
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                GForceDial(longG: rec.longAccel / Geo.g, latG: rec.latAccel / Geo.g)
                Text("G-FORCE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 150)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                StatTile(title: "Top", value: String(format: "%.1f", unit.convert(rec.topSpeed)), unit: unit.label,
                         tint: Heat.color(1), icon: "flame.fill")
                StatTile(title: "Average", value: String(format: "%.1f", unit.convert(avg)), unit: unit.label, icon: "equal.circle.fill")
                StatTile(title: "Distance",
                         value: rec.distance >= 1000 ? String(format: "%.2f", rec.distance / 1000) : String(format: "%.0f", rec.distance),
                         unit: rec.distance >= 1000 ? "km" : "m", icon: "point.topleft.down.to.point.bottomright.curvepath")
                StatTile(title: "Elevation", value: rec.altitude.map { String(format: "%.0f", $0) } ?? "–",
                         unit: rec.altitude == nil ? "" : "m", icon: "mountain.2.fill")
            }
        }
    }

    // MARK: Rows

    /// `picked` is nil outside selection mode, otherwise whether the run is ticked.
    private func runRow(_ s: RunSummary, picked: Bool?) -> some View {
        HStack(spacing: 12) {
            if let picked {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            VStack(spacing: 0) {
                Text(String(format: "%.0f", unit.convert(s.topSpeed)))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(unit.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.body.weight(.semibold)).lineLimit(1)
                if s.driver != nil || s.runType != nil {
                    RunTags(driver: s.driver, runType: s.runType)
                }
                Text(s.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if s.notes != nil { Image(systemName: "note.text") }
                    Label(RunAnalysis.formatDuration(s.duration), systemImage: "timer")
                    Label(s.distance >= 1000 ? String(format: "%.2f km", s.distance / 1000) : String(format: "%.0f m", s.distance),
                          systemImage: "ruler")
                    if s.fused { Label("10 Hz", systemImage: "gyroscope") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if picked == nil {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .card(padding: 12)
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .stroke(Theme.accent.opacity(picked == true ? 0.7 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    private func tip(_ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
