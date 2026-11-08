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

    private let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: hasLiDAR ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                                .foregroundStyle(hasLiDAR ? .green : .orange)
                            Text(hasLiDAR ? "LiDAR ready" : "No LiDAR on this device — accuracy will be lower")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("Pick a track, tape two reference marks on the ground, then follow the ghost cones. Every cone you mark becomes a reference for the next one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("New track") {
                    NavigationLink {
                        LayoutSetupView(kind: .skidpad)
                    } label: {
                        row("Skidpad", "Figure of eight · 15.25 m inner circles", "infinity")
                    }
                    NavigationLink {
                        LayoutSetupView(kind: .acceleration)
                    } label: {
                        row("Acceleration", "75 m straight + stop area", "arrow.right.to.line")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        row("Import CSV", "Autocross / trackdrive cone list", "doc.badge.plus")
                    }
                    Button {
                        showPaste = true
                    } label: {
                        row("Paste CSV", "Paste x, y, colour rows", "doc.on.clipboard")
                    }
                }

                if !store.sessions.isEmpty {
                    Section("Saved sessions") {
                        ForEach(store.sessions) { s in
                            Button {
                                resumeSession = s
                            } label: {
                                sessionRow(s)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { store.delete(store.sessions[i]) }
                        }
                    }
                }

                Section("Accuracy tips") {
                    Label("Tape the A–B baseline carefully — everything is aligned to it.", systemImage: "ruler")
                    Label("Textured tarmac tracks better than smooth, plain concrete.", systemImage: "square.grid.3x3")
                    Label("Walk steadily; re-check the ghost when tracking says 'Relocalising'.", systemImage: "figure.walk")
                    Label("Phone GPS only tags the site. It can't place cones (±3 m).", systemImage: "location")
                }
                .font(.footnote)
            }
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
            .onAppear { store.reload() }
        }
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func sessionRow(_ s: SavedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(s.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Text("\(s.doneCount)/\(s.layout.cones.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(s.savedAt.formatted(date: .abbreviated, time: .shortened))
                if s.hasWorldMap { Label("AR map", systemImage: "map").labelStyle(.titleAndIcon) }
                if let d = distanceToSite(s) { Text(d) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
