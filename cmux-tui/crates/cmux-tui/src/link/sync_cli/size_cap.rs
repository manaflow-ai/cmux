//! How much a chat's streamed copy sends before the chat starts. A copy lists what it would send
//! by the same rules that pick what goes ([`super::local::collect`]: heavy folders, secrets,
//! `.gitignore` in git, and in git the repository's history under `.git/`), counted against
//! [`MAX_BYTES`] and [`MAX_FILES`]. A folder under both goes whole, as before. A folder past one
//! is never refused: the listing stops at the file limit (its cost stays bounded; bytes are only
//! summed, so a sparse file of hundreds of GB costs nothing) and the copy sends a first pass of
//! what it listed, at most [`FIRST_BYTES`] in [`FIRST_FILES`] files, the smallest first and no
//! repository history (`.git` at any depth), so the chat starts in the folder the person chose at
//! once. Everything else stays on this Mac, counted as `left_on_mac` in the copy's
//! `skipped_counts`; the chat's agent asks for a file of it with `cmux link access request PATH`.
//!
//! Leo, 2026-11-15, on a Cloud chat at `~/Projects` refused as too big to copy: "why are you guys
//! still blocking on these?"
//!
//! Every surface that copies a folder of this Mac to a Cloud machine goes through it: New Cloud
//! chat and `cloud start-chat --from-folder` (`link start-chat copy`, `link seed push`), Move to
//! Cloud (`link seed push`, `link agent move --sync seed`) and `link sync push`. A Git seed sends
//! a bundle of what the machine lacks, not this copy, so it is not counted here; the copy a seed
//! falls back to is, `.git/` included.
//!
//! Time counts as well as size: a fresh copy this Mac's link would take longer than a minute to
//! send starts from a first pass too, and every start knows which before any machine is made
//! ([`super::estimate`]).
//!
//! `--allow-large` (on `link seed push`, `link sync push` and `cloud start-chat --from-folder`)
//! records the folder here ([`allow`]) for [`GRANT_LASTS`], and a copy of that folder in that time,
//! by any surface (the app's own runs too), sends it whole.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use sha2::{Digest as _, Sha256};

/// The most bytes a copy sends whole: 20 GiB.
pub(crate) const MAX_BYTES: u64 = 20 * 1024 * 1024 * 1024;
/// The most files a copy sends whole (and lists).
pub(crate) const MAX_FILES: u64 = 500_000;
/// What a copy of a folder past [`MAX_BYTES`] or [`MAX_FILES`] sends before its chat starts.
pub(crate) const FIRST_BYTES: u64 = 256 * 1024 * 1024;
/// The most files of that first pass.
pub(crate) const FIRST_FILES: u64 = 20_000;
/// How far past [`MAX_FILES`] a listing goes on while only repository history (`.git` at any
/// depth) is over it: a parent of repositories whose nested histories hold most of its files is
/// listed to its last folder, since a first pass sends no history anyway; the listing's cost stays
/// bounded at this many times the file limit.
const HISTORY_ROOM: u64 = 4;
/// How long an `--allow-large` lasts for its folder.
const GRANT_LASTS: Duration = Duration::from_secs(24 * 60 * 60);

/// The running total of a copy's files against its limits, and each listed file's size (what a
/// first pass picks by). Only the file count ends a listing ([`FileLimit`]), so its cost is
/// bounded; bytes past [`MAX_BYTES`], or files past [`MAX_FILES`] the listing went on past because
/// they were repository history, make the copy a first pass once the listing is done.
#[derive(Clone, Debug)]
pub(super) struct Cap {
    max_bytes: u64,
    max_files: u64,
    bytes: u64,
    files: u64,
    /// The files counted that are not repository history.
    working: u64,
    sizes: HashMap<String, u64>,
    /// When a start's estimate before any machine (`estimate.rs`) stops listing, as at the file
    /// limit; none for a copy.
    until: Option<Instant>,
    /// The listing stopped at `until`.
    timed_out: bool,
}

impl Cap {
    /// The limits for a copy ([`MAX_BYTES`], [`MAX_FILES`]; a test's own in tests).
    pub(super) fn new() -> Self {
        let (max_bytes, max_files) = limits();
        Self {
            max_bytes,
            max_files,
            bytes: 0,
            files: 0,
            working: 0,
            sizes: HashMap::new(),
            until: None,
            timed_out: false,
        }
    }

    /// [`Cap::new`] for a listing that also stops at `until`, as at the file limit
    /// ([`Cap::timed_out`] then says so).
    pub(super) fn until(until: Instant) -> Self {
        Self { until: Some(until), ..Self::new() }
    }

    /// Whether the listing stopped at its time bound ([`Cap::until`]).
    pub(super) fn timed_out(&self) -> bool {
        self.timed_out
    }

    /// The files and bytes counted so far.
    pub(super) fn listed(&self) -> (u64, u64) {
        (self.files, self.bytes)
    }

    /// Counts one file of `bytes` going as `relative`: [`FileLimit`] once the files that are not
    /// repository history pass the file limit (or all of them pass [`HISTORY_ROOM`] times it),
    /// which ends the listing.
    pub(super) fn charge(&mut self, relative: &str, bytes: u64) -> Result<(), FileLimit> {
        self.files += 1;
        if !super::local::in_history(relative) {
            self.working += 1;
        }
        if self.working > self.max_files || self.files > self.max_files.saturating_mul(HISTORY_ROOM)
        {
            return Err(FileLimit);
        }
        // The clock is read once every 1,024 files, so the bound adds nothing to the walk's cost.
        if self.files % 1024 == 0 && self.until.is_some_and(|until| Instant::now() >= until) {
            self.timed_out = true;
            return Err(FileLimit);
        }
        self.bytes = self.bytes.saturating_add(bytes);
        self.sizes.insert(relative.to_owned(), bytes);
        Ok(())
    }

