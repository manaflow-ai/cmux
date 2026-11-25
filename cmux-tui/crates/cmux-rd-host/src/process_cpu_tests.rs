use super::*;
fn sample() -> Sample {
    Sample { pid: 10, start_abstime: 42, cpu_ns: 100, sampled_ns: 100 }
}
#[test]
fn process_cpu_interval_units_and_multicore() {
    let before = sample();
    assert_eq!(
        interval(Ok(before), Ok(Sample { cpu_ns: 350, sampled_ns: 200, ..before })).cpu_pct,
        Some(250.0)
    );
    assert_eq!(interval(Ok(before), Ok(Sample { sampled_ns: 200, ..before })).cpu_pct, Some(0.0));
}
#[test]
fn process_cpu_interval_rejects_reuse_regression_and_unavailable() {
    let before = sample();
    for after in [
        Sample { pid: 11, ..before },
        Sample { start_abstime: 43, ..before },
        Sample { cpu_ns: 99, ..before },
        before,
    ] {
        assert!(interval(Ok(before), Ok(after)).cpu_pct.is_none());
    }
    assert_eq!(interval(Err("permission_denied"), Ok(before)).reason, Some("permission_denied"));
    assert_eq!(interval(Ok(before), Err("process_gone")).reason, Some("process_gone"));
}
#[test]
fn process_cpu_ticks_scale_by_the_timebase() {
    // Apple Silicon: 125/3 ns per tick, so 24 ticks are 1000 ns, not 24.
    assert_eq!(ticks_to_ns(24, 125, 3), Some(1000));
    // Intel: 1/1.
    assert_eq!(ticks_to_ns(24, 1, 1), Some(24));
    assert_eq!(ticks_to_ns(24, 1, 0), Some(24));
    assert_eq!(ticks_to_ns(u64::MAX, 125, 3), None);
}
