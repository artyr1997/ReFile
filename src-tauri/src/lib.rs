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

/// A folder's size, all that is inside it; off the main thread, as a big one takes a while.
#[tauri::command]
async fn folder_size(path: String) -> CmdResult<u64> {
    tauri::async_runtime::spawn_blocking(move || fs::tree_size(&PathBuf::from(path)))
        .await
        .map_err(|e| e.to_string())
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
// ── the viewer: pictures and text open inside ReFile, music in RePlay ──

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

/// Music and videos go to RePlay (which plays their folder from them); without RePlay, to the Mac's default.
#[tauri::command]
fn open_in_replay(app: tauri::AppHandle, path: String) -> CmdResult<()> {
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

/// How long the windows take to fade out (hiding, closing) and in (showing again).
#[cfg(target_os = "macos")]
const FADE_SECONDS: f64 = 0.4;

/// `windows` animated to `alpha` over FADE_SECONDS, then `done`.
#[cfg(target_os = "macos")]
unsafe fn fade_windows(windows: &[*mut objc2::runtime::AnyObject], alpha: f64, done: Option<&block2::Block<dyn Fn()>>) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    let _: () = msg_send![class!(NSAnimationContext), beginGrouping];
    let context: *mut AnyObject = msg_send![class!(NSAnimationContext), currentContext];
    let _: () = msg_send![context, setDuration: FADE_SECONDS];
    let name: *mut AnyObject = msg_send![class!(NSString), stringWithUTF8String: c"easeInEaseOut".as_ptr()];
    let timing: *mut AnyObject = msg_send![class!(CAMediaTimingFunction), functionWithName: name];
    let _: () = msg_send![context, setTimingFunction: timing];
    if let Some(done) = done {
        let _: () = msg_send![context, setCompletionHandler: done];
    }
    for &window in windows {
        let animator: *mut AnyObject = msg_send![window, animator];
        let _: () = msg_send![animator, setAlphaValue: alpha];
    }
    let _: () = msg_send![class!(NSAnimationContext), endGrouping];
}

/// all of the app's NSWindows
#[cfg(target_os = "macos")]
unsafe fn app_windows() -> Vec<*mut objc2::runtime::AnyObject> {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
    let windows: *mut AnyObject = msg_send![app, windows];
    let count: usize = msg_send![windows, count];
    (0..count).map(|i| msg_send![windows, objectAtIndex: i]).collect()
}

/// NSApplication's own hide:, kept to be called once the windows have faded out
#[cfg(target_os = "macos")]
static HIDE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// hide: (⌘H, the Hide menu item, ReDesk's Hide / Show Windows): the windows fade out first
#[cfg(target_os = "macos")]
unsafe extern "C-unwind" fn fading_hide(this: *mut objc2::runtime::AnyObject, sel: objc2::runtime::Sel, sender: *mut objc2::runtime::AnyObject) {
    use block2::RcBlock;
    let this = this as usize;
    let sender = sender as usize;
    let done = RcBlock::new(move || {
        // SAFETY: HIDE holds NSApplication's hide:, which takes these arguments
        unsafe {
            let hide: unsafe extern "C-unwind" fn(*mut objc2::runtime::AnyObject, objc2::runtime::Sel, *mut objc2::runtime::AnyObject) =
                std::mem::transmute(HIDE.load(std::sync::atomic::Ordering::Relaxed));
            hide(this as *mut _, sel, sender as *mut _);
            // hidden now: back to whole, for when the app shows again (which fades them in)
            for window in app_windows() {
                let _: () = objc2::msg_send![window, setAlphaValue: 1.0f64];
            }
        }
    });
    // SAFETY: on the main thread, as hide: is
    unsafe { fade_windows(&app_windows(), 0.0, Some(&done)) };
}

/// Windows fade out when the app hides and when one closes, and fade in when the app shows again.
/// ReDesk's Hide / Show Windows and Close All Windows ask with a distributed notification, "hide", "show" or "close".
#[cfg(target_os = "macos")]
fn fade_windows_in_and_out() {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send, sel};
    use std::ffi::CStr;

    // SAFETY: AppKit's own objects, on the main thread (setup); hide: keeps its signature
    unsafe {
        let method = objc2::ffi::class_getInstanceMethod(class!(NSApplication), sel!(hide:));
        if !method.is_null() {
            let ours: objc2::runtime::Imp = std::mem::transmute(fading_hide as *const ());
            // only once: a second time would keep fading_hide as the "original"
            if HIDE.load(std::sync::atomic::Ordering::Relaxed) == 0 {
                if let Some(old) = objc2::ffi::method_setImplementation(method, ours) {
                    HIDE.store(old as usize, std::sync::atomic::Ordering::Relaxed);
                }
            }
        }

        let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
        let null = std::ptr::null::<AnyObject>();
        let will = RcBlock::new(|_: *mut AnyObject| {
            for window in app_windows() {
                let _: () = msg_send![window, setAlphaValue: 0.0f64];
            }
        });
        let did = RcBlock::new(|_: *mut AnyObject| fade_windows(&app_windows(), 1.0, None));
        let will_name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"NSApplicationWillUnhideNotification".as_ptr()];
        let did_name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"NSApplicationDidUnhideNotification".as_ptr()];
        let _: *mut AnyObject = msg_send![center, addObserverForName: will_name, object: null, queue: null, usingBlock: &*will];
        let _: *mut AnyObject = msg_send![center, addObserverForName: did_name, object: null, queue: null, usingBlock: &*did];

        let desk = RcBlock::new(|note: *mut AnyObject| {
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
            let said = CStr::from_ptr(text).to_bytes();
            // "hide <pid>": this app alone (ReDesk's own desktops)
            let mine = format!("hide {}", std::process::id());
            if said == mine.as_bytes() {
                if !hidden {
                    let _: () = msg_send![app, hide: null];
                }
                return;
            }
            match said {
                b"hide" if !hidden => {
                    let _: () = msg_send![app, hide: null];
                }
                b"show" if hidden => {
                    let _: () = msg_send![app, unhideWithoutActivation];
                }
                b"close" => {
                    let windows = app_windows();
                    let shown: Vec<_> = windows.iter().copied().filter(|&w| msg_send![w, isVisible]).collect();
                    let gone = windows.iter().map(|&w| w as usize).collect::<Vec<_>>();
                    let done = RcBlock::new(move || {
                        for &window in &gone {
                            let _: () = msg_send![window as *mut AnyObject, close];
                        }
                    });
                    fade_windows(&shown, 0.0, Some(&done));
                }
                _ => {}
            }
        });
        let distributed: *mut AnyObject = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
        let name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"com.artursavytskyi.re.windows".as_ptr()];
        let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
        let _: *mut AnyObject = msg_send![distributed, addObserverForName: name, object: null, queue: queue, usingBlock: &*desk];
    }
}

