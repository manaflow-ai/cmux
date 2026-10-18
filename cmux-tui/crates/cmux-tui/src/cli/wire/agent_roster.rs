//! `agent list`: the `agent.list` rows ranked by who needs the person,
//! limited, counted by state, and joined with their terminals' titles and
//! folders. The daemon's rows are unchanged; only the CLI shapes them.

use serde_json::Value;

use super::super::command::AgentRosterView;

/// The printed roster: `{"agents":[...],"counts":{...}}`.
pub(super) fn shape(
    rows: Value,
    _terminals: &[Value],
    _view: AgentRosterView,
    _now_ms: u64,
) -> Value {
    rows
}

/// The human roster: a counts line, then one row per agent.
pub(super) fn human(_result: &Value, _home: Option<&str>) -> String {
    String::new()
}

/// A compact age, one unit: `45s`, `12m`, `3h`, `2d`.
fn age_text(_age_ms: u64) -> String {
    String::new()
}

#[cfg(test)]
mod tests;
