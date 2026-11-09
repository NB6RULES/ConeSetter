import Foundation

struct RunExportImages {
    /// Heatmap track image (square PNG).
    var track: Data?
    var trackSize: (w: Int, h: Int) = (560, 560)
    var speedChart: Data?
    var accelChart: Data?
    var chartSize: (w: Int, h: Int) = (720, 320)
}

/// Builds the .xlsx export for a run: Summary (stats + images), Charts (native Excel charts),
/// Data (every sample), GPS fixes (raw), Chart data (downsampled series behind the charts).
enum RunExcelExporter {
    static let bandCount = 6

    static func workbook(run: SpeedRun, unit: SpeedUnit, images: RunExportImages = RunExportImages()) -> Data {
        let wb = XLSXWorkbook()
        wb.title = run.name
        let stats = RunAnalysis.stats(run)
        let u = unit.label
        let s = run.samples
        let frame = s.first.map { Geo.LocalFrame(lat0: $0.lat, lon0: $0.lon) }
            ?? run.fixes.first.map { Geo.LocalFrame(lat0: $0.lat, lon0: $0.lon) }
            ?? Geo.LocalFrame(lat0: 0, lon0: 0)

        // MARK: Summary
        let sum = wb.addSheet("Summary")
        sum.widths = [0: 30, 1: 16, 2: 10, 3: 3]
        sum.set(0, [.t("Cone Setter · Speed run", .title)])
        sum.set(1, [.t(run.name, .subtitle)])
        sum.set(2, [.t("Recorded", .bold), .number(excelDate(run.startDate), .dateTime)])
        sum.set(3, [.t("Data source", .bold), .t(stats.fusedFraction > 0.5 ? "GPS + IMU fusion (10 Hz)" : "GPS only")])

        var r = 5
        sum.set(r, [.t("Statistic", .header), .t("Value", .header), .t("Unit", .header)]); r += 1
        func stat(_ label: String, _ v: Double?, _ unitLabel: String, _ st: XLSXWorkbook.Style = .dp2) {
            let value: XLSXWorkbook.Cell
            if let v, v.isFinite {
                value = .number(v, st)
            } else {
                value = .text("—", .normal)
            }
            sum.set(r, [.t(label, .bold), value, .t(unitLabel)])
            r += 1
        }
        stat("Duration", stats.duration, "s", .dp1)
        sum.set(r, [.t("Duration (h:mm:ss)", .bold), .t(RunAnalysis.formatDuration(stats.duration))]); r += 1
        stat("Distance", stats.distance, "m", .dp1)
        stat("Distance", stats.distance / 1000, "km", .dp3)
        stat("Top speed", unit.convert(stats.topSpeed), u)
        stat("Top speed at", stats.topSpeedTime, "s", .dp1)
        stat("Average speed", unit.convert(stats.avgSpeed), u)
        stat("Moving average speed", unit.convert(stats.movingAvgSpeed), u)
        stat("Moving time", stats.movingTime, "s", .dp1)
        stat("Max acceleration", stats.maxAccel / Geo.g, "g", .dp3)
        stat("Max braking", stats.maxBraking / Geo.g, "g", .dp3)
        stat("Max lateral", stats.maxLateral / Geo.g, "g", .dp3)
        stat("0–100 km/h", stats.zeroTo100, "s", .dp3)
        stat("75 m from launch", stats.best75m, "s", .dp3)
        stat("75 m trap speed", stats.best75mTrapSpeed.map(unit.convert), u)
        stat("Samples", Double(stats.sampleCount), "", .dp0)
        stat("Sample rate", stats.sampleRate, "Hz", .dp1)
        stat("GPS fixes", Double(stats.fixCount), "", .dp0)

        r += 1
        sum.set(r, [.t("Speed bands (track colours)", .header), .t("From (\(u))", .header), .t("To (\(u))", .header)]); r += 1
        let bands = RunAnalysis.bands(top: stats.topSpeed, count: bandCount)
        for b in bands {
            sum.set(r, [.t("Band \(b.index + 1) · #\(HeatColor.hex(b.heat))"), .n(unit.convert(b.lower), .dp1), .n(unit.convert(b.upper), .dp1)])
            r += 1
        }
        r += 1
        for note in [
            "Sheets: Charts (native Excel charts) · Data (every sample) · GPS fixes (raw Core Location) · Chart data (series behind the charts).",
            "Coordinates are WGS84. X/Y are metres east/north of the first point.",
            "Long accel: + = speeding up. Lat accel: + = to the left. 1 g = 9.80665 m/s².",
            "75 m / 0–100 times are measured from the moment the car pulls away (0.5 m/s).",
        ] {
            sum.set(r, [.t(note, .note)])
            r += 1
        }

        var imgRow = 1
        if let png = images.track {
            sum.pictures.append(.init(png: png, name: "Track heatmap", col: 4, row: imgRow,
                                      widthPx: images.trackSize.w, heightPx: images.trackSize.h))
            imgRow += Int((Double(images.trackSize.h) / 20).rounded(.up)) + 1
        }
        if let png = images.speedChart {
            sum.pictures.append(.init(png: png, name: "Speed graph", col: 4, row: imgRow,
                                      widthPx: images.chartSize.w, heightPx: images.chartSize.h))
            imgRow += Int((Double(images.chartSize.h) / 20).rounded(.up)) + 1
        }
        if let png = images.accelChart {
            sum.pictures.append(.init(png: png, name: "Acceleration graph", col: 4, row: imgRow,
                                      widthPx: images.chartSize.w, heightPx: images.chartSize.h))
        }

        // MARK: Chart data (downsampled)
        let cd = wb.addSheet("Chart data")
        cd.freezeRows = 1
        let idx = RunAnalysis.strideIndices(count: s.count, max: 3000)
        cd.set(0, [.t("Time (s)", .header), .t("Speed (\(u))", .header), .t("Long accel (g)", .header),
                   .t("Lat accel (g)", .header), .t("Distance (m)", .header)])
        var tVals: [Double] = [], vVals: [Double] = [], aLong: [Double] = [], aLat: [Double] = [], dVals: [Double] = []
        let smoothLong = RunAnalysis.movingAverage(s.map(\.longAccel), stats.sampleRate > 5 ? 3 : 1)
        let smoothLat = RunAnalysis.movingAverage(s.map(\.latAccel), stats.sampleRate > 5 ? 3 : 1)
        for (k, i) in idx.enumerated() {
            let t = round3(s[i].t)
            let v = round3(unit.convert(s[i].speed))
            let al = round4(smoothLong[i] / Geo.g)
            let at = round4(smoothLat[i] / Geo.g)
            let d = round3(s[i].distance)
            tVals.append(t); vVals.append(v); aLong.append(al); aLat.append(at); dVals.append(d)
            cd.set(k + 1, [.n(t, .dp3), .n(v, .dp2), .n(al, .dp3), .n(at, .dp3), .n(d, .dp2)])
        }
        cd.widths = [0: 10, 1: 12, 2: 13, 3: 13, 4: 13]

        // Track points split into speed bands, two columns (X, Y) per band.
        let trackIdx = RunAnalysis.strideIndices(count: s.count, max: 5000)
        var bandX = Array(repeating: [Double](), count: bandCount)
        var bandY = Array(repeating: [Double](), count: bandCount)
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for i in trackIdx {
            let p = frame.xy(s[i].lat, s[i].lon)
            let b = RunAnalysis.bandIndex(speed: s[i].speed, top: stats.topSpeed, count: bandCount)
            bandX[b].append(round3(p.x))
            bandY[b].append(round3(p.y))
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let bandCol0 = 6
        for b in 0..<bandCount {
            let cx = bandCol0 + 2 * b
            let range = "\(fmt1(unit.convert(bands[b].lower)))–\(fmt1(unit.convert(bands[b].upper))) \(u)"
            cd.set(0, cx, .t("Band \(b + 1) X (m) · \(range)", .header))
            cd.set(0, cx + 1, .t("Band \(b + 1) Y (m)", .header))
            cd.widths[cx] = 12
            cd.widths[cx + 1] = 12
            for (k, xv) in bandX[b].enumerated() {
                cd.set(k + 1, cx, .n(xv, .dp2))
                cd.set(k + 1, cx + 1, .n(bandY[b][k], .dp2))
            }
        }

        // MARK: Charts
        let ch = wb.addSheet("Charts")
        ch.widths = [0: 2]
        ch.set(0, [.empty, .t("Charts use the 'Chart data' sheet. Track: X/Y metres from the start, coloured by speed band.", .note)])
        let last = max(idx.count, 1)
        func ref(_ col: Int) -> XLSXWorkbook.Ref { .init(sheet: "Chart data", col: col, firstRow: 1, lastRow: last) }
        let tMax = tVals.last.map { $0 > 0 ? $0 : 1 } ?? 1

        ch.charts.append(.init(
            title: "Speed vs time", xTitle: "Time (s)", yTitle: "Speed (\(u))",
            series: [.init(name: "Speed (\(u))", x: ref(0), y: ref(1), xValues: tVals, yValues: vVals, colorHex: "FF6A12", lineWidthPt: 2)],
            xMin: 0, xMax: tMax, yMin: 0, legend: false, col: 1, row: 2, widthPx: 960, heightPx: 380))
        ch.charts.append(.init(
            title: "Acceleration vs time", xTitle: "Time (s)", yTitle: "Acceleration (g)",
            series: [
                .init(name: "Longitudinal (g)", x: ref(0), y: ref(2), xValues: tVals, yValues: aLong, colorHex: "1F77FF", lineWidthPt: 1.5),
                .init(name: "Lateral (g)", x: ref(0), y: ref(3), xValues: tVals, yValues: aLat, colorHex: "21B573", lineWidthPt: 1.5),
            ],
            xMin: 0, xMax: tMax, col: 1, row: 22, widthPx: 960, heightPx: 380))
        ch.charts.append(.init(
            title: "Speed vs distance", xTitle: "Distance (m)", yTitle: "Speed (\(u))",
            series: [.init(name: "Speed (\(u))", x: ref(4), y: ref(1), xValues: dVals, yValues: vVals, colorHex: "C2185B", lineWidthPt: 2)],
            xMin: 0, xMax: max(dVals.last ?? 1, 1), yMin: 0, legend: false, col: 1, row: 42, widthPx: 960, heightPx: 380))

        var trackSeries: [XLSXWorkbook.Series] = []
        for b in 0..<bandCount where !bandX[b].isEmpty {
            let cx = bandCol0 + 2 * b
            let n = bandX[b].count
            trackSeries.append(.init(
                name: "\(fmt1(unit.convert(bands[b].lower)))–\(fmt1(unit.convert(bands[b].upper))) \(u)",
                x: .init(sheet: "Chart data", col: cx, firstRow: 1, lastRow: n),
                y: .init(sheet: "Chart data", col: cx + 1, firstRow: 1, lastRow: n),
                xValues: bandX[b], yValues: bandY[b], colorHex: HeatColor.hex(bands[b].heat), markerSize: 4))
        }
        if !trackSeries.isEmpty, minX.isFinite {
            // Equal scales on both axes so the track isn't distorted.
            let span = max(maxX - minX, maxY - minY, 10) * 1.08 / 2
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            let step = niceStep(span * 2)
            ch.charts.append(.init(
                title: "Track · path travelled (coloured by speed)", xTitle: "East (m)", yTitle: "North (m)",
                series: trackSeries, markersOnly: true,
                xMin: floor((cx - span) / step) * step, xMax: ceil((cx + span) / step) * step,
                yMin: floor((cy - span) / step) * step, yMax: ceil((cy + span) / step) * step,
                col: 1, row: 62, widthPx: 760, heightPx: 760))
        }

        // MARK: Data (every sample)
        let data = wb.addSheet("Data")
        data.freezeRows = 1
        let headers = ["Time", "Elapsed (s)", "Latitude", "Longitude", "Altitude (m)", "Speed (\(u))", "Speed (m/s)",
                       "Long accel (m/s²)", "Lat accel (m/s²)", "Long accel (g)", "Lat accel (g)", "Distance (m)",
                       "X east (m)", "Y north (m)", "Heading (°)", "GPS accuracy (m)", "Source"]
        data.set(0, headers.map { .t($0, .header) })
        data.widths = [0: 23, 1: 11, 2: 13, 3: 13, 4: 11, 5: 11, 6: 11, 7: 14, 8: 14, 9: 12, 10: 12, 11: 12, 12: 11, 13: 11, 14: 11, 15: 14, 16: 8]
        let start = run.startDate.timeIntervalSince1970
        let tz = Double(TimeZone.current.secondsFromGMT(for: run.startDate))
        for (i, p) in s.enumerated() {
            let xy = frame.xy(p.lat, p.lon)
            data.set(i + 1, [
                .number((start + p.t + tz) / 86400 + 25569, .dateTime),
                .n(p.t, .dp3), .n(p.lat, .dp7), .n(p.lon, .dp7), .n(p.alt, .dp1),
                .n(unit.convert(p.speed), .dp2), .n(p.speed, .dp3),
                .n(p.longAccel, .dp3), .n(p.latAccel, .dp3),
                .n(p.longAccel / Geo.g, .dp3), .n(p.latAccel / Geo.g, .dp3),
                .n(p.distance, .dp2), .n(xy.x, .dp2), .n(xy.y, .dp2),
                .n(p.heading, .dp1), .n(p.hAcc, .dp1), .t(p.fused ? "fused" : "gps"),
            ])
        }

        // MARK: GPS fixes
        let gps = wb.addSheet("GPS fixes")
        gps.freezeRows = 1
        gps.set(0, ["Time", "Elapsed (s)", "Latitude", "Longitude", "Altitude (m)", "H accuracy (m)", "V accuracy (m)",
                    "Speed (m/s)", "Speed (\(u))", "Speed accuracy (m/s)", "Course (°)", "Course accuracy (°)"].map { .t($0, .header) })
        gps.widths = [0: 23, 1: 11, 2: 13, 3: 13, 4: 11, 5: 13, 6: 13, 7: 11, 8: 11, 9: 16, 10: 10, 11: 16]
        for (i, f) in run.fixes.enumerated() {
            gps.set(i + 1, [
                .number((start + f.t + tz) / 86400 + 25569, .dateTime),
                .n(f.t, .dp3), .n(f.lat, .dp7), .n(f.lon, .dp7), .n(f.alt, .dp1),
                .n(f.hAcc, .dp1), .n(f.vAcc, .dp1),
                f.speed >= 0 ? .n(f.speed, .dp3) : .empty,
                f.speed >= 0 ? .n(unit.convert(f.speed), .dp2) : .empty,
                f.speedAcc >= 0 ? .n(f.speedAcc, .dp2) : .empty,
                f.course >= 0 ? .n(f.course, .dp1) : .empty,
                f.courseAcc >= 0 ? .n(f.courseAcc, .dp1) : .empty,
            ])
        }

        return wb.data()
    }

    // MARK: - Other formats

    static func csv(run: SpeedRun, unit: SpeedUnit) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["time_utc,elapsed_s,lat,lon,alt_m,speed_\(unit.rawValue),speed_ms,long_accel_ms2,lat_accel_ms2,distance_m,heading_deg,gps_acc_m,source"]
        for p in run.samples {
            let date = run.startDate.addingTimeInterval(p.t)
            lines.append([
                iso.string(from: date),
                String(format: "%.3f", p.t),
                String(format: "%.8f", p.lat), String(format: "%.8f", p.lon), String(format: "%.1f", p.alt),
                String(format: "%.2f", unit.convert(p.speed)), String(format: "%.3f", p.speed),
                String(format: "%.3f", p.longAccel), String(format: "%.3f", p.latAccel),
                String(format: "%.2f", p.distance), String(format: "%.1f", p.heading),
                String(format: "%.1f", p.hAcc), p.fused ? "fused" : "gps",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func gpx(run: SpeedRun) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Cone Setter\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        x += "<trk><name>\(run.name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</name><trkseg>\n"
        for p in run.samples {
            x += String(format: "<trkpt lat=\"%.8f\" lon=\"%.8f\"><ele>%.1f</ele>", p.lat, p.lon, p.alt)
            x += "<time>\(iso.string(from: run.startDate.addingTimeInterval(p.t)))</time>"
            x += String(format: "<extensions><speed>%.3f</speed></extensions></trkpt>\n", p.speed)
        }
        x += "</trkseg></trk>\n</gpx>\n"
        return x
    }

    // MARK: - Helpers

    static func excelDate(_ d: Date) -> Double {
        let tz = Double(TimeZone.current.secondsFromGMT(for: d))
        return (d.timeIntervalSince1970 + tz) / 86400 + 25569
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    private static func fmt1(_ v: Double) -> String { String(format: "%.0f", v) }

    private static func niceStep(_ range: Double) -> Double {
        let raw = max(range, 1) / 8
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        let nice: Double = n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10
        return nice * mag
    }
}
