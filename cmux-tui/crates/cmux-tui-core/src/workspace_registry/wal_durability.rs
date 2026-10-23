//! Registry durability off the request path: group F_FULLFSYNC of the WAL.
//!
//! Every registry commit runs in WAL mode with `synchronous=NORMAL`: the
//! commit's frames are in the WAL file (the kernel's page cache) when
//! `COMMIT` returns. That already survives a crash, kill or restart of the
//! daemon; SQLite keeps WAL+NORMAL consistent across a power loss too, where
//! a lost tail of commits is lost whole. Only a power loss or kernel panic
//! can take an acknowledged commit back, and on such a loss every terminal,
//! host and shell the commit described is gone as well.
//!
//! So no request waits for the disk. Each commit wakes this syncer
//! ([`WalDurability::note_commit`]); its thread flushes the WAL file with
//! one F_FULLFSYNC (fdatasync off macOS) for every commit made since its
//! last flush, outside every lock. Before, each commit flushed with
//! `synchronous=FULL` while it held the registry connection lock: about
//! 4.5 ms per commit on a fleet M4 Pro, one to three of them on every
//! create and close reply, and every other request that needed the lock
//! waited behind them (daemon request p95 60-80 ms, PL-daemon 2026-10-23).
//!
//! The thread sleeps on a condition variable while nothing is owed (no
//! timer, no wakeups at idle). [`WalDurability::wait_durable`] waits until
//! every commit made so far is on disk, for callers that must order an
//! effect after power-loss durability and for tests.

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::panic_free::RecoverPoison;

/// Commit counters shared with the syncer thread.
#[derive(Default)]
struct SyncState {
    /// Commits made on the registry connection.
    committed: u64,
    /// Commits known to be on disk.
    synced: u64,
    /// The registry closed: the thread flushes what is owed and ends.
    stopping: bool,
}

struct Shared {
    wal_path: PathBuf,
    state: Mutex<SyncState>,
    changed: Condvar,
    /// `CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS`: each flush takes this much
    /// longer, as on a busy disk.
    slow_flush: Option<Duration>,
}

/// The syncer of one registry database (see the module docs).
pub(crate) struct WalDurability {
    shared: Arc<Shared>,
}

impl WalDurability {
    /// Start the syncer for the database at `database_path` (its WAL is
    /// `<database_path>-wal`).
    pub(crate) fn start(database_path: &std::path::Path, slow_flush: Option<Duration>) -> Self {
        let mut wal_path = database_path.as_os_str().to_owned();
        wal_path.push("-wal");
        let shared = Arc::new(Shared {
            wal_path: PathBuf::from(wal_path),
            state: Mutex::new(SyncState::default()),
            changed: Condvar::new(),
            slow_flush,
        });
        let thread_shared = shared.clone();
        let spawned = std::thread::Builder::new()
            .name("registry-wal-sync".into())
            .spawn(move || run(&thread_shared));
        if let Err(error) = spawned {
            // Without the thread, commits stay crash safe (WAL+NORMAL) but
            // a power loss may roll back more of them; say so once.
            eprintln!("cmux-tui: registry WAL syncer did not start: {error}");
            shared.state.lock().recover_poison().stopping = true;
        }
        Self { shared }
    }

    /// One more commit is in the WAL; flush it soon.
    pub(crate) fn note_commit(&self) {
        let mut state = self.shared.state.lock().recover_poison();
        state.committed += 1;
        drop(state);
        self.shared.changed.notify_all();
    }

    /// Wait until every commit made before this call is on disk. Never call
    /// it while holding the registry connection lock: commits made under the
    /// lock are counted only when their guard is released.
    pub(crate) fn wait_durable(&self) {
        let mut state = self.shared.state.lock().recover_poison();
        let target = state.committed;
        while state.synced < target && !state.stopping {
            state = self.shared.changed.wait(state).recover_poison();
        }
        if state.synced < target {
            // The thread is gone: flush on this thread.
            drop(state);
            flush(&self.shared);
            let mut state = self.shared.state.lock().recover_poison();
            state.synced = state.synced.max(target);
        }
    }

    /// (committed, synced) commit counts, for `server-stats` `write_path`.
    pub(crate) fn counts(&self) -> (u64, u64) {
        let state = self.shared.state.lock().recover_poison();
        (state.committed, state.synced)
    }
}

impl Drop for WalDurability {
    /// The registry closes (daemon shutdown): flush what is owed on this
    /// thread, so a clean exit never leaves a commit only in the page cache.
    fn drop(&mut self) {
        let owed = {
            let mut state = self.shared.state.lock().recover_poison();
            state.stopping = true;
            state.synced < state.committed
        };
        self.shared.changed.notify_all();
        if owed {
            flush(&self.shared);
        }
    }
}

fn run(shared: &Shared) {
    let mut state = shared.state.lock().recover_poison();
    loop {
        while state.committed == state.synced && !state.stopping {
            state = shared.changed.wait(state).recover_poison();
        }
        if state.committed == state.synced {
            return;
        }
        let target = state.committed;
        drop(state);
        flush(shared);
        state = shared.state.lock().recover_poison();
        state.synced = state.synced.max(target);
        shared.changed.notify_all();
    }
}

/// Flush the WAL file to stable storage. A missing WAL was checkpointed
/// into the database and removed, which SQLite syncs itself.
fn flush(shared: &Shared) {
    if let Some(delay) = shared.slow_flush {
        std::thread::sleep(delay);
    }
    let file = match File::options().read(true).write(true).open(&shared.wal_path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => {
            eprintln!("cmux-tui: open registry WAL for its flush failed: {error}");
            return;
        }
    };
    if let Err(error) = full_sync(&file) {
        eprintln!("cmux-tui: registry WAL flush failed: {error}");
    }
}

/// F_FULLFSYNC on macOS (the device cache too, as SQLite's `fullfsync=ON`),
/// else fdatasync. Unit tests use a plain fsync, as their registries do
/// (`REGISTRY_FULLFSYNC_PRAGMA`).
fn full_sync(file: &File) -> std::io::Result<()> {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: fcntl on an fd this function borrows for the call.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } == 0 {
            return Ok(());
        }
        // Some file systems refuse F_FULLFSYNC; SQLite falls back the same way.
        file.sync_data()
    }
    #[cfg(not(all(target_os = "macos", not(test))))]
    {
        file.sync_data()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wait_durable_returns_after_the_flush_of_every_earlier_commit() {
        let dir = std::env::temp_dir().join(format!("wal-durability-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("r.sqlite");
        std::fs::write(dir.join("r.sqlite-wal"), b"frames").unwrap();
        let durability = WalDurability::start(&db, None);
        durability.note_commit();
        durability.note_commit();
        durability.wait_durable();
        assert_eq!(durability.counts(), (2, 2));
        drop(durability);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_commit_does_not_wait_for_a_slow_flush() {
        let dir = std::env::temp_dir().join(format!("wal-durability-slow-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("r.sqlite");
        let durability = WalDurability::start(&db, Some(Duration::from_millis(300)));
        let started = std::time::Instant::now();
        durability.note_commit();
        assert!(started.elapsed() < Duration::from_millis(100));
        durability.wait_durable();
        assert!(started.elapsed() >= Duration::from_millis(300));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
