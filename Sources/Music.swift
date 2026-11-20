import AVFoundation
import AudioToolbox
import MediaPlayer
import SQLite3

// PLAY (what RePlay was): the music folder's songs kept in SQLite (RePlay's own library, where RePlay kept it:
// Application Support/com.artursavytskyi.resound, so the songs and the kept stations stay), the queue
// (order, shuffle, repeat), the player (AVPlayer: files and the radio's streams), the radio (Radio Browser)
// and the Mac's media keys and Now Playing.

struct Track: Equatable {
    let id: Int64
    let path: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNo: Int?
    let discNo: Int?
    let year: Int?
    let durationMs: Int64
}

struct Station: Equatable {
    let uuid: String
    let name: String
    let url: String
    let country: String
    let codec: String
    let bitrate: Int

    var json: [String: Any] { ["uuid": uuid, "name": name, "url": url, "country": country, "codec": codec, "bitrate": bitrate] }

    static func from(_ d: [String: Any]) -> Station? {
        guard let uuid = d["uuid"] as? String, let url = d["url"] as? String else { return nil }
        return Station(uuid: uuid, name: d["name"] as? String ?? "", url: url, country: d["country"] as? String ?? "",
                       codec: d["codec"] as? String ?? "", bitrate: (d["bitrate"] as? NSNumber)?.intValue ?? 0)
    }
}

enum Repeat: String { case off, all, one }

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ── the library ──

final class Library {
    private var db: OpaquePointer?

