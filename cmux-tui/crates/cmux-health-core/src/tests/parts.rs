//! Renderers, acpmux, the page host, the roster and pending user actions.

use super::*;
use crate::RepairAction::{Reconnect, RestartConnection, RestartPageHost, RestartRenderer};
use crate::State;

#[test]
fn an_unresponsive_renderer_restarts_after_5_s_and_a_crash_at_once() {
    const ID: &str = "renderer:77";
    let mut h = model();
    register(&mut h, ID, Kind::Renderer, "Web content", 0);
    assert_eq!(h.next_tick_ms(), None, "a renderer is timed only once unresponsive");
    h.event(ID, "unresponsive", 1_000, None);
    assert_eq!(h.next_tick_ms(), Some(6_000));
    assert_eq!(run(&mut h, 7_999), vec![(6_000, RestartRenderer, 1)]);
    assert_eq!(
        part(&h, ID).map(|p| p.detail),
        Some("Not responding for 5 s. Restarting it (attempt 1 of 3).".into())
    );
    h.event(ID, "responsive", 7_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);
    assert_eq!(
        receipts(&h, ID),
        vec![(RestartRenderer, Outcome::Started), (RestartRenderer, Outcome::Ok)]
    );

    // A crash is repaired on the next tick, a new episode at step 1.
    h.event(ID, "crashed", 20_000, None);
    assert_eq!(h.next_tick_ms(), Some(20_000));
    assert_eq!(run(&mut h, 20_000), vec![(20_000, RestartRenderer, 1)]);
    h.unregister(ID);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);
}

#[test]
fn acpmux_silent_or_disconnected_reconnects_then_restarts_the_connection() {
    const ID: &str = "acpmux";
    let mut h = model();
    register(&mut h, ID, Kind::Acpmux, "Agent sessions", 0);
    h.beat(ID, 0);
    assert_eq!(h.next_tick_ms(), Some(10_000));
    assert_eq!(run(&mut h, 12_999), vec![(10_000, Reconnect, 1), (12_000, RestartConnection, 2)]);
    assert_eq!(
        part(&h, ID).map(|p| p.detail),
        Some(
            "Agent sessions have not answered for 12 s. Restarting the connection (attempt 2 of \
             3)."
            .into()
        )
    );
    h.event(ID, "connected", 13_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), Some(23_000));

    h.event(ID, "disconnected", 15_000, None);
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Stuck));
    assert_eq!(run(&mut h, 15_000), vec![(15_000, Reconnect, 1)]);
    h.beat(ID, 15_500);
    assert_eq!(part(&h, ID), None);
}

/// Fail all automatic attempts at the same instant, without waiting out backoff.
fn exhausted_connection(now: u64) -> Health {
    let mut h = model();
    register(&mut h, "acpmux", Kind::Acpmux, "Agent sessions", now);
    h.event("acpmux", "disconnected", now, None);
    for (index, expected) in
        [Reconnect, RestartConnection, RestartConnection].into_iter().enumerate()
    {
        let actions = h.tick(now);
        assert_eq!(actions.len(), 1);
        let action = &actions[0];
        assert_eq!((action.action, action.attempt), (expected, index as u32 + 1));
        h.repair_result("acpmux", action.action, Some(action.token), false, now);
    }
    assert!(h.tick(now).is_empty(), "the cap still prevents a fourth attempt");
    h
}

#[test]
fn exhausted_reconnect_stays_quiet_until_ten_seconds_then_requests_action() {
    let mut h = exhausted_connection(1_000);
    assert_eq!(h.snapshot().worst, State::Repairing);
    assert_eq!(h.next_tick_ms(), Some(11_000));
    assert_eq!(h.heap_sizes().0, 1, "the existing part deadline is the only live timer");

    // A repeated failure cannot accelerate or restart the escalation bound.
    h.repair_result("acpmux", RestartConnection, Some(3), false, 2_000);
    assert_eq!(h.next_tick_ms(), Some(11_000));
    assert!(h.tick(10_999).is_empty());
    assert_eq!(h.snapshot().worst, State::Repairing);
    assert!(h.tick(11_000).is_empty(), "escalation does not send another repair");
    let failed = part(&h, "acpmux").expect("failed connection");
    assert_eq!((failed.state, failed.can_repair), (State::Failed, true));
    assert_eq!(
        h.next_tick_ms(),
        Some(601_000),
        "a failed part retries by itself when its oldest attempt leaves the window"
    );
}

#[test]
fn recovery_before_the_failure_bound_cancels_connection_escalation() {
    let mut h = exhausted_connection(1_000);
    h.event("acpmux", "connected", 10_999, None);
    assert_eq!(part(&h, "acpmux"), None);
    assert_eq!(h.next_tick_ms(), Some(20_999), "only ordinary liveness remains armed");
    assert!(h.tick(11_000).is_empty());
    assert_eq!(h.snapshot().worst, State::Healthy);

    // The spent cap survives recovery, but a new short outage gets its own bound.
    h.event("acpmux", "disconnected", 12_000, None);
    assert!(h.tick(12_000).is_empty());
    assert_eq!(h.snapshot().worst, State::Repairing);
    assert_eq!(h.next_tick_ms(), Some(22_000));
    assert!(h.tick(22_000).is_empty());
    assert_eq!(h.snapshot().worst, State::Failed);
}

