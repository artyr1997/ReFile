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
    /// the other corner of the cells chosen together (⇧ and the arrows, ⇧-click, ⌘A); none: the one cell
    private(set) var extent: (row: Int, column: Int)?
    /// the cells chosen: from row to row, from column to column
    var selection: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let chosen else { return nil }
        let e = extent ?? chosen
        return (min(chosen.row, e.row)...max(chosen.row, e.row), min(chosen.column, e.column)...max(chosen.column, e.column))
    }
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
        // the chosen cells: their + drawn on into one another round them, a frame of the same thin line, the same ink
        if let sel = selection, sel.rows.upperBound < rows.count, sel.columns.upperBound < widths.count {
            let left = x[sel.columns.lowerBound].rounded() + 0.5, right = x[sel.columns.upperBound + 1].rounded() + 0.5
            let top = y[sel.rows.lowerBound].rounded() + 0.5, bottom = y[sel.rows.upperBound + 1].rounded() + 0.5
            let frame = NSBezierPath(rect: NSRect(x: left, y: top, width: right - left, height: bottom - top))
            frame.lineWidth = 1
            NSColor(white: 1, alpha: 0.32).setStroke()
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
                var one = cell.replacingOccurrences(of: "\n", with: " ")
                if header, let sorted, sorted.column == c { one += sorted.ascending ? "  ↑" : "  ↓" }
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
    /// the sizes before a drag kept (once it moves) to undo it
    private var dragKept = false

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
            dragKept = false
            drag = d
            dragFrom = { if case .column = d { return p.x } else { return p.y } }()
            return
        }
        guard let at = cell(at: p) else { return }
        if event.modifierFlags.contains(.shift) && chosen != nil { return extend(at.row, at.column) }
        choose(at.row, at.column)
        if event.clickCount == 2 { edit() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        if !dragKept { dragKept = true; remember() }
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
        extent = nil
        window?.makeFirstResponder(self)
        scrollToVisible(cellRect(row, column).insetBy(dx: -24, dy: -24))
        needsDisplay = true
    }

    /// the cells chosen reach on to this one (⇧ and an arrow, ⇧-click)
    func extend(_ r: Int, _ c: Int) {
        guard chosen != nil, !rows.isEmpty else { return choose(r, c) }
        let row = max(0, min(rows.count - 1, r)), column = max(0, min(columns - 1, c))
        extent = (row, column)
        scrollToVisible(cellRect(row, column).insetBy(dx: -24, dy: -24))
        needsDisplay = true
    }

    // ── copied, cut and pasted (⌘C ⌘X ⌘V), as tabs between cells and lines between rows: as Numbers and
    // Excel copy theirs, so cells go both ways ──

    func copyCells() {
        guard let sel = selection else { return }
        let block = sel.rows.map { r in sel.columns.map { c in c < rows[r].count ? rows[r][c] : "" } }
        let text = Table.write(block, name: "x.tsv", separator: "\t").dropLast()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(text), forType: .string)
    }

    func cutCells() {
        copyCells()
        clear()
    }

    /// the cells chosen, emptied (one change)
    func clear() {
        guard let sel = selection else { return }
        let any = sel.rows.contains { r in sel.columns.contains { c in c < rows[r].count && !rows[r][c].isEmpty } }
        guard any else { return }
        remember()
        for r in sel.rows { for c in sel.columns where c < rows[r].count { rows[r][c] = "" } }
        changed()
    }

    /// What was copied, from the chosen cell on (rows and columns added where it reaches past them); a single
    /// value into several cells chosen fills them all.
    func pasteCells() {
        guard let sel = selection, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        commit()
        let lines = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let block: [[String]] = lines.contains("\t") ? Table.parse(lines, name: "x.tsv")
            : lines.components(separatedBy: "\n").map { [$0] }
        guard !block.isEmpty else { return }
        remember()
        if block.count == 1 && block[0].count == 1 && (sel.rows.count > 1 || sel.columns.count > 1) {
            for r in sel.rows { for c in sel.columns { put(block[0][0], r, c) } }
        } else {
            for (i, line) in block.enumerated() { for (j, value) in line.enumerated() { put(value, sel.rows.lowerBound + i, sel.columns.lowerBound + j) } }
            chosen = (sel.rows.lowerBound, sel.columns.lowerBound)
            extent = (sel.rows.lowerBound + block.count - 1, sel.columns.lowerBound + (block.map(\.count).max() ?? 1) - 1)
        }
        // every row as wide as the widest, so the file stays even
        let n = columns
        for i in rows.indices { while rows[i].count < n { rows[i].append("") } }
        let keep = (chosen, extent)
        changed()
        chosen = keep.0; extent = keep.1
        needsDisplay = true
    }

    /// a value into a cell, rows and columns added to reach it
    private func put(_ value: String, _ r: Int, _ c: Int) {
        while rows.count <= r { rows.append(Array(repeating: "", count: max(1, columns))) }
        while rows[r].count <= c { rows[r].append("") }
        rows[r][c] = value
    }

    /// The table's own keys while it is shown and nothing is being written: the arrows choose, Enter writes,
    /// Tab the next, ⌫ empties. False for what isn't its own.
    func key(_ e: NSEvent) -> Bool {
        guard editable else { return false }
        if editing { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if e.keyCode == 6 && mods == .command { undo(); return true }
        if mods == .command {
            switch e.keyCode {
            case 8: copyCells(); return true
            case 7: cutCells(); return true
            case 9: pasteCells(); return true
            case 0:
                if !rows.isEmpty { chosen = (0, 0); extent = (rows.count - 1, max(0, columns - 1)); needsDisplay = true }
                return true
            default: break
            }
        }
        if e.keyCode == 6 && mods == [.command, .shift] { redo(); return true }
        // rows and columns added (⇧⌘ and an arrow: on that side of the chosen cell) and taken away (⌘⌫ the row,
        // ⇧⌘⌫ the column)
        if let (r, c) = chosen {
            if mods == [.command, .shift] {
                switch e.keyCode {
                case 125: insertRow(at: r + 1); return true
                case 126: insertRow(at: r); return true
                case 124: insertColumn(at: c + 1); return true
                case 123: insertColumn(at: c); return true
                case 51, 117: deleteColumn(c); return true
                default: break
                }
            }
            if mods == .command && (e.keyCode == 51 || e.keyCode == 117) { deleteRow(r); return true }
        }
        // sorted by the chosen cell's column: ⌃⇧↓ A to Z, ⌃⇧↑ Z to A
        if let (_, c) = chosen, mods == [.control, .shift], e.keyCode == 125 || e.keyCode == 126 {
            sort(by: c, ascending: e.keyCode == 125)
            return true
        }
        guard mods.isEmpty || mods == .shift else { return false }
        let (r, c) = chosen ?? (-1, -1)
        switch e.keyCode {
        case 123, 124, 125, 126:
            guard chosen != nil else { choose(0, 0); return true }
            let (dr, dc) = [126: (-1, 0), 125: (1, 0), 123: (0, -1), 124: (0, 1)][Int(e.keyCode)]!
            if mods == .shift {
                // ⇧: the cells chosen reach on
                let e0 = extent ?? chosen!
                extend(e0.row + dr, e0.column + dc)
            } else {
                choose(r + dr, c + dc)
            }
        case 48: if chosen != nil { mods == .shift ? choose(r, c - 1) : choose(r, c + 1) } else { choose(0, 0) }
        case 36, 76: if chosen == nil { choose(0, 0) } else { edit() }
        case 51, 117:
            guard chosen != nil else { return true }
            if extent == nil { set("", r, c) } else { clear() }
        default: return false
        }
        return true
    }

    // ── rows and columns, added and taken away ──

    /// the sizes set by hand move with their rows and columns
    private func shift(_ sizes: inout [Int: CGFloat], from i: Int, by d: Int) {
        var moved: [Int: CGFloat] = [:]
        for (k, v) in sizes {
            if k < i { moved[k] = v } else if d < 0 && k == i { continue } else { moved[k + d] = v }
        }
        sizes = moved
    }

    func insertRow(at r: Int) {
        remember()
        let at = max(0, min(rows.count, r))
        rows.insert(Array(repeating: "", count: max(1, columns)), at: at)
        shift(&setHeights, from: at, by: 1)
        changed()
        choose(at, chosen?.column ?? 0)
    }

    func deleteRow(_ r: Int) {
        guard rows.count > 1, r < rows.count else { return }
        remember()
        rows.remove(at: r)
        shift(&setHeights, from: r, by: -1)
        changed()
        choose(min(r, rows.count - 1), chosen?.column ?? 0)
    }

    func insertColumn(at c: Int) {
        remember()
        let at = max(0, min(columns, c))
        sorted = nil
        for i in rows.indices {
            while rows[i].count < at { rows[i].append("") }
            rows[i].insert("", at: at)
        }
        shift(&setWidths, from: at, by: 1)
        // an empty column, wide enough to write in
        setWidths[at] = 120
        changed()
        choose(chosen?.row ?? 0, at)
    }

    func deleteColumn(_ c: Int) {
        guard columns > 1, c < columns else { return }
        remember()
        sorted = nil
        for i in rows.indices where c < rows[i].count { rows[i].remove(at: c) }
        shift(&setWidths, from: c, by: -1)
        changed()
        choose(chosen?.row ?? 0, min(c, columns - 1))
    }

    // ── undone and done again (⌘Z, ⇧⌘Z): every change kept as it was before it ──

    private struct State {
        let rows: [[String]]
        let widths: [Int: CGFloat]
        let heights: [Int: CGFloat]
        let sorted: (column: Int, ascending: Bool)?
        let chosen: (row: Int, column: Int)?
    }
    private var undone: [State] = []
    private var redone: [State] = []
    private var now: State { State(rows: rows, widths: setWidths, heights: setHeights, sorted: sorted, chosen: chosen) }

    /// what the table is now, kept to come back to (before a change)
    private func remember() {
        undone.append(now)
        if undone.count > 200 { undone.removeFirst() }
        redone = []
    }

    private func restore(_ state: State) {
        rows = state.rows
        setWidths = state.widths
        setHeights = state.heights
        sorted = state.sorted
        changed()
        if let c = state.chosen { choose(c.row, c.column) }
    }

    func undo() {
        commit()
        guard let last = undone.popLast() else { return NSSound.beep() }
        redone.append(now)
        restore(last)
    }

    func redo() {
        guard let next = redone.popLast() else { return NSSound.beep() }
        undone.append(now)
        restore(next)
    }

    /// the column the rows were last sorted by, and which way (an arrow by its name)
    private(set) var sorted: (column: Int, ascending: Bool)?

    /// The rows under the first (the columns' names) sorted by a column: numbers as numbers (2 before 10),
    /// words as Finder sorts names, the empty last; rows alike keep their order. Their heights go with them.
    func sort(by c: Int, ascending: Bool) {
        guard rows.count > 2 else { return }
        commit()
        remember()
        let value = { (i: Int) -> String in c < self.rows[i].count ? self.rows[i][c].trimmingCharacters(in: .whitespaces) : "" }
        let number = { (t: String) -> Double? in Double(t.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")) }
        let order = (1..<rows.count).sorted { a, b in
            let x = value(a), y = value(b)
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            if x.isEmpty { return a < b }
            let result: ComparisonResult
            if let nx = number(x), let ny = number(y) { result = nx < ny ? .orderedAscending : nx > ny ? .orderedDescending : .orderedSame }
            else { result = x.localizedStandardCompare(y) }
            if result == .orderedSame { return a < b }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        let chosenRow = chosen?.row
        let heights = setHeights
        rows = [rows[0]] + order.map { rows[$0] }
        setHeights = [:]
        if let h = heights[0] { setHeights[0] = h }
        for (new, old) in order.enumerated() { if let h = heights[old] { setHeights[new + 1] = h } }
        sorted = (c, ascending)
        changed()
        // the chosen cell stays on its row, wherever it went
        if let chosenRow, chosenRow > 0, let to = order.firstIndex(of: chosenRow) { choose(to + 1, c) } else { choose(chosen?.row ?? 0, c) }
    }

    private func changed() {
        measure()
        store()
        onEdit?()
        onResize?()
    }

    /// a right click on a cell: what can be done there
    override func menu(for event: NSEvent) -> NSMenu? {
        guard editable else { return nil }
        commit()
        let p = convert(event.locationInWindow, from: nil)
        guard let at = cell(at: p) else { return nil }
        if let sel = selection, sel.rows.contains(at.row), sel.columns.contains(at.column) {} else { choose(at.row, at.column) }
        let menu = NSMenu()
        let items: [(String, String, () -> Void)] = [
            ("Undo", "⌘Z", { [weak self] in self?.undo() }),
            ("Redo", "⇧⌘Z", { [weak self] in self?.redo() }),
            ("", "", {}),
            ("Cut", "⌘X", { [weak self] in self?.cutCells() }),
            ("Copy", "⌘C", { [weak self] in self?.copyCells() }),
            ("Paste", "⌘V", { [weak self] in self?.pasteCells() }),
            ("", "", {}),
            ("Row above", "⇧⌘↑", { [weak self] in self?.insertRow(at: at.row) }),
            ("Row below", "⇧⌘↓", { [weak self] in self?.insertRow(at: at.row + 1) }),
            ("Column left", "⇧⌘←", { [weak self] in self?.insertColumn(at: at.column) }),
            ("Column right", "⇧⌘→", { [weak self] in self?.insertColumn(at: at.column + 1) }),
            ("", "", {}),
            ("Sort A → Z", "⌃⇧↓", { [weak self] in self?.sort(by: at.column, ascending: true) }),
            ("Sort Z → A", "⌃⇧↑", { [weak self] in self?.sort(by: at.column, ascending: false) }),
            ("", "", {}),
            ("Delete row", "⌘⌫", { [weak self] in self?.deleteRow(at.row) }),
            ("Delete column", "⇧⌘⌫", { [weak self] in self?.deleteColumn(at.column) }),
        ]
        menuActions = []
        for (title, keys, run) in items {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let action = MenuAction(run)
            menuActions.append(action)
            let item = menu.addItem(withTitle: tx(title) + "    " + keys, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            if title == "Delete row" { item.isEnabled = rows.count > 1 }
            if title == "Delete column" { item.isEnabled = columns > 1 }
            if title.hasPrefix("Sort") { item.isEnabled = rows.count > 2 }
            if title == "Undo" { item.isEnabled = !undone.isEmpty }
            if title == "Redo" { item.isEnabled = !redone.isEmpty }
            if title == "Paste" { item.isEnabled = NSPasteboard.general.string(forType: .string) != nil }
        }
        menu.autoenablesItems = false
        return menu
    }
    private var menuActions: [MenuAction] = []

    private func set(_ value: String, _ r: Int, _ c: Int) {
        guard (c < rows[r].count ? rows[r][c] : "") != value else { return }
        remember()
        while rows[r].count <= c { rows[r].append("") }
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

/// a menu item's action, kept while its menu is shown
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
