use super::*;

fn held(id: &str, at: u64) -> Held {
    Held { id: id.to_string(), held_at_ms: at, replaying: false, sent: false, settling: false }
}

#[test]
fn daemon_down_holds_a_close_instead_of_rejecting_it() {
    for kind in ["notConnected", "connectionClosed", "daemonShutdown", "connectFailed"] {
        assert_eq!(disposition(kind, true), Disposition::Hold, "{kind}");
        assert_eq!(disposition(kind, false), Disposition::Hold, "{kind}");
    }
}

#[test]
fn a_late_reply_holds_only_while_the_daemon_does_not_answer() {
    assert_eq!(disposition("timedOut", false), Disposition::Hold);
    assert_eq!(disposition("timedOut", true), Disposition::Reject);
}

#[test]
fn a_refusal_is_rejected() {
    for kind in ["command", "malformedResponse", "wrongApp", "terminalStartTimedOut", "other"] {
        assert_eq!(disposition(kind, false), Disposition::Reject, "{kind}");
    }
}

#[test]
fn while_unreachable_nothing_replays_and_the_bound_is_the_next_check() {
    let list = [held("a", 1_000), held("b", 5_000)];
    let out = sweep(&list, 10_000, false, HOLD_BOUND_MS);
    assert!(out.replay.is_empty());
    assert!(out.expire.is_empty());
    assert_eq!(out.next_check_ms, Some(1_000 + HOLD_BOUND_MS));
}

#[test]
fn reconnect_replays_once_in_order() {
    let mut list = vec![held("a", 1_000), held("b", 2_000)];
    let out = sweep(&list, 3_000, true, HOLD_BOUND_MS);
    assert_eq!(out.replay, ["a", "b"]);
    assert_eq!(out.next_check_ms, None);
    // The app marks them replaying: a second sweep (another answering
    // edge) before their outcome sends nothing again.
    for entry in &mut list {
        entry.replaying = true;
    }
    let again = sweep(&list, 3_500, true, HOLD_BOUND_MS);
    assert!(again.replay.is_empty(), "no double replay");
    assert!(again.expire.is_empty());
}

#[test]
fn past_the_bound_one_refusal_and_never_a_late_replay() {
    let list = [held("a", 0), held("b", 60_000)];
    let out = sweep(&list, HOLD_BOUND_MS, true, HOLD_BOUND_MS);
    assert_eq!(out.expire, ["a"]);
    assert_eq!(out.replay, ["b"]);
    // The app drops an expired one: the next sweep cannot refuse it twice.
    let rest = [held("b", 60_000)];
    let later = sweep(&rest, HOLD_BOUND_MS + 1, false, HOLD_BOUND_MS);
    assert!(later.expire.is_empty());
    assert_eq!(later.next_check_ms, Some(60_000 + HOLD_BOUND_MS));
}

#[test]
fn a_replay_in_flight_does_not_expire_under_it() {
    let list = [Held { replaying: true, ..held("a", 0) }];
    let out = sweep(&list, HOLD_BOUND_MS * 2, false, HOLD_BOUND_MS);
    assert!(out.expire.is_empty());
    assert!(out.replay.is_empty());
    assert_eq!(out.next_check_ms, None);
}

#[test]
fn a_timed_out_close_is_never_refused_for_certain_and_settles_when_the_daemon_is_back() {
    // The daemon is paused: the close times out, but may sit in its queue.
    assert!(maybe_sent("timedOut"));
    // A reply lost when the connection closed or the daemon shut down.
    assert!(maybe_sent("connectionClosed"));
    assert!(maybe_sent("daemonShutdown"));
    // A connection that never opened: the daemon never had it.
    assert!(!maybe_sent("notConnected"));
    assert!(!maybe_sent("connectFailed"));
    let list = [Held { sent: true, ..held("a", 0) }, held("b", 0)];
    // Past the bound with no answer: `a` gets the notice that it may
    // still close, never "wasn't closed"; `b` never left, so it is refused.
    let out = sweep(&list, HOLD_BOUND_MS, false, HOLD_BOUND_MS);
    assert_eq!(out.unsure, ["a"]);
    assert_eq!(out.expire, ["b"]);
    assert!(out.replay.is_empty() && out.settle.is_empty());
    // The daemon resumes before the bound: `a` is settled from its
    // state, never sent a second time.
    let back = sweep(&list, 60_000, true, HOLD_BOUND_MS);
    assert_eq!(back.settle, ["a"]);
    assert_eq!(back.replay, ["b"]);
    assert!(back.expire.is_empty() && back.unsure.is_empty());
}

#[test]
fn a_sent_action_past_the_bound_is_never_settled_late_even_when_the_daemon_is_back() {
    // No sweep ran at the bound (the app was suspended); the first one
    // after it already sees the daemon answering.
    let list = [Held { sent: true, ..held("a", 0) }, held("b", 0)];
    let out = sweep(&list, HOLD_BOUND_MS + 30_000, true, HOLD_BOUND_MS);
    assert_eq!(out.unsure, ["a"]);
    assert_eq!(out.expire, ["b"]);
    assert!(out.settle.is_empty() && out.replay.is_empty(), "no late replay");
}

#[test]
fn a_settle_in_flight_is_not_asked_for_twice() {
    let mut list = vec![Held { sent: true, ..held("a", 0) }];
    assert_eq!(sweep(&list, 10_000, true, HOLD_BOUND_MS).settle, ["a"]);
    list[0].settling = true;
    let again = sweep(&list, 11_000, true, HOLD_BOUND_MS);
    assert!(again.settle.is_empty() && again.replay.is_empty(), "no second settle");
    // Nor does it expire under the read.
    let late = sweep(&list, HOLD_BOUND_MS * 2, false, HOLD_BOUND_MS);
    assert!(late.unsure.is_empty() && late.expire.is_empty());
}

#[test]
fn a_replay_that_times_out_goes_back_held_as_sent() {
    let replaying = Held { replaying: true, ..held("a", 1_000) };
    let back = requeue(&replaying, "timedOut");
    assert_eq!(back, Held { sent: true, ..held("a", 1_000) });
    // Past the bound it is never refused for certain.
    let late = sweep(std::slice::from_ref(&back), HOLD_BOUND_MS + 1_000, false, HOLD_BOUND_MS);
    assert_eq!(late.unsure, ["a"]);
    // A later attempt that never left does not clear it.
    assert!(requeue(&Held { replaying: true, ..back }, "notConnected").sent);
    // A settle that failed before its connection opened changes only
    // its in-flight mark.
    let settling = Held { settling: true, ..held("b", 0) };
    assert_eq!(requeue(&settling, "connectFailed"), held("b", 0));
}

#[test]
fn the_words_name_the_action_and_its_target() {
    let close = text("close", "Background task");
    assert_eq!(close.pending, "Close Background task");
    assert_eq!(close.when_back, "will close Background task when back");
    assert_eq!(
        close.refusal,
        "cmux couldn't reach its session service; Background task wasn't closed"
    );
    assert_eq!(
        close.unsure,
        "cmux couldn't reach its session service; Background task may still close when it's back"
    );
    assert_eq!(
        text("color", "Logs").refusal,
        "cmux couldn't reach its session service; Logs's color wasn't changed"
    );
    let other = text("Reorder tabs", "x");
    assert_eq!(other.pending, "Reorder tabs");
    assert_eq!(other.when_back, "will reorder tabs when back");
    assert_eq!(
        other.refusal,
        "cmux couldn't reach its session service; \u{201c}Reorder tabs\u{201d} wasn't done"
    );
}
