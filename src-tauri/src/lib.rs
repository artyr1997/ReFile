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

/// The disk the user's files are on: its size and how much is free, in bytes.
#[derive(serde::Serialize)]
struct Disk {
    total: u64,
    free: u64,
}

#[tauri::command]
fn disk_space() -> CmdResult<Disk> {
    let home = dirs::home_dir().ok_or("no home folder")?;
    let path = std::ffi::CString::new(home.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
    let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: a valid C string and a statfs to fill.
    if unsafe { libc::statfs(path.as_ptr(), &mut stats) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let block = stats.f_bsize as u64;
    Ok(Disk { total: stats.f_blocks * block, free: stats.f_bavail * block })
}

/// How busy the Mac is, 0…1: the processor (all its cores, since the last time asked) and the memory.
#[derive(serde::Serialize)]
struct Load {
    cpu: f32,
    memory: f32,
}

#[tauri::command]
fn load() -> Load {
    use sysinfo::{CpuRefreshKind, MemoryRefreshKind, RefreshKind, System};
    static SYSTEM: std::sync::OnceLock<std::sync::Mutex<System>> = std::sync::OnceLock::new();
    let system = SYSTEM.get_or_init(|| {
        let what = RefreshKind::nothing().with_cpu(CpuRefreshKind::nothing().with_cpu_usage()).with_memory(MemoryRefreshKind::nothing().with_ram());
        std::sync::Mutex::new(System::new_with_specifics(what))
    });
    let Ok(mut system) = system.lock() else { return Load { cpu: 0.0, memory: 0.0 } };
    system.refresh_cpu_usage();
    system.refresh_memory();
    let total = system.total_memory().max(1) as f32;
    Load { cpu: system.global_cpu_usage() / 100.0, memory: system.used_memory() as f32 / total }
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
/// window's corners, and the UI draws its own close / minimise / zoom buttons. No shadow either
/// (tauri.conf.json).
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
        }
    });
}

/// The window starts hidden (tauri.conf.json) and fades in once the interface has drawn itself
/// (window_ready), so the app opens softly instead of appearing empty.
#[cfg(target_os = "macos")]
fn fade_in(window: &tauri::Window) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};

    if window.is_visible().unwrap_or(true) {
        return;
    }
    let Ok(ns_window) = window.ns_window() else {
        let _ = window.show();
        return;
    };
    let ns_window = ns_window as *mut AnyObject;
    // SAFETY: the live NSWindow of `window`, on the main thread (see reveal).
    unsafe {
        let _: () = msg_send![ns_window, setAlphaValue: 0.0f64];
    }
    let _ = window.show();
    let _ = window.set_focus();
    unsafe {
        let _: () = msg_send![class!(NSAnimationContext), beginGrouping];
        let context: *mut AnyObject = msg_send![class!(NSAnimationContext), currentContext];
        let _: () = msg_send![context, setDuration: 0.3f64];
        let name: *mut AnyObject = msg_send![class!(NSString), stringWithUTF8String: c"easeOut".as_ptr()];
        let timing: *mut AnyObject = msg_send![class!(CAMediaTimingFunction), functionWithName: name];
        let _: () = msg_send![context, setTimingFunction: timing];
        let animator: *mut AnyObject = msg_send![ns_window, animator];
        let _: () = msg_send![animator, setAlphaValue: 1.0f64];
        let _: () = msg_send![class!(NSAnimationContext), endGrouping];
    }
}

/// Fades the window in on the main thread; `after` waits first (the fallback, should the interface never say it is ready).
fn reveal(window: &tauri::Window, after: std::time::Duration) {
    let window = window.clone();
    std::thread::spawn(move || {
        std::thread::sleep(after);
        let target = window.clone();
        let _ = window.run_on_main_thread(move || {
            #[cfg(target_os = "macos")]
            fade_in(&target);
            #[cfg(not(target_os = "macos"))]
            let _ = target.show();
        });
    });
}

/// The interface has drawn itself (main.ts): the window can fade in.
#[tauri::command]
fn window_ready(webview: tauri::Webview) {
    // the webview's window: ReSurf's holds its tabs' webviews too
    reveal(&webview.window(), std::time::Duration::ZERO);
}

/// ReDesk's Hide / Show Windows (a distributed notification, "hide" or "show"): the windows fade out
/// and then the app hides, or the app shows again with its windows fading in.
#[cfg(target_os = "macos")]
fn listen_for_desk_fades() {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use std::ffi::CStr;

    /// every window of the app animated to `alpha`, then `done`
    unsafe fn animate(alpha: f64, done: Option<&block2::Block<dyn Fn()>>) {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let windows: *mut AnyObject = msg_send![app, windows];
        let count: usize = msg_send![windows, count];
        let _: () = msg_send![class!(NSAnimationContext), beginGrouping];
        let context: *mut AnyObject = msg_send![class!(NSAnimationContext), currentContext];
        let _: () = msg_send![context, setDuration: 0.25f64];
        if let Some(done) = done {
            let _: () = msg_send![context, setCompletionHandler: done];
        }
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            let animator: *mut AnyObject = msg_send![window, animator];
            let _: () = msg_send![animator, setAlphaValue: alpha];
        }
        let _: () = msg_send![class!(NSAnimationContext), endGrouping];
    }

    /// every window's alpha set at once
    unsafe fn set_alpha(alpha: f64) {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let windows: *mut AnyObject = msg_send![app, windows];
        let count: usize = msg_send![windows, count];
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            let _: () = msg_send![window, setAlphaValue: alpha];
        }
    }

    let handler = RcBlock::new(|note: *mut AnyObject| {
        // SAFETY: on the main queue, with AppKit's own objects
        unsafe {
            let object: *mut AnyObject = msg_send![note, object];
            if object.is_null() {
                return;
            }
            let text: *const std::os::raw::c_char = msg_send![object, UTF8String];
            if text.is_null() {
                return;
            }
            let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
            let hidden: bool = msg_send![app, isHidden];
            match CStr::from_ptr(text).to_bytes() {
                b"hide" if !hidden => {
                    let done = RcBlock::new(|| {
                        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
                        let _: () = msg_send![app, hide: std::ptr::null::<AnyObject>()];
                        set_alpha(1.0);
                    });
                    animate(0.0, Some(&done));
                }
                b"show" if hidden => {
                    set_alpha(0.0);
                    let _: () = msg_send![app, unhideWithoutActivation];
                    animate(1.0, None);
                }
                _ => {}
            }
        }
    });
    // SAFETY: the center copies the block and keeps the observer for the app's life
    unsafe {
        let center: *mut AnyObject = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
        let name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"com.artursavytskyi.re.windows".as_ptr()];
        let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
        let _: *mut AnyObject = msg_send![center, addObserverForName: name, object: std::ptr::null::<AnyObject>(),
                                          queue: queue, usingBlock: &*handler];
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|_app| {
            #[cfg(target_os = "macos")]
            listen_for_desk_fades();
            #[cfg(target_os = "macos")]
            {
                use tauri::Manager;
                if let Some(window) = _app.get_webview_window("main") {
                    round_window(&window);
                    reveal(&window.as_ref().window(), std::time::Duration::from_secs(3));
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            window_ready,
            home_dir,
            disk_space,
            load,
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
