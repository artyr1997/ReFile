import AppKit

// The viewer: a picture or a text over the folder (Space for a quick look, or a file opened here). A text is
// written in right there and keeps itself a moment after the typing stops (⌘S at once); only its first
// megabyte is shown, and then it can't be written in. ← → the folder's other pictures and texts.

final class Viewer: Flipped, NSTextViewDelegate {
    let entry: Entry
    private let titleLabel = titleField()
    private let image = ImageBox()
    private let scroll = FadeScroll()
    private let text: NSTextView
    private let foot = label("", Fonts.words(14), NSColor(white: 1, alpha: 0.6 * 0.7), align: .center)
    private let truncated: Bool
    /// a table (CSV, TSV): shown as one, not written in
    private var table: TableView?
    /// a table's side buttons, at the window's corners as everywhere in ReFile: BACK (closed), NOVA (a row
    /// under the chosen cell), SORT (by its column; again, the other way), FULL
    private var sides: [SideButton] = []
    private var separator: Character = ","
    /// a cell written in since the file was last kept: only then is it written (never just for being opened)
    private var tableDirty = false

    /// a cell written in: the file kept a moment later, as a text is
    private func tableChanged() {
        tableDirty = true
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    private var saved = ""
    private var timer: DispatchWorkItem?
    private(set) var edited = false
    var onClose: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var position: String? { didSet { showFoot() } }
    /// FULL: the picture or the text filling the window, nothing round it (Esc, F back)
    private var full = false { didSet { needsLayout = true } }
    func fillWindow() { full = true }

    init(entry: Entry, image img: NSImage) {
        self.entry = entry
        truncated = false
        text = NSTextView()
        super.init(frame: .zero)
        image.image = img
        setUp()
        scroll.isHidden = true
    }

    init(entry: Entry, text t0: String, truncated: Bool) {
        let t = t0
        self.entry = entry
        self.truncated = truncated
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)
        super.init(frame: .zero)
        saved = t
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isEditable = !truncated
        text.insertionPointColor = Ink.text
        text.textContainerInset = .zero
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.22)]
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 13 * 1.6
        p.maximumLineHeight = 13 * 1.6
        p.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.mono(13), .foregroundColor: Ink.text, .paragraphStyle: p]
        text.typingAttributes = attrs
        text.textStorage?.setAttributedString(NSAttributedString(string: t, attributes: attrs))
        text.delegate = self
        scroll.documentView = text
        if Table.isTable(entry.name) {
            let t = TableView()
            t.fontSize = 14
            t.rows = Table.parse(t0, name: entry.name)
            t.keep = entry.path
            t.restore()
            // written in, unless only its first megabyte is shown
            t.editable = !truncated
            separator = Table.separator(of: t0, name: entry.name)
            t.onEdit = { [weak self] in self?.tableChanged() }
            t.onResize = { [weak self] in self?.needsLayout = true }
            table = t
            let back = SideButton("BACK") { [weak self] in self?.save(); self?.onClose?() }
            let nova = SideButton("NOVA", as: "NEW ROW") { [weak t] in
                guard let t else { return }
                t.insertRow(at: (t.chosen?.row ?? t.rows.count - 1) + 1)
            }
            let sort = SideButton("SORT") { [weak t] in
                guard let t else { return }
                let c = t.chosen?.column ?? 0
                t.sort(by: c, ascending: !(t.sorted?.column == c && t.sorted?.ascending == true))
            }
            let fullB = SideButton("FULL") { [weak self] in self?.full.toggle() }
            nova.enabled = t.editable
            sort.enabled = t.editable
            sides = [back, nova, sort, fullB]
            text.isEditable = false
            scroll.documentView = t
            scroll.hasHorizontalScroller = false
        }
        setUp()
        image.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        titleLabel.stringValue = entry.name
        titleLabel.toolTip = entry.path
        addSubview(titleLabel)
        addSubview(image)
        addSubview(scroll)
        addSubview(foot)
        sides.forEach { addSubview($0) }
        showFoot()
    }

    private func showFoot() {
        var s = Files.size(entry.size)
        if let table { s += " · \(table.rows.count) rows · \(table.widths.count) columns" }
        if truncated { s += " · the first megabyte, not editable" }
        if let position { s += " · \(position)" }
        foot.stringValue = s
    }

    func focus() {
        if let table { return table.choose(0, 0) }
        if !scroll.isHidden { window?.makeFirstResponder(text) }
    }

    // ── kept as it is written ──

    func textDidChange(_ notification: Notification) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// what was written, kept (only whole files: one shown cut at a megabyte stays as it is)
    func save() {
        timer?.cancel()
        timer = nil
        if let table {
            table.commit()
            guard !truncated, tableDirty else { return }
            let csv = Table.write(table.rows, name: entry.name, separator: separator)
            do {
                try Files.write(csv, to: entry.path)
                saved = csv
                tableDirty = false
                edited = true
            } catch {}
            return
        }
        guard !scroll.isHidden, !truncated, text.string != saved else { return }
        do {
            try Files.write(text.string, to: entry.path)
            saved = text.string
            edited = true
        } catch {}
    }

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        // a table: written in (its field has the keys), or its own keys (the arrows, Enter, Tab, ⌫)
        if let table {
            if table.editing { return false }
            if mods == .command && e.keyCode == 1 { save(); return true }
            if table.key(e) { return true }
            if e.keyCode == 53 { if full { full = false } else { save(); onClose?() }; return true }
            return mods == .command ? false : e.keyCode == 3 ? { full.toggle(); return true }() : true
        }
        if window?.firstResponder === text {
            // in the text: it's typing, but for Esc (close) and ⌘S
            if e.keyCode == 53 { if full { full = false } else { onClose?() }; return true }
            if mods == .command && e.keyCode == 1 { save(); return true }
            return false
        }
        switch e.keyCode {
        case 53: if full { full = false } else { onClose?() }
        case 49: onClose?()
        case 3: full.toggle()
        case 123, 126: onStep?(-1)
        case 124, 125: onStep?(1)
        default: return mods == .command ? false : true
        }
        return true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let small = W < 760 || H < 560
        let titleW = small ? W - 200 : W * 0.5
        titleLabel.frame = NSRect(x: (W - titleW) / 2, y: small ? 12 : 28, width: titleW, height: 32)
        let area = full ? bounds.insetBy(dx: 40, dy: 32)
            : small ? NSRect(x: 40, y: 52, width: W - 80, height: H - 104)
            : NSRect(x: W * 0.0625 + 60, y: H * 0.0625 + 40, width: W - 2 * (W * 0.0625 + 60), height: H - 2 * H * 0.0625 - 84)
        titleLabel.isHidden = full
        foot.isHidden = full
        // the table's buttons at the corners, as ReFile places its own (none in a small window, only FULL in full)
        for (i, b) in sides.enumerated() {
            let left = i % 2 == 0, top = i < 2
            b.top = top
            let h = b.intrinsicContentSize.height
            b.frame = NSRect(x: left ? W * 0.0625 - 28 : W - (W * 0.0625 - 28) - SideButton.width,
                             y: top ? H * 0.0625 + 8 : H - H * 0.0625 - h, width: SideButton.width, height: h)
            b.isHidden = small || (full && i != 3)
        }
        if sides.count == 4 { sides[3].chosen = full }
        image.frame = area
        scroll.frame = area
        text.frame.size.width = scroll.contentSize.width
        if let table {
            // a table narrower than its place stands in its middle
            let cells = table.widths.reduce(0, +)
            table.inset.width = max(24, (scroll.contentSize.width - cells) / 2)
            let s = table.size
            table.frame = NSRect(x: 0, y: 0, width: max(s.width, scroll.contentSize.width), height: max(s.height, scroll.contentSize.height))
            table.needsDisplay = true
        }
        foot.frame = NSRect(x: 0, y: H - (small ? 8 : H * 0.0625 - 6) - 30, width: W, height: 24)
    }
}
