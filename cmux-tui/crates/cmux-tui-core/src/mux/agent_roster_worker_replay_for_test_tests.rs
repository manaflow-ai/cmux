use super::*;

impl Mux {
    /// Starts a roster replay from zero in this running daemon, as a start
    /// whose snapshot does not restore does: the roster goes back to empty and
    /// the owner replays the journal in the background, `page` records per
    /// page, through `gate` (`agent_roster_restore::REPLAY_GATE_FOR_TEST`).
    #[cfg(test)]
    pub(crate) fn restart_agent_roster_replay_for_test(
        &self,
        page: usize,
        gate: (SyncSender<()>, Receiver<()>),
    ) {
        use agent_roster_restore::{RosterFoldLimits, restore_agent_roster_within};
        assert!(self.settle_agent_roster_for_test());
        let restored = {
            let registry = self.workspace_registry.lock().unwrap();
            registry
                .put_journal_reducer_state(
                    crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
                    crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
                    0,
                    "",
                )
                .unwrap();
            let limits = RosterFoldLimits { page, save_every_pages: 64, stop_after_pages: None };
            restore_agent_roster_within(&registry, limits, Some(Duration::ZERO)).unwrap()
        };
        *self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner) = restored.host;
        *self.agent_roster_worker.replay_gate.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(gate);
        self.continue_agent_roster_replay(restored.replay.expect("a replay from zero"));
    }
}
