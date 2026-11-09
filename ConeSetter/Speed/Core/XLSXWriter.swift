import Foundation

/// Small SpreadsheetML (.xlsx) writer: styled cells, frozen headers, column widths,
/// native scatter charts (with cached values) and embedded PNG images.
final class XLSXWorkbook {
    enum Style: Int {
        case normal = 0, header, dateTime, dp2, dp7, dp1, title, note, dp3, bold, subtitle, dp0
    }

    enum Cell {
        case empty
        case text(String, Style)
        case number(Double, Style)

        static func t(_ s: String, _ st: Style = .normal) -> Cell { .text(s, st) }
        static func n(_ v: Double, _ st: Style = .dp2) -> Cell { v.isFinite ? .number(v, st) : .empty }
        static func n(_ v: Double?, _ st: Style = .dp2) -> Cell { v.map { n($0, st) } ?? .empty }
    }

    struct Ref {
        var sheet: String
        var col: Int
        var firstRow: Int
        var lastRow: Int

        var formula: String {
            let s = "'" + sheet.replacingOccurrences(of: "'", with: "''") + "'"
            let c = XLSXWorkbook.colName(col)
            return "\(s)!$\(c)$\(firstRow + 1):$\(c)$\(lastRow + 1)"
        }
    }

    struct Series {
        var name: String
        var x: Ref
        var y: Ref
        var xValues: [Double]
        var yValues: [Double]
        var colorHex: String
        var lineWidthPt: Double = 1.75
        var markerSize: Int = 0
        var smooth = false
    }

    struct Chart {
        var title: String
        var xTitle: String
        var yTitle: String
        var series: [Series]
        var markersOnly = false
        var xMin: Double?
        var xMax: Double?
        var yMin: Double?
        var yMax: Double?
        var legend = true
        var col: Int
        var row: Int
        var widthPx: Int
        var heightPx: Int
    }

    struct Picture {
        var png: Data
        var name: String
        var col: Int
        var row: Int
        var widthPx: Int
        var heightPx: Int
    }

    final class Sheet {
        let name: String
        fileprivate var rows: [Int: [Cell]] = [:]
        var widths: [Int: Double] = [:]
        var freezeRows = 0
        var charts: [Chart] = []
        var pictures: [Picture] = []

        init(name: String) { self.name = name }

        func set(_ row: Int, _ cells: [Cell]) { rows[row] = cells }

        func set(_ row: Int, _ col: Int, _ cell: Cell) {
            var r = rows[row] ?? []
            if r.count <= col { r.append(contentsOf: Array(repeating: .empty, count: col - r.count + 1)) }
            r[col] = cell
            rows[row] = r
        }
    }

    private(set) var sheets: [Sheet] = []
    var title = "Workbook"
    var creator = "Cone Setter"

    func addSheet(_ name: String) -> Sheet {
        let s = Sheet(name: name)
        sheets.append(s)
        return s
    }

    // MARK: - Output

