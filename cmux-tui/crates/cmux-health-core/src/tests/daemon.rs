//! The session daemon: the 2026-11-09 restart loop, a restore that makes
//! progress (never repaired), one that stalls (never killed) and an
//! oversized registry.

use super::*;
use crate::State;

const ID: &str = "sessionDaemon";
const GB: u64 = 1_000_000_000;

fn daemon() -> Health {
    let mut h = model();
    register(&mut h, ID, Kind::SessionDaemon, "Session service", 0);
    h
}

#[test]
fn three_starts_without_ready_hold_the_replace_once_per_process() {
    let mut h = daemon();
    assert_eq!(h.next_tick_ms(), None);
    for at in [0, 180_000] {
        h.event(ID, "started", at, None);
        assert!(run(&mut h, at).is_empty());
    }
    assert_eq!(part(&h, ID), None, "two starts are not a loop");
    h.event(ID, "started", 360_000, None);
    assert_eq!(run(&mut h, 360_000), vec![(360_000, RepairAction::HoldReplace, 1)]);
    let stuck = part(&h, ID).expect("listed");
    assert_eq!(stuck.state, State::Stuck);
    assert_eq!(stuck.action, RepairAction::HoldReplace);
    assert!(!stuck.can_repair);
    assert_eq!(
        stuck.detail,
        "The session service restarted 3 times in 6 min without finishing startup. Holding \
         restarts so the current one can finish restoring."
    );
    // Held once for this process: the only timer is the loop's end.
    assert_eq!(h.next_tick_ms(), Some(600_000));
    assert!(h.repair_now(ID, 361_000).is_empty(), "nothing for the user to click");

    // A fourth process: hold it too.
    h.event(ID, "started", 420_000, None);
    assert_eq!(run(&mut h, 420_000), vec![(420_000, RepairAction::HoldReplace, 2)]);

    // It finishes startup: healthy, no timer.
    h.event(ID, "ready", 500_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);
    assert_eq!(
        receipts(&h, ID),
        vec![
            (RepairAction::HoldReplace, Outcome::Started),
            (RepairAction::HoldReplace, Outcome::Started),
            (RepairAction::HoldReplace, Outcome::Ok),
        ]
    );
}

#[test]
fn a_loop_ages_out_of_the_window() {
    let mut h = daemon();
    for at in [0, 60_000, 120_000] {
        h.event(ID, "started", at, None);
    }
    run(&mut h, 120_000);
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Stuck));
    // The first start leaves the 10 min window: no longer a loop.
    assert!(run(&mut h, 600_000).is_empty());
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);
}

#[test]
fn a_restore_that_makes_progress_is_slow_and_never_repaired() {
    let mut h = daemon();
    h.event(ID, "started", 0, None);
    let mut actions = Vec::new();
    // 30 min of restore, 1 GB a minute.
    for minute in 1..=30u64 {
        let at = minute * 60_000;
        h.event(ID, "restoreProgress", at, Some(minute * GB));
        actions.extend(run(&mut h, at));
        assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Slow), "minute {minute}");
    }
    assert!(actions.is_empty(), "a restore that progresses is never repaired: {actions:?}");
    h.event(ID, "restoreProgress", 1_860_000, Some(31 * GB + 400_000_000));
    let slow = part(&h, ID).expect("listed");
    assert_eq!(slow.detail, "Restoring workspaces, 31.4 GB read");
    assert_eq!((slow.action, slow.can_repair), (RepairAction::None, false));
    h.event(ID, "ready", 1_900_000, None);
    assert_eq!(part(&h, ID), None);
    assert_eq!(h.next_tick_ms(), None);
}

#[test]
fn a_stalled_restore_is_stuck_with_no_action_and_resumes() {
    let mut h = daemon();
    h.event(ID, "started", 0, None);
    h.event(ID, "restoreProgress", 1_000, Some(12_400_000_000));
    assert_eq!(part(&h, ID).map(|p| p.detail), Some("Restoring workspaces, 12.4 GB read".into()));
    // The same value again is not progress.
    h.event(ID, "restoreProgress", 60_000, Some(12_400_000_000));
    assert_eq!(h.next_tick_ms(), Some(121_000));
    assert!(run(&mut h, 121_000).is_empty(), "a restore is never killed");
    let stuck = part(&h, ID).expect("listed");
    assert_eq!(stuck.state, State::Stuck);
    assert_eq!(
        (stuck.action, stuck.can_repair, stuck.max_attempts),
        (RepairAction::None, false, 0)
    );
    assert_eq!(
        stuck.detail,
        "Restoring workspaces has made no progress for 2 min (12.4 GB read). Waiting; a restore \
         is never interrupted."
    );
    assert_eq!(h.next_tick_ms(), None);
    h.event(ID, "restoreProgress", 130_000, Some(13 * GB));
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Slow));
}

#[test]
fn an_oversized_registry_is_slow_and_the_worse_cause_wins() {
    let mut h = daemon();
    h.size(ID, 59 * GB, 0);
    let slow = part(&h, ID).expect("listed");
    assert_eq!(slow.state, State::Slow);
    assert_eq!(slow.detail, "Workspace data is 59 GB; startup will be slow");
    assert_eq!(h.next_tick_ms(), None, "a size alone arms nothing");

    // A loop on top of it: stuck, with the loop's words.
    for at in [10_000, 20_000, 30_000] {
        h.event(ID, "started", at, None);
    }
    run(&mut h, 30_000);
    let stuck = part(&h, ID).expect("listed");
    assert_eq!(stuck.state, State::Stuck);
    assert!(stuck.detail.starts_with("The session service restarted 3 times in 20 s"));

    // Ready: back to the size alone.
    h.event(ID, "ready", 40_000, None);
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Slow));
    h.size(ID, 7 * GB, 50_000);
    assert_eq!(part(&h, ID), None);
}

#[test]
fn a_restore_with_its_data_size_reads_as_a_percent_and_without_counters_as_restoring() {
    let mut h = daemon();
    h.size(ID, 59 * GB, 0);
    h.event(ID, "started", 0, None);
    h.event(ID, "restoreProgress", 1_000, None);
    assert_eq!(part(&h, ID).map(|p| p.detail), Some("Restoring workspaces".into()));
    // Lines with no counters keep it restoring past the stall bound.
    for second in (5..=300).step_by(5) {
        h.event(ID, "restoreProgress", second * 1_000, None);
        assert!(run(&mut h, second * 1_000).is_empty());
    }
    assert_eq!(part(&h, ID).map(|p| p.state), Some(State::Slow));
    h.event(ID, "restoreProgress", 301_000, Some(GB * 59 / 4));
    assert_eq!(part(&h, ID).map(|p| p.detail), Some("Restoring workspaces, about 25%".into()));
    h.event(ID, "restoreProgress", 302_000, Some(60 * GB));
    assert_eq!(part(&h, ID).map(|p| p.detail), Some("Restoring workspaces, about 99%".into()));
}