    init(_ path: String) {
        sqlite3_open(path, &db)
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS tracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, mtime INTEGER NOT NULL,
                title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, album_artist TEXT NOT NULL,
                track_no INTEGER, disc_no INTEGER, year INTEGER, duration_ms INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS playlists (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS playlist_tracks (playlist_id INTEGER NOT NULL, track_id INTEGER NOT NULL, position INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
    }

    func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    enum V { case i(Int64), t(String), n }

    @discardableResult
    func run(_ sql: String, _ values: [V] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() {
            switch v {
            case .i(let n): sqlite3_bind_int64(stmt, Int32(i + 1), n)
            case .t(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1, TRANSIENT)
            case .n: sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
        while true {
            let r = sqlite3_step(stmt)
            if r == SQLITE_ROW { row?(stmt); continue }
            return r == SQLITE_DONE
        }
    }

    private func text(_ s: OpaquePointer, _ c: Int32) -> String { sqlite3_column_text(s, c).map { String(cString: $0) } ?? "" }
    private func int(_ s: OpaquePointer, _ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, c)) }

    func setting(_ key: String) -> String? {
        var out: String?
        run("SELECT value FROM settings WHERE key = ?", [.t(key)]) { out = self.text($0, 0) }
        return out
    }

    func setSetting(_ key: String, _ value: String) {
        run("INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.t(key), .t(value)])
    }

    private let columns = "id, path, title, artist, album, album_artist, track_no, disc_no, year, duration_ms"

    private func track(_ s: OpaquePointer) -> Track {
        Track(id: sqlite3_column_int64(s, 0), path: text(s, 1), title: text(s, 2), artist: text(s, 3), album: text(s, 4),
              albumArtist: text(s, 5), trackNo: int(s, 6), discNo: int(s, 7), year: int(s, 8), durationMs: sqlite3_column_int64(s, 9))
    }

    /// album order: album artist, album, disc, track number, title
    func tracks() -> [Track] {
        var out: [Track] = []
        run("""
            SELECT \(columns) FROM tracks ORDER BY album_artist COLLATE NOCASE, album COLLATE NOCASE,
            COALESCE(disc_no, 1), COALESCE(track_no, 9999), title COLLATE NOCASE
            """) { out.append(self.track($0)) }
        return out
    }

    func track(_ id: Int64) -> Track? {
        var out: Track?
        run("SELECT \(columns) FROM tracks WHERE id = ?", [.i(id)]) { out = self.track($0) }
        return out
    }

    func id(of path: String) -> Int64? {
        var out: Int64?
        run("SELECT id FROM tracks WHERE path = ?", [.t(path)]) { out = sqlite3_column_int64($0, 0) }
        return out
    }

    func known() -> [String: Int64] {
        var out: [String: Int64] = [:]
        run("SELECT path, mtime FROM tracks") { out[self.text($0, 0)] = sqlite3_column_int64($0, 1) }
        return out
    }

    func upsert(_ path: String, mtime: Int64, _ t: Tags) {
        let opt = { (n: Int?) -> V in n.map { .i(Int64($0)) } ?? .n }
        run("""
            INSERT INTO tracks (path, mtime, title, artist, album, album_artist, track_no, disc_no, year, duration_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(path) DO UPDATE SET mtime = ?2, title = ?3, artist = ?4, album = ?5, album_artist = ?6,
            track_no = ?7, disc_no = ?8, year = ?9, duration_ms = ?10
            """, [.t(path), .i(mtime), .t(t.title), .t(t.artist), .t(t.album), .t(t.albumArtist), opt(t.trackNo), opt(t.discNo), opt(t.year), .i(t.durationMs)])
    }

    func remove(_ paths: [String]) {
        for p in paths { run("DELETE FROM tracks WHERE path = ?", [.t(p)]) }
    }
}

/// what a song's file says of itself: its tags, or, without them, the usual Artist / Album / 01 Song layout
struct Tags {
    var title = "", artist = "", album = "", albumArtist = ""
    var trackNo: Int?, discNo: Int?, year: Int?
    var durationMs: Int64 = 0

    static func read(_ path: String) -> Tags {
        let url = URL(fileURLWithPath: path)
        var t = Tags()
        let stem = url.deletingPathExtension().lastPathComponent
        let album = url.deletingLastPathComponent().lastPathComponent
        let artist = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        (t.trackNo, t.title) = split(stem)
        t.album = album
        t.artist = artist
        t.albumArtist = artist
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return t }
        defer { AudioFileClose(file) }
        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr { t.durationMs = Int64(duration * 1000) }
        var dict: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let info = dict?.takeRetainedValue() as? [String: Any] else { return t }
        let word = { (k: String) -> String? in (info[k] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        if let v = word(kAFInfoDictionary_Title) { t.title = v }
        if let v = word(kAFInfoDictionary_Album) { t.album = v }
        if let v = word(kAFInfoDictionary_Artist) {
            t.artist = v
            t.albumArtist = v
        }
        if let v = word(kAFInfoDictionary_TrackNumber), let n = Int(v.split(separator: "/").first ?? "") { t.trackNo = n }
        if let v = word(kAFInfoDictionary_Year), let n = Int(v.prefix(4)) { t.year = n }
        return t
    }

    /// "03 - Song" / "03. Song" / "03 Song" → (3, "Song")
    static func split(_ stem: String) -> (Int?, String) {
        let digits = stem.prefix { $0.isASCII && $0.isNumber }
        let rest = stem.dropFirst(digits.count).drop { " .-_".contains($0) }.trimmingCharacters(in: .whitespaces)
        if digits.isEmpty || digits.count > 3 || rest.isEmpty || rest.count == stem.count - digits.count { return (nil, stem) }
        return (Int(digits), rest)
    }
}

// ── the queue: what plays and in which order ──

struct Queue {
    private(set) var items: [(id: Int64, path: String)] = []
    private var order: [Int] = []
    private var pos = 0
    var shuffle = false
    var repeatMode = Repeat.off

    var current: (id: Int64, path: String)? { pos < order.count ? items[order[pos]] : nil }
    var isEmpty: Bool { order.isEmpty }

    mutating func set(_ list: [(id: Int64, path: String)], start: Int) {
        let start = min(start, max(0, list.count - 1))
        items = list
        order = Array(0..<list.count)
        if shuffle && !list.isEmpty {
            // the chosen one plays first, the rest in no order
            order.remove(at: start)
            order.shuffle()
            order.insert(start, at: 0)
            pos = 0
        } else {
            pos = start
        }
    }

    /// moved on; `auto`: the song ended by itself (repeat one plays it again)
    mutating func advance(auto: Bool) -> (id: Int64, path: String)? {
        guard !order.isEmpty else { return nil }
        if auto && repeatMode == .one { return current }
        if pos + 1 < order.count {
            pos += 1
        } else if repeatMode != .off {
            pos = 0
            if shuffle { order.shuffle() }
        } else {
            return nil
        }
        return current
    }

    mutating func back() -> (id: Int64, path: String)? {
        pos = max(0, pos - 1)
        return current
    }

    /// what comes next shuffled (what was and what plays stay), or the album's order again
    mutating func setShuffle(_ on: Bool) {
        shuffle = on
        guard !order.isEmpty else { return }
        let now = order[pos]
        if on {
            var next = Array(order[(pos + 1)...])
            next.shuffle()
            order = Array(order[...pos]) + next
        } else {
            order = Array(0..<items.count)
            pos = now
        }
    }

    mutating func cycleRepeat() -> Repeat {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        return repeatMode
    }

    mutating func playNext(_ list: [(id: Int64, path: String)]) {
        let first = items.count
        items += list
        let at = min(pos + 1, order.count)
        order.insert(contentsOf: first..<(first + list.count), at: at)
    }

    mutating func append(_ list: [(id: Int64, path: String)]) {
        let first = items.count
        items += list
        order += Array(first..<(first + list.count))
    }

    var upcoming: [Int64] { pos + 1 < order.count ? order[(pos + 1)...].map { items[$0].id } : [] }
}

// ── the radio: Radio Browser, an open, free list of the world's stations ──

enum Radio {
    static let api = "https://all.api.radio-browser.info/json"
    static let genres: [(name: String, key: String)] = [
        ("Jazz", "tag:jazz"), ("Smooth Jazz", "tag:smooth jazz"), ("Lo-fi", "tag:lofi"), ("Ambient", "tag:ambient"),
        ("Chillout", "tag:chillout"), ("Classical", "tag:classical"), ("Piano", "tag:piano"), ("Soundtrack", "tag:soundtrack"),
        ("Meditation", "tag:meditation"), ("Electronic", "tag:electronic"), ("House", "tag:house"), ("Indie", "tag:indie"),
        ("Rock", "tag:rock"), ("Classic Rock", "tag:classic rock"), ("Pop", "tag:pop"), ("80s", "tag:80s"), ("90s", "tag:90s"),
        ("Oldies", "tag:oldies"), ("Soul", "tag:soul"), ("Blues", "tag:blues"), ("Folk", "tag:folk"), ("Reggae", "tag:reggae"),
        ("Hip Hop", "tag:hip hop"), ("Japan", "country:JP"), ("Ukraine", "country:UA"),
    ]
    private static let order = "order=votes&reverse=true&hidebroken=true&limit=200"

    private static func get(_ path: String, _ done: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: api + path) else { return done(.failure(URLError(.badURL))) }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("RePlay/0.2", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { data, _, error in
            DispatchQueue.main.async {
                if let data { done(.success(data)) } else { done(.failure(error ?? URLError(.badServerResponse))) }
            }
        }.resume()
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? s
    }

    /// what the player plays: a stream in MP3 or AAC (HLS too); nothing under 64 kbps (thin sound)
    private static func stations(_ path: String, _ done: @escaping (Result<[Station], Error>) -> Void) {
        get(path) { r in
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let data):
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                var seen = Set<String>()
                let out = list.compactMap { s -> Station? in
                    let codec = (s["codec"] as? String ?? "").uppercased()
                    let url = s["url_resolved"] as? String ?? ""
                    let bitrate = (s["bitrate"] as? NSNumber)?.intValue ?? 0
                    let name = (s["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard url.hasPrefix("http"), ["MP3", "AAC", "AAC+"].contains(codec), bitrate == 0 || bitrate >= 64,
                          seen.insert(name.lowercased()).inserted else { return nil }
                    return Station(uuid: s["stationuuid"] as? String ?? url, name: name, url: url, country: s["country"] as? String ?? "", codec: codec, bitrate: bitrate)
                }
                done(.success(out))
            }
        }
    }

    static func stations(genre: String, _ done: @escaping (Result<[Station], Error>) -> Void) {
        guard let key = genres.first(where: { $0.name == genre })?.key else { return done(.success([])) }
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        if parts[0] == "country" { stations("/stations/bycountrycodeexact/\(parts[1])?\(order)", done) } else { stations("/stations/bytagexact/\(encode(parts[1]))?\(order)", done) }
    }

    static func search(_ q: String, _ done: @escaping (Result<[Station], Error>) -> Void) {
        stations("/stations/search?name=\(encode(q.trimmingCharacters(in: .whitespaces)))&\(order)", done)
    }

    /// Radio Browser counts what is listened to (its way of ranking stations), as it asks
    static func click(_ uuid: String) { get("/url/\(uuid)") { _ in } }
}

// ── the player ──

final class Music: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    static let shared = Music()
    static let changed = Notification.Name("ReFile.music")
    static let scanned = Notification.Name("ReFile.scanned")

    let library: Library
    private let libraryPath: String
    private let player = AVPlayer()
    private var queue = Queue()
    private(set) var track: Track?
    private(set) var station: Station?
    private var stationList: [Station] = []
    private(set) var onAir: String?
    private(set) var error: String?
    private(set) var scanning: (done: Int, total: Int)?
    private var endObserver: Any?

    /// another folder in its place (--render)
    static var root: URL?

    private override init() {
        let dir = Self.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.artursavytskyi.resound")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        libraryPath = dir.appendingPathComponent("library.sqlite").path
        library = Library(libraryPath)
        super.init()
        // first start: ~/Music
        if library.setting("folder") == nil {
            library.setSetting("folder", FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].path)
        }
        player.automaticallyWaitsToMinimizeStalling = true
        mediaKeys()
    }

    var playing: Bool { player.timeControlStatus != .paused && (track != nil || station != nil) }
    var positionMs: Int64 { station != nil ? 0 : Int64(max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) * 1000) }
    var shuffle: Bool { queue.shuffle }
    var repeatMode: Repeat { queue.repeatMode }
    var folder: String? { library.setting("folder") }

    private func tell() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
        nowPlaying()
    }

