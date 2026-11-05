//! The checkpoint (`<home>/journal-projected.json`, the journal's compaction point) and its
//! thread ([module docs](super)).

use super::*;
use std::sync::atomic::Ordering as AtomicOrdering;

#[derive(Serialize, Deserialize)]
struct Checkpoint {
    schema: String,
    lsn: Lsn,
}

/// The checkpoint's LSN; 0 when there is none. One that does not read fails the open: a replay
/// from the journal's oldest record could undo a retention rewrite.
pub(super) fn read_checkpoint(home: &Path) -> Result<Lsn> {
    let path = home.join(CHECKPOINT_NAME);
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => {
            anyhow::bail!("read the event journal's checkpoint {}: {error}", path.display())
        }
    };
    match serde_json::from_slice::<Checkpoint>(&bytes) {
        Ok(checkpoint) if checkpoint.schema == CHECKPOINT_SCHEMA => Ok(checkpoint.lsn),
        _ => anyhow::bail!(
            "the event journal's checkpoint {} does not read; move it aside to replay the whole journal",
            path.display()
        ),
    }
}

/// Removes the temporary files of checkpoints a crash interrupted (`write_checkpoint`).
pub(super) fn remove_checkpoint_temporaries(home: &Path) {
    let Ok(entries) = std::fs::read_dir(home) else { return };
    let prefix = format!("{CHECKPOINT_NAME}.tmp-");
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with(&prefix) {
            continue;
        }
        let path = entry.path();
        if let Err(error) = crate::config::refuse_lost_home(&path)
            .and_then(|()| std::fs::remove_file(&path).map_err(anyhow::Error::from))
        {
            tracing::warn!("remove {}: {error:#}", path.display());
        }
    }
}

/// Writes the checkpoint whole under a temporary name, syncs it, renames it into place and syncs
/// the home folder; an error at any step (the folder's sync too) is returned.
fn write_checkpoint(home: &Path, lsn: Lsn) -> Result<()> {
    let path = home.join(CHECKPOINT_NAME);
    crate::config::refuse_lost_home(&path)?;
    let tmp = home.join(format!("{CHECKPOINT_NAME}.tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec(&Checkpoint { schema: CHECKPOINT_SCHEMA.into(), lsn })?;
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&tmp).with_context(|| format!("write {}", tmp.display()))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&tmp, &path).with_context(|| format!("rename to {}", path.display()))?;
    sync_directory(home)
}

impl Inner {
    /// One checkpoint ([module docs](self)); ten failures in a row ask the daemon to stop.
    pub(super) fn checkpoint(&self) -> Result<()> {
        let _one = self.checkpointing.lock_or_recover();
        let result = self.checkpoint_once();
        let mut order = self.order.lock_or_recover();
        match &result {
            Ok(()) => order.failures = 0,
            Err(error) if !order.frozen => {
                order.failures = order.failures.saturating_add(1);
                if order.failures >= CHECKPOINT_FAILURES_TO_STOP {
                    drop(order);
                    self.ask_to_stop(format!(
                        "{CHECKPOINT_FAILURES_TO_STOP} event journal checkpoints failed in a row, the last: {error:#}"
                    ));
                }
            }
            Err(_) => {}
        }
        result
    }

    fn checkpoint_once(&self) -> Result<()> {
        let (lsn, dirty, metas) = {
            let mut order = self.order.lock_or_recover();
            anyhow::ensure!(
                !order.frozen,
                "the event journal's checkpoint is frozen (a log sync failed): a restart writes the logs again"
            );
            if !order.has_work() {
                let checkpointed = order.checkpointed;
                drop(order);
                self.retire(checkpointed);
                return Ok(());
            }
            // A failed checkpoint waits for the timer or another `CHECKPOINT_BYTES`.
            order.bytes = 0;
            (order.applied, std::mem::take(&mut order.dirty), order.metas.clone())
        };
        #[cfg(test)]
        super::hold_after_start();
        // Every record up to `lsn` durable first (one group commit, on this background thread):
        // the checkpoint is never past the journal's durable end, and a metadata image written
        // below names only lines the journal holds (E13).
        if lsn > 0
            && let Err(error) = self.journal.wait_durable(lsn, SEAL_WAIT)
        {
            self.order.lock_or_recover().dirty.extend(dirty);
            anyhow::bail!("the event journal did not sync through {lsn}: {error}");
        }
        // Each chat's newest image through `lsn` (the overlay held it when `lsn` was read): the
        // sessions folder's sync below covers a new chat's folder.
        if let Err(error) = self.project_metas(metas) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        if let Err(error) = self.sync_logs(&dirty) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        // A close's failed sync of a log this checkpoint synced through a clone may have made the
        // clone's sync report success: the close notes it under the writers' lock, read here.
        if self.local.close_sync_failed() {
            self.freeze("an event log failed to sync at its close".into());
            anyhow::bail!(
                "an event log failed to sync: the journal keeps every line until a restart"
            );
        }
        // No LSN past a sync that failed on another thread (review of #35866, finding 2's base
        // part). A request's `flush_session` may have failed its sync of a log since this
        // checkpoint began, and the kernel may then report success to this checkpoint's own sync
        // of that log for the pages the failed one dropped. Such a sync is under way until its
        // failure froze the store (`counted_sync`), so the checkpoint waits for the syncs under
        // way now, then reads `frozen`. The wait is bounded by those syncs: one that begins later
        // cannot undo a sync this checkpoint saw end, and is not waited for.
        self.syncs.wait_for_those_under_way();
        anyhow::ensure!(
            !self.order.lock_or_recover().frozen,
            "the event journal's checkpoint is frozen (a sync failed while it ran): a restart writes the logs again"
        );
        write_checkpoint(&self.home, lsn)?;
        let damage = {
            let mut order = self.order.lock_or_recover();
            order.checkpointed = order.checkpointed.max(lsn);
            std::mem::take(&mut order.damage)
        };
        if damage && let Err(error) = self.journal.clear_damage() {
            tracing::warn!("clear the event journal's damage report: {error}");
        }
        self.retire(lsn);
        Ok(())
    }

