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
mod tests {
    use super::*;

    #[test]
    fn output_recovery_cache_budget_is_shared_and_released_with_the_last_reader() {
        let store = OutputStore::new(None);
        let mut cuts = Vec::new();
        for _ in 0..16 {
            cuts.push(store.make_recovery_cut("x".repeat(4 * 1024 * 1024), 0).unwrap());
        }
        assert!(store.make_recovery_cut("x".into(), 0).is_err());
        let retained_reader = cuts[0].clone();
        cuts.remove(0);
        assert!(
            store.make_recovery_cut("x".into(), 0).is_err(),
            "a live reader still owns the bytes"
        );
        drop(retained_reader);
        assert!(store.make_recovery_cut("x".repeat(4 * 1024 * 1024), 0).is_ok());
    }

    #[test]
    fn output_recovery_invalidates_on_each_gap_generation_and_clear_in_all_modes() {
        for mode in [PersistenceMode::Memory, PersistenceMode::Snapshot, PersistenceMode::Full] {
            let store = OutputStore::new(None);
            store.full.set_enabled(mode == PersistenceMode::Full);
            store
                .tail
                .store(mode == PersistenceMode::Snapshot, std::sync::atomic::Ordering::Relaxed);
            let terminal =
                TerminalPublicId::parse("term_00000000000000000000000000000f3a").unwrap();
            let generation = Arc::from("first");
            store.stream_gap(&terminal, &generation);
            let (first, gap, slot, end) = store.recovery_state(&terminal).unwrap();
            assert!(gap);
            assert_eq!(end, 0);
            *slot.lock().unwrap() =
                Some(store.make_recovery_cut("old history".into(), end).unwrap());
            store.stream_gap(&terminal, &generation);
            let (second, _, slot, _) = store.recovery_state(&terminal).unwrap();
            assert_ne!(first, second);
            assert!(slot.lock().unwrap().is_none());
            assert!(store.check_recovery_epoch(&terminal, &first).is_err());
            store.append(&terminal, &Arc::from("second"), b"new", None);
            let (third, _, _, end) = store.recovery_state(&terminal).unwrap();
            assert_ne!(second, third);
            assert_eq!(end, 3);
            store.history_cleared(&terminal);
            let (fourth, _, slot, _) = store.recovery_state(&terminal).unwrap();
            assert_ne!(third, fourth);
            assert!(slot.lock().unwrap().is_none());
        }
    }
}