    // ── the library ──

    func tracks() -> [Track] { library.tracks() }

    func setFolder(_ path: String) {
        library.setSetting("folder", path)
        rescan()
    }

    private var busy = false

    /// the music folder read again on the side: new songs in, changed ones read again, gone ones out
    func rescan() {
        guard !busy, let folder else { return }
        busy = true
        let path = libraryPath
        DispatchQueue.global(qos: .utility).async {
            let lib = Library(path)
            let audio = Set(Files.audio)
            var files: [String] = []
            if let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in walk where audio.contains(u.pathExtension.lowercased()) { files.append(u.path) }
            }
            var known = lib.known()
            lib.exec("BEGIN")
            for (i, f) in files.enumerated() {
                let m = Int64((try? FileManager.default.attributesOfItem(atPath: f)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                if known.removeValue(forKey: f) != m { lib.upsert(f, mtime: m, Tags.read(f)) }
                if i % 25 == 0 { DispatchQueue.main.async { self.scanning = (i, files.count); NotificationCenter.default.post(name: Self.scanned, object: nil) } }
            }
            lib.remove(Array(known.keys))
            lib.exec("COMMIT")
            DispatchQueue.main.async {
                self.busy = false
                self.scanning = nil
                NotificationCenter.default.post(name: Self.scanned, object: nil)
            }
        }
    }

    /// songs opened from a folder: into the library as they are, their ids in the same order
    private func add(_ paths: [String]) -> [(id: Int64, path: String)] {
        var known = library.known()
        var out: [(Int64, String)] = []
        for p in paths {
            let m = Int64((try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            if known.removeValue(forKey: p) != m { library.upsert(p, mtime: m, Tags.read(p)) }
            if let id = library.id(of: p) { out.append((id, p)) }
        }
        return out
    }

    // ── playing ──

    private func load(_ item: (id: Int64, path: String)?) {
        station = nil
        onAir = nil
        guard let item else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            track = nil
            return tell()
        }
        track = library.track(item.id)
        let playerItem = AVPlayerItem(url: URL(fileURLWithPath: item.path))
        watchEnd(playerItem)
        player.replaceCurrentItem(with: playerItem)
        error = nil
        player.play()
        // a file it can't play says so
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.player.currentItem === playerItem, playerItem.status == .failed else { return }
            self.error = "Can't play “\((item.path as NSString).lastPathComponent)”"
            self.tell()
        }
        tell()
    }

    private func watchEnd(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            // a song ended by itself: the queue moves on (repeat one plays it again)
            let next = self.queue.advance(auto: true)
            if next == nil { self.player.seek(to: .zero); self.player.pause(); self.tell() } else { self.load(next) }
        }
    }

