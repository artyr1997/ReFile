//! PLAY (what RePlay was): the music folder's songs kept in SQLite, the player (rodio), the radio
//! (radio.rs) and the Mac's media keys (media.rs). The Svelte side (src/lib/play/) talks to it through
//! these commands and the `player` / `scan` events. The library is RePlay's own, where RePlay kept it
//! (Application Support/com.artursavytskyi.resound), so the songs and the kept stations stay.

// RePlay's playlists and video checks stay in, unused for now
#[allow(dead_code)]
mod db;
#[cfg(target_os = "macos")]
pub mod media;
mod player;
mod radio;
#[allow(dead_code)]
mod scan;

use db::{Db, Track};
use player::{Audio, Queue, QueueItem, Repeat};
use radio::Station;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};

pub struct PlayState {
    db: Mutex<Db>,
    db_path: PathBuf,
    queue: Mutex<Queue>,
    pub audio: Audio,
    scanning: Mutex<bool>,
    radio: Mutex<Radio>,
}

/// The station on (instead of a song), and the list it was picked from: PREV / NEXT go along it.
#[derive(Default)]
struct Radio {
    station: Option<Station>,
    list: Vec<Station>,
}

type CmdResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Opens the library and the player; called once from setup.
pub fn setup(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let dir = dirs::data_dir().ok_or("no Application Support folder")?.join("com.artursavytskyi.resound");
    std::fs::create_dir_all(&dir)?;
    let db_path = dir.join("library.sqlite");
    let db = Db::open(&db_path)?;
    // first start: ~/Music
    if db.setting("folder")?.is_none() {
        if let Some(music) = dirs::audio_dir() {
            db.set_setting("folder", &music.to_string_lossy())?;
        }
    }
    // when a song ends by itself, the queue moves on from here
    let handle = app.handle().clone();
    let audio = Audio::spawn(move || {
        let state = handle.state::<PlayState>();
        let item = state.queue.lock().ok().and_then(|mut q| q.advance(true).cloned());
        play_current(&handle, item);
    });
    app.manage(PlayState {
        db: Mutex::new(db),
        db_path,
        queue: Mutex::new(Queue::default()),
        audio,
        scanning: Mutex::new(false),
        radio: Mutex::new(Radio::default()),
    });
    #[cfg(target_os = "macos")]
    media::listen(app.handle());
    Ok(())
}

/// Everything the player shows.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub track: Option<Track>,
    /// a station instead of a song
    pub station: Option<Station>,
    /// the song on air, as the station names it
    pub on_air: Option<String>,
    pub playing: bool,
    pub position_ms: u64,
    shuffle: bool,
    repeat: Repeat,
    error: Option<String>,
}

pub fn status(state: &PlayState) -> CmdResult<Status> {
    let audio = state.audio.status.lock().map_err(err)?.clone();
    let station = state.radio.lock().map_err(err)?.station.clone();
    let queue = state.queue.lock().map_err(err)?;
    let track = match queue.current() {
        Some(item) if station.is_none() => state.db.lock().map_err(err)?.track(item.id).ok(),
        _ => None,
    };
    Ok(Status {
        track,
        on_air: if station.is_some() { audio.on_air } else { None },
        station,
        playing: audio.playing,
        position_ms: audio.position_ms,
        shuffle: queue.shuffle,
        repeat: queue.repeat,
        error: audio.error,
    })
}

/// Starts whatever the queue now points at (or stops), and tells the windows.
fn play_current(app: &AppHandle, item: Option<QueueItem>) {
    let state = app.state::<PlayState>();
    // a song: the radio is off
    if let Ok(mut radio) = state.radio.lock() {
        radio.station = None;
    }
    match item {
        Some(item) => state.audio.load(item.path, true),
        None => state.audio.stop(),
    }
    // let the audio thread pick it up before reporting
    std::thread::sleep(Duration::from_millis(30));
    if let Ok(s) = status(&state) {
        let _ = app.emit("player", s);
    }
}

fn queue_items(state: &PlayState, ids: &[i64]) -> CmdResult<Vec<QueueItem>> {
    let db = state.db.lock().map_err(err)?;
    ids.iter().map(|&id| db.track(id).map(|t| QueueItem { id, path: PathBuf::from(t.path) })).collect()
}

/// The music of a folder opened in ReFile: `paths` (the folder's songs, in its order) become the queue,
/// starting at `start`; they join the library if they weren't in it.
#[tauri::command]
pub fn play_files(app: AppHandle, state: State<PlayState>, paths: Vec<String>, start: usize) -> CmdResult<()> {
    let paths: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    let ids = scan::add(&*state.db.lock().map_err(err)?, &paths)?;
    let items = queue_items(&state, &ids)?;
    let item = {
        let mut q = state.queue.lock().map_err(err)?;
        q.set(items, start.min(ids.len().saturating_sub(1)));
        q.current().cloned()
    };
    play_current(&app, item);
    // the library may have new songs
    let _ = app.emit("scan", serde_json::json!({ "finished": true }));
    Ok(())
}

