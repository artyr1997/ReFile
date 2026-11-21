import AppKit

// ReFile: a quiet file browser. The main window is FILE (everything): the folder's items on the left, what the
// chosen one holds on the right (COLM), or one list with sizes and dates (LIST). A file opens in a new window
// of its own, in its mode, TEXT, VIEW (pictures and books) or PLAY (music and videos); a folder all inside
// (⇧Enter, ⇧F / T / V / P) in a new window too, in that mode. Those windows keep to their folder.

/// what a window was opened for: a file (in its mode), or every file inside a folder
struct Opened {
    var path: String?
    var mode: Mode?
    var tree: String?
}

final class FileView: Flipped {
    var opened: Opened?
    private(set) var locked = false
    private var lockRoot = ""

    // ── state ──
    private(set) var mode: Mode = .file
    var playTab = "folder"
    private var layoutKind = "colm"
    private(set) var cwd = ""
    private let home = NSHomeDirectory()
    private var flat: String?
    private var entries: [Entry] = []
    private(set) var selected = 0
    var query = ""
    private var listError = ""
    private var sizes: [String: Int64] = [:]
    private var sort = (key: "name", way: 1)

    // ── views ──
    private var sides: [String: SideButton] = [:]
    private let titleLabel = titleField()
    let column = ListView()
    let table = ListView()
    let preview = Preview()
    let search = Field(size: 18, align: .center)
    /// NOVA in FILE: a new folder here (N)
    private let novaFolder = SideButton("NOVA") {}
    /// VIEW's window: NOVA adds pictures and books here (A), FULL reads the one chosen with its pages filling the window
    private let viewNova = SideButton("NOVA") {}
    private let viewFull = SideButton("FULL") {}
    private let marks = Marks()
    private let strip = DragStrip()
    private var popup: Popup?
    private var popupKeys: ((NSEvent) -> Bool)?
    private var viewer: Viewer?
    private var reader: Reader?
    private var video: VideoView?
    private(set) var play: PlayView?
    var pinned = false { didSet { marks.pinned = pinned } }


    var W: CGFloat { bounds.width }
    var H: CGFloat { bounds.height }
    var small: Bool { W < 760 || H < 560 }
    var tiny: Bool { W < 520 || H < 420 }
    /// a window for a file or for all inside a folder in PLAY, VIEW or TEXT: its mode's own buttons
    var own: Bool { locked && mode != .file }
    var mini: Bool { mode == .play && (tiny || (play?.chosenMini ?? false)) }
    /// the browser shows, but in PLAY's songs and radio, and its mini player
    var browsing: Bool { mode != .play || (playTab == "folder" && !mini) }
    private var layoutShown: String { mode == .view || mode == .text ? "colm" : layoutKind }

    override init(frame: NSRect) {
        super.init(frame: frame)
        if let tab = Saved.word("playTab"), ["folder", "songs", "radio"].contains(tab) { playTab = tab }
        if let s = Saved.json("sort") as? [String: Any], let key = s["key"] as? String, let way = s["way"] as? Int,
           ["name", "kind", "date", "size"].contains(key), way == 1 || way == -1 { sort = (key, way) }

        for (word, as_) in [("COLM", nil), ("LIST", nil), ("INFO", nil), ("DEL", nil), ("SONG", nil), ("LIVE", nil), ("FULL", "PLAYER FULL"),
                            ("READ", nil), ("ADD", nil), ("EDIT", nil), ("NOVA", nil)] as [(String, String?)] {
            let b = SideButton(word, as: as_) {}
            sides[word] = b
            addSubview(b)
        }
        sides["COLM"]!.action = { [weak self] in self?.setLayout("colm") }
        sides["COLM"]!.title = "Columns (C)"
        sides["LIST"]!.action = { [weak self] in self?.setLayout("list") }
        sides["LIST"]!.title = "List (L)"
        sides["INFO"]!.action = { [weak self] in self?.mode == .play ? self?.play?.openInfo() : self?.openInfo() }
        sides["INFO"]!.title = "Info (I)"
        sides["DEL"]!.action = { [weak self] in self?.confirmTrash() }
        sides["DEL"]!.title = "Move to Trash (Backspace)"
        sides["SONG"]!.action = { [weak self] in self?.play?.setTab("folder") }
        sides["SONG"]!.title = "Songs here (1)"
        sides["LIVE"]!.action = { [weak self] in self?.play?.setTab("radio") }
        sides["LIVE"]!.title = "Radio (3)"
        sides["FULL"]!.action = { [weak self] in self?.play?.setMini(!(self?.mini ?? false)) }
        sides["FULL"]!.title = "The player fills the window (⌘F)"
        sides["READ"]!.action = { [weak self] in self?.openEntry() }
        sides["READ"]!.title = "Read, look (Enter)"
        sides["ADD"]!.action = { [weak self] in self?.addFiles() }
        sides["ADD"]!.title = "Add pictures and books here (A)"
        sides["EDIT"]!.action = { [weak self] in self?.openEntry() }
        sides["EDIT"]!.title = "Edit (Enter)"
        sides["NOVA"]!.action = { [weak self] in self?.newText() }
        sides["NOVA"]!.title = "A new text here (N)"
        for w in ["ADD", "EDIT", "NOVA"] { sides[w]!.boxed = true }
        viewNova.action = { [weak self] in self?.addFiles() }
        viewNova.title = "Add pictures and books here (A)"
        viewFull.action = { [weak self] in self?.openFull() }
        viewFull.title = "Read with the pages filling the window"
        addSubview(viewNova)
        addSubview(viewFull)

        addSubview(titleLabel)
        column.onSelect = { [weak self] i in self?.choose(i) }
        column.onOpen = { [weak self] i in self?.choose(i); self?.openEntry() }
        column.onMenu = { [weak self] i in self?.openActions(i) }
        table.onSelect = column.onSelect
        table.onOpen = column.onOpen
        table.onMenu = column.onMenu
        table.columns = [Column(), Column(width: 110, size: 14), Column(width: 220, size: 14)]
        addSubview(column)
        addSubview(table)
        preview.openEntry = { [weak self] e in self?.openFromPreview(e) }
        preview.onPictureSize = { [weak self] size in self?.pictureSize(size) }
        addSubview(preview)
        novaFolder.action = { [weak self] in self?.newFolder() }
        novaFolder.title = "New folder (N)"
        addSubview(novaFolder)
        search.placeholder = "Search"
        search.toolTip = "Search (/)"
        search.onChange = { [weak self] in self?.queried() }
        addSubview(search)
        addSubview(strip)
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── at the start ──

    func start() {
        locked = opened?.path != nil || opened?.tree != nil
        if let m = opened?.mode { mode = m }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            // files may change in other apps while ReFile is in the background
            self?.reload()
        }
        if mode == .play { makePlay() }
        if let tree = opened?.tree {
            lockRoot = tree
            showTree(tree)
        } else if let path = opened?.path {
            lockRoot = Files.parent(path) ?? path
            let its = Files.mode(of: Files.kind(Files.name(path)))
            if let its, opened?.mode == nil { mode = its }
            if mode == .play {
                playTab = "folder"
                makePlay()
            }
            navigate(Files.parent(path) ?? path, select: Files.name(path))
            if let entry = entries.first(where: { $0.path == path }), openHere(entry) {} else {
                // not one ReFile can show after all: the Mac's app then
                Files.open(path)
                if entries.first(where: { $0.path == path }) == nil { window?.close() }
            }
        } else {
            navigate(home)
        }
        apply()
    }

