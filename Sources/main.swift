import AppKit

// ReFile: a quiet file browser (FILE; a file opens in its own window in TEXT, VIEW or PLAY). A native Mac app on the ReSpace desk.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launched = false
    private var pending: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = menu()
        Lang.shared.follow()
        Desk.listen()
        launched = true
        if pending.isEmpty {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(1440, screen.width), height: min(900, screen.height))
            open(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), opened: nil)
        } else {
            for p in pending { newWindow(from: nil, opened: Opened(path: p)) }
        }
        pending = []
    }

    /// a file opened with ReFile (Open With in Finder): a window in its mode, showing it
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        if !launched { pending += paths; return }
        for p in paths { newWindow(from: NSApp.keyWindow, opened: Opened(path: p)) }
    }

    @discardableResult
    func open(_ frame: NSRect, opened: Opened?) -> FileWindow {
        let w = FileWindow(frame: frame)
        w.main.opened = opened
        if let p = opened?.path ?? opened?.tree { w.title = Files.name(p) }
        w.open()
        return w
    }

    /// ⌘N (or a file, or a folder all inside): another window, the size of the one in front, a little lower and to the right
    func newWindow(from front: NSWindow?, opened: Opened?) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = front?.frame ?? NSRect(x: screen.midX - 720, y: screen.midY - 450, width: min(1440, screen.width), height: min(900, screen.height))
        open(front == nil ? base : base.offsetBy(dx: 28, dy: -28), opened: opened)
    }

    // quits when its last window is closed, not when its windows are put away on another of ReDesk's desktops
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { putAway.isEmpty }

    func applicationWillTerminate(_ notification: Notification) {
        for case let w as FileWindow in NSApp.windows { w.main.end() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSApp.windows.compactMap({ $0 as? FileWindow }).isEmpty { newWindow(from: nil, opened: nil) }
        return true
    }

    private func menu() -> NSMenu {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Hide ReFile", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ReFile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(withTitle: "ReFile", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        bar.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return bar
    }
}

let app = ReApp.shared
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    Render.run(into: CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
