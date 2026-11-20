import AppKit

// PLAY: three views (1 / 2 / 3; no tabs shown): FOLDER (ReFile's own list, of music and videos only),
// SONGS (every song of the music folder) and RADIO (genres and their stations); the player under them all,
// < and > beside PLAY. A tiny window (or FULL, ⌘F) is the player alone, filling the window.

final class PlayView: Flipped {
    private weak var main: FileView?
    var chosenMini = false

    private let songs = ListView()
    private let genres = ListView()
    private let stations = ListView()
    private let welcome = Flipped()
    private let welcomeText = label("", Fonts.words(24), align: .center)
    private let now = label("", Fonts.words(18), align: .center)
    private let bar = Bar()
    private let left = label("0:00", Fonts.words(15), NSColor(white: 1, alpha: 0.8 * 0.6))
    private let right = label("0:00", Fonts.words(15), NSColor(white: 1, alpha: 0.8 * 0.6), align: .right)
    private let prev = WordButton("<", font: Fonts.buttons(20)) {}
    private let next = WordButton(">", font: Fonts.buttons(20)) {}
    private let playButton = PlayButton()
    private let miniTitle = NSTextField(wrappingLabelWithString: "")
    private let miniArtist = label("", Fonts.words(16), NSColor(white: 1, alpha: 0.8 * 0.6), align: .center)
    private var timer: Timer?

    private var all: [Track] = []
    private var ti = 0
    private var genreNames: [String] = []
    private var byGenre: [String: [Station]] = [:]
    private var found: [Station] = []
    private var gi = 0
    private var si = 0
    private var side = "genres"
    private var radioLoading = false
    private var radioError = ""
    private var searchWork: DispatchWorkItem?

