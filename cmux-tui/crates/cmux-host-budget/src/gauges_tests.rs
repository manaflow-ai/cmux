use super::*;
use serde_json::json;

fn kinds(v: &Value) -> Vec<&'static str> {
    gauges(v).into_iter().map(|g| g.kind).collect()
}

#[test]
fn a_mac_verdict_has_cpu_and_memory_only() {
    let v = json!({"load1": 9.6, "load_limit": 12.0, "cores_kind": "performance",
                   "pressure": "normal", "available_ram_fraction": 0.4});
    let g = gauges(&v);
    assert_eq!(kinds(&v), ["cpu", "memory"]);
    assert_eq!(g[0].percent, 80.0);
    assert_eq!(g[0].level, "warn");
    assert_eq!(g[0].detail, "load 9.6 / 12 P-cores");
    assert_eq!(g[1].percent, 60.0);
    assert_eq!(g[1].level, "normal", "RAM in use is not pressure by itself");
}

#[test]
fn a_load_past_its_limit_passes_100_and_is_critical() {
    let g = gauges(&json!({"load1": 146.0, "load_limit": 12.0}));
    assert_eq!(g[0].percent, 1216.7);
    assert_eq!(g[0].level, "critical");
}

#[test]
fn memory_reads_the_stall_estimate_where_the_daemon_keeps_one() {
    let v = json!({"available_ram_fraction": 0.5, "pressure": "normal",
                   "mem_stall": {"source": "vmstat", "some": {"avg10": 33.2, "avg60": 1.0, "avg300": 0.0},
                                 "full": {"avg10": 2.0, "avg60": 0.0, "avg300": 0.0}, "covered_secs": 60}});
    let g = &gauges(&v)[0];
    assert_eq!((g.kind, g.percent, g.level), ("memory", 33.2, "warn"));
    assert_eq!(g.detail, "stalled 33.2% of 10 s");
}

#[test]
fn full_stall_or_the_systems_word_raises_memory() {
    let full = json!({"mem_stall": {"some": {"avg10": 12.0}, "full": {"avg10": 12.0}}});
    assert_eq!(gauges(&full)[0].level, "critical");
    let word = json!({"available_ram_fraction": 0.5, "pressure": "critical"});
    assert_eq!(gauges(&word)[0].level, "critical");
    let low = json!({"available_ram_fraction": 0.03, "pressure": "normal"});
    assert_eq!(gauges(&low)[0].level, "warn");
}

#[test]
fn tokens_cache_and_mac_slots_show_where_their_readings_are() {
    let v = json!({"token_stall": {"some": {"avg10": 63.0}, "full": {"avg10": 0.0}},
                   "cache_faults": {"calls": 1000, "misses": 66},
                   "mac_slots": {"used": 9, "total": 10}});
    let g = gauges(&v);
    assert_eq!(kinds(&v), ["tokens", "cache", "mac_slots"]);
    assert_eq!((g[0].percent, g[0].level), (63.0, "critical"));
    assert_eq!((g[1].percent, g[1].level), (6.6, "normal"));
    assert_eq!(g[1].detail, "66 of 1000 calls missed");
    assert_eq!((g[2].percent, g[2].level), (90.0, "warn"));
}

#[test]
fn readings_that_cannot_be_read_give_no_gauge() {
    let v = json!({"load1": null, "load_limit": 0.0, "cache_faults": {"calls": 0, "misses": 0},
                   "mac_slots": {"used": 1, "total": 0}, "token_stall": {"full": {}}});
    assert!(gauges(&v).is_empty());
    assert!(gauges(&json!("not a verdict")).is_empty());
}

#[test]
fn with_gauges_sets_the_list_on_the_verdict() {
    let mut v = json!({"load1": 3.0, "load_limit": 12.0});
    with_gauges(&mut v);
    assert_eq!(v["gauges"][0]["kind"], "cpu");
    assert_eq!(v["gauges"][0]["percent"], 25.0);
    assert_eq!(v["gauges"][0]["level"], "normal");
    let mut s = json!("x");
    with_gauges(&mut s);
    assert_eq!(s, json!("x"));
}
