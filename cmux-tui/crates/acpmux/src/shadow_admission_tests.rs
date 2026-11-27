use super::*;
use crate::placement::{Work, place};

const GB: u64 = 1_000_000_000;

/// A `_acpmux/host_health` reading, as `peer_status.rs` builds it.
fn health(cpus: u64, load: f64, pressure: &str, avail: f64, live: u64) -> Value {
    json!({
        "cpus": cpus,
        "load": [load, load, load],
        "ram": {"totalBytes": 64 * GB, "freeBytes": (64.0 * avail) as u64 * GB},
        "swap": {"usedBytes": GB, "totalBytes": 32 * GB},
        "disk": {"freeBytes": 500 * GB, "totalBytes": 1000 * GB},
        "liveSessions": live,
        "pressure": {"ok": true, "over": [], "load1": load, "load_limit": cpus as f64,
            "cores": cpus, "cores_kind": "logical", "pressure": pressure,
            "available_ram_fraction": avail, "swap_mb_per_min": 0.0},
        "pressureAgeMs": 2_000,
    })
}

fn peer(name: &str, health: Value, at: Option<u64>) -> Candidate {
    Candidate { name: name.into(), local: false, health, health_at: at }
}

#[test]
fn a_reading_maps_to_the_formulas_inputs() {
    let c = peer("map-lane", health(32, 205.0, "normal", 0.42, 3), Some(100_000));
    let i = inputs(&c, 130_000, None);
    assert_eq!(i.host, "map-lane");
    assert_eq!((i.cores, i.load1), (Some(32), Some(205.0)));
    // The arrival time less the meter's sample age; never the peer's own clock.
    assert_eq!(i.health_at_ms, Some(98_000));
    assert_eq!(i.mem_pressure.as_deref(), Some("normal"));
    assert_eq!(i.available_fraction, Some(0.42));
    assert_eq!((i.swap_used_bytes, i.swap_total_bytes), (Some(GB), Some(32 * GB)));
    assert_eq!(i.ram_total_bytes, Some(64 * GB));
    assert_eq!(i.swap_growth_mb_per_min, Some(0.0));
    assert_eq!(i.psi_cpu_some_avg10, None);
}

#[test]
fn a_peer_row_carries_its_health_at() {
    let row = json!({"name": "row-lane", "connected": true, "health": {"cpus": 4}, "healthAt": 77});
    let c = Candidate::peer(&row).expect("named row");
    assert_eq!((c.name.as_str(), c.local, c.health_at), ("row-lane", false, Some(77)));
    assert_eq!(Candidate::peer(&json!({"health": {}})).map(|c| c.name), None);
}

#[test]
fn a_host_at_load_205_reads_cpu_saturated_on_its_second_sample() {
    let name = "sat-lane";
    let first = peer(name, health(32, 205.0, "normal", 0.42, 3), Some(1_000_000));
    let v = judge(std::slice::from_ref(&first), 1_001_000);
    assert_eq!((v[0].reason, v[0].would_defer), ("ok", false));
    let second = peer(name, health(32, 205.0, "normal", 0.42, 3), Some(1_060_000));
    let v = judge(&[second], 1_061_000);
    assert_eq!((v[0].reason, v[0].would_defer), ("saturated:cpu", true));
    assert_eq!(v[0].mem.state, crate::host_pressure::SignalState::Ok);
}

#[test]
fn a_stale_or_unread_peer_is_unknown() {
    let old = peer("stale-lane", health(8, 1.0, "normal", 0.5, 0), Some(0));
    let none = peer("unread-lane", Value::Null, None);
    let v = judge(&[old, none], 400_000);
    assert!(v.iter().all(|v| v.reason == "unknown:stale" && v.would_defer), "{v:?}");
}

/// The candidate sets the placement tests weigh: calm, full, overloaded,
/// unread and stale hosts, alone and together.
fn fleets() -> Vec<Vec<Candidate>> {
    let calm = |n: &str| peer(n, health(32, 4.0, "normal", 0.6, 2), Some(1_000_000));
    let hot = |n: &str| peer(n, health(32, 205.0, "normal", 0.42, 9), Some(1_000_000));
    let swapped = |n: &str| peer(n, health(16, 3.0, "warn", 0.05, 4), Some(1_000_000));
    let unread = |n: &str| peer(n, Value::Null, None);
    let stale = |n: &str| peer(n, health(8, 1.0, "normal", 0.7, 0), Some(1));
    vec![
        vec![calm("pk-a")],
        vec![calm("pk-a"), hot("pk-b")],
        vec![hot("pk-b"), swapped("pk-c")],
        vec![unread("pk-d"), hot("pk-b")],
        vec![stale("pk-e"), calm("pk-a"), swapped("pk-c"), unread("pk-d")],
        vec![hot("pk-b"), hot("pk-f")],
    ]
}

#[test]
fn the_shadow_verdict_never_changes_the_pick() {
    for work in [Work::Agent, Work::Build] {
        for fleet in fleets() {
            let before = place(&fleet, None, work);
            // Judged repeatedly so every host walks into its saturated state.
            for _ in 0..3 {
                let after = with_shadow("place", place(&fleet, None, work), &fleet);
                let mut without = after.clone();
                let shadow = without.as_object_mut().and_then(|o| o.remove("shadow"));
                assert_eq!(without, before, "the shadow changed the verdict for {fleet:?}");
                let shadow = shadow.expect("a shadow line");
                assert_eq!(shadow["pick"], before["pick"]);
                assert_eq!(shadow["hosts"].as_array().map(Vec::len), Some(fleet.len()));
            }
        }
    }
}

