//! One pass per machine at a time, spaced per machine. Every acpmux daemon
//! on a machine (the app's, the nightly's, each tagged dev build's) runs
//! cleanup over the same worktrees, so a per-process "last pass" let each of
//! them scan every worktree: a dozen daemons over 800 worktrees kept git
//! running all day (about 17 git processes a second) and fseventsd busy.
//!
//! A pass holds an exclusive `flock` on `.pass.lock` in the archive store
//! while it runs (the kernel drops it when the holder ends, a crash
//! included), and `.pass-stamp` there records when the last automatic
//! pass started and finished. The next one is due a spacing after the later
//! of the two, so a pass longer than its spacing does not start the next at
//! once.

use std::fs::File;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const LOCK: &str = ".pass.lock";
// No `.json` extension: `Store::list` reads every `*.json` as a manifest.
const STAMP: &str = ".pass-stamp";

/// When the machine's last recorded pass ran.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stamp {
    pub started_ms: u64,
    #[serde(default)]
    pub finished_ms: Option<u64>,
}

impl Stamp {
    fn last_ms(&self) -> u64 {
        self.started_ms.max(self.finished_ms.unwrap_or(0))
    }
}

/// Why a pass may not start now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    /// Another process on this machine runs one.
    Busy,
    /// The last one was less than the spacing ago.
    NotDue,
    /// The lock could not be opened.
    Unavailable(String),
}

/// The machine's pass, held until dropped or finished.
#[derive(Debug)]
pub struct Claim {
    _lock: File,
    stamp: Option<PathBuf>,
    started_ms: u64,
    /// The start's stamp could not be written (a full disk): the caller's
    /// own spacing is all that holds the next pass back.
    stamp_error: Option<String>,
}

impl Drop for Claim {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            // SAFETY: the descriptor belongs to this claim and remains open
            // until this drop implementation returns. Explicitly releasing
            // it makes the lock handoff deterministic before a caller's next
            // claim, rather than relying on close-time unlock semantics.
            unsafe { libc::flock(self._lock.as_raw_fd(), libc::LOCK_UN) };
        }
    }
}

impl Claim {
    /// Records the end of a recorded pass; the lock goes with `self`. The
    /// error of a stamp that could not be written, at the start or now.
    pub fn finish(self, now_ms: u64) -> Result<(), String> {
        let Some(path) = &self.stamp else { return Ok(()) };
        let end =
            write_stamp(path, Stamp { started_ms: self.started_ms, finished_ms: Some(now_ms) });
        match self.stamp_error.as_ref() {
            Some(error) => Err(error.clone()),
            None => end,
        }
    }
}

/// The last recorded pass in `dir`, if any.
pub fn last(dir: &Path) -> Option<Stamp> {
    let text = std::fs::read(dir.join(STAMP)).ok()?;
    serde_json::from_slice(&text).ok()
}

/// Claims the machine's pass in the store folder `dir`. With `spacing`,
/// only when the last recorded pass was at least that long ago (an
/// automatic pass); without, regardless (a pass someone asked for). With
/// `record`, its start and end become the machine's last pass.
pub fn claim(
    dir: &Path,
    now_ms: u64,
    spacing: Option<u64>,
    record: bool,
) -> Result<Claim, Refused> {
    std::fs::create_dir_all(dir)
        .map_err(|e| Refused::Unavailable(format!("{}: {e}", dir.display())))?;
    let lock_path = dir.join(LOCK);
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .map_err(|e| Refused::Unavailable(format!("{}: {e}", lock_path.display())))?;
    if !try_lock(&lock) {
        return Err(Refused::Busy);
    }
    if let Some(spacing) = spacing
        && let Some(stamp) = last(dir)
        // A stamp from the future (the clock was ahead) does not hold
        // cleanup back on every daemon until the clock gets there.
        && stamp.last_ms() <= now_ms
        && now_ms - stamp.last_ms() < spacing
    {
        return Err(Refused::NotDue);
    }
    let stamp = record.then(|| dir.join(STAMP));
    let stamp_error = stamp
        .as_deref()
        .and_then(|path| write_stamp(path, Stamp { started_ms: now_ms, finished_ms: None }).err());
    Ok(Claim { _lock: lock, stamp, started_ms: now_ms, stamp_error })
}

