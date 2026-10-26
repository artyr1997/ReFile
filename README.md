# ReFile

A quiet file browser for macOS in the style of ReNote. Rust (Tauri) works with the
filesystem; the interface is Svelte.

- **COLM / LIST**: column view (folder + preview of the selected item) or a list with dates and sizes
- **BACK / NEW / DEL / INFO**: parent folder, new folder, move to Trash, details and shortcuts
- **Search**: filters the current folder
- Keys: ↑ ↓ select · → / Enter open · ← back · / search · C / L views · N new folder · I info · Backspace to Trash

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReFile.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.