/// A video starts: the music pauses.
#[tauri::command]
pub fn pause_music(state: State<PlayState>) {
    if state.audio.status.lock().is_ok_and(|s| s.playing) {
        state.audio.pause();
    }
}

// ── library ──

#[tauri::command]
pub fn music_folder(state: State<PlayState>) -> CmdResult<Option<String>> {
    state.db.lock().map_err(err)?.setting("folder")
}

#[tauri::command]
pub fn set_music_folder(app: AppHandle, state: State<PlayState>, folder: String) -> CmdResult<()> {
    state.db.lock().map_err(err)?.set_setting("folder", &folder)?;
    rescan(app, state)
}

/// Scans the music folder in the background; progress and the end come as `scan` events.
#[tauri::command]
pub fn rescan(app: AppHandle, state: State<PlayState>) -> CmdResult<()> {
    let Some(folder) = state.db.lock().map_err(err)?.setting("folder")? else {
        return Err("Choose a music folder first.".into());
    };
    {
        let mut busy = state.scanning.lock().map_err(err)?;
        if *busy {
            return Ok(());
        }
        *busy = true;
    }
    let db_path = state.db_path.clone();
    std::thread::spawn(move || {
        // a connection of its own, so the library stays usable while scanning
        let result = Db::open(&db_path).and_then(|db| {
            scan::scan(&db, &PathBuf::from(&folder), |done, total| {
                let _ = app.emit("scan", serde_json::json!({ "done": done, "total": total, "finished": false }));
            })
        });
        if let Ok(mut busy) = app.state::<PlayState>().scanning.lock() {
            *busy = false;
        }
        let payload = match result {
            Ok(r) => serde_json::json!({ "finished": true, "result": r }),
            Err(e) => serde_json::json!({ "finished": true, "error": e }),
        };
        let _ = app.emit("scan", payload);
    });
    Ok(())
}

#[tauri::command]
pub fn tracks(state: State<PlayState>) -> CmdResult<Vec<Track>> {
    state.db.lock().map_err(err)?.tracks()
}

// ── playback ──

/// Plays `track_ids` as the new queue, starting at `start`.
#[tauri::command]
pub fn play(app: AppHandle, state: State<PlayState>, track_ids: Vec<i64>, start: usize) -> CmdResult<()> {
    let items = queue_items(&state, &track_ids)?;
    let item = {
        let mut q = state.queue.lock().map_err(err)?;
        q.set(items, start);
        q.current().cloned()
    };
    play_current(&app, item);
    Ok(())
}

#[tauri::command]
pub fn toggle_play(app: AppHandle, state: State<PlayState>) -> CmdResult<()> {
    let audio = state.audio.status.lock().map_err(err)?.clone();
    if state.radio.lock().map_err(err)?.station.is_some() {
        // a station: off, or tuned in again
        if audio.playing { state.audio.pause() } else { state.audio.play() }
        return Ok(());
    }
    if audio.playing {
        state.audio.pause();
    } else if audio.position_ms == 0 && !state.queue.lock().map_err(err)?.is_empty() {
        // stopped at the end (or never started): start the current song again
        let item = state.queue.lock().map_err(err)?.current().cloned();
        play_current(&app, item);
        return Ok(());
    } else {
        state.audio.play();
    }
    Ok(())
}

#[tauri::command]
pub fn next(app: AppHandle, state: State<PlayState>) -> CmdResult<()> {
    if state.radio.lock().map_err(err)?.station.is_some() {
        return turn_dial(&app, &state, 1);
    }
    let item = state.queue.lock().map_err(err)?.advance(false).cloned();
    if item.is_some() {
        play_current(&app, item);
    }
    Ok(())
}

/// Like Music: more than 3 s in → back to the start of the song, otherwise the previous one.
#[tauri::command]
pub fn previous(app: AppHandle, state: State<PlayState>) -> CmdResult<()> {
    if state.radio.lock().map_err(err)?.station.is_some() {
        return turn_dial(&app, &state, -1);
    }
    let position = state.audio.status.lock().map_err(err)?.position_ms;
    if position > 3000 {
        state.audio.seek(Duration::ZERO);
        return Ok(());
    }
    let item = state.queue.lock().map_err(err)?.back().cloned();
    play_current(&app, item);
    Ok(())
}

#[tauri::command]
pub fn seek(state: State<PlayState>, position_ms: u64) -> CmdResult<()> {
    state.audio.seek(Duration::from_millis(position_ms));
    Ok(())
}

#[tauri::command]
pub fn set_shuffle(state: State<PlayState>, on: bool) -> CmdResult<()> {
    state.queue.lock().map_err(err)?.set_shuffle(on);
    Ok(())
}

