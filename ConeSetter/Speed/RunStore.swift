import Foundation

private let checkpointQueue = DispatchQueue(label: "conesetter.checkpoint", qos: .utility)

struct RunSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var startDate: Date
    var duration: Double
    var distance: Double
    var topSpeed: Double
    var avgSpeed: Double
    var fused: Bool
    var sampleCount: Int

    init(run: SpeedRun) {
        let s = RunAnalysis.stats(run)
        id = run.id
        name = run.name
        startDate = run.startDate
        duration = s.duration
        distance = s.distance
        topSpeed = s.topSpeed
        avgSpeed = s.avgSpeed
        fused = s.fusedFraction > 0.5
        sampleCount = s.sampleCount
    }
}

/// Saves runs as JSON (full data) plus a small summary file for the list.
@MainActor
final class RunStore: ObservableObject {
    static let shared = RunStore()

    @Published private(set) var summaries: [RunSummary] = []
    nonisolated let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("SpeedRuns", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let dec = Self.decoder
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        summaries = files
            .filter { $0.lastPathComponent.hasSuffix(".summary.json") }
            .compactMap { try? dec.decode(RunSummary.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startDate > $1.startDate }
    }

    func save(_ run: SpeedRun) {
        let enc = Self.encoder
        if let data = try? enc.encode(run) {
            try? data.write(to: runURL(run.id), options: .atomic)
        }
        if let data = try? enc.encode(RunSummary(run: run)) {
            try? data.write(to: summaryURL(run.id), options: .atomic)
        }
        reload()
    }

    func rename(_ id: UUID, to name: String) async {
        guard var run = await load(id) else { return }
        run.name = name
        save(run)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: runURL(id))
        try? FileManager.default.removeItem(at: summaryURL(id))
        reload()
    }

    nonisolated func load(_ id: UUID) async -> SpeedRun? {
        let url = runURL(id)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? RunStore.decoder.decode(SpeedRun.self, from: data)
        }.value
    }

    // MARK: Crash recovery checkpoint

    nonisolated var checkpointURL: URL { dir.appendingPathComponent("in-progress.checkpoint") }

    /// Checkpoint writes and clears run in order on one queue, so a write that was still
    /// in flight can never land after the run has been saved and the checkpoint cleared.

    nonisolated func writeCheckpoint(_ run: SpeedRun) {
        let url = checkpointURL
        checkpointQueue.async {
            if let data = try? RunStore.encoder.encode(run) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    nonisolated func clearCheckpoint() {
        let url = checkpointURL
        checkpointQueue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Turns a checkpoint left behind by a crash or a killed app into a saved run.
    func recoverCheckpoint() -> Bool {
        guard let data = try? Data(contentsOf: checkpointURL),
              var run = try? Self.decoder.decode(SpeedRun.self, from: data) else { return false }
        clearCheckpoint()
        guard run.samples.count > 2 else { return false }
        run.samples = RunPostProcessor.process(samples: run.samples, fixes: run.fixes)
        run.name += " (recovered)"
        save(run)
        return true
    }

    nonisolated private func runURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).run.json") }
    nonisolated private func summaryURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).summary.json") }

    nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
