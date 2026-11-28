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
    let line =
        "API Error: Request rejected (429) · This request would exceed your account's rate limit";
    let mut last = ExitLine::default();
    last.heard(line);
    last.heard("subrouter: exit status 1");
    last.turn_ended_well();
    let data = exited_data(Some(0), last.take().as_deref());
    assert_eq!(data, serde_json::json!({"code": 0, "reason": "agent_exited"}));
    // A 429 after the turn's end still explains the exit, once: the next process has none.
    last.heard(&format!("  {line}  "));
    let data = exited_data(Some(0), last.take().as_deref());
    assert_eq!((data["reason"].as_str(), data["error"].as_str()), (Some("rate_limit"), Some(line)));
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
    let line =
        "API Error: Request rejected (429) · This request would exceed your account's rate limit";
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
