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
mod explains_exit_tests {
    use super::explains_exit;

    #[test]
    fn a_wrapper_exit_line_does_not_hide_the_real_error() {
        let tail = ["No conversation found with session ID: e140627e", "subrouter: exit status 1"];
        let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
        assert_eq!(last, Some("No conversation found with session ID: e140627e"));
    }

    /// acp-chief-issues.md #3: sr2 prints its route banner at every start; a
    /// start that died after it must quote the real error, never the banner.
    #[test]
    fn the_sr2_route_banner_does_not_explain_the_exit() {
        let tail = [
            "claude2: read rotation: context deadline exceeded",
            "sr2 route: profile settings name http://127.0.0.1:1; managed settings override it with the sr2 gateway",
            "sr2 route: gateway http://sr2-gateway.tail137216.ts.net:4016",
        ];
        let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
        assert_eq!(last, Some("claude2: read rotation: context deadline exceeded"));
    }

    #[test]
    fn ordinary_lines_still_explain_the_exit() {
        assert!(explains_exit("Error: exit status unknown to me"));
        assert!(explains_exit("panic: index out of range"));
        assert!(!explains_exit("at Object.<anonymous> (cli.js:1:1)"));
        assert!(!explains_exit("[SYSTEM_ERROR] boom"));
        assert!(!explains_exit(""));
    }

    /// An agent that printed its account's 429 and quit says so in its `exited` record.
    #[test]
    fn an_exit_after_a_429_is_classed_rate_limit_with_its_line() {
        use super::{ExitLine, exit_cause, exited_data};
        let tail = [
            "API Error: Request rejected (429) · This request would exceed your account's rate limit",
            "subrouter: exit status 1",
        ];
        let mut heard = ExitLine::default();
        tail.iter().for_each(|l| heard.heard(l));
        let last = heard.take();
        assert_eq!(last.as_deref(), Some(tail[0]));
        let data = exited_data(Some(0), last.as_deref());
        assert_eq!(data["code"], 0);
        assert_eq!(data["reason"], "rate_limit");
        assert_eq!(data["error"], tail[0]);
        assert_eq!(exit_cause("API Error: 529 overloaded_error"), "capacity");
        assert_eq!(exit_cause("Not logged in · Please run /login"), "auth");
        assert_eq!(exit_cause("panic: index out of range"), "agent_exited");
        // Nothing on stderr: no error, and the plain class.
        let quiet = exited_data(Some(1), None);
        assert_eq!(quiet, serde_json::json!({"code": 1, "reason": "agent_exited"}));
    }

    /// An earlier turn's 429, retried and answered, does not explain a later quiet idle exit.
    #[test]
    fn an_earlier_turns_429_does_not_class_a_clean_idle_exit_rate_limit() {
        use super::{ExitLine, exited_data};
        let line = "API Error: Request rejected (429) · This request would exceed your account's rate limit";
        let mut last = ExitLine::default();
        last.heard(line);
        last.heard("subrouter: exit status 1");
        last.turn_ended_well();
        let data = exited_data(Some(0), last.take().as_deref());
        assert_eq!(data, serde_json::json!({"code": 0, "reason": "agent_exited"}));
        // A 429 after the turn's end still explains the exit, once: the next process has none.
        last.heard(&format!("  {line}  "));
        let data = exited_data(Some(0), last.take().as_deref());
        assert_eq!(
            (data["reason"].as_str(), data["error"].as_str()),
            (Some("rate_limit"), Some(line))
        );
        assert_eq!(last.take(), None);
    }

    /// A hosted agent's tap: its 429, then its prompt's answer `end_turn`, then a quiet exit is
    /// not `rate_limit`; a cancelled turn or another answer does not clear the line.
    #[test]
    fn a_hosted_agents_answered_turn_clears_its_earlier_429() {
        use super::{ExitLine, ends_a_turn_well, exited_data};
        use crate::rpc::{Message, RpcError};
        let answer = |result: serde_json::Value| Message::Response {
            id: serde_json::json!(3),
            result: Some(result),
            error: None,
        };
        let line = "API Error: Request rejected (429) · This request would exceed your account's rate limit";
        // The tap's own steps: each inbound message, then the exit.
        let tap = |messages: &[Message]| {
            let mut last = ExitLine::default();
            last.heard(line);
            for m in messages {
                if ends_a_turn_well(m) {
                    last.turn_ended_well();
                }
            }
            exited_data(Some(0), last.take().as_deref())
        };
        let ended = answer(serde_json::json!({"stopReason": "end_turn"}));
        assert_eq!(tap(&[ended]), serde_json::json!({"code": 0, "reason": "agent_exited"}));
        for kept in [
            answer(serde_json::json!({"stopReason": "cancelled"})),
            answer(serde_json::json!({"sessionId": "s"})),
            Message::Response {
                id: serde_json::json!(3),
                result: None,
                error: Some(RpcError::new(-32603, line)),
            },
        ] {
            assert_eq!(tap(&[kept])["reason"], "rate_limit");
        }
    }
}
