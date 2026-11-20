import AppKit

// VIEW's books, read where they lie: where each was left (by its path), comics' pages (a CBZ or CBR is
// unpacked once into ReFile's cache: many "CBR"s are zips and the other way round, bsdtar reads both),
// and how pages are laid out two at a time.

/// where a book was left: a page index (PDF, comics) or a place in an EPUB; how far, 0…1; manga
struct Place {
    var position: String?
    var progress: Double = 0
    var rtl = false
}

enum Places {
    private static var all: [String: [String: Any]] = (Saved.json("books") as? [String: [String: Any]]) ?? [:]

    static func of(_ path: String) -> Place {
        guard let d = all[path] else { return Place() }
        let position = d["position"].flatMap { $0 is NSNull ? nil : "\($0)" }
        return Place(position: position, progress: (d["progress"] as? NSNumber)?.doubleValue ?? 0, rtl: d["rtl"] as? Bool ?? false)
    }

    static func keep(_ path: String, position: String? = nil, progress: Double? = nil, rtl: Bool? = nil) {
        var d = all[path] ?? [:]
        if let position { d["position"] = position }
        if let progress { d["progress"] = progress }
        if let rtl { d["rtl"] = rtl }
        all[path] = d
        Saved.setJSON("books", all)
    }

    /// "New", "34% read", "Finished"
    static func note(_ path: String) -> String {
        let p = of(path)
        if p.position == nil { return "New" }
        return p.progress >= 0.999 ? "Finished" : "\(Int((p.progress * 100).rounded()))% read"
    }
}

enum Comic {
    static let images = ["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "jxl"]

    /// where a comic's pages go: the cache, by its path and when it last changed
    static func folder(_ path: String) -> URL? {
        let fm = FileManager.default
        let changed = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 1469598103934665603
        for b in "\(path)|\(changed)".utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.artursavytskyi.refile/comics/\(String(hash, radix: 16))")
        if fm.fileExists(atPath: cache.path) { return cache }
        let part = cache.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        try? fm.createDirectory(at: part, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = ["-xf", path, "-C", part.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: part)
            return nil
        }
        try? fm.moveItem(at: part, to: cache)
        return cache
    }

    /// its pages, in their order
    static func pages(_ path: String) -> [URL] {
        guard let dir = folder(path), let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let u as URL in walk {
            let rel = u.path.dropFirst(dir.path.count + 1)
            if rel.lowercased().hasPrefix("__macosx") || u.lastPathComponent.hasPrefix(".") { continue }
            if images.contains(u.pathExtension.lowercased()) { out.append(u) }
        }
        return out.sorted { String($0.path.dropFirst(dir.path.count)).localizedStandardCompare(String($1.path.dropFirst(dir.path.count))) == .orderedAscending }
    }

    static func cover(_ path: String) -> NSImage? {
        pages(path).first.flatMap { NSImage(contentsOf: $0) }
    }
}

enum Spreads {
    /// Pages grouped as shown at once: portrait pages two side by side, a landscape page alone, the cover
    /// alone (as the front of a printed comic), a portrait page with no partner alone; a small window one by one.
    static func build(_ sizes: [NSSize], single: Bool) -> [[Int]] {
        var out: [[Int]] = []
        var i = 0
        let portrait = { (s: NSSize) in s.height > s.width }
        while i < sizes.count {
            if !single && i > 0 && portrait(sizes[i]) && i + 1 < sizes.count && portrait(sizes[i + 1]) {
                out.append([i, i + 1])
                i += 2
            } else {
                out.append([i])
                i += 1
            }
        }
        return out
    }

    static func of(_ spreads: [[Int]], page: Int) -> Int { spreads.firstIndex { $0.contains(page) } ?? 0 }

    /// "12 / 180" or "12–13 / 180"
    static func label(_ spread: [Int]?, total: Int) -> String {
        guard let spread, let first = spread.first, let last = spread.last, total > 0 else { return "" }
        return first == last ? "\(first + 1) / \(total)" : "\(first + 1)–\(last + 1) / \(total)"
    }
}
