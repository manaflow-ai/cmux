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
/// the home folder; an error at any step (the folder's sync too) is returned. Its syncs are full
/// (`F_FULLFSYNC` on macOS flushes the drive's whole cache): every log, folder and `session.json`
/// the checkpoint and recovery synced in write order before it is then durable against a power
/// loss too, once per checkpoint, before any journal record is retired.
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
    log_sync::sync_full(&file)?;
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
        let (lsn, dirty, metas, read) = {
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
            // The segments the open read stay listed until their sync succeeds below: a
            // checkpoint that fails before it (a journal sync slower than its wait, an image
            // that cannot be written) leaves them for the next one (review of #35866, P1-1).
            (
                order.applied,
                std::mem::take(&mut order.dirty),
                order.metas.clone(),
                order.read_segments.clone(),
            )
        };
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
        // The segments the open's repair read without rewriting them: a killed daemon's writes may
        // be in the page cache only (review 3 of #34901, finding 1a), so they are synced before
        // their records are retired.
        if let Err(error) = self.sync_read_segments(&read) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        // Synced: no later checkpoint needs to sync them again (the list only shrinks after the
        // open, so these are exactly the ones the sync covered).
        self.order.lock_or_recover().read_segments.retain(|path| !read.contains(path));
        if let Err(error) = self.sync_logs(&dirty) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        if self.local.sync_failed.load(AtomicOrdering::SeqCst) {
            self.freeze("an event log failed to sync at its close".into());
            anyhow::bail!(
                "an event log failed to sync: the journal keeps every line until a restart"
            );
        }
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
    /// Syncs, in write order, each segment the open's repair read without rewriting it; one
    /// that is gone (its chat was deleted, or a retention rewrite replaced it) is passed: what
    /// replaced it was synced when it was written.
    fn sync_read_segments(&self, read: &BTreeSet<PathBuf>) -> Result<()> {
        for path in read {
            let file = match crate::config::private_state_file(path) {
                Ok(file) => file,
                Err(error) if is_not_found(&error) => continue,
                Err(error) => return Err(error.context(format!("open {}", path.display()))),
            };
            if let Err(error) = log_sync::sync_segment_ordered(&file) {
                self.freeze(format!("an event log failed to sync: {error}"));
                return Err(anyhow::Error::from(SyncFailed(error))
                    .context(format!("sync {}", path.display())));
            }
        }
        Ok(())
    }

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
        log_sync::sync_directory_ordered(&self.local.root).map_err(failed)
    }

    /// A sync of the store's files failed: no checkpoint until a restart, and the daemon is asked
    /// to stop. The freeze is a `frozen` record in the journal, after every line it covers (it is
    /// appended under the appends' lock): the open that replays it writes every replayed chat's
    /// lines again, as a later sync may report success for the pages the failed one dropped. A
    /// record and not a file of its own (review of #35866, P2-1 and P2-2): no checkpoint in
    /// flight can take it back, as a checkpoint retires only what its LSN covers and that LSN was
    /// read before this record; and it needs no write that can fail apart from the journal's own.
    /// The group commit makes it durable as any acknowledged record, and the shutdown that
    /// follows seals the journal.
    pub(super) fn freeze(&self, why: String) {
        let mut order = self.order.lock_or_recover();
        if !order.frozen {
            order.frozen = true;
            let mut appended = self.journal.append(KIND_FROZEN, Class::Ack, why.as_bytes());
            if appended == Err(AppendError::Backlog) {
                // The writer is behind: wait for it off the appends' lock, then append again.
                drop(order);
                let _ = self.journal.wait_durable(self.journal.last_lsn(), SEAL_WAIT);
                order = self.order.lock_or_recover();
                appended = self.journal.append(KIND_FROZEN, Class::Ack, why.as_bytes());
            }
            match appended {
                Ok(lsn) => order.applied = order.applied.max(lsn),
                Err(error) => tracing::error!(
                    "journal the freeze: {error}: the next start may trust pages the failed sync dropped"
                ),
            }
        }
        drop(order);
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
