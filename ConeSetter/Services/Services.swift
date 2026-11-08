import Foundation
import ARKit
import CoreLocation
import UIKit

// MARK: - Saved sessions

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [SavedSession] = []
    private let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedSession.self, from: data)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ session: SavedSession, worldMapData: Data?) {
        var s = session
        let mapURL = dir.appendingPathComponent("\(s.id.uuidString).worldmap")
        if let data = worldMapData {
            try? data.write(to: mapURL, options: .atomic)
            s.hasWorldMap = true
        } else {
            s.hasWorldMap = FileManager.default.fileExists(atPath: mapURL.path)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s) {
            try? data.write(to: dir.appendingPathComponent("\(s.id.uuidString).json"), options: .atomic)
        }
        reload()
    }

    func worldMap(for id: UUID) -> ARWorldMap? {
        let url = dir.appendingPathComponent("\(id.uuidString).worldmap")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func delete(_ session: SavedSession) {
        for ext in ["json", "worldmap"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(session.id.uuidString).\(ext)"))
        }
        reload()
    }
}

// MARK: - Phone GPS (site tag only — not precise enough to place cones)

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published private(set) var location: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.location = last }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Haptics

@MainActor
enum Haptics {
    private static let notify = UINotificationFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func success() { notify.notificationOccurred(.success) }
    static func warning() { notify.notificationOccurred(.warning) }
    static func error() { notify.notificationOccurred(.error) }
    static func tick() { light.impactOccurred() }
    static func tap() { rigid.impactOccurred() }
}

// MARK: - Formatting

enum Fmt {
    static func distance(_ m: Double) -> String {
        m >= 1 ? String(format: "%.1f m", m) : String(format: "%.0f cm", m * 100)
    }

    static func cm(_ m: Double) -> String {
        let v = abs(m) * 100
        return v < 10 ? String(format: "%.1f cm", v) : String(format: "%.0f cm", v)
    }

    static func metres(_ m: Double) -> String { String(format: "%.2f m", m) }
}
