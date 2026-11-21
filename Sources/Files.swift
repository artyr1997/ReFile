import AppKit

// The filesystem side of ReFile: reading folders, an item's details, new folders and texts, copies,
// renames, zips, the Trash; what each file is and the mode it opens in; how busy the Mac is.

struct Entry: Equatable {
    let name: String
    let path: String
    /// a folder to step into (an app counts as a file, as in Finder)
    let isDir: Bool
    /// bytes; nil for folders (and apps): measured on the side
    let size: Int64?
    let modified: Date?
}

struct Info {
    let name: String
    let path: String
    let kind: String
    let isDir: Bool
    let size: Int64?
    /// the visible items inside a folder
    let items: Int?
    let created: Date?
    let modified: Date?
}

enum Kind { case image, book, text, audio, video, other }

enum Mode: String, CaseIterable { case file, text, view, play }

enum Files {
    static let images = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg", "ico"]
    static let audio = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff", "ogg", "opus"]
    static let video = ["mp4", "m4v", "mov", "webm"]
    static let books = ["pdf", "epub", "cbz", "cbr"]
    static let texts = [
        "txt", "md", "markdown", "log", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "cfg", "env",
        "xml", "html", "htm", "css", "scss", "js", "mjs", "cjs", "ts", "tsx", "jsx", "svelte", "vue", "py", "rb", "rs",
        "go", "swift", "java", "kt", "c", "h", "cpp", "hpp", "cs", "php", "sh", "zsh", "bash", "fish", "sql", "lua",
        "gitignore", "dockerfile", "makefile", "srt", "vtt", "tex", "plist", "jmx", "itermcolors",
    ]

    static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        if dot == name.startIndex { return String(name.dropFirst()).lowercased() }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// A file with no extension (README, Makefile) is tried as text; the Mac's app opens it if it isn't.
    static func kind(_ name: String) -> Kind {
        let e = ext(name)
        if images.contains(e) { return .image }
        if books.contains(e) { return .book }
        if audio.contains(e) { return .audio }
        if video.contains(e) { return .video }
        if texts.contains(e) || e.isEmpty { return .text }
        return .other
    }

    /// the mode a file opens in; nil: not one of ReFile's (the Mac's app opens it)
    static func mode(of kind: Kind) -> Mode? {
        switch kind {
        case .text: return .text
        case .image, .book: return .view
        case .audio, .video: return .play
        case .other: return nil
        }
    }

    /// whether `entry` shows in `mode`: folders always, files of the mode's kinds
    static func shows(_ entry: Entry, in mode: Mode) -> Bool {
        mode == .file || entry.isDir || Self.mode(of: kind(entry.name)) == mode
    }

    // ── reading ──

    static let fm = FileManager.default

    private static func isBundle(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "app" }

