use super::*;

fn receipt(outcome: Value) -> Value {
    serde_json::json!({"outcome": outcome, "exited_at": "12", "revision": "3"})
}

/// R41: clients get a typed end; a host loss is never worded as an exit.
#[test]
fn wire_json_types_process_ends_and_host_losses() {
    let exit = |outcome| TerminalExit { outcome, exited_at_ms: 1 };
    assert_eq!(
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Exit { code: 3 })).wire_json(),
        serde_json::json!({"kind": "exited", "code": 3})
    );
    assert_eq!(
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Signal {
            signal: 9,
            core_dumped: false
        }))
        .wire_json(),
        serde_json::json!({"kind": "signaled", "signal": 9, "core_dumped": false})
    );
    for (detail, reason) in [
        ("missing-host-record", "missing_record"),
        ("host-incarnation-mismatch", "incarnation_mismatch"),
        ("host-process-ended-before-adoption", "dead_before_adoption"),
        ("host-exited-during-adoption", "died_during_adoption"),
        ("terminal host ended without a durable exit sidecar", "died_without_exit_status"),
        ("session-shutdown: signal 15", "session_shutdown"),
        ("session-shutdown: exit 1", "session_shutdown"),
        (EXIT_OWNER_GONE, "owner_gone"),
        ("something new", "other"),
    ] {
        let json = TerminalEnd::host_lost(detail).wire_json();
        assert_eq!(json["kind"], "host_lost");
        assert_eq!(json["reason"], reason, "{detail}");
        assert_eq!(json["detail"], detail);
    }
    assert_eq!(TerminalEnd::launch_failed("no pty").wire_json()["kind"], "launch_failed");
}

#[test]
fn persisted_exit_and_signal_receipts_are_process_ends() {
    for outcome in [
        serde_json::json!({"kind":"exit","code":0}),
        serde_json::json!({"kind":"signal","signal":15,"core_dumped":false}),
    ] {
        let end = TerminalEnd::from_receipt(Some(&receipt(outcome)));
        assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{end:?}");
        assert_eq!(end.exit().exited_at_ms, 12);
        assert!(end.detach_proof().is_some());
    }
}

#[test]
fn persisted_unknown_or_missing_receipts_are_host_losses() {
    let unknown = receipt(serde_json::json!({
        "kind":"unknown","reason":"host-process-ended-before-adoption",
    }));
    for end in [
        TerminalEnd::from_receipt(Some(&unknown)),
        TerminalEnd::from_receipt(None),
        TerminalEnd::from_receipt(Some(&serde_json::json!({"reason":"legacy"}))),
    ] {
        assert!(matches!(end, TerminalEnd::HostLost(_)), "{end:?}");
        assert!(end.detach_proof().is_none());
    }
}

/// cx-6so.49 L1: a replacement host that adopted a running session saw
/// it end without a status; that receipt is a process end, while any
/// other unknown reason stays a host loss.
#[test]
fn persisted_exit_unobserved_receipt_is_a_process_end() {
    let unobserved = receipt(serde_json::json!({"kind":"unknown","reason":"exit-unobserved"}));
    let end = TerminalEnd::from_receipt(Some(&unobserved));
    assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{end:?}");
    assert_eq!(end.exit().exited_at_ms, 12);
    assert!(end.detach_proof().is_some());
    assert_eq!(end.wire_json()["kind"], "exited");
    let near = receipt(serde_json::json!({"kind":"unknown","reason":"exit-unobserved: x"}));
    assert!(matches!(TerminalEnd::from_receipt(Some(&near)), TerminalEnd::HostLost(_)));
}

#[test]
fn a_host_loss_never_yields_a_detach_proof() {
    let real = TerminalExit::now(TerminalExitOutcome::Exit { code: 1 });
    assert!(TerminalEnd::ProcessEnded(real).detach_proof().is_some());
    // An older host's Exit frame without a status is still a real end.
    assert!(TerminalEnd::ProcessEnded(TerminalExit::unknown("omitted")).detach_proof().is_some());
    assert!(TerminalEnd::host_lost("lost").detach_proof().is_none());
    // The owner abandoning its own launch detaches like a close.
    assert!(TerminalEnd::launch_failed("spawn").detach_proof().is_some());
}