#[tauri::command]
pub fn cycle_repeat(state: State<PlayState>) -> CmdResult<Repeat> {
    Ok(state.queue.lock().map_err(err)?.cycle_repeat())
}

#[tauri::command]
pub fn play_next(state: State<PlayState>, track_ids: Vec<i64>) -> CmdResult<()> {
    let items = queue_items(&state, &track_ids)?;
    state.queue.lock().map_err(err)?.play_next(items);
    Ok(())
}

#[tauri::command]
pub fn add_to_queue(state: State<PlayState>, track_ids: Vec<i64>) -> CmdResult<()> {
    let items = queue_items(&state, &track_ids)?;
    state.queue.lock().map_err(err)?.append(items);
    Ok(())
}

/// Songs (by their files) put next, or at the end of the queue: from a folder, they join the library first.
#[tauri::command]
pub fn queue_files(state: State<PlayState>, paths: Vec<String>, next: bool) -> CmdResult<()> {
    let paths: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    let ids = scan::add(&*state.db.lock().map_err(err)?, &paths)?;
    let items = queue_items(&state, &ids)?;
    let mut queue = state.queue.lock().map_err(err)?;
    if next { queue.play_next(items) } else { queue.append(items) }
    Ok(())
}

#[tauri::command]
pub fn player_status(state: State<PlayState>) -> CmdResult<Status> {
    status(&state)
}

/// The songs still to come, in play order.
#[tauri::command]
pub fn upcoming(state: State<PlayState>) -> CmdResult<Vec<Track>> {
    let ids = state.queue.lock().map_err(err)?.upcoming();
    let db = state.db.lock().map_err(err)?;
    Ok(ids.into_iter().filter_map(|id| db.track(id).ok()).collect())
}

// ── radio ──

#[tauri::command]
pub fn radio_genres() -> Vec<&'static str> {
    radio::GENRES.iter().map(|g| g.name).collect()
}

/// A genre's stations (asked of Radio Browser, off the main thread).
#[tauri::command]
pub async fn radio_stations(genre: String) -> CmdResult<Vec<Station>> {
    tauri::async_runtime::spawn_blocking(move || radio::stations(&genre)).await.map_err(err)?
}

#[tauri::command]
pub async fn radio_search(query: String) -> CmdResult<Vec<Station>> {
    tauri::async_runtime::spawn_blocking(move || radio::search(&query)).await.map_err(err)?
}

fn favorites(db: &Db) -> Vec<Station> {
    db.setting("radio_favorites").ok().flatten().and_then(|json| serde_json::from_str(&json).ok()).unwrap_or_default()
}

/// The stations kept (newest first), here in the library: there without the network too.
#[tauri::command]
pub fn radio_favorites(state: State<PlayState>) -> CmdResult<Vec<Station>> {
    let db = state.db.lock().map_err(err)?;
    Ok(favorites(&db))
}

#[tauri::command]
pub fn set_radio_favorite(state: State<PlayState>, station: Station, on: bool) -> CmdResult<()> {
    let db = state.db.lock().map_err(err)?;
    let mut kept: Vec<Station> = favorites(&db).into_iter().filter(|s| s.uuid != station.uuid).collect();
    if on {
        kept.insert(0, station);
    }
    db.set_setting("radio_favorites", &serde_json::to_string(&kept).map_err(err)?)
}

/// Plays `station`; `list` is where it was picked from, for PREV / NEXT.
#[tauri::command]
pub fn play_station(app: AppHandle, state: State<PlayState>, station: Station, list: Vec<Station>) -> CmdResult<()> {
    tune_in(&app, &state, station, Some(list))
}

fn tune_in(app: &AppHandle, state: &PlayState, station: Station, list: Option<Vec<Station>>) -> CmdResult<()> {
    radio::count_click(&station.uuid);
    state.audio.stream(station.url.clone());
    {
        let mut radio = state.radio.lock().map_err(err)?;
        if let Some(list) = list {
            radio.list = list;
        }
        radio.station = Some(station);
    }
    std::thread::sleep(Duration::from_millis(30));
    if let Ok(s) = status(state) {
        let _ = app.emit("player", s);
    }
    Ok(())
}

/// PREV / NEXT on the radio: the station before or after this one in its list.
fn turn_dial(app: &AppHandle, state: &PlayState, step: isize) -> CmdResult<()> {
    let next = {
        let radio = state.radio.lock().map_err(err)?;
        let Some(on) = &radio.station else { return Ok(()) };
        let count = radio.list.len() as isize;
        if count == 0 {
            return Ok(());
        }
        let at = radio.list.iter().position(|s| s.uuid == on.uuid).map(|i| i as isize).unwrap_or(-step.min(0));
        radio.list[((at + step) % count + count) as usize % count as usize].clone()
    };
    tune_in(app, state, next, None)
}