    func play(ids: [Int64], start: Int) {
        let list = ids.compactMap { id in library.track(id).map { (id, $0.path) } }
        queue.set(list, start: start)
        load(queue.current)
    }

    /// FOLDER: the folder's songs, from `start`
    func play(files: [String], start: Int) {
        let list = add(files)
        queue.set(list, start: min(start, max(0, list.count - 1)))
        load(queue.current)
        NotificationCenter.default.post(name: Self.scanned, object: nil)
    }

    func togglePlay() {
        if station != nil {
            // live: a pause lets the stream go; playing again tunes in afresh
            if playing { player.pause(); player.replaceCurrentItem(with: nil) } else if let s = station { tune(s) }
            return tell()
        }
        if playing { player.pause() } else if player.currentItem == nil, !queue.isEmpty { load(queue.current) } else { player.play() }
        tell()
    }

    func next() {
        if station != nil { return turnDial(1) }
        if let n = queue.advance(auto: false) { load(n) }
    }

    /// as Music: more than 3 s in, back to the song's start; else the one before
    func previous() {
        if station != nil { return turnDial(-1) }
        if positionMs > 3000 {
            player.seek(to: .zero)
            return tell()
        }
        load(queue.back())
    }

    func seek(_ ms: Int64) {
        player.seek(to: CMTime(value: max(0, ms), timescale: 1000))
        tell()
    }

