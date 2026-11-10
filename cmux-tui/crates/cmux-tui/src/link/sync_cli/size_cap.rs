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
//! `--allow-large` (on `link seed push`, `link sync push` and `cloud start-chat --from-folder`)
//! is the one override: it records the folder here ([`allow`]) for [`GRANT_LASTS`], and a copy of
//! that folder in that time, by any surface (the app's own runs too), sends it whole.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use sha2::{Digest as _, Sha256};

/// The most bytes a copy sends: 20 GiB.
pub(crate) const MAX_BYTES: u64 = 20 * 1024 * 1024 * 1024;
/// The most files a copy sends.
pub(crate) const MAX_FILES: u64 = 500_000;
/// The error code of a refused copy.
pub(crate) const CODE: &str = "copy.too_large";
/// How long an `--allow-large` lasts for its folder.
const GRANT_LASTS: Duration = Duration::from_secs(24 * 60 * 60);

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
}

impl Cap {
    /// The limits for a copy of `folder` ([`MAX_BYTES`], [`MAX_FILES`]; a test's own in tests).
    pub(super) fn of(folder: &Path) -> Self {
        let (max_bytes, max_files) = limits();
        Self {
            folder: folder.to_path_buf(),
            max_bytes,
            max_files,
            bytes: 0,
            files: 0,
            git_bytes: 0,
        }
    }

    /// Counts one file of `bytes` going as `relative`: [`TooLarge`] once a limit is passed.
    pub(super) fn charge(&mut self, relative: &str, bytes: u64) -> Result<(), TooLarge> {
        self.files += 1;
        self.bytes = self.bytes.saturating_add(bytes);
        if relative.starts_with(".git/") {
            self.git_bytes = self.git_bytes.saturating_add(bytes);
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
fn shown(folder: &Path) -> String {
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

#[cfg(test)]
thread_local! {
    /// A test's own limits (bytes, files) for copies on its thread.
    pub(super) static TEST_LIMITS: std::cell::Cell<Option<(u64, u64)>> =
        const { std::cell::Cell::new(None) };
    /// A test's own state folder for `--allow-large` grants.
    pub(super) static TEST_STATE: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Whether a copy of the plain (not git) folder `folder` passes the limits, counted as the copy
/// counts it and stopped at the first limit passed: for `cloud start-chat --from-folder`, which
/// refuses such a folder before any machine is made. A folder with an `--allow-large`, or in git
/// (a seed may take it whole, never this copy; the copy it falls back to counts it), is not counted.
pub(crate) fn check_plain(folder: &Path) -> Result<(), TooLarge> {
    let Ok(folder) = std::fs::canonicalize(folder) else { return Ok(()) };
    if allowed(&folder) || super::in_git(&folder) {
        return Ok(());
    }
    let cap = Some(Cap::of(&folder));
    match super::local::collect(&folder, super::local::Rules::Copy, cap) {
        // Any other failure is the copy's to report.
        Err(error) => error.downcast::<TooLarge>().map_or(Ok(()), Err),
        Ok(_) => Ok(()),
    }
}

#[cfg(test)]
#[path = "size_cap_tests.rs"]
mod tests;