    fn retire(&self, lsn: Lsn) {
        if let Err(error) = self.journal.retire_through(lsn) {
            tracing::warn!("retire the event journal before {lsn}: {error}");
        }
    }

    /// Syncs the logs of `dirty` (their open segment and folders) and the sessions folder (a
    /// delete's removal, a new chat's folder). A chat deleted meanwhile is passed. A failed sync
    /// call freezes the checkpoint; another error (a folder that does not open) fails only this
    /// checkpoint, and the next one tries again.
    fn sync_logs(&self, dirty: &BTreeSet<String>) -> Result<()> {
        let failed = |error: anyhow::Error| {
            if error.chain().any(|cause| cause.is::<SyncFailed>()) {
                self.freeze(format!("an event log failed to sync: {error:#}"));
            }
            error
        };
        for chat in dirty {
            match self.local.sync_log(chat) {
                Ok(()) => {}
                Err(error) if is_not_found(&error) => {}
                Err(error) => {
                    return Err(failed(error.context(format!("sync the log of {chat}"))));
                }
            }
        }
        sync_directory(&self.local.root).map_err(failed)
    }

    /// Runs `sync`, a sync of the store's files that freezes the store when it fails (a request's
    /// `flush_session`, a chat's `session.json` from the overlay, the folder syncer), so that a
    /// checkpoint never writes an LSN past its failure: the sync is under way until its failure,
    /// if any, froze the store, and a checkpoint waits for the syncs under way before it writes
    /// (`checkpoint_once`). Only the sync itself is counted, never a wait before it (a settle's
    /// wait for its record): the checkpoint's wait is bounded by syncs alone.
    pub(super) fn counted_sync<T>(
        &self,
        what: &str,
        sync: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        let under_way = UnderWay { inner: self, ticket: self.syncs.begin() };
        #[cfg(test)]
        super::hold_in_sync();
        let result = sync();
        if let Err(error) = &result
            && error.chain().any(|cause| cause.is::<SyncFailed>())
        {
            #[cfg(test)]
            super::hold_before_freeze();
            self.freeze(format!("{what}: {error:#}"));
        }
        // Ended only now: a checkpoint that waited for it then reads the store frozen.
        drop(under_way);
        result
    }

    /// A log sync failed: no checkpoint until a restart, and the daemon is asked to stop.
    pub(super) fn freeze(&self, why: String) {
        self.order.lock_or_recover().frozen = true;
        self.ask_to_stop(why);
    }

    pub(super) fn ask_to_stop(&self, why: String) {
        tracing::error!(
            "{why}: the event journal keeps every line; the daemon stops so that its restart writes the logs again"
        );
        self.stop.send_if_modified(|reason| {
            if reason.is_some() {
                return false;
            }
            *reason = Some(why);
            true
        });
    }

