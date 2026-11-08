//! `terminal <t> status`: the terminal's program status records (OSC 7501)
//! with the agent status every list shows (W5-Q, bench round 4 #7).

use serde_json::Value;

/// The `terminal.get` `result` with each program status record's `status`.
/// `agents` are the terminal's daemon agent records; `unseen` is whether the
/// terminal has an unread notification. Not yet: the result as it is.
pub(super) fn annotate(result: Value, _agents: &[Value], _unseen: bool) -> Value {
    result
}

/// What the human table shows for the records. Not yet: the records.
pub(super) fn human_records(records: Value) -> Value {
    records
}

#[cfg(test)]
#[path = "program_status_view/tests.rs"]
mod tests;
