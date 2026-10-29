//! ReFile: a quiet file browser in the ReNote style.
//! Rust reads and changes the filesystem; the Svelte UI (src/) calls these
//! commands through src/lib/files.ts.

mod fs;

use fs::{Entry, Info};
use std::path::PathBuf;
use tauri_plugin_opener::OpenerExt;

type CmdResult<T> = Result<T, String>;

#[tauri::command]
fn home_dir() -> CmdResult<String> {
    dirs::home_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .ok_or_else(|| "No home folder".into())
}

#[tauri::command]
fn list_dir(path: String) -> CmdResult<Vec<Entry>> {
    fs::list_dir(&PathBuf::from(path))
}

#[tauri::command]
fn item_info(path: String) -> CmdResult<Info> {
    fs::info(&PathBuf::from(path))
}

#[tauri::command]
fn create_folder(parent: String, name: String) -> CmdResult<String> {
    fs::create_folder(&PathBuf::from(parent), &name).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn rename_item(path: String, name: String) -> CmdResult<String> {
    fs::rename(&PathBuf::from(path), &name).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn compress_item(path: String) -> CmdResult<String> {
    fs::compress(&PathBuf::from(path)).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn duplicate_item(path: String) -> CmdResult<String> {
    fs::duplicate(&PathBuf::from(path)).map(|p| p.to_string_lossy().into_owned())
}

/// Opens Finder with the item selected.
#[tauri::command]
fn reveal_in_finder(path: String) -> CmdResult<()> {
    std::process::Command::new("open")
        .args(["-R", &path])
        .status()
        .map_err(|e| e.to_string())
        .and_then(|s| if s.success() { Ok(()) } else { Err("Finder couldn't show this item.".into()) })
}

#[tauri::command]
fn move_to_trash(path: String) -> CmdResult<()> {
    fs::move_to_trash(&PathBuf::from(path))
}

/// Opens a file (or app) with its default macOS application.
// ── the viewer: pictures and text open inside ReFile, music in ReSound ──

/// A picture's bytes, handed to the UI as they are (an ArrayBuffer there, no base64).
#[tauri::command]
fn read_file(path: String) -> CmdResult<tauri::ipc::Response> {
    const MAX: u64 = 200_000_000;
    let size = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
    if size > MAX {
        return Err("Too big to show".into());
    }
    std::fs::read(&path).map(tauri::ipc::Response::new).map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
struct Text {
    text: String,
    /// only the first megabyte is shown
    truncated: bool,
}

/// A text file's first megabyte; an error when it isn't text (zero bytes, or not UTF-8).
#[tauri::command]
fn read_text(path: String) -> CmdResult<Text> {
    use std::io::Read;
    const MAX: usize = 1_000_000;
    let mut bytes = Vec::new();
    std::fs::File::open(&path)
        .and_then(|f| f.take(MAX as u64 + 1).read_to_end(&mut bytes))
        .map_err(|e| e.to_string())?;
    let truncated = bytes.len() > MAX;
    bytes.truncate(MAX);
    if bytes[..bytes.len().min(8192)].contains(&0) {
        return Err("Not text".into());
    }
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text.to_owned(),
        // cut in the middle of a letter at the megabyte's end: fine; anywhere else: not UTF-8 text
        Err(e) if truncated && e.valid_up_to() + 4 >= bytes.len() => String::from_utf8_lossy(&bytes[..e.valid_up_to()]).into_owned(),
        Err(_) => return Err("Not text".into()),
    };
    Ok(Text { text, truncated })
}

/// The viewer's edits, written over the file.
#[tauri::command]
fn write_text(path: String, text: String) -> CmdResult<()> {
    std::fs::write(&path, text).map_err(|e| e.to_string())
}

/// Music goes to ReSound (which plays its folder from it); without ReSound, to the Mac's default.
#[tauri::command]
fn open_in_resound(app: tauri::AppHandle, path: String) -> CmdResult<()> {
    let sent = std::process::Command::new("open")
        .args(["-b", "com.artursavytskyi.resound", &path])
        .status()
        .is_ok_and(|s| s.success());
    if sent { Ok(()) } else { open_path(app, path) }
}

#[tauri::command]
fn open_path(app: tauri::AppHandle, path: String) -> CmdResult<()> {
    app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
}

/// No title bar at all (decorations are off in tauri.conf.json): macOS rims every titled window with
/// a light line that can't be turned off. The window is clear instead, its page is rounded here like a
/// window's corners, and the UI draws its own close / minimise / zoom buttons.
#[cfg(target_os = "macos")]
fn round_window(window: &tauri::WebviewWindow) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let _ = window.with_webview(|platform| {
        let view = platform.inner() as *mut AnyObject;
        if view.is_null() {
            return;
        }
        // SAFETY: `inner()` is the live WKWebView (an NSView); this runs on the main thread.
        unsafe {
            let _: () = msg_send![view, setWantsLayer: true];
            let layer: *mut AnyObject = msg_send![view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: 12.0f64];
                let _: () = msg_send![layer, setMasksToBounds: true];
            }
            // the shadow follows the rounded page, not the old square
            let ns_window: *mut AnyObject = msg_send![view, window];
            if !ns_window.is_null() {
                let _: () = msg_send![ns_window, invalidateShadow];
            }
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|_app| {
            #[cfg(target_os = "macos")]
            {
                use tauri::Manager;
                if let Some(window) = _app.get_webview_window("main") {
                    round_window(&window);
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            home_dir,
            list_dir,
            item_info,
            create_folder,
            rename_item,
            duplicate_item,
            compress_item,
            reveal_in_finder,
            move_to_trash,
            open_path,
            read_file,
            read_text,
            write_text,
            open_in_resound,
        ])
        .run(tauri::generate_context!())
        .expect("error while running ReFile");
}
