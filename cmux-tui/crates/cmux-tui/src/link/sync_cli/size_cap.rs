//! The most a chat's streamed copy sends: [`MAX_BYTES`] of files or [`MAX_FILES`] files, counted
//! by the same rules that pick what goes ([`super::local::collect`]: heavy folders, secrets,
//! `.gitignore` in git, and in git the repository's history under `.git/`). The count stops the
//! moment either is passed, so a folder of hundreds of GB is refused in seconds, before anything
//! is sent, with [`CODE`] and a message that names the folder, what was found and the fix.
//!
//! Every surface that copies a folder of this Mac to a Cloud machine goes through it: New Cloud
//! chat and `cloud start-chat --from-folder` (`link start-chat copy`, `link seed push`), Move to
//! Cloud (`link seed push`, `link agent move --sync seed`) and `link sync push`. A Git seed sends
//! a bundle of what the machine lacks, not this copy, so it is not counted here; the copy a seed
//! falls back to is, `.git/` included.
//!
//! The one override is a [`Grant`]: a person agreed to copy this folder at the size a full count
//! found ([`measure`]), and for [`GRANT_LASTS`] a copy of it by any surface sends up to that size
//! plus a margin ([`Grant::max_bytes`], [`Grant::max_files`]). A folder that grew past the margin
//! is refused again. [`record`] is the only writer of grants, and grants no more than a fresh
//! [`measure`] of the same folder found: a count keeps what it found ([`Counted`]) for
//! [`COUNT_LASTS`], and a record above it, or with no count, is refused. The app's "Copy anyway"
//! counts the folder (`link copy-grant measure`), shows what it found, and records exactly that
//! (`link copy-grant record`); `--allow-large` (on `link seed push`, `link sync push` and `cloud
//! start-chat --from-folder`) counts and records in one step ([`allow`]). Grants and counts are
//! kept in folders only this user can open, written through no symbolic link.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// The most bytes a copy sends: 20 GiB.
pub(crate) const MAX_BYTES: u64 = 20 * 1024 * 1024 * 1024;
/// The most files a copy sends.
pub(crate) const MAX_FILES: u64 = 500_000;
/// The error code of a refused copy.
pub(crate) const CODE: &str = "copy.too_large";
/// How long a grant lasts for its folder.
const GRANT_LASTS: Duration = Duration::from_secs(24 * 60 * 60);
/// How long a count ([`measure`]) may be granted ([`record`]) after it was made: the time a person
/// has to read "Copy 87 GB in 1.2M files?" and agree.
const COUNT_LASTS: Duration = Duration::from_secs(60 * 60);
/// The least a grant's folder may grow in bytes and still go: 1 GiB (or 10%, when that is more).
const MARGIN_BYTES: u64 = 1024 * 1024 * 1024;
/// The least a grant's folder may grow in files and still go: 10,000 (or 10%, when that is more).
const MARGIN_FILES: u64 = 10_000;

/// What a count reports as it goes ([`measure`]): bytes and files so far.
#[derive(Clone)]
pub(crate) struct Progress(pub Arc<dyn Fn(u64, u64) + Send + Sync>);

impl std::fmt::Debug for Progress {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Progress")
    }
}

/// How many files pass between two [`Progress`] reports.
const PROGRESS_EVERY_FILES: u64 = 2_000;

/// The running total of a copy's files against its limits.
#[derive(Clone, Debug)]
pub(super) struct Cap {
    folder: PathBuf,
    max_bytes: u64,
    max_files: u64,
    bytes: u64,
    files: u64,
    /// Of `bytes`, those under `.git/` (the repository's history).
    git_bytes: u64,
    progress: Option<Progress>,
}

impl Cap {
    /// The limits for a copy of `folder` (canonical): [`MAX_BYTES`] and [`MAX_FILES`] (a test's
    /// own in tests), or a fresh [`Grant`]'s limits when they are higher.
    pub(super) fn of(folder: &Path) -> Self {
        let (mut max_bytes, mut max_files) = limits();
        if let Some(grant) = granted(folder) {
            max_bytes = max_bytes.max(grant.max_bytes());
            max_files = max_files.max(grant.max_files());
        }
        Self::with(folder, max_bytes, max_files)
    }

    /// No limits: a full count ([`measure`]).
    fn unbounded(folder: &Path, progress: Option<Progress>) -> Self {
        Self { progress, ..Self::with(folder, u64::MAX, u64::MAX) }
    }

