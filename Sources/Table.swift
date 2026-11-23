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

extension Table {
    /// The rows written back as a CSV (or TSV): a cell with the separator, a quote or a new line in quotes.
    static func write(_ rows: [[String]], name: String, separator: Character) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(separator) || cell.contains("\"") || cell.contains("\n")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }

    static func separator(of text: String, name: String) -> Character {
        let first = text.prefix { $0 != "\n" }
        return Files.ext(name) == "tsv" ? "\t" : first.filter { $0 == ";" }.count > first.filter { $0 == "," }.count ? ";" : ","
    }
}

/// The cells, measured and drawn; as large as they are (its frame set to `size` when shown whole). In the
/// viewer it can be written in: a cell chosen (a click, the arrows), written in (Enter, a double click), and
/// the columns and rows made wider and taller by dragging the lines between them (where the + are).
final class TableView: Flipped, NSTextFieldDelegate {
    var rows: [[String]] = [] { didSet { measure() } }
    var fontSize: CGFloat = 13 { didSet { measure() } }
    /// room round the whole and inside each cell
    var inset = NSSize(width: 24, height: 20)
    private var cellPad: CGFloat { fontSize * 0.9 }
    private var rowHeight: CGFloat { fontSize * 2.4 }
    private(set) var widths: [CGFloat] = []
    /// the widest a column grows by itself (what is longer ends in …)
    var widest: CGFloat = 340
    /// written in and resized (the viewer's); told when it changes, and when its size does
    var editable = false
    var onEdit: (() -> Void)?
    var onResize: (() -> Void)?
    /// the sizes set by hand, kept for the file
    var keep: String?
    private var setWidths: [Int: CGFloat] = [:]
    private var setHeights: [Int: CGFloat] = [:]
    private(set) var chosen: (row: Int, column: Int)?
    private var field: NSTextField?
    var editing: Bool { field != nil }

    var size: NSSize {
        NSSize(width: inset.width * 2 + widths.reduce(0, +), height: inset.height * 2 + (0..<rows.count).reduce(0) { $0 + height($1) })
    }

    private func font(_ header: Bool) -> NSFont { Fonts.words(fontSize) }
    private func height(_ r: Int) -> CGFloat { setHeights[r] ?? rowHeight }
    private var columns: Int { rows.map(\.count).max() ?? 0 }

    /// the sizes kept for this file, if any
    func restore() {
        guard let keep, let d = UserDefaults.standard.dictionary(forKey: "table." + keep) else { return }
        for (k, v) in (d["w"] as? [String: Double]) ?? [:] { if let c = Int(k) { setWidths[c] = v } }
        for (k, v) in (d["h"] as? [String: Double]) ?? [:] { if let r = Int(k) { setHeights[r] = v } }
        measure()
    }

    private func store() {
        guard let keep else { return }
        UserDefaults.standard.set(["w": Dictionary(uniqueKeysWithValues: setWidths.map { (String($0.key), Double($0.value)) }),
                                   "h": Dictionary(uniqueKeysWithValues: setHeights.map { (String($0.key), Double($0.value)) })],
                                  forKey: "table." + keep)
    }

