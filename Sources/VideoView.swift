import AppKit
import AVFoundation

// A video as ReSurf shows a page: in a card, the folder's name above it, under it the video's name between
// < and > (the folder's other videos). BACK at the top left, FULL at the bottom right (the card over nearly
// the whole window). In the card, over the picture's foot, the line and the time, gone while it plays and
// the mouse rests. Space plays and pauses, ← → ten seconds, ⇧← ⇧→ the video before / after.

final class VideoView: Flipped {
    private let paths: [String]
    private var index: Int
    private let onClose: () -> Void
    private let player = AVPlayer()
    private let card = Flipped()
    private let picture = AVPlayerLayer()
    private let foot = Flipped()
    private let shade = CAGradientLayer()
    private let left = label("0:00", Fonts.words(14), NSColor(white: 0.91, alpha: 0.85))
    private let right = label("0:00", Fonts.words(14), NSColor(white: 0.91, alpha: 0.85), align: .right)
    private let bar = Bar()
    private let paused = PlayButton()
    private let failed = label("This video doesn't play here.", Fonts.words(18), NSColor(white: 0.91, alpha: 0.7), align: .center)
    private let titleLabel = titleField()
    private let name = titleField()
    private let prev = WordButton("<", font: Fonts.buttons(26)) {}
    private let next = WordButton(">", font: Fonts.buttons(26)) {}
    private let back = SideButton("BACK") {}
    private let fullButton = SideButton("FULL") {}
    private var full = Saved.word("videoFull") == "1"
    private var timeObserver: Any?
    private var restTimer: Timer?
    private var tracking: NSTrackingArea?

    init(paths: [String], start: Int, onClose: @escaping () -> Void) {
        self.paths = paths
        index = start
        self.onClose = onClose
        super.init(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.cgColor
        card.layer?.masksToBounds = true
        picture.player = player
        picture.videoGravity = .resizeAspect
        card.layer?.addSublayer(picture)
        addSubview(card)
        foot.wantsLayer = true
        shade.colors = [NSColor(white: 0, alpha: 0.55).cgColor, NSColor.clear.cgColor]
        foot.layer?.addSublayer(shade)
        bar.seek = { [weak self] f in
            guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite else { return }
            self.player.seek(to: CMTime(seconds: d * f, preferredTimescale: 600))
        }
        for v in [left, right, bar] as [NSView] { foot.addSubview(v) }
        card.addSubview(foot)
        paused.word = "PLAY"
        paused.action = { [weak self] in self?.toggle() }
        card.addSubview(paused)
        failed.isHidden = true
        card.addSubview(failed)
        addSubview(titleLabel)
        addSubview(name)
        prev.action = { [weak self] in self?.step(-1) }
        prev.toolTip = "Previous video (⇧←)"
        next.action = { [weak self] in self?.step(1) }
        next.toolTip = "Next video (⇧→)"
        addSubview(prev)
        addSubview(next)
        back.title = "Back to the folder (Esc)"
        back.action = { [weak self] in self?.close() }
        fullButton.title = "Video fills the window (F)"
        fullButton.action = { [weak self] in self?.toggleFull() }
        addSubview(back)
        addSubview(fullButton)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in self?.tick() }
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        restTimer?.invalidate()
        onClose()
    }

    private func load() {
        let path = paths[index]
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        player.replaceCurrentItem(with: item)
        failed.isHidden = true
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.index < self.paths.count - 1 { self.step(1) } else { self.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if item.status == .failed { self?.failed.isHidden = false }
        }
        player.play()
        let url = URL(fileURLWithPath: path)
        name.stringValue = url.deletingPathExtension().lastPathComponent
        name.toolTip = name.stringValue
        titleLabel.stringValue = url.deletingLastPathComponent().lastPathComponent
        titleLabel.toolTip = path
        prev.alphaValue = index == 0 ? 0.18 : 0.6
        next.alphaValue = index == paths.count - 1 ? 0.18 : 0.6
        wake()
    }

    private func step(_ d: Int) {
        let n = index + d
        guard n >= 0, n < paths.count else { return }
        index = n
        load()
    }

