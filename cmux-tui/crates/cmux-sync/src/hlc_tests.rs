use super::*;

fn clock(id: &str) -> Clock {
    Clock::new(Actor::new(id))
}

#[test]
fn stamps_never_go_backwards_when_the_wall_clock_does() {
    let mut c = clock("a");
    let first = c.now(1_000);
    let second = c.now(900);
    let third = c.now(900);
    assert!(first < second && second < third, "{first:?} {second:?} {third:?}");
    assert_eq!(second.ms, 1_000);
}

#[test]
fn an_edit_after_seeing_a_remote_one_orders_after_it_even_with_a_slow_clock() {
    let mut fast = clock("fast");
    let mut slow = clock("slow");
    let theirs = fast.now(10_000);
    slow.observe(&theirs, 2_000);
    let mine = slow.now(2_001);
    assert!(mine > theirs);
}

#[test]
fn observe_reports_how_far_ahead_a_remote_clock_runs() {
    let mut c = clock("a");
    let ahead = Stamp { ms: 5_000, n: 0, actor: Actor::new("b") };
    assert_eq!(c.observe(&ahead, 1_000), 4_000);
    assert_eq!(c.observe(&ahead, 9_000), 0);
}

#[test]
fn a_far_ahead_remote_does_not_poison_future_local_stamps() {
    let mut c = clock("a");
    let far = Stamp { ms: MAX_DRIFT_MS + 10_000, n: 0, actor: Actor::new("b") };
    assert_eq!(c.observe(&far, 0), MAX_DRIFT_MS + 10_000);
    assert_eq!(c.now(1).ms, 1);
}

#[test]
fn the_actor_breaks_ties() {
    let a = Stamp { ms: 1, n: 0, actor: Actor::new("a") };
    let b = Stamp { ms: 1, n: 0, actor: Actor::new("b") };
    assert!(a < b);
}

#[test]
fn the_counter_overflow_borrows_the_next_millisecond() {
    let mut c = clock("a");
    c.ms = 7;
    c.n = u32::MAX;
    let s = c.now(7);
    assert_eq!((s.ms, s.n), (8, 0));
}
