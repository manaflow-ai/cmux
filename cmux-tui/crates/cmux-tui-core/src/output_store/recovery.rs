//! Immutable recovery cuts shared by independent and retrying readers.
use super::*;

pub(crate) struct RecoveryCut {
    pub(crate) text: String,
    pub(crate) end: u64,
    _reservation: RecoveryReservation,
}

/// All retained recovery screens together, independent of terminal count.
const RECOVERY_MAX_BYTES: u64 = 64 * 1024 * 1024;

struct RecoveryReservation {
    used: Arc<std::sync::atomic::AtomicU64>,
    bytes: u64,
}

impl Drop for RecoveryReservation {
    fn drop(&mut self) {
        self.used.fetch_sub(self.bytes, std::sync::atomic::Ordering::Relaxed);
    }
}

impl LogState {
    pub(super) fn invalidate_recovery(&mut self) {
        self.gap_pending = true;
        self.recovery_epoch = Arc::from(crate::workspace_registry::new_uuid_v4());
        self.recovery_cut = Arc::new(Mutex::new(None));
    }
}

pub(crate) type RecoveryState = (Arc<str>, bool, Arc<Mutex<Option<Arc<RecoveryCut>>>>, u64);

impl OutputStore {
    pub(crate) fn make_recovery_cut(
        &self,
        text: String,
        end: u64,
    ) -> anyhow::Result<Arc<RecoveryCut>> {
        let bytes = text.len() as u64;
        anyhow::ensure!(bytes <= 4 * 1024 * 1024, "terminal recovery snapshot exceeds 4 MiB");
        self.recovery_bytes
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |used| used.checked_add(bytes).filter(|total| *total <= RECOVERY_MAX_BYTES),
            )
            .map_err(|_| anyhow::anyhow!("terminal recovery cache budget exhausted"))?;
        Ok(Arc::new(RecoveryCut {
            text,
            end,
            _reservation: RecoveryReservation { used: self.recovery_bytes.clone(), bytes },
        }))
    }

    pub(crate) fn recovery_state(&self, terminal_id: &TerminalPublicId) -> Option<RecoveryState> {
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)?.clone();
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        Some((
            state.recovery_epoch.clone(),
            state.gap_pending,
            state.recovery_cut.clone(),
            state.next_offset(),
        ))
    }

    pub(crate) fn check_recovery_epoch(
        &self,
        terminal_id: &TerminalPublicId,
        epoch: &str,
    ) -> anyhow::Result<()> {
        let current = self
            .recovery_state(terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal output recovery disappeared; retry"))?;
        anyhow::ensure!(current.0.as_ref() == epoch, "terminal output recovery changed; retry");
        Ok(())
    }
}

#[cfg(test)]
#[path = "recovery_tests.rs"]
mod tests;
