//! Frees a projection's state folder on the machine (its upper layer, whiteouts, record and cache,
//! [`crate::state`]) once nothing can need it again (RFD 0007, hard case 8). One [`pass`] runs at
//! the daemon's start and on a timer, does a bounded amount of work ([`Limits`]) and says what it
//! freed and why ([`Report`]). Each projection's cache is capped on its own
//! (`overlay::DEFAULT_CACHE_MAX_BYTES`), and its content store keeps a floor of free disk
//! (`overlay::content::DEFAULT_CONTENT_FLOOR`).
//!
//! What goes, and the one rule that keeps edits safe:
//!
//! - a projection **brought back** whose upper layer is still as Bring Back read it
//!   ([`state::BroughtBack`]): its edits are on the Mac;
//! - a projection of a chat that is **archived or deleted**: released by the Mac
//!   ([`state::Released`]), or every chat on this machine whose folder is in it archived;
//! - an **orphan**: no chat on this machine names it, and it is older than the grace
//!   ([`ORPHAN_GRACE`]): the chat was deleted, or never started.
//!
//! A live chat's upper layer whose edits were never brought back is never freed. Whether a chat
//! is live comes from the machine's chat list ([`Chats`]); a list that could not be read whole,
//! or holds no chat at all, frees nothing by it (only brought-back and released projections go).

use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::state::{self, Release};

/// How long state no chat names stays before it is an orphan.
pub const ORPHAN_GRACE: Duration = Duration::from_secs(14 * 24 * 60 * 60);
/// The most folders one pass frees; the rest wait for the next pass.
pub const MAX_RECLAIMS: usize = 16;
/// The most projection folders one pass reads.
pub const MAX_SCAN: usize = 4096;

/// One chat on this machine, as its chat list has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    pub id: String,
    /// The folder it runs in.
    pub folder: Option<PathBuf>,
    pub archived: bool,
}

/// The machine's chats.
#[derive(Clone, Debug, Default)]
pub struct Chats {
    pub rows: Vec<Chat>,
    /// The list was read whole. A partial or failed read says nothing about which chats are gone.
    pub complete: bool,
}

/// How the chats use a folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Use {
    /// A chat that is not archived runs in it (or below it).
    Live,
    /// Chats run in it, all archived.
    Archived,
    /// No chat names it.
    Unnamed,
}

impl Chats {
    /// A list that was not read: it frees nothing by itself.
    #[must_use]
    pub fn unread() -> Self {
        Self::default()
    }

    /// Whether the list can say a chat is gone: read whole, and not empty (an empty list on a
    /// machine with chat state is a new or broken chat service, not a machine with no chats).
    fn knows(&self) -> bool {
        self.complete && !self.rows.is_empty()
    }

    fn fold<'a>(rows: impl Iterator<Item = &'a Chat>) -> Use {
        let mut seen = false;
        for chat in rows {
            if !chat.archived {
                return Use::Live;
            }
            seen = true;
        }
        if seen { Use::Archived } else { Use::Unnamed }
    }

    fn of_folder(&self, folder: &Path) -> Use {
        Self::fold(self.rows.iter().filter(|chat| {
            chat.folder.as_deref().is_some_and(|runs_in| runs_in.starts_with(folder))
        }))
    }
}

/// Where this machine keeps per-chat state.
#[derive(Clone, Debug, Default)]
pub struct Places {
    /// The daemon's `projections/` folder: a state folder per projection name.
    pub projections: Option<PathBuf>,
}

/// A pass's bounds.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub orphan_grace: Duration,
    pub max_reclaims: usize,
    pub max_scan: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self { orphan_grace: ORPHAN_GRACE, max_reclaims: MAX_RECLAIMS, max_scan: MAX_SCAN }
    }
}

/// Why something was freed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    BroughtBack,
    Archived,
    Deleted,
    Orphan,
}

impl Why {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BroughtBack => "brought back",
            Self::Archived => "chat archived",
            Self::Deleted => "chat deleted",
            Self::Orphan => "orphan",
        }
    }
}

