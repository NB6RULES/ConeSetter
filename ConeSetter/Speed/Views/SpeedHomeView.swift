import SwiftUI
import CoreLocation

struct SpeedHomeView: View {
    @StateObject private var rec = SpeedRecorder.shared
    @StateObject private var store = RunStore.shared
    @AppStorage("speedUnit") private var unitRaw = SpeedUnit.kmh.rawValue
    @State private var path: [RunSummary] = []
    @State private var confirmStop = false
    @State private var recovered = false

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(spacing: 14) {
                        statusChips
                        SpeedGauge(speed: unit.convert(rec.speed), unit: unit,
                                   maxScale: SpeedGauge.scale(for: max(rec.topSpeed, rec.speed), unit: unit),
                                   active: rec.isRecording)
                        recordButton
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                if rec.authorization == .denied || rec.authorization == .restricted {
                    Section {
                        Label("Location access is off. Turn it on in Settings › Cone Setter to record speed.", systemImage: "location.slash")
                            .font(.subheadline)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }

                if rec.isRecording {
                    Section("Live") { liveStats }
                    Section {
                        HeatmapMap(coords: rec.trail.map(\.coordinate), speeds: rec.trail.map(\.speed),
                                   top: max(rec.trail.map(\.speed).max() ?? 1, 1), followUser: true)
                            .frame(height: 260)
                            .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    if store.summaries.isEmpty {
                        Text("No runs yet. Mount the phone firmly in the car, start recording, then drive.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.summaries) { s in
                        NavigationLink(value: s) { runRow(s) }
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(store.summaries[i].id) }
                    }
                } header: {
                    Text("Runs")
                } footer: {
                    if recovered { Text("A run interrupted by the app closing was recovered.") }
                }

                Section("Tips") {
                    Label("Fix the phone to the car (any orientation). A loose phone breaks the IMU fusion — it then falls back to GPS only.", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    Label("Drive a short straight with a firm launch and a brake first; that calibrates the 10 Hz fusion.", systemImage: "arrow.up.forward")
                    Label("Wait for GPS ±5 m or better before starting. Recording continues with the screen locked.", systemImage: "location.fill")
                }
                .font(.footnote)
            }
            .navigationTitle("Speed")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Units", selection: $unitRaw) {
                            ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        Toggle("IMU fusion (10 Hz)", isOn: Binding(get: { rec.useIMU }, set: { rec.useIMU = $0 }))
                            .disabled(rec.isRecording || !rec.motionAvailable)
                    } label: {
                        Image(systemName: "gearshape")
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
            .onAppear {
                rec.beginPreview()
                if !rec.isRecording, store.recoverCheckpoint() { recovered = true }
            }
            .onDisappear { rec.endPreview() }
        }
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
                Image(systemName: rec.isRecording ? "stop.fill" : "record.circle")
                Text(rec.isRecording ? "Stop · \(RunAnalysis.formatDuration(rec.elapsed))" : "Start recording")
                    .monospacedDigit()
            }
        }
        .buttonStyle(FilledButtonStyle(color: rec.isRecording ? .red : .orange))
        .disabled(rec.authorization == .denied || rec.authorization == .restricted)
    }

    private var liveStats: some View {
        let avg = rec.elapsed > 0 ? rec.distance / rec.elapsed : 0
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(title: "Top", value: String(format: "%.1f", unit.convert(rec.topSpeed)), unit: unit.label)
            StatTile(title: "Average", value: String(format: "%.1f", unit.convert(avg)), unit: unit.label)
            StatTile(title: "Distance", value: rec.distance >= 1000 ? String(format: "%.2f", rec.distance / 1000) : String(format: "%.0f", rec.distance),
                     unit: rec.distance >= 1000 ? "km" : "m")
            StatTile(title: "Long", value: String(format: "%+.2f", rec.longAccel / Geo.g), unit: "g",
                     tint: rec.longAccel >= 0 ? .green : .red)
            StatTile(title: "Lateral", value: String(format: "%+.2f", rec.latAccel / Geo.g), unit: "g")
            StatTile(title: "Elevation", value: rec.altitude.map { String(format: "%.0f", $0) } ?? "–", unit: rec.altitude == nil ? "" : "m")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func runRow(_ s: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.name).font(.body.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f %@", unit.convert(s.topSpeed), unit.label))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Heat.color(1))
            }
            HStack(spacing: 10) {
                Text(s.startDate.formatted(date: .abbreviated, time: .shortened))
                Text(RunAnalysis.formatDuration(s.duration))
                Text(s.distance >= 1000 ? String(format: "%.2f km", s.distance / 1000) : String(format: "%.0f m", s.distance))
                if s.fused { Image(systemName: "gyroscope") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
