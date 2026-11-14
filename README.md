# ReFile

A quiet file browser for macOS in the style of ReNote. Rust (Tauri) works with the
filesystem; the interface is Svelte.

- **COLM / LIST**: column view (folder + preview of the selected item) or a list with dates and sizes
- **DEL / INFO**: move to Trash, details and shortcuts; ← goes to the parent folder, N makes a new one
- **Load**: a faint line at each side, filled from below as far as used: the processor on the left, the memory on the right, each with its percent under it (not in a small window)
- **Search**: filters the current folder; under it a faint line, filled as far as the disk is used, with the percent used and what is free under it (not in a small window)
- **Pictures and texts** open (Enter, a double click) in a window of their own, named after the file: ← → step through the folder's others, a text is written in place and saves itself, Esc or CLOSE closes the window. Space looks at one quickly in the same window instead.
- Keys: ⌘N new window · ↑ ↓ select · → / Enter open · ← back · / search · C / L views · ⌃⌘1 / 2 / 3 / 4 sort by name / kind / date / size (folders on top; the same keys again turn the order round; kept) · N new folder · I info · Backspace to Trash

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReFile.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.
