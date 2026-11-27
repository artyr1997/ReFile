import AppKit
import CoreText

// The look: glass, as every Re app on the desk. The window is the system's blur of what is behind it, the
// words on it in the desk's white ink; the buttons in Noto Sans JP, the words in M PLUS 1p.

enum Ink {
    /// the words (as --text on glass)
    static let text = NSColor(white: 1, alpha: 0.8)
    /// lines, frames, quieter words (as --line)
    static let line = NSColor(white: 1, alpha: 0.5)
    /// what is written in something inked: a dark solid (as --bg)
    static let paper = NSColor(red: 0x1f / 255, green: 0x20 / 255, blue: 0x23 / 255, alpha: 1)
    /// the popups' pane over the blur
    static let pane = NSColor(white: 0, alpha: 0.32)
    /// quieter words (as --muted)
    static let muted = NSColor(white: 1, alpha: 0.6)
    /// what went wrong
    static let error = NSColor(red: 0xe0 / 255, green: 0x7a / 255, blue: 0x72 / 255, alpha: 1)
}

enum Fonts {
    private static func descriptor(_ name: String, _ ext: String) -> CTFontDescriptor? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "fonts"),
              let all = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        return all.first
    }

    /// Noto Sans JP: its Latin letters, the Japanese ones after them
    private static let noto: CTFontDescriptor? = {
        guard let latin = descriptor("noto-sans-jp-latin-400-normal", "woff") else { return nil }
        guard let japanese = descriptor("noto-sans-jp-japanese-400-normal", "woff") else { return latin }
        return CTFontDescriptorCreateCopyWithAttributes(latin, [kCTFontCascadeListAttribute: [japanese]] as CFDictionary)
    }()

    private static let mplus: CTFontDescriptor? = descriptor("MPLUS1p", "ttf")

    private static var cache: [String: NSFont] = [:]

    private static func font(_ d: CTFontDescriptor?, _ key: String, _ size: CGFloat, fallback: NSFont) -> NSFont {
        let id = "\(key)-\(size)"
        if let f = cache[id] { return f }
        let f = d.map { CTFontCreateWithFontDescriptor($0, size, nil) as NSFont } ?? fallback
        cache[id] = f
        return f
    }

    /// the buttons' lettering
    static func buttons(_ size: CGFloat) -> NSFont {
        font(noto, "noto", size, fallback: .systemFont(ofSize: size, weight: .light))
    }

    /// the words
    static func words(_ size: CGFloat) -> NSFont {
        font(mplus, "mplus", size, fallback: .systemFont(ofSize: size))
    }

    /// a text's own lettering, of one width (the viewer, a text's page)
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

// ── the desk's language: ReDesk's Settings › Language (English or Japanese) ──

final class Lang {
    static let shared = Lang()
    static let changed = Notification.Name("ReFile.language")

    private(set) var japanese = false

    // four characters each, as the English words are four letters
    private let words: [String: String] = [
        "COLM": "縦列表示",
        "LIST": "一覧表示",
        "INFO": "詳細情報",
        "DEL": "削除する",
        "SONG": "楽曲一覧",
        "LIVE": "ラジオ局",
        "PLAYER FULL": "全画面化",
        "PREV": "前の曲へ",
        "NEXT": "次の曲へ",
        "READ": "中を見る",
        "ADD": "追加する",
        "EDIT": "編集する",
        "NOVA": "新規作成",
        "CLOSE": "閲覧終了",
        "BACK": "前に戻る",
        "FULL": "全画面化",
        "NEW ROW": "行を追加",
        "SORT": "並べ替え",
        "MANG": "右から左",
        "NEXT BOOK": "次の本へ",
        "FAVO": "栞を挟む",
        "PEN": "ペン書き",
        "BRUSH": "筆で書く",
        "UNDO": "元に戻す",
        "PAD": "指で描く",
        "SAVE": "保存する",
        "RUB": "消しゴム",
        "EXIT": "編集終了",
        "IMP": "読み込み",
        "EXP": "書き出し",
        "HOME": "ホームへ",
        "NEW TAB": "新規タブ",
        "FULL NOTE": "全文表示",
        "NEXT SPACE": "次の場所",
    ]

