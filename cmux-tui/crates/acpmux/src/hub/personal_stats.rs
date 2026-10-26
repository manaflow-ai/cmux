//! Part of `Hub`; see `hub/mod.rs`. Personal stats (`crate::stats`,
//! hq#1920) and the restart record that keeps them honest about a wait the
//! dead daemon left open.

use super::*;

impl Hub {
    /// Personal stats over every session log (`crate::stats`): blocking,
    /// one pass over the store. Live is what this daemon holds running or
    /// waiting, never session.json's status: after a crash that still says
    /// what the dead daemon left.
    pub fn stats(
        &self,
        options: &crate::stats::StatsOptions,
    ) -> Result<crate::stats::StatsSummary> {
        let live = self
            .sessions()
            .into_iter()
            .filter(|s| matches!(s.status(), SessionStatus::Running | SessionStatus::Waiting))
            .map(|s| s.id.clone())
            .collect();
        crate::stats::summarize(&*self.store, options, &live)
    }

    /// After a restart: a session the dead daemon left waiting (a turn's
    /// permission question, or a subagent asking after its turn) is idle
    /// now. A `status idle` record with `detail: restart` says so in the log
    /// and session.json, and the stats end that wait at the record before
    /// it, not at whatever status comes next.
    pub(super) fn mark_lost_wait(&self, session: &Session) {
        let status = SessionStatus::Idle.to_string();
        self.append(session, "mux", "status", json!({"status": status, "detail": "restart"}));
        self.save_meta(session);
    }
}
