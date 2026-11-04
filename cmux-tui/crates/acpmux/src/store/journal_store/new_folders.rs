//! New chats' folders (review of #35483, F1 and F4 at the root): a record that made a chat's
//! folder is acknowledged only once that folder's entry in `sessions/` is synced as well.
//!
//! The replay never makes a chat's folder again (S2's rule for logs, now for metadata too): a
//! folder that is gone was removed by a delete, by a run without the journal or by the transfer
//! recovery, and the chat stays removed. That is safe only if an OS crash can never take back the
//! folder of a chat a client was told about. A new folder's entry is durable at the next sync of
//! `sessions/`; this thread makes that sync at once, at the daemon's disk tier, and the durability
//! the outbound gate waits for (`Store::durability`) passes such a record only after it. A crash
//! before then loses only a chat no reply showed; its records go to `journal-unapplied/`.

use super::*;

/// The folders of new chats whose `sessions/` entry is not synced yet, and the durable LSN the
/// outbound gate reads (the journal's, held below the first such record).
pub(super) struct NewFolders {
    state: Mutex<State>,
    wake: Condvar,
    /// The gate's durable watch. The journal's durable listener owns it, so it closes when the
    /// writer ends (S2c); this thread publishes through it while it is open.
    durable: std::sync::Weak<tokio::sync::watch::Sender<u64>>,
}

#[derive(Default)]
struct State {
    /// LSNs of the records that made a chat's folder, whose entry is not synced yet.
    unsynced: BTreeSet<Lsn>,
    /// The journal's durable LSN, as its writer last reported it.
    journal_durable: Lsn,
    /// A sync of `sessions/` failed: a later one may report success for the entries it dropped,
    /// so none of those chats is ever acknowledged (the checkpoint is frozen, the daemon stops).
    failed: bool,
    stop: bool,
}

impl State {
    /// The LSN through which every record is durable and every new chat's folder synced.
    fn durable(&self) -> Lsn {
        match self.unsynced.first() {
            Some(first) => self.journal_durable.min(first.saturating_sub(1)),
            None => self.journal_durable,
        }
    }

    fn publish(&self, durable: &tokio::sync::watch::Sender<u64>) {
        let value = self.durable();
        durable.send_if_modified(|was| {
            let moved = value > *was;
            if moved {
                *was = value;
            }
            moved
        });
    }
}

impl NewFolders {
    pub(super) fn new(
        durable: std::sync::Weak<tokio::sync::watch::Sender<u64>>,
        journal_durable: Lsn,
    ) -> Self {
        Self {
            state: Mutex::new(State { journal_durable, ..State::default() }),
            wake: Condvar::new(),
            durable,
        }
    }

    /// The journal's durable listener: its writer reports `lsn` durable.
    pub(super) fn journal_durable(&self, lsn: Lsn, durable: &tokio::sync::watch::Sender<u64>) {
        let mut state = self.state.lock_or_recover();
        state.journal_durable = state.journal_durable.max(lsn);
        state.publish(durable);
    }

    /// Appends the record of a save that made the chat's folder (`append`) and holds its LSN
    /// back from the gate until the folder's entry is synced. The LSN is noted under the same
    /// lock as the append: the writer's listener, which needs that lock, cannot report the
    /// record durable before it is noted. (The append is a memory copy that never waits for the
    /// writer, and the writer calls its listeners with none of the journal's locks held.)
    pub(super) fn append_made(&self, append: impl FnOnce() -> Result<Lsn>) -> Result<Lsn> {
        let mut state = self.state.lock_or_recover();
        let lsn = append()?;
        state.unsynced.insert(lsn);
        drop(state);
        self.wake.notify_one();
        Ok(lsn)
    }

    pub(super) fn stop(&self) {
        self.state.lock_or_recover().stop = true;
        self.wake.notify_all();
    }
}

impl Inner {
    /// The folder syncer's thread ([module docs](self)): one sync of `sessions/` for every new
    /// folder noted before it starts, then the gate's durable LSN moves on.
    pub(super) fn run_folder_syncer(&self) {
        let folders = &self.new_folders;
        let mut state = folders.state.lock_or_recover();
        loop {
            state = folders
                .wake
                .wait_while(state, |state| {
                    !state.stop && (state.unsynced.is_empty() || state.failed)
                })
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.stop {
                return;
            }
            let Some(&through) = state.unsynced.last() else { continue };
            drop(state);
            // Each folder noted through `through` was made before its record was appended, so
            // before this sync starts.
            let synced = sync_directory(&self.local.root);
            state = folders.state.lock_or_recover();
            match synced {
                Ok(()) => {
                    state.unsynced.retain(|lsn| *lsn > through);
                    if let Some(durable) = folders.durable.upgrade() {
                        state.publish(&durable);
                    }
                }
                Err(error) if error.chain().any(|cause| cause.is::<SyncFailed>()) => {
                    state.failed = true;
                    drop(state);
                    self.freeze(format!("the sessions folder failed to sync: {error:#}"));
                    state = folders.state.lock_or_recover();
                }
                Err(error) => {
                    // The folder did not open (no file descriptor left): tried again shortly. A
                    // reply that waits for it past the gate's stall limit stops the daemon.
                    tracing::warn!("sync {}: {error:#}", self.local.root.display());
                    state = folders
                        .wake
                        .wait_timeout_while(state, FOLDER_SYNC_RETRY, |state| !state.stop)
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .0;
                }
            }
        }
    }
}

/// How long the folder syncer waits before it tries a sync of `sessions/` that could not start.
const FOLDER_SYNC_RETRY: Duration = Duration::from_millis(100);
