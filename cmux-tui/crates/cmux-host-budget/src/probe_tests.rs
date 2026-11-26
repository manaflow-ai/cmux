use super::*;

fn levels(v: &[(&str, u32)]) -> Vec<(String, u32)> {
    v.iter().map(|(n, c)| ((*n).to_owned(), *c)).collect()
}

#[test]
fn performance_cores_sum_every_level_but_efficiency() {
    // RFD 0072 run A read level 0 alone: 5 on a 15-CPU M5 Pro. The budget's count is 15.
    assert_eq!(performance_cores(&levels(&[("Super", 5), ("Performance", 10)])), Some(15));
    assert_eq!(performance_cores(&levels(&[("Super", 5)])), Some(5));
    assert_eq!(performance_cores(&levels(&[("Performance", 8), ("Efficiency", 4)])), Some(8));
    assert_eq!(performance_cores(&levels(&[("Efficiency", 4)])), None);
}

#[test]
fn cpu_busy_from_ticks() {
    // user, system, idle, nice
    let before = [100, 50, 800, 0];
    let after = [160, 70, 870, 0];
    // 80 ticks busy of 150.
    let busy = cpu_busy_ticks(before, after).unwrap();
    assert!((busy - 80.0 / 150.0).abs() < 1e-9);
    assert_eq!(cpu_busy_ticks(before, before), None);
    assert_eq!(cpu_busy_ticks(before, [100, 50, 900, 0]), Some(0.0));
}

#[test]
fn cpu_busy_ticks_survive_a_counter_wrap() {
    let before = [u32::MAX - 9, 0, 100, 0];
    let after = [10, 0, 120, 0];
    // 20 busy, 20 idle.
    assert_eq!(cpu_busy_ticks(before, after), Some(0.5));
}

#[test]
fn cpu_busy_from_proc_stat_readings() {
    let a = parse_proc_stat_cpu("cpu  100 0 100 700 0 0 0 0 0 0\n").unwrap();
    let b = parse_proc_stat_cpu("cpu  400 0 100 800 0 0 0 0 0 0\n").unwrap();
    assert_eq!(cpu_busy(a, b), Some(0.75));
}

#[test]
fn thermal_words() {
    assert_eq!(thermal_pressure_word(0), "nominal");
    assert_eq!(thermal_pressure_word(2), "heavy");
    assert_eq!(thermal_pressure_word(4), "sleeping");
    assert_eq!(thermal_pressure_word(9), "unknown");
}

#[test]
fn thermal_zones_fold_to_the_hottest_sane_one() {
    assert_eq!(parse_thermal_millic_max(["45000\n", "61500\n", "38000"]), Some(61.5));
    assert_eq!(parse_thermal_millic_max(["0\n", "-5000", "x", "250000"]), None);
    assert_eq!(parse_thermal_millic_max(Vec::<&str>::new()), None);
}

#[test]
fn hid_idle_nanos_to_seconds() {
    assert_eq!(hid_idle_seconds(2_500_000_000), Some(2.5));
    assert_eq!(hid_idle_seconds(0), Some(0.0));
    assert_eq!(hid_idle_seconds(-1), None);
}

#[test]
fn the_host_probe_reads_on_this_platform() {
    let first = HostProbe.sample();
    assert!(first.logical_cpus >= 1);
    let second = HostProbe.sample();
    if let Some(b) = second.cpu_busy {
        assert!((0.0..=1.0).contains(&b));
    }
    if let Some(i) = second.hid_idle_seconds {
        assert!(i >= 0.0);
    }
}

#[test]
fn old_sample_json_still_reads() {
    let s: Sample = serde_json::from_str(r#"{"load1": 3.0, "logical_cpus": 8}"#).unwrap();
    assert_eq!(s.cpu_busy, None);
    assert_eq!(s.hid_idle_seconds, None);
    assert_eq!(s.lateness_p50_ms, None);
    let s: Sample = serde_json::from_str(r#"{"cpu_busy": 0.9, "lateness_p50_ms": 1.6}"#).unwrap();
    assert_eq!(s.cpu_busy, Some(0.9));
}

#[test]
fn reclaim_counters_sum_their_zones_and_need_an_allocstall_line() {
    let vmstat = "nr_free_pages 9\nworkingset_refault_anon 3\nworkingset_refault_file 40\n\
                  allocstall_dma 0\nallocstall_dma32 2\nallocstall_normal 5\nallocstall_movable 1\n\
                  pgscan_kswapd 77\npgscan_direct 1200\npgscan_direct_throttle 0\noom_kill 0\n";
    assert_eq!(
        parse_vmstat_reclaim(vmstat),
        Some(Reclaim { alloc_stalls: 8, direct_scanned: 1200, refaults: 43 })
    );
    // Before 5.9 the refault counter was one line.
    let old = "workingset_refault 11\nallocstall 4\npgscan_direct 9\n";
    assert_eq!(
        parse_vmstat_reclaim(old),
        Some(Reclaim { alloc_stalls: 4, direct_scanned: 9, refaults: 11 })
    );
    assert_eq!(parse_vmstat_reclaim("oom_kill 0\n"), None);
}