    private var music: Music { .shared }
    private var tab: String { main?.playTab ?? "folder" }
    private var q: String { (main?.query ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    private var mini: Bool { main?.mini ?? false }

    init(main: FileView) {
        self.main = main
        super.init(frame: .zero)
        songs.columns = [Column(share: 2), Column(share: 1, alpha: 0.7), Column(width: 60, size: 15, alpha: 0.6, align: .right)]
        songs.gap = 16
        songs.onSelect = { [weak self] i in self?.ti = i; self?.refresh() }
        songs.onOpen = { [weak self] i in self?.playSongs(from: i) }
        songs.onMenu = { [weak self] i in self?.ti = i; self?.songActions() }
        genres.gap = 16
        genres.onSelect = { [weak self] i in
            guard let self else { return }
            self.gi = i
            self.side = "genres"
            self.main?.search.stringValue = ""
            self.main?.query = ""
            self.loadGenre()
        }
        stations.columns = [Column(share: 2), Column(share: 1, alpha: 0.7), Column(width: 80, size: 13, alpha: 0.45, align: .right)]
        stations.gap = 16
        stations.onSelect = { [weak self] i in self?.si = i; self?.side = "stations"; self?.refresh() }
        stations.onOpen = { [weak self] i in self?.playStation(i) }
        stations.onMenu = { [weak self] i in self?.si = i; self?.toggleFavorite() }
        for v in [songs, genres, stations, welcome, now, bar, left, right, prev, next, playButton, miniTitle, miniArtist] as [NSView] { addSubview(v) }
        welcome.addSubview(welcomeText)
        let choose = BoxButton("CHOOSE FOLDER", size: 16, kern: 3.2, pad: NSSize(width: 22, height: 8)) { [weak self] in self?.chooseFolder() }
        choose.identifier = .init("choose")
        welcome.addSubview(choose)
        miniTitle.font = Fonts.words(24)
        miniTitle.textColor = Ink.text
        miniTitle.alignment = .center
        miniTitle.maximumNumberOfLines = 2
        miniTitle.lineBreakMode = .byTruncatingTail
        prev.action = { [weak self] in self?.music.previous() }
        prev.toolTip = "Previous (⏮)"
        next.action = { [weak self] in self?.music.next() }
        next.toolTip = "Next (⏭)"
        playButton.action = { [weak self] in self?.music.togglePlay() }
        playButton.toolTip = "Play / pause (Space)"
        bar.seek = { [weak self] f in
            guard let t = self?.music.track else { return }
            self?.music.seek(Int64(Double(t.durationMs) * f))
        }
        NotificationCenter.default.addObserver(forName: Music.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: Music.scanned, object: nil, queue: .main) { [weak self] _ in self?.scanned() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        all = music.tracks()
        music.rescan()
        if tab == "radio" { openRadio() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // passes clicks through to the folder's list where it shows nothing
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // ── what is listed ──

    private var tracks: [Track] {
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.artist) \($0.albumArtist) \($0.album)".lowercased().contains(q) }
    }

    private var genreList: [String] { music.favorites.isEmpty ? genreNames : ["Favorites"] + genreNames }
    private var genre: String { gi < genreList.count ? genreList[gi] : "" }
    private var stationList: [Station] {
        if !q.isEmpty { return found }
        return genre == "Favorites" ? music.favorites : byGenre[genre] ?? []
    }

    private func scanned() {
        all = music.tracks()
        ti = min(ti, max(0, tracks.count - 1))
        if music.scanning != nil { main?.showToast("SCAN", seconds: 1) }
        refresh()
    }

    // ── tabs and the mini player ──

    func setTab(_ t: String) {
        guard t != tab else { return }
        main?.setPlayTab(t)
        if t == "radio" { openRadio() }
        refresh()
    }

    private func openRadio() {
        if genreNames.isEmpty {
            genreNames = Radio.genres.map(\.name)
            gi = 0
            loadGenre()
        }
    }

    /// FULL (⌘F): the player alone, filling the window as it is; out of a window made tiny by hand, it grows back
    func setMini(_ on: Bool) {
        chosenMini = on
        if !on, let w = window, w.frame.width < 520 || w.frame.height < 420 {
            var f = w.frame
            f.origin.y -= 900 - f.height
            f.size = NSSize(width: 1440, height: 900)
            w.setFrame(f, display: true, animate: true)
        }
        main?.apply()
    }

    func queryChanged() {
        if tab == "radio" {
            searchWork?.cancel()
            guard !q.isEmpty else { found = []; return refresh() }
            let text = q
            let work = DispatchWorkItem { [weak self] in
                self?.radioLoading = true
                self?.radioError = ""
                self?.refresh()
                Radio.search(text) { r in
                    guard let self else { return }
                    self.radioLoading = false
                    switch r {
                    case .success(let list): self.found = list; self.si = 0; self.side = "stations"
                    case .failure(let e): self.radioError = "Radio Browser didn't answer: \(e.localizedDescription)"
                    }
                    self.refresh()
                }
            }
            searchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            ti = 0
        }
        refresh()
    }

    private func loadGenre() {
        si = 0
        let name = genre
        guard !name.isEmpty, name != "Favorites", byGenre[name] == nil else { return refresh() }
        radioLoading = true
        radioError = ""
        refresh()
        Radio.stations(genre: name) { [weak self] r in
            guard let self else { return }
            self.radioLoading = false
            switch r {
            case .success(let list): self.byGenre[name] = list
            case .failure(let e): self.radioError = "Radio Browser didn't answer: \(e.localizedDescription)"
            }
            self.refresh()
        }
    }

    // ── playing ──

    private func playSongs(from i: Int) {
        let list = tracks
        guard !list.isEmpty else { return }
        music.play(ids: list.map(\.id), start: i)
    }

    private func playStation(_ i: Int? = nil) {
        let list = stationList
        let at = i ?? si
        guard at < list.count else { return }
        si = at
        music.play(station: list[at], list: list)
    }

    private func toggleFavorite() {
        let list = stationList
        guard si < list.count else { return }
        let s = list[si]
        let on = !music.favorites.contains { $0.uuid == s.uuid }
        let was = genre
        music.setFavorite(s, on)
        if was != "Favorites" { gi = max(0, genreList.firstIndex(of: was) ?? 0) } else if music.favorites.isEmpty { gi = 0 }
        main?.showToast(on ? "KEPT" : "LET GO")
        refresh()
    }

    // ── drawn ──

    func refresh() {
        guard let main else { return }
        let showLists = !mini
        let playing = music.track
        let list = tracks
        songs.isHidden = !(showLists && tab == "songs" && !all.isEmpty)
        welcome.isHidden = !(showLists && tab == "songs" && all.isEmpty && music.scanning == nil)
        welcomeText.stringValue = "No music in \(music.folder.map { ($0 as NSString).lastPathComponent } ?? "your folder") yet."
        songs.lines = list.map { Line(cells: [$0.title, $0.artist.isEmpty ? $0.albumArtist : $0.artist, clock($0.durationMs)], dot: $0.id == playing?.id) }
        songs.selected = ti
        songs.empty = q.isEmpty ? "No songs yet." : "Nothing found."

        let radio = showLists && tab == "radio"
        genres.isHidden = !radio
        stations.isHidden = !radio
        genres.lines = genreList.enumerated().map { i, g in Line(cells: [g], alpha: i == gi ? 1 : 0.6) }
        genres.selected = gi
        genres.underline = side == "genres" && q.isEmpty
        genres.dim = q.isEmpty ? 1 : 0.35
        let kept = Set(music.favorites.map(\.uuid))
        stations.lines = stationList.map { s in
            Line(cells: [s.name, s.country, "\(s.codec) \(s.bitrate > 0 ? String(s.bitrate) : "")"], dot: music.station?.uuid == s.uuid,
                 mark: kept.contains(s.uuid) && genre != "Favorites" ? "◆" : nil)
        }
        stations.selected = si
        stations.underline = side == "stations" || !q.isEmpty
        stations.empty = radioLoading ? "Tuning in…" : !radioError.isEmpty ? radioError : !q.isEmpty ? "Nothing found." : genre == "Favorites" ? "No stations kept yet." : "No stations."

        // the player
        let title: NSAttributedString
        if let e = music.error {
            title = attributed(e, Fonts.words(15), Ink.error, align: .center)
        } else if let s = music.station {
            let a = NSMutableAttributedString(attributedString: attributed(plain(music.onAir ?? s.name), Fonts.words(18), align: .center))
            if music.onAir != nil { a.append(attributed(" - \(s.name)", Fonts.words(18), NSColor(white: 1, alpha: 0.8 * 0.6), align: .center)) }
            title = a
        } else if let t = playing {
            let a = NSMutableAttributedString(attributedString: attributed(t.title, Fonts.words(18), align: .center))
            a.append(attributed(" - \(t.artist.isEmpty ? t.albumArtist : t.artist)", Fonts.words(18), NSColor(white: 1, alpha: 0.8 * 0.6), align: .center))
            title = a
        } else {
            title = attributed("Nothing playing.", Fonts.words(18), NSColor(white: 1, alpha: 0.8 * 0.45), align: .center)
        }
        now.attributedStringValue = title
        playButton.word = music.playing ? "STOP" : "PLAY"
        miniTitle.stringValue = music.error ?? (music.station.map { music.onAir ?? $0.name } ?? playing?.title ?? "Nothing playing.")
        miniTitle.textColor = music.error != nil ? Ink.error : (playing == nil && music.station == nil ? NSColor(white: 1, alpha: 0.8 * 0.45) : Ink.text)
        miniArtist.stringValue = music.station.map { music.onAir != nil ? $0.name : $0.country } ?? playing.map { $0.artist.isEmpty ? $0.albumArtist : $0.artist } ?? ""
        now.isHidden = mini
        miniTitle.isHidden = !mini
        miniArtist.isHidden = !mini
        let live = music.station != nil
        for v in [bar, left, right] as [NSView] { v.isHidden = live }
        tick()
        _ = main
        needsLayout = true
    }

    private func tick() {
        let pos = music.positionMs
        let total = music.track?.durationMs ?? 0
        left.stringValue = clock(pos)
        right.stringValue = clock(total)
        bar.progress = total > 0 ? min(1, Double(pos) / Double(total)) : 0
        bar.enabled = music.track != nil
        let word = music.playing ? "STOP" : "PLAY"
        if playButton.word != word { playButton.word = word }
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let small = W < 760 || H < 560
        let area = small ? NSRect(x: 40, y: 52, width: W - 80, height: H - 52 - 128)
            : NSRect(x: W * 0.0625 + 96, y: H * 0.0625 + 40, width: W - 2 * (W * 0.0625 + 96), height: H - H * 0.0625 - 40 - (H * 0.0625 + 112))
        songs.frame = area
        if small {
            songs.columns = [Column(), Column(width: 56, size: 15, alpha: 0.6, align: .right)]
            stations.columns = [Column(), Column(width: 70, alpha: 0.7)]
        } else {
            songs.columns = [Column(share: 2), Column(share: 1, alpha: 0.7), Column(width: 60, size: 15, alpha: 0.6, align: .right)]
            stations.columns = [Column(share: 2), Column(share: 1, alpha: 0.7), Column(width: 80, size: 13, alpha: 0.45, align: .right)]
        }
        if small {
            let gw = (area.width - 20) * 2 / 5
            genres.frame = NSRect(x: area.minX, y: area.minY, width: gw, height: area.height)
            stations.frame = NSRect(x: area.minX + gw + 20, y: area.minY, width: area.width - gw - 20, height: area.height)
        } else {
            genres.frame = NSRect(x: area.minX, y: area.minY, width: 200, height: area.height)
            stations.frame = NSRect(x: area.minX + 248, y: area.minY, width: area.width - 248, height: area.height)
        }
        welcome.frame = NSRect(x: 0, y: H * 0.45 - 60, width: W, height: 120)
        welcomeText.frame = NSRect(x: 0, y: 0, width: W, height: 34)
        if let choose = welcome.subviews.first(where: { $0.identifier?.rawValue == "choose" }) {
            let s = choose.intrinsicContentSize
            choose.frame = NSRect(x: (W - s.width) / 2, y: 66, width: s.width, height: s.height)
        }

        let controlsW: CGFloat = 32 + 26 + playButton.width + 26 + 32
        if mini {
            // the song in the middle, the artist under it, the line, the controls
            let w = min(W - 88, 600)
            let titleH = min(miniTitle.sizeThatFits(NSSize(width: w, height: 80)).height, 64)
            let total = titleH + 10 + 22 + 14 + 18 + 14 + 36
            var y = max(36, (H - total) / 2)
            miniTitle.frame = NSRect(x: (W - w) / 2, y: y, width: w, height: titleH)
            y += titleH + 10
            miniArtist.frame = NSRect(x: (W - w) / 2, y: y, width: w, height: 22)
            y += 22 + 14
            let pw = min(380, W - 88)
            layoutProgress(NSRect(x: (W - pw) / 2, y: y, width: pw, height: 18))
            y += 18 + 14
            layoutControls(NSRect(x: (W - controlsW) / 2, y: y, width: controlsW, height: 36))
        } else {
            let pw = small ? W - 80 : min(560, W - 2 * (W * 0.0625 + 100))
            let bottom = small ? H - 14 : H - (H * 0.0625 - 14)
            let gap: CGFloat = small ? 6 : 10
            var y = bottom - 36
            layoutControls(NSRect(x: (W - controlsW) / 2, y: y, width: controlsW, height: 36))
            if music.station == nil {
                y -= gap + 18
                layoutProgress(NSRect(x: (W - pw) / 2, y: y, width: pw, height: 18))
            }
            y -= gap + 26
            now.frame = NSRect(x: (W - pw) / 2, y: y, width: pw, height: 26)
        }
    }

    private func layoutProgress(_ r: NSRect) {
        let cw: CGFloat = 44
        left.frame = NSRect(x: r.minX, y: r.minY - 1, width: cw, height: 20)
        right.frame = NSRect(x: r.maxX - cw, y: r.minY - 1, width: cw, height: 20)
        bar.frame = NSRect(x: r.minX + cw + 14, y: r.minY, width: max(0, r.width - 2 * (cw + 14)), height: r.height)
    }

    private func layoutControls(_ r: NSRect) {
        prev.frame = NSRect(x: r.minX, y: r.minY, width: 32, height: r.height)
        playButton.frame = NSRect(x: r.minX + 32 + 26, y: r.minY + (r.height - 30) / 2, width: playButton.width, height: 30)
        next.frame = NSRect(x: r.maxX - 32, y: r.minY, width: 32, height: r.height)
        prev.alphaValue = 0.6
        next.alphaValue = 0.6
    }

    // ── popups ──

    private var actionIndex = 0

    private func songActions() {
        let list = tracks
        guard ti < list.count, let main else { return }
        let t = list[ti]
        let at = ti
        let menu = Menu([tx("Play"), tx("Play next"), tx("Add to queue"), tx("Show in Finder")])
        let run = { [weak self] (n: Int) in
            guard let self else { return }
            main.closePopup()
            switch n {
            case 0: self.music.play(ids: list.map(\.id), start: at)
            case 1: self.music.playNext([t.id]); main.showToast("NEXT")
            case 2: self.music.addToQueue([t.id]); main.showToast("QUEUED")
            default: Files.reveal(t.path)
            }
        }
        menu.onPick = run
        main.showPopup(stack([wrapping(t.title, Fonts.words(22)), divider(), menu], spacing: 24, center: true)) { e in
            switch e.keyCode {
            case 53: main.closePopup()
            case 125: menu.chosen = (menu.chosen + 1) % 4
            case 126: menu.chosen = (menu.chosen + 3) % 4
            case 36, 76: run(menu.chosen)
            default: break
            }
            return true
        }
    }

    private func openQueue() {
        guard let main else { return }
        let up = music.upcoming
        var views: [NSView] = [heading(tx("UP NEXT")), divider()]
        if up.isEmpty {
            views.append(wrapping(tx("Nothing after this song."), Fonts.words(15), NSColor(white: 1, alpha: 0.6)))
        } else {
            let rows = up.prefix(40).enumerated().map { i, t -> [NSView] in
                [label("\(i + 1)", Fonts.words(14), NSColor(white: 1, alpha: 0.5)), label(t.title, Fonts.words(15)), label(t.artist, Fonts.words(14), NSColor(white: 1, alpha: 0.6))]
            }
            let g = NSGridView(views: rows)
            g.columnSpacing = 16
            g.rowSpacing = 8
            views.append(g)
        }
        main.showPopup(stack(views, spacing: 24, center: true)) { e in
            if [53, 36, 76].contains(e.keyCode) { main.closePopup() }
            return true
        }
    }

    func openInfo() {
        guard let main else { return }
        let playKeys: [(String, String)] = [
            ("1 / 2 / 3", "Folder / songs / radio"), ("Space", "Play / pause"), ("⏮ / ⏭", "Previous / next song (the Mac's media keys)"),
            ("Enter", "Play (a video: here)"), ("← →", "Genres / stations (radio)"), ("K", "Keep a station"), ("S / R", "Shuffle / repeat"),
            ("Q", "Up next"), ("E / right click", "Actions"), ("⌘F", "The player fills the window"),
        ]
        let n = all.count
        let views: [NSView] = [
            heading("RE:FILE · PLAY"), divider(),
            wrapping(tx(n == 1 ? "{n} song" : "{n} songs", ["n": n]), Fonts.buttons(16)),
            wrapping(music.folder ?? tx("No folder chosen"), Fonts.words(14), NSColor(white: 1, alpha: 0.6)),
            buttons([(tx("FOLDER"), { [weak self] in self?.chooseFolder() }), (tx("RESCAN"), { [weak self] in self?.music.rescan(); main.closePopup(); _ = self })]),
            divider(), main.shortcutGrid(playKeys + FileView.shortcuts), divider(),
            wrapping("MP3 · AAC · ALAC · FLAC · WAV · AIFF\nMP4 · MOV", Fonts.words(13), NSColor(white: 1, alpha: 0.8 * 0.55)),
        ]
        main.showPopup(stack(views, spacing: 24, center: true)) { e in
            if [53, 36, 76].contains(e.keyCode) { main.closePopup() }
            return true
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = music.folder.map { URL(fileURLWithPath: $0) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let url = panel.url else { return }
            self?.music.setFolder(url.path)
            self?.main?.closePopup()
            self?.refresh()
        }
    }

    // ── keys: FileView asks first; true when taken ──

    func key(_ e: NSEvent, typing: Bool) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘F: the player fills the window, or the lists come back
        if e.keyCode == 3 && mods == .command { setMini(!mini); return true }
        if mini {
            if e.keyCode == 49 && mods.isEmpty { music.togglePlay(); return true }
            return false
        }
        if typing {
            // the search: the arrows and Enter go to the songs or the stations
            if tab == "radio", [125, 126, 36, 76].contains(e.keyCode) {
                side = "stations"
                if e.keyCode == 36 || e.keyCode == 76 { playStation() } else { moveRadio(e.keyCode == 125 ? 1 : -1) }
                return true
            }
            if tab == "songs", [125, 126].contains(e.keyCode) { moveSong(e.keyCode == 125 ? 1 : -1); return true }
            if tab == "songs", [36, 76].contains(e.keyCode) { playSongs(from: ti); return true }
            return false
        }
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 18: setTab("folder")
        case 19: setTab("songs")
        case 20: setTab("radio")
        case 49: music.togglePlay()
        case 1:
            music.setShuffle(!music.shuffle)
            main?.showToast(music.shuffle ? "SHUF" : "ORDER")
        case 15:
            let r = music.cycleRepeat()
            main?.showToast(["all": "REPT", "one": "ONE", "off": "ONCE"][r.rawValue] ?? "")
        case 12: openQueue()
        case 34: openInfo()
        default:
            if tab == "radio" {
                switch e.keyCode {
                case 125: moveRadio(1)
                case 126: moveRadio(-1)
                case 124: side = "stations"; refresh()
                case 123: if q.isEmpty { side = "genres"; refresh() }
                case 36, 76: if side == "genres" && q.isEmpty { side = "stations"; refresh() } else { playStation() }
                case 40: toggleFavorite()
                default: return false
                }
                return true
            }
            if tab == "songs" {
                switch e.keyCode {
                case 125: moveSong(1)
                case 126: moveSong(-1)
                case 36, 76: playSongs(from: ti)
                case 14: songActions()
                default: return false
                }
                return true
            }
            return false
        }
        return true
    }

    private func moveRadio(_ d: Int) {
        if side == "genres" && q.isEmpty {
            let n = genreList.count
            guard n > 0 else { return }
            gi = (gi + d + n) % n
            loadGenre()
            genres.reveal(gi)
        } else {
            let n = stationList.count
            guard n > 0 else { return }
            si = (si + d + n) % n
            refresh()
            stations.reveal(si)
        }
    }

    private func moveSong(_ d: Int) {
        let n = tracks.count
        guard n > 0 else { return }
        ti = (ti + d + n) % n
        refresh()
        songs.reveal(ti)
    }
}

/// the line of a song: faint, filled as far as it has played; a click there goes there
final class Bar: Flipped {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var enabled = true
    var seek: ((Double) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY - 1
        Ink.line.withAlphaComponent(0.5 * 0.25).setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: 2).fill()
        Ink.line.setFill()
        NSRect(x: 0, y: y, width: bounds.width * CGFloat(progress), height: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        seek?(Double(min(1, max(0, p.x / max(1, bounds.width)))))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// PLAY / STOP: spaced letters in a frame (on glass a frame means chosen)
final class PlayButton: Flipped {
    var word = "PLAY" { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }

    var width: CGFloat { ceil(attributed("STOP", Fonts.buttons(15), kern: 6).size().width) + 18 - 6 + 2 }

    // the word alone, no frame round it
    override func draw(_ dirtyRect: NSRect) {
        let s = attributed(word, Fonts.buttons(15), NSColor(white: 1, alpha: hover ? 1 : 0.8), kern: 6)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width + 6) / 2, y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}