#[test]
fn a_line_names_the_pick_and_every_host() {
    let fleet = [
        peer("ln-a", health(32, 4.0, "normal", 0.6, 2), Some(5_000_000)),
        peer("ln-b", health(16, 3.0, "critical", 0.3, 2), Some(5_000_000)),
    ];
    let verdicts = judge(&fleet, 5_001_000);
    let l = line("place", Some("ln-b"), &verdicts, 5_001_000);
    assert_eq!(l["ts"], 5_001_000);
    assert_eq!(l["site"], "place");
    assert_eq!(l["pick"], "ln-b");
    assert_eq!(
        (l["would_defer"].clone(), l["reason"].clone()),
        (json!(true), json!("saturated:mem"))
    );
    assert_eq!(l["inputs_digest"], json!(verdicts[1].inputs_digest));
    assert_eq!(l["formula_version"], crate::host_pressure::SHADOW_FORMULA_VERSION);
    assert_eq!(l["hosts"][0]["host"], "ln-a");
    assert_eq!(l["hosts"][0]["reason"], "ok");
    let none = line("pick", None, &verdicts, 5_001_000);
    assert!(none["pick"].is_null() && none["reason"].is_null(), "{none}");
}

#[test]
fn a_full_dns_name_logs_the_short_name_and_the_same_pressure_digest() {
    // A lane VM's daemon names itself by its DNS name; lane-place names it short.
    // Other clocks and a kept state change inputs_digest, never these two.
    let reading = health(32, 4.0, "normal", 0.6, 2);
    let long = [peer("ln-a.example.ts.net", reading.clone(), Some(5_000_000))];
    let short = [peer("ln-a", reading, Some(5_090_000))];
    let a = line("admit", Some("ln-a.example.ts.net"), &judge(&long, 5_001_000), 5_001_000);
    let b = line("place", Some("ln-a"), &judge(&short, 5_091_000), 5_091_000);
    assert_eq!(a["hosts"][0]["host_short"], "ln-a");
    assert_eq!(b["hosts"][0]["host_short"], "ln-a");
    assert_eq!(a["pressure_digest"], b["pressure_digest"]);
    assert_eq!(a["hosts"][0]["pressure_digest"], a["pressure_digest"]);
    assert_ne!(a["inputs_digest"], b["inputs_digest"]);
}

#[test]
fn ls_prints_the_hosts_that_would_defer() {
    let status = json!({"shadowAdmission": [
        {"host": "a", "would_defer": false, "reason": "ok"},
        {"host": "b", "would_defer": true, "reason": "saturated:cpu"},
        {"host": "c", "would_defer": true, "reason": "unknown:stale"},
    ]});
    assert_eq!(
        ls_lines(&status),
        [
            "b: would-defer: saturated:cpu (shadow; nothing is deferred)",
            "c: would-defer: unknown:stale (shadow; nothing is deferred)",
        ]
    );
    assert!(ls_lines(&json!({})).is_empty());
}

#[test]
fn the_kept_verdicts_list_each_host_once() {
    let c = peer("kept-lane", health(4, 1.0, "normal", 0.5, 0), Some(9_000_000));
    judge(std::slice::from_ref(&c), 9_001_000);
    judge(&[c], 9_100_000);
    let kept: Vec<Value> =
        last_verdicts().into_iter().filter(|v| v["host"] == "kept-lane").collect();
    assert_eq!(kept.len(), 1, "{kept:?}");
}

#[test]
fn daemon_status_gives_the_inputs_placement_builds() {
    let readings = json!({
        "cpus": 32,
        "pressureAgeMs": 4_000,
        "load": [205.0, 180.0, 150.0],
        "ram": {"totalBytes": 64 * GB},
        "swap": {"usedBytes": 30_800_000_000_u64, "totalBytes": 31_700_000_000_u64},
    });
    let pressure = json!({"host": "st-lane", "ok": false, "over": ["load"], "load1": 190.0,
        "load_limit": 32.0, "cores": 32, "cores_kind": "logical", "pressure": "warn",
        "available_ram_fraction": 0.42, "swap_mb_per_min": 12.5, "warning": null});
    let placed = Candidate {
        name: "st-lane".into(),
        local: true,
        health: local_health(&readings, pressure.clone()),
        health_at: Some(9_000_000),
    };
    // `daemon status`'s `host_pressure`: the verdict, this daemon's own keys,
    // then the readings.
    let mut status = pressure;
    status["local_turns"] = json!(3);
    status["top"] = json!([]);
    let status = with_readings(status, &readings);
    for k in ["cpus", "pressureAgeMs", "load", "ram", "swap", "swap_mb_per_min", "cores"] {
        assert!(status.get(k).is_some(), "host_pressure lacks {k}: {status}");
    }
    let read = status_candidate("st-lane", &status, 9_000_000);
    let a = inputs(&placed, 9_010_000, None);
    let b = inputs(&read, 9_010_000, None);
    assert_eq!(a, b);
    // The OS load average, not the meter's own sample.
    assert_eq!(a.load1, Some(205.0));
    assert_eq!(a.health_at_ms, Some(8_996_000));
    assert_eq!(shadow_verdict(&a), shadow_verdict(&b));

    // With no meter sample yet neither side has a pressure reading.
    let empty = json!({"host": "st-lane", "ok": null, "over": [], "warning": null});
    let placed = Candidate { health: local_health(&readings, Value::Null), ..placed };
    let read = status_candidate("st-lane", &with_readings(empty, &readings), 9_000_000);
    assert_eq!(inputs(&placed, 9_010_000, None), inputs(&read, 9_010_000, None));
}
