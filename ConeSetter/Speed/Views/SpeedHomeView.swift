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

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdateBanner()
                    dashboard

                    if rec.authorization == .denied || rec.authorization == .restricted {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Location access is off. Turn it on in Settings › Cone Setter to record speed.",
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

                    SectionTitle(text: "Runs", systemImage: "flag.checkered")
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
                                NavigationLink(value: s) { runRow(s) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { deleteTarget = s } label: {
                                            Label("Delete run", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        Text(recovered
                             ? "A run interrupted by the app closing was recovered. Touch and hold a run to delete it."
                             : "Touch and hold a run to delete it.")
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

    private func runRow(_ s: RunSummary) -> some View {
        HStack(spacing: 12) {
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
                Text(s.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
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
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .card(padding: 12)
        .contentShape(Rectangle())
    }

    private func tip(_ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
