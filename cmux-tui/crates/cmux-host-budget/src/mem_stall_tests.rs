use super::*;

fn r(alloc_stalls: u64, refaults: u64) -> Reclaim {
    Reclaim { alloc_stalls, direct_scanned: 0, refaults }
}

/// Feeds one reading a second for `secs` seconds, each `(stall rise, refaults)`.
fn run(a: &mut StallAverages, t0: Instant, from: u64, secs: u64, per_sec: (u64, u64)) -> Reclaim {
    let mut c = a.last.map_or(r(0, 0), |(_, c)| c);
    for s in from..from + secs {
        c = r(c.alloc_stalls + per_sec.0, c.refaults + per_sec.1);
        a.push(t0 + Duration::from_secs(s), c);
    }
    c
}

#[test]
fn nothing_until_two_readings() {
    let mut a = StallAverages::default();
    assert_eq!(a.get(), None);
    a.push(Instant::now(), r(5, 5));
    assert_eq!(a.get(), None, "the first reading is the baseline");
}

#[test]
fn calm_reads_zero() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 120, (0, 100));
    let m = a.get().unwrap();
    assert_eq!(m.some, Avgs::default());
    assert_eq!(m.full, Avgs::default());
    assert_eq!(m.covered_secs, 119);
    assert_eq!(m.source, Source::Vmstat);
}

#[test]
fn a_held_stall_reaches_the_kernels_numbers() {
    // Stalling every second for 10 s: avg10 is 1 - e^-1 of the way (63.2%), as the kernel's.
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 1, (0, 0));
    run(&mut a, t0, 1, 10, (1, 0));
    let m = a.get().unwrap();
    assert!((m.some.avg10 - 63.21).abs() < 0.01, "{m:?}");
    assert!((m.some.avg60 - 15.35).abs() < 0.01, "{m:?}");
    assert!((m.some.avg300 - 3.28).abs() < 0.01, "{m:?}");
    assert_eq!(m.full, Avgs::default(), "direct reclaim without thrash is some, not full");
}

#[test]
fn thrash_with_reclaim_is_full() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 1, (0, 0));
    run(&mut a, t0, 1, 600, (3, 650_000));
    let m = a.get().unwrap();
    assert!(m.full.avg10 > 99.9 && m.full.avg60 > 99.9 && m.full.avg300 > 86.0, "{m:?}");
    assert_eq!(m.some.avg10, m.full.avg10);
}

#[test]
fn refaults_alone_count_at_ten_mib_a_second() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 1, (0, 0));
    run(&mut a, t0, 1, 30, (0, REFAULT_PAGES_PER_SEC - 1));
    assert_eq!(a.get().unwrap().some.avg10, 0.0, "under the line");
    run(&mut a, t0, 31, 30, (0, REFAULT_PAGES_PER_SEC));
    assert!(a.get().unwrap().some.avg10 > 95.0);
}

#[test]
fn a_stall_decays_like_psi() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 1, (0, 0));
    run(&mut a, t0, 1, 60, (1, 0));
    let peak = a.get().unwrap().some;
    run(&mut a, t0, 61, 10, (0, 0));
    let after = a.get().unwrap().some;
    assert!((after.avg10 - peak.avg10 * (-1f64).exp()).abs() < 0.05, "{peak:?} {after:?}");
    assert!(after.avg60 < peak.avg60 && after.avg300 < peak.avg300);
}

#[test]
fn a_gap_or_a_reboot_is_a_new_baseline() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 5, (0, 0));
    let before = a.get().unwrap();
    // 10 minutes later, with many stalls in between: not one stalled second, no change.
    a.push(t0 + Duration::from_secs(605), r(1_000, 0));
    assert_eq!(a.get().unwrap(), before);
    // Counters going down: a new boot.
    a.push(t0 + Duration::from_secs(606), r(0, 0));
    assert_eq!(a.get().unwrap(), before);
    // A wider tick folds its whole span: 2 s stalled moves avg10 by 1 - e^-0.2.
    a.push(t0 + Duration::from_secs(608), r(1, 0));
    assert!((a.get().unwrap().some.avg10 - 18.13).abs() < 0.01);
}

#[test]
fn prints_in_psis_shape() {
    let mut a = StallAverages::default();
    let t0 = Instant::now();
    run(&mut a, t0, 0, 3, (0, 0));
    let v = serde_json::to_value(a.get().unwrap()).unwrap();
    assert_eq!(
        v,
        serde_json::json!({
            "source": "vmstat",
            "some": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0},
            "full": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0},
            "coveredSecs": 2
        })
    );
}