impl From<Release> for Why {
    fn from(release: Release) -> Self {
        match release {
            Release::Archived => Self::Archived,
            Release::Deleted => Self::Deleted,
        }
    }
}

/// One thing a pass freed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reclaim {
    pub path: PathBuf,
    pub why: Why,
    pub bytes: u64,
}

/// What a pass did.
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub reclaimed: Vec<Reclaim>,
    /// Folders due to go that the pass's bound left for the next one.
    pub deferred: usize,
    /// Folders due to go that could not be removed, and why.
    pub failed: Vec<(PathBuf, String)>,
}

impl Report {
    /// The bytes the pass freed.
    #[must_use]
    pub fn bytes(&self) -> u64 {
        self.reclaimed.iter().map(|reclaim| reclaim.bytes).sum()
    }
}

/// The daemon's live projections, so a pass never pulls state out from under a mount.
pub trait Live {
    /// Whether this daemon serves projection `name` now.
    fn mounted(&self, name: &str) -> bool;
    /// Ends projection `name` (this daemon's mount of it, or a dead daemon's mount left at `at`)
    /// with new mounts of it held off, then runs `free` and answers what it did. `None`, and
    /// `free` not run, when `only_if_idle` and this daemon serves it now.
    fn end(
        &self,
        name: &str,
        at: Option<&Path>,
        only_if_idle: bool,
        free: &mut dyn FnMut() -> io::Result<u64>,
    ) -> Option<io::Result<u64>>;
}

/// No live projections (tests, and a machine whose daemon mounts none).
pub struct Idle;

impl Live for Idle {
    fn mounted(&self, _name: &str) -> bool {
        false
    }

    fn end(
        &self,
        _name: &str,
        _at: Option<&Path>,
        _only_if_idle: bool,
        free: &mut dyn FnMut() -> io::Result<u64>,
    ) -> Option<io::Result<u64>> {
        Some(free())
    }
}

/// Whether projection state folder `state` may go, and why. `mounted`: this daemon serves it now.
#[must_use]
pub fn verdict(
    state: &Path,
    chats: &Chats,
    mounted: bool,
    now: SystemTime,
    grace: Duration,
) -> Option<Why> {
    let record = state::read(state);
    if let Some(record) = &record {
        if let Some(released) = &record.released {
            return Some(released.why.into());
        }
        if let Some(back) = &record.brought_back
            && state::mark(state).is_ok_and(|mark| mark == back.mark)
        {
            return Some(Why::BroughtBack);
        }
    }
    if !chats.knows() {
        return None;
    }
    match record.as_ref().map(|record| chats.of_folder(&record.at)) {
        Some(Use::Live) => None,
        Some(Use::Archived) => Some(Why::Archived),
        Some(Use::Unnamed) | None => {
            if mounted {
                return None;
            }
            let since = record
                .as_ref()
                .map(|record| record.attached_ms.max(record.created_ms))
                .filter(|ms| *ms > 0)
                .or_else(|| modified_ms(state));
            older_than(since, now, grace).then_some(Why::Orphan)
        }
    }
}

/// Frees projection state folder `state` (mounted at `at`) for `why`: the whole folder, and for a
/// chat that is gone the empty mount point too (Bring Back keeps it: the chat may go on there).
/// Answers the bytes freed.
///
/// # Errors
/// When the folder cannot be removed.
pub fn free_projection(state: &Path, at: Option<&Path>, why: Why) -> io::Result<u64> {
    let bytes = match remove_tree(state) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
        other => other?,
    };
    if why != Why::BroughtBack
        && let Some(at) = at
    {
        // Only an empty folder: a mount still there, or anything put in it, stays.
        let _ = fs::remove_dir(at);
    }
    Ok(bytes)
}

