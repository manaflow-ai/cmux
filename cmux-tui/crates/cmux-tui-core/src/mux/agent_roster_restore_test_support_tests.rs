use super::{AgentRosterReplay, RosterFoldLimits};

impl AgentRosterReplay {
    /// Test seam: a replay through `through` from no saved state.
    pub(in crate::mux) fn for_test(through: u64, limits: RosterFoldLimits) -> Self {
        Self {
            through,
            saved_at: 0,
            pages: 0,
            needs_repair: false,
            finish_rebuild: false,
            save_as: crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            skipped: Vec::new(),
            problems: Vec::new(),
            limits,
            progress_from: None,
        }
    }
}
