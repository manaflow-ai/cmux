//! One WAL sync per creation (create-txn).
//!
//! Every registry commit runs with `synchronous=FULL` (and `fullfsync` on
//! macOS), so each commit pays its own WAL sync. A terminal or workspace
//! creation commits up to seven times in a row (receipt prepared, executing,
//! workspace row, terminal reserved, relaunch record, terminal ready,
//! projection): about 22 ms of a 45 ms create on an M6 Mac mini.
//!
//! A thread inside a [`DeferScope`] commits with `synchronous=NORMAL`
//! instead. Each of its commits is still a complete SQLite commit in the
//! WAL: the bytes are in the kernel when the commit returns, so a crash of
//! the daemon alone loses none of them, exactly as before. Only the sync is
//! left out. The scope syncs the WAL file once when it ends
//! ([`DeferredSync::sync`]); one sync of the file makes every commit written
//! to it before the sync durable, so the creation still answers only after
//! every one of its commits is durable.
//!
//! The rule that keeps durability what it was: nothing an unsynced commit
//! wrote reaches anyone except the thread that committed it before the WAL
//! is synced.
//! - Another thread that takes the registry connection syncs first
//!   ([`DeferredSync::before_hold`]), and so does another thread that takes
//!   the mux state lock or the presentation cache
//!   ([`DeferredSync::sync_for_reader`]): the creating thread installs
//!   committed revisions there.
//! - The creating thread holds its mux events and journal wakeups until its
//!   scope has synced (`crate::mux::create_txn`), and activates the new
//!   terminal and answers its request only after that.
//!
//! So a power loss (the only failure that can drop unsynced commits) drops
//! only commits that no one saw: those of a creation that was never
//! answered, which recovery already treats like a creation interrupted by a
//! daemon crash. Nothing that was published (a revision, a journal sequence,
//! a reply) can be reused after the restart.

use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use rusqlite::Connection;

/// Group commit state of one registry connection.
#[derive(Default)]
pub(crate) struct DeferredSync {
    /// The WAL file of an on-disk WAL-mode registry. Unset (in-memory and
    /// non-WAL registries): nothing is ever deferred.
    wal: OnceLock<PathBuf>,
    /// Serializes syncs.
    sync_lock: Mutex<()>,
    /// A completed NORMAL commit may not be synced yet.
    unsynced: AtomicBool,
    /// A deferring thread holds the connection in NORMAL mode now: what it
    /// committed during this hold is not marked in `unsynced` yet.
    normal_hold: AtomicBool,
    /// The connection runs `synchronous=NORMAL`. Changed only by the thread
    /// that holds the connection lock.
    normal: AtomicBool,
    /// `total_changes` of the connection when the current NORMAL hold began.
    changes_at_hold: AtomicU64,
    /// Nesting depth of the current holder's connection holds (the lock is
    /// reentrant). Changed only by the holder.
    holds: AtomicUsize,
    /// WAL syncs performed (diagnostics).
    syncs: AtomicU64,
}

thread_local! {
    /// The `DeferredSync`s this thread defers commits on, one entry per open
    /// scope (scopes nest).
    static DEFERRING: RefCell<Vec<usize>> = const { RefCell::new(Vec::new()) };
}

/// The current thread defers the WAL sync of its commits on one registry
/// connection until [`DeferScope::finish`] (or drop, which syncs too).
pub(crate) struct DeferScope {
    sync: Arc<DeferredSync>,
    open: bool,
}

impl DeferScope {
    /// End the scope and sync every commit it made. An error leaves the
    /// commits in place (they are committed, durability is unknown) and
    /// marked unsynced, so the next sync retries.
    pub(crate) fn finish(mut self) -> std::io::Result<()> {
        self.close()
    }

    fn close(&mut self) -> std::io::Result<()> {
        if !std::mem::replace(&mut self.open, false) {
            return Ok(());
        }
        let key = self.sync.key();
        DEFERRING.with(|deferring| {
            let mut deferring = deferring.borrow_mut();
            if let Some(index) = deferring.iter().rposition(|entry| *entry == key) {
                deferring.remove(index);
            }
        });
        if self.sync.needs_sync() { self.sync.sync() } else { Ok(()) }
    }
}

impl Drop for DeferScope {
    fn drop(&mut self) {
        if let Err(error) = self.close() {
            eprintln!("cmux-tui: registry WAL sync after a creation failed: {error}");
        }
    }
}

impl DeferredSync {
    fn key(&self) -> usize {
        self as *const Self as usize
    }

    /// Defer commits of an on-disk WAL registry whose WAL file is `wal`.
    pub(crate) fn enable(&self, wal: PathBuf) {
        let _ = self.wal.set(wal);
    }

    /// Open a scope on the current thread. On a registry without a WAL
    /// file the scope defers nothing.
    pub(crate) fn scope(self: &Arc<Self>) -> DeferScope {
        DEFERRING.with(|deferring| deferring.borrow_mut().push(self.key()));
        DeferScope { sync: self.clone(), open: true }
    }

    /// True while the current thread has a scope open on this connection.
    pub(crate) fn defers_here(&self) -> bool {
        self.wal.get().is_some()
            && DEFERRING.with(|deferring| deferring.borrow().contains(&self.key()))
    }