    func end() {
        viewer?.save()
    }

    func leave() { viewer?.save() }

    private func makePlay() {
        guard play == nil else { return }
        let p = PlayView(main: self)
        p.frame = bounds
        p.autoresizingMask = [.width, .height]
        addSubview(p, positioned: .below, relativeTo: search)
        play = p
    }

    // ── the four modes ──

    /// this folder in that mode, the selection kept where it can be (--render only: the main window stays FILE)
    func setMode(_ next: Mode) {
        guard next != mode, !locked else { return }
        let keep = current?.path
        closeViewer()
        mode = next
        query = ""
        search.stringValue = ""
        if next == .play { makePlay() }
        let i = keep.flatMap { k in visible.firstIndex { $0.path == k } } ?? 0
        selected = i
        apply()
    }

    func setPlayTab(_ tab: String) {
        playTab = tab
        Saved.setWord("playTab", tab)
        query = ""
        search.stringValue = ""
        apply()
    }

    private func setLayout(_ l: String) {
        layoutKind = l
        apply()
    }

    // ── what is listed ──

    var visible: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let here = entries.filter { Files.shows($0, in: mode) }
        return sorted(q.isEmpty ? here : here.filter { $0.name.lowercased().contains(q) })
    }

    var current: Entry? {
        let v = visible
        return selected < v.count ? v[selected] : nil
    }

    func sizeOf(_ e: Entry) -> Int64? { e.size ?? sizes[e.path] }

    private func sizeOf(_ info: Info) -> Int64? { info.size ?? sizes[info.path] }

    /// folders stay on top; inside them and the files, the chosen order, then the name
    func sorted(_ list: [Entry]) -> [Entry] {
        let (key, way) = sort
        func by(_ a: Entry, _ b: Entry) -> Int {
            switch key {
            case "kind":
                let x = a.isDir ? "" : Files.ext(a.name), y = b.isDir ? "" : Files.ext(b.name)
                return x == y ? 0 : x.localizedStandardCompare(y) == .orderedAscending ? -1 : 1
            case "date":
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                return x == y ? 0 : x < y ? -1 : 1
            case "size":
                // a folder not measured yet goes to the end either way
                let x = sizeOf(a), y = sizeOf(b)
                if x == nil || y == nil { return x == y ? 0 : (x == nil ? -way : way) }
                return x! == y! ? 0 : x! < y! ? -1 : 1
            default:
                return 0
            }
        }
        return list.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let c = way * by(a, b)
            if c != 0 { return c < 0 }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// ⌃⌘1 name, ⌃⌘2 kind, ⌃⌘3 date, ⌃⌘4 size; the same again turns the order round
    private func sortBy(_ key: String) {
        let keep = current?.path
        let first = ["name": 1, "kind": 1, "date": -1, "size": -1]
        sort = (key, sort.key == key ? -sort.way : first[key]!)
        Saved.setJSON("sort", ["key": sort.key, "way": sort.way])
        keepSelection(keep)
        apply()
    }

    private func keepSelection(_ path: String?) {
        if let path, let i = visible.firstIndex(where: { $0.path == path }) { selected = i }
    }

    // ── going places ──

    func navigate(_ path: String, select name: String? = nil) {
        do {
            let list = try Files.list(path)
            flat = nil
            cwd = path
            entries = list
            listError = ""
            query = ""
            search.stringValue = ""
            selected = name.flatMap { n in visible.firstIndex { $0.name == n } } ?? 0
            measure()
        } catch {
            listError = "No access to “\(Files.name(path))”."
        }
        apply()
        reveal()
    }

    /// every file inside `root`, at any depth, as one list
    private func showTree(_ root: String) {
        flat = root
        cwd = root
        entries = []
        listError = "⋯"
        apply()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Files.tree(root) }
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self.entries = list
                    self.listError = ""
                case .failure(let e):
                    self.listError = e.localizedDescription
                }
                self.selected = 0
                self.apply()
            }
        }
    }

    /// the folder again, the selection on the same item when it is still there
    func reload(select name: String? = nil) {
        guard !cwd.isEmpty else { return }
        let keep = name ?? current?.name
        if let flat {
            entries = (try? Files.tree(flat)) ?? entries
        } else {
            for e in entries { sizes[e.path] = nil }
            do {
                entries = try Files.list(cwd)
                listError = ""
            } catch {
                listError = "No access to “\(Files.name(cwd))”."
            }
        }
        let v = visible
        selected = keep.flatMap { k in v.firstIndex { $0.name == k } } ?? min(selected, max(0, v.count - 1))
        measure()
        apply()
    }

    private var canGoBack: Bool {
        if locked { return flat == nil && cwd != lockRoot && cwd.hasPrefix(lockRoot.hasSuffix("/") ? lockRoot : lockRoot + "/") }
        return flat != nil || (!cwd.isEmpty && cwd != home && Files.parent(cwd) != nil)
    }

    private func back() {
        guard canGoBack else { return }
        if let flat { return navigate(flat) }
        if let parent = Files.parent(cwd) { navigate(parent, select: Files.name(cwd)) }
    }

    /// Folders open in place. A file goes to a new window of its own, in its mode; in a window opened for a
    /// file, the folder's others open there. What isn't ReFile's opens in the Mac's app.
    func openEntry(_ entry: Entry? = nil) {
        guard let entry = entry ?? current else { return }
        if entry.isDir { return navigate(entry.path) }
        guard let its = Files.mode(of: Files.kind(entry.name)) else { return Files.open(entry.path) }
        if opened?.path == nil && flat == nil {
            (NSApp.delegate as? AppDelegate)?.newWindow(from: window, opened: Opened(path: entry.path, mode: its))
            return
        }
        _ = openHere(entry)
    }

    /// a file opened in its mode in this window: shown, read, played; false when it can't be
    @discardableResult
    func openHere(_ entry: Entry) -> Bool {
        let kind = Files.kind(entry.name)
        switch kind {
        case .image, .text: return show(entry)
        case .book:
            closeViewer()
            let r = Reader(path: entry.path) { [weak self] in self?.closeReader() }
            r.onNext = { [weak self] in self?.openNextBook() }
            r.frame = bounds
            r.autoresizingMask = [.width, .height]
            addSubview(r, positioned: .below, relativeTo: strip)
            reader = r
            apply()
            return true
        case .video, .audio:
            let same = visible.filter { !$0.isDir && Files.kind($0.name) == kind }
            let start = max(0, same.firstIndex(of: entry) ?? 0)
            if kind == .video {
                Music.shared.pauseForVideo()
                let v = VideoView(paths: same.map(\.path), start: start) { [weak self] in self?.closeVideo() }
                v.frame = bounds
                v.autoresizingMask = [.width, .height]
                addSubview(v, positioned: .below, relativeTo: strip)
                video = v
            } else {
                makePlay()
                Music.shared.play(files: same.map(\.path), start: start)
            }
            apply()
            return true
        case .other:
            return false
        }
    }

    /// NEXT in the reader: the folder's next book (round to the first after the last), read here instead
    private func openNextBook() {
        let books = visible.filter { !$0.isDir && Files.kind($0.name) == .book }
        guard let path = reader?.path, let i = books.firstIndex(where: { $0.path == path }) else { return }
        let next = books[(i + 1) % books.count]
        guard next.path != path else { return }
        reader?.removeFromSuperview()
        reader = nil
        if let k = visible.firstIndex(where: { $0.path == next.path }) { selected = k }
        openHere(next)
    }

    private func closeReader() {
        reader?.removeFromSuperview()
        reader = nil
        apply()
    }

    private func closeVideo() {
        video?.removeFromSuperview()
        video = nil
        apply()
    }

    // ── the viewer: a picture or a text over the list ──

    /// the pictures (VIEW), the texts (TEXT), both (FILE's quick look)
    private var viewable: [Entry] { visible.filter { !$0.isDir && [.image, .text].contains(Files.kind($0.name)) } }

    @discardableResult
    func show(_ entry: Entry) -> Bool {
        let kind = Files.kind(entry.name)
        let v: Viewer
        if kind == .image {
            guard let img = NSImage(contentsOfFile: entry.path) else { return false }
            v = Viewer(entry: entry, image: img)
        } else {
            guard let t = Files.readText(entry.path) else { return false }
            v = Viewer(entry: entry, text: t.text, truncated: t.truncated)
        }
        closeViewer()
        v.onClose = { [weak self] in self?.closeViewer() }
        v.onStep = { [weak self] d in self?.stepViewer(d) }
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v, positioned: .below, relativeTo: strip)
        viewer = v
        updateViewerFoot()
        apply()
        v.focus()
        return true
    }

    private func updateViewerFoot() {
        guard let v = viewer else { return }
        let list = viewable
        let at = list.firstIndex { $0.path == v.entry.path }
        v.position = list.count > 1 && at != nil ? "\(at! + 1) / \(list.count)" : nil
    }

    func closeViewer() {
        guard let v = viewer else { return }
        v.save()
        let edited = v.edited
        v.removeFromSuperview()
        viewer = nil
        if edited { reload() }
        apply()
    }

    /// ← / → in the viewer: the previous / next picture or text, the selection following
    private func stepViewer(_ delta: Int) {
        guard let v = viewer else { return }
        let list = viewable
        guard list.count > 1, let at = list.firstIndex(where: { $0.path == v.entry.path }) else { return }
        let next = list[(at + delta + list.count) % list.count]
        if show(next), let i = visible.firstIndex(of: next) {
            selected = i
            apply()
        }
    }

    /// COLM: an item in the right column clicked: its folder stepped into, it chosen
    private func openFromPreview(_ entry: Entry) {
        guard let c = current, c.isDir else { return }
        navigate(c.path, select: entry.name)
    }

    func choose(_ i: Int) {
        selected = i
        apply()
    }

    private func move(_ delta: Int) {
        let n = visible.count
        guard n > 0 else { return }
        selected = (selected + delta + n) % n
        apply()
        reveal()
    }

    private func reveal() {
        (layoutShown == "colm" ? column : table).reveal(selected)
    }

    private func queried() {
        query = search.stringValue
        if mode == .play && !browsing {
            play?.queryChanged()
            return
        }
        selected = 0
        apply()
    }

    // ── folders' sizes: measured on the side, two at a time, gently ──

    private var waiting: [String] = []
    private var measuring = 0
    private static let sizer = DispatchQueue(label: "refile.sizes", qos: .utility, attributes: .concurrent)

    private func measure(first: String? = nil) {
        waiting = entries.filter { $0.size == nil && sizes[$0.path] == nil }.map(\.path)
        if let first, sizes[first] == nil { waiting.removeAll { $0 == first }; waiting.insert(first, at: 0) }
        measureNext()
    }

    private func measureNext() {
        while measuring < 2, !waiting.isEmpty {
            let path = waiting.removeFirst()
            measuring += 1
            Self.sizer.async {
                let bytes = Files.treeSize(path)
                DispatchQueue.main.async {
                    self.measuring -= 1
                    let keep = self.current?.path
                    self.sizes[path] = bytes
                    if self.sort.key == "size" { self.keepSelection(keep) }
                    self.refreshSizes()
                    self.measureNext()
                }
            }
        }
    }

    private func refreshSizes() {
        if layoutShown == "list" { fillLists() }
        if let c = current, !c.isDir || c.size == nil, case .file = preview.content { fillPreview() }
        if case .look = preview.content { fillPreview() }
    }

    // ── drawn ──

    private var lastPreviewPath: String?
    private var pictureDims: NSSize?

    /// everything as the state is now
    func apply() {
        let v = visible
        if selected >= v.count { selected = max(0, v.count - 1) }
        configureSides()
        titleLabel.stringValue = cwd.isEmpty ? "" : (flat != nil ? "\(Files.name(cwd)) · all inside" : Files.name(cwd))
        titleLabel.toolTip = cwd
        fillLists()
        if current?.path != lastPreviewPath || preview.isHidden {
            lastPreviewPath = current?.path
            pictureDims = nil
            fillPreview()
        }
        search.placeholder = mode != .play ? "Search" : playTab == "folder" ? titleLabel.stringValue : playTab == "songs" ? "Search songs" : "Search stations"
        play?.refresh()
        needsLayout = true
    }

    private func fillLists() {
        let v = visible
        let empty = listError.isEmpty ? (query.isEmpty ? "Empty folder." : "Nothing found.") : listError
        if layoutShown == "colm" {
            column.lines = v.map { Line(cells: [$0.name]) }
            column.selected = selected
            column.empty = empty
        } else {
            table.lines = v.map { Line(cells: [$0.name, Files.size(sizeOf($0)), Files.date($0.modified)]) }
            table.selected = selected
            table.empty = empty
        }
    }

    private func pictureSize(_ s: NSSize) {
        pictureDims = s
        fillPreview(keepImage: true)
    }

    private func fillPreview(keepImage: Bool = false) {
        guard layoutShown == "colm", let entry = current else { return preview.show(.none) }
        if entry.isDir {
            guard let list = try? Files.list(entry.path) else { return preview.show(.message("No access.")) }
            let here = sorted(list).filter { Files.shows($0, in: mode) }
            if mode == .view {
                let thumbs = here.filter { !$0.isDir && Files.shows($0, in: .view) }.prefix(60)
                if !thumbs.isEmpty { return preview.show(.thumbs(Array(thumbs), texts: false)) }
            } else if mode == .text {
                let thumbs = here.filter { !$0.isDir && Files.shows($0, in: .text) }.prefix(40)
                if !thumbs.isEmpty { return preview.show(.thumbs(Array(thumbs), texts: true)) }
            }
            return preview.show(.rows(here))
        }
        guard let info = Files.info(entry.path) else { return preview.show(.message("No access.")) }
        let kind = Files.kind(info.name)
        let ext = Files.ext(info.name).uppercased()
        switch mode {
        case .view:
            let names = ["pdf": "PDF", "epub": "EPUB", "cbz": "Comic", "cbr": "Comic"]
            let meta = kind == .book
                ? "\(names[Files.ext(info.name)] ?? ext) · \(Places.note(info.path)) · \(Files.size(sizeOf(info)))"
                : "\(ext)\(pictureDims.map { " · \(Int($0.width)) × \(Int($0.height))" } ?? "") · \(Files.size(sizeOf(info)))"
            if keepImage, case .look = preview.content { preview.updateMeta(meta) } else { preview.show(.look(info, meta: meta)) }
        case .text:
            let head = Files.head(info.path, max: 6000)
            let lines = head.map { " · \($0.lines) \($0.lines == 1 ? "line" : "lines")" } ?? ""
            preview.show(.page(info, text: head?.text, meta: "\(ext.isEmpty ? "TEXT" : ext)\(lines) · \(Files.size(sizeOf(info)))"))
        default:
            let text = kind == .text ? Files.head(info.path, max: 6000)?.text : nil
            preview.show(.file(info, size: Files.size(sizeOf(info)), text: text))
        }
        if info.size == nil && sizes[info.path] == nil { measure(first: info.path) }
    }

    private func configureSides() {
        for b in sides.values { b.isHidden = true }
        novaFolder.isHidden = true
        viewNova.isHidden = true
        viewFull.isHidden = true
        let showing = viewer == nil && reader == nil && video == nil
        // a small window: no side buttons (in PLAY's FULL neither)
        guard showing, !small else { return }
        if mode == .play && mini {
            // the player filling the window: FULL, unframed, to bring the lists back
            sides["FULL"]!.isHidden = false
            sides["FULL"]!.chosen = false
            return
        }
        let hasFile = current.map { !$0.isDir } ?? false
        if own && mode == .play {
            sides["SONG"]!.isHidden = false
            sides["SONG"]!.chosen = playTab != "radio"
            sides["LIVE"]!.isHidden = false
            sides["LIVE"]!.chosen = playTab == "radio"
            sides["INFO"]!.isHidden = false
            sides["FULL"]!.isHidden = false
            sides["FULL"]!.chosen = false
        } else if own && mode == .view {
            sides["READ"]!.isHidden = false
            sides["READ"]!.enabled = hasFile
            viewNova.isHidden = false
            sides["INFO"]!.isHidden = false
            viewFull.isHidden = false
            viewFull.enabled = hasFile
        } else if own && mode == .text {
            sides["EDIT"]!.isHidden = false
            sides["EDIT"]!.enabled = hasFile
            sides["NOVA"]!.isHidden = false
            sides["INFO"]!.isHidden = false
            sides["DEL"]!.isHidden = false
            sides["DEL"]!.enabled = current != nil
        } else {
            sides["COLM"]!.isHidden = false
            sides["COLM"]!.chosen = layoutShown == "colm"
            sides["LIST"]!.isHidden = false
            sides["LIST"]!.chosen = layoutShown != "colm"
            sides["INFO"]!.isHidden = false
            novaFolder.isHidden = false
        }
    }

    private func place(_ b: SideButton, _ at: String) {
        let left = at.hasSuffix("Left")
        let x = left ? W * 0.0625 - 28 : W - (W * 0.0625 - 28) - SideButton.width
        // the room over the first letter for all (a bottom one's letters stay where they are: it stands on its
        // bottom), so a chosen one's frame has as much over its letters as under them
        b.top = !b.boxed
        let h = b.intrinsicContentSize.height
        let y: CGFloat
        switch at {
        case "topLeft", "topRight": y = H * 0.0625 + 8
        case "midLeft", "midRight": y = (H - h) / 2
        default: y = H - H * 0.0625 - h
        }
        b.frame = NSRect(x: x, y: y, width: SideButton.width, height: h)
    }

    override func layout() {
        super.layout()
        // the window resized (tiled by ReDesk, say): the side buttons as its size wants them
        configureSides()
        let places: [(String, String)] = [("COLM", "topLeft"), ("LIST", "bottomRight"), ("INFO", "bottomLeft"), ("DEL", "bottomRight"),
                                          ("SONG", "topLeft"), ("LIVE", "topRight"), ("FULL", "bottomRight"),
                                          ("READ", "topLeft"), ("ADD", "midRight"), ("EDIT", "midLeft"), ("NOVA", "midRight")]
        for (w, at) in places { place(sides[w]!, at) }
        place(novaFolder, "topRight")
        place(viewNova, "topRight")
        place(viewFull, "bottomRight")
        strip.frame = NSRect(x: 0, y: 0, width: W, height: 28)
        marks.frame = NSRect(x: 14, y: 14, width: 13, height: 40)

        let titleW = small ? W - 200 : W * 0.5
        titleLabel.frame = NSRect(x: (W - titleW) / 2, y: small ? 12 : 28, width: titleW, height: 32)
        titleLabel.isHidden = mode == .play

        // the lists: between the title and the search (in PLAY, between the search and the player)
        var top: CGFloat = small ? 52 : H * 0.0625 + 40
        var bottom: CGFloat = small ? 52 : H * 0.0625 + 44
        if mode == .play {
            top = small ? 52 : H * 0.0625 + 40
            bottom = small ? 128 : H * 0.0625 + 112
        }
        let listH = max(0, H - top - bottom)
        let colm = layoutShown == "colm"
        // the viewer, a book or a video over it: what they cover out of sight (the glass is see-through)
        let covered = viewer != nil || reader != nil || video != nil
        column.isHidden = !browsing || !colm || covered
        preview.isHidden = !browsing || !colm || covered
        table.isHidden = !browsing || colm || covered
        play?.isHidden = covered || mode != .play
        titleLabel.isHidden = mode == .play || covered
        if small {
            column.frame = NSRect(x: 40 - 9.6, y: top, width: W / 2 - 50 + 19.2, height: listH)
            preview.frame = NSRect(x: W / 2 + 10 - 9.6, y: top, width: W / 2 - 50 + 19.2, height: listH)
            let tw = W - 80
            table.frame = NSRect(x: (W - tw) / 2, y: top, width: tw, height: listH)
            table.columns = W < 560 ? [Column(), Column(width: 80, size: 14, align: .center)]
                : [Column(), Column(width: 80, size: 14, align: .center), Column(width: 150, size: 14)]
            table.columnGap = 16
        } else {
            column.frame = NSRect(x: W * 0.213 - 9.6, y: top, width: W * 0.26 + 19.2, height: listH)
            preview.frame = NSRect(x: W * 0.5 - 9.6, y: top, width: W * 0.5 - W * 0.0625 - 60 + 19.2, height: listH)
            let tw = min(680, W - 2 * (W * 0.0625 + 60))
            table.frame = NSRect(x: (W - tw) / 2 - 9.6, y: top, width: tw + 19.2, height: listH)
            table.columns = [Column(), Column(width: 110, size: 14), Column(width: 220, size: 14)]
            table.columnGap = 24
        }
        preview.windowHeight = H

        // the search: at the bottom, as far from it as the title from the top; in PLAY, at the top (the title)
        let searchW = small ? W - 200 : 360
        search.isHidden = mini || viewer != nil || reader != nil || video != nil
        search.frame = mode == .play
            ? NSRect(x: (W - searchW) / 2, y: small ? 12 : 28, width: searchW, height: 32)
            : NSRect(x: (W - searchW) / 2, y: H - (small ? 8 : 28) - 32, width: searchW, height: 32)

        popup?.frame = bounds
    }

    // ── popups ──

    func showPopup(_ content: NSView, keys: ((NSEvent) -> Bool)? = nil) {
        closePopup()
        let p = Popup(content: content, modal: true)
        p.onClose = { [weak self] in self?.closePopup() }
        p.frame = bounds
        addSubview(p, positioned: .below, relativeTo: strip)
        popup = p
        popupKeys = keys
    }

    func closePopup() {
        popup?.removeFromSuperview()
        popup = nil
        popupKeys = nil
        window?.makeFirstResponder(nil)
    }

    var popupShown: Bool { popup != nil }

    /// a popup with a name to type (NEW FOLDER, NEW TEXT, RENAME): Enter does it, Esc goes
    private func askName(_ title: String, _ value: String, chooseUpTo: Int, button: String, _ done: @escaping (String) throws -> Void) {
        let field = NameField(value)
        let problem = wrapping("", Fonts.words(15), Ink.error)
        problem.isHidden = true
        let run = { [weak self] in
            do {
                try done(field.stringValue)
                self?.closePopup()
            } catch {
                problem.stringValue = error.localizedDescription
                problem.isHidden = false
            }
        }
        let content = stack([heading(tx(title)), divider(), field, problem, buttons([(tx(button), run), (tx("CANCEL"), { [weak self] in self?.closePopup() })])],
                            spacing: 24, center: true)
        showPopup(content) { [weak self] e in
            if e.keyCode == 53 { self?.closePopup(); return true }
            if e.keyCode == 36 || e.keyCode == 76 { run(); return true }
            return false
        }
        DispatchQueue.main.async { field.choose(upTo: chooseUpTo) }
    }

    private func newFolder() {
        askName("NEW FOLDER", "New folder", chooseUpTo: 10, button: "CREATE") { [weak self] name in
            guard let self else { return }
            let path = try Files.createFolder(in: self.cwd, name)
            self.query = ""
            self.search.stringValue = ""
            self.reload(select: Files.name(path))
            self.reveal()
        }
    }

    /// TEXT's NEW: a new text in this folder, opened to be written
    private func newText() {
        askName("NEW TEXT", "Untitled.md", chooseUpTo: 8, button: "CREATE") { [weak self] name in
            guard let self else { return }
            let path = try Files.createFile(in: self.cwd, name)
            self.query = ""
            self.search.stringValue = ""
            self.reload(select: Files.name(path))
            if let e = self.entries.first(where: { $0.path == path }) { DispatchQueue.main.async { self.show(e) } }
        }
    }

    /// VIEW's ADD (A): pictures and books copied into this folder
    /// FULL (VIEW): the one chosen opened, a book with its pages filling the window
    private func openFull() {
        guard let entry = current, !entry.isDir else { return }
        openEntry(entry)
        reader?.fillWindow()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = (Files.images + Files.books).compactMap { .init(filenameExtension: $0) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let self else { return }
            do {
                let copied = try Files.copy(panel.urls.map(\.path), into: self.cwd)
                self.reload(select: copied.first.map(Files.name))
                self.reveal()
            } catch {
            }
        }
    }

    private func confirmTrash() {
        guard let c = current else { return }
        let problem = wrapping("", Fonts.words(15), Ink.error)
        problem.isHidden = true
        let run = { [weak self] in
            do {
                try Files.trash(c.path)
                self?.closePopup()
                self?.reload(select: "")
            } catch {
                problem.stringValue = error.localizedDescription
                problem.isHidden = false
            }
        }
        let content = stack([wrapping(tx("Move “{name}” to Trash?", ["name": c.name]), Fonts.buttons(16)), problem,
                             buttons([(tx("YES"), run), (tx("NO"), { [weak self] in self?.closePopup() })])], spacing: 24, center: true)
        showPopup(content) { [weak self] e in
            if e.keyCode == 53 { self?.closePopup(); return true }
            if e.keyCode == 36 || e.keyCode == 76 { run(); return true }
            return false
        }
    }

    static let shortcuts: [(String, String)] = [
        ("⇧ Enter, ⇧ F / T / V / P", "The folder selected, all inside it (at any depth), in a new window"),
        ("⌘ N", "New window"),
        ("↑ / ↓", "Select"),
        ("→ / Enter", "Open (a file: in a new window, in its mode)"),
        ("Space", "A quick look at a picture or text, here"),
        ("⌘ S", "Save the text (it saves itself too)"),
        ("←", "Back"),
        ("/", "Search"),
        ("C / L", "Columns / List"),
        ("⌃⌘ 1 / 2 / 3 / 4", "Sort by name / kind / date / size (again: the other way)"),
        ("N", "New folder"),
        ("I", "Info"),
        ("E / right click", "Actions"),
        ("Backspace", "Move to Trash"),
    ]

    func shortcutGrid(_ list: [(String, String)]) -> NSGridView {
        let rows = list.map { k, d -> [NSView] in
            [label(tx(k), Fonts.buttons(13), NSColor(white: 1, alpha: 0.8 * 0.85), kern: 1.3, align: .right),
             wrapping(tx(d), Fonts.words(13), NSColor(white: 1, alpha: 0.8 * 0.7), align: .left, width: 360)]
        }
        let g = NSGridView(views: rows)
        g.columnSpacing = 24
        g.rowSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        for i in 0..<g.numberOfRows { g.row(at: i).rowAlignment = .firstBaseline }
        return g
    }

    private func openInfo() {
        let info = Files.info(current?.path ?? cwd)
        var views: [NSView] = [heading("RE:FILE"), divider()]
        if let info {
            views.append(wrapping(info.name, Fonts.words(24)))
            var rows = [("Kind", info.kind)]
            if info.isDir { rows.append(("Items", info.items.map(String.init) ?? "--")) }
            rows += [("Size", Files.size(sizeOf(info))), ("Created", Files.date(info.created)), ("Modified", Files.date(info.modified)),
                     ("Where", Files.parent(info.path) ?? "/")]
            let grid = NSGridView()
            preview.fill(grid, rows)
            grid.columnSpacing = 20
            grid.rowSpacing = 14
            views += [grid, divider()]
            if info.size == nil && sizes[info.path] == nil { measure(first: info.path) }
        }
        views += [shortcutGrid(Self.shortcuts), divider(), label(tx("local · private · offline"), Fonts.words(13), NSColor(white: 1, alpha: 0.8 * 0.55), kern: 1.95)]
        showPopup(stack(views, spacing: 24, center: true)) { [weak self] e in
            if e.keyCode == 53 || e.keyCode == 36 || e.keyCode == 76 { self?.closePopup(); return true }
            return false
        }
    }

    // ── the actions (E, a right click) ──

    private var actionIndex = 0

    private func openActions(_ i: Int? = nil) {
        if let i { selected = i; apply() }
        guard let entry = current else { return }
        actionIndex = 0
        var names = ["Open", "Rename", "Duplicate", "Compress", "Copy path", "Show in Finder", "Info", "Move to Trash"]
        // a picture or a video ReDesk can show: one of its wallpapers too
        if !entry.isDir && Files.wallpaperKinds.contains((entry.name as NSString).pathExtension.lowercased()) {
            names.insert("Add to wallpapers", at: 6)
        }
        let problem = wrapping("", Fonts.words(15), Ink.error)
        problem.isHidden = true
        let menu = Menu(names.map { tx($0) })
        let run = { [weak self] (n: Int) in
            guard let self else { return }
            do {
                switch names[n] {
                case "Open": self.closePopup(); self.openEntry(entry)
                case "Rename":
                    let dot = entry.isDir ? -1 : (entry.name as NSString).deletingPathExtension.count
                    self.askName("RENAME", entry.name, chooseUpTo: dot > 0 ? dot : entry.name.count, button: "RENAME") { name in
                        let path = try Files.rename(entry.path, to: name)
                        self.query = ""
                        self.search.stringValue = ""
                        self.reload(select: Files.name(path))
                        self.reveal()
                    }
                case "Duplicate":
                    let copy = try Files.duplicate(entry.path)
                    self.closePopup()
                    self.reload(select: Files.name(copy))
                    self.reveal()
                case "Compress":
                    let zip = try Files.compress(entry.path)
                    self.closePopup()
                    self.reload(select: Files.name(zip))
                    self.reveal()
                case "Copy path":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                    self.closePopup()
                case "Show in Finder": self.closePopup(); Files.reveal(entry.path)
                case "Info": self.openInfo()
                case "Add to wallpapers":
                    try Files.addWallpaper(entry.path)
                    self.closePopup()
                default: self.confirmTrash()
                }
            } catch {
                problem.stringValue = error.localizedDescription
                problem.isHidden = false
            }
        }
        menu.onPick = run
        showPopup(stack([wrapping(entry.name, Fonts.words(22)), divider(), menu, problem], spacing: 24, center: true)) { [weak self] e in
            guard let self else { return false }
            switch e.keyCode {
            case 53: self.closePopup()
            case 125: menu.chosen = (menu.chosen + 1) % names.count
            case 126: menu.chosen = (menu.chosen - 1 + names.count) % names.count
            case 36, 76: run(menu.chosen)
            default: return true
            }
            return true
        }
    }

    // ── keys ──

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command && e.keyCode == 45 { // ⌘N: another window
            (NSApp.delegate as? AppDelegate)?.newWindow(from: window, opened: nil)
            return true
        }
        if mods == .command && e.keyCode == 13 { // ⌘W: this one closes
            window?.close()
            return true
        }
        // popups are modal: Enter confirms, Esc closes, nothing else reacts (typing in their field does)
        if popup != nil {
            if let keys = popupKeys, keys(e) { return true }
            return !(window?.firstResponder is NSTextView)
        }
        if let reader { return reader.key(e) }
        if let video { return video.key(e) }
        if let viewer { return viewer.key(e) }

        // PLAY's own keys first: the player, the tabs, the songs and the radio
        if mode == .play, let play, play.key(e, typing: search.editing) { return true }
        let typing = window?.firstResponder is NSTextView
        if !browsing {
            if e.keyCode == 44 && !typing { search.focus(); return true }
            if search.editing && e.keyCode == 53 { search.stringValue = ""; queried(); window?.makeFirstResponder(nil); return true }
            if !typing && mods.subtracting(.shift).isEmpty { return modeKey(e) }
            return false
        }

        // in the search: the arrows move through what it found, Enter opens, Esc clears
        if search.editing {
            switch e.keyCode {
            case 125: move(1); return true
            case 126: move(-1); return true
            case 36, 76: openEntry(); return true
            case 53:
                search.stringValue = ""
                queried()
                window?.makeFirstResponder(nil)
                return true
            default: return false
            }
        }
        if typing { return false }

        switch (e.keyCode, mods) {
        case (125, []): move(1)
        case (126, []): move(-1)
        case (124, []): if current?.isDir == true { openEntry() }
        case (18, [.control, .command]): sortBy("name")
        case (19, [.control, .command]): sortBy("kind")
        case (20, [.control, .command]): sortBy("date")
        case (21, [.control, .command]): sortBy("size")
        case (36, .shift), (76, .shift): openTree(mode)
        case (36, []), (76, []), (31, .command): openEntry()
        case (49, []):
            // a quick look: only what the viewer shows
            if let c = current, !c.isDir, viewable.contains(c) { show(c) }
        case (123, []), (126, .command): back()
        case (53, []): search.stringValue = ""; queried()
        case (51, []), (117, []): confirmTrash()
        case (44, []): search.focus()
        case (45, []): if own && mode == .text { newText() } else { newFolder() }
        case (0, []) where own && mode == .view: addFiles()
        case (34, []): if mode == .play { play?.openInfo() } else { openInfo() }
        case (14, []): openActions()
        case (8, []): setLayout("colm")
        case (37, []): setLayout("list")
        default:
            if mods.subtracting(.shift).isEmpty { return modeKey(e) }
            return false
        }
        return true
    }

    /// ⇧F / T / V / P: the folder, all inside it, in a new window in that mode (the main window doesn't change mode)
    private func modeKey(_ e: NSEvent) -> Bool {
        let modes: [UInt16: Mode] = [3: .file, 17: .text, 9: .view, 35: .play]
        guard let next = modes[e.keyCode], e.modifierFlags.contains(.shift) else { return false }
        openTree(next)
        return true
    }

    /// ⇧Enter, ⇧F / T / V / P: the folder chosen (or this one), all inside it, in a new window
    private func openTree(_ m: Mode) {
        let root = current?.isDir == true ? current!.path : cwd
        guard !root.isEmpty else { return }
        (NSApp.delegate as? AppDelegate)?.newWindow(from: window, opened: Opened(path: nil, mode: m, tree: root))
    }

    func focusChanged(_ focused: Bool) {
        marks.focused = focused
    }
}