    fn with(folder: &Path, max_bytes: u64, max_files: u64) -> Self {
        Self {
            folder: folder.to_path_buf(),
            max_bytes,
            max_files,
            bytes: 0,
            files: 0,
            git_bytes: 0,
            progress: None,
        }
    }

    /// Counts one file of `bytes` going as `relative`: [`TooLarge`] once a limit is passed.
    pub(super) fn charge(&mut self, relative: &str, bytes: u64) -> Result<(), TooLarge> {
        self.files += 1;
        self.bytes = self.bytes.saturating_add(bytes);
        if relative.starts_with(".git/") {
            self.git_bytes = self.git_bytes.saturating_add(bytes);
        }
        if let Some(progress) = &self.progress
            && self.files.is_multiple_of(PROGRESS_EVERY_FILES)
        {
            (progress.0)(self.bytes, self.files);
        }
        if self.bytes > self.max_bytes || self.files > self.max_files {
            return Err(TooLarge {
                folder: self.folder.clone(),
                bytes: self.bytes,
                files: self.files,
                git_bytes: self.git_bytes,
                max_bytes: self.max_bytes,
                max_files: self.max_files,
            });
        }
        Ok(())
    }
}

/// A copy refused before anything was sent: what it found by the time a limit was passed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TooLarge {
    pub folder: PathBuf,
    /// At least this much was found (the count stopped here).
    pub bytes: u64,
    pub files: u64,
    /// Of `bytes`, those of the repository's history (`.git/`).
    pub git_bytes: u64,
    pub max_bytes: u64,
    pub max_files: u64,
}

impl std::fmt::Display for TooLarge {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let folder = shown(&self.folder);
        let limit = format!(
            "a copy sends at most {} or {} files",
            size(self.max_bytes),
            count(self.max_files)
        );
        // The repository's history is most of it: a seed (a clone from GitHub) is the way.
        if self.git_bytes.saturating_mul(2) > self.bytes {
            return write!(
                formatter,
                "{folder} is too big to copy to a Cloud machine: it holds at least {} to send, {} of \
                 it the repository's history (.git) ({limit}). Push it to GitHub so the machine \
                 clones it instead",
                size(self.bytes),
                size(self.git_bytes),
            );
        }
        write!(
            formatter,
            "{folder} is too big to copy to a Cloud machine: it holds at least {} in at least {} files \
             ({limit}). Pick the project folder inside it",
            size(self.bytes),
            count(self.files),
        )
    }
}

impl std::error::Error for TooLarge {}

/// What a person at a terminal adds to a [`TooLarge`] message: the one override.
pub(crate) const OVERRIDE_HINT: &str =
    "; to copy it anyway, run the same command with --allow-large";

/// `folder` with this Mac's home as `~`.
pub(crate) fn shown(folder: &Path) -> String {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    match home.as_deref().and_then(|home| folder.strip_prefix(home).ok()) {
        Some(rest) if rest.as_os_str().is_empty() => "~".to_owned(),
        Some(rest) => format!("~/{}", rest.display()),
        None => folder.display().to_string(),
    }
}

/// `bytes` in GB (of 1024³; one decimal under 100 GB), or in MB under 1 GB.
pub(crate) fn size(bytes: u64) -> String {
    const GB: f64 = (1024 * 1024 * 1024) as f64;
    const MB: f64 = (1024 * 1024) as f64;
    let bytes = bytes as f64;
    if bytes >= 100.0 * GB {
        format!("{:.0} GB", bytes / GB)
    } else if bytes >= GB {
        let text = format!("{:.1}", bytes / GB);
        format!("{} GB", text.strip_suffix(".0").unwrap_or(&text))
    } else {
        format!("{:.0} MB", bytes / MB)
    }
}

/// `number` with its thousands separated by commas.
pub(crate) fn count(number: u64) -> String {
    let digits = number.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

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

/// A person's agreement to copy `folder` whole at the size a full count found: a copy of it sends
/// up to [`Grant::max_bytes`] and [`Grant::max_files`] until [`GRANT_LASTS`] after `granted_at`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Grant {
    /// The folder, canonical.
    pub folder: PathBuf,
    /// The bytes the count found and the person saw.
    pub bytes: u64,
    /// The files the count found and the person saw.
    pub files: u64,
    /// When it was recorded, in seconds since the Unix epoch.
    pub granted_at: u64,
}

