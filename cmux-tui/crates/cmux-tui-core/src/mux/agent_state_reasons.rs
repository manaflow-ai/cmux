//! `state_reason` on the private `list-agents` rows: why the roster holds each
//! terminal agent's state (journal_reducers_state_reason.rs). Ids, names and
//! times only; the screen text a cause carried stays in its journal record,
//! read under the journal's own sensitivity rules (`cmux agent explain`).
//!
//! Not on `agent.list` or `session.snapshot`: those public values are
//! compared whole (a mutation's result against the listed agent), and a
//! reason that moves with every observation would churn them.

use std::collections::HashMap;
use std::sync::PoisonError;

use serde_json::Value;

use super::Mux;

impl Mux {
    /// Each roster terminal's state reason, keyed by terminal id.
    pub(crate) fn agent_state_reasons(&self) -> HashMap<String, Value> {
        self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner).roster.state_reasons()
    }
}