/// the folder's name at the top
func titleField() -> NSTextField {
    let f = label("", Fonts.words(18), align: .center)
    f.lineBreakMode = .byTruncatingTail
    return f
}

/// a popup's list of words to choose (the actions): the one chosen underlined
final class Menu: Flipped {
    let items: [String]
    var chosen = 0 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private let rowH: CGFloat = 19.2, gap: CGFloat = 16

    init(_ items: [String]) {
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let w = items.map { attributed($0, Fonts.words(16)).size().width }.max() ?? 100
        widthAnchor.constraint(equalToConstant: ceil(w) + 20).isActive = true
        heightAnchor.constraint(equalToConstant: CGFloat(items.count) * (rowH + gap) - gap + 10).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            var a: [NSAttributedString.Key: Any] = [.font: Fonts.words(16), .foregroundColor: Ink.text]
            if i == chosen {
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                a[.underlineColor] = Ink.text
            }
            NSAttributedString(string: item, attributes: a).draw(at: NSPoint(x: 6, y: 5 + CGFloat(i) * (rowH + gap)))
        }
    }

    private func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        let i = Int((p.y - 5 + gap / 2) / (rowH + gap))
        return i >= 0 && i < items.count ? i : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if let i = index(event) { chosen = i } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if let i = index(event) { onPick?(i) } }
}

