//! Where the person was on the phone, so a launch opens there: the workspace, the screen in it
//! (chat or terminal, and which one), the scroll anchor and the selection.
//!
//! One small JSON file, written whole (temp file, then rename) and read whole. The app reads it
//! synchronously on launch, before its first frame, and checks it against the workspaces it has
//! cached; nothing here waits on the network. A place whose workspace is not in the cache opens
//! the list, as does a missing, corrupt, oversized or newer-version file.
//!
//! Saving is debounced here, not in Swift: the app reports every change with [`Store::note`]
//! and its own monotonic clock, and calls [`Store::tick`] when the returned deadline passes and
//! [`Store::flush`] when it goes to the background. A scroll reports many changes a second; the
//! file is written at most once per quiet period, and at least once per `max_wait` while the
//! changes keep coming.

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file's format version. A file with another version reads as nothing.
pub const VERSION: u32 = 1;

/// A file larger than this is not read (the record is a few hundred bytes).
pub const MAX_FILE_BYTES: u64 = 64 * 1024;

/// Which screen of the workspace was open.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Screen {
    Chat,
    Terminal,
}

/// The row at the top of the visible part of a scrolled list, and how far past its top edge
/// the list was scrolled, in points. `row` is the list's own stable row id (a message id, a
/// transcript sequence number, a terminal row), never an index.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScrollAnchor {
    pub row: String,
    pub offset: f64,
}

/// Where the person was.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LastPlace {
    /// The workspace's id, as the cached workspace list names it.
    pub workspace: String,
    /// The screen open in it; `None` is the workspace's own default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen: Option<Screen>,
    /// The chat or terminal (tab) open in that screen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    /// The scroll anchor of that screen; `None` is its default (the bottom of a chat or
    /// terminal, following new output).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll: Option<ScrollAnchor>,
    /// The selected row or tab in that screen, by its id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct File {
    v: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    place: Option<LastPlace>,
}

/// What reading the file found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadOutcome {
    /// A place, or a file saying the person was on the list.
    Read,
    /// No file: a first launch.
    Missing,
    /// Not JSON, not this shape, or an empty workspace id.
    Corrupt,
    /// Written by a newer app.
    OtherVersion,
    /// Larger than [`MAX_FILE_BYTES`].
    TooLarge,
    /// The file is there and could not be read (an I/O error, or data protection before the
    /// first unlock).
    Unreadable,
}

/// Reads the file at `path`. Never fails: anything but a good file is no place.
pub fn read(path: &Path) -> (Option<LastPlace>, ReadOutcome) {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return (None, ReadOutcome::Missing),
        Err(_) => return (None, ReadOutcome::Unreadable),
    };
    let mut bytes = Vec::new();
    match file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes) {
        Ok(_) if bytes.len() as u64 > MAX_FILE_BYTES => return (None, ReadOutcome::TooLarge),
        Ok(_) => {}
        Err(_) => return (None, ReadOutcome::Unreadable),
    }
    decode(&bytes)
}

fn decode(bytes: &[u8]) -> (Option<LastPlace>, ReadOutcome) {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return (None, ReadOutcome::Corrupt);
    };
    match value.get("v").and_then(serde_json::Value::as_u64) {
        Some(v) if v == u64::from(VERSION) => {}
        Some(_) => return (None, ReadOutcome::OtherVersion),
        None => return (None, ReadOutcome::Corrupt),
    }
    let Ok(file) = serde_json::from_value::<File>(value) else {
        return (None, ReadOutcome::Corrupt);
    };
    match file.place {
        Some(place) if place.workspace.is_empty() => (None, ReadOutcome::Corrupt),
        place => (place.map(normalized), ReadOutcome::Read),
    }
}

/// A non-finite offset (never written by this crate, but a hand-edited or damaged file can hold
/// one in a valid shape) drops the anchor; empty ids are no ids.
fn normalized(mut place: LastPlace) -> LastPlace {
    if place.item.as_deref() == Some("") {
        place.item = None;
    }
    if place.selection.as_deref() == Some("") {
        place.selection = None;
    }
    if let Some(scroll) = &place.scroll
        && (scroll.row.is_empty() || !scroll.offset.is_finite())
    {
        place.scroll = None;
    }
    place
}

