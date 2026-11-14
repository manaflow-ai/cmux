use super::*;

const HOUR_MS: u64 = 60 * 60 * 1000;

fn sid(id: u64) -> SurfaceId {
    id
}

fn idle(surface: u64, since_ms: u64) -> ReclaimCandidate {
    ReclaimCandidate {
        surfaces: vec![sid(surface)],
        prompt_since_ms: Some(since_ms),
        attached: false,
        kept: false,
        last_output_ms: Some(since_ms),
        program_reported: false,
    }
}

#[test]
fn parks_only_idle_quiet_unwatched_unkept_shells_oldest_first() {
    let now = 200 * HOUR_MS;
    let busy = ReclaimCandidate { prompt_since_ms: None, ..idle(2, 0) };
    let watched = ReclaimCandidate { attached: true, ..idle(3, 0) };
    let kept = ReclaimCandidate { kept: true, ..idle(4, 0) };
    let agent = ReclaimCandidate { program_reported: true, ..idle(5, 0) };
    let printing = ReclaimCandidate { last_output_ms: Some(now - 1000), ..idle(6, 0) };
    let fresh = idle(7, now - 10 * 60 * 1000);
    let candidates =
        [idle(1, 50 * HOUR_MS), busy, watched, kept, agent, printing, fresh, idle(8, HOUR_MS)];
    assert_eq!(
        pick_reclaim(&candidates, now, 10),
        [sid(8), sid(1)],
        "the oldest prompt first; nothing busy, watched, kept, reporting, printing or fresh"
    );
    assert_eq!(pick_reclaim(&candidates, now, 1), [sid(8)]);
    assert!(pick_reclaim(&candidates, now, 0).is_empty());
}

#[test]
fn park_tabs_leaves_watched_and_kept_terminals_running() {
    let watched = ReclaimCandidate { attached: true, surfaces: vec![sid(2), sid(3)], ..idle(2, 0) };
    let kept = ReclaimCandidate { kept: true, ..idle(4, 0) };
    let busy = ReclaimCandidate { prompt_since_ms: None, ..idle(5, 0) };
    let candidates = [idle(1, 0), watched, kept, busy];
    assert_eq!(
        drop_watched(&candidates, &[sid(1), sid(3), sid(4), sid(5), sid(9)]),
        [sid(1), sid(5), sid(9)],
        "every view of an attached terminal stays; a busy shell is the caller's choice"
    );
}

#[test]
fn reclaims_only_under_the_reserve_and_refills_past_it() {
    assert_eq!(reclaim_need(100, 511), 0);
    assert_eq!(reclaim_need(511 - PTY_RESERVE, 511), 0);
    assert_eq!(reclaim_need(511 - PTY_RESERVE + 1, 511), PTY_REFILL - PTY_RESERVE + 1);
    assert_eq!(reclaim_need(511, 511), PTY_REFILL);
    assert_eq!(reclaim_need(527, 511), PTY_REFILL, "more nodes than the limit");
    assert_eq!(reclaim_need(40, 50), 50 - 10, "a limit under the refill frees what it can");
}

#[test]
fn counts_only_numbered_pty_nodes() {
    assert!(is_pty_node("ttys000"));
    assert!(is_pty_node("ttys510"));
    assert!(!is_pty_node("ttys0"), "legacy node");
    assert!(!is_pty_node("ttysf"));
    assert!(!is_pty_node("ttyp000"));
}

#[test]
fn a_failed_launch_forces_the_next_pass() {
    let mut clock = ReclaimClock::default();
    let start = Instant::now();
    assert!(clock.due(start, false));
    assert!(!clock.due(start + Duration::from_millis(10), false));
    assert!(clock.due(start + Duration::from_millis(20), true));
    assert!(clock.due(start + RECLAIM_CHECK_EVERY * 2, false));
}
