import AppKit
import PDFKit
import WebKit

// VIEW's reading (what ReBook's was), of a book where it lies. PDFs and comics are page by page: portrait
// pages come two at a time, a landscape page alone (Spreads). An EPUB's text flows into pages, two columns
// when the window is wide. MANGA (M): right to left. FULL (F): the pages fill the window. The place each book
// was left at is kept by its path.

final class Reader: Flipped, WKNavigationDelegate {
    private let path: String
    private let format: String
    private let onClose: () -> Void
    private var place: Place
    private let titleLabel = titleField()
    private let back = SideButton("BACK") {}
    private let fullButton = SideButton("FULL") {}
    private let manga = SideButton("MANGA") {}
    private let prev = WordButton("<", font: Fonts.buttons(26)) {}
    private let next = WordButton(">", font: Fonts.buttons(26)) {}
    private let pageLabel = label("", Fonts.words(16), align: .center)
    private let stage = Flipped()
    private let error = NSTextField(wrappingLabelWithString: "")
    private var full = false

    // page by page (PDF, comics)
    private var pdf: PDFDocument?
    private var comic: [URL] = []
    private var sizes: [NSSize] = []
    private var spreads: [[Int]] = []
    private var current = 0
    private var pages: [ImageBox] = []
    private var paged: Bool { format != "epub" }

    // EPUB
    private var web: WKWebView?
    private var chapters: [URL] = []
    private var chapter = 0
    private var page = 0
    private var pageCount = 1
    private var root: URL?
    private var pendingLast = false

    init(path: String, onClose: @escaping () -> Void) {
        self.path = path
        format = Files.ext(path)
        self.onClose = onClose
        place = Places.of(path)
        super.init(frame: .zero)
        titleLabel.stringValue = (Files.name(path) as NSString).deletingPathExtension
        titleLabel.toolTip = path
        addSubview(titleLabel)
        addSubview(stage)
        back.boxed = true
        back.title = "Back to the folder (Esc)"
        back.action = { [weak self] in self?.close() }
        fullButton.boxed = true
        fullButton.title = "Pages fill the window (F, Esc back)"
        fullButton.action = { [weak self] in self?.toggleFull() }
        manga.title = "Manga: right to left (M)"
        manga.action = { [weak self] in self?.toggleManga() }
        manga.chosen = place.rtl
        for v in [back, fullButton, manga, prev, next, pageLabel] as [NSView] { addSubview(v) }
        prev.action = { [weak self] in self?.goLeft() }
        next.action = { [weak self] in self?.goRight() }
        error.font = Fonts.words(18)
        error.textColor = Ink.text
        error.alignment = .center
        error.isHidden = true
        addSubview(error)
        manga.isHidden = !paged
        open()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func close() {
        onClose()
    }

    private func fail(_ why: String) {
        error.stringValue = "This book couldn't be opened.\n\(why)"
        error.isHidden = false
        needsLayout = true
    }

    private func open() {
        if format == "pdf" {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return fail("Not a PDF it can read.") }
            pdf = doc
            sizes = (0..<doc.pageCount).map { doc.page(at: $0)?.bounds(for: .mediaBox).size ?? NSSize(width: 600, height: 800) }
            layOutSpreads(keep: Int(place.position ?? "0") ?? 0)
        } else if format == "cbz" || format == "cbr" {
            pageLabel.stringValue = "⋯"
            DispatchQueue.global(qos: .userInitiated).async {
                let list = Comic.pages(self.path)
                let dims = list.map { u -> NSSize in
                    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                          let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat else { return NSSize(width: 600, height: 900) }
                    return NSSize(width: w, height: h)
                }
                DispatchQueue.main.async {
                    guard !list.isEmpty else { return self.fail("No pages in it.") }
                    self.comic = list
                    self.sizes = dims
                    self.layOutSpreads(keep: Int(self.place.position ?? "0") ?? 0)
                }
            }
        } else {
            openEpub()
        }
    }

    // ── page by page ──