/// Writes `place` to `path` whole: a temp file beside it, then a rename, so a crash mid-write
/// leaves the old file or the new one, never half of one.
pub fn write(path: &Path, place: Option<&LastPlace>) -> io::Result<()> {
    let body = serde_json::to_vec(&File { v: VERSION, place: place.cloned().map(normalized) })
        .map_err(io::Error::other)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = tmp_path(path);
    fs::write(&tmp, body)?;
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}

/// Where a launch opens.
#[derive(Debug, Clone, PartialEq)]
pub enum Restore {
    /// The workspace list.
    List,
    /// The saved place, checked against the cache.
    Place(LastPlace),
}

/// Checks `place` against the cache: `workspaces` are the ids of the cached workspace list, and
/// `items`, when the cache knows them, the chat and terminal ids of the saved workspace.
///
/// A workspace not in the cache (closed, or another account's) opens the list. An empty cache
/// opens the list too: with nothing to check against, a stale place must not open a screen that
/// then disappears. An item not in `items` keeps the workspace and drops the item, its scroll
/// anchor and selection, which belonged to that item.
pub fn resolve(
    place: Option<&LastPlace>,
    workspaces: &[String],
    items: Option<&[String]>,
) -> Restore {
    let Some(place) = place else {
        return Restore::List;
    };
    if !workspaces.contains(&place.workspace) {
        return Restore::List;
    }
    let mut place = place.clone();
    if let (Some(item), Some(items)) = (place.item.as_deref(), items)
        && !items.iter().any(|id| id == item)
    {
        place.item = None;
        place.scroll = None;
        place.selection = None;
    }
    Restore::Place(place)
}

/// What [`Store::note`] and [`Store::tick`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Note {
    /// Nothing to write: the change matches what is on disk.
    Unchanged,
    /// Written now.
    Written,
    /// Waiting for a quiet period: call [`Store::tick`] at `at_ms` (or [`Store::flush`]).
    Due { at_ms: u64 },
    /// The write failed; the change stays pending and the next tick or flush tries again.
    Failed { at_ms: u64 },
}

struct Pending {
    place: Option<LastPlace>,
    /// When the oldest unsaved change came.
    since_ms: u64,
    /// When the newest came.
    last_ms: u64,
}

/// The saved place and the debounce of its writes. Time is the app's own monotonic clock in
/// milliseconds, from any origin, never going back.
pub struct Store {
    path: PathBuf,
    quiet_ms: u64,
    max_wait_ms: u64,
    /// What the file holds (or held at open).
    saved: Option<LastPlace>,
    /// What the file held at open: the launch's place, kept for the screen that opens late (a
    /// chat whose transcript comes after the app moved on through its first screens).
    launch: Option<LastPlace>,
    read_outcome: ReadOutcome,
    pending: Option<Pending>,
}

