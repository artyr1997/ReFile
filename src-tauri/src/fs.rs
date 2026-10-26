//! Filesystem side of ReFile: reading folders, item details, new folders, Trash.
//! Kept free of Tauri so it can be unit-tested; lib.rs exposes it as commands.

use serde::Serialize;
use std::cmp::Ordering;
use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, String>;

/// One row in a folder listing.
#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub name: String,
    pub path: String,
    /// true for folders you can step into; app bundles count as files, like in Finder
    pub is_dir: bool,
    /// bytes; None for folders
    pub size: Option<u64>,
    /// milliseconds since the Unix epoch
    pub modified: Option<i64>,
}

/// Details for the INFO popup.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub name: String,
    pub path: String,
    pub kind: String,
    pub is_dir: bool,
    pub size: Option<u64>,
    /// visible items inside a folder
    pub items: Option<usize>,
    pub created: Option<i64>,
    pub modified: Option<i64>,
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn millis(time: std::io::Result<SystemTime>) -> Option<i64> {
    let t = time.ok()?.duration_since(UNIX_EPOCH).ok()?;
    i64::try_from(t.as_millis()).ok()
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

fn is_bundle(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(),
        Some("app")
    )
}

/// Follows symlinks; falls back to the link itself when the target is gone.
fn metadata(path: &Path) -> Option<Metadata> {
    fs::metadata(path).or_else(|_| fs::symlink_metadata(path)).ok()
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

fn entry(path: PathBuf) -> Option<Entry> {
    let meta = metadata(&path)?;
    let is_dir = meta.is_dir() && !is_bundle(&path);
    Some(Entry {
        name: name_of(&path),
        is_dir,
        size: if is_dir { None } else { Some(meta.len()) },
        modified: millis(meta.modified()),
        path: path.to_string_lossy().into_owned(),
    })
}

/// "file2" before "file10", case-insensitive, like Finder.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.to_lowercase(), b.to_lowercase());
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut s = String::new();
                    while let Some(ch) = it.peek().copied().filter(char::is_ascii_digit) {
                        s.push(ch);
                        it.next();
                    }
                    s
                };
                let (m, n) = (take(&mut x), take(&mut y));
                let (mt, nt) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                let ord = mt.len().cmp(&nt.len()).then_with(|| mt.cmp(nt)).then_with(|| m.len().cmp(&n.len()));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(c), Some(d)) => {
                if c != d {
                    return c.cmp(&d);
                }
                x.next();
                y.next();
            }
        }
    }
}

/// Visible items of a folder: folders first, then files, each in natural order.
pub fn list_dir(path: &Path) -> Result<Vec<Entry>> {
    let mut entries: Vec<Entry> = fs::read_dir(path)
        .map_err(err)?
        .filter_map(|e| e.ok())
        .filter(|e| !is_hidden(&e.file_name().to_string_lossy()))
        .filter_map(|e| entry(e.path()))
        .collect();
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| natural_cmp(&a.name, &b.name)));
    Ok(entries)
}

fn kind(path: &Path, meta: &Metadata) -> String {
    if is_bundle(path) {
        return "Application".into();
    }
    if meta.is_dir() {
        return "Folder".into();
    }
    match path.extension().and_then(|e| e.to_str()) {
        Some(ext) if !ext.is_empty() => format!("{} file", ext.to_uppercase()),
        _ => "File".into(),
    }
}

pub fn info(path: &Path) -> Result<Info> {
    let meta = metadata(path).ok_or_else(|| format!("{} not found", path.display()))?;
    let is_dir = meta.is_dir() && !is_bundle(path);
    let items = if is_dir {
        fs::read_dir(path)
            .ok()
            .map(|it| it.filter_map(|e| e.ok()).filter(|e| !is_hidden(&e.file_name().to_string_lossy())).count())
    } else {
        None
    };
    Ok(Info {
        name: name_of(path),
        path: path.to_string_lossy().into_owned(),
        kind: kind(path, &meta),
        is_dir,
        size: if is_dir { None } else { Some(meta.len()) },
        items,
        created: millis(meta.created()),
        modified: millis(meta.modified()),
    })
}

/// A single item name: not empty, no path separators.
fn valid_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err("Use a name without “/”.".into());
    }
    Ok(name)
}

/// Creates `parent/name` and returns its path. The name must be a single, new item.
pub fn create_folder(parent: &Path, name: &str) -> Result<PathBuf> {
    let name = valid_name(name)?;
    let path = parent.join(name);
    if path.exists() {
        return Err(format!("“{name}” already exists here."));
    }
    fs::create_dir(&path).map_err(err)?;
    Ok(path)
}

/// Renames an item in place; never overwrites another item.
pub fn rename(path: &Path, new_name: &str) -> Result<PathBuf> {
    let new_name = valid_name(new_name)?;
    let parent = path.parent().ok_or("Can't rename this item.")?;
    let target = parent.join(new_name);
    if target == path {
        return Ok(target);
    }
    // a case-only change ("photo" → "Photo") is the same item on macOS, so allow it
    let same_item = target.to_string_lossy().to_lowercase() == path.to_string_lossy().to_lowercase();
    if target.exists() && !same_item {
        return Err(format!("“{new_name}” already exists here."));
    }
    fs::rename(path, &target).map_err(err)?;
    Ok(target)
}

