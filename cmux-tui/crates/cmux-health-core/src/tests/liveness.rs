//! A renderer of visible agent chats whose main thread never runs again (a page stuck in
//! `for (;;) {}`): its pages rest, so no beat says anything; the model pings it, and only two
//! pings unanswered over 30 s, visible and awake, end it. Every way the time may not count voids
//! the pings, and a hidden or quiet app arms nothing.

use super::*;
use crate::RepairAction::{self, EndRenderer, Ping};
use crate::State;
use crate::policy::{
    LIVENESS_HUNG_MS, LIVENESS_LATE_MS, LIVENESS_PING_EVERY_MS, LIVENESS_QUIET_MS, REPAIR_WINDOW_MS,
};

const ID: &str = "liveness:7";

/// A renderer whose one visible chat beat at 0 and rests.
fn resting_renderer() -> Health {
    let mut h = model();
    register(&mut h, ID, Kind::Liveness, "Agent chats", 0);
    h.rest(ID, 0);
    h
}

#[test]
fn a_page_that_never_answers_gets_two_pings_then_its_renderer_ends() {
    let mut h = resting_renderer();
    // Quiet 15 s: the first ping, nothing else.
    assert_eq!(h.next_tick_ms(), Some(LIVENESS_QUIET_MS));
    assert_eq!(run(&mut h, 15_000), vec![(15_000, Ping, 0)]);
    assert_eq!(part(&h, ID), None, "a ping out is no fault yet");
    // Unanswered 15 s: the second.
    assert_eq!(h.next_tick_ms(), Some(15_000 + LIVENESS_PING_EVERY_MS));
    assert_eq!(run(&mut h, 30_000), vec![(30_000, Ping, 0)]);
    // Both unanswered, 30 s since the first: the renderer ends, naming how long it was silent.
    assert_eq!(h.next_tick_ms(), Some(15_000 + LIVENESS_HUNG_MS));
    let actions = h.tick(45_000);
    assert_eq!(actions.len(), 1);
    let end = &actions[0];
    assert_eq!(
        (end.id.as_str(), end.kind, end.action, end.attempt),
        (ID, Kind::Liveness, EndRenderer, 1)
    );
    assert_eq!(end.hung_ms, Some(45_000));
    let shown = part(&h, ID).expect("listed");
    assert_eq!(shown.state, State::Repairing);
    assert_eq!(shown.detail, "Not answering for 45 s. Restarting its chats (attempt 1 of 3).");
    // The new renderer's first beat ends the episode; pings were never receipts.
    h.beat(ID, 50_000);
    assert_eq!(part(&h, ID), None);
    assert_eq!(receipts(&h, ID), vec![(EndRenderer, Outcome::Started), (EndRenderer, Outcome::Ok)]);
}

#[test]
fn an_answered_ping_never_ends_anything() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 15_000), vec![(15_000, Ping, 0)]);
    // The answer is a beat: a new quiet wait from it.
    h.beat(ID, 15_020);
    assert_eq!(h.next_tick_ms(), Some(15_020 + LIVENESS_QUIET_MS));
    // An hour of a healthy resting chat: one ping per quiet wait, each answered, no end.
    let mut pings = 0;
    while let Some(at) = h.next_tick_ms().filter(|&at| at <= 3_600_000) {
        for action in h.tick(at) {
            assert_eq!(action.action, Ping);
            pings += 1;
            h.beat(ID, at + 5);
        }
    }
    // One per quiet wait: 15 s, plus the 5 ms each answer takes.
    assert_eq!(pings, 238);
    assert!(h.snapshot().receipts.is_empty());
}

#[test]
fn a_page_that_beats_is_never_pinged() {
    let mut h = resting_renderer();
    // A chat that streams or takes typing beats every 2 s: its beat is the answer, no ping.
    for at in (2_000..=120_000).step_by(2_000) {
        assert!(run(&mut h, at - 1).is_empty());
        h.beat(ID, at);
    }
    assert_eq!(h.next_tick_ms(), Some(120_000 + LIVENESS_QUIET_MS));
}

#[test]
fn one_ping_answered_late_and_one_unanswered_is_not_hung() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 30_000), vec![(15_000, Ping, 0), (30_000, Ping, 0)]);
    // A busy main thread answers just before the limit: the count starts over.
    h.beat(ID, 44_999);
    assert!(run(&mut h, 44_999 + LIVENESS_QUIET_MS - 1).is_empty());
    assert_eq!(part(&h, ID), None);
}