    private var single: Bool { bounds.width < 760 || bounds.height < 560 }

    private func layOutSpreads(keep page: Int) {
        spreads = Spreads.build(sizes, single: single)
        current = Spreads.of(spreads, page: page)
        showSpread()
    }

    private var spread: [Int] { current < spreads.count ? spreads[current] : [] }

    private func showSpread() {
        pages.forEach { $0.removeFromSuperview() }
        let shown = place.rtl ? spread.reversed() : spread
        pages = shown.map { _ in ImageBox() }
        pages.forEach(stage.addSubview)
        pageLabel.stringValue = Spreads.label(spread, total: sizes.count)
        if let first = spread.first, let last = spread.last {
            Places.keep(path, position: String(first), progress: Double(last + 1) / Double(max(1, sizes.count)))
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        drawPages(Array(shown))
    }

    private func drawPages(_ shown: [Int]) {
        let scale = window?.backingScaleFactor ?? 2
        for (box, i) in zip(pages, shown) {
            let size = box.bounds.size
            if let pdf, let p = pdf.page(at: i) {
                box.image = p.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
            } else if i < comic.count {
                let url = comic[i]
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = NSImage(contentsOf: url)
                    DispatchQueue.main.async { box.image = img }
                }
            }
        }
    }

    private func go(_ target: Int) {
        guard target != current, target >= 0, target < spreads.count else { return }
        current = target
        showSpread()
    }

    private func nextPage() {
        if paged { go(min(current + 1, spreads.count - 1)) } else { epubStep(1) }
    }

    /// going back from the first page returns to the folder
    private func prevPage() {
        if paged {
            if current == 0 { close() } else { go(current - 1) }
        } else {
            epubStep(-1)
        }
    }

    // which way the arrows and sides turn depends on the reading direction
    private func goLeft() { place.rtl ? nextPage() : prevPage() }
    private func goRight() { place.rtl ? prevPage() : nextPage() }

    private func toggleManga() {
        place.rtl.toggle()
        manga.chosen = place.rtl
        Places.keep(path, rtl: place.rtl)
        if paged { showSpread() }
    }

    /// FULL in VIEW's window: the book opened with its pages filling the window at once
    func fillWindow() { if !full { toggleFull() } }

    private func toggleFull() {
        full.toggle()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if paged { showSpread() } else { relayoutEpub() }
    }

    // ── EPUB: its chapters, each laid into pages of columns ──

