//! VIEW (what ReBook was): books read where they lie. PDF and EPUB bytes go to the UI as they are
//! (read_file); comics (CBZ, CBR) are served a page at a time over the `refile://` protocol:
//!   refile://localhost/page/<index>?<the comic's path, percent-encoded>
//! A CBR is unpacked once into ReFile's cache (many "CBR"s are zips, and the other way round).

use crate::comic::{self, PageSize, Pages, Source};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::http::{Response, StatusCode};

type CmdResult<T> = Result<T, String>;

/// Comics opened in this run, by path: their page lists (with sizes).
static OPENED: Mutex<Option<HashMap<String, Arc<Pages>>>> = Mutex::new(None);

/// What a file really is, by its first bytes.
fn sniff(path: &Path) -> Option<&'static str> {
    let mut head = [0u8; 8];
    let n = std::fs::File::open(path).ok()?.read(&mut head).ok()?;
    let head = &head[..n];
    if head.starts_with(b"Rar!") {
        Some("rar")
    } else if head.starts_with(b"PK") {
        Some("zip")
    } else {
        None
    }
}

/// Where a CBR's pages go: the cache, by its path and when it last changed.
fn unpacked(path: &Path) -> CmdResult<PathBuf> {
    use std::hash::{Hash, Hasher};
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hash);
    std::fs::metadata(path).and_then(|m| m.modified()).ok().hash(&mut hash);
    let dir = dirs::cache_dir().ok_or("no cache folder")?.join("com.artursavytskyi.refile/comics").join(format!("{:016x}", hash.finish()));
    if !dir.exists() {
        let part = dir.with_extension("part");
        let _ = std::fs::remove_dir_all(&part);
        comic::unpack_rar(path, &part)?;
        std::fs::rename(&part, &dir).map_err(|e| e.to_string())?;
    }
    Ok(dir)
}

fn pages(path: &str) -> CmdResult<Arc<Pages>> {
    if let Some(pages) = OPENED.lock().ok().and_then(|m| m.as_ref().and_then(|m| m.get(path).cloned())) {
        return Ok(pages);
    }
    let file = PathBuf::from(path);
    let source = match sniff(&file) {
        Some("rar") => Source::Folder(unpacked(&file)?),
        Some("zip") => Source::Zip(file),
        _ => return Err("Not a comic".into()),
    };
    let pages = Arc::new(comic::load(source)?);
    if pages.names.is_empty() {
        return Err("No pages in it".into());
    }
    if let Ok(mut opened) = OPENED.lock() {
        opened.get_or_insert_with(HashMap::new).insert(path.to_owned(), pages.clone());
    }
    Ok(pages)
}

/// A comic's pages, as their sizes (the reader lays out its spreads from them); off the main thread.
#[tauri::command]
pub async fn comic_pages(path: String) -> CmdResult<Vec<PageSize>> {
    tauri::async_runtime::spawn_blocking(move || pages(&path).map(|p| p.sizes.clone())).await.map_err(|e| e.to_string())?
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Some(b) = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn respond(status: StatusCode, mime: &str, body: Vec<u8>) -> Response<Vec<u8>> {
    Response::builder()
        .status(status)
        .header("Content-Type", mime)
        .header("Access-Control-Allow-Origin", "*")
        .header("Cache-Control", "max-age=3600")
        .body(body)
        .unwrap_or_else(|_| Response::new(Vec::new()))
}

/// Serves `refile://localhost/page/<index>?<path>`.
pub fn serve(uri: &tauri::http::Uri) -> Response<Vec<u8>> {
    let parts: Vec<&str> = uri.path().trim_matches('/').split('/').collect();
    let path = decode(uri.query().unwrap_or(""));
    let result = match (parts.first().copied(), parts.get(1).and_then(|s| s.parse::<usize>().ok())) {
        (Some("page"), Some(index)) => pages(&path).and_then(|p| p.read(index)),
        _ => Err("Unknown address".into()),
    };
    match result {
        Ok((body, mime)) => respond(StatusCode::OK, mime, body),
        Err(e) => respond(StatusCode::NOT_FOUND, "text/plain", e.into_bytes()),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn percent_decoding() {
        assert_eq!(super::decode("%2FUsers%2Fa%20b%2F%D0%BA.cbz"), "/Users/a b/к.cbz");
    }
}
