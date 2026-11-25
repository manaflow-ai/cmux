//! `open {live}`: a file the browser tab renders (a page, an SVG, a PDF, an image) reloads
//! in its tab when the file changes, so a deck or a page the agent keeps writing stays
//! current beside the chat without another `open`.
//!
//! One `notify` watcher on each file's folder (an atomic rename-replace or a
//! delete-then-recreate is seen there, never on the old inode) and one thread for the life
//! of this server. A burst of writes is one reload: the reload goes out once the file has
//! been quiet for [`QUIET`]. A deleted file reloads into Chromium's own "file not found"
//! page, which says so; a recreated one reloads again. A reload that answers
//! `selector.not_found` (the person closed the tab) ends that watch. At most
//! [`MAX_WATCHES`] files are watched; a newer one drops the oldest.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use notify::Watcher as _;
use notify::event::{EventKind, MetadataKind, ModifyKind};
use serde_json::{Map, Value, json};

use super::super::command::RequestPlan;
use super::{CallFailure, v2_tools};

/// Sends one daemon request from the watch thread (`Backend::resource_sender`).
pub(super) type Sender = Arc<dyn Fn(RequestPlan) -> Result<Value, CallFailure> + Send + Sync>;

pub(super) const MAX_WATCHES: usize = 16;
pub(super) const QUIET: Duration = Duration::from_millis(150);

/// Whether `open` watches a file by default: one the browser tab renders.
pub(super) fn renders_in_browser(path: &str) -> bool {
    let extension = Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    matches!(
        extension.as_str(),
        "html"
            | "htm"
            | "xhtml"
            | "svg"
            | "pdf"
            | "png"
            | "jpg"
            | "jpeg"
            | "gif"
            | "webp"
            | "avif"
            | "bmp"
            | "ico"
    )
}

/// A watched file and the browser that shows it.
struct Entry {
    path: PathBuf,
    browser: String,
}

type Entries = Arc<Mutex<VecDeque<Entry>>>;

/// The watches of this server, and the thread that reloads.
pub(super) struct Watches {
    entries: Entries,
    watcher: notify::RecommendedWatcher,
    /// Watched folders, with how many entries use each.
    folders: HashMap<PathBuf, usize>,
}

impl Watches {
    /// Starts the watcher and its thread; dropping `Watches` ends the thread.
    pub(super) fn start(send: Sender) -> Result<Self, String> {
        let (events, received) = mpsc::channel();
        let watcher = notify::recommended_watcher(move |event| {
            let _ = events.send(event);
        })
        .map_err(|error| format!("cannot watch files: {error}"))?;
        let entries = Entries::default();
        let shared = entries.clone();
        std::thread::Builder::new()
            .name("cmux-mcp-live-file".into())
            .spawn(move || reload_loop(&received, &shared, &send))
            .map_err(|error| format!("cannot start the file watch: {error}"))?;
        Ok(Self { entries, watcher, folders: HashMap::new() })
    }

    /// Watches `path` for `browser`, dropping the oldest watch past [`MAX_WATCHES`].
    pub(super) fn add(&mut self, path: &str, browser: &str) -> Result<(), String> {
        let path = Path::new(path);
        let (Some(folder), Some(name)) = (path.parent(), path.file_name()) else {
            return Err(format!("{} has no folder to watch", path.display()));
        };
        // Events name the folder as the file system sees it (macOS: /private/tmp).
        let folder = folder.canonicalize().unwrap_or_else(|_| folder.to_path_buf());
        let path = folder.join(name);
        if !self.folders.contains_key(&folder) {
            self.watcher
                .watch(&folder, notify::RecursiveMode::NonRecursive)
                .map_err(|error| format!("cannot watch {}: {error}", folder.display()))?;
        }
        *self.folders.entry(folder).or_default() += 1;
        let dropped = {
            let mut entries = self.entries.lock().map_err(|_| "file watch lock".to_owned())?;
            // The same file in the same browser again: one watch, now the newest.
            let mut dropped = Vec::new();
            if let Some(at) =
                entries.iter().position(|entry| entry.path == path && entry.browser == browser)
            {
                dropped.extend(entries.remove(at));
            }
            entries.push_back(Entry { path, browser: browser.to_owned() });
            let excess = entries.len().saturating_sub(MAX_WATCHES);
            dropped.extend(entries.drain(..excess));
            dropped
        };
        for entry in dropped {
            self.release(&entry.path);
        }
        Ok(())
    }

    fn release(&mut self, path: &Path) {
        let Some(folder) = path.parent() else { return };
        let Some(count) = self.folders.get_mut(folder) else { return };
        *count -= 1;
        if *count == 0 {
            self.folders.remove(folder);
            let _ = self.watcher.unwatch(folder);
        }
    }

    #[cfg(test)]
    pub(super) fn watched(&self) -> Vec<(PathBuf, String)> {
        let entries = self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.iter().map(|entry| (entry.path.clone(), entry.browser.clone())).collect()
    }
}

/// Whether an event may have changed what the file shows: not a read (the reload itself
/// opens the file) and not an access-time update.
fn changes(kind: &EventKind) -> bool {
    !matches!(
        kind,
        EventKind::Access(_) | EventKind::Modify(ModifyKind::Metadata(MetadataKind::AccessTime))
    )
}

/// Blocks on the watcher's events; once a changed file is quiet for [`QUIET`], reloads
/// each browser that shows it.
fn reload_loop(
    received: &mpsc::Receiver<notify::Result<notify::Event>>,
    entries: &Entries,
    send: &Sender,
) {
    let mut due: HashMap<PathBuf, Instant> = HashMap::new();
    loop {
        let event = match due.values().min() {
            None => received.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
            Some(at) => received.recv_timeout(at.saturating_duration_since(Instant::now())),
        };
        match event {
            Ok(Ok(event)) if changes(&event.kind) => {
                let Ok(watched) = entries.lock() else { return };
                for path in event.paths {
                    if watched.iter().any(|entry| entry.path == path) {
                        due.insert(path, Instant::now() + QUIET);
                    }
                }
            }
            Ok(_) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        let now = Instant::now();
        let ready: Vec<PathBuf> =
            due.iter().filter(|(_, at)| **at <= now).map(|(path, _)| path.clone()).collect();
        for path in ready {
            due.remove(&path);
            let browsers: Vec<String> = match entries.lock() {
                Ok(watched) => watched
                    .iter()
                    .filter(|entry| entry.path == path)
                    .map(|entry| entry.browser.clone())
                    .collect(),
                Err(_) => return,
            };
            for browser in browsers {
                if reload(send, &browser) == Reload::Gone
                    && let Ok(mut watched) = entries.lock()
                {
                    watched.retain(|entry| entry.browser != browser);
                }
            }
        }
    }
}

#[derive(PartialEq)]
enum Reload {
    Sent,
    Gone,
}

/// One `browser.reload` for `browser`.
fn reload(send: &Sender, browser: &str) -> Reload {
    let Some(tool) = v2_tools::find("browser_reload") else { return Reload::Gone };
    let mut arguments = Map::new();
    arguments.insert("browser".into(), json!(browser));
    if let Ok(key) = super::super::wire::random_idempotency_key() {
        arguments.insert("idempotency_key".into(), json!(key));
    }
    let Ok(call) = tool.plan(&arguments) else { return Reload::Gone };
    match send(call.plan) {
        Err(failure)
            if failure.error.get("code").and_then(Value::as_str) == Some("selector.not_found") =>
        {
            Reload::Gone
        }
        _ => Reload::Sent,
    }
}
