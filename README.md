# ReFile

A quiet file browser for macOS in the style of ReNote. Rust (Tauri) works with the
filesystem; the interface is Svelte.

Four modes, one in each corner (and **F / T / V / P**: this folder in that mode). A window keeps its mode;
a file opened in FILE (Enter, a double click) goes to a window of its own in its mode, named after it.

- **FILE**: everything. COLM / LIST (C / L): a column view (folder + preview of the selected item) or a list with dates and sizes; ← goes to the parent folder, N makes a new one, Backspace moves to the Trash, I shows details and the keys.
- **TEXT**: only texts (code, notes, logs, anything with text in it); Enter opens one, written in place, saving itself; ← → step through the folder's others.
- **VIEW** (what ReBook was): only pictures and books (PDF, EPUB, CBZ, CBR); the right column shows the picture or the book's cover. Pictures open full (← → through the others); books are read where they lie, with two-page spreads, the page turn, manga (M), full screen (F), and the place each was left at kept (by its path).
- **PLAY** (what RePlay was): only music and videos; FOLDER plays the folder from the song chosen, a video shows in a card; SONGS has every song of the music folder; RADIO has stations by genre (K keeps one). The player under them, PREV / NEXT on the sides, shuffle / repeat (S / R), up next (Q), the Mac's media keys, the mini player in a small window (M). The library and the kept stations are RePlay's own.
- **Load**: a faint line at each side, filled from below as far as used: the processor on the left, the memory on the right, each with its percent under it (not in a small window, nor in PLAY)
- **Search**: filters the current folder (in PLAY: at the top, the songs or the stations too); under it a faint line, filled as far as the disk is used (not in a small window, nor in PLAY)
- Keys: F / T / V / P modes · ⌘N new window · ↑ ↓ select · → / Enter open · Space a quick look (in PLAY: play / pause) · ← back · / search · C / L views · ⌃⌘1 / 2 / 3 / 4 sort by name / kind / date / size (folders on top; the same keys again turn the order round; kept) · N new folder · I info · E actions · Backspace to Trash

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReFile.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.
