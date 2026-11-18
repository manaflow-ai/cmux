//! Frees what a machine keeps for each chat once nothing can need it again: a projection's state
//! folder (its upper layer, whiteouts, record and cache, [`crate::state`]), the chat's copy of its
//! folder under the work root (`$HOME/work/chats/<key>/<copy>`), and the repositories added to the
//! chat (`$HOME/chats/<chat>`). One [`pass`] runs at the daemon's start and on a timer, does a
//! bounded amount of work ([`Limits`]) and says what it freed and why ([`Report`]).
//!
//! What goes, and the one rule that keeps edits safe:
//!
//! - a projection **brought back** whose upper layer is still as Bring Back read it
//!   ([`state::BroughtBack`]): its edits are on the Mac;
//! - anything of a chat that is **archived or deleted**: released by the Mac
//!   ([`state::Released`]), or every chat on this machine whose folder is in it archived;
//! - an **orphan**: no chat on this machine names it, and it is older than the grace
//!   ([`ORPHAN_GRACE`]): the chat was deleted, or never started;
//! - the **idle caches** past the machine's budget ([`CACHE_BUDGET`]), oldest blob first: they are
//!   clean copies of the Mac's bytes, fetched again on the next read.
//!
//! A live chat's upper layer whose edits were never brought back is never freed. Whether a chat
//! is live comes from the machine's chat list ([`Chats`]); a list that could not be read whole,
//! or holds no chat at all, frees nothing by it (only brought-back and released projections, and
//! idle caches, go).

use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::overlay::CACHE_ID_FILE;
use crate::state::{self, Release};

/// How long state no chat names stays before it is an orphan.
pub const ORPHAN_GRACE: Duration = Duration::from_secs(14 * 24 * 60 * 60);
/// The most bytes the caches of projections no chat is using keep, together.
pub const CACHE_BUDGET: u64 = 4 * 1024 * 1024 * 1024;
/// The most folders one pass frees; the rest wait for the next pass.
pub const MAX_RECLAIMS: usize = 16;
/// The most entries one pass reads in a folder of chats.
pub const MAX_SCAN: usize = 4096;
/// The most cache files one pass deletes.
pub const MAX_CACHE_FILES: usize = 4096;

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

    fn of_id_or_folder(&self, id: &str, folder: &Path) -> Use {
        Self::fold(self.rows.iter().filter(|chat| {
            chat.id == id
                || chat.folder.as_deref().is_some_and(|runs_in| runs_in.starts_with(folder))
        }))
    }
}

/// Where this machine keeps per-chat state.
#[derive(Clone, Debug, Default)]
pub struct Places {
    /// The daemon's `projections/` folder: a state folder per projection name.
    pub projections: Option<PathBuf>,
    /// The work root's `chats/` folder: `<key>/<copy>`, a folder per copy of a chat's folder.
    pub copies: Option<PathBuf>,
    /// `$HOME/chats`: `<chat>/<repo>`, the repositories added to a chat.
    pub repos: Option<PathBuf>,
}

/// A pass's bounds.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub orphan_grace: Duration,
    pub cache_budget: u64,
    pub max_reclaims: usize,
    pub max_scan: usize,
    pub max_cache_files: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            orphan_grace: ORPHAN_GRACE,
            cache_budget: CACHE_BUDGET,
            max_reclaims: MAX_RECLAIMS,
            max_scan: MAX_SCAN,
            max_cache_files: MAX_CACHE_FILES,
        }
    }
}

/// Why something was freed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    BroughtBack,
    Archived,
    Deleted,
    Orphan,
    CacheOverBudget,
}

impl Why {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BroughtBack => "brought back",
            Self::Archived => "chat archived",
            Self::Deleted => "chat deleted",
            Self::Orphan => "orphan",
            Self::CacheOverBudget => "idle caches over budget",
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
    /// Whether one of this daemon's mounts is at or below `folder`.
    fn holds(&self, folder: &Path) -> bool;
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

