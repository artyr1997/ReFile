import AppKit
import PDFKit

// --render <dir>: ReFile drawn into pictures, out of sight, over a folder of made-up files (pictures, texts, a
// PDF), with its own empty music library: what is on this Mac is left alone.

enum Render {
    static func run(into dir: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("refile-render-\(getpid())")
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let files = root.appendingPathComponent("Made up")
        for d in ["Photos", "Notes", "Books", "Music"] { try? fm.createDirectory(at: files.appendingPathComponent(d), withIntermediateDirectories: true) }
        Saved.root = root.appendingPathComponent("state")
        Music.root = root.appendingPathComponent("music")
        try? fm.createDirectory(at: Music.root!, withIntermediateDirectories: true)
        Music.shared.setFolder(files.appendingPathComponent("Music").path)
        // pictures: a few soft gradients
        for (i, name) in ["Sea.png", "Dune.png", "Forest.png", "Night.png"].enumerated() {
            let img = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in
                let colors = [[NSColor.systemTeal, .systemBlue], [.systemOrange, .systemBrown], [.systemGreen, .systemTeal], [.systemIndigo, .black]][i]
                NSGradient(starting: colors[0], ending: colors[1])?.draw(in: r, angle: 60)
                return true
            }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: files.appendingPathComponent("Photos/\(name)"))
            }
        }
        let text = "# A quiet note\n\nKnowledge does not arrive complete.\nIt settles, layer by layer.\n\n" + (1...30).map { "Line \($0): the words go on." }.joined(separator: "\n")
        for name in ["Ideas.md", "Plan.txt", "todo.txt"] { try? text.write(to: files.appendingPathComponent("Notes/\(name)"), atomically: true, encoding: .utf8) }
        try? text.write(to: files.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        // a table: teas, as a CSV (a quoted cell with a comma in it)
        let teas = ["Name,Kind,Water,Time,Origin,Note", "Sencha,Green,70°,1 min,Shizuoka,\"Fresh, grassy\"", "Gyokuro,Green,55°,2 min,Uji,Shaded before the harvest",
                    "Hojicha,Roasted,90°,30 s,Kyoto,Toasty", "Genmaicha,Green with rice,85°,1 min,Shizuoka,Roasted rice", "Matcha,Powdered,80°,whisked,Uji,Drunk from a bowl",
                    "Bancha,Green,80°,1 min,Kagoshima,Everyday", "Kukicha,Stems,75°,1 min,Kyoto,Light and sweet", "Oolong,Half-fermented,90°,3 min,Taiwan,Many steepings",
                    "Darjeeling,Black,95°,3 min,India,Muscatel"].joined(separator: "\n")
        try? teas.write(to: files.appendingPathComponent("Notes/teas.csv"), atomically: true, encoding: .utf8)
        // a PDF of three pages
        let pdf = PDFDocument()
        for n in 1...3 {
            let page = NSImage(size: NSSize(width: 595, height: 842), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                attributed("Page \(n)", .systemFont(ofSize: 48), .black).draw(at: NSPoint(x: 60, y: 700))
                return true
            }
            if let p = PDFPage(image: page) { pdf.insert(p, at: n - 1) }
        }
        pdf.write(to: files.appendingPathComponent("Books/A short book.pdf"))

        func shoot(_ w: NSWindow, _ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let view = w.contentView else { return }
            view.frame = NSRect(origin: .zero, size: w.frame.size)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let out = NSImage(size: view.bounds.size)
            out.lockFocus()
            NSColor(white: 0.16, alpha: 1).setFill()
            view.bounds.fill()
            rep.draw(in: view.bounds)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        func window(_ size: NSSize, mode: Mode, at path: String, select: String?) -> FileWindow {
            let w = FileWindow(frame: NSRect(origin: .zero, size: size))
            w.main.frame = NSRect(origin: .zero, size: size)
            w.main.start()
            w.main.setMode(mode)
            w.main.navigate(path, select: select)
            return w
        }
        let wide = NSSize(width: 1440, height: 900)
        let w1 = window(wide, mode: .file, at: files.path, select: "README.md")
        shoot(w1, "file-colm")
        w1.main.key(keyEvent(37))
        shoot(w1, "file-list")
        let w2 = window(wide, mode: .view, at: files.path, select: "Photos")
        shoot(w2, "view-folder")
        w2.main.navigate(files.appendingPathComponent("Photos").path, select: "Sea.png")
        shoot(w2, "view-picture")
        w2.main.navigate(files.appendingPathComponent("Books").path, select: "A short book.pdf")
        shoot(w2, "view-book")
        let w3 = window(wide, mode: .text, at: files.appendingPathComponent("Notes").path, select: "Ideas.md")
        shoot(w3, "text-page")
        if let e = w3.main.current { w3.main.show(e) }
        shoot(w3, "text-viewer")
        let w8 = window(wide, mode: .text, at: files.appendingPathComponent("Notes").path, select: "teas.csv")
        shoot(w8, "table-page")
        if let e = w8.main.current { w8.main.show(e) }
        shoot(w8, "table-viewer")
        let w4 = window(wide, mode: .play, at: files.path, select: nil)
        shoot(w4, "play-folder")
        w4.main.key(keyEvent(19))
        shoot(w4, "play-songs")
        let w5 = window(wide, mode: .file, at: files.path, select: "Photos")
        w5.main.key(keyEvent(34))
        shoot(w5, "info")
        let w6 = window(NSSize(width: 640, height: 420), mode: .file, at: files.path, select: "README.md")
        shoot(w6, "small")
        let w7 = window(wide, mode: .view, at: files.appendingPathComponent("Books").path, select: "A short book.pdf")
        w7.main.openHere(w7.main.current!)
        shoot(w7, "reader")
        for w in [w1, w2, w3, w4, w5, w6, w7, w8] { w.main.end() }
        try? fm.removeItem(at: root)
    }

    private static func keyEvent(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
}
