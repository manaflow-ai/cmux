//! SQLite page caches given back under memory pressure (`memorySqliteTrim`).
//!
//! Chrome's `sql::Database` registers a memory pressure listener per
//! connection and its `TrimMemory()` (sql/database.cc) calls
//! `sqlite3_db_release_memory` on that connection, on the connection's own
//! sequence; it never calls the process-wide `sqlite3_release_memory`. Here
//! each long-lived connection of the owner is one lossless consumer in the
//! owner's memory registry (`Mux::memory`). At warning and at critical its
//! release posts one item to the mux's Files lane at best-effort priority;
//! the item takes only that connection's own lock, the one every user of the
//! connection holds, so it is the connection's only user while it frees.
//! The pressure source's thread never touches SQLite, and no request thread
//! and no request lock (the workspace registry, state) is involved. The
//! history search worker frees its own connection on its own thread.
//!
//! A release frees only clean pages no statement holds; the next query reads
//! them again from the file or the kernel's cache, so nothing is lost. The
//! consumers report no byte count: reading `SQLITE_DBSTATUS_CACHE_USED`
//! needs the connection's lock, and a memory report never waits for one.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, Weak};

use cmux_memory::{MemoryConsumer, PressureLevel, Registration, Retention};
use cmux_threads::work::{Lane, Priority, Shutdown};

use super::Mux;

/// One long-lived SQLite connection (or set of connections) of the owner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TrimTarget {
    /// The workspace registry and session journal (`RegistryConnection`).
    Registry,
    /// `conversations.sqlite3` (`ConversationHost`).
    Conversations,
    /// The Chief registry (`ChiefHost`).
    Chiefs,
    /// `apps-storage.sqlite` (`apps::Supervisor`).
    AppStorage,
    /// The machine's per-profile page visit logs (`history_ops::pages`).
    HistoryVisits,
    /// The history search index's reader and indexing worker.
    HistorySearch,
}

impl TrimTarget {
    pub(crate) const ALL: [Self; 6] = [
        Self::Registry,
        Self::Conversations,
        Self::Chiefs,
        Self::AppStorage,
        Self::HistoryVisits,
        Self::HistorySearch,
    ];

    /// The consumer's name in the memory report.
    pub(crate) const fn consumer_name(self) -> &'static str {
        match self {
            Self::Registry => "sqlite.registry",
            Self::Conversations => "sqlite.conversations",
            Self::Chiefs => "sqlite.chiefs",
            Self::AppStorage => "sqlite.app-storage",
            Self::HistoryVisits => "sqlite.history-visits",
            Self::HistorySearch => "sqlite.history-search",
        }
    }

    /// Frees the target's page cache under its own lock. A store that is
    /// not open holds no cache and stays closed.
    fn release(self, mux: &Mux) -> anyhow::Result<()> {
        match self {
            Self::Registry => mux.registry_connection.release_memory()?,
            Self::Conversations => mux.conversations.release_memory()?,
            Self::Chiefs => mux.chiefs.release_memory()?,
            #[cfg(unix)]
            Self::AppStorage => {
                mux.control_clients
                    .apps()
                    .release_memory()
                    .map_err(|e| anyhow::anyhow!(e.message))?;
            }
            #[cfg(not(unix))]
            Self::AppStorage => {}
            Self::HistoryVisits => crate::history_ops::release_visit_store_memory(mux)?,
            Self::HistorySearch => {
                if let Some(search) = mux.history_search.get() {
                    search.release_memory()?;
                }
            }
        }
        Ok(())
    }
}

/// The owner's SQLite consumers, registered once by [`Mux::start_sqlite_trim`].
#[derive(Default)]
pub(crate) struct SqliteTrim {
    registrations: OnceLock<Vec<Registration>>,
    /// Per target: a release item is queued and has not started, so a burst
    /// of level changes queues one.
    queued: [AtomicBool; TrimTarget::ALL.len()],
    /// Hears each finished release with the thread it ran on.
    #[cfg(test)]
    pub(super) observer: OnceLock<std::sync::mpsc::SyncSender<TrimRun>>,
}

impl SqliteTrim {
    /// `target`'s queued flag: one per [`TrimTarget`], named so no index can
    /// fall outside the array.
    fn queued(&self, target: TrimTarget) -> &AtomicBool {
        let [registry, conversations, chiefs, app_storage, history_visits, history_search] =
            &self.queued;
        match target {
            TrimTarget::Registry => registry,
            TrimTarget::Conversations => conversations,
            TrimTarget::Chiefs => chiefs,
            TrimTarget::AppStorage => app_storage,
            TrimTarget::HistoryVisits => history_visits,
            TrimTarget::HistorySearch => history_search,
        }
    }
}

/// A release as the test observer sees it.
#[cfg(test)]
#[derive(Debug)]
pub(super) struct TrimRun {
    pub(super) target: TrimTarget,
    pub(super) thread: Option<String>,
}

impl Mux {
    /// Registers the owner's SQLite connections as memory consumers and
    /// starts the kernel pressure source, when `features` turns
    /// `memorySqliteTrim` on. Call it once the mux is built.
    pub fn start_sqlite_trim(self: &Arc<Self>, features: &cmux_features::Snapshot) {
        if features.is_enabled(cmux_features::feature::MEMORY_SQLITE_TRIM) {
            self.register_sqlite_trim();
            self.memory.watch_system_pressure();
        }
    }

    /// Registers one lossless consumer per [`TrimTarget`], once.
    pub(crate) fn register_sqlite_trim(self: &Arc<Self>) {
        self.sqlite_trim.registrations.get_or_init(|| {
            TrimTarget::ALL
                .into_iter()
                .map(|target| {
                    let mux = Arc::downgrade(self);
                    let consumer = MemoryConsumer::new(
                        target.consumer_name(),
                        Retention::Lossless,
                        || None,
                        move |level| {
                            if level != PressureLevel::Normal {
                                queue_release(&mux, target);
                            }
                        },
                    );
                    self.memory.registry().register(consumer)
                })
                .collect()
        });
    }
}

/// Queues `target`'s release on the mux's Files lane unless one is queued.
/// Runs on the pressure source's thread: it only posts.
fn queue_release(mux: &Weak<Mux>, target: TrimTarget) {
    let Some(mux) = mux.upgrade() else { return };
    if mux.sqlite_trim.queued(target).swap(true, Ordering::AcqRel) {
        return;
    }
    let posted = mux.post_mux_work(
        Priority::BestEffort,
        Lane::Files,
        Shutdown::SkipOnShutdown,
        move |mux| {
            let Some(mux) = mux.upgrade() else { return };
            mux.sqlite_trim.queued(target).store(false, Ordering::Release);
            run_release(&mux, target);
        },
    );
    if posted.is_err() {
        mux.sqlite_trim.queued(target).store(false, Ordering::Release);
    }
}

/// One release on a Files lane worker: never inside a request scope.
fn run_release(mux: &Mux, target: TrimTarget) {
    debug_assert!(
        !cmux_tui_platform::request_path::in_scope(),
        "a SQLite page cache release ran on a request path"
    );
    if let Err(error) = target.release(mux) {
        eprintln!("cmux-tui: {} page cache release failed: {error:#}", target.consumer_name());
    }
    #[cfg(test)]
    if let Some(observer) = mux.sqlite_trim.observer.get() {
        let thread = std::thread::current().name().map(str::to_owned);
        let _ = observer.try_send(TrimRun { target, thread });
    }
}

#[cfg(test)]
#[path = "sqlite_trim_tests.rs"]
mod tests;