    func data() -> Data {
        var zip = ZipWriter()
        var strings: [String] = []
        var stringIndex: [String: Int] = [:]
        func sst(_ s: String) -> Int {
            if let i = stringIndex[s] { return i }
            strings.append(s)
            stringIndex[s] = strings.count - 1
            return strings.count - 1
        }

        var sheetXML: [String] = []
        var drawingParts: [(sheet: Int, drawing: Int)] = []
        var chartCount = 0
        var imageCount = 0
        var drawingFiles: [(path: String, xml: String, rels: String)] = []
        var chartFiles: [(path: String, xml: String)] = []
        var imageFiles: [(path: String, data: Data)] = []

        for (si, sheet) in sheets.enumerated() {
            var drawingID: Int?
            if !sheet.charts.isEmpty || !sheet.pictures.isEmpty {
                let d = drawingFiles.count + 1
                drawingID = d
                var anchors = ""
                var rels = ""
                var rid = 0
                var shapeID = 1
                for chart in sheet.charts {
                    chartCount += 1
                    rid += 1
                    shapeID += 1
                    chartFiles.append(("xl/charts/chart\(chartCount).xml", chartXML(chart)))
                    rels += "<Relationship Id=\"rId\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"../charts/chart\(chartCount).xml\"/>"
                    anchors += anchorXML(col: chart.col, row: chart.row, w: chart.widthPx, h: chart.heightPx, body: """
                    <xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="\(shapeID)" name="Chart \(chartCount)"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart r:id="rId\(rid)"/></a:graphicData></a:graphic></xdr:graphicFrame>
                    """)
                }
                for pic in sheet.pictures {
                    imageCount += 1
                    rid += 1
                    shapeID += 1
                    imageFiles.append(("xl/media/image\(imageCount).png", pic.png))
                    rels += "<Relationship Id=\"rId\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image\(imageCount).png\"/>"
                    let cx = pic.widthPx * 9525, cy = pic.heightPx * 9525
                    anchors += anchorXML(col: pic.col, row: pic.row, w: pic.widthPx, h: pic.heightPx, body: """
                    <xdr:pic><xdr:nvPicPr><xdr:cNvPr id="\(shapeID)" name="\(esc(pic.name))"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rId\(rid)"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>
                    """)
                }
                let drawing = xmlHeader + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">" + anchors + "</xdr:wsDr>"
                let drawingRels = xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + rels + "</Relationships>"
                drawingFiles.append(("xl/drawings/drawing\(d).xml", drawing, drawingRels))
                drawingParts.append((si, d))
            }
            sheetXML.append(worksheetXML(sheet, drawing: drawingID != nil, sst: sst))
        }

        // [Content_Types].xml
        var ct = xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        ct += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        ct += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ct += "<Default Extension=\"png\" ContentType=\"image/png\"/>"
        ct += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in sheets.indices {
            ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        ct += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        ct += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        for d in drawingFiles {
            ct += "<Override PartName=\"/\(d.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
        }
        for c in chartFiles {
            ct += "<Override PartName=\"/\(c.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"
        }
        ct += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        ct += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        ct += "</Types>"
        zip.add("[Content_Types].xml", ct)

        zip.add("_rels/.rels", xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        zip.add("docProps/core.xml", xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(esc(title))</dc:title><dc:creator>\(esc(creator))</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """)
        zip.add("docProps/app.xml", xmlHeader + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Cone Setter</Application></Properties>
        """)

        var wb = xmlHeader + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>"
        for (i, s) in sheets.enumerated() {
            wb += "<sheet name=\"\(esc(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        wb += "</sheets></workbook>"
        zip.add("xl/workbook.xml", wb)

        var wbRels = xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in sheets.indices {
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        wbRels += "<Relationship Id=\"rId\(sheets.count + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        wbRels += "</Relationships>"
        zip.add("xl/_rels/workbook.xml.rels", wbRels)
        zip.add("xl/styles.xml", stylesXML)

        for (i, xml) in sheetXML.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", xml)
        }
        for part in drawingParts {
            zip.add("xl/worksheets/_rels/sheet\(part.sheet + 1).xml.rels", xmlHeader + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing\(part.drawing).xml"/></Relationships>
            """)
        }
        for (i, d) in drawingFiles.enumerated() {
            zip.add(d.path, d.xml)
            zip.add("xl/drawings/_rels/drawing\(i + 1).xml.rels", d.rels)
        }
        for c in chartFiles { zip.add(c.path, c.xml) }
        for img in imageFiles { zip.add(img.path, img.data, compress: false) }

        var ss = xmlHeader + "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
        for s in strings { ss += "<si><t xml:space=\"preserve\">\(esc(s))</t></si>" }
        ss += "</sst>"
        zip.add("xl/sharedStrings.xml", ss)

        return zip.finish()
    }

    // MARK: - Worksheet

    private func worksheetXML(_ sheet: Sheet, drawing: Bool, sst: (String) -> Int) -> String {
        let rowKeys = sheet.rows.keys.sorted()
        let maxCol = max(1, sheet.rows.values.map(\.count).max() ?? 1)
        let lastRow = (rowKeys.last ?? 0) + 1
        var out = xmlHeader
        out.reserveCapacity(64 + rowKeys.count * 40 * maxCol)
        out += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        out += "<dimension ref=\"A1:\(Self.colName(maxCol - 1))\(lastRow)\"/>"
        if sheet.freezeRows > 0 {
            let top = "A\(sheet.freezeRows + 1)"
            out += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"\(sheet.freezeRows)\" topLeftCell=\"\(top)\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\" activeCell=\"\(top)\" sqref=\"\(top)\"/></sheetView></sheetViews>"
        } else {
            out += "<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>"
        }
        out += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        if !sheet.widths.isEmpty {
            out += "<cols>"
            for (c, w) in sheet.widths.sorted(by: { $0.key < $1.key }) {
                out += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.2f", w))\" customWidth=\"1\"/>"
            }
            out += "</cols>"
        }
        out += "<sheetData>"
        let colNames = (0..<maxCol).map { Self.colName($0) }
        for r in rowKeys {
            guard let cells = sheet.rows[r] else { continue }
            let rn = r + 1
            out += "<row r=\"\(rn)\">"
            for (c, cell) in cells.enumerated() {
                switch cell {
                case .empty:
                    continue
                case .text(let s, let st):
                    out += "<c r=\"\(colNames[c])\(rn)\" s=\"\(st.rawValue)\" t=\"s\"><v>\(sst(s))</v></c>"
                case .number(let v, let st):
                    out += "<c r=\"\(colNames[c])\(rn)\" s=\"\(st.rawValue)\"><v>\(Self.num(v, st))</v></c>"
                }
            }
            out += "</row>"
        }
        out += "</sheetData>"
        out += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        if drawing { out += "<drawing r:id=\"rId1\"/>" }
        out += "</worksheet>"
        return out
    }

    private func anchorXML(col: Int, row: Int, w: Int, h: Int, body: String) -> String {
        "<xdr:oneCellAnchor><xdr:from><xdr:col>\(col)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx=\"\(w * 9525)\" cy=\"\(h * 9525)\"/>" + body + "<xdr:clientData/></xdr:oneCellAnchor>"
    }

    // MARK: - Chart

    private func chartXML(_ chart: Chart) -> String {
        var x = xmlHeader
        x += "<c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        x += "<c:roundedCorners val=\"0\"/>"
        x += "<c:chart>"
        x += titleXML(chart.title, size: 1400)
        x += "<c:autoTitleDeleted val=\"0\"/>"
        x += "<c:plotArea><c:layout/>"
        x += "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>"
        for (i, s) in chart.series.enumerated() {
            x += "<c:ser><c:idx val=\"\(i)\"/><c:order val=\"\(i)\"/>"
            x += "<c:tx><c:v>\(esc(s.name))</c:v></c:tx>"
            if chart.markersOnly {
                x += "<c:spPr><a:ln w=\"19050\"><a:noFill/></a:ln></c:spPr>"
                x += "<c:marker><c:symbol val=\"circle\"/><c:size val=\"\(min(max(s.markerSize, 2), 72))\"/><c:spPr><a:solidFill><a:srgbClr val=\"\(s.colorHex)\"/></a:solidFill><a:ln w=\"3175\"><a:noFill/></a:ln></c:spPr></c:marker>"
            } else {
                x += "<c:spPr><a:ln w=\"\(Int(s.lineWidthPt * 12700))\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"\(s.colorHex)\"/></a:solidFill><a:round/></a:ln></c:spPr>"
                x += "<c:marker><c:symbol val=\"none\"/></c:marker>"
            }
            x += "<c:xVal>" + numRefXML(s.x, s.xValues) + "</c:xVal>"
            x += "<c:yVal>" + numRefXML(s.y, s.yValues) + "</c:yVal>"
            x += "<c:smooth val=\"\(s.smooth ? 1 : 0)\"/>"
            x += "</c:ser>"
        }
        x += "<c:axId val=\"500000001\"/><c:axId val=\"500000002\"/></c:scatterChart>"
        x += axisXML(id: 500000001, cross: 500000002, pos: "b", title: chart.xTitle, min: chart.xMin, max: chart.xMax)
        x += axisXML(id: 500000002, cross: 500000001, pos: "l", title: chart.yTitle, min: chart.yMin, max: chart.yMax)
        x += "<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>"
        x += "</c:plotArea>"
        if chart.legend {
            x += "<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend>"
        }
        x += "<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/>"
        x += "</c:chart>"
        x += "<c:spPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"D9D9D9\"/></a:solidFill></a:ln></c:spPr>"
        x += "</c:chartSpace>"
        return x
    }

    private func titleXML(_ text: String, size: Int) -> String {
        "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"\(size)\" b=\"1\"/></a:pPr><a:r><a:rPr lang=\"en-GB\" sz=\"\(size)\" b=\"1\"/><a:t>\(esc(text))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
    }

    private func axisXML(id: Int, cross: Int, pos: String, title: String, min: Double?, max: Double?) -> String {
        var x = "<c:valAx><c:axId val=\"\(id)\"/><c:scaling><c:orientation val=\"minMax\"/>"
        if let mx = max { x += "<c:max val=\"\(Self.num(mx, .normal))\"/>" }
        if let mn = min { x += "<c:min val=\"\(Self.num(mn, .normal))\"/>" }
        x += "</c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(pos)\"/>"
        x += "<c:majorGridlines><c:spPr><a:ln w=\"6350\"><a:solidFill><a:srgbClr val=\"E3E3E3\"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>"
        x += titleXML(title, size: 1000)
        x += "<c:numFmt formatCode=\"General\" sourceLinked=\"0\"/>"
        x += "<c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"low\"/>"
        x += "<c:spPr><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"8C8C8C\"/></a:solidFill></a:ln></c:spPr>"
        x += "<c:crossAx val=\"\(cross)\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"midCat\"/>"
        x += "</c:valAx>"
        return x
    }

    private func numRefXML(_ ref: Ref, _ values: [Double]) -> String {
        var x = "<c:numRef><c:f>\(esc(ref.formula))</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(values.count)\"/>"
        for (i, v) in values.enumerated() where v.isFinite {
            x += "<c:pt idx=\"\(i)\"><c:v>\(Self.num(v, .normal))</c:v></c:pt>"
        }
        x += "</c:numCache></c:numRef>"
        return x
    }

    // MARK: - Helpers

    private let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static func colName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func num(_ v: Double, _ style: Style) -> String {
        guard v.isFinite else { return "0" }
        let digits: Int
        switch style {
        case .dp7: digits = 8
        case .dateTime: digits = 9
        case .dp0: digits = 0
        default: digits = 4
        }
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    private func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                if ch.value < 0x20 && ch != "\n" && ch != "\t" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private var stylesXML: String {
        xmlHeader + """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="5">\
        <numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm:ss.000"/>\
        <numFmt numFmtId="165" formatCode="0.00"/>\
        <numFmt numFmtId="166" formatCode="0.0000000"/>\
        <numFmt numFmtId="167" formatCode="0.0"/>\
        <numFmt numFmtId="168" formatCode="0.000"/>\
        </numFmts>\
        <fonts count="5">\
        <font><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="18"/><color rgb="FFFF6A12"/><name val="Calibri"/><family val="2"/></font>\
        <font><i/><sz val="10"/><color rgb="FF7F7F7F"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/><family val="2"/></font>\
        </fonts>\
        <fills count="3">\
        <fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FF2B2D33"/><bgColor indexed="64"/></patternFill></fill>\
        </fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="12">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment wrapText="1" vertical="center"/></xf>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="168" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        </cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
    }
}
