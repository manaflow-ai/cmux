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
            if order.applied <= order.checkpointed
                && order.dirty.is_empty()
                && order.metas.is_empty()
            {
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
            if !timer.wanted {
                timer = self
                    .wake
                    .wait_timeout(timer, checkpoint_every())
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .0;
                if timer.stop {
                    return;
                }
            }
            timer.wanted = false;
            drop(timer);
            if let Err(error) = self.checkpoint() {
                tracing::warn!("event journal checkpoint: {error:#}");
            }
            timer = self.timer.lock_or_recover();
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

/// How long the checkpointer waits between two checkpoints. Debug builds only:
/// `ACPMUX_TEST_JOURNAL_CHECKPOINT_MS` (10 ms to 60 s) shortens it for the daemon-level tests.
fn checkpoint_every() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("ACPMUX_TEST_JOURNAL_CHECKPOINT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(ms.clamp(10, 60_000));
    }
    CHECKPOINT_EVERY
}

/// Whether `error` comes from a file or folder that is not there.
fn is_not_found(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound)
    })
}
