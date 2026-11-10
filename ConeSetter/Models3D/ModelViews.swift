import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// App-wide navigation state: selected tab, and a 3D file handed to the app from outside.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable { case cones, speed, models }

    @Published var tab: Tab = .cones
    @Published var openItem: ModelItem?
    @Published var importError: String?

    /// Called for files opened from the Files app or a share sheet.
    func open(url: URL) {
        do {
            let item = try ModelLibrary.shared.importFile(from: url)
            tab = .models
            openItem = item
        } catch {
            tab = .models
            importError = error.localizedDescription
        }
    }
}

// MARK: - Library

struct ModelsHomeView: View {
    @ObservedObject private var library = ModelLibrary.shared
    @ObservedObject private var router = AppRouter.shared
    @State private var showImporter = false
    @State private var deleteTarget: ModelItem?
    @State private var share: ShareItem?
    @State private var showFormats = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdateBanner()
                    hero

                    if library.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 38))
                                .foregroundStyle(Theme.accent)
                            Text("No files yet").font(.headline)
                            Text("Open a STEP, STL, DXF or other 3D file. You can also share a file to Cone Setter from the Files app.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .card()
                    } else {
                        SectionTitle(text: "Files", systemImage: "folder.fill")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(library.items) { item in
                                Button { router.openItem = item } label: { tile(item) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { share = ShareItem(url: item.fileURL) } label: {
                                            Label("Share file", systemImage: "square.and.arrow.up")
                                        }
                                        Button(role: .destructive) { deleteTarget = item } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        Text("Touch and hold a file to share or delete it.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    formats
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("3D Viewer")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var last: ModelItem?
                    for url in urls {
                        do { last = try library.importFile(from: url) } catch { router.importError = error.localizedDescription }
                    }
                    if urls.count == 1, let item = last { router.openItem = item }
                case .failure(let error):
                    router.importError = error.localizedDescription
                }
            }
            .fullScreenCover(item: $router.openItem) { item in
                if item.kind.isViewable {
                    ModelViewerView(item: item)
                } else {
                    UnsupportedFormatView(item: item)
                }
            }
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .alert("Couldn't open the file", isPresented: Binding(get: { router.importError != nil }, set: { if !$0 { router.importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(router.importError ?? "")
            }
            .confirmationDialog("Delete this file from Cone Setter?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let t = deleteTarget { library.delete(t) }
                    deleteTarget = nil
                }
            } message: {
                Text("The original file in Files is not affected.")
            }
            .onAppear { library.reload() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View CAD and 3D files")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
            Text("STEP, IGES, STL, DXF, Blender, OBJ, 3MF, glTF and more, fully offline.")
                .font(.subheadline)
                .opacity(0.92)
            Button { showImporter = true } label: {
                Label("Open file", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white, in: Capsule())
                    .foregroundStyle(Theme.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                Theme.accentGradient
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.white.opacity(0.13))
                    .rotationEffect(.degrees(14))
                    .offset(x: 30, y: -26)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.3), radius: 18, y: 8)
    }

    private func tile(_ item: ModelItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 13 / 255, green: 14 / 255, blue: 17 / 255))
                if let image = library.thumbnail(for: item) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: item.kind.isViewable ? "cube" : "lock.doc")
                        .font(.system(size: 34))
                        .foregroundStyle(item.kind.isViewable ? Theme.accent : Color.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text(item.ext.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(item.kind.isViewable ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.gray), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .id(library.thumbnailVersion)

            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(padding: 10)
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { showFormats.toggle() }
            } label: {
                HStack {
                    SectionTitle(text: "Supported formats", systemImage: "checkmark.seal.fill")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showFormats ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            if showFormats {
                VStack(alignment: .leading, spacing: 12) {
                    formatRow("CAD", "STEP (.step .stp), IGES (.iges .igs), BREP, FreeCAD (.fcstd), Rhino (.3dm)")
                    formatRow("Drawings", "DXF (ASCII): lines, polylines, arcs, circles, splines, blocks, 3D faces")
                    formatRow("Mesh", "STL, OBJ, PLY, OFF, 3MF, AMF, glTF / GLB, FBX, DAE, 3DS, VRML")
                    formatRow("Blender", ".blend mesh objects with their viewport colours. Modifiers, curves and text aren't shown.")
                    Divider().overlay(Theme.stroke)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 22)
                        Text("SolidWorks (.sldprt), CATIA (.CATPart), NX / Creo (.prt), Fusion (.f3d), Inventor (.ipt) and DWG are closed formats that only their own software can read. Export a STEP (or DXF for drawings) and open that here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .card()
            }
        }
    }

    private func formatRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Viewer

struct ModelViewerView: View {
    @StateObject private var ctrl: ModelViewerController
    @Environment(\.dismiss) private var dismiss
    @State private var showInfo = false
    @State private var share: ShareItem?

    init(item: ModelItem) {
        _ctrl = StateObject(wrappedValue: ModelViewerController(item: item))
    }

    var body: some View {
        ZStack {
            Color(red: 13 / 255, green: 14 / 255, blue: 17 / 255).ignoresSafeArea()
            WebViewContainer(webView: ctrl.webView)
                .ignoresSafeArea()
                .opacity(ctrl.phase == .ready ? 1 : 0)

            switch ctrl.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Theme.accent)
                    Text("Opening \(ctrl.item.name)")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(ctrl.item.bytes > 5_000_000 ? "Large CAD files can take a minute." : "Reading geometry…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(30)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.yellow)
                    Text("Couldn't open this file").font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { ctrl.reload() }
                        .buttonStyle(FilledButtonStyle(color: Theme.accent))
                        .frame(width: 180)
                }
                .padding(30)
            case .ready:
                EmptyView()
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if ctrl.phase == .ready { controls }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showInfo) {
            ModelInfoSheet(item: ctrl.item, info: ctrl.info)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            circleButton("xmark") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(ctrl.item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = ctrl.info?.sizeText, ctrl.phase == .ready {
                    Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            circleButton("info") { showInfo = true }
            circleButton("square.and.arrow.up") { share = ShareItem(url: ctrl.item.fileURL) }
        }
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .tint(.primary)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([("Iso", "iso"), ("Front", "front"), ("Back", "back"), ("Left", "left"), ("Right", "right"), ("Top", "top"), ("Bottom", "bottom")], id: \.1) { label, key in
                        Button {
                            ctrl.setView(key)
                            Haptics.tick()
                        } label: {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                        }
                        .tint(.primary)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                toolButton("Fit", "arrow.up.left.and.arrow.down.right", active: false) { ctrl.fit() }
                toolButton("Edges", "square.dashed", active: ctrl.edges) { ctrl.edges.toggle() }
                toolButton(ctrl.orthographic ? "Ortho" : "Persp", ctrl.orthographic ? "square" : "cube", active: ctrl.orthographic) { ctrl.orthographic.toggle() }
                toolButton(ctrl.zUp ? "Z up" : "Y up", "arrow.up.to.line", active: ctrl.zUp) { ctrl.zUp.toggle() }
            }
            Text("Drag to orbit · pinch to zoom · two fingers to pan")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func toolButton(_ title: String, _ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tick()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct ModelInfoSheet: View {
    let item: ModelItem
    let info: ModelInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Name", value: item.name)
                    if case .viewable(let format) = item.kind { LabeledContent("Format", value: format) }
                    LabeledContent("Size on disk", value: item.sizeText)
                }
                if let info {
                    Section {
                        if info.size.count == 3 {
                            let u = info.unit.isEmpty ? "" : " \(info.unit)"
                            LabeledContent("X", value: String(format: "%.3f", info.size[0]) + u)
                            LabeledContent("Y", value: String(format: "%.3f", info.size[1]) + u)
                            LabeledContent("Z", value: String(format: "%.3f", info.size[2]) + u)
                        }
                    } header: {
                        Text("Overall size")
                    } footer: {
                        Text(info.unit.isEmpty
                             ? "This file doesn't state its units, so sizes are in the file's own units (usually mm)."
                             : "Bounding box along the file's own axes.")
                    }
                    Section("Geometry") {
                        if info.meshes > 0 { LabeledContent(info.flat ? "Objects" : "Bodies / parts", value: "\(info.meshes)") }
                        if info.triangles > 0 { LabeledContent("Triangles", value: info.triangles.formatted()) }
                        if info.lines > 0 { LabeledContent("Line segments", value: info.lines.formatted()) }
                        LabeledContent("Vertices", value: info.vertices.formatted())
                        if info.materials > 1 { LabeledContent("Colours / materials", value: "\(info.materials)") }
                    }
                    if !info.notes.isEmpty {
                        Section("Notes") {
                            ForEach(info.notes, id: \.self) { note in
                                Text(note).font(.subheadline)
                            }
                        }
                    }
                    if !info.skipped.isEmpty {
                        Section {
                            ForEach(info.skipped.sorted { $0.key < $1.key }, id: \.key) { key, count in
                                LabeledContent(key, value: "\(count)")
                            }
                        } header: {
                            Text("Not drawn")
                        } footer: {
                            Text("These DXF entity types (such as text and hatches) aren't shown.")
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Closed formats

struct UnsupportedFormatView: View {
    let item: ModelItem
    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?
    @State private var searched = false
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text("Preview picture saved inside the file. This is an image, not the 3D model.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .card()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            IconBadge(systemImage: "lock.doc.fill", tint: .yellow, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.headline)
                                Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .card()

                    if case .proprietary(let app, _, let export) = item.kind {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "How to view it here", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            Text("In \(app):").font(.subheadline.weight(.semibold))
                            Text(export).font(.subheadline)
                            Text("Then open the exported file in this tab. STEP keeps the exact geometry, colours and assembly structure.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .card()
                    }

                    Button { share = ShareItem(url: item.fileURL) } label: {
                        Label("Share or open in another app", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(FilledButtonStyle(color: .gray))
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Can't open directly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .task {
                guard !searched else { return }
                searched = true
                let url = item.fileURL
                let found = await Task.detached(priority: .userInitiated) { EmbeddedPreview.find(in: url) }.value
                preview = found
            }
        }
    }

    private var title: String {
        if case .proprietary(_, let format, _) = item.kind { return format }
        return ".\(item.ext) file"
    }

    private var explanation: String {
        if case .proprietary(let app, _, _) = item.kind {
            return "This is a closed format. Only \(app) (or software licensed by its maker) can read the geometry inside, so no independent viewer can open it."
        }
        return "Cone Setter doesn't recognise this file type as a 3D model. If it is one, export it as STEP, STL or OBJ and open that instead."
    }
}