    private func openEpub() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let dir = Comic.folder(self.path) else { return DispatchQueue.main.async { self.fail("Not an EPUB it can read.") } }
            let list = Self.spine(dir)
            DispatchQueue.main.async {
                guard !list.isEmpty else { return self.fail("No chapters in it.") }
                self.root = dir
                self.chapters = list
                // where it was left: "chapter:page"; one kept before as an EPUB CFI starts from how far it was
                if let p = self.place.position, p.contains(":"), !p.hasPrefix("epubcfi") {
                    let parts = p.split(separator: ":").compactMap { Int($0) }
                    self.chapter = min(parts.first ?? 0, list.count - 1)
                    self.page = parts.count > 1 ? parts[1] : 0
                } else {
                    self.chapter = min(list.count - 1, Int(self.place.progress * Double(list.count)))
                }
                self.makeWeb()
                self.loadChapter()
            }
        }
    }

    /// the book's chapters in reading order (container.xml → its package → the spine)
    private static func spine(_ dir: URL) -> [URL] {
        guard let container = try? String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let r = container.range(of: #"full-path="([^"]+)""#, options: .regularExpression) else { return [] }
        let opfPath = String(container[r]).replacingOccurrences(of: "full-path=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let opf = dir.appendingPathComponent(opfPath)
        guard let xml = try? XMLDocument(contentsOf: opf, options: []) else { return [] }
        let base = opf.deletingLastPathComponent()
        var manifest: [String: String] = [:]
        for item in (try? xml.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let e = item as? XMLElement, let id = e.attribute(forName: "id")?.stringValue, let href = e.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = href.removingPercentEncoding ?? href
        }
        var out: [URL] = []
        for ref in (try? xml.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            guard let e = ref as? XMLElement, let id = e.attribute(forName: "idref")?.stringValue, let href = manifest[id] else { continue }
            out.append(base.appendingPathComponent(href))
        }
        return out
    }

    private func makeWeb() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let w = WKWebView(frame: .zero, configuration: config)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        stage.addSubview(w)
        web = w
        // the words' font, where the book's pages can read it
        if let root, let font = Bundle.main.url(forResource: "MPLUS1p", withExtension: "ttf", subdirectory: "fonts") {
            try? FileManager.default.copyItem(at: font, to: root.appendingPathComponent("refile-words.ttf"))
        }
        needsLayout = true
    }

    private func loadChapter() {
        guard let web, let root, chapter < chapters.count else { return }
        web.loadFileURL(chapters[chapter], allowingReadAccessTo: root)
    }

    private var columns: Int { stage.bounds.width >= 800 ? 2 : 1 }

    private var css: String {
        let fontURL = root?.appendingPathComponent("refile-words.ttf").absoluteString ?? ""
        return """
        @font-face { font-family: 'ReFileWords'; src: url('\(fontURL)'); }
        html { height: 100%; overflow: hidden !important; }
        body { margin: 0 !important; padding: 0 !important; height: 100vh !important; box-sizing: border-box;
          column-count: \(columns); column-gap: 48px; column-fill: auto;
          font-family: 'ReFileWords', sans-serif !important; color: rgba(255,255,255,0.8) !important;
          background: transparent !important; line-height: 1.75 !important; font-size: 17px; overflow: visible !important; }
        body * { color: rgba(255,255,255,0.8) !important; background: transparent !important; }
        p, li, blockquote { font-family: 'ReFileWords', sans-serif !important; }
        img, svg { max-width: 100% !important; max-height: 92vh !important; object-fit: contain; }
        a { color: rgba(255,255,255,0.8) !important; }
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        (function(){var s=document.createElement('style');s.textContent=\(jsString(css));document.head.appendChild(s);
        var step=window.innerWidth+48;return Math.max(1,Math.ceil((document.scrollingElement.scrollWidth+48-1)/step));})()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            self.pageCount = (result as? Int) ?? 1
            if self.pendingLast { self.page = self.pageCount - 1; self.pendingLast = false }
            self.page = min(self.page, self.pageCount - 1)
            self.showPage()
        }
    }

    // links inside the book stay in it; others go to the browser
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.isFileURL, let i = chapters.firstIndex(where: { $0.path == url.path }) {
                chapter = i
                page = 0
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    private func showPage() {
        web?.evaluateJavaScript("document.scrollingElement.scrollLeft = \(page) * (window.innerWidth + 48)")
        let progress = (Double(chapter) + Double(page + 1) / Double(max(1, pageCount))) / Double(max(1, chapters.count))
        pageLabel.stringValue = "\(Int((progress * 100).rounded()))%"
        Places.keep(path, position: "\(chapter):\(page)", progress: progress)
    }

    private func epubStep(_ d: Int) {
        if d > 0 {
            if page + 1 < pageCount { page += 1; return showPage() }
            if chapter + 1 < chapters.count { chapter += 1; page = 0; loadChapter() }
        } else {
            if page > 0 { page -= 1; return showPage() }
            if chapter > 0 { chapter -= 1; pendingLast = true; loadChapter() } else { close() }
        }
    }

    private func relayoutEpub() {
        // the pages laid again for the new size: the same chapter, its page as far in as it was
        let fraction = Double(page) / Double(max(1, pageCount))
        loadChapter()
        page = Int(fraction * Double(pageCount))
    }

    // ── keys and laid out ──

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) { return false }
        switch e.keyCode {
        case 124: goRight()
        case 123: goLeft()
        case 121, 49: nextPage()   // PageDown, Space
        case 116: prevPage()       // PageUp
        case 46 where paged: toggleManga()
        case 115 where paged: go(0)                        // Home
        case 119 where paged: go(max(0, spreads.count - 1)) // End
        case 53: if full { toggleFull() } else { close() }
        case 3: toggleFull()
        default: return true
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard paged, stage.frame.contains(p) else { return }
        // a click on the left or right side of the page turns it
        if p.x < stage.frame.midX { goLeft() } else { goRight() }
    }

    private var lastSize = NSSize.zero

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let small = W < 760 || H < 560
        stage.frame = full ? bounds.insetBy(dx: 6, dy: 6)
            : small ? NSRect(x: 24, y: 48, width: W - 48, height: H - 96)
            : NSRect(x: W * 0.0625 + 44, y: H * 0.0625 + 24, width: W - 2 * (W * 0.0625 + 44), height: H - 2 * (H * 0.0625 + 24))
        for v in [titleLabel, back, fullButton, prev, next, pageLabel] as [NSView] { v.isHidden = full }
        manga.isHidden = full || !paged || small
        if small { back.isHidden = true; fullButton.isHidden = true }
        let tw = small ? W - 200 : W * 0.5
        titleLabel.frame = NSRect(x: (W - tw) / 2, y: small ? 8 : H * 0.03125 + 12 - 16, width: tw, height: 32)
        let bh = back.intrinsicContentSize.height
        back.frame = NSRect(x: W * 0.0625 - 28, y: (H - bh) / 2, width: SideButton.width, height: bh)
        fullButton.frame = NSRect(x: W - (W * 0.0625 - 28) - SideButton.width, y: (H - bh) / 2, width: SideButton.width, height: bh)
        manga.top = true
        let mh = manga.intrinsicContentSize.height
        manga.frame = NSRect(x: W - (W * 0.0625 - 28) - SideButton.width, y: H * 0.0625 + 8, width: SideButton.width, height: mh)
        let py = H - (small ? 8 : H * 0.03125 + 12) - 16
        let lw: CGFloat = 120
        pageLabel.frame = NSRect(x: (W - lw) / 2, y: py + 6, width: lw, height: 22)
        prev.frame = NSRect(x: (W - lw) / 2 - 24 - 24, y: py, width: 24, height: 32)
        next.frame = NSRect(x: (W + lw) / 2 + 24, y: py, width: 24, height: 32)
        error.preferredMaxLayoutWidth = min(600, W - 80)
        error.frame = NSRect(x: (W - min(600, W - 80)) / 2, y: H / 2 - 30, width: min(600, W - 80), height: 60)

        if paged {
            let shown = place.rtl ? spread.reversed() : spread
            let ratios = shown.map { i -> CGFloat in i < sizes.count && sizes[i].height > 0 ? sizes[i].width / sizes[i].height : 0.7 }
            let total = ratios.reduce(0, +)
            let h = total > 0 ? min(stage.bounds.height, stage.bounds.width / total) : 0
            var x = (stage.bounds.width - h * total) / 2
            for (box, r) in zip(pages, ratios) {
                box.frame = NSRect(x: x, y: (stage.bounds.height - h) / 2, width: floor(h * r), height: floor(h))
                if pdf != nil { box.wantsLayer = true; box.layer?.backgroundColor = NSColor.white.cgColor }
                x += floor(h * r)
            }
            // a small window shows one page at a time, staying on the same page
            if lastSize != bounds.size, !sizes.isEmpty, (lastSize.width < 760 || lastSize.height < 560) != single || lastSize == .zero {
                lastSize = bounds.size
                DispatchQueue.main.async { self.layOutSpreads(keep: self.spread.first ?? 0) }
            }
            lastSize = bounds.size
        } else if let web {
            let changed = web.frame.size != stage.bounds.size
            web.frame = stage.bounds
            if changed && !chapters.isEmpty { DispatchQueue.main.async { self.relayoutEpub() } }
        }
    }
}

private func jsString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}