    private func measure() {
        var w = [CGFloat](repeating: 0, count: columns)
        for (r, row) in rows.prefix(800).enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: font(r == 0)]
            for (c, cell) in row.enumerated() {
                let one = cell.replacingOccurrences(of: "\n", with: " ")
                w[c] = max(w[c], min(widest, ceil((one as NSString).size(withAttributes: attrs).width)))
            }
        }
        widths = w.enumerated().map { setWidths[$0.offset] ?? $0.element + cellPad * 2 }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// the edges of the columns across, and of the rows down
    private var xs: [CGFloat] { var x = [inset.width]; for w in widths { x.append(x.last! + w) }; return x }
    private var ys: [CGFloat] { var y = [inset.height]; for r in 0..<rows.count { y.append(y.last! + height(r)) }; return y }

    private func cellRect(_ r: Int, _ c: Int) -> NSRect {
        let x = xs, y = ys
        return NSRect(x: x[c], y: y[r], width: x[c + 1] - x[c], height: y[r + 1] - y[r])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let x = xs, y = ys
        // only the rows in sight
        let first = max(0, (y.firstIndex { $0 > dirtyRect.minY } ?? 1) - 2)
        let last = min(rows.count, (y.firstIndex { $0 > dirtyRect.maxY } ?? rows.count) + 1)
        guard first < last else { return }
        // the chosen cell: a thin frame round it, as the apps frame a chosen button
        if let chosen, chosen.row < rows.count, chosen.column < widths.count {
            let frame = NSBezierPath(rect: cellRect(chosen.row, chosen.column).insetBy(dx: 3.5, dy: 3.5))
            frame.lineWidth = 1
            NSColor(white: 1, alpha: editing ? 0.85 : 0.6).setStroke()
            frame.stroke()
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        for r in first..<last {
            let header = r == 0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(header), .paragraphStyle: p,
                .foregroundColor: header ? NSColor(white: 1, alpha: 0.95) : Ink.text.withAlphaComponent(0.72),
            ]
            for (c, cell) in rows[r].enumerated() where c < widths.count {
                if editing, let chosen, chosen.row == r, chosen.column == c { continue }
                let one = cell.replacingOccurrences(of: "\n", with: " ")
                let s = NSAttributedString(string: one, attributes: attrs)
                let h = s.size().height
                s.draw(with: NSRect(x: x[c] + cellPad, y: y[r] + (height(r) - h) / 2, width: widths[c] - cellPad * 2, height: h + 2),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        // a + where four cells meet, at every corner, nothing between
        let arm: CGFloat = 4
        let marks = NSBezierPath()
        marks.lineWidth = 1
        for r in first...min(last, rows.count) {
            let yy = y[r].rounded() + 0.5
            for x0 in x {
                let xx = x0.rounded() + 0.5
                marks.move(to: NSPoint(x: xx - arm, y: yy)); marks.line(to: NSPoint(x: xx + arm, y: yy))
                marks.move(to: NSPoint(x: xx, y: yy - arm)); marks.line(to: NSPoint(x: xx, y: yy + arm))
            }
        }
        NSColor(white: 1, alpha: 0.32).setStroke()
        marks.stroke()
    }

    // ── made wider and taller: the lines between the columns and the rows dragged ──

    private let grip: CGFloat = 5
    private enum Drag { case column(Int, CGFloat), row(Int, CGFloat) }
    private var drag: Drag?
    private var dragFrom: CGFloat = 0

    /// the line under the point: a column's right edge, or a row's foot
    private func line(at p: NSPoint) -> Drag? {
        let x = xs, y = ys
        guard p.y >= y.first! - grip, p.y <= y.last! + grip, p.x >= x.first! - grip, p.x <= x.last! + grip else { return nil }
        if let c = (1..<x.count).first(where: { abs(x[$0] - p.x) <= grip }) { return .column(c - 1, widths[c - 1]) }
        if let r = (1..<y.count).first(where: { abs(y[$0] - p.y) <= grip }) { return .row(r - 1, height(r - 1)) }
        return nil
    }

    override func resetCursorRects() {
        guard editable else { return }
        let x = xs, y = ys
        let top = y.first!, bottom = y.last!, left = x.first!, right = x.last!
        for xx in x.dropFirst() { addCursorRect(NSRect(x: xx - grip, y: top, width: grip * 2, height: bottom - top), cursor: .resizeLeftRight) }
        for yy in y.dropFirst() { addCursorRect(NSRect(x: left, y: yy - grip, width: right - left, height: grip * 2), cursor: .resizeUpDown) }
    }

    override var acceptsFirstResponder: Bool { editable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cell(at p: NSPoint) -> (row: Int, column: Int)? {
        let x = xs, y = ys
        guard let c = (0..<widths.count).first(where: { p.x >= x[$0] && p.x < x[$0 + 1] }),
              let r = (0..<rows.count).first(where: { p.y >= y[$0] && p.y < y[$0 + 1] }) else { return nil }
        return (r, c)
    }

    override func mouseDown(with event: NSEvent) {
        guard editable else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        commit()
        if let d = line(at: p) {
            drag = d
            dragFrom = { if case .column = d { return p.x } else { return p.y } }()
            return
        }
        guard let at = cell(at: p) else { return }
        choose(at.row, at.column)
        if event.clickCount == 2 { edit() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .column(let c, let start):
            setWidths[c] = max(36, start + p.x - dragFrom)
        case .row(let r, let start):
            setHeights[r] = max(fontSize * 1.8, start + p.y - dragFrom)
        }
        measure()
        onResize?()
    }

    override func mouseUp(with event: NSEvent) {
        if drag != nil { drag = nil; store() }
    }

    // ── written in ──

    func choose(_ r: Int, _ c: Int) {
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, r)), column = max(0, min(columns - 1, c))
        chosen = (row, column)
        window?.makeFirstResponder(self)
        scrollToVisible(cellRect(row, column).insetBy(dx: -24, dy: -24))
        needsDisplay = true
    }

    /// The table's own keys while it is shown and nothing is being written: the arrows choose, Enter writes,
    /// Tab the next, ⌫ empties. False for what isn't its own.
    func key(_ e: NSEvent) -> Bool {
        guard editable else { return false }
        if editing { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.isEmpty || mods == .shift else { return false }
        let (r, c) = chosen ?? (-1, -1)
        switch e.keyCode {
        case 126: chosen == nil ? choose(0, 0) : choose(r - 1, c)
        case 125: chosen == nil ? choose(0, 0) : choose(r + 1, c)
        case 123: chosen == nil ? choose(0, 0) : choose(r, c - 1)
        case 124: chosen == nil ? choose(0, 0) : choose(r, c + 1)
        case 48: if chosen != nil { mods == .shift ? choose(r, c - 1) : choose(r, c + 1) } else { choose(0, 0) }
        case 36, 76: if chosen == nil { choose(0, 0) } else { edit() }
        case 51, 117:
            guard chosen != nil else { return true }
            set("", r, c)
        default: return false
        }
        return true
    }

    private func set(_ value: String, _ r: Int, _ c: Int) {
        while rows[r].count <= c { rows[r].append("") }
        guard rows[r][c] != value else { return }
        rows[r][c] = value
        onEdit?()
    }

    func edit() {
        guard let (r, c) = chosen, field == nil else { return }
        let f = NSTextField(string: r < rows.count && c < rows[r].count ? rows[r][c] : "")
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = false
        f.font = font(r == 0)
        f.textColor = NSColor(white: 1, alpha: 0.95)
        f.delegate = self
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        let rect = cellRect(r, c)
        let h = ceil(f.intrinsicContentSize.height)
        f.frame = NSRect(x: rect.minX + cellPad - 2, y: rect.midY - h / 2, width: max(60, rect.width - cellPad * 2 + 4), height: h)
        addSubview(f)
        field = f
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// what was written kept in its cell
    func commit() {
        guard let f = field, let (r, c) = chosen else { return }
        field = nil
        f.removeFromSuperview()
        set(f.stringValue, r, c)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancel() {
        guard let f = field else { return }
        field = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let (r, c) = chosen else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.insertNewline(_:)): commit(); choose(r + 1, c)
        case #selector(NSResponder.insertTab(_:)): commit(); choose(r, c + 1)
        case #selector(NSResponder.insertBacktab(_:)): commit(); choose(r, c - 1)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { if field != nil { commit() } }
}
