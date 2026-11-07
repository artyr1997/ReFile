# ReFile

A quiet file browser for macOS in the style of ReNote. Rust (Tauri) works with the
filesystem; the interface is Svelte.

- **COLM / LIST**: column view (folder + preview of the selected item) or a list with dates and sizes
- **DEL / INFO**: move to Trash, details and shortcuts; ← goes to the parent folder, N makes a new one
- **Load**: a faint line at each side, filled from below as far as used: the processor on the left, the memory on the right (hover for the numbers; not in a small window)
- **Search**: filters the current folder; under it a faint line, filled as far as the disk is used (hover for the numbers; not in a small window)
- Keys: ↑ ↓ select · → / Enter open · ← back · / search · C / L views · N new folder · I info · Backspace to Trash

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReFile.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.
