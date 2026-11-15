import Foundation

/// Rebuilds runs from the files the app exports: a zip from "Save as zip", a single run CSV,
/// or a full-backup JSON. Excel and GPX files are for reading elsewhere and are not imported.
enum RunImport {
    struct Result {
        var runs: [SpeedRun] = []
        var problems: [String] = []
    }

    enum ImportError: LocalizedError {
        case notARun(String)

        var errorDescription: String? {
            switch self {
            case .notARun(let why): return why
            }
        }
    }

    // MARK: Entry points

    static func runs(fromFile data: Data, fileName: String) -> Result {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        var result = Result()
        do {
            switch ext {
            case "zip":
                return try runs(fromZip: data)
            case "csv":
                result.runs = [try run(fromCSV: String(decoding: data, as: UTF8.self), name: base)]
            case "json":
                result.runs = [try run(fromJSON: data)]
            default:
                result.problems = ["\(fileName): choose a .zip saved from the GPS tab, a run .csv or a backup .json."]
            }
        } catch {
            result.problems = ["\(fileName): \(error.localizedDescription)"]
        }
        return result
    }

    static func runs(fromZip data: Data) throws -> Result {
        let zip = try ZipReader(data)
        var result = Result()
        var members: [String: [String: ZipReader.Entry]] = [:]
        var order: [String] = []
        var index: [String: [String: String]] = [:]

        for e in zip.entries where !e.isDirectory {
            let file = (e.name as NSString).lastPathComponent
            if file.hasPrefix(".") || e.name.contains("__MACOSX") { continue }
            let ext = (file as NSString).pathExtension.lowercased()
            let base = (file as NSString).deletingPathExtension
            if file.lowercased() == "runs.csv" {
                if let d = try? zip.read(e) { index = parseIndex(String(decoding: d, as: UTF8.self)) }
            } else if ["json", "csv", "xlsx", "gpx"].contains(ext) {
                if members[base] == nil { order.append(base) }
                members[base, default: [:]][ext] = e
            }
        }
        if order.isEmpty { throw ImportError.notARun("There are no runs in this zip.") }

        for base in order {
            let exts = members[base] ?? [:]
            do {
                var run: SpeedRun
                if let e = exts["json"] {
                    run = try self.run(fromJSON: try zip.read(e))
                } else if let e = exts["csv"] {
                    run = try self.run(fromCSV: String(decoding: try zip.read(e), as: UTF8.self), name: base)
                } else {
                    result.problems.append("\(base): only Excel or GPX in the zip. Save it again as CSV or as a full backup to import it.")
                    continue
                }
                if let row = index[base] {
                    RunDetails(name: row["name"] ?? run.name, driver: row["driver"] ?? run.driverText,
                               runType: row["run_type"] ?? run.runTypeText,
                               notes: (row["notes"] ?? "").isEmpty ? run.notesText : (row["notes"] ?? "")).apply(to: &run)
                }
                result.runs.append(run)
            } catch {
                result.problems.append("\(base): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func run(fromJSON data: Data) throws -> SpeedRun {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let run = try? dec.decode(SpeedRun.self, from: data), run.samples.count >= 2 else {
            throw ImportError.notARun("not a run backup")
        }
        return run
    }

    /// A run CSV as written by `RunExcelExporter.csv`. Raw GPS fixes and barometer readings are not
    /// in the CSV, so the imported run has the processed samples only.
    static func run(fromCSV text: String, name: String) throws -> SpeedRun {
        let rows = parseCSV(text)
        guard let header = rows.first, rows.count >= 3 else { throw ImportError.notARun("no samples") }
        var col: [String: Int] = [:]
        for (i, h) in header.enumerated() { col[h.trimmingCharacters(in: .whitespaces).lowercased()] = i }
        guard let cT = col["elapsed_s"], let cLat = col["lat"], let cLon = col["lon"] else {
            throw ImportError.notARun("not a run CSV (needs elapsed_s, lat and lon columns)")
        }
        let cAlt = col["alt_m"], cSpeed = col["speed_ms"], cLong = col["long_accel_ms2"], cLatAcc = col["lat_accel_ms2"]
        let cDist = col["distance_m"], cHead = col["heading_deg"], cAcc = col["gps_acc_m"], cSrc = col["source"]
        let cKmh = col["speed_kmh"], cMph = col["speed_mph"]

        func num(_ row: [String], _ i: Int?) -> Double? {
            guard let i, i < row.count else { return nil }
            return Double(row[i].trimmingCharacters(in: .whitespaces))
        }

        var samples: [SpeedSample] = []
        samples.reserveCapacity(rows.count - 1)
        var lastT = -Double.infinity
        for row in rows.dropFirst() {
            guard let t = num(row, cT), let lat = num(row, cLat), let lon = num(row, cLon),
                  t.isFinite, lat.isFinite, lon.isFinite, t > lastT else { continue }
            let speed = num(row, cSpeed) ?? num(row, cKmh).map { $0 / 3.6 } ?? num(row, cMph).map { $0 / 2.2369362921 } ?? 0
            var fused = false
            if let cSrc, cSrc < row.count { fused = row[cSrc].trimmingCharacters(in: .whitespaces) == "fused" }
            samples.append(SpeedSample(t: t, lat: lat, lon: lon, alt: num(row, cAlt) ?? 0, speed: speed,
                                       longAccel: num(row, cLong) ?? 0, latAccel: num(row, cLatAcc) ?? 0,
                                       heading: num(row, cHead) ?? 0, distance: num(row, cDist) ?? 0,
                                       hAcc: num(row, cAcc) ?? 0, fused: fused))
            lastT = t
        }
        guard samples.count >= 2 else { throw ImportError.notARun("no usable samples") }

        var start = Date()
        if let cTime = col["time_utc"], let first = rows.dropFirst().first, cTime < first.count,
           let t0 = num(first, cT) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            let s = first[cTime].trimmingCharacters(in: .whitespaces)
            if let d = iso.date(from: s) ?? plain.date(from: s) { start = d.addingTimeInterval(-t0) }
        }
        return SpeedRun(id: UUID(), name: name, startDate: start, samples: samples, fixes: [],
                        imuUsed: samples.contains { $0.fused })
    }

    // MARK: CSV

    /// The Runs.csv index, keyed by the "file" column.
    static func parseIndex(_ text: String) -> [String: [String: String]] {
        let rows = parseCSV(text)
        guard let header = rows.first, let fileCol = header.firstIndex(of: "file") else { return [:] }
        var out: [String: [String: String]] = [:]
        for row in rows.dropFirst() where fileCol < row.count && !row[fileCol].isEmpty {
            var d: [String: String] = [:]
            for (i, h) in header.enumerated() where i < row.count { d[h] = row[i] }
            out[row[fileCol]] = d
        }
        return out
    }

    /// RFC 4180 parser: quoted fields, doubled quotes, commas and line breaks inside quotes. Skips a BOM.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var fieldStarted = false
        let bytes = Array(text.utf8)
        var i = bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")

        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            fieldStarted = false
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while i < bytes.count {
            let c = bytes[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote { field.append(quote); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == quote, !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if c == comma {
                endField()
            } else if c == lf {
                endRow()
            } else if c == cr {
                if i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
                endRow()
            } else {
                field.append(c)
                fieldStarted = true
            }
            i += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
