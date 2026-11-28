use super::*;

fn at(start: Instant, ms: u64) -> Instant {
    start + Duration::from_millis(ms)
}

#[test]
fn three_bursts_on_a_grid_give_a_period_and_a_window() {
    let start = Instant::now();
    let mut period = LossPeriod::default();
    for onset in [0, 45_000, 90_100] {
        assert!(period.loss(at(start, onset)));
        assert!(!period.loss(at(start, onset + 200)), "same burst");
    }
    let learned = period.period().expect("a period");
    assert!(learned.abs_diff(Duration::from_millis(45_050)) < Duration::from_millis(10));
    assert!(!period.armed(at(start, 100_000)), "between bursts");
    assert!(period.armed(at(start, 134_500)), "within LEAD of the next");
    assert!(period.armed(at(start, 136_500)), "within TAIL after it");
    assert!(!period.armed(at(start, 138_000)), "past it");
    assert!(period.armed(at(start, 179_800)), "the one after, unseen");
    assert!(!period.armed(at(start, 90_100 + 45_050 * 9)), "lapsed");
}

#[test]
fn a_skipped_burst_is_a_multiple_and_noise_is_not_a_period() {
    let start = Instant::now();
    let mut period = LossPeriod::default();
    for onset in [0, 15_000, 45_200, 60_100] {
        period.loss(at(start, onset));
    }
    let learned = period.period().expect("skipped burst still fits");
    assert!(learned.abs_diff(Duration::from_millis(15_025)) < Duration::from_millis(10));

    let mut random = LossPeriod::default();
    for onset in [0, 11_000, 29_000, 36_500] {
        random.loss(at(start, onset));
    }
    assert_eq!(random.period(), None);
    assert!(!random.armed(at(start, 40_000)));
}

#[test]
fn short_gaps_and_retracted_onsets_teach_nothing() {
    let start = Instant::now();
    let mut fast = LossPeriod::default();
    for onset in [0, 3_500, 7_000, 10_500] {
        fast.loss(at(start, onset));
    }
    assert_eq!(fast.period(), None, "below PERIOD_MIN");

    let mut period = LossPeriod::default();
    period.loss(at(start, 0));
    period.loss(at(start, 20_000));
    period.loss(at(start, 40_000));
    assert!(period.period().is_some());
    period.retract();
    assert_eq!(period.period(), None, "two onsets are not a pattern");
}

#[test]
fn a_changed_pattern_drops_the_old_onsets() {
    let start = Instant::now();
    let mut period = LossPeriod::default();
    for onset in [0, 20_000, 40_000, 47_000, 77_000, 107_000] {
        period.loss(at(start, onset));
    }
    let learned = period.period().expect("the new pattern");
    assert_eq!(learned, Duration::from_secs(30));
}
