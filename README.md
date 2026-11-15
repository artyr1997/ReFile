# ReFile

A quiet file browser for macOS in the style of ReNote. Rust (Tauri) works with the
filesystem; the interface is Svelte.

Four modes, on **F / T / V / P** (this folder in that mode); the sides keep COLM / LIST at the top, INFO / DEL at the
bottom (a small window has no buttons, the keys only). A window keeps its mode;
a file opened (Enter, a double click), in any mode, goes to a new window of its own in its mode, named after it
(music too: that window plays it); in that window the folder's others open there.
**⇧Enter** (or **⇧F / ⇧T / ⇧V / ⇧P**, for another mode) opens the folder selected (or this one) in a new window,
every file inside it at any depth in one list, in that mode: ⇧P on Music, all its music.
Those new windows keep to what they were opened for: their mode stays (only its button shows), and
nothing above their folder can be reached (the folders inside a file's folder can).

- **FILE**: everything. COLM / LIST (C / L): a column view (folder + preview of the selected item: a picture, a book's cover, a text's start or a video's first frame over its details) or a list with dates and sizes; ← goes to the parent folder, N makes a new one, Backspace moves to the Trash, I shows details and the keys.
- **TEXT**: only texts (code, notes, logs, anything with text in it), always in columns, as VIEW: on the right the start of the text as a page, with its kind, lines and size under it; a folder shows its texts as small pages of their first lines. Enter opens one, written in place, saving itself; ← → step through the folder's others.
- **VIEW** (what ReBook was): only pictures and books (PDF, EPUB, CBZ, CBR), always in columns, as ReBook's library: on the right the picture or the book's cover, big, with what it is under it (a book: how far it was read; a picture: its size in pixels); a folder shows its pictures and books, small. Pictures open full (← → through the others); books are read where they lie, with two-page spreads, the page turn, manga (M), full screen (F), and the place each was left at kept (by its path).
- **PLAY** (what RePlay was): only music and videos; FOLDER plays the folder from the song chosen, a video shows in a card; SONGS has every song of the music folder; RADIO has stations by genre (K keeps one). The player under them, PREV / NEXT on the sides, shuffle / repeat (S / R), up next (Q), the Mac's media keys, the mini player in a tiny window (M; a small one keeps the list). The library and the kept stations are RePlay's own.
- **Load**: a faint line at each side, filled from below as far as used: the processor on the left, the memory on the right, each with its percent under it (not in a small window, nor in PLAY)
- **Search**: filters the current folder (in PLAY: at the top, the songs or the stations too); under it a faint line, filled as far as the disk is used (not in a small window, nor in PLAY)
- Keys: F / T / V / P modes · ⇧Enter / ⇧F ⇧T ⇧V ⇧P all inside a folder, in a new window · ⌘N new window · ↑ ↓ select · → / Enter open · Space a quick look (in PLAY: play / pause) · ← back · / search · C / L views · ⌃⌘1 / 2 / 3 / 4 sort by name / kind / date / size (folders on top; the same keys again turn the order round; kept) · N new folder · I info · E actions · Backspace to Trash

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReFile.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.
