import Foundation

private let checkpointQueue = DispatchQueue(label: "obraessentials.checkpoint", qos: .utility)

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
    var driver: String?
    var runType: String?
    var notes: String?

    init(run: SpeedRun) {
        driver = run.driverText.isEmpty ? nil : run.driverText
        runType = run.runTypeText.isEmpty ? nil : run.runTypeText
        notes = run.notesText.isEmpty ? nil : run.notesText
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

    struct ImportOutcome {
        var imported = 0
        var duplicates = 0
        var problems: [String] = []

        var message: String {
            var parts: [String] = []
            if imported > 0 { parts.append("Imported \(imported) run\(imported == 1 ? "" : "s").") }
            if duplicates > 0 { parts.append("\(duplicates) already here, skipped.") }
            if imported == 0 && duplicates == 0 && problems.isEmpty { parts.append("Nothing to import.") }
            if !problems.isEmpty { parts.append(problems.prefix(6).joined(separator: "\n")) }
            return parts.joined(separator: "\n")
        }
    }

    /// Imports runs from a zip saved by "Save as zip", a run CSV or a backup JSON.
    func importFile(at url: URL) async -> ImportOutcome {
        let name = url.lastPathComponent
        let parsed = await Task.detached(priority: .userInitiated) { () -> RunImport.Result in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var data: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readable in
                data = try? Data(contentsOf: readable)
            }
            guard let data else {
                return RunImport.Result(runs: [], problems: ["\(name): \(coordError?.localizedDescription ?? "the file couldn't be read")"])
            }
            return RunImport.runs(fromFile: data, fileName: name)
        }.value

        var outcome = ImportOutcome(problems: parsed.problems)
        var known = summaries
        let enc = Self.encoder
        for run in parsed.runs {
            let summary = RunSummary(run: run)
            let duplicate = known.contains {
                $0.id == run.id || (abs($0.startDate.timeIntervalSince(run.startDate)) < 1.5 && $0.sampleCount == summary.sampleCount)
            }
            if duplicate { outcome.duplicates += 1; continue }
            guard let runData = try? enc.encode(run), let sumData = try? enc.encode(summary) else {
                outcome.problems.append("\(run.name): couldn't be saved")
                continue
            }
            do {
                try runData.write(to: runURL(run.id), options: .atomic)
                try sumData.write(to: summaryURL(run.id), options: .atomic)
                known.append(summary)
                outcome.imported += 1
            } catch {
                outcome.problems.append("\(run.name): \(error.localizedDescription)")
            }
        }
        reload()
        return outcome
    }

    /// Saves the name, driver, run type and notes of a run.
    func updateDetails(_ id: UUID, _ details: RunDetails) async {
        guard var run = await load(id) else { return }
        details.apply(to: &run)
        save(run)
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    func delete(_ ids: [UUID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: runURL(id))
            try? FileManager.default.removeItem(at: summaryURL(id))
        }
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