#[test]
fn a_hidden_renderer_has_no_timer_and_its_pings_are_void() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 30_000).len(), 2);
    // Hidden with both pings out: no timer at all, and nothing ends.
    h.visibility(ID, false, 31_000);
    assert_eq!(h.next_tick_ms(), None);
    assert!(run(&mut h, 10_000_000).is_empty());
    // Shown again: a whole new count from the show (quiet wait, two pings, 30 s).
    h.visibility(ID, true, 100_000);
    assert_eq!(run(&mut h, 144_999), vec![(115_000, Ping, 0), (130_000, Ping, 0)]);
    assert_eq!(h.tick(145_000).first().map(|a| a.action), Some(EndRenderer));
}

#[test]
fn sleep_wake_or_a_debugger_voids_the_pings_out() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 30_000).len(), 2);
    // The Mac slept (the host's `void` on sleep and wake): a ping sent before it says nothing.
    h.event(ID, "void", 40_000, None);
    assert_eq!(h.next_tick_ms(), Some(40_000 + LIVENESS_QUIET_MS));
    assert!(
        run(&mut h, 40_000 + LIVENESS_QUIET_MS + LIVENESS_HUNG_MS - 1)
            .iter()
            .all(|&(_, action, _)| action == Ping)
    );
    // A debugger paused the page at the moment it would end: the host voids instead of ending.
    h.event(ID, "void", 85_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), Some(85_000 + LIVENESS_QUIET_MS));
}

#[test]
fn a_late_tick_voids_the_pings_out() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 30_000).len(), 2);
    // The deadline was 45 s; the host's timer fired 20 s late (App Nap, the app stopped in a
    // debugger): its own time did not run, so nothing ends, and the count starts over.
    let late = 45_000 + LIVENESS_LATE_MS + 15_000;
    assert!(h.tick(late).is_empty());
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), Some(late + LIVENESS_QUIET_MS));
    // A tick only a little late still counts.
    assert_eq!(run(&mut h, late + 30_000).len(), 2);
    let on_time = late + LIVENESS_QUIET_MS + LIVENESS_HUNG_MS + LIVENESS_LATE_MS;
    assert_eq!(h.tick(on_time).first().map(|a| a.action), Some(EndRenderer));
}

#[test]
fn a_renderer_that_stays_hung_is_ended_at_most_three_times_then_fails() {
    let mut h = resting_renderer();
    let ends = |actions: Vec<(u64, RepairAction, u32)>| -> Vec<_> {
        actions.into_iter().filter(|&(_, action, _)| action == EndRenderer).collect()
    };
    // Three ends in the repair window, then failed.
    let window_end = 45_000 + REPAIR_WINDOW_MS;
    assert_eq!(
        ends(run(&mut h, window_end - 1)),
        vec![(45_000, EndRenderer, 1), (75_000, EndRenderer, 2), (105_000, EndRenderer, 3)]
    );
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Failed));
    // The cap holds only within the window: once the first end leaves it, the part tries again by
    // itself, from step 1, with no click.
    assert_eq!(h.next_tick_ms(), Some(window_end), "a failed part re-arms when its window frees");
    assert_eq!(ends(run(&mut h, window_end)), vec![(window_end, EndRenderer, 1)]);
}

#[test]
fn unregistering_the_renderer_stops_its_timer() {
    let mut h = resting_renderer();
    assert_eq!(run(&mut h, 15_000).len(), 1);
    h.unregister(ID);
    assert_eq!(h.next_tick_ms(), None);
}

#[test]
fn many_resting_renderers_cost_one_deadline_each_and_hidden_ones_none() {
    let mut h = model();
    for n in 0..64 {
        let id = format!("liveness:{n}");
        register(&mut h, &id, Kind::Liveness, "Agent chats", 0);
        h.rest(&id, 0);
        if n >= 4 {
            h.visibility(&id, false, 0);
        }
    }
    // Four visible renderers: four pings at 15 s, and nothing armed for the 60 hidden.
    assert_eq!(h.heap_sizes().0, 4);
    assert_eq!(run(&mut h, 15_000).len(), 4);
}
