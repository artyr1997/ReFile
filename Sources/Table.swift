import AppKit

// A table (CSV, TSV) drawn as ReFile writes: no lines round the cells, only a thin + where their corners
// meet; the first row, the names of the columns, brighter. In the TEXT preview the start of it, as a page;
// in the viewer the whole of it, scrolled down and across.

enum Table {
    static let kinds = ["csv", "tsv"]

    static func isTable(_ name: String) -> Bool { kinds.contains(Files.ext(name)) }

    /// The rows and their cells: quoted cells may hold the separator, new lines and "" (a quote). The
    /// separator is a tab in a .tsv; in a .csv a comma, or a semicolon if its first line has more of those.
    static func parse(_ text: String, name: String, limit: Int = 5000) -> [[String]] {
        let first = text.prefix { $0 != "\n" }
        let sep: Character = Files.ext(name) == "tsv" ? "\t"
            : first.filter { $0 == ";" }.count > first.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var chars = text.makeIterator()
        var next = chars.next()
        while let c = next {
            next = chars.next()
            if quoted {
                if c == "\"" {
                    if next == "\"" { cell.append("\""); next = chars.next() } else { quoted = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                quoted = true
            } else if c == sep {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(cell); cell = ""
                rows.append(row); row = []
                if rows.count >= limit { return rows }
            } else {
                cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        // a last empty line is no row
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        return rows
    }
}

/// The cells, measured and drawn; as large as they are (its frame set to `size` when shown whole).
final class TableView: Flipped {
    var rows: [[String]] = [] { didSet { measure() } }
    var fontSize: CGFloat = 13 { didSet { measure() } }
    /// room round the whole and inside each cell
    var inset = NSSize(width: 24, height: 20)
    private var cellPad: CGFloat { fontSize * 0.9 }
    private var rowHeight: CGFloat { fontSize * 2.4 }
    private(set) var widths: [CGFloat] = []
    /// the widest a column grows (what is longer ends in …)
    var widest: CGFloat = 340

    var size: NSSize {
        NSSize(width: inset.width * 2 + widths.reduce(0, +), height: inset.height * 2 + CGFloat(rows.count) * rowHeight)
    }

    private func font(_ header: Bool) -> NSFont { Fonts.words(fontSize) }

    private func measure() {
        let columns = rows.map(\.count).max() ?? 0
        var w = [CGFloat](repeating: 0, count: columns)
        for (r, row) in rows.prefix(800).enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: font(r == 0)]
            for (c, cell) in row.enumerated() {
                let one = cell.replacingOccurrences(of: "\n", with: " ")
                w[c] = max(w[c], min(widest, ceil((one as NSString).size(withAttributes: attrs).width)))
            }
        }
        widths = w.map { $0 + cellPad * 2 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let rh = rowHeight
        // only the rows in sight
        let first = max(0, Int((dirtyRect.minY - inset.height) / rh) - 1)
        let last = min(rows.count, Int((dirtyRect.maxY - inset.height) / rh) + 2)
        guard first < last else { return }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        // the edges of the columns, across
        var xs: [CGFloat] = [inset.width]
        for w in widths { xs.append(xs.last! + w) }
        for r in first..<last {
            let y = inset.height + CGFloat(r) * rh
            let header = r == 0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(header), .paragraphStyle: p,
                .foregroundColor: header ? NSColor(white: 1, alpha: 0.95) : Ink.text.withAlphaComponent(0.72),
            ]
            for (c, cell) in rows[r].enumerated() where c < widths.count {
                let one = cell.replacingOccurrences(of: "\n", with: " ")
                let s = NSAttributedString(string: one, attributes: attrs)
                let h = s.size().height
                s.draw(with: NSRect(x: xs[c] + cellPad, y: y + (rh - h) / 2, width: widths[c] - cellPad * 2, height: h + 2),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        // a + where four cells meet, at every corner, nothing between
        let arm: CGFloat = 4
        let marks = NSBezierPath()
        marks.lineWidth = 1
        for r in first...min(last, rows.count) {
            let y = (inset.height + CGFloat(r) * rh).rounded() + 0.5
            for x0 in xs {
                let x = x0.rounded() + 0.5
                marks.move(to: NSPoint(x: x - arm, y: y)); marks.line(to: NSPoint(x: x + arm, y: y))
                marks.move(to: NSPoint(x: x, y: y - arm)); marks.line(to: NSPoint(x: x, y: y + arm))
            }
        }
        NSColor(white: 1, alpha: 0.32).setStroke()
        marks.stroke()
    }
}
