import SwiftUI
import ARKit
import CoreLocation
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var store = SessionStore.shared
    @StateObject private var location = LocationService.shared
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var importedLayout: ConeLayout?
    @State private var importError: String?
    @State private var resumeSession: SavedSession?
    @State private var deleteTarget: SavedSession?

    private let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private static let skidpadPreview = LayoutFactory.skidpad(SkidpadParams())
    private static let accelPreview = LayoutFactory.acceleration(AccelParams())

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdateBanner()
                    hero

                    SectionTitle(text: "New track", systemImage: "plus.circle.fill")
                    HStack(spacing: 12) {
                        NavigationLink {
                            LayoutSetupView(kind: .skidpad)
                        } label: {
                            trackTile("Skidpad", "Figure of eight", Self.skidpadPreview)
                        }
                        NavigationLink {
                            LayoutSetupView(kind: .acceleration)
                        } label: {
                            trackTile("Acceleration", "75 m straight", Self.accelPreview)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 0) {
                        Button { showImporter = true } label: {
                            row("Import CSV", "Autocross / trackdrive cone list", "doc.badge.plus")
                        }
                        Divider().overlay(Theme.stroke).padding(.leading, 52)
                        Button { showPaste = true } label: {
                            row("Paste CSV", "Paste colour, x, y rows", "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.plain)
                    .card(padding: 12)

                    if !store.sessions.isEmpty {
                        SectionTitle(text: "Saved sessions", systemImage: "clock.arrow.circlepath")
                        VStack(spacing: 10) {
                            ForEach(store.sessions) { s in
                                Button { resumeSession = s } label: { sessionRow(s) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { deleteTarget = s } label: {
                                            Label("Delete session", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        Text("Touch and hold a session to delete it.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    SectionTitle(text: "Accuracy tips", systemImage: "lightbulb.fill")
                    VStack(alignment: .leading, spacing: 12) {
                        tip("Tape the A–B baseline carefully. Everything is aligned to it.", "ruler")
                        tip("Textured tarmac tracks better than smooth, plain concrete.", "square.grid.3x3")
                        tip("Walk steadily, and re-check the ghost if tracking says Relocalising.", "figure.walk")
                        tip("Phone GPS only tags the site. It can't place cones (±3 m).", "location")
                    }
                    .card()

                    VersionFooter()
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cone Setter")
            .navigationDestination(item: $importedLayout) { layout in
                LayoutSetupView(custom: layout)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showPaste) {
                PasteCSVView { text in
                    do {
                        importedLayout = try CSVLayoutParser.parse(text, name: "Pasted track")
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
            .fullScreenCover(item: $resumeSession) { s in
                ARPlacementView(layout: s.layout, resume: s)
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog("Delete this session?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = deleteTarget { store.delete(s) }
                    deleteTarget = nil
                }
            }
            .onAppear { store.reload() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: hasLiDAR ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                Text(hasLiDAR ? "LiDAR ready" : "No LiDAR on this device")
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.2), in: Capsule())

            Text("Lay out a test track")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Tape two reference marks, then follow the ghost cones. Every cone you mark becomes a reference for the next.")
                .font(.subheadline)
                .opacity(0.92)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .bottomTrailing) {
                Theme.accentGradient
                Image(systemName: "cone.fill")
                    .font(.system(size: 130))
                    .foregroundStyle(.white.opacity(0.13))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 24, y: 28)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.3), radius: 18, y: 8)
    }

    private func trackTile(_ title: String, _ subtitle: String, _ layout: ConeLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LayoutPreview(layout: layout)
                .frame(height: 96)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text("\(subtitle) · \(layout.cones.count) cones").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 10)
    }

    private func tip(_ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func sessionRow(_ s: SavedSession) -> some View {
        let total = max(s.layout.cones.count, 1)
        return HStack(spacing: 12) {
            ProgressRing(fraction: Double(s.doneCount) / Double(total), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(.body.weight(.semibold))
                HStack(spacing: 8) {
                    Text("\(s.doneCount)/\(s.layout.cones.count) cones")
                    Text(s.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if s.hasWorldMap { Label("AR map", systemImage: "map.fill") }
                    if let d = distanceToSite(s) { Label(d, systemImage: "location.fill") }
                }
                .font(.caption2).foregroundStyle(Theme.accent)
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(Theme.accent)
        }
        .card(padding: 12)
        .contentShape(Rectangle())
    }

    private func distanceToSite(_ s: SavedSession) -> String? {
        guard let lat = s.latitude, let lon = s.longitude, let here = location.location else { return nil }
        let d = here.distance(from: CLLocation(latitude: lat, longitude: lon))
        return d < 1000 ? String(format: "%.0f m away", d) : String(format: "%.1f km away", d / 1000)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                importedLayout = try CSVLayoutParser.parse(text, name: url.deletingPathExtension().lastPathComponent)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

struct PasteCSVView: View {
    var onLoad: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = "# colour,x,y  (metres, x forward, y left)\nrefA,0,0\nrefB,20,0\nblue,0,1.5\nyellow,0,-1.5\nblue,5,1.5\nyellow,5,-1.5\n"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("One cone per row: colour, x, y. Colours: blue, yellow, orange, big_orange. Optional refA / refB rows set the taped reference points.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Paste CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Load") {
                        dismiss()
                        onLoad(text)
                    }
                }
            }
        }
    }
}
