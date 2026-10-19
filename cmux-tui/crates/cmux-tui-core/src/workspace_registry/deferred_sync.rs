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
//! every one of its commits is durable. (In WAL mode SQLite still syncs the
//! WAL before a checkpoint, the database after it, and a reused WAL's
//! header under NORMAL, with `F_FULLFSYNC` when `fullfsync` is on.)
//!
//! The rule that keeps durability what it was: nothing an unsynced commit
//! wrote reaches anyone except the thread that committed it before the WAL
//! is synced. Every way out of the creating thread passes a barrier
//! ([`DeferredSync::sync_for_reader`]) that waits until the WAL is synced
//! past everything written so far:
//! - another thread that takes the registry connection
//!   ([`DeferredSync::acquired`]), the workspace registry, the mux state lock
//!   or the presentation cache (the creating thread installs committed
//!   revisions and rows there);
//! - the session journal reader connections, after each read and before its
//!   rows or head go anywhere (`SessionJournalReader`, found through
//!   [`for_database`]);
//! - the creating thread itself holds its mux events and journal wakeups
//!   until its scope has synced (`crate::mux::create_txn`), and activates the
//!   new terminal and answers its request only after that.
//!
//! So a power loss (the only failure that can drop unsynced commits) drops
//! only commits that no one saw: those of a creation that was never
//! answered, which recovery already treats like a creation interrupted by a
//! daemon crash. Nothing that was published (a revision, a journal sequence,
//! a reply) can be reused after the restart.
//!
//! A failed WAL sync ends the daemon at once ([`fatal_sync_failure`]): after
//! a failed fsync the kernel may have dropped the dirty pages, so neither a
//! retry nor going on can make the commits durable, and something may
//! already have read them. Terminal hosts are separate processes and
//! survive; the next daemon adopts them, as after a crash.
//!
//! The barrier counts committed holds, not commits: a connection hold that
//! changed rows (`total_changes`, so a write that changes no row, such as
//! DDL, is not counted; creations write only rows) raises `written`, and a
//! sync raises `synced` to what was written when it started.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};

use rusqlite::Connection;

/// Group commit state of one registry connection.
#[derive(Default)]
pub(crate) struct DeferredSync {
    /// The WAL file of an on-disk WAL-mode registry. Unset (in-memory and
    /// non-WAL registries): nothing is ever deferred.
    wal: OnceLock<PathBuf>,
    /// Serializes syncs; a reader that finds a sync running waits for it.
    sync_lock: Mutex<()>,
    /// NORMAL holds that changed rows, counted when the hold ends.
    written: AtomicU64,
    /// `written` as it was when the last successful sync started.
    synced: AtomicU64,
    /// A deferring thread holds the connection in NORMAL mode now; what it
    /// committed during this hold is not counted in `written` yet.
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

/// The group commit state of every open registry database of this process,
/// by WAL file, for the other connections on that database
/// ([`for_database`]).
static DATABASES: Mutex<Vec<(PathBuf, Weak<DeferredSync>)>> = Mutex::new(Vec::new());

/// The group commit state of the registry whose database is `database`, if
/// this process has it open: a separate connection on the same file (the
/// session journal readers) passes its barrier before it hands out rows.
pub(crate) fn for_database(database: &Path) -> Option<Arc<DeferredSync>> {
    let wal = wal_path(database);
    let mut databases = DATABASES.lock().unwrap_or_else(PoisonError::into_inner);
    databases.retain(|(_, sync)| sync.strong_count() > 0);
    databases.iter().find(|(path, _)| *path == wal).and_then(|(_, sync)| sync.upgrade())
}

/// The WAL file SQLite uses for `database` (it resolves symlinks).
pub(crate) fn wal_path(database: &Path) -> PathBuf {
    let database = std::fs::canonicalize(database).unwrap_or_else(|_| database.to_path_buf());
    let mut wal = database.into_os_string();
    wal.push("-wal");
    PathBuf::from(wal)
}

/// The current thread defers the WAL sync of its commits on one registry
/// connection until [`DeferScope::finish`] (or drop, which syncs too).
pub(crate) struct DeferScope {
    sync: Arc<DeferredSync>,
    open: bool,
}

impl DeferScope {
    /// End the scope and make every commit it made durable.
    pub(crate) fn finish(mut self) {
        self.close();
    }