impl Grant {
    /// The most bytes a copy under this grant sends: what was granted plus the larger of 10% and
    /// [`MARGIN_BYTES`].
    pub(crate) fn max_bytes(&self) -> u64 {
        self.bytes.saturating_add((self.bytes / 10).max(MARGIN_BYTES))
    }

    /// The most files a copy under this grant sends: what was granted plus the larger of 10% and
    /// [`MARGIN_FILES`].
    pub(crate) fn max_files(&self) -> u64 {
        self.files.saturating_add((self.files / 10).max(MARGIN_FILES))
    }

    /// When it stops counting, in seconds since the Unix epoch.
    pub(crate) fn expires_at(&self) -> u64 {
        self.granted_at.saturating_add(GRANT_LASTS.as_secs())
    }

    /// What `--allow-large` tells the person at a terminal it granted.
    pub(crate) fn summary(&self) -> String {
        format!(
            "{} may be copied for 24 hours: {} in {} files, and up to {} or {} files if it grows",
            shown(&self.folder),
            size(self.bytes),
            count(self.files),
            size(self.max_bytes()),
            count(self.max_files()),
        )
    }
}

/// What a full count of a copy of a folder found ([`measure`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Measured {
    /// The folder counted, canonical.
    pub folder: PathBuf,
    pub bytes: u64,
    pub files: u64,
    /// Of `bytes`, those of the repository's history (`.git/`).
    pub git_bytes: u64,
}

/// What a count of a folder found, kept for [`record`] to grant no more than that.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Counted {
    /// The folder, canonical.
    folder: PathBuf,
    bytes: u64,
    files: u64,
    /// When it was counted, in seconds since the Unix epoch.
    at: u64,
}

/// Where the grant of `folder` is kept: `<state>/link-sync/allow-large/<sha256>`.
fn grant_path(folder: &Path) -> Option<PathBuf> {
    kept_path("allow-large", folder)
}

/// Where the last count of `folder` is kept: `<state>/link-sync/copy-counted/<sha256>`.
fn count_path(folder: &Path) -> Option<PathBuf> {
    kept_path("copy-counted", folder)
}

fn kept_path(kind: &str, folder: &Path) -> Option<PathBuf> {
    #[cfg(test)]
    let state = TEST_STATE.with(|state| state.borrow().clone());
    #[cfg(not(test))]
    let state = None;
    let state = state.or_else(cmux_tui_core::platform::workspace_state_dir)?;
    let digest = Sha256::digest(folder.as_os_str().as_encoded_bytes());
    let name: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    Some(state.join("link-sync").join(kind).join(name))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// Whether something made `at` (seconds since the Unix epoch) is younger than `lasts`: not older,
/// and not dated in the future.
fn fresh(at: u64, lasts: Duration) -> bool {
    now().checked_sub(at).is_some_and(|age| age < lasts.as_secs())
}

/// Counts what a copy of `folder` sends, by the rules a copy counts by, to the end (no limit
/// stops it): what "Copy anyway" shows the person before they agree. `progress` hears the count
/// as it goes. What it found is kept for [`COUNT_LASTS`]: [`record`] grants no more than that.
pub(crate) fn measure(folder: &Path, progress: Option<Progress>) -> anyhow::Result<Measured> {
    use anyhow::Context as _;
    let folder = std::fs::canonicalize(folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    let cap = Cap::unbounded(&folder, progress);
    let set = super::local::collect(&folder, super::local::Rules::Copy, Some(cap))?;
    let cap = set.cap.context("the count kept no total")?;
    let counted = Counted { folder: folder.clone(), bytes: cap.bytes, files: cap.files, at: now() };
    let path = count_path(&folder).context("this Mac has no state folder to keep the count in")?;
    keep(&path, &serde_json::to_vec(&counted)?)?;
    Ok(Measured { folder, bytes: cap.bytes, files: cap.files, git_bytes: cap.git_bytes })
}

/// Records that a copy of `folder` may send `bytes` in `files` (what the person was shown), plus
/// the margin, for [`GRANT_LASTS`]. Refused, granting nothing, unless a [`measure`] of the same
/// folder in the last [`COUNT_LASTS`] found at least that much. The only writer of grants.
pub(crate) fn record(folder: &Path, bytes: u64, files: u64) -> anyhow::Result<Grant> {
    use anyhow::Context as _;
    let folder = std::fs::canonicalize(folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    let counted = count_path(&folder)
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<Counted>(&bytes).ok())
        .filter(|counted| counted.folder == folder && fresh(counted.at, COUNT_LASTS))
        .with_context(|| {
            format!("{} was not counted in the last hour: count it first", shown(&folder))
        })?;
    anyhow::ensure!(
        bytes <= counted.bytes && files <= counted.files,
        "{} was counted at {} in {} files: a grant cannot be for more",
        shown(&folder),
        size(counted.bytes),
        count(counted.files),
    );
    let path = grant_path(&folder).context("this Mac has no state folder to keep the grant in")?;
    let grant = Grant { folder, bytes, files, granted_at: now() };
    keep(&path, &serde_json::to_vec(&grant)?)?;
    Ok(grant)
}

/// Writes `bytes` whole at `path`: a new file that only this user can read, in a folder only this
/// user can open (made 0700, or made so when it is there), renamed over the old one, so a reader
/// never sees half of it. A symbolic link in place of the folder or the new file is refused.
fn keep(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("cannot make {}", dir.display()))?;
    let kind =
        std::fs::symlink_metadata(dir).with_context(|| format!("cannot open {}", dir.display()))?;
    anyhow::ensure!(kind.is_dir(), "{} is not a folder (a link?): nothing written", dir.display());
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("cannot make {} private", dir.display()))?;
    let name = path.file_name().context("no file name")?.to_string_lossy();
    let temporary = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    write_private(&temporary, bytes)
        .with_context(|| format!("cannot write {}", temporary.display()))?;
    let renamed = std::fs::rename(&temporary, path);
    if renamed.is_err() {
        // Ours: write_private made it new.
        let _ = std::fs::remove_file(&temporary);
    }
    renamed.with_context(|| format!("cannot write {}", path.display()))
}

