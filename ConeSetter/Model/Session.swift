import Foundation

enum ConeStatus: String, Codable {
    case pending, placed, accepted, skipped
}

struct ConeProgress: Codable, Equatable {
    var status: ConeStatus = .pending
    /// Live ARKit anchor marking where the real cone was measured (this session only).
    var anchorID: UUID?
    /// Measured position in layout coordinates, kept so a later session can restore it.
    var measuredLayout: Vec2?
}

enum OrderMode: String, Codable, CaseIterable, Identifiable {
    case nearest, sequential
    var id: String { rawValue }
    var label: String { self == .nearest ? "Nearest next" : "File order" }
}

enum MarkMode: String, Codable, CaseIterable, Identifiable {
    case tip, ground
    var id: String { rawValue }
    var label: String { self == .tip ? "Aim at cone tip" : "Aim at ground spot" }
}

struct PlacementSettings: Codable, Equatable {
    var toleranceCM: Double = 3
    var chainMode = true
    var order: OrderMode = .nearest
    var markMode: MarkMode = .tip
    var showMesh = false
    var occlusion = false
    var showAllMarkers = true
}

struct SavedSession: Codable, Identifiable {
    var id: UUID
    var name: String
    var savedAt: Date
    var layout: ConeLayout
    var progress: [Int: ConeProgress]
    var settings: PlacementSettings
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var hasWorldMap: Bool = false

    var doneCount: Int {
        progress.values.filter { $0.status == .placed || $0.status == .accepted }.count
    }
}
