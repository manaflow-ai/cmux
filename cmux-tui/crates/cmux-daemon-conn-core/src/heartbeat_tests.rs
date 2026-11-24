use super::*;

#[test]
fn misses_mark_not_answering_while_alive_and_an_answer_clears_it() {
    let mut beat = CmuxHeartbeat::default();
    let (run, tell) = beat.start();
    assert!(!tell);
    assert_eq!(
        beat.tick(run, false, 2, true),
        CmuxHeartbeatStep { action: 2, tell: false, answering: true }
    );
    assert_eq!(
        beat.tick(run, false, 2, true),
        CmuxHeartbeatStep { action: 2, tell: true, answering: false }
    );
    // Past the misses each unanswered ask tells again.
    assert_eq!(
        beat.tick(run, false, 2, true),
        CmuxHeartbeatStep { action: 2, tell: true, answering: false }
    );
    assert_eq!(
        beat.tick(run, true, 2, true),
        CmuxHeartbeatStep { action: 2, tell: true, answering: true }
    );
    assert_eq!(
        beat.tick(run, true, 2, true),
        CmuxHeartbeatStep { action: 2, tell: false, answering: true }
    );
}

#[test]
fn a_dead_peer_closes_and_a_stale_run_does_nothing() {
    let mut beat = CmuxHeartbeat::default();
    let (run, _) = beat.start();
    assert_eq!(beat.tick(run, false, 1, false).action, STEP_CLOSE);
    assert!(!beat.stop());
    assert_eq!(beat.tick(run, false, 1, true).action, STEP_STALE);
}