/// Writes `bytes` to a new file at `path` that only this user can read, flushed to the disk. A
/// file or link already at `path` is refused (`create_new`, and no link followed), never written
/// through. A file it made but could not fill is removed.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o600)
        .open(path)?;
    let filled = file.write_all(bytes).and_then(|()| file.sync_all());
    if filled.is_err() {
        let _ = std::fs::remove_file(path);
    }
    filled
}

/// `--allow-large`: counts `folder` to the end ([`measure`]) and grants what it found ([`record`]).
pub(crate) fn allow(folder: &Path) -> anyhow::Result<Grant> {
    let measured = measure(folder, None)?;
    record(folder, measured.bytes, measured.files)
}

/// The fresh grant of `folder` (canonical), if any. A grant of another folder (a hash that
/// matched), one that does not parse (an older `--allow-large` kept a bare path, with no size),
/// one older than [`GRANT_LASTS`] or one dated in the future is none.
fn granted(folder: &Path) -> Option<Grant> {
    let grant: Grant = serde_json::from_slice(&std::fs::read(grant_path(folder)?).ok()?).ok()?;
    (fresh(grant.granted_at, GRANT_LASTS) && grant.folder == folder).then_some(grant)
}

/// The limits a copy runs with: [`MAX_BYTES`] and [`MAX_FILES`], or a test's own.
fn limits() -> (u64, u64) {
    #[cfg(test)]
    if let Some(limits) = TEST_LIMITS.with(std::cell::Cell::get) {
        return limits;
    }
    (MAX_BYTES, MAX_FILES)
}

#[cfg(test)]
thread_local! {
    /// A test's own limits (bytes, files) for copies on its thread.
    pub(super) static TEST_LIMITS: std::cell::Cell<Option<(u64, u64)>> =
        const { std::cell::Cell::new(None) };
    /// A test's own state folder for grants.
    pub(super) static TEST_STATE: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Whether a copy of the plain (not git) folder `folder` passes the limits, counted as the copy
/// counts it and stopped at the first limit passed: for `cloud start-chat --from-folder`, which
/// refuses such a folder before any machine is made. A [`Grant`] raises the limits as it does for
/// every copy. A folder in git (a seed may take it whole, never this copy; the copy it falls back
/// to counts it) is not counted.
pub(crate) fn check_plain(folder: &Path) -> Result<(), TooLarge> {
    let Ok(folder) = std::fs::canonicalize(folder) else { return Ok(()) };
    if super::in_git(&folder) {
        return Ok(());
    }
    let cap = Some(Cap::of(&folder));
    match super::local::collect(&folder, super::local::Rules::Copy, cap) {
        // Any other failure is the copy's to report.
        Err(error) => error.downcast::<TooLarge>().map_or(Ok(()), Err),
        Ok(_) => Ok(()),
    }
}

// The way on from a refused copy of a folder that is not a repository: the repositories inside it
// (`~/Projects`, a parent of many), each a folder a chat can start in instead.

/// The most repositories a refusal names.
pub(crate) const MAX_REPOS: usize = 24;
/// The most entries read in one folder while looking for repositories: a folder of thousands of
/// entries is never read whole.
const MAX_ENTRIES: usize = 2_000;

/// One git working copy inside the refused folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Repo {
    /// Its path below the folder (`cmux`, `work/api`).
    pub name: String,
    /// Its absolute path on this Mac.
    pub path: PathBuf,
}