#[test]
fn page_host_restarts_on_two_load_failures_in_30_s_or_a_missing_listener() {
    const ID: &str = "pageHost";
    let mut h = model();
    register(&mut h, ID, Kind::PageHost, "Page server", 0);
    h.event(ID, "loadFailed", 1_000, None);
    h.event(ID, "loadFailed", 40_000, None);
    assert_eq!(part(&h, ID), None, "30 s apart is not broken");
    assert_eq!(h.next_tick_ms(), None);
    h.event(ID, "loadFailed", 50_000, None);
    assert_eq!(run(&mut h, 50_000), vec![(50_000, RestartPageHost, 1)]);
    // Not back in 2 s: again.
    assert_eq!(run(&mut h, 52_000), vec![(52_000, RestartPageHost, 2)]);
    h.event(ID, "loaded", 53_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);

    h.event(ID, "listenerMissing", 60_000, None);
    let stuck = part(&h, ID).expect("listed");
    assert_eq!(stuck.detail, "Pages cannot load: their server is not running.");
    // A new episode starts at step 1; the cap counts the two before it.
    assert_eq!(run(&mut h, 60_000), vec![(60_000, RestartPageHost, 1)]);
    // The cap (3 in 10 min) is spent: the next step gives up.
    assert!(run(&mut h, 70_000).is_empty());
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Failed));
    assert_eq!(h.repair_now(ID, 70_500).len(), 1);
}

#[test]
fn a_long_roster_restore_is_slow_then_stuck_with_no_action() {
    const ID: &str = "roster";
    let mut h = model();
    register(&mut h, ID, Kind::Roster, "Workspace list", 0);
    h.event(ID, "restoreStarted", 0, None);
    assert_eq!(h.next_tick_ms(), Some(30_000));
    assert!(run(&mut h, 30_000).is_empty());
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Slow));
    assert_eq!(h.next_tick_ms(), Some(300_000));
    assert!(run(&mut h, 300_000).is_empty());
    let stuck = part(&h, ID).expect("listed");
    assert_eq!(
        (stuck.state, stuck.action, stuck.can_repair),
        (State::Stuck, RepairAction::None, false)
    );
    assert_eq!(stuck.detail, "Restoring workspaces has run for 5 min without finishing.");
    assert_eq!(h.next_tick_ms(), None);
    h.event(ID, "restoreFinished", 310_000, None);
    assert_eq!(part(&h, ID), None);
}

#[test]
fn pending_actions_list_newest_first_and_count_the_rest() {
    let mut h = model();
    for n in 0..10u64 {
        h.pending(&format!("intent:{n}"), &format!("Close tab {n}"), n);
    }
    let snap = h.snapshot();
    assert_eq!(snap.worst, State::Healthy);
    assert_eq!(snap.pending.len(), 8);
    assert_eq!(snap.pending_more, 2);
    assert_eq!(snap.pending[0].id, "intent:9");
    assert_eq!(snap.pending[0].label, "Close tab 9");
    assert_eq!(snap.pending[0].since_ms, 9);
    for n in 0..9u64 {
        h.pending_done(&format!("intent:{n}"));
    }
    let snap = h.snapshot();
    assert_eq!((snap.pending.len(), snap.pending_more), (1, 0));
    assert_eq!(h.next_tick_ms(), None, "pending items arm no timer");
}

#[test]
fn receipts_keep_the_last_64() {
    let mut h = model();
    register(&mut h, "page:1", Kind::Page, "Notes", 0);
    // Each hang heals after its first attempt; give the cap room with a
    // click every time.
    let mut t = 0;
    for _ in 0..40 {
        h.event("page:1", "crashed", t, None);
        h.repair_now("page:1", t);
        h.beat("page:1", t + 1);
        t += 1_000;
    }
    let snap = h.snapshot();
    assert_eq!(snap.receipts.len(), 64);
    assert!(snap.receipts[0].at_ms > snap.receipts[63].at_ms, "newest first");
}

/// The host's one timer says which part it waits for: at idle on cmux20-bench (2026-11-25) the timer fired
/// every 5 s (`app.health.tick`, 0.22/s) and nothing named the part that kept it armed.
#[test]
fn each_reply_names_the_part_the_next_tick_is_for() {
    const ID: &str = "renderer:9";
    let mut h = model();
    let reply = crate::ops::call(
        &mut h,
        "register",
        &serde_json::json!({ "id": ID, "kind": "renderer", "label": "Web content", "nowMs": 0 }),
    )
    .expect("register");
    assert_eq!(reply.get("nextTickId"), Some(&serde_json::Value::Null), "no timer: no part");
    let reply = crate::ops::call(
        &mut h,
        "event",
        &serde_json::json!({ "id": ID, "event": "unresponsive", "nowMs": 1_000 }),
    )
    .expect("event");
    assert_eq!(reply["nextTickMs"], 6_000);
    assert_eq!(reply["nextTickId"], ID);
}