/// "name copy.ext", then "name copy 2.ext", … — like Finder.
fn copy_name(parent: &Path, path: &Path) -> PathBuf {
    let is_dir = path.is_dir() && !is_bundle(path);
    let (stem, ext) = match (path.file_stem(), path.extension()) {
        (Some(stem), Some(ext)) if !is_dir => (stem.to_string_lossy().into_owned(), format!(".{}", ext.to_string_lossy())),
        _ => (name_of(path), String::new()),
    };
    let mut n = 1;
    loop {
        let suffix = if n == 1 { " copy".to_string() } else { format!(" copy {n}") };
        let candidate = parent.join(format!("{stem}{suffix}{ext}"));
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
    }
}

fn copy_recursive(from: &Path, to: &Path) -> std::io::Result<()> {
    let meta = fs::symlink_metadata(from)?;
    if meta.file_type().is_symlink() {
        #[cfg(unix)]
        return std::os::unix::fs::symlink(fs::read_link(from)?, to);
    }
    if meta.is_dir() {
        fs::create_dir(to)?;
        for item in fs::read_dir(from)? {
            let item = item?;
            copy_recursive(&item.path(), &to.join(item.file_name()))?;
        }
        Ok(())
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

/// Copies a file or folder next to itself and returns the copy's path.
pub fn duplicate(path: &Path) -> Result<PathBuf> {
    let parent = path.parent().ok_or("Can't duplicate this item.")?;
    let target = copy_name(parent, path);
    copy_recursive(path, &target).map_err(err)?;
    Ok(target)
}

/// "name.zip", then "name 2.zip", … next to the item — like Finder's Compress.
fn zip_name(parent: &Path, path: &Path) -> PathBuf {
    let base = name_of(path);
    let mut n = 1;
    loop {
        let file = if n == 1 { format!("{base}.zip") } else { format!("{base} {n}.zip") };
        let candidate = parent.join(file);
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
    }
}

/// Zips a file or folder next to itself with macOS `ditto` (the tool Finder uses,
/// keeps resource forks and metadata) and returns the archive's path.
pub fn compress(path: &Path) -> Result<PathBuf> {
    let parent = path.parent().ok_or("Can't compress this item.")?;
    let target = zip_name(parent, path);
    let status = std::process::Command::new("ditto")
        .args(["-c", "-k", "--sequesterRsrc", "--keepParent"])
        .arg(path)
        .arg(&target)
        .status()
        .map_err(err)?;
    if !status.success() {
        let _ = fs::remove_file(&target);
        return Err("Couldn't compress this item.".into());
    }
    Ok(target)
}

/// Moves a file or folder to the system Trash (recoverable), never deletes outright.
pub fn move_to_trash(path: &Path) -> Result<()> {
    trash::delete(path).map_err(err)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("refile-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn natural_order() {
        let mut names = vec!["file10", "File2", "file1", "00 Documents", "10 Photo", "2 b"];
        names.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(names, vec!["00 Documents", "2 b", "10 Photo", "file1", "File2", "file10"]);
    }

    #[test]
    fn lists_folders_first_and_skips_hidden() {
        let dir = temp_dir("list");
        fs::write(dir.join("b.txt"), "hello").unwrap();
        fs::write(dir.join(".secret"), "").unwrap();
        fs::create_dir(dir.join("z folder")).unwrap();
        fs::create_dir(dir.join("Tool.app")).unwrap();

        let entries = list_dir(&dir).unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["z folder", "b.txt", "Tool.app"]);
        assert_eq!(entries[1].size, Some(5));
        assert!(entries[0].is_dir && entries[0].size.is_none());
        assert!(!entries[2].is_dir, "app bundles behave like files");

        let folder = info(&dir).unwrap();
        assert_eq!(folder.items, Some(3));
        assert_eq!(info(&dir.join("b.txt")).unwrap().kind, "TXT file");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rename_and_duplicate() {
        let dir = temp_dir("rename");
        fs::write(dir.join("note.txt"), "x").unwrap();
        fs::create_dir(dir.join("box")).unwrap();
        fs::write(dir.join("box/inner.md"), "y").unwrap();

        let renamed = rename(&dir.join("note.txt"), "letter.txt").unwrap();
        assert!(renamed.exists() && !dir.join("note.txt").exists());
        assert!(rename(&renamed, "box").is_err(), "never overwrites");
        assert!(rename(&renamed, "Letter.txt").is_ok(), "case-only rename is allowed");

        let first = duplicate(&dir.join("Letter.txt")).unwrap();
        let second = duplicate(&dir.join("Letter.txt")).unwrap();
        assert_eq!(name_of(&first), "Letter copy.txt");
        assert_eq!(name_of(&second), "Letter copy 2.txt");

        let folder_copy = duplicate(&dir.join("box")).unwrap();
        assert_eq!(name_of(&folder_copy), "box copy");
        assert_eq!(fs::read_to_string(folder_copy.join("inner.md")).unwrap(), "y");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn compress_names_archives_like_finder() {
        let dir = temp_dir("zip");
        fs::create_dir(dir.join("box")).unwrap();
        fs::write(dir.join("box/a.txt"), "hello").unwrap();

        let first = compress(&dir.join("box")).unwrap();
        let second = compress(&dir.join("box")).unwrap();
        assert_eq!(name_of(&first), "box.zip");
        assert_eq!(name_of(&second), "box 2.zip");
        assert!(fs::metadata(&first).unwrap().len() > 0);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn create_folder_validates_names() {
        let dir = temp_dir("create");
        let made = create_folder(&dir, "  New folder ").unwrap();
        assert!(made.is_dir() && made.ends_with("New folder"));
        assert!(create_folder(&dir, "New folder").is_err(), "no duplicates");
        assert!(create_folder(&dir, "a/b").is_err());
        assert!(create_folder(&dir, "  ").is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
