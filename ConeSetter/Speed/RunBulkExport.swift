import Foundation

/// Exports several saved runs into one .zip in the temporary folder.
@MainActor
enum RunBulkExport {
    struct Failure: LocalizedError {
        var errorDescription: String? { "None of the selected runs could be read." }
    }

    static func zip(ids: [UUID], formats: [RunExportFormat], unit: SpeedUnit, skip: IdleSkip,
                    progress: (String) -> Void) async throws -> URL {
        var files: [RunBundle.File] = []
        var runs: [SpeedRun] = []
        var bases: [String] = []
        var taken = Set<String>()

        for (i, id) in ids.enumerated() {
            progress("Exporting run \(i + 1) of \(ids.count)…")
            guard let run = await RunStore.shared.load(id) else { continue }
            let base = RunBundle.uniqueName(RunBundle.fileBase(run), taken: &taken)
            for format in formats {
                switch format {
                case .xlsx:
                    let images = await RunImageRenderer.exportImages(run: run, unit: unit, skip: skip)
                    let data = await Task.detached(priority: .userInitiated) {
                        RunExcelExporter.workbook(run: run, unit: unit, images: images, skip: skip)
                    }.value
                    files.append(.init(name: "\(base).xlsx", data: data))
                case .csv:
                    files.append(.init(name: "\(base).csv", data: Data(RunExcelExporter.csv(run: run, unit: unit).utf8)))
                case .gpx:
                    files.append(.init(name: "\(base).gpx", data: Data(RunExcelExporter.gpx(run: run).utf8)))
                }
            }
            runs.append(run)
            bases.append(base)
        }
        guard !runs.isEmpty else { throw Failure() }

        progress("Packing \(runs.count) run\(runs.count == 1 ? "" : "s")…")
        let index = RunBundle.indexCSV(runs: runs, files: bases, unit: unit)
        // UTF-8 BOM so Excel reads accented names correctly.
        files.insert(.init(name: "Runs.csv", data: Data([0xEF, 0xBB, 0xBF]) + Data(index.utf8)), at: 0)
        let packed = files
        let data = await Task.detached(priority: .userInitiated) { RunBundle.zip(packed) }.value

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HHmm"
        let name = "ConeSetter \(runs.count) run\(runs.count == 1 ? "" : "s") \(df.string(from: Date())).zip"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
