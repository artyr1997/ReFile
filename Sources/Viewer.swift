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
    private let close = SideButton("CLOSE") {}
    private let truncated: Bool
    private var saved = ""
    private var timer: DispatchWorkItem?
    private(set) var edited = false
    var onClose: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var position: String? { didSet { showFoot() } }

    init(entry: Entry, image img: NSImage) {
        self.entry = entry
        truncated = false
        text = NSTextView()
        super.init(frame: .zero)
        image.image = img
        setUp()
        scroll.isHidden = true
    }

    init(entry: Entry, text t: String, truncated: Bool) {
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
        close.boxed = true
        close.title = "Close (Esc)"
        close.action = { [weak self] in self?.onClose?() }
        addSubview(close)
        showFoot()
    }

    private func showFoot() {
        var s = Files.size(entry.size)
        if truncated { s += " · the first megabyte, not editable" }
        if let position { s += " · \(position)" }
        foot.stringValue = s
    }

    func focus() {
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
        guard !scroll.isHidden, !truncated, text.string != saved else { return }
        do {
            try Files.write(text.string, to: entry.path)
            saved = text.string
            edited = true
        } catch {
            (superview as? FileView)?.showToast("NOT SAVED")
        }
    }

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === text {
            // in the text: it's typing, but for Esc (close) and ⌘S
            if e.keyCode == 53 { onClose?(); return true }
            if mods == .command && e.keyCode == 1 { save(); return true }
            return false
        }
        switch e.keyCode {
        case 53, 49: onClose?()
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
        let area = small ? NSRect(x: 40, y: 52, width: W - 80, height: H - 104)
            : NSRect(x: W * 0.0625 + 60, y: H * 0.0625 + 40, width: W - 2 * (W * 0.0625 + 60), height: H - 2 * H * 0.0625 - 84)
        image.frame = area
        scroll.frame = area
        text.frame.size.width = scroll.contentSize.width
        foot.frame = NSRect(x: 0, y: H - (small ? 8 : H * 0.0625 - 6) - 30, width: W, height: 24)
        let h = close.intrinsicContentSize.height
        close.frame = NSRect(x: W * 0.0625 - 28, y: (H - h) / 2, width: SideButton.width, height: h)
        close.isHidden = small
    }
}
