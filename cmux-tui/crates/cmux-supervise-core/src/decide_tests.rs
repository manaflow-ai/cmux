use super::*;
use crate::budget::StopCause;

const BOUND: Duration = Duration::from_secs(60);

fn facts<'a>(liveness: Liveness, stall: &'a Stall, now: Duration) -> Facts<'a> {
    Facts { liveness, stall, bound: BOUND, now, intent: None, budget_exceeded: false }
}

fn s(secs: u64) -> Duration {
    Duration::from_secs(secs)
}

#[test]
fn time_alone_never_restarts() {
    // One failed look, then the machine slept for a day: one look is no proof.
    let mut stall = Stall::default();
    stall.look(Progress::Stalled, s(0));
    assert_eq!(decide(facts(Liveness::Alive, &stall, s(86_400))), Decision::Keep);
    // Many failed looks, but all inside the bound (a slow disk's 10 s fsync).
    let mut stall = Stall::default();
    for t in 0..50 {
        stall.look(Progress::Stalled, s(t));
    }
    assert_eq!(decide(facts(Liveness::Alive, &stall, s(50))), Decision::Keep);
}

#[test]
fn a_stall_over_the_whole_bound_restarts_and_one_move_clears_it() {
    let mut stall = Stall::default();
    for t in [0, 20, 40] {
        stall.look(Progress::Stalled, s(t));
    }
    stall.look(Progress::Moved, s(55));
    stall.look(Progress::Stalled, s(56));
    assert_eq!(decide(facts(Liveness::Alive, &stall, s(70))), Decision::Keep);
    for t in [80, 100, 117] {
        stall.look(Progress::Stalled, s(t));
    }
    assert!(matches!(
        decide(facts(Liveness::Alive, &stall, s(117))),
        Decision::Restart(StopCause::NoProgress(_))
    ));
}

#[test]
fn unknown_keeps_dead_restarts_meant_stays_stopped_over_budget_holds() {
    let stall = Stall::default();
    assert_eq!(decide(facts(Liveness::Unknown, &stall, s(0))), Decision::Keep);
    assert!(matches!(
        decide(facts(Liveness::Dead, &stall, s(0))),
        Decision::Restart(StopCause::Died(_))
    ));
    let quit = Facts { intent: Some("person quit"), ..facts(Liveness::Dead, &stall, s(0)) };
    assert_eq!(decide(quit), Decision::StayStopped("person quit".into()));
    let over = Facts { budget_exceeded: true, ..facts(Liveness::Dead, &stall, s(0)) };
    assert_eq!(decide(over), Decision::Hold);
}

#[test]
fn a_meant_stop_that_stalls_past_the_bound_is_never_restarted() {
    let mut stall = Stall::default();
    for t in [0, 30, 61] {
        stall.look(Progress::Stalled, s(t));
    }
    let stopping = Facts { intent: Some("person quit"), ..facts(Liveness::Alive, &stall, s(61)) };
    assert_eq!(decide(stopping), Decision::Keep);
}
