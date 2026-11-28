use super::*;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn reading(latency_ms: f64, late: f64) -> Reading {
    Reading { latency_ms, late }
}

/// Each tier's limits, at and past each edge.
#[test]
fn a_reading_meets_the_tier_its_latency_and_late_share_allow() {
    let table = [
        (20.0, 0.0, Tier::Good),
        (200.0, 0.05, Tier::Good),
        (200.1, 0.0, Tier::Slow),
        (20.0, 0.06, Tier::Slow),
        (500.0, 0.20, Tier::Slow),
        (500.1, 0.0, Tier::Poor),
        (20.0, 0.21, Tier::Poor),
        (900.0, 0.0, Tier::Poor),
    ];
    for (latency, late, tier) in table {
        assert_eq!(TierState::first(reading(latency, late)).tier, tier, "{latency} ms, {late}");
    }
}

/// Hysteresis: one reading past a limit moves nothing, two in a row move the tier down; a link
/// back under the limit but not under 80 % of it stays where it is; five readings in a row under
/// 80 % move it up one step.
#[test]
fn the_tier_moves_down_after_two_bad_ticks_and_up_after_five_clear_ones() {
    let mut state = TierState::first(reading(50.0, 0.0));
    assert_eq!(state.tier, Tier::Good);
    // One spike, then back: still good.
    state = state.next(reading(260.0, 0.0));
    assert_eq!(state.tier, Tier::Good);
    state = state.next(reading(50.0, 0.0));
    state = state.next(reading(260.0, 0.0));
    assert_eq!(state.tier, Tier::Good, "a spike's count starts over after a good tick");
    state = state.next(reading(260.0, 0.0));
    assert_eq!(state.tier, Tier::Slow);
    // 180 ms meets good's limit but not 80 % of it (160 ms): slow stays, however long.
    for _ in 0..50 {
        state = state.next(reading(180.0, 0.0));
    }
    assert_eq!(state.tier, Tier::Slow, "a link that sits on the limit does not flap");
    for _ in 0..4 {
        state = state.next(reading(150.0, 0.0));
    }
    assert_eq!(state.tier, Tier::Slow);
    state = state.next(reading(150.0, 0.0));
    assert_eq!(state.tier, Tier::Good);
    // Down to poor at once from good (two ticks), up one step at a time.
    state = state.next(reading(900.0, 0.0)).next(reading(900.0, 0.0));
    assert_eq!(state.tier, Tier::Poor);
    for _ in 0..5 {
        state = state.next(reading(20.0, 0.0));
    }
    assert_eq!(state.tier, Tier::Slow, "poor comes up one step");
    for _ in 0..5 {
        state = state.next(reading(20.0, 0.0));
    }
    assert_eq!(state.tier, Tier::Good);
}

/// A link that alternates across a limit every tick never moves.
#[test]
fn a_link_that_alternates_across_a_limit_keeps_its_tier() {
    let mut state = TierState::first(reading(190.0, 0.0));
    let mut moves = 0;
    for n in 0..200 {
        let next = state.next(reading(if n % 2 == 0 { 210.0 } else { 190.0 }, 0.0));
        moves += usize::from(next.tier != state.tier);
        state = next;
    }
    assert_eq!((state.tier, moves), (Tier::Good, 0));
}

/// RFC 6298's first sample and its smoothing.
#[test]
fn the_estimator_follows_rfc_6298() {
    let mut rtt = RttEstimator::default();
    assert_eq!(rtt.rto(), None);
    rtt.sample(ms(100));
    assert_eq!((rtt.srtt(), rtt.rttvar()), (Some(ms(100)), Some(ms(50))));
    assert_eq!(rtt.rto(), Some(ms(300)));
    rtt.sample(ms(180));
    // rttvar = 3/4 * 50 + 1/4 * 80 = 57.5; srtt = 7/8 * 100 + 1/8 * 180 = 110.
    assert_eq!(rtt.rttvar(), Some(Duration::from_micros(57_500)));
    assert_eq!(rtt.srtt(), Some(ms(110)));
}

fn steady(rtt_ms: u64, jitter_ms: u64) -> RttEstimator {
    let mut rtt = RttEstimator::default();
    for n in 0..64 {
        rtt.sample(ms(if n % 2 == 0 { rtt_ms + jitter_ms } else { rtt_ms - jitter_ms }));
    }
    rtt
}

/// The probe's wait: 2 s until a round trip is known and for any link under about 400 ms,
/// four timeouts above that, never over 6 s.
#[test]
fn the_probe_waits_four_timeouts_between_2_and_6_s() {
    let floor = Duration::from_secs(2);
    assert_eq!(probe_wait(&RttEstimator::default(), floor), floor, "nothing measured: today's 2 s");
    assert_eq!(probe_wait(&steady(20, 2), floor), floor);
    assert_eq!(probe_wait(&steady(150, 15), floor), floor);
    let at_800 = probe_wait(&steady(800, 80), floor);
    assert!(at_800 > Duration::from_secs(3) && at_800 < Duration::from_secs(5), "{at_800:?}");
    assert_eq!(probe_wait(&steady(3_000, 300), floor), PROBE_MOST, "capped");
    // A floor set past the cap (a test, an env) is kept.
    assert_eq!(probe_wait(&steady(20, 2), Duration::from_secs(9)), Duration::from_secs(9));
}

/// The silence budget's floor: today's 6 s below about 700 ms, never over 12 s.
#[test]
fn the_silence_floor_is_6_s_until_the_link_is_slow_and_at_most_12_s() {
    let (every, base) = (Duration::from_secs(2), Duration::from_secs(6));
    assert_eq!(silence_floor(&RttEstimator::default(), every, base), base);
    for rtt in [20, 150, 400] {
        assert_eq!(silence_floor(&steady(rtt, rtt / 10), every, base), base, "{rtt} ms");
    }
    let at_800 = silence_floor(&steady(800, 80), every, base);
    assert!(at_800 > base && at_800 < Duration::from_secs(8), "{at_800:?}");
    assert_eq!(silence_floor(&steady(5_000, 500), every, base), base * 2, "capped at 12 s");
}

/// The tier waits for a round trip (a late tick before it is the link opening), and the late share is over the last minute only.
#[test]
fn quality_reads_null_until_a_pong_and_forgets_late_ticks_after_a_minute() {
    let mut q = LinkQuality::default();
    q.tick(true);
    assert_eq!(q.view(), Value::Null);
    q.pong(ms(30));
    q.tick(false);
    assert_eq!(q.view()["tier"], "good");
    // Ten late ticks of thirty: a third of the minute, poor.
    for _ in 0..10 {
        q.tick(true);
    }
    assert_eq!(q.tier(), Some(Tier::Poor));
    for _ in 0..LATE_WINDOW {
        q.tick(false);
    }
    assert_eq!(q.view()["lateShare"], 0.0);
    // Up one step per five clear ticks once under 80 % of the limits.
    for _ in 0..10 {
        q.tick(false);
    }
    assert_eq!(q.tier(), Some(Tier::Good));
}