    func setShuffle(_ on: Bool) { queue.setShuffle(on); tell() }
    func cycleRepeat() -> Repeat { defer { tell() }; return queue.cycleRepeat() }
    func playNext(_ ids: [Int64]) { queue.playNext(ids.compactMap { id in library.track(id).map { (id, $0.path) } }) }
    func addToQueue(_ ids: [Int64]) { queue.append(ids.compactMap { id in library.track(id).map { (id, $0.path) } }) }
    var upcoming: [Track] { queue.upcoming.compactMap { library.track($0) } }

    /// a video starts: the music pauses
    func pauseForVideo() {
        if playing { togglePlay() }
    }

    // ── the radio ──

    var favorites: [Station] {
        guard let json = library.setting("radio_favorites"), let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap(Station.from)
    }

    func setFavorite(_ s: Station, _ on: Bool) {
        var kept = favorites.filter { $0.uuid != s.uuid }
        if on { kept.insert(s, at: 0) }
        if let data = try? JSONSerialization.data(withJSONObject: kept.map(\.json)) { library.setSetting("radio_favorites", String(decoding: data, as: UTF8.self)) }
    }

    /// `station` on; `list` is where it was picked from, for < and >
    func play(station s: Station, list: [Station]) {
        stationList = list
        tune(s)
    }

    private func tune(_ s: Station) {
        Radio.click(s.uuid)
        station = s
        track = nil
        onAir = nil
        error = nil
        guard let url = URL(string: s.url) else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.error = "The station went quiet."
            self?.tell()
        }
        player.replaceCurrentItem(with: item)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.player.currentItem === item, item.status == .failed else { return }
            self.error = "Can't play the station."
            self.tell()
        }
        tell()
    }

    /// the song on air, as the station names it (its stream's ICY title)
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                if let title = item.stringValue?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                    onAir = title
                    tell()
                    return
                }
            }
        }
    }

    private func turnDial(_ step: Int) {
        guard let on = station, !stationList.isEmpty else { return }
        let at = stationList.firstIndex { $0.uuid == on.uuid } ?? (step > 0 ? -1 : 0)
        let n = stationList.count
        tune(stationList[((at + step) % n + n) % n])
    }

    // ── the Mac's media keys (⏮ ⏯ ⏭, the headphones' buttons), and Now Playing in Control Centre ──

    private func mediaKeys() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.playCommand.addTarget { [weak self] _ in if self?.playing == false { self?.togglePlay() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in if self?.playing == true { self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }

    private func nowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if let t = track {
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist.isEmpty ? t.albumArtist : t.artist,
                                     MPMediaItemPropertyPlaybackDuration: Double(t.durationMs) / 1000,
                                     MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
                                     MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        } else if let s = station {
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: onAir ?? s.name, MPMediaItemPropertyArtist: onAir == nil ? s.country : s.name,
                                     MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        } else {
            center.nowPlayingInfo = nil
        }
        center.playbackState = playing ? .playing : (track != nil || station != nil ? .paused : .stopped)
    }
}

/// "3:07"
func clock(_ ms: Int64) -> String {
    let s = max(0, ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// the emoji in one colour (a station's name, a song on air): asked for as text, not the Mac's colour ones
func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{FE0F}", with: "\u{FE0E}") }
