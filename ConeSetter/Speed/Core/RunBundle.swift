import Foundation

/// The editable labels of a run: name, driver, run type and free notes.
struct RunDetails: Equatable {
    var name: String
    var driver: String
    var runType: String
    var notes: String

    init(name: String, driver: String = "", runType: String = "", notes: String = "") {
        self.name = name
        self.driver = driver
        self.runType = runType
        self.notes = notes
    }

    init(run: SpeedRun) {
        self.init(name: run.name, driver: run.driverText, runType: run.runTypeText, notes: run.notesText)
    }

    func apply(to run: inout SpeedRun) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { run.name = n }
        let d = driver.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = runType.trimmingCharacters(in: .whitespacesAndNewlines)
        run.driver = d.isEmpty ? nil : d
        run.runType = t.isEmpty ? nil : t
        run.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RunExportFormat: String, CaseIterable {
    case xlsx, csv, gpx
}

/// Packs the exports of several runs into one .zip, with a Runs.csv index of every run.
enum RunBundle {
    struct File {
        var name: String
        var data: Data
    }

    /// File name (no extension) for a run: its name, then driver and run type when set.
    static func fileBase(_ run: SpeedRun) -> String {
        var parts = [run.name]
        if !run.driverText.isEmpty { parts.append(run.driverText) }
        if !run.runTypeText.isEmpty { parts.append(run.runTypeText) }
        return sanitize(parts.joined(separator: " - "))
    }

    static func sanitize(_ s: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "·", "?", "*", "\"", "<", ">", "|"]
        var out = String(s.map { bad.contains($0) || $0.isNewline ? "-" : $0 })
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        while out.contains("- -") { out = out.replacingOccurrences(of: "- -", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if out.count > 90 { out = String(out.prefix(90)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Run" : out
    }

    /// Returns `base`, or `base (2)`, `base (3)`… when that name is already taken (case-insensitive).
    static func uniqueName(_ base: String, taken: inout Set<String>) -> String {
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) (\(n))"
            n += 1
        }
        taken.insert(name.lowercased())
        return name
    }

    /// One row per run: labels plus the headline numbers. `files` are the file bases used in the zip.
    static func indexCSV(runs: [SpeedRun], files: [String], unit: SpeedUnit) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [[
            "file", "name", "recorded_local", "driver", "run_type", "notes",
            "duration_s", "distance_m", "top_speed_\(unit.rawValue)", "avg_speed_\(unit.rawValue)",
            "max_accel_g", "max_braking_g", "max_lateral_g", "zero_to_100_kmh_s", "75m_s", "source",
        ].joined(separator: ",")]
        for (i, run) in runs.enumerated() {
            let st = RunAnalysis.stats(run)
            func opt(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "" }
            lines.append([
                field(i < files.count ? files[i] : ""),
                field(run.name),
                df.string(from: run.startDate),
                field(run.driverText),
                field(run.runTypeText),
                field(run.notesText),
                String(format: "%.1f", st.duration),
                String(format: "%.1f", st.distance),
                String(format: "%.2f", unit.convert(st.topSpeed)),
                String(format: "%.2f", unit.convert(st.avgSpeed)),
                String(format: "%.3f", st.maxAccel / Geo.g),
                String(format: "%.3f", st.maxBraking / Geo.g),
                String(format: "%.3f", st.maxLateral / Geo.g),
                opt(st.zeroTo100, "%.3f"),
                opt(st.best75m, "%.3f"),
                st.fusedFraction > 0.5 ? "fused" : "gps",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting.
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func zip(_ files: [File], date: Date = Date()) -> Data {
        var z = ZipWriter(date: date)
        for f in files {
            // .xlsx is already a zip; deflating it again only costs time.
            z.add(f.name, f.data, compress: !f.name.lowercased().hasSuffix(".xlsx"))
        }
        return z.finish()
    }
}
