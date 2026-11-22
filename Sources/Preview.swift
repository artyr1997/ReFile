import AppKit
import QuickLookThumbnailing

// The right column: what the item chosen holds. A folder: its items (VIEW: its pictures and books, small;
// TEXT: its texts as small pages). A file: VIEW the picture or the book's cover, big, what it is under it;
// TEXT the start of the text as a page; FILE a look at it over its details.

/// pictures drawn small (and books' covers, videos' first frames), by the system, kept while ReFile runs
enum Thumbs {
    private static var made: [String: NSImage] = [:]
    private static var none = Set<String>()
    private static var asked: [String: [(NSImage?) -> Void]] = [:]

    static func get(_ path: String, size: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        let key = "\(path)|\(Int(size))"
        if let img = made[key] { return done(img) }
        if none.contains(key) { return done(nil) }
        if asked[key] != nil { asked[key]!.append(done); return }
        asked[key] = [done]
        let finish = { (img: NSImage?) in
            DispatchQueue.main.async {
                if let img { made[key] = img } else { none.insert(key) }
                for d in asked.removeValue(forKey: key) ?? [] { d(img) }
            }
        }
        // a comic: its first page
        let e = Files.ext(path)
        if e == "cbz" || e == "cbr" {
            DispatchQueue.global(qos: .utility).async { finish(Comic.cover(path)) }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size * 1.4),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in finish(rep?.nsImage) }
    }
}

/// a picture, fitted into its place (or filling it)
final class ImageBox: Flipped {
    var image: NSImage? { didSet { needsDisplay = true } }
    var fill = false
    var corner: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let k = fill ? max(bounds.width / s.width, bounds.height / s.height) : min(bounds.width / s.width, bounds.height / s.height, fill ? .infinity : 1e9)
        let d = NSSize(width: s.width * k, height: s.height * k)
        let r = NSRect(x: (bounds.width - d.width) / 2, y: (bounds.height - d.height) / 2, width: d.width, height: d.height)
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// where the picture lies in it
    var drawnRect: NSRect {
        guard let s = image?.size, s.width > 0, s.height > 0 else { return .zero }
        let k = min(bounds.width / s.width, bounds.height / s.height)
        let d = NSSize(width: s.width * k, height: s.height * k)
        return NSRect(x: (bounds.width - d.width) / 2, y: (bounds.height - d.height) / 2, width: d.width, height: d.height)
    }
}

/// the start of a text, as a page: a darker pane, its lines fading out at its foot
final class PageView: Flipped {
    var text = "" { didSet { needsDisplay = true } }
    /// a table's (CSV, TSV) start instead of its text
    var table: [[String]]? {
        didSet {
            if let table {
                if grid.superview == nil { addSubview(grid) }
                grid.fontSize = size
                grid.rows = Array(table.prefix(60))
                grid.isHidden = false
            } else {
                grid.isHidden = true
            }
            needsDisplay = true
            needsLayout = true
        }
    }
    private let grid = TableView()
    var size: CGFloat = 12
    var pad = NSSize(width: 32, height: 28)