    /// Some commit may be written to the WAL without a sync.
    pub(crate) fn needs_sync(&self) -> bool {
        self.unsynced.load(Ordering::SeqCst) || self.normal_hold.load(Ordering::SeqCst)
    }

    /// Sync the WAL file. Every commit written before the call is durable
    /// when it returns `Ok`.
    pub(crate) fn sync(&self) -> std::io::Result<()> {
        let Some(wal) = self.wal.get() else { return Ok(()) };
        let _sync = self.sync_lock.lock().unwrap_or_else(PoisonError::into_inner);
        // Cleared before the sync: a commit marked after this point keeps
        // the flag for the next sync.
        let was_unsynced = self.unsynced.swap(false, Ordering::SeqCst);
        if !was_unsynced && !self.normal_hold.load(Ordering::SeqCst) {
            return Ok(());
        }
        crate::debug_spans::mark("registry.wal_sync");
        let result = sync_wal_file(wal);
        if result.is_err() {
            self.unsynced.store(true, Ordering::SeqCst);
        }
        self.syncs.fetch_add(1, Ordering::Relaxed);
        crate::debug_spans::mark("registry.wal_synced");
        result
    }

    /// Before a thread that is not deferring reads what a deferring thread
    /// may have published in shared memory (mux state, presentation): sync
    /// its commits first.
    pub(crate) fn sync_for_reader(&self) {
        if self.needs_sync()
            && !self.defers_here()
            && let Err(error) = self.sync()
        {
            eprintln!("cmux-tui: registry WAL sync before a read failed: {error}");
        }
    }

    /// The connection commits without a sync now (debug timing marks).
    pub(crate) fn commits_deferred(&self) -> bool {
        self.normal.load(Ordering::Relaxed)
    }

    /// WAL syncs performed so far.
    #[allow(dead_code)]
    pub(crate) fn sync_count(&self) -> u64 {
        self.syncs.load(Ordering::Relaxed)
    }

    /// The connection lock was just taken. On the first hold of this
    /// thread: a thread that does not defer syncs what a deferring thread
    /// left unsynced before it reads or writes, and the connection's
    /// `synchronous` mode is set for the new holder.
    pub(crate) fn acquired(&self, connection: &Connection) {
        if self.holds.fetch_add(1, Ordering::Relaxed) == 0 {
            self.before_hold(connection);
        }
    }

    /// A hold of the connection lock ends (the lock is still held).
    pub(crate) fn releasing(&self, connection: &Connection) {
        if self.holds.fetch_sub(1, Ordering::Relaxed) == 1 {
            self.after_hold(connection);
        }
    }

    fn before_hold(&self, connection: &Connection) {
        if self.wal.get().is_none() {
            return;
        }
        let defer = self.defers_here();
        if !defer
            && self.needs_sync()
            && let Err(error) = self.sync()
        {
            eprintln!("cmux-tui: registry WAL sync before a connection hold failed: {error}");
        }
        if defer != self.normal.load(Ordering::Relaxed) {
            let pragma =
                if defer { "PRAGMA synchronous=NORMAL;" } else { "PRAGMA synchronous=FULL;" };
            match connection.execute_batch(pragma) {
                Ok(()) => self.normal.store(defer, Ordering::Relaxed),
                // A failed switch to NORMAL keeps FULL. A failed switch back
                // to FULL keeps NORMAL, and `after_hold` syncs this hold's
                // commits itself.
                Err(error) => eprintln!("cmux-tui: registry {pragma} failed: {error}"),
            }
        }
        if self.normal.load(Ordering::Relaxed) {
            self.changes_at_hold.store(connection.total_changes(), Ordering::Relaxed);
            if defer {
                self.normal_hold.store(true, Ordering::SeqCst);
            }
        }
    }

    fn after_hold(&self, connection: &Connection) {
        if !self.normal.load(Ordering::Relaxed) {
            return;
        }
        let changed = connection.total_changes() != self.changes_at_hold.load(Ordering::Relaxed);
        // Marked before the hold flag clears, so a reader always sees one.
        if changed {
            self.unsynced.store(true, Ordering::SeqCst);
        }
        self.normal_hold.store(false, Ordering::SeqCst);
        if changed
            && !self.defers_here()
            && let Err(error) = self.sync()
        {
            eprintln!("cmux-tui: registry WAL sync after a NORMAL commit failed: {error}");
        }
    }
}

/// Sync the WAL file the way SQLite's FULL commit does: F_FULLFSYNC on
/// Apple platforms (`File::sync_data`), fdatasync elsewhere. Unit tests run
/// the registry with `fullfsync=OFF` (workspace_registry.rs), so they use a
/// plain fsync on Apple platforms too.
fn sync_wal_file(wal: &std::path::Path) -> std::io::Result<()> {
    let file = match std::fs::OpenOptions::new().write(true).open(wal) {
        Ok(file) => file,
        // No WAL file: nothing was written since the last checkpoint reset.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    #[cfg(all(test, target_vendor = "apple"))]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: `file` owns the descriptor for the duration of the call.
        if unsafe { libc::fsync(file.as_raw_fd()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
    #[cfg(not(all(test, target_vendor = "apple")))]
    file.sync_data()
}
