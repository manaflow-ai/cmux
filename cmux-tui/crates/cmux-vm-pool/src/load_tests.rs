use super::*;

#[test]
fn rfc3339_formats_known_instants() {
    let at = |s: u64| std::time::UNIX_EPOCH + std::time::Duration::from_secs(s);
    assert_eq!(rfc3339(at(0)), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(at(1_795_174_000)), "2026-11-20T11:26:40Z");
    assert_eq!(rfc3339(at(951_782_400)), "2000-02-29T00:00:00Z");
}

#[test]
fn rfc3339_parses_back_what_it_writes_and_go_offsets() {
    for secs in [0_u64, 951_782_400, 1_795_174_000, 4_102_444_800] {
        let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs);
        assert_eq!(parse_rfc3339(&rfc3339(at)), Some(secs as i64));
    }
    assert_eq!(parse_rfc3339("2026-11-20T12:26:40.5+01:00"), Some(1_795_174_000));
    assert_eq!(parse_rfc3339("2026-11-20T03:26:40-08:00"), Some(1_795_174_000));
    assert_eq!(parse_rfc3339("2026-13-20T03:26:40Z"), None);
    assert_eq!(parse_rfc3339("yesterday"), None);
}
#[test]
fn controller_and_monitoring_bodies_parse() {
    let body = json!({"vms": {
        "fsp-a": {"ok": true, "cpu_percent": 95.0, "mem_total_bytes": 100.0, "mem_used_bytes": 40.0},
        "fsp-b": {"ok": false, "cpu_percent": 1.0},
        "fsp-c": {"cpu_percent": 10.0, "sampled_at": "2026-11-20T11:26:30.123456789Z"},
        "fsp-d": {"cpu_percent": 99.0, "sampled_at": "2026-11-20T11:20:00Z"}
    }});
    // At 11:26:40Z with a 90 s limit: fsp-d (6 min 40 s old) is left out, fsp-c (10 s) stays.
    let loads = parse_controller(&body, 1_795_174_000, 90);
    assert_eq!(loads.len(), 2);
    assert_eq!(loads["fsp-a"], Load { cpu_pct: 95.0, mem_pct: Some(40.0) });
    assert!(loads["fsp-a"].full(90.0) && !loads["fsp-a"].quiet(20.0));
    assert!(loads["fsp-c"].quiet(20.0));
    let series = json!({"timeSeries": [
        {"metric": {"labels": {"instance_name": "cmux-runner-pool-w1a-0001"}}, "points": [{"value": {"doubleValue": 0.42}}]}
    ]});
    let loads = parse_monitoring(&series);
    assert!((loads["cmux-runner-pool-w1a-0001"].cpu_pct - 42.0).abs() < 1e-9);
}

#[test]
fn summary_gives_p50_and_the_lines() {
    let loads: HashMap<String, Load> = [10.0, 20.0, 50.0, 95.0]
        .iter()
        .enumerate()
        .map(|(i, &c)| (format!("m{i}"), Load { cpu_pct: c, mem_pct: None }))
        .collect();
    let s = summary(&loads);
    assert_eq!(s["measured"], 4);
    assert_eq!(s["cpu_p50"], 50.0);
    assert_eq!(s["at_or_over_90"], 1);
    assert_eq!(s["under_20"], 1);
}
