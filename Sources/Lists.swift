import AppKit

// A list: its rows' names (the one chosen underlined), and, when it is a table, more columns beside them
// (a file's size and date; a song's artist and time; a station's country and kind). A click chooses, a
// double click opens, a right click asks for the actions.

struct Line {
    var cells: [String]
    /// what plays now: a dot before its name
    var dot = false
    /// ◆ after the name (a station kept)
    var mark: String? = nil
    /// how strong the name is (genres not chosen are fainter)
    var alpha: CGFloat = 1
}

struct Column {
    var width: CGFloat? = nil   // nil: the rest
    var share: CGFloat = 1      // of the rest, for the ones without a width
    var size: CGFloat = 16
    var alpha: CGFloat = 1
    var align: NSTextAlignment = .left
}

final class ListView: Flipped {
    let scroll = FadeScroll()
    private let doc = ListDoc()

    var lines: [Line] = [] { didSet { relayout() } }
    var selected: Int? { didSet { doc.needsDisplay = true } }
    /// the chosen one underlined (only in the column the keys move in)
    var underline = true { didSet { doc.needsDisplay = true } }
    var columns: [Column] = [Column()] { didSet { doc.needsDisplay = true } }
    var gap: CGFloat = 22 { didSet { relayout() } }
    var columnGap: CGFloat = 24
    var empty = "" { didSet { doc.needsDisplay = true } }
    var dim: CGFloat = 1 { didSet { alphaValue = dim } }

    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    var onMenu: ((Int) -> Void)?

    let rowH: CGFloat = 19.2
    let pad = NSSize(width: 9.6, height: 6.4)

    override init(frame: NSRect) {
        super.init(frame: frame)
        doc.list = self
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        relayout()
    }

    private func relayout() {
        let n = CGFloat(lines.count)
        let h = pad.height * 2 + n * rowH + max(0, n - 1) * gap
        doc.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(h, scroll.contentSize.height))
        doc.needsDisplay = true
        scroll.update()
    }

    func rect(_ i: Int) -> NSRect {
        NSRect(x: pad.width, y: pad.height + CGFloat(i) * (rowH + gap), width: max(0, doc.bounds.width - pad.width * 2), height: rowH)
    }

    func row(at p: NSPoint) -> Int? {
        let i = Int((p.y - pad.height + gap / 2) / (rowH + gap))
        return i >= 0 && i < lines.count ? i : nil
    }

    /// the row chosen kept in sight, clear of the faded edges
    func reveal(_ i: Int?) {
        guard let i, i < lines.count else { return }
        doc.scrollToVisible(rect(i).insetBy(dx: 0, dy: -FadeScroll.fade))
        scroll.update()
    }

    /// the columns' places in a row `width` wide
    func places(_ width: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let fixed = columns.compactMap(\.width).reduce(0, +)
        let shares = columns.filter { $0.width == nil }.map(\.share).reduce(0, +)
        let rest = max(0, width - fixed - columnGap * CGFloat(columns.count - 1))
        var x: CGFloat = 0
        return columns.map { c in
            let w = c.width ?? rest * c.share / max(shares, 1)
            defer { x += w + columnGap }
            return (x, w)
        }
    }

    func drawRows(_ dirty: NSRect) {
        if lines.isEmpty {
            attributed(empty, Fonts.words(16), NSColor(white: 1, alpha: 0.6 * 0.45)).draw(at: NSPoint(x: pad.width, y: pad.height))
            return
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        for (i, line) in lines.enumerated() {
            let r = rect(i)
            guard r.intersects(dirty.insetBy(dx: 0, dy: -30)) else { continue }
            let at = places(r.width)
            for (c, text) in line.cells.enumerated() where c < columns.count {
                let col = columns[c]
                var x = r.minX + at[c].x
                var w = at[c].w
                var attrs: [NSAttributedString.Key: Any] = [.font: Fonts.words(col.size), .foregroundColor: NSColor(white: 1, alpha: 0.8 * col.alpha * (c == 0 ? line.alpha : 1))]
                let style = p.mutableCopy() as! NSMutableParagraphStyle
                style.alignment = col.align
                attrs[.paragraphStyle] = style
                if c == 0 {
                    if line.dot {
                        Ink.text.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 7, width: 7, height: 7)).fill()
                        x += 11
                        w -= 11
                    }
                    if i == selected && underline {
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        attrs[.underlineColor] = Ink.text
                    }
                    var markW: CGFloat = 0
                    if let mark = line.mark {
                        let m = attributed(mark, Fonts.words(9), NSColor(white: 1, alpha: 0.8 * 0.55))
                        markW = m.size().width + 8
                        let nameW = min(w - markW, NSAttributedString(string: text, attributes: attrs).size().width)
                        m.draw(at: NSPoint(x: x + nameW + 8, y: r.minY + 5))
                    }
                    NSAttributedString(string: text, attributes: attrs).draw(with: NSRect(x: x, y: r.minY, width: max(0, w - markW), height: r.height + 4),
                                                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                } else {
                    let s = NSAttributedString(string: text, attributes: attrs)
                    let dy = (16 - col.size) * 0.8
                    s.draw(with: NSRect(x: x, y: r.minY + dy, width: w, height: r.height + 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
        }
    }

    func clicked(_ e: NSEvent, in view: NSView) {
        guard let i = row(at: view.convert(e.locationInWindow, from: nil)) else { return }
        if e.type == .rightMouseDown { return onMenu?(i) ?? () }
        if e.clickCount == 2 { onOpen?(i) } else { onSelect?(i) }
    }
}

private final class ListDoc: Flipped {
    weak var list: ListView?
    override func draw(_ dirtyRect: NSRect) { list?.drawRows(dirtyRect) }
    override func mouseDown(with event: NSEvent) { list?.clicked(event, in: self) }
    override func rightMouseDown(with event: NSEvent) { list?.clicked(event, in: self) }
}
