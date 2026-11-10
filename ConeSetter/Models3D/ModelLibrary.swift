import Foundation
import UIKit

/// How the app can handle a file, judged by its extension.
enum ModelKind: Equatable {
    /// Opens in the built-in viewer.
    case viewable(String)
    /// Closed vendor format: app name, format name, how to export something we can read.
    case proprietary(app: String, format: String, export: String)
    case unknown

    static let viewable: [String: String] = [
        "step": "STEP", "stp": "STEP", "iges": "IGES", "igs": "IGES", "brep": "OpenCascade BREP", "brp": "OpenCascade BREP",
        "fcstd": "FreeCAD", "3dm": "Rhino 3DM", "dxf": "DXF drawing",
        "stl": "STL", "obj": "Wavefront OBJ", "ply": "PLY", "off": "OFF", "3mf": "3MF", "amf": "AMF",
        "gltf": "glTF", "glb": "glTF binary", "fbx": "FBX", "dae": "Collada", "3ds": "3D Studio", "wrl": "VRML", "bim": "dotbim",
    ]

    static func of(extension ext: String) -> ModelKind {
        let e = ext.lowercased()
        if let name = viewable[e] { return .viewable(name) }
        let stepSW = "File › Save As › choose STEP AP214 (*.step)"
        switch e {
        case "sldprt", "sldasm", "slddrw":
            return .proprietary(app: "SolidWorks", format: e == "sldasm" ? "SolidWorks assembly" : e == "slddrw" ? "SolidWorks drawing" : "SolidWorks part",
                                export: e == "slddrw" ? "File › Save As › choose DXF (*.dxf)" : stepSW)
        case "catpart", "catproduct", "cgr", "catdrawing":
            return .proprietary(app: "CATIA", format: "CATIA V5 file", export: "File › Save As › type: stp")
        case "f3d", "f3z":
            return .proprietary(app: "Fusion", format: "Fusion archive", export: "File › Export › type: STEP (*.step)")
        case "ipt", "iam":
            return .proprietary(app: "Inventor", format: "Inventor file", export: "File › Export › CAD Format › STEP")
        case "prt", "asm":
            return .proprietary(app: "NX or Creo", format: "NX / Creo file",
                                export: "NX: File › Export › STEP.  Creo: File › Save As › Save a Copy › STEP")
        case "par", "psm":
            return .proprietary(app: "Solid Edge", format: "Solid Edge file", export: "Save As › STEP (*.stp)")
        case "x_t", "x_b", "xmt_txt", "xmt_bin":
            return .proprietary(app: "your CAD program", format: "Parasolid file", export: "Open it in your CAD program and save as STEP")
        case "sat", "sab":
            return .proprietary(app: "your CAD program", format: "ACIS file", export: "Open it in your CAD program and save as STEP")
        case "dwg":
            return .proprietary(app: "AutoCAD", format: "DWG drawing", export: "Save As › AutoCAD DXF (*.dxf), ASCII")
        case "jt":
            return .proprietary(app: "your CAD program", format: "JT file", export: "Export as STEP from NX or Teamcenter")
        case "skp":
            return .proprietary(app: "SketchUp", format: "SketchUp model", export: "File › Export › 3D Model › OBJ, STL or glTF")
        case "blend":
            return .proprietary(app: "Blender", format: "Blender file", export: "File › Export › glTF 2.0 (.glb)")
        case "3dxml":
            return .proprietary(app: "CATIA / 3DEXPERIENCE", format: "3DXML file", export: "Export as STEP")
        default:
            return .unknown
        }
    }

    var isViewable: Bool {
        if case .viewable = self { return true }
        return false
    }
}

struct ModelInfo: Codable, Equatable {
    var vertices = 0
    var triangles = 0
    var lines = 0
    var meshes = 0
    var materials = 0
    var unit = ""
    var size: [Double] = []
    var flat = false
    var skipped: [String: Int] = [:]

    init() {}

