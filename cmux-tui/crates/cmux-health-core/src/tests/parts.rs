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
