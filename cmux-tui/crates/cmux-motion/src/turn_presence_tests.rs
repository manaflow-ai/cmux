use super::*;

/// Drives `steps` (time, running, immediate) through the model at every
/// millisecond and returns each drawn span as (from, to, shown).
fn spans(start: bool, steps: &[(u64, bool, bool)], until: u64) -> Vec<(u64, u64, bool)> {
    let mut model = TurnPresence::new(start, 0);
    let mut out = Vec::new();
    let mut from = 0;
    let mut shown = model.shown();
    let mut next = 0;
    for at in 0..=until {
        while next < steps.len() && steps[next].0 == at {
            model.set(steps[next].1, at, steps[next].2);
            next += 1;
        }
        model.advance(at);
        if model.shown() != shown {
            out.push((from, at, shown));
            from = at;
            shown = model.shown();
        }
    }
    out.push((from, until, shown));
    out
}

#[test]
fn the_first_state_draws_at_once() {
    assert!(TurnPresence::new(true, 5).shown());
    assert!(!TurnPresence::new(false, 5).shown());
}

#[test]
fn a_turn_shorter_than_the_dwell_never_shows_stop() {
    let drawn = spans(false, &[(100, true, false), (180, false, false)], 2_000);
    assert_eq!(drawn, vec![(0, 2_000, false)]);
}

#[test]
fn a_send_shows_stop_at_once() {
    let mut model = TurnPresence::new(false, 0);
    model.set(true, 50, true);
    assert!(model.shown());
}

#[test]
fn a_turn_that_starts_inside_the_linger_keeps_stop_and_pulses() {
    let mut model = TurnPresence::new(true, 0);
    model.set(false, 1_000, false);
    assert!(model.lingering());
    model.set(true, 1_005, false);
    assert!(model.shown());
    assert_eq!(model.pulses(), 1);
    assert_eq!(model.next_wake(), None);
}

#[test]
fn rapid_bursts_never_toggle_stop_for_less_than_the_hold() {
    // A turn that ends and starts again every 20-1000 ms, for 10 s: some
    // restarts land inside the linger (a pulse), some after it.
    let mut steps = Vec::new();
    let mut at = 10;
    let mut running = false;
    let mut seed = 7u64;
    while at < 10_000 {
        running = !running;
        steps.push((at, running, false));
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
        at += 20 + (seed >> 33) % 980;
    }
    let drawn = spans(false, &steps, 12_000);
    assert!(drawn.len() > 4, "the bursts drew Stop: {drawn:?}");
    // The first span is the chat's first draw, the last is cut at `until`.
    for &(from, to, _) in &drawn[1..drawn.len() - 1] {
        assert!(to - from >= TURN_PRESENCE_HOLD_MS, "a span of {} ms: {drawn:?}", to - from);
    }
}