/// The git working copies directly in `folder`, and one level further down (`work/api`), by name,
/// at most `limit`, and whether there were more. Only `.git` is looked for: no folder below a
/// repository or two levels down is read, hidden folders are skipped and symlinks never followed,
/// and at most [`MAX_ENTRIES`] entries of any one folder are read (a folder with more answers "more",
/// since a repository may be among the unread ones).
pub(crate) fn child_repos(folder: &Path, limit: usize) -> (Vec<Repo>, bool) {
    let mut found = Vec::new();
    let mut more = false;
    let (children, mut unread) = folders_in(folder);
    let mut plain = Vec::new();
    for child in children {
        if is_repo(&child) {
            push(&mut found, &mut more, folder, child, limit);
        } else {
            plain.push(child);
        }
    }
    for child in plain {
        if more {
            break;
        }
        let (grandchildren, cut) = folders_in(&child);
        unread |= cut;
        for grandchild in grandchildren {
            if is_repo(&grandchild) {
                push(&mut found, &mut more, folder, grandchild, limit);
            }
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    (found, more || unread)
}

fn push(found: &mut Vec<Repo>, more: &mut bool, folder: &Path, path: PathBuf, limit: usize) {
    if found.len() >= limit {
        *more = true;
        return;
    }
    let name = path
        .strip_prefix(folder)
        .map_or_else(|_| path.display().to_string(), |rest| rest.display().to_string());
    found.push(Repo { name, path });
}

/// The visible folders right in `folder` (no symlinks), by name, at most [`MAX_ENTRIES`] entries
/// read, and whether entries were left unread (so a repository among them may be missing: the
/// caller says "and more").
fn folders_in(folder: &Path) -> (Vec<PathBuf>, bool) {
    let Ok(mut entries) = std::fs::read_dir(folder) else { return (Vec::new(), false) };
    let mut folders: Vec<PathBuf> = entries
        .by_ref()
        .take(MAX_ENTRIES)
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    folders.sort();
    let cut = entries.next().is_some();
    (folders, cut)
}

/// Whether `folder` is a working copy's top: it holds `.git` (a folder, or a worktree's file).
fn is_repo(folder: &Path) -> bool {
    std::fs::symlink_metadata(folder.join(".git")).is_ok()
}

/// What a person at a terminal reads after a refusal of `folder`: the repositories inside it to start
/// in instead (`; the repositories inside it: cmux, web (start in one: --from-folder ~/Projects/cmux)`),
/// else nothing.
pub(crate) fn repos_hint(folder: &Path) -> String {
    let folder = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
    let (repos, more) = child_repos(&folder, MAX_REPOS);
    let Some(first) = repos.first() else { return String::new() };
    let names: Vec<&str> = repos.iter().map(|repo| repo.name.as_str()).collect();
    let more = if more { ", and more" } else { "" };
    format!(
        "; the repositories inside it: {}{more} (start in one: --from-folder {})",
        names.join(", "),
        shell_word(&shown(&first.path))
    )
}

/// `path` (as [`shown`] writes it) as one shell word a person can paste: quoted when a shell would
/// split or expand it, with a leading `~/` left outside the quotes so the shell still expands it.
fn shell_word(path: &str) -> String {
    let (home, rest) = path.strip_prefix("~/").map_or(("", path), |rest| ("~/", rest));
    let plain = !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=@%+,".contains(c));
    if plain { format!("{home}{rest}") } else { format!("{home}'{}'", rest.replace('\'', "'\\''")) }
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