    static func entry(_ path: String) -> Entry? {
        guard let a = (try? fm.attributesOfItem(atPath: path)) ?? (try? fm.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath)) else { return nil }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        let dir = isDir.boolValue
        return Entry(name: (path as NSString).lastPathComponent, path: path, isDir: dir && !isBundle(path),
                     size: dir ? nil : (a[.size] as? NSNumber)?.int64Value, modified: a[.modificationDate] as? Date)
    }

    /// a folder's visible items: folders first, then files, each in natural order
    static func list(_ path: String) throws -> [Entry] {
        let names = try fm.contentsOfDirectory(atPath: path)
        let base = path == "/" ? "" : path
        return names.filter { !$0.hasPrefix(".") }.compactMap { entry(base + "/" + $0) }.sorted(by: natural)
    }

    static func natural(_ a: Entry, _ b: Entry) -> Bool {
        if a.isDir != b.isDir { return a.isDir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// every file inside `root`, at any depth (hidden ones and apps' insides left out), the first `limit`
    static func tree(_ root: String, limit: Int = 20000) throws -> [Entry] {
        let url = URL(fileURLWithPath: root)
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw NSError(domain: "ReFile", code: 1, userInfo: [NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is not a folder"])
        }
        var out: [Entry] = []
        for case let item as URL in walk {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true && !isBundle(item.path) { continue }
            if let e = entry(item.path) {
                out.append(e)
                if out.count >= limit { break }
            }
        }
        return out
    }

    static func info(_ path: String) -> Info? {
        guard let a = try? fm.attributesOfItem(atPath: path) else { return nil }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        let bundle = isBundle(path)
        let dir = isDir.boolValue && !bundle
        let kind: String
        if bundle { kind = "Application" } else if isDir.boolValue { kind = "Folder" } else {
            let e = (path as NSString).pathExtension
            kind = e.isEmpty ? "File" : "\(e.uppercased()) file"
        }
        let items = dir ? (try? fm.contentsOfDirectory(atPath: path))?.filter { !$0.hasPrefix(".") }.count : nil
        return Info(name: path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent, path: path, kind: kind, isDir: dir,
                    size: isDir.boolValue ? nil : (a[.size] as? NSNumber)?.int64Value, items: items,
                    created: a[.creationDate] as? Date, modified: a[.modificationDate] as? Date)
    }

    /// Everything inside a folder (or an app), in bytes, as Finder counts it: off the main thread, and
    /// gently (it walks every folder inside).
    static func treeSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let item as URL in walk {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    // ── changing ──

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func valid(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "." || n == ".." || n.contains("/") || n.contains("\0") { throw Problem(message: "Use a name without “/”.") }
        return n
    }

    static func createFolder(in parent: String, _ name: String) throws -> String {
        let n = try valid(name)
        let path = (parent as NSString).appendingPathComponent(n)
        if fm.fileExists(atPath: path) { throw Problem(message: "“\(n)” already exists here.") }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    static func createFile(in parent: String, _ name: String) throws -> String {
        let n = try valid(name)
        let path = (parent as NSString).appendingPathComponent(n)
        if fm.fileExists(atPath: path) { throw Problem(message: "“\(n)” already exists here.") }
        guard fm.createFile(atPath: path, contents: Data()) else { throw Problem(message: "Couldn't make “\(n)”.") }
        return path
    }

    /// "name copy.ext", then "name copy 2.ext", … as Finder
    private static func copyName(_ parent: String, _ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        let e = (name as NSString).pathExtension
        let folder = isDir.boolValue && !isBundle(path)
        let stem = folder || e.isEmpty ? name : (name as NSString).deletingPathExtension
        let tail = folder || e.isEmpty ? "" : "." + e
        var n = 1
        while true {
            let candidate = (parent as NSString).appendingPathComponent(stem + (n == 1 ? " copy" : " copy \(n)") + tail)
            if !fm.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
    }

    static func duplicate(_ path: String) throws -> String {
        let target = copyName((path as NSString).deletingLastPathComponent, path)
        try fm.copyItem(atPath: path, toPath: target)
        return target
    }

    /// files copied into `dir` (VIEW's ADD): one there by the same name already, the copy is "name copy"
    static func copy(_ paths: [String], into dir: String) throws -> [String] {
        var out: [String] = []
        for p in paths {
            var target = (dir as NSString).appendingPathComponent((p as NSString).lastPathComponent)
            if target == p { continue }
            if fm.fileExists(atPath: target) { target = copyName(dir, p) }
            try fm.copyItem(atPath: p, toPath: target)
            out.append(target)
        }
        return out
    }

    /// renamed in place; never over another item (a change of case only is the same item)
    static func rename(_ path: String, to name: String) throws -> String {
        let n = try valid(name)
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(n)
        if target == path { return target }
        if fm.fileExists(atPath: target) && target.lowercased() != path.lowercased() { throw Problem(message: "“\(n)” already exists here.") }
        try fm.moveItem(atPath: path, toPath: target)
        return target
    }

    /// zipped next to itself with ditto (the tool Finder uses): "name.zip", then "name 2.zip"
    static func compress(_ path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        var n = 1
        var target = ""
        repeat {
            target = (parent as NSString).appendingPathComponent(n == 1 ? "\(base).zip" : "\(base) \(n).zip")
            n += 1
        } while fm.fileExists(atPath: target)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", path, target]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            try? fm.removeItem(atPath: target)
            throw Problem(message: "Couldn't compress this item.")
        }
        return target
    }

    /// to the Trash (it can come back), never deleted outright
    static func trash(_ path: String) throws {
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    // ── texts ──

    /// a text file's first megabyte; nil when it isn't text (zero bytes, or not UTF-8)
    static func readText(_ path: String) -> (text: String, truncated: Bool)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let max = 1_000_000
        var bytes = (try? h.read(upToCount: max + 1)) ?? Data()
        let truncated = bytes.count > max
        if truncated { bytes = bytes.prefix(max) }
        return decode(bytes, cut: truncated).map { ($0, truncated) }
    }

    private static func decode(_ bytes: Data, cut: Bool) -> String? {
        if bytes.prefix(8192).contains(0) { return nil }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        // cut in the middle of a letter at the end: fine
        if cut || bytes.count > 0 {
            for drop in 1...3 where bytes.count > drop {
                if let s = String(data: bytes.dropLast(drop), encoding: .utf8) { return s }
            }
        }
        return nil
    }

    /// the start of a text (its first `max` bytes) and how many lines the whole file has; nil when not text
    static func head(_ path: String, max: Int) -> (text: String, lines: Int)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let first = (try? h.read(upToCount: min(max, 64 * 1024))) ?? Data()
        guard let text = decode(first, cut: true) else { return nil }
        var lines = first.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        var last = first.last
        var read = first.count
        while read < 50_000_000, let more = try? h.read(upToCount: 256 * 1024), !more.isEmpty {
            lines += more.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            last = more.last
            read += more.count
        }
        return (text, lines + (last != nil && last != 10 ? 1 : 0))
    }

    static func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // ── shown ──

    /// "17.02.2025 23.12.03"
    static func date(_ d: Date?) -> String {
        guard let d else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH.mm.ss"
        return f.string(from: d)
    }

    /// Finder's decimal sizes: 438 bytes, 3 KB, 1.2 MB
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        if bytes < 1000 { return "\(bytes) \(bytes == 1 ? "byte" : "bytes")" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(Int(value.rounded())) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }

    static func parent(_ path: String) -> String? {
        if path == "/" { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    static func name(_ path: String) -> String { path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent }
}

// ── ReDesk's wallpapers ──

extension Files {
    /// what ReDesk shows as a wallpaper: pictures, and videos AVFoundation plays
    static let wallpaperKinds: Set<String> = ["jpg", "jpeg", "png", "heic", "mp4", "mov", "m4v"]

    /// Edit › Add to wallpapers: a copy (a clone on APFS: no room taken until one of them changes) in ReDesk's
    /// Added folder, and ReDesk told, which lists it with its wallpapers at once
    static func addWallpaper(_ path: String) throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReDesk/Added", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let base = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        var target = folder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.artursavytskyi.redesk.wallpapers"), object: target.path, userInfo: nil, deliverImmediately: true)
    }
}