    init(dictionary d: [String: Any]) {
        func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        vertices = int("vertices")
        triangles = int("triangles")
        lines = int("lines")
        meshes = int("meshes")
        materials = int("materials")
        unit = d["unit"] as? String ?? ""
        size = (d["size"] as? [NSNumber])?.map(\.doubleValue) ?? []
        flat = (d["flat"] as? NSNumber)?.boolValue ?? false
        if let s = d["dxfSkipped"] as? [String: NSNumber] { skipped = s.mapValues(\.intValue) }
    }

    var sizeText: String? {
        guard size.count == 3 else { return nil }
        let u = unit.isEmpty ? "" : " \(unit)"
        func f(_ v: Double) -> String {
            let a = abs(v)
            return a >= 1000 ? String(format: "%.0f", v) : a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        }
        return "\(f(size[0])) × \(f(size[1])) × \(f(size[2]))\(u)"
    }
}

struct ModelItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let added: Date
    let bytes: Int

    var name: String { fileURL.lastPathComponent }
    var ext: String { fileURL.pathExtension.lowercased() }
    var kind: ModelKind { ModelKind.of(extension: ext) }
    var folder: URL { fileURL.deletingLastPathComponent() }
    var thumbnailURL: URL { folder.appendingPathComponent(".thumb.png") }
    var infoURL: URL { folder.appendingPathComponent(".info.json") }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    static func == (a: ModelItem, b: ModelItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Imported 3D files, each kept in its own folder under Documents/Models together with a
/// thumbnail and the stats the viewer reported.
@MainActor
final class ModelLibrary: ObservableObject {
    static let shared = ModelLibrary()

    @Published private(set) var items: [ModelItem] = []
    /// Bumped when a thumbnail is written, so lists refresh their images.
    @Published private(set) var thumbnailVersion = 0

    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [])) ?? []
        var out: [ModelItem] = []
        for folder in folders {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            guard let file = files.first else { continue }
            let added = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out.append(ModelItem(id: folder.lastPathComponent, fileURL: file, added: added, bytes: bytes))
        }
        items = out.sorted { $0.added > $1.added }
    }

    /// Copies a file into the library and returns its entry.
    @discardableResult
    func importFile(from url: URL) throws -> ModelItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        do {
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readable in
                do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? (copyError as NSError?) { throw e }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        reload()
        guard let item = items.first(where: { $0.id == id }) else {
            throw CocoaError(.fileReadUnknown)
        }
        return item
    }

    func delete(_ item: ModelItem) {
        try? FileManager.default.removeItem(at: item.folder)
        reload()
    }

    func saveThumbnail(_ png: Data, for item: ModelItem) {
        try? png.write(to: item.thumbnailURL, options: .atomic)
        thumbnailVersion += 1
    }

    func saveInfo(_ info: ModelInfo, for item: ModelItem) {
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: item.infoURL, options: .atomic)
        }
    }

    func info(for item: ModelItem) -> ModelInfo? {
        guard let data = try? Data(contentsOf: item.infoURL) else { return nil }
        return try? JSONDecoder().decode(ModelInfo.self, from: data)
    }

    func thumbnail(for item: ModelItem) -> UIImage? {
        UIImage(contentsOfFile: item.thumbnailURL.path)
    }
}

/// Best-effort search for a preview picture stored inside a closed CAD file. Older files keep
/// a plain PNG inside; newer ones often compress it, in which case nothing is found.
enum EmbeddedPreview {
    static func find(in url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 64 else { return nil }
        let limit = min(data.count, 80_000_000)
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let end = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        var best: UIImage?
        var bestArea: CGFloat = 0
        var from = data.startIndex
        var found = 0
        while found < 12, let start = data.range(of: signature, options: [], in: from..<data.startIndex + limit) {
            guard let stop = data.range(of: end, options: [], in: start.upperBound..<data.endIndex) else { break }
            found += 1
            if let image = UIImage(data: data.subdata(in: start.lowerBound..<stop.upperBound)) {
                let area = image.size.width * image.size.height
                if area > bestArea, image.size.width >= 48 {
                    best = image
                    bestArea = area
                }
            }
            from = stop.upperBound
        }
        return best
    }
}
