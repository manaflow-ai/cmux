//! A page that stops beating, one whose input is never handled, and the
//! host's repair results.

use super::*;
use crate::State;
use crate::RepairAction::{ReloadPage, RestartRenderer};

const ID: &str = "page:42";

#[test]
fn silent_page_climbs_the_ladder_then_fails_and_the_click_restarts_it() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    h.beat(ID, 0);
    assert_eq!(h.next_tick_ms(), Some(5_000));

    // Slow at 5 s silent, no action.
    assert!(h.tick(5_000).is_empty());
    let slow = part(&h, ID).expect("listed");
    assert_eq!((slow.state, slow.action, slow.can_repair), (State::Slow, RepairAction::None, false));
    assert_eq!(h.next_tick_ms(), Some(10_000));

    // Stuck at 10 s: reload at once, then the renderer after 2 s and 10 s.
    assert_eq!(h.tick(10_000).len(), 1);
    let repairing = part(&h, ID).expect("listed");
    assert_eq!(repairing.state, State::Repairing);
    assert_eq!(
        repairing.detail,
        "Not answering for 10 s. Reloading it (attempt 1 of 3); your draft is kept."
    );
    assert_eq!((repairing.attempt, repairing.max_attempts), (1, 3));
    assert_eq!(repairing.next_at_ms, Some(12_000));
    assert!(repairing.can_repair);
    assert_eq!(repairing.label, "Agent chat");
    assert_eq!(repairing.since_ms, 10_000);
    assert_eq!(run(&mut h, 81_999), vec![(12_000, RestartRenderer, 2), (22_000, RestartRenderer, 3)]);

    // The 60 s after the third attempt pass: the cap is spent, `failed`.
    assert_eq!(h.next_tick_ms(), Some(82_000));
    assert!(h.tick(82_000).is_empty());
    let failed = part(&h, ID).expect("listed");
    assert_eq!((failed.state, failed.can_repair), (State::Failed, true));
    assert_eq!(failed.action, RestartRenderer);
    assert!(failed.detail.contains("Tried 3 repairs"), "{}", failed.detail);
    assert_eq!(h.snapshot().worst, State::Failed);
    assert_eq!(h.next_tick_ms(), None, "a failed part waits for the click, no timer");
    assert_eq!(
        receipts(&h, ID),
        vec![
            (ReloadPage, Outcome::Started),
            (RestartRenderer, Outcome::Started),
            (RestartRenderer, Outcome::Started),
            (RestartRenderer, Outcome::GaveUp),
        ]
    );

    // The click clears the cap and starts at step 1.
    let actions = h.repair_now(ID, 90_000);
    assert_eq!(actions.len(), 1);
    assert_eq!((actions[0].action, actions[0].attempt), (ReloadPage, 1));
    assert_eq!(actions[0].id, ID);
    assert_eq!(h.next_tick_ms(), Some(92_000));

    // The beat comes back: healthy, off the snapshot, a recovery receipt.
    h.beat(ID, 91_000);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.snapshot().worst, State::Healthy);
    assert_eq!(receipts(&h, ID).last(), Some(&(ReloadPage, Outcome::Ok)));
    assert_eq!(h.next_tick_ms(), Some(96_000));

    // Hidden: never timed.
    h.visibility(ID, false, 91_500);
    assert_eq!(h.next_tick_ms(), None);
    // Shown: armed from the show.
    h.visibility(ID, true, 200_000);
    assert_eq!(h.next_tick_ms(), Some(205_000));
}

#[test]
fn repair_now_on_a_healthy_page_does_nothing() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    assert!(h.repair_now(ID, 1_000).is_empty());
}

#[test]
fn a_failed_result_advances_the_ladder_at_once_and_ok_alone_never_heals() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    assert_eq!(run(&mut h, 10_000), vec![(10_000, ReloadPage, 1)]);

    // ok: still repairing until the page beats.
    h.repair_result(ID, ReloadPage, true, 10_400);
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Repairing));
    assert_eq!(h.next_tick_ms(), Some(12_000));

    // A stale result (not the step that is out) is ignored.
    h.repair_result(ID, RestartRenderer, false, 10_450);
    assert_eq!(h.next_tick_ms(), Some(12_000));

    // ok: false makes the next step due now.
    h.repair_result(ID, ReloadPage, false, 10_500);
    assert_eq!(h.next_tick_ms(), Some(10_500));
    assert_eq!(run(&mut h, 10_500), vec![(10_500, RestartRenderer, 2)]);
    assert_eq!(
        receipts(&h, ID),
        vec![
            (ReloadPage, Outcome::Started),
            (ReloadPage, Outcome::Ok),
            (ReloadPage, Outcome::Failed),
            (RestartRenderer, Outcome::Started),
        ]
    );

    h.beat(ID, 11_000);
    assert_eq!(part(&h, ID), None);
}

#[test]
fn unhandled_input_is_slow_at_3_s_and_stuck_at_10_s_even_while_beating() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    h.input(ID, 1, 0, 1_000);
    let mut actions = Vec::new();
    let mut slow_at = None;
    for t in (0..=12_000).step_by(500) {
        if t % 2_000 == 0 {
            h.beat(ID, t);
        }
        actions.extend(run(&mut h, t));
        if slow_at.is_none() && part(&h, ID).is_some_and(|p| p.state == State::Slow) {
            slow_at = Some(t);
        }
    }
    assert_eq!(slow_at, Some(4_000));
    assert_eq!(actions, vec![(11_000, ReloadPage, 1)]);
    let stuck = part(&h, ID).expect("listed");
    assert!(stuck.detail.starts_with("Has not handled your clicks or typing for 11 s."));

    // The reloaded page loads: its old input died with it.
    h.event(ID, "loaded", 12_100, None);
    assert_eq!(part(&h, ID), None);
}

#[test]
fn a_crashed_page_is_repaired_on_the_next_tick() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    h.event(ID, "crashed", 1_000, None);
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Stuck));
    assert_eq!(h.next_tick_ms(), Some(1_000), "due at once");
    assert_eq!(run(&mut h, 1_000), vec![(1_000, ReloadPage, 1)]);
    assert_eq!(
        part(&h, ID).map(|p| p.detail),
        Some("Stopped unexpectedly. Reloading it (attempt 1 of 3); your draft is kept.".into())
    );
}

#[test]
fn the_cap_counts_every_episode_in_ten_minutes() {
    let mut h = model();
    register(&mut h, ID, Kind::Page, "Agent chat", 0);
    // Three episodes, each healed by a beat after its first attempt.
    let mut t = 0;
    for _ in 0..3 {
        let acts = run(&mut h, t + 10_000);
        assert_eq!(acts, vec![(t + 10_000, ReloadPage, 1)]);
        h.beat(ID, t + 10_500);
        t += 10_500;
    }
    // The fourth hang inside the window gives up at once.
    assert!(run(&mut h, t + 10_000).is_empty());
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Failed));
}