    fn close(&mut self) {
        if !std::mem::replace(&mut self.open, false) {
            return;
        }
        let key = self.sync.key();
        DEFERRING.with(|deferring| {
            let mut deferring = deferring.borrow_mut();
            if let Some(index) = deferring.iter().rposition(|entry| *entry == key) {
                deferring.remove(index);
            }
        });
        self.sync.sync();
    }
}

impl Drop for DeferScope {
    fn drop(&mut self) {
        self.close();
    }
}

impl DeferredSync {
    fn key(&self) -> usize {
        self as *const Self as usize
    }

    /// Defer commits of an on-disk WAL registry whose WAL file is `wal`.
    pub(crate) fn enable(self: &Arc<Self>, wal: PathBuf) {
        if self.wal.set(wal.clone()).is_ok() {
            let mut databases = DATABASES.lock().unwrap_or_else(PoisonError::into_inner);
            databases.retain(|(_, sync)| sync.strong_count() > 0);
            databases.push((wal, Arc::downgrade(self)));
        }
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
    fn needs_sync(&self) -> bool {
        self.written.load(Ordering::SeqCst) > self.synced.load(Ordering::SeqCst)
            || self.normal_hold.load(Ordering::SeqCst)
    }

    /// Make every commit written so far durable: return once a sync that
    /// started after it was written has finished (this one, or one another
    /// thread was running). Ends the daemon when the sync fails.
    pub(crate) fn sync(&self) {
        let Some(wal) = self.wal.get() else { return };
        if !self.needs_sync() {
            return;
        }
        let _sync = self.sync_lock.lock().unwrap_or_else(PoisonError::into_inner);
        // Read under the lock: a sync that finished while this thread waited
        // may already cover everything.
        let target = self.written.load(Ordering::SeqCst);
        let hold = self.normal_hold.load(Ordering::SeqCst);
        if target <= self.synced.load(Ordering::SeqCst) && !hold {
            return;
        }
        crate::debug_spans::mark("registry.wal_sync");
        if let Err(error) = sync_wal_file(wal) {
            fatal_sync_failure(wal, &error);
        }
        // Commits of a hold still open when the sync started are counted
        // when the hold ends, so they get a sync of their own then.
        self.synced.fetch_max(target, Ordering::SeqCst);
        self.syncs.fetch_add(1, Ordering::Relaxed);
        crate::debug_spans::mark("registry.wal_synced");
    }

    /// The barrier before a thread that is not deferring reads what a
    /// deferring thread may have published (see the module docs).
    pub(crate) fn sync_for_reader(&self) {
        if self.needs_sync() && !self.defers_here() {
            self.sync();
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
    /// thread: a thread that does not defer passes the barrier before it
    /// reads or writes, and the connection's `synchronous` mode is set for
    /// the new holder.
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
        if !defer {
            self.sync();
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
            self.normal_hold.store(true, Ordering::SeqCst);
        }
    }

    fn after_hold(&self, connection: &Connection) {
        if !self.normal.load(Ordering::Relaxed) {
            return;
        }
        let changed = connection.total_changes() != self.changes_at_hold.load(Ordering::Relaxed);
        // Counted before the hold flag clears, so a reader always sees one.
        if changed {
            self.written.fetch_add(1, Ordering::SeqCst);
        }
        self.normal_hold.store(false, Ordering::SeqCst);
        if changed && !self.defers_here() {
            self.sync();
        }
    }
}

/// A WAL sync failed: end the daemon before anything else reads what the
/// sync was to make durable (see the module docs).
fn fatal_sync_failure(wal: &Path, error: &std::io::Error) -> ! {
    eprintln!(
        "cmux-tui: registry WAL sync of {} failed: {error}; stopping so that no unsynced \
         commit is published (terminal hosts keep running for the next daemon)",
        wal.display()
    );
    std::process::abort()
}

/// Sync the WAL file the way SQLite's FULL commit does: F_FULLFSYNC on
/// Apple platforms (`File::sync_data`), fdatasync elsewhere. Unit tests run
/// the registry with `fullfsync=OFF` (workspace_registry.rs), so they use a
/// plain fsync on Apple platforms too. A missing WAL file while commits are
/// unsynced is an error: the registry connection keeps it open, so the path
/// is wrong or the file was removed under the daemon.
fn sync_wal_file(wal: &Path) -> std::io::Result<()> {
    let file = std::fs::OpenOptions::new().write(true).open(wal)?;
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
