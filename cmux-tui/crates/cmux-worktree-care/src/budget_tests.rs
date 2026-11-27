use super::*;

const MIN: u64 = 60_000;
const GIB: u64 = 1 << 30;

fn s(at_min: u64, used_gib: u64) -> Sample {
    Sample { at_ms: at_min * MIN, used: used_gib * GIB, total: 100 * GIB }
}

#[test]
fn a_steady_fill_gives_its_rate_and_the_hours_to_each_line() {
    // 1 GiB every 10 minutes: 6 GiB/h from 50 GiB.
    let samples: Vec<Sample> = (0..12).map(|i| s(i * 10, 50 + i)).collect();
    let now = 110 * MIN;
    let rate = fill_rate(&samples, now).expect("rate");
    assert!((rate / GIB as f64 - 6.0).abs() < 0.05, "{rate}");
    let f = forecast(&samples, now, 61 * GIB, 100 * GIB);
    let to_target = f.hours_to_target.expect("target");
    assert!((to_target - 14.0 / 6.0).abs() < 0.05, "{to_target}");
    assert!(f.hours_to_critical.expect("critical") > to_target);
}

#[test]
fn a_cleanup_drop_is_not_a_disk_that_stopped_filling() {
    // Fills 1 GiB per 10 min, a cleanup frees 20 GiB in the middle.
    let mut samples = Vec::new();
    let mut used = 40;
    for i in 0..12u64 {
        if i == 6 {
            used -= 20;
        }
        samples.push(s(i * 10, used));
        used += 1;
    }
    let rate = fill_rate(&samples, 110 * MIN).expect("rate");
    assert!((rate / GIB as f64 - 6.0).abs() < 1.0, "{}", rate / GIB as f64);
}

#[test]
fn too_few_or_too_short_samples_give_no_rate() {
    assert_eq!(fill_rate(&[s(0, 10), s(10, 11)], 20 * MIN), None);
    assert_eq!(fill_rate(&[s(0, 10), s(5, 11), s(10, 12)], 20 * MIN), None);
    assert_eq!(fill_rate(&[], 0), None);
}

#[test]
fn samples_older_than_a_day_are_left_out() {
    let mut samples = vec![s(0, 90), s(10, 10), s(20, 10)];
    samples.extend((0..5).map(|i| s(3000 + i * 10, 20)));
    let rate = fill_rate(&samples, 3040 * MIN).expect("rate");
    assert_eq!(rate, 0.0);
}

#[test]
fn a_disk_over_a_line_is_zero_hours_from_it_and_a_flat_one_never() {
    assert_eq!(hours_until(0.75, 80 * GIB, 100 * GIB, None), Some(0.0));
    assert_eq!(hours_until(0.75, 50 * GIB, 100 * GIB, None), None);
    assert_eq!(hours_until(0.75, 50 * GIB, 100 * GIB, Some(0.0)), None);
    let h = hours_until(0.75, 50 * GIB, 100 * GIB, Some(5.0 * GIB as f64)).expect("hours");
    assert!((h - 5.0).abs() < 1e-9);
}

#[test]
fn passes_come_sooner_from_seventy_percent() {
    assert_eq!(spacing_ms(0.10), 6 * 60 * MIN);
    assert_eq!(spacing_ms(0.699), 6 * 60 * MIN);
    assert_eq!(spacing_ms(0.70), 30 * MIN);
    assert_eq!(spacing_ms(0.799), 30 * MIN);
    assert_eq!(spacing_ms(0.80), 10 * MIN);
    assert_eq!(spacing_ms(0.90), 3 * MIN);
    assert_eq!(Settings::default().pressure(0.69), Pressure::Normal);
    assert_eq!(Settings::default().pressure(0.70), Pressure::High);
    assert_eq!(Settings::default().pressure(0.90), Pressure::Critical);
}

fn forecast_in(hours: Option<f64>) -> Forecast {
    Forecast {
        fill_bytes_per_hour: hours.map(|_| 1.0),
        hours_to_target: hours,
        hours_to_critical: None,
        samples: 10,
    }
}

#[test]
fn a_predicted_crossing_within_the_interval_is_pressure_now() {
    let settings = Settings::default();
    // 60% used: the next look is 6 h away; a crossing in 2 h is acted on now.
    let soon = plan(&settings, 0.60, &forecast_in(Some(2.0)));
    assert!(soon.predicted && !soon.over_budget);
    assert_eq!(soon.pressure, Pressure::High);
    assert!(soon.budget_pressure());
    assert_eq!(soon.spacing_ms, 30 * MIN);
    let later = plan(&settings, 0.60, &forecast_in(Some(7.0)));
    assert!(!later.predicted);
    assert_eq!(later.pressure, Pressure::Normal);
    assert!(!later.budget_pressure());
    let flat = plan(&settings, 0.60, &forecast_in(None));
    assert!(!flat.predicted);
}

#[test]
fn over_the_budget_is_pressure_and_under_seventy_is_not() {
    let settings = Settings::default();
    assert!(plan(&settings, 0.76, &forecast_in(None)).over_budget);
    assert!(plan(&settings, 0.72, &forecast_in(None)).budget_pressure());
    assert!(!plan(&settings, 0.50, &forecast_in(None)).budget_pressure());
}

#[test]
fn a_projection_stops_once_it_is_under_the_line() {
    let mut p = Projection::new(80 * GIB, 100 * GIB, 0.70);
    assert!(!p.done());
    p.add(5 * GIB);
    assert!(!p.done(), "{}", p.fraction());
    p.add(6 * GIB);
    assert!(p.done(), "{}", p.fraction());
    assert!(Projection::new(10, 0, 0.7).fraction() == 0.0);
}

#[test]
fn the_ring_file_is_bounded_and_skips_same_minute_samples() {
    let dir = crate::store::care_tests::scratch("budget-ring");
    let samples = Samples::in_dir(&dir);
    for i in 0..(2 * MAX_SAMPLES as u64 + 10) {
        samples.record(Sample { at_ms: i * 2 * MIN, used: i, total: 1000 }).expect("record");
    }
    let loaded = samples.load();
    assert!(loaded.len() <= 2 * MAX_SAMPLES, "{}", loaded.len());
    assert!(loaded.len() >= MAX_SAMPLES);
    assert_eq!(loaded.last().map(|s| s.used), Some(2 * MAX_SAMPLES as u64 + 9));
    let before = loaded.len();
    let last = loaded.last().copied().expect("last");
    samples.record(Sample { at_ms: last.at_ms + 1000, ..last }).expect("record");
    assert_eq!(samples.load().len(), before);
}
