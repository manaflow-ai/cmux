//! Which stderr line explains why an agent process closed.

/// Whether a stderr line can say why an agent process died: not blank, not a
/// stack frame, not a wrapper tag or sr2's route banner, and not a wrapper's
/// own exit line such as
/// `subrouter: exit status 1` (the `sr claude proxy` harness prints that after
/// Claude's real error, e.g. "No conversation found with session ID: ...").
pub(super) fn explains_exit(line: &str) -> bool {
    if line.is_empty() || line.starts_with("at ") || line.starts_with("[SYSTEM_ERROR]") {
        return false;
    }
    // sr2 names its route at every start, before Claude runs: it says where
    // the harness went, never why it died.
    if line.starts_with("sr2 route:") {
        return false;
    }
    !is_wrapper_exit_line(line)
}

/// An `exited` record's data: its exit `code`, and, when the dead process's stderr said why
/// (`last`: its last line that [`explains_exit`]), that line as `error` and its class as `reason`
/// ([`exit_cause`]).
///
/// Leo, 2026-11-21: "i dont think 429 should just cause a process to just exit on its own, this
/// is pretty weird". An agent process that quit on its own between turns was logged `exited`
/// with only its code, and a code of 0 read as "agent stopped" in the transcript, as if someone
/// had stopped it: an agent that printed its account's 429 and quit read the same as a Stop. Now
/// the record says what the process said, and the transcript says it exited and why
/// (`transcript.rs`). A `rate_limit` exit also holds the chat until the reset and starts the
/// harness again there on the same conversation, with no prompt (`rate_hold.rs` `hold_at_exit`).
/// A process that said nothing explaining is `reason: agent_exited` with no `error`.
pub(super) fn exited_data<C: serde::Serialize>(code: C, last: Option<&str>) -> serde_json::Value {
    match last {
        Some(line) => serde_json::json!({"code": code, "reason": exit_cause(line), "error": line}),
        None => serde_json::json!({"code": code, "reason": "agent_exited"}),
    }
}

/// The last stderr line of the session's current agent process that could say why it quit
/// ([`explains_exit`]), for the hub's `exited` record (`permissions.rs`). Not the session's
/// `stderr_tail`: that is cleared only when a turn starts, so after a turn whose 429 was retried
/// and answered it still held the 429, and a later quiet idle exit read as `rate_limit`. Here a
/// turn the agent ended well clears the line (`turns.rs`), and each exit takes it, so the next
/// process starts with none, as a hosted agent's tap keeps its own (`tap.rs`).
#[derive(Debug, Default)]
pub(super) struct ExitLine(Option<String>);

impl ExitLine {
    /// One cleaned stderr line of the process.
    pub(super) fn heard(&mut self, line: &str) {
        let line = line.trim();
        if explains_exit(line) {
            self.0 = Some(line.to_owned());
        }
    }

    /// The agent answered a turn after the line: it did not end the process.
    pub(super) fn turn_ended_well(&mut self) {
        self.0 = None;
    }

    /// At the process's exit: its line, leaving none for the next process.
    pub(super) fn take(&mut self) -> Option<String> {
        self.0.take()
    }
}

/// Why an agent process died, from the stderr line that says it: as a turn its death cut off is
/// classed (`turn_errors::resume_cause`: `rate_limit` for an account's 429 or usage limit,
/// `capacity`, `transport`, `context`), `auth` for a sign-in failure, else `agent_exited`.
pub(super) fn exit_cause(line: &str) -> &'static str {
    crate::turn_errors::resume_cause(crate::agent::AGENT_CLOSED, line)
        .or_else(|| crate::recovery::auth_kind(line).map(|_| "auth"))
        .unwrap_or("agent_exited")
}

/// An agent's answer to a prompt that ended its turn well, as the hosted agent's tap sees it
/// (`tap.rs`): a result with a `stopReason` other than `cancelled`, the same rule `finish_turn`
/// clears the hub's [`ExitLine`] by.
pub(super) fn ends_a_turn_well(msg: &crate::rpc::Message) -> bool {
    let crate::rpc::Message::Response { result: Some(result), error: None, .. } = msg else {
        return false;
    };
    result.get("stopReason").and_then(serde_json::Value::as_str).is_some_and(|r| r != "cancelled")
}

/// `<program>: exit status <n>`, as Go's `exec.ExitError` prints it.
fn is_wrapper_exit_line(line: &str) -> bool {
    let Some((program, rest)) = line.split_once(": exit status ") else {
        return false;
    };
    !program.is_empty()
        && !program.contains(char::is_whitespace)
        && !rest.is_empty()
        && rest.trim_start_matches('-').chars().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
#[path = "exit_reason_explains_exit_tests.rs"]
mod explains_exit_tests;
