use serde_json::json;

use super::{Verdict, verdict};

fn line(report: serde_json::Value) -> String {
    format!("motd noise\n{report}\n")
}

/// A machine whose agents all reach the edge, with no login on it, starts.
#[test]
fn an_edge_routed_machine_with_no_login_is_ready() {
    let ok = json!({"ok": true, "holds_credential": false, "daemon": {"running": true},
                    "agents": {"claude": {"edge_routed": true}, "codex": {"edge_routed": true}}});
    assert_eq!(verdict(&line(ok)), Verdict::Ready);
}

/// The DEV build's signed-out turn: a machine whose cmux-tui predates the report prints
/// nothing, and the start ends with that reason instead of opening a chat.
#[test]
fn a_machine_too_old_to_report_is_unsupported_and_other_output_is_invalid() {
    assert_eq!(verdict(""), Verdict::Unsupported);
    assert_eq!(verdict("  \n"), Verdict::Unsupported);
    assert_eq!(verdict("bash: acp: unknown command\n"), Verdict::Invalid);
    assert_eq!(verdict(&line(json!({"ok": true}))), Verdict::Invalid, "no agents: not the report");
}

/// Each refusal names its cause: a login on the machine first, then no acpmux, then a route
/// that is not the edge's.
#[test]
fn a_refused_report_names_its_cause() {
    let report = |holds: bool, running: bool| {
        line(json!({"ok": false, "holds_credential": holds, "daemon": {"running": running},
                    "agents": {"claude": {"edge_routed": false}}}))
    };
    assert_eq!(verdict(&report(true, true)), Verdict::HoldsCredential);
    assert_eq!(verdict(&report(true, false)), Verdict::HoldsCredential);
    assert_eq!(verdict(&report(false, false)), Verdict::NoDaemon);
    assert_eq!(verdict(&report(false, true)), Verdict::NotEdge);
    let unsaid = line(json!({"ok": false, "agents": {}}));
    assert_eq!(verdict(&unsaid), Verdict::HoldsCredential, "an unsaid login counts as one");
}