    override func draw(_ dirtyRect: NSRect) {
        Ink.pane.setFill()
        bounds.fill()
        if table != nil { return }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size * 1.6
        p.maximumLineHeight = size * 1.6
        p.lineBreakMode = .byCharWrapping
        let s = NSAttributedString(string: text, attributes: [.font: Fonts.mono(size), .foregroundColor: Ink.text, .paragraphStyle: p])
        NSGraphicsContext.saveGraphicsState()
        bounds.insetBy(dx: 0, dy: 0).clip()
        s.draw(with: NSRect(x: pad.width, y: pad.height, width: bounds.width - pad.width * 2, height: bounds.height - pad.height),
               options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layout() {
        super.layout()
        if table != nil {
            grid.inset = NSSize(width: pad.width - 8, height: pad.height - 8)
            grid.frame = NSRect(origin: .zero, size: NSSize(width: max(bounds.width, grid.size.width), height: max(bounds.height, grid.size.height)))
            clipsToBounds = true
        }
        // its foot fades out, as more text goes on
        wantsLayer = true
        let mask = CAGradientLayer()
        mask.frame = bounds
        let flipped = layer?.contentsAreFlipped() ?? false
        mask.colors = flipped ? [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            : [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        mask.locations = flipped ? [0, 0.8, 1] : [0, 0.2, 1]
        layer?.mask = mask
    }
}

/// a small picture (or a text's small page) and its name under it; a click opens its folder on it
final class Thumb: Flipped {
    let entry: Entry
    let image = ImageBox()
    let page = PageView()
    let blank: NSTextField
    let name: NSTextField
    var action: (() -> Void)?

    init(_ entry: Entry, text: Bool) {
        self.entry = entry
        blank = label(Files.ext(entry.name).uppercased().isEmpty ? "TEXT" : Files.ext(entry.name).uppercased(), Fonts.buttons(12), kern: 3.6, align: .center)
        name = label(entry.name, Fonts.words(13))
        super.init(frame: .zero)
        image.fill = true
        page.size = 7
        page.pad = NSSize(width: 11, height: 10)
        page.isHidden = !text
        image.isHidden = text
        addSubview(image)
        addSubview(page)
        addSubview(blank)
        addSubview(name)
        blank.isHidden = true
        toolTip = entry.name
    }

    required init?(coder: NSCoder) { fatalError() }

    /// nothing to show: a frame with what it is in it
    var showsBlank = false { didSet { blank.isHidden = !showsBlank; needsDisplay = true } }

    override func layout() {
        super.layout()
        let r = NSRect(x: 0, y: 0, width: bounds.width, height: 150)
        image.frame = r
        page.frame = r
        blank.frame = NSRect(x: 0, y: 66, width: bounds.width, height: 18)
        name.frame = NSRect(x: 0, y: 158, width: bounds.width, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsBlank else { return }
        Ink.line.setStroke()
        let p = NSBezierPath(rect: NSRect(x: 1, y: 1, width: bounds.width - 2, height: 148))
        p.lineWidth = 2
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class Preview: Flipped {
    enum Content {
        case none
        case message(String)
        case rows([Entry])
        case thumbs([Entry], texts: Bool)
        /// VIEW: a picture or a book's cover, big, and what it is
        case look(Info, meta: String)
        /// TEXT: the text's start as a page, and what it is
        case page(Info, text: String?, meta: String)
        /// FILE: a look at it, over its details
        case file(Info, size: String, text: String?)
    }

    private(set) var content = Content.none
    let list = ListView()
    private let scroll = FadeScroll()
    private let doc = Flipped()
    private var thumbs: [Thumb] = []
    private let big = ImageBox()
    private let page = PageView()
    private let blank = Flipped()
    private let blankName = label("", Fonts.words(22), align: .center)
    private let meta = label("", Fonts.words(16), Ink.muted, align: .center)
    private let details = NSGridView()
    private let message = label("", Fonts.words(16), NSColor(white: 1, alpha: 0.6 * 0.45))
    /// the window's height (FILE's look takes at most 46% of it)
    var windowHeight: CGFloat = 900
    var openEntry: ((Entry) -> Void)?
    /// a picture's own size, once known (VIEW's meta line)
    var onPictureSize: ((NSSize) -> Void)?
    private var token = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.gap = 22
        list.underline = false
        addSubview(list)
        scroll.documentView = doc
        addSubview(scroll)
        for v in [big, page, blank, meta, details, message] as [NSView] { addSubview(v) }
        blank.addSubview(blankName)
        blank.wantsLayer = true
        blank.layer?.borderColor = Ink.line.cgColor
        blank.layer?.borderWidth = 2
        blankName.cell?.wraps = true
        blankName.maximumNumberOfLines = 4
        details.columnSpacing = 20
        details.rowSpacing = 14
        list.onSelect = { [weak self] i in
            guard let self, case .rows(let entries) = self.content, i < entries.count else { return }
            self.openEntry?(entries[i])
        }
        show(.none)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: Content) {
        content = c
        token += 1
        let t = token
        for v in [list, scroll, big, page, blank, meta, details, message] as [NSView] { v.isHidden = true }
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = []
        big.image = nil
        switch c {
        case .none: break
        case .message(let m):
            message.stringValue = m
            message.isHidden = false
        case .rows(let entries):
            list.lines = entries.map { Line(cells: [$0.name]) }
            list.empty = "Empty."
            list.isHidden = false
            list.reveal(0)
        case .thumbs(let entries, let texts):
            scroll.isHidden = false
            for e in entries {
                let th = Thumb(e, text: texts)
                th.action = { [weak self] in self?.openEntry?(e) }
                doc.addSubview(th)
                thumbs.append(th)
                if texts {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let head = Files.head(e.path, max: 700)
                        DispatchQueue.main.async {
                            guard t == self.token else { return }
                            if let head { th.page.text = head.text } else { th.page.isHidden = true; th.showsBlank = true }
                        }
                    }
                } else {
                    Thumbs.get(e.path, size: 240) { img in
                        guard t == self.token else { return }
                        if let img { th.image.image = img } else { th.showsBlank = true }
                    }
                }
            }
        case .look(let info, let m):
            meta.stringValue = m
            meta.isHidden = false
            let kind = Files.kind(info.name)
            let showPicture = { (img: NSImage?) in
                guard t == self.token else { return }
                if let img {
                    self.big.image = img
                    self.big.isHidden = false
                    self.blank.isHidden = true
                    if kind == .image { self.onPictureSize?(img.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size) }
                } else {
                    self.blankName.stringValue = (info.name as NSString).deletingPathExtension
                    self.blank.isHidden = false
                }
                self.needsLayout = true
            }
            if kind == .image {
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = NSImage(contentsOfFile: info.path)
                    DispatchQueue.main.async { showPicture(img) }
                }
            } else {
                // a moment on the book first: running down the list doesn't draw every cover
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard t == self.token else { return }
                    Thumbs.get(info.path, size: 480, showPicture)
                }
            }
        case .page(let info, let text, let m):
            meta.stringValue = m
            meta.isHidden = false
            if let text {
                page.size = 12
                page.pad = NSSize(width: 32, height: 28)
                page.text = text
                page.table = Table.isTable(info.name) ? Table.parse(text, name: info.name, limit: 60) : nil
                page.isHidden = false
            } else {
                blankName.stringValue = "Not text after all."
                blank.isHidden = false
            }
        case .file(let info, let size, let text):
            fill(details, [("Kind", info.kind), ("Size", size), ("Modified", Files.date(info.modified)), ("Created", Files.date(info.created))])
            details.isHidden = false
            let kind = Files.kind(info.name)
            if kind == .text, let text {
                page.size = 12
                page.pad = NSSize(width: 32, height: 28)
                page.text = text
                page.table = Table.isTable(info.name) ? Table.parse(text, name: info.name, limit: 60) : nil
                page.isHidden = false
            } else if kind == .image || kind == .book || kind == .video {
                Thumbs.get(info.path, size: 520) { img in
                    guard t == self.token, let img else { return }
                    self.big.image = img
                    self.big.isHidden = false
                    self.needsLayout = true
                }
            }
        }
        needsLayout = true
    }

    /// the line under VIEW's look, once the picture's size is known
    func updateMeta(_ m: String) { meta.stringValue = m }

    /// a details grid: each name small and spaced, its value beside it
    func fill(_ grid: NSGridView, _ rows: [(String, String)]) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        grid.subviews.forEach { $0.removeFromSuperview() }
        for (name, value) in rows {
            let n = label(tx(name).uppercased(), Fonts.buttons(12), NSColor(white: 1, alpha: 0.8 * 0.55), kern: 3.6)
            let v = NSTextField(wrappingLabelWithString: value)
            v.font = Fonts.words(16)
            v.textColor = Ink.text
            v.isSelectable = false
            grid.addRow(with: [n, v])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .leading }
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        list.frame = bounds
        message.frame = NSRect(x: 9.6, y: 6.4, width: W, height: 22)
        switch content {
        case .thumbs:
            scroll.frame = bounds
            let gapX: CGFloat = 18, gapY: CGFloat = 22
            let inner = scroll.contentSize.width - 19.2
            let cols = max(1, Int((inner + gapX) / (120 + gapX)))
            let w = (inner - gapX * CGFloat(cols - 1)) / CGFloat(cols)
            for (i, th) in thumbs.enumerated() {
                th.frame = NSRect(x: 9.6 + CGFloat(i % cols) * (w + gapX), y: 6.4 + CGFloat(i / cols) * (176 + gapY), width: w, height: 176)
            }
            let rows = (thumbs.count + cols - 1) / cols
            doc.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, 12.8 + CGFloat(rows) * (176 + gapY)))
            scroll.update()
        case .look, .page:
            // the picture (or the page) and what it is under it, in the middle of the column
            let metaH: CGFloat = 22, gap: CGFloat = 18
            let room = NSRect(x: 9.6, y: 6.4, width: W - 19.2, height: max(0, H - 12.8 - 60))
            var shown = room
            if !big.isHidden, let s = big.image?.size, s.width > 0 {
                let k = min(room.width / s.width, room.height / s.height)
                shown.size = NSSize(width: s.width * k, height: s.height * k)
            } else if !blank.isHidden {
                let w = min(260, room.width)
                shown.size = NSSize(width: w, height: min(room.height, w * 1.5))
            } else if !page.isHidden {
                shown.size = NSSize(width: room.width, height: room.height)
            }
            let total = shown.height + gap + metaH
            let y = 6.4 + max(0, (H - 12.8 - total) / 2)
            shown.origin = NSPoint(x: 9.6 + (room.width - shown.width) / 2, y: y)
            big.frame = shown
            page.frame = shown
            blank.frame = shown
            blankName.frame = NSRect(x: 24, y: shown.height / 2 - 40, width: max(0, shown.width - 48), height: 80)
            meta.frame = NSRect(x: 9.6, y: shown.maxY + gap, width: room.width, height: metaH)
        case .file:
            var y: CGFloat = 6.4
            // the look over the details, as tall as leaves them room
            let maxH = max(0, min(windowHeight * 0.46, H - 12.8 - details.fittingSize.height - 30))
            if !big.isHidden, let s = big.image?.size, s.width > 0 {
                let k = min((W - 19.2) / s.width, maxH / s.height)
                big.frame = NSRect(x: 9.6, y: y, width: s.width * k, height: s.height * k)
                y = big.frame.maxY + 30
            } else if !page.isHidden {
                page.frame = NSRect(x: 9.6, y: y, width: W - 19.2, height: maxH)
                y = page.frame.maxY + 30
            }
            details.frame = NSRect(x: 9.6, y: y, width: W - 19.2, height: details.fittingSize.height)
        default:
            break
        }
    }
}