    pub(super) fn run_checkpointer(&self) {
        let mut timer = self.timer.lock_or_recover();
        loop {
            if timer.stop {
                return;
            }
            if !timer.wanted && !self.order.lock_or_recover().has_work() {
                // Idle (cmux-ad m9: no periodic wake): asleep until a change (`touched`). The flag
                // goes up before the second look, so a change either shows in that look or finds
                // the flag and wakes this wait (it notifies under the timer lock held here).
                self.idle.store(true, AtomicOrdering::SeqCst);
                #[cfg(test)]
                self.hold(|seams| seams.idle_hold.take());
                if !self.order.lock_or_recover().has_work() {
                    timer = self
                        .wake
                        .wait_while(timer, |timer| {
                            !timer.stop && !timer.wanted && self.idle.load(AtomicOrdering::SeqCst)
                        })
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if timer.stop {
                        return;
                    }
                }
                self.idle.store(false, AtomicOrdering::SeqCst);
            }
            if !timer.wanted {
                // One period after the first change: a burst shares one checkpoint. Each wait here
                // ends only on the state its waker sets before it notifies under the timer lock
                // (`idle` for the wait above; `wanted` and `stop` for this one), never on a bare
                // notify: a `touched` that took the idle flag before the second look above gets
                // the timer lock, and notifies, only once this thread waits here, and a spurious
                // wakeup is no reason either.
                timer = self
                    .wake
                    .wait_timeout_while(timer, self.checkpoint_every(), |timer| {
                        !timer.stop && !timer.wanted
                    })
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .0;
                if timer.stop {
                    return;
                }
            }
            timer.wanted = false;
            drop(timer);
            #[cfg(test)]
            checkpointer_seams(&self.home, |seams| seams.wakes = seams.wakes.saturating_add(1));
            if let Err(error) = self.checkpoint() {
                tracing::warn!("event journal checkpoint: {error:#}");
            }
            timer = self.timer.lock_or_recover();
        }
    }

    /// A change was appended: wakes an idle checkpointer (`run_checkpointer`). One atomic read
    /// when it is not idle. Never called with the appends' lock held.
    pub(super) fn touched(&self) {
        if self.idle.load(AtomicOrdering::SeqCst) && self.idle.swap(false, AtomicOrdering::SeqCst) {
            #[cfg(test)]
            self.hold(|seams| seams.touch_hold.take());
            let _timer = self.timer.lock_or_recover();
            self.wake.notify_all();
        }
    }

    /// How long the checkpointer waits between two checkpoints. Debug builds only:
    /// `ACPMUX_TEST_JOURNAL_CHECKPOINT_MS` (10 ms to 60 s) shortens it for the daemon-level tests.
    fn checkpoint_every(&self) -> Duration {
        #[cfg(test)]
        if let ms @ 1.. = checkpointer_seams(&self.home, |seams| seams.every_ms) {
            return Duration::from_millis(ms);
        }
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("ACPMUX_TEST_JOURNAL_CHECKPOINT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
        {
            return Duration::from_millis(ms.clamp(10, 60_000));
        }
        CHECKPOINT_EVERY
    }

    /// Tests: stops at the hold that `take` gives out of this store's seams, if there is one.
    #[cfg(test)]
    fn hold(&self, take: impl FnOnce(&mut CheckpointerSeams) -> Option<Hold>) {
        if let Some((arrived, release)) = checkpointer_seams(&self.home, take) {
            let _ = arrived.send(());
            let _ = release.recv();
        }
    }

    pub(super) fn want_checkpoint(&self) {
        let mut timer = self.timer.lock_or_recover();
        if !timer.wanted {
            timer.wanted = true;
            drop(timer);
            self.wake.notify_all();
        }
    }
}

/// Whether `error` comes from a file or folder that is not there.
fn is_not_found(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound)
    })
}

/// The syncs of the store's files under way that freeze the store when they fail
/// ([`Inner::counted_sync`]), each with a ticket in the order they began.
#[derive(Default)]
pub(super) struct SyncsUnderWay {
    tickets: Mutex<Tickets>,
    ended: Condvar,
}

#[derive(Default)]
struct Tickets {
    /// The ticket of the next sync that begins.
    next: u64,
    /// The tickets of the syncs under way.
    under_way: BTreeSet<u64>,
}

/// One sync under way ([`Inner::counted_sync`]). It ends when this drops, in a panic too, so a
/// checkpoint never waits for it for ever; a panic first freezes the store, since what the sync
/// did is then not known (review of #35895, P3).
struct UnderWay<'a> {
    inner: &'a Inner,
    ticket: u64,
}

impl SyncsUnderWay {
    /// A new sync's ticket, under way until [`SyncsUnderWay::end`].
    fn begin(&self) -> u64 {
        let mut tickets = self.tickets.lock_or_recover();
        let ticket = tickets.next;
        tickets.next = ticket.saturating_add(1);
        tickets.under_way.insert(ticket);
        ticket
    }

    fn end(&self, ticket: u64) {
        self.tickets.lock_or_recover().under_way.remove(&ticket);
        self.ended.notify_all();
    }

    /// Waits until each sync under way now has ended, never for one that begins meanwhile: the
    /// wait is bounded by the syncs under way when it starts, however many begin after them.
    fn wait_for_those_under_way(&self) {
        let mut tickets = self.tickets.lock_or_recover();
        let horizon = tickets.next;
        while tickets.under_way.first().is_some_and(|&first| first < horizon) {
            #[cfg(test)]
            log_sync::note(&log_sync::NOTE_BEFORE_SYNCS_WAIT, "waits for the syncs under way");
            tickets = self.ended.wait(tickets).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }
}

impl Drop for UnderWay<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.inner.freeze("a sync of the store's files panicked".into());
        }
        self.inner.syncs.end(self.ticket);
    }
}
