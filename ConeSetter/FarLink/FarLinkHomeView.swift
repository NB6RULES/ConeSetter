import SwiftUI

/// FarLink colours, built on the app theme: orange accent, with green / yellow / red kept for status.
enum FLTheme {
    static let accent = Theme.accent
    static let ok = Color.green
    static let warn = Color.yellow
    static let danger = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let regen = Color(red: 0.3, green: 0.8, blue: 1.0)
    static let tile = Theme.surface
    /// Unfilled part of gauges and bars.
    static let track = Color.white.opacity(0.08)
}

/// One Bluetooth link for the whole app, created the first time the FarLink tab is opened so the
/// Bluetooth permission prompt only appears when FarLink is actually used.
@MainActor
enum FarLinkRuntime {
    static let link = FardriverLink()
}

/// The FarLink tab: FarDriver motor controller dashboard, tuning, registers and settings.
struct FarLinkHomeView: View {
    @State private var link: FardriverLink?

    var body: some View {
        Group {
            if let link {
                FarLinkRoot().environment(link)
            } else {
                Theme.background.ignoresSafeArea()
            }
        }
        .tint(FLTheme.accent)
        .onAppear { if link == nil { link = FarLinkRuntime.link } }
    }
}

private struct FarLinkRoot: View {
    enum Page: String, CaseIterable, Identifiable {
        case dash = "Dash", tune = "Tune", registers = "Registers", settings = "Settings"
        var id: String { rawValue }
    }

    @Environment(FardriverLink.self) private var link
    @State private var page: Page = .dash
    @State private var showConnect = false
    @State private var prompted = false

    var body: some View {
        VStack(spacing: 0) {
            Text("FarLink")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            ConnectionBar { showConnect = true }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch page {
                case .dash: FarLinkDashboardView()
                case .tune: FarLinkTuneView()
                case .registers: FarLinkRegistersView()
                case .settings: FarLinkSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showConnect) {
            ConnectSheet().environment(link).tint(FLTheme.accent)
        }
        .onAppear {
            guard !prompted else { return }
            prompted = true
            if link.state == .idle && link.settings.lastPeripheralID == nil { showConnect = true }
        }
    }
}

struct ConnectionBar: View {
    @Environment(FardriverLink.self) private var link
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                IconBadge(systemImage: "bolt.horizontal.fill", tint: dotColor, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CONTROLLER")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(link.state.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                if link.state.isLive {
                    Chip(text: String(format: "%.0f fr/s", link.framesPerSecond), systemImage: "waveform",
                         tint: link.framesPerSecond > 0 ? .green : FLTheme.warn)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .card(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch link.state {
        case .connected: link.framesPerSecond > 0 ? FLTheme.ok : FLTheme.warn
        case .demo: FLTheme.regen
        case .connecting, .scanning: FLTheme.warn
        case .failed, .bluetoothOff: FLTheme.danger
        case .idle: .gray
        }
    }
}

struct ConnectSheet: View {
    @Environment(FardriverLink.self) private var link
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if link.state.isLive {
                        Button("Disconnect", role: .destructive) {
                            link.stopDemo(); link.disconnect()
                        }
                    }
                    Button {
                        link.state == .scanning ? link.stopScan() : link.startScan()
                    } label: {
                        Label(link.state == .scanning ? "Stop scanning" : "Scan for controllers",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        link.startDemo(); dismiss()
                    } label: {
                        Label("Try demo controller", systemImage: "play.circle")
                    }
                } footer: {
                    Text("Close the official FarDriver app first — the controller's Bluetooth module only accepts one connection.")
                }

                if case .failed(let msg) = link.state {
                    Section { Text(msg).foregroundStyle(FLTheme.danger) }
                }

                Section("Nearby devices") {
                    if link.devices.isEmpty {
                        Text(link.state == .scanning ? "Looking…" : "Tap scan. Turn the controller's ignition on.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(link.devices) { d in
                        Button {
                            link.connect(d.id); dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.name).font(.body.weight(d.likelyFardriver ? .semibold : .regular))
                                    if d.likelyFardriver {
                                        Text("Looks like a FarDriver").font(.caption).foregroundStyle(FLTheme.accent)
                                    }
                                }
                                Spacer()
                                SignalBars(rssi: d.rssi)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .themedList()
            .navigationTitle("Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onDisappear { if link.state == .scanning { link.stopScan() } }
    }
}

struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let level = rssi > -60 ? 4 : rssi > -70 ? 3 : rssi > -80 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
    }
}