/// One pass over `places`: frees what may go, at most [`Limits::max_reclaims`] folders.
#[must_use]
pub fn pass(
    places: &Places,
    chats: &Chats,
    live: &dyn Live,
    now: SystemTime,
    limits: &Limits,
) -> Report {
    let mut report = Report::default();
    let mut left = limits.max_reclaims;
    if let Some(dir) = &places.projections {
        projections(dir, chats, live, now, limits, &mut left, &mut report);
    }
    report
}

/// Takes one of the pass's frees, or counts the folder as deferred.
fn take(left: &mut usize, report: &mut Report) -> bool {
    if *left == 0 {
        report.deferred += 1;
        return false;
    }
    *left -= 1;
    true
}

fn note(report: &mut Report, path: &Path, why: Why, freed: io::Result<u64>) {
    match freed {
        Ok(bytes) => report.reclaimed.push(Reclaim { path: path.to_path_buf(), why, bytes }),
        Err(error) => report.failed.push((path.to_path_buf(), error.to_string())),
    }
}

fn projections(
    dir: &Path,
    chats: &Chats,
    live: &dyn Live,
    now: SystemTime,
    limits: &Limits,
    left: &mut usize,
    report: &mut Report,
) {
    for (name, state) in folders(dir, limits.max_scan) {
        let Some(why) = verdict(&state, chats, live.mounted(&name), now, limits.orphan_grace)
        else {
            continue;
        };
        if !take(left, report) {
            continue;
        }
        let at = state::read(&state).map(|record| record.at);
        let freed = live.end(&name, at.as_deref(), why == Why::Orphan, &mut || {
            free_projection(&state, at.as_deref(), why)
        });
        match freed {
            Some(freed) => note(report, &state, why, freed),
            // Mounted since the verdict: it is in use again.
            None => *left += 1,
        }
    }
}

/// The folders in `dir` (name and path), at most `max`, by name.
fn folders(dir: &Path, max: usize) -> Vec<(String, PathBuf)> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    let mut found: Vec<(String, PathBuf)> = entries
        .filter_map(Result::ok)
        .take(max)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter_map(|entry| Some((entry.file_name().into_string().ok()?, entry.path())))
        .collect();
    found.sort();
    found
}

fn modified_ms(path: &Path) -> Option<u64> {
    fs::symlink_metadata(path).ok()?.modified().ok().map(state::ms_of)
}

fn older_than(since_ms: Option<u64>, now: SystemTime, grace: Duration) -> bool {
    since_ms.is_some_and(|since| {
        u128::from(state::ms_of(now).saturating_sub(since)) >= grace.as_millis()
    })
}

/// Removes `path` and everything below it, never crossing into another file system (a mount
/// below it stays, and the removal fails there). Answers the bytes of the files removed.
///
/// # Errors
/// When something below cannot be removed.
pub fn remove_tree(path: &Path) -> io::Result<u64> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        fs::remove_file(path)?;
        return Ok(meta.len());
    }
    let mut bytes = 0;
    remove_below(path, &meta, &mut bytes)?;
    fs::remove_dir(path)?;
    Ok(bytes)
}

fn remove_below(dir: &Path, meta: &fs::Metadata, bytes: &mut u64) -> io::Result<()> {
    // A folder the agent made read-only still goes: its owner may write it again.
    if meta.mode() & 0o700 != 0o700 {
        fs::set_permissions(dir, fs::Permissions::from_mode((meta.mode() & 0o7777) | 0o700))?;
    }
    let device = meta.dev();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let child = fs::symlink_metadata(&path)?;
        if child.is_dir() {
            if child.dev() != device {
                return Err(io::Error::other(format!(
                    "{} is a mount; it and what is above it stay",
                    path.display()
                )));
            }
            remove_below(&path, &child, bytes)?;
            fs::remove_dir(&path)?;
        } else {
            fs::remove_file(&path)?;
            *bytes += child.len();
        }
    }
    Ok(())
}

// The tests drive a real overlay, which is Linux only.
#[cfg(all(test, target_os = "linux"))]
#[path = "reap_tests.rs"]
mod tests;