    private func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        tick()
        wake()
    }

    private func seekBy(_ s: Double) {
        let now = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? 0
        player.seek(to: CMTime(seconds: min(max(now + s, 0), d.isFinite ? d : now + s), preferredTimescale: 600))
    }

    private func toggleFull() {
        full.toggle()
        Saved.setWord("videoFull", full ? "1" : "0")
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3
            c.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private var playing: Bool { player.timeControlStatus != .paused }

    private func tick() {
        let t = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? 0
        left.stringValue = clock(Int64((t.isFinite ? t : 0) * 1000))
        right.stringValue = clock(Int64((d.isFinite ? d : 0) * 1000))
        bar.progress = d.isFinite && d > 0 ? t / d : 0
        paused.isHidden = playing || !failed.isHidden
    }

    /// the line in the card rests with the mouse while the video plays
    private func wake() {
        foot.alphaValue = 1
        NSCursor.setHiddenUntilMouseMoves(false)
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
            guard let self, self.playing else { return }
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.5
                self.foot.animator().alphaValue = 0
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseMoved(with event: NSEvent) { wake() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard card.frame.contains(p) else { return }
        if event.clickCount == 2 { toggleFull() } else if !foot.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY).contains(p) { toggle() }
    }

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) { return false }
        wake()
        switch (e.keyCode, mods) {
        case (49, []), (40, []): toggle()
        case (123, []): seekBy(-10)
        case (124, []): seekBy(10)
        case (123, .shift): step(-1)
        case (124, .shift): step(1)
        case (3, []): toggleFull()
        case (53, _): if full { toggleFull() } else { close() }
        default: return false
        }
        return true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let small = W < 760 || H < 560
        card.frame = full ? bounds.insetBy(dx: 6, dy: 6)
            : NSRect(x: W * Spacing.x + 80, y: H * Spacing.y + 24, width: W - 2 * (W * Spacing.x + 80), height: H - 2 * (H * Spacing.y + 24))
        if small && !full { card.frame = NSRect(x: 24, y: 48, width: W - 48, height: H - 96) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = card.bounds
        CATransaction.commit()
        foot.frame = NSRect(x: 0, y: card.bounds.height - 82, width: card.bounds.width, height: 82)
        shade.frame = foot.bounds
        left.frame = NSRect(x: 24, y: 48, width: 56, height: 20)
        right.frame = NSRect(x: foot.bounds.width - 24 - 56, y: 48, width: 56, height: 20)
        bar.frame = NSRect(x: 24 + 56 + 14, y: 48, width: max(0, foot.bounds.width - 2 * (24 + 56 + 14)), height: 18)
        paused.frame = NSRect(x: (card.bounds.width - paused.width) / 2, y: card.bounds.height / 2 - 16, width: paused.width, height: 32)
        failed.frame = NSRect(x: 0, y: card.bounds.height / 2 - 12, width: card.bounds.width, height: 24)
        for v in [titleLabel, name, prev, next, back, fullButton] as [NSView] { v.isHidden = full }
        let tw = W * 0.6
        titleLabel.frame = NSRect(x: (W - tw) / 2, y: H * Spacing.y / 2 + 12 - 16, width: tw, height: 32)
        let nw = min(W * 0.7 - 120, attributed(name.stringValue, Fonts.words(18)).size().width + 8)
        let py = H - (H * Spacing.y / 2 + 12) - 16
        name.frame = NSRect(x: (W - nw) / 2, y: py, width: nw, height: 32)
        prev.frame = NSRect(x: name.frame.minX - 64 - 24, y: py, width: 24, height: 32)
        next.frame = NSRect(x: name.frame.maxX + 64, y: py, width: 24, height: 32)
        back.top = true
        let bh = back.intrinsicContentSize.height
        back.frame = NSRect(x: W * Spacing.x - 28, y: H * Spacing.y + 8, width: SideButton.width, height: bh)
        let fh = fullButton.intrinsicContentSize.height
        fullButton.frame = NSRect(x: W - (W * Spacing.x - 28) - SideButton.width, y: H - H * Spacing.y - fh, width: SideButton.width, height: fh)
        fullButton.chosen = full
        back.isHidden = back.isHidden || small
        fullButton.isHidden = fullButton.isHidden || small
    }
}