fn write_stamp(path: &Path, stamp: Stamp) -> Result<(), String> {
    let text = serde_json::to_vec(&stamp).map_err(|e| e.to_string())?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, text).map_err(|e| format!("{}: {e}", temporary.display()))?;
    std::fs::rename(&temporary, path).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(unix)]
fn try_lock(file: &File) -> bool {
    use std::os::fd::AsRawFd;
    // SAFETY: flock on a descriptor the caller owns for the call.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

#[cfg(not(unix))]
fn try_lock(_file: &File) -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FOLDER: AtomicU64 = AtomicU64::new(0);

    fn folder(name: &str) -> PathBuf {
        let serial = NEXT_FOLDER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "care-schedule-{name}-{}-{}-{serial}",
            std::process::id(),
            crate::inventory::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    const HOUR: u64 = 60 * 60 * 1000;

    #[test]
    fn a_second_daemon_waits_while_one_runs_a_pass() {
        let dir = folder("busy");
        let held = claim(&dir, 1_000, Some(HOUR), true).expect("first pass");
        // Another process opens its own descriptor: flock is per open file.
        assert_eq!(claim(&dir, 1_000, Some(HOUR), true).unwrap_err(), Refused::Busy);
        assert_eq!(claim(&dir, 1_000, None, false).unwrap_err(), Refused::Busy);
        drop(held);
        assert!(claim(&dir, 1_000, None, false).is_ok(), "the lock goes with the claim");
    }

    #[test]
    fn the_next_automatic_pass_waits_a_spacing_after_the_last_ended() {
        let dir = folder("spacing");
        claim(&dir, 0, Some(HOUR), true).expect("first pass").finish(2 * HOUR).unwrap();
        assert_eq!(last(&dir), Some(Stamp { started_ms: 0, finished_ms: Some(2 * HOUR) }));
        // A daemon that starts (or wakes) an hour after the start, but before
        // an hour after the end, does not scan again.
        assert_eq!(
            claim(&dir, 2 * HOUR + HOUR / 2, Some(HOUR), true).unwrap_err(),
            Refused::NotDue
        );
        assert!(claim(&dir, 3 * HOUR, Some(HOUR), true).is_ok());
    }

    #[test]
    fn a_pass_that_never_finished_still_spaces_the_next() {
        let dir = folder("crash");
        drop(claim(&dir, 10, Some(HOUR), true).expect("pass"));
        assert_eq!(claim(&dir, HOUR / 2, Some(HOUR), true).unwrap_err(), Refused::NotDue);
    }

    #[test]
    fn a_stamp_from_the_future_does_not_hold_cleanup_back() {
        let dir = folder("future");
        claim(&dir, 10 * HOUR, Some(HOUR), true).expect("pass").finish(10 * HOUR).unwrap();
        assert!(claim(&dir, HOUR, Some(HOUR), true).is_ok());
    }

    #[test]
    fn an_asked_for_pass_ignores_the_spacing_and_a_report_records_nothing() {
        let dir = folder("asked");
        claim(&dir, 0, Some(HOUR), true).expect("pass").finish(5).unwrap();
        claim(&dir, 6, None, false).expect("report now").finish(7).unwrap();
        assert_eq!(last(&dir), Some(Stamp { started_ms: 0, finished_ms: Some(5) }));
        claim(&dir, 8, None, true).expect("clean up now").finish(9).unwrap();
        assert_eq!(last(&dir), Some(Stamp { started_ms: 8, finished_ms: Some(9) }));
    }
}