/// The app, for ReDesk's word on which corners to round (listen_for_desk_corners).
#[cfg(target_os = "macos")]
static DESK_APP: std::sync::OnceLock<tauri::AppHandle> = std::sync::OnceLock::new();

/// ReDesk's Flush tiling: the windows side by side as one, so only the outer corners of them all are
/// round. ReDesk says, for each window, which corners (1 top left, 2 top right, 4 bottom left, 8 bottom
/// right) and which of its edges touch another window (1 top, 2 right, 4 bottom, 8 left): the window
/// rounds only those corners (no window has a rim or a shadow anyway).
#[cfg(target_os = "macos")]
fn listen_for_desk_corners(app: &tauri::AppHandle) {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use tauri::Manager;

    let _ = DESK_APP.set(app.clone());
    let handler = RcBlock::new(|note: *mut AnyObject| {
        // SAFETY: on the main queue; the userInfo ReDesk sends holds numbers only
        unsafe {
            let info: *mut AnyObject = msg_send![note, userInfo];
            if info.is_null() {
                return;
            }
            let number = |key: &std::ffi::CStr| -> f64 {
                let key: *mut AnyObject = msg_send![class!(NSString), stringWithUTF8String: key.as_ptr()];
                let value: *mut AnyObject = msg_send![info, objectForKey: key];
                if value.is_null() { -1.0 } else { msg_send![value, doubleValue] }
            };
            if number(c"pid") as u32 != std::process::id() {
                return;
            }
            let corners = number(c"corners") as u32;
            let Some(app) = DESK_APP.get() else { return };
            let Some(window) = app.get_webview_window("main") else { return };
            // this app's window there? (a second one of its windows is not this)
            let scale = window.scale_factor().unwrap_or(1.0);
            if let (Ok(at), Ok(size)) = (window.outer_position(), window.outer_size()) {
                let near = |a: f64, b: f64| (a - b).abs() < 24.0;
                if !(near(at.x as f64 / scale, number(c"x")) && near(at.y as f64 / scale, number(c"y"))
                    && near(size.width as f64 / scale, number(c"w")) && near(size.height as f64 / scale, number(c"h")))
                {
                    return;
                }
            }
            set_corners(&window, corners);
        }
    });
    // SAFETY: AppKit's own objects, on the main thread (setup); the center keeps the block
    unsafe {
        let center: *mut AnyObject = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
        let name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"com.artursavytskyi.re.corners".as_ptr()];
        let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
        let _: *mut AnyObject = msg_send![center, addObserverForName: name, object: std::ptr::null::<AnyObject>(),
                                          queue: queue, usingBlock: &*handler];
    }
}

