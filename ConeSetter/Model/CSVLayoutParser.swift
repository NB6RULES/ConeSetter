import Foundation

/// Reads autocross / trackdrive layouts from CSV.
///
/// Accepted rows (comma, semicolon or tab separated, header lines ignored):
///   blue,12.5,3.0            colour first (FSDS / FSSIM style, extra columns ignored)
///   12.5,3.0,yellow          coordinates first
///   7,big_orange,0.5,1.5     id, colour, x, y
///   refA,0,0  /  refB,20,0   optional taped reference points
/// Coordinates are metres; x = forward, y = left.
enum CSVLayoutParser {
    enum ParseError: LocalizedError {
        case noCones

        var errorDescription: String? {
            "No cones found. Use one cone per row, e.g. \"blue,12.5,3.0\"."
        }
    }

    static func parse(_ text: String, name: String) throws -> ConeLayout {
        var cones: [PlannedCone] = []
        var refA: Vec2?
        var refB: Vec2?
        let separators = CharacterSet(charactersIn: ",;\t")

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            let fields = line.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let wordIndex = fields.firstIndex(where: { Double($0) == nil }) else { continue }
            let tag = fields[wordIndex]

            let after = fields[(wordIndex + 1)...].compactMap { Double($0) }
            let all = fields.compactMap { Double($0) }
            let coords: [Double] = after.count >= 2 ? after : all
            guard coords.count >= 2 else { continue } // header or junk
            let p = Vec2(coords[0], coords[1])

            let t = tag.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            if ["refa", "referencea", "a"].contains(t) { refA = p; continue }
            if ["refb", "referenceb", "b"].contains(t) { refB = p; continue }
            guard let colour = ConeColor.parse(tag) else { continue }

            cones.append(PlannedCone(id: cones.count, x: p.x, y: p.y, color: colour, group: group(for: colour)))
        }

        guard let first = cones.first else { throw ParseError.noCones }

        let a = refA ?? first.pos
        let b = refB ?? cones.max(by: { dist2($0.pos, a) < dist2($1.pos, a) })?.pos ?? (a + Vec2(10, 0))
        let hintA = refA != nil
            ? String(format: "Reference A from the file (%.2f, %.2f)", a.x, a.y)
            : String(format: "First cone in the file (%.2f, %.2f) — put a mark here", a.x, a.y)
        let hintB = (refB != nil ? "Reference B from the file" : "Farthest cone from A")
            + String(format: " — %.2f m from A, tape it", dist2(a, b))

        return ConeLayout(
            name: name.isEmpty ? "Imported track" : name,
            kind: .custom,
            cones: cones,
            refA: a,
            refB: b,
            refAHint: hintA,
            refBHint: hintB
        )
    }

    private static func group(for c: ConeColor) -> String {
        switch c {
        case .blue: return "Left edge"
        case .yellow: return "Right edge"
        case .orange: return "Orange"
        case .bigOrange: return "Big orange"
        }
    }
}