impl Store {
    /// Reads the file at `path` now (the launch read) and keeps its place. `quiet_ms`: how long
    /// changes must stop before a write; `max_wait_ms`: the longest a change waits while
    /// changes keep coming.
    pub fn open(path: PathBuf, quiet_ms: u64, max_wait_ms: u64) -> Self {
        let (saved, read_outcome) = read(&path);
        Self {
            path,
            quiet_ms,
            max_wait_ms: max_wait_ms.max(quiet_ms),
            launch: saved.clone(),
            saved,
            read_outcome,
            pending: None,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// What the launch read found.
    pub fn read_outcome(&self) -> ReadOutcome {
        self.read_outcome
    }

    /// The place on disk when the store opened, or the latest one written since.
    pub fn saved(&self) -> Option<&LastPlace> {
        self.saved.as_ref()
    }

    /// The latest place, saved or not.
    pub fn latest(&self) -> Option<&LastPlace> {
        match &self.pending {
            Some(pending) => pending.place.as_ref(),
            None => self.saved.as_ref(),
        }
    }

    /// Where a launch opens: the saved place checked against the cache (see [`resolve`]).
    pub fn restore(&self, workspaces: &[String], items: Option<&[String]>) -> Restore {
        resolve(self.saved.as_ref(), workspaces, items)
    }

    /// The person moved: `workspace` (`None`: the list), its `screen` and its `item` (the tab),
    /// which is also the selection. The scroll anchor is kept when the item is the same one, as
    /// the latest place or the launch's place has it; another item starts at its default.
    pub fn note_location(
        &mut self,
        workspace: Option<String>,
        screen: Option<Screen>,
        item: Option<String>,
        now_ms: u64,
    ) -> Note {
        let Some(workspace) = workspace.filter(|id| !id.is_empty()) else {
            return self.note(None, now_ms);
        };
        let item = item.filter(|id| !id.is_empty());
        let scroll = self.anchor_of(&workspace, item.as_deref()).cloned();
        self.note(
            Some(LastPlace { workspace, screen, selection: item.clone(), item, scroll }),
            now_ms,
        )
    }

    /// The reader of `item` in `workspace` came to rest at `anchor` (`None`: on the newest row,
    /// following). Kept only when that item is where the person is: a chat scrolled elsewhere
    /// (a card on the tab grid) is not their place.
    pub fn note_scroll(
        &mut self,
        workspace: &str,
        item: &str,
        anchor: Option<ScrollAnchor>,
        now_ms: u64,
    ) -> Note {
        let Some(mut place) = self.latest().cloned() else {
            return Note::Unchanged;
        };
        if place.workspace != workspace || place.item.as_deref() != Some(item) {
            return Note::Unchanged;
        }
        place.scroll = anchor;
        self.note(Some(place), now_ms)
    }

    /// Where `item` of `workspace` was scrolled, from the latest place, else the launch's: read
    /// when its screen first lays out its cached rows.
    pub fn scroll_for(&self, workspace: &str, item: &str) -> Option<&ScrollAnchor> {
        self.anchor_of(workspace, Some(item))
    }

    fn anchor_of(&self, workspace: &str, item: Option<&str>) -> Option<&ScrollAnchor> {
        let item = item?;
        let matches = |place: &&LastPlace| {
            place.workspace == workspace && place.item.as_deref() == Some(item)
        };
        match self.latest().filter(matches) {
            Some(latest) => latest.scroll.as_ref(),
            None => self.launch.as_ref().filter(matches).and_then(|place| place.scroll.as_ref()),
        }
    }

    /// The person is now at `place` (`None`: the workspace list).
    pub fn note(&mut self, place: Option<LastPlace>, now_ms: u64) -> Note {
        let place = place.map(normalized).filter(|place| !place.workspace.is_empty());
        if self.pending.is_none() && place == self.saved {
            return Note::Unchanged;
        }
        if let Some(pending) = &self.pending
            && pending.place == place
        {
            return self.tick(now_ms);
        }
        if place == self.saved {
            // Back to what is on disk before the write: nothing left to save.
            self.pending = None;
            return Note::Unchanged;
        }
        let since_ms = self.pending.as_ref().map_or(now_ms, |pending| pending.since_ms);
        self.pending = Some(Pending { place, since_ms, last_ms: now_ms });
        self.tick(now_ms)
    }

    /// Writes the pending change if its quiet period or its longest wait has passed.
    pub fn tick(&mut self, now_ms: u64) -> Note {
        let Some(pending) = &self.pending else {
            return Note::Unchanged;
        };
        let due_ms = (pending.last_ms.saturating_add(self.quiet_ms))
            .min(pending.since_ms.saturating_add(self.max_wait_ms));
        if now_ms < due_ms {
            return Note::Due { at_ms: due_ms };
        }
        match self.write_pending() {
            Ok(true) => Note::Written,
            Ok(false) => Note::Unchanged,
            Err(_) => Note::Failed { at_ms: now_ms.saturating_add(self.quiet_ms) },
        }
    }

    /// Writes the pending change now (the app is going to the background). Returns whether
    /// anything was written.
    pub fn flush(&mut self) -> io::Result<bool> {
        self.write_pending()
    }

    fn write_pending(&mut self) -> io::Result<bool> {
        let Some(pending) = self.pending.take() else {
            return Ok(false);
        };
        match write(&self.path, pending.place.as_ref()) {
            Ok(()) => {
                self.saved = pending.place;
                self.read_outcome = ReadOutcome::Read;
                Ok(true)
            }
            Err(err) => {
                self.pending = Some(pending);
                Err(err)
            }
        }
    }
}

#[cfg(test)]
mod tests;