    fn holds(&self, _folder: &Path) -> bool {
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

/// One pass over `places`: frees what may go, at most [`Limits::max_reclaims`] folders, then trims
/// the idle caches to the budget.
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
    if chats.knows() {
        if let Some(dir) = &places.copies {
            copies(dir, chats, live, now, limits, &mut left, &mut report);
        }
        if let Some(dir) = &places.repos {
            repos(dir, chats, live, now, limits, &mut left, &mut report);
        }
    }
    if let Some(dir) = &places.projections {
        trim_caches(dir, live, limits, &mut report);
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

fn copies(
    dir: &Path,
    chats: &Chats,
    live: &dyn Live,
    now: SystemTime,
    limits: &Limits,
    left: &mut usize,
    report: &mut Report,
) {
    let mut scanned = 0;
    for (_, key) in folders(dir, limits.max_scan) {
        for (_, copy) in folders(&key, limits.max_scan.saturating_sub(scanned)) {
            scanned += 1;
            if live.holds(&copy) {
                continue;
            }
            let why = match chats.of_folder(&copy) {
                Use::Live => continue,
                Use::Archived => Why::Archived,
                Use::Unnamed if older_than(modified_ms(&copy), now, limits.orphan_grace) => {
                    Why::Orphan
                }
                Use::Unnamed => continue,
            };
            if take(left, report) {
                note(report, &copy, why, remove_tree(&copy));
            }
        }
        // A key whose copies all went goes too (only when empty).
        let _ = fs::remove_dir(&key);
        if scanned >= limits.max_scan {
            break;
        }
    }
}

fn repos(
    dir: &Path,
    chats: &Chats,
    live: &dyn Live,
    now: SystemTime,
    limits: &Limits,
    left: &mut usize,
    report: &mut Report,
) {
    for (chat, folder) in folders(dir, limits.max_scan) {
        if live.holds(&folder) {
            continue;
        }
        let why = match chats.of_id_or_folder(&chat, &folder) {
            Use::Live => continue,
            Use::Archived => Why::Archived,
            Use::Unnamed if older_than(modified_ms(&folder), now, limits.orphan_grace) => {
                Why::Orphan
            }
            Use::Unnamed => continue,
        };
        if take(left, report) {
            note(report, &folder, why, remove_tree(&folder));
        }
    }
}

/// Deletes the oldest blobs of the caches no mount uses until they are within the budget.
fn trim_caches(dir: &Path, live: &dyn Live, limits: &Limits, report: &mut Report) {
    let mut blobs: Vec<(i64, u64, PathBuf, PathBuf)> = Vec::new();
    let mut total = 0u64;
    for (name, state) in folders(dir, limits.max_scan) {
        if live.mounted(&name) {
            continue;
        }
        let cache = state.join("cache");
        let Ok(entries) = fs::read_dir(&cache) else { continue };
        for entry in entries.filter_map(Result::ok) {
            if entry.file_name() == CACHE_ID_FILE {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_file() {
                total += meta.len();
                let modified = meta.mtime().saturating_mul(1_000_000_000) + meta.mtime_nsec();
                blobs.push((modified, meta.len(), entry.path(), cache.clone()));
            }
        }
    }
    if total <= limits.cache_budget {
        return;
    }
    blobs.sort_unstable();
    let mut freed: Vec<Reclaim> = Vec::new();
    for (_, bytes, path, cache) in blobs.into_iter().take(limits.max_cache_files) {
        if total <= limits.cache_budget {
            break;
        }
        if fs::remove_file(&path).is_err() {
            continue;
        }
        total = total.saturating_sub(bytes);
        match freed.iter_mut().find(|reclaim| reclaim.path == cache) {
            Some(reclaim) => reclaim.bytes += bytes,
            None => freed.push(Reclaim { path: cache, why: Why::CacheOverBudget, bytes }),
        }
    }
    report.reclaimed.extend(freed);
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

#[cfg(test)]
#[path = "reap_tests.rs"]
mod tests;
