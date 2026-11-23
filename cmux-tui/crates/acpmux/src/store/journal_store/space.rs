//! A full disk is a state the daemon stays up in, not a reason to stop (RFD 0049 R6, leg `disk`).
//!
//! The store keeps a reserve file in its home ([`RESERVE`], [`RESERVE_BYTES`]). When a write of
//! the journal fails for a full disk or quota ([`cmux_journal::Journal::on_out_of_space`]), the
//! store enters the full state (a log line's write that fails so is answered with its own
//! `ENOSPC` already, before its record is appended):
//!
//! - the reserve is removed, so the writer's next retry (its backoff, 100 ms at first) writes the
//!   records already appended. A reply waiting for them is sent once they are durable, as on any
//!   disk: nothing is acknowledged before it is on disk, and the replies of reads that waited
//!   behind them (the gate holds every reply on a connection after a write's) go too;
//! - every later log append, meta save and delete is refused at once, before it writes anything,
//!   with an error the request's annotation types `disk.full` (path and free bytes,
//!   `recovery.rs`). Reads answer from memory as before;
//! - a thread checks the free space on a backoff of 100 ms doubling to 5 s. Once the disk has
//!   twice the reserve free (so the reserve's own removal never ends the state), it writes the
//!   reserve again and the store leaves the state.
//!
//! One log line on entering and one on leaving. A daemon opened with less than twice the reserve
//! free and no reserve starts in the full state.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The reserve file, in the store's home.
pub(crate) const RESERVE: &str = "journal-reserve";
/// The reserve's size: room for the records appended before the first failure (a reply's few
/// records; the journal's queue holds at most `max_pending_bytes`, 64 MiB, which a full disk with
/// a large backlog waits out until space returns, still without stopping).
pub(super) const RESERVE_BYTES: u64 = if cfg!(test) { 64 << 10 } else { 8 << 20 };
const RETRY_MIN: Duration = Duration::from_millis(100);
const RETRY_MAX: Duration = Duration::from_secs(5);

pub(super) struct Space {
    home: PathBuf,
    full: AtomicBool,
    /// The store ends: the retry thread stops.
    ending: Arc<AtomicBool>,
}

impl Space {
    /// Keeps the reserve there, or writes one when the disk has room; else the store starts full.
    pub(super) fn open(home: &Path, ending: Arc<AtomicBool>) -> Arc<Self> {
        let space =
            Arc::new(Self { home: home.to_path_buf(), full: AtomicBool::new(false), ending });
        let path = space.reserve_path();
        let kept = crate::home_fs::symlink_metadata(&path).is_ok_and(|m| m.len() >= RESERVE_BYTES);
        if !kept && !space.make_reserve() {
            space.enter("the disk had no room for the journal's reserve at start");
        }
        space
    }

    pub(super) fn is_full(&self) -> bool {
        self.full.load(Ordering::SeqCst)
    }

    /// The refusal of a write while full: its message names the disk as full
    /// (`recovery::is_disk_full`), so the request's answer is typed `disk.full`.
    pub(super) fn refuse(&self) -> anyhow::Result<()> {
        if !self.is_full() {
            return Ok(());
        }
        Err(anyhow::anyhow!(
            "no space left on device: {} is full; acpmux stores nothing until it has {} MiB free",
            self.home.display(),
            (2 * RESERVE_BYTES) >> 20
        ))
    }

    /// Enters the full state, once until it leaves: the reserve goes, and a thread waits for
    /// space. Quick: called on the journal writer's thread.
    pub(super) fn enter(self: &Arc<Self>, why: &str) {
        if self.full.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = crate::home_fs::remove_file(self.reserve_path());
        tracing::warn!(
            home = %self.home.display(),
            free_bytes = self.free(),
            "the disk is full ({why}): acpmux keeps answering, refuses each change until there \
             is room, and keeps every change it acknowledged"
        );
        let space = Arc::clone(self);
        let started = std::thread::Builder::new()
            .name("acpmux-disk-full".into())
            .spawn(move || space.wait_for_room());
        if let Err(error) = started {
            // No thread: the state ends at the next open; the store still refuses at once.
            tracing::error!("start the full disk's retry thread: {error}");
        }
    }

    fn wait_for_room(&self) {
        let mut backoff = RETRY_MIN;
        loop {
            std::thread::sleep(backoff);
            if self.ending.load(Ordering::SeqCst) {
                return;
            }
            if self.free() >= 2 * RESERVE_BYTES && self.make_reserve() {
                self.full.store(false, Ordering::SeqCst);
                tracing::info!(
                    home = %self.home.display(),
                    free_bytes = self.free(),
                    "the disk has room again: acpmux stores changes again"
                );
                return;
            }
            backoff = backoff.saturating_mul(2).min(RETRY_MAX);
        }
    }

    fn reserve_path(&self) -> PathBuf {
        self.home.join(RESERVE)
    }

    fn free(&self) -> u64 {
        #[cfg(test)]
        if let Some(free) = test_free(&self.home) {
            return free;
        }
        crate::recovery::space(&self.home).map_or(u64::MAX, |space| space.free)
    }

    /// Writes the reserve whole (allocated, so its removal frees that much), when the disk has
    /// twice its size free. False when it could not.
    fn make_reserve(&self) -> bool {
        if self.free() < 2 * RESERVE_BYTES {
            return false;
        }
        let path = self.reserve_path();
        let made = (|| -> std::io::Result<()> {
            let mut file = crate::home_fs::create_file(&path)?;
            let zeros = vec![0u8; 1 << 20];
            let mut left = RESERVE_BYTES;
            while left > 0 {
                let n = usize::try_from(left.min(1 << 20)).unwrap_or(1 << 20);
                file.write_all(zeros.get(..n).unwrap_or(&zeros))?;
                left -= n as u64;
            }
            file.sync_all()
        })();
        match made {
            Ok(()) => true,
            Err(error) => {
                let _ = crate::home_fs::remove_file(&path);
                tracing::warn!("write the journal's disk reserve {}: {error}", path.display());
                false
            }
        }
    }
}

/// Tests: the free bytes each home's check reads instead of `statvfs`'s.
#[cfg(test)]
static TEST_FREE: std::sync::Mutex<std::collections::BTreeMap<PathBuf, u64>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

#[cfg(test)]
fn test_free(home: &Path) -> Option<u64> {
    TEST_FREE.lock().unwrap_or_else(|e| e.into_inner()).get(home).copied()
}

/// Tests: the free bytes the store in `home` reads (None: `statvfs`'s).
#[cfg(test)]
pub(crate) fn set_test_free(home: &Path, free: Option<u64>) {
    let mut map = TEST_FREE.lock().unwrap_or_else(|e| e.into_inner());
    match free {
        Some(free) => drop(map.insert(home.to_path_buf(), free)),
        None => drop(map.remove(home)),
    }
}

/// A full disk or quota anywhere in the error's chain.
pub(super) fn is_out_of_space(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| cause.downcast_ref::<std::io::Error>().is_some_and(io_out_of_space))
}

fn io_out_of_space(error: &std::io::Error) -> bool {
    if matches!(error.kind(), std::io::ErrorKind::StorageFull | std::io::ErrorKind::QuotaExceeded) {
        return true;
    }
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(code) if code == libc::ENOSPC || code == libc::EDQUOT) {
        return true;
    }
    false
}
