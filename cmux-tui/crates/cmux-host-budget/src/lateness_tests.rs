use super::*;

fn window_of(lates: &[f64]) -> LatenessWindow {
    let mut w = LatenessWindow::default();
    for (i, l) in lates.iter().enumerate() {
        w.push(1_000 + i as u64 * 10, *l);
    }
    w
}

#[test]
fn percentile_is_nearest_rank() {
    let v: Vec<f64> = (1..=100).map(f64::from).collect();
    assert_eq!(percentile(&v, 0.5), Some(50.0));
    assert_eq!(percentile(&v, 0.95), Some(95.0));
    assert_eq!(percentile(&v, 1.0), Some(100.0));
    assert_eq!(percentile(&v, 0.0), Some(1.0));
    assert_eq!(percentile(&[7.0], 0.95), Some(7.0));
    assert_eq!(percentile(&[], 0.5), None);
}

#[test]
fn lateness_is_never_negative() {
    let ten = Duration::from_millis(10);
    assert!((lateness_ms(ten, Duration::from_micros(11_610)) - 1.61).abs() < 1e-9);
    assert_eq!(lateness_ms(ten, Duration::from_millis(9)), 0.0);
}

#[test]
fn stats_need_enough_wakes() {
    let w = window_of(&[1.0; MIN_WAKES - 1]);
    assert_eq!(w.stats(2_000), None);
    let w = window_of(&[1.0; MIN_WAKES]);
    assert_eq!(w.stats(2_000).map(|s| s.wakes), Some(MIN_WAKES));
}

#[test]
fn stats_report_median_p95_and_share_over_five_ms() {
    // 90 wakes at 1 ms, 10 at 8 ms.
    let mut lates = vec![1.0; 90];
    lates.extend([8.0; 10]);
    let s = window_of(&lates).stats(2_000).unwrap();
    assert_eq!(s.wakes, 100);
    assert_eq!(s.p50_ms, 1.0);
    assert_eq!(s.p95_ms, 8.0);
    assert!((s.share_over_5ms - 0.1).abs() < 1e-9);
}

#[test]
fn exactly_five_ms_is_not_over() {
    let s = window_of(&[5.0; 50]).stats(2_000).unwrap();
    assert_eq!(s.share_over_5ms, 0.0);
}

#[test]
fn old_wakes_leave_the_window() {
    let mut w = LatenessWindow::default();
    for i in 0..50 {
        w.push(i * 10, 9.0);
    }
    let later = WINDOW.as_millis() as u64 + 10_000;
    for i in 0..50 {
        w.push(later + i * 10, 1.0);
    }
    let s = w.stats(later + 500).unwrap();
    assert_eq!(s.wakes, 50);
    assert_eq!(s.p95_ms, 1.0);
    // Read alone, without a push, the old ones are also left out.
    assert_eq!(window_of(&[9.0; 50]).stats(1_000 + WINDOW.as_millis() as u64 + 10_000), None);
}

#[test]
fn the_window_is_capped_and_bad_values_are_dropped() {
    let mut w = LatenessWindow::default();
    for i in 0..(MAX_WAKES as u64 + 500) {
        w.push(10_000 + i, 1.0);
    }
    w.push(20_000, f64::NAN);
    w.push(20_000, f64::INFINITY);
    assert_eq!(w.stats(20_000).map(|s| s.wakes), Some(MAX_WAKES));
}

#[test]
fn the_thread_starts_wakes_and_stops() {
    let monitor = LatenessMonitor::start().expect("thread");
    std::thread::sleep(Duration::from_millis(600));
    let s = monitor.stats().expect("a burst's wakes");
    assert!(s.wakes >= MIN_WAKES);
    assert!(s.p50_ms >= 0.0 && s.p50_ms < 1_000.0);
    drop(monitor);
}
