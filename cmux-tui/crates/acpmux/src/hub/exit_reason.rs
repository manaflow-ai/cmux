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
/// (`transcript.rs`). The chat's status and its resume are as before: the next prompt starts the
/// harness again on the same conversation.
pub(super) fn exited_data<C: serde::Serialize>(code: C, last: Option<&str>) -> serde_json::Value {
    let mut data = serde_json::json!({"code": code});
    if let (Some(line), Some(o)) = (last, data.as_object_mut()) {
        o.insert("reason".to_owned(), exit_cause(line).into());
        o.insert("error".to_owned(), line.into());
    }
    data
}

/// The last line of `lines` that explains an exit ([`explains_exit`]), trimmed.
pub(super) fn last_explaining<'a>(
    lines: impl DoubleEndedIterator<Item = &'a str>,
) -> Option<&'a str> {
    lines.rev().map(str::trim).find(|l| explains_exit(l))
}

/// Why an agent process died, from the stderr line that says it: as a turn its death cut off is
/// classed (`turn_errors::resume_cause`: `rate_limit` for an account's 429 or usage limit,
/// `capacity`, `transport`, `context`), `auth` for a sign-in failure, else `agent_exited`.
pub(super) fn exit_cause(line: &str) -> &'static str {
    crate::turn_errors::resume_cause(crate::agent::AGENT_CLOSED, line)
        .or_else(|| crate::recovery::auth_kind(line).map(|_| "auth"))
        .unwrap_or("agent_exited")
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
        use super::{exit_cause, exited_data, last_explaining};
        let tail = [
            "API Error: Request rejected (429) · This request would exceed your account's rate limit",
            "subrouter: exit status 1",
        ];
        let last = last_explaining(tail.iter().copied());
        assert_eq!(last, Some(tail[0]));
        let data = exited_data(Some(0), last);
        assert_eq!(data["code"], 0);
        assert_eq!(data["reason"], "rate_limit");
        assert_eq!(data["error"], tail[0]);
        assert_eq!(exit_cause("API Error: 529 overloaded_error"), "capacity");
        assert_eq!(exit_cause("Not logged in · Please run /login"), "auth");
        assert_eq!(exit_cause("panic: index out of range"), "agent_exited");
        // Nothing on stderr: the code alone, as before.
        let quiet = exited_data(Some(1), None);
        assert_eq!(quiet, serde_json::json!({"code": 1}));
    }
}