    /// Whether what was listed is more than a copy sends whole, in bytes or in files.
    pub(super) fn past(&self) -> bool {
        self.bytes > self.max_bytes || self.files > self.max_files
    }

    /// Whether what was listed is more bytes than a copy sends whole.
    pub(super) fn past_bytes(&self) -> bool {
        self.bytes > self.max_bytes
    }

    /// The size `relative` was counted at (0 for one never counted).
    pub(super) fn size_of(&self, relative: &str) -> u64 {
        self.sizes.get(relative).copied().unwrap_or(0)
    }
}

/// A listing stopped at the file limit: the copy sends a first pass of what it listed
/// ([`super::local::collect`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FileLimit;

impl std::fmt::Display for FileLimit {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("past the most files a copy sends whole")
    }
}

impl std::error::Error for FileLimit {}

/// `args` without the `--allow-large` flag, and whether it was there. A word that is the value of
/// a flag in `takes_value`, or comes after `--`, is never the flag: it stays.
pub(crate) fn take_allow_large(args: &[String], takes_value: &[&str]) -> (Vec<String>, bool) {
    let mut kept = Vec::with_capacity(args.len());
    let (mut given, mut value_next, mut text) = (false, false, false);
    for arg in args {
        if text || value_next {
            value_next = false;
            kept.push(arg.clone());
            continue;
        }
        if arg == "--allow-large" {
            given = true;
            continue;
        }
        text = arg == "--";
        value_next = takes_value.contains(&arg.as_str());
        kept.push(arg.clone());
    }
    (kept, given)
}

/// Where the `--allow-large` of `folder` is kept: `<state>/link-sync/allow-large/<sha256>`.
fn grant_path(folder: &Path) -> Option<PathBuf> {
    #[cfg(test)]
    let state = TEST_STATE.with(|state| state.borrow().clone());
    #[cfg(not(test))]
    let state = None;
    let state = state.or_else(cmux_tui_core::platform::workspace_state_dir)?;
    let digest = Sha256::digest(folder.as_os_str().as_encoded_bytes());
    let name: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    Some(state.join("link-sync").join("allow-large").join(name))
}

/// Records `--allow-large` for `folder` (made canonical): a copy of it sends it whole for
/// [`GRANT_LASTS`], whichever surface runs the copy.
pub(crate) fn allow(folder: &Path) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use std::os::unix::fs::DirBuilderExt as _;
    let folder = std::fs::canonicalize(folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    let path =
        grant_path(&folder).context("this Mac has no state folder to keep --allow-large in")?;
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("cannot make {}", dir.display()))?;
    std::fs::write(&path, folder.as_os_str().as_encoded_bytes())
        .with_context(|| format!("cannot write {}", path.display()))
}

/// Whether `folder` (canonical) has an `--allow-large` from the last [`GRANT_LASTS`].
pub(super) fn allowed(folder: &Path) -> bool {
    let Some(path) = grant_path(folder) else { return false };
    let Ok(meta) = std::fs::metadata(&path) else { return false };
    let fresh = meta
        .modified()
        .ok()
        .and_then(|at| SystemTime::now().duration_since(at).ok())
        .is_some_and(|age| age < GRANT_LASTS);
    // The grant names its folder: a hash that matched another path never counts.
    fresh && std::fs::read(&path).is_ok_and(|named| named == folder.as_os_str().as_encoded_bytes())
}

/// The limits a copy runs with: [`MAX_BYTES`] and [`MAX_FILES`], or a test's own.
fn limits() -> (u64, u64) {
    #[cfg(test)]
    if let Some(limits) = TEST_LIMITS.with(std::cell::Cell::get) {
        return limits;
    }
    (MAX_BYTES, MAX_FILES)
}

/// The first pass a copy past its limits sends: [`FIRST_BYTES`] and [`FIRST_FILES`], or a test's own.
pub(super) fn first_limits() -> (u64, u64) {
    #[cfg(test)]
    if let Some(limits) = TEST_FIRST.with(std::cell::Cell::get) {
        return limits;
    }
    // On a slow link the first pass is what goes within the start's time budget (estimate.rs).
    (super::estimate::within_budget(FIRST_BYTES), FIRST_FILES)
}

#[cfg(test)]
thread_local! {
    /// A test's own first pass (bytes, files) for copies on its thread.
    pub(super) static TEST_FIRST: std::cell::Cell<Option<(u64, u64)>> =
        const { std::cell::Cell::new(None) };
    /// A test's own limits (bytes, files) for copies on its thread.
    pub(super) static TEST_LIMITS: std::cell::Cell<Option<(u64, u64)>> =
        const { std::cell::Cell::new(None) };
    /// A test's own state folder for `--allow-large` grants.
    pub(super) static TEST_STATE: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Runs `run` with a copy's limits at `bytes` and `files` on this thread (other modules' tests).
#[cfg(test)]
pub(crate) fn with_test_limits<T>(bytes: u64, files: u64, run: impl FnOnce() -> T) -> T {
    TEST_LIMITS.with(|limits| limits.set(Some((bytes, files))));
    let out = run();
    TEST_LIMITS.with(|limits| limits.set(None));
    out
}

#[cfg(test)]
#[path = "size_cap_tests.rs"]
mod tests;