    // the popups' words
    private let texts: [String: String] = [
        "Move “{name}” to Trash?": "「{name}」をゴミ箱に入れますか？",
        "YES": "はい",
        "NO": "いいえ",
        "NEW TEXT": "新しいテキスト",
        "NEW FOLDER": "新しいフォルダ",
        "CREATE": "作成",
        "CANCEL": "キャンセル",
        "RENAME": "名前を変更",
        "Open": "開く",
        "Rename": "名前を変更",
        "Duplicate": "複製",
        "Compress": "圧縮",
        "Copy path": "パスをコピー",
        "Show in Finder": "Finderで表示",
        "Add to wallpapers": "壁紙に追加",
        "Row above": "上に行を追加", "Row below": "下に行を追加", "Column left": "左に列を追加", "Column right": "右に列を追加",
        "Delete row": "行を削除", "Delete column": "列を削除", "Sort A → Z": "昇順に並べる", "Sort Z → A": "降順に並べる", "Undo": "取り消す", "Redo": "やり直す", "Cut": "切り取り", "Copy": "コピー", "Paste": "貼り付け",
        "Info": "情報",
        "Move to Trash": "ゴミ箱に入れる",
        "Kind": "種類",
        "Items": "項目数",
        "Size": "サイズ",
        "Created": "作成日",
        "Modified": "変更日",
        "Where": "場所",
        "local · private · offline": "ローカル · 非公開 · オフライン",
        "This folder in FILE / TEXT / VIEW / PLAY": "このフォルダを FILE / TEXT / VIEW / PLAY で",
        "The folder selected, all inside it (at any depth), in a new window": "選んだフォルダの中身をすべて（どの深さも）新しいウィンドウで",
        "New window": "新しいウィンドウ",
        "Select": "選ぶ",
        "Open (a file: in a new window, in its mode)": "開く（ファイルは新しいウィンドウで、その種類のモードで）",
        "A quick look at a picture or text, here": "画像やテキストをここでちらっと見る",
        "Save the text (it saves itself too)": "テキストを保存（自動でも保存されます）",
        "Back": "戻る",
        "Search": "検索",
        "Search songs": "曲を検索",
        "Search stations": "放送局を検索",
        "Columns / List": "列 / 一覧",
        "Sort by name / kind / date / size (again: the other way)": "名前 / 種類 / 日付 / サイズで並べる（もう一度で逆順）",
        "New folder": "新しいフォルダ",
        "Actions": "操作",
        "E / right click": "E / 右クリック",
        "Space": "スペース",
        "Play": "再生",
        "Play next": "次に再生",
        "Add to queue": "再生待ちに追加",
        "UP NEXT": "次に再生",
        "Nothing after this song.": "この曲の後には何もありません。",
        "{n} song": "{n}曲",
        "{n} songs": "{n}曲",
        "No folder chosen": "フォルダが選ばれていません",
        "FOLDER": "フォルダ",
        "RESCAN": "再スキャン",
        "Folder / songs / radio": "フォルダ / 曲 / ラジオ",
        "Play / pause": "再生 / 一時停止",
        "Play (a video: here)": "再生（動画はここで）",
        "Genres / stations (radio)": "ジャンル / 局（ラジオ）",
        "Keep a station": "局を保存",
        "Shuffle / repeat": "シャッフル / リピート",
        "Up next": "次に再生",
        "Mini player": "ミニプレーヤー",
    ]

    // The language turning, as on a departures board: each letter runs through others (Latin and katakana)
    // before it stops at its new one, the first soonest, the next a little later.
    private let pool = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private let step = 55.0, settle = 260.0, stagger = 110.0, length = 1200.0
    private var frame = -1
    private var timer: Timer?

    /// a button's word in the desk's language; `as` names it where the same word means another thing
    func t(_ word: String, as key: String? = nil) -> String {
        let target = japanese ? (words[key ?? word] ?? word) : word
        guard frame >= 0 else { return target }
        let elapsed = Double(frame) * step
        var out = ""
        for (i, letter) in target.enumerated() {
            if letter == " " || elapsed >= settle + Double(i) * stagger {
                out.append(letter)
                continue
            }
            var hash = Int32(truncatingIfNeeded: frame &* 31 &+ i &* 17)
            for unit in (key ?? word).utf16 { hash = hash &* 33 &+ Int32(unit) }
            out.append(pool[Int(hash.magnitude % UInt32(pool.count))])
        }
        return out
    }

    /// the popups' words (any length); {name} in them is filled from `values`
    func tx(_ text: String, _ values: [String: Any] = [:]) -> String {
        var out = japanese ? (texts[text] ?? text) : text
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: "\(value)") }
        return out
    }

    private func set(_ code: String, animate: Bool) {
        let ja = code == "ja"
        if animate && ja != japanese && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { turn() }
        japanese = ja
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func turn() {
        timer?.invalidate()
        frame = 0
        timer = Timer.scheduledTimer(withTimeInterval: step / 1000, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if Double(self.frame + 1) * self.step > self.length {
                self.frame = -1
                t.invalidate()
                self.timer = nil
            } else {
                self.frame += 1
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// once, at start: the language ReDesk keeps (in Application Support/ReSpace/language, a file of the suite's
    /// own: ReDesk's settings are another app's data to macOS, which would ask each time), and its word when it changes
    func follow() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReSpace/language")
        let kept = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        set(kept.flatMap { $0.isEmpty ? nil : $0 } ?? "en", animate: false)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.artursavytskyi.re.language"), object: nil, queue: .main) { [weak self] note in
            self?.set(note.object as? String ?? "en", animate: true)
        }
    }
}

func t(_ word: String, as key: String? = nil) -> String { Lang.shared.t(word, as: key) }
func tx(_ text: String, _ values: [String: Any] = [:]) -> String { Lang.shared.tx(text, values) }