/// Only `corners` round (the view's layer). No rim and no shadow, alone or not.
#[cfg(target_os = "macos")]
fn set_corners(window: &tauri::WebviewWindow, corners: u32) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let _ = window.with_webview(move |platform| {
        let view = platform.inner() as *mut AnyObject;
        if view.is_null() {
            return;
        }
        // SAFETY: the live WKWebView, on the main thread
        unsafe {
            let layer: *mut AnyObject = msg_send![view, layer];
            if layer.is_null() {
                return;
            }
            // the layer's own corners (CACornerMask: min X min Y 1, max X min Y 2, min X max Y 4, max X max Y 8);
            // its min Y is at the top when its contents are flipped
            let flipped: bool = msg_send![layer, contentsAreFlipped];
            let (top_left, top_right, bottom_left, bottom_right) = if flipped { (1, 2, 4, 8) } else { (4, 8, 1, 2) };
            let mut mask: usize = 0;
            if corners & 1 != 0 { mask |= top_left; }
            if corners & 2 != 0 { mask |= top_right; }
            if corners & 4 != 0 { mask |= bottom_left; }
            if corners & 8 != 0 { mask |= bottom_right; }
            let _: () = msg_send![layer, setMaskedCorners: mask];
        }
    });
}

/// A window asked to close fades out first, then goes.
fn fade_on_close(window: &tauri::Window, event: &tauri::WindowEvent) {
    #[cfg(target_os = "macos")]
    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        let Ok(ns_window) = window.ns_window() else { return };
        api.prevent_close();
        let target = window.clone();
        let done = block2::RcBlock::new(move || {
            let _ = target.destroy();
        });
        // SAFETY: the live NSWindow of `window`, on the main thread (window events are)
        unsafe { fade_windows(&[ns_window as *mut objc2::runtime::AnyObject], 0.0, Some(&done)) };
    }
}


#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .on_window_event(fade_on_close)
        .plugin(tauri_plugin_opener::init())
        .setup(|_app| {
            #[cfg(target_os = "macos")]
            fade_windows_in_and_out();
            #[cfg(target_os = "macos")]
            listen_for_desk_corners(_app.handle());
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
            folder_size,
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
            open_in_replay,
        ])
        .run(tauri::generate_context!())
        .expect("error while running ReFile");
}
