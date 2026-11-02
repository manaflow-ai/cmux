//! The app's C ABI calls, on the verdict JSON the daemon reports.

use super::*;
use crate::tests::gray;

/// acpmux's `host_pressure` as `daemon status` reports it, with its session facts.
const DAEMON: &str = r#"{"host":"gray","cores":12,"cores_kind":"performance","load1":146.2,"load_limit":12,
    "pressure":"warn","available_ram_fraction":0.04,"swap_mb_per_min":90,
    "over":["load1 146.2 >= 12 (12 P-cores)","memory pressure warn","available RAM 4% < 10%","swap +90 MB/min"],
    "ok":false,"warning":"host-budget: gray over its CPU/RAM budget: ...","enforce":false,
    "local_turns":39,"background_processes":1298,
    "top":[{"session_id":"s1","name":"app-efficiency","turns":3,"processes":410}]}"#;

#[test]
fn a_daemons_verdict_reads() {
    assert_eq!(level_of(DAEMON, Level::Normal), Some(Level::Critical));
    let r = reading(DAEMON).unwrap();
    assert_eq!((r.pressure.as_str(), r.load1, r.load_limit), ("warn", Some(146.2), 12.0));
}

/// acpmux judged with `pressure: warn` allowed: a warn event adds no reason.
#[test]
fn a_daemons_allowance_holds_for_an_event() {
    let v = r#"{"host":"gray","cores":12,"load1":13,"load_limit":12,"pressure":"normal","swap_mb_per_min":0,
        "over":["load1 13.0 >= 12 (12 P-cores)"],"ok":false,"formula":{"load1_per_core":1,"pressure":"warn"}}"#;
    let warned = verdict_with_pressure(v, 2).unwrap();
    let parsed: Value = serde_json::from_str(&warned).unwrap();
    assert_eq!(parsed["over"].as_array().unwrap().len(), 1);
    assert_eq!(parsed["pressure"], "warn");
    assert_eq!(level_of(&warned, Level::Normal), Some(Level::Warning));
}

/// Before its second sample acpmux has no swap rate, and it may not read the load or pressure.
#[test]
fn a_daemons_unread_numbers_read() {
    let v = r#"{"host":"gray","cores":12,"load1":null,"load_limit":12,"pressure":"unknown",
        "swap_mb_per_min":null,"over":[],"ok":true}"#;
    let r = reading(v).unwrap();
    assert_eq!(r.load1, None);
    assert!(!crate::pressure_is_over(&r.pressure, "normal"));
    assert_eq!(level_of(v, Level::Normal), Some(Level::Normal));
}

/// A judged event keeps the daemon's session facts.
#[test]
fn an_event_keeps_the_session_facts() {
    let calm = verdict_with_pressure(DAEMON, 1).unwrap();
    let parsed: Value = serde_json::from_str(&calm).unwrap();
    assert_eq!(parsed["local_turns"], 39);
    assert_eq!(parsed["top"][0]["name"], "app-efficiency");
    assert_eq!(parsed["pressure"], "normal");
    assert_eq!(parsed["over"].as_array().unwrap().len(), 3);
}

#[test]
fn the_dispatch_levels_are_the_sysctls() {
    let fine = serde_json::to_string(&gray(2.0, 1, 0.5, 0.0, &Budget::default())).unwrap();
    let pressure = |level| {
        let v: Value = serde_json::from_str(&verdict_with_pressure(&fine, level).unwrap()).unwrap();
        v["pressure"].as_str().unwrap().to_owned()
    };
    assert_eq!(
        [pressure(1), pressure(2), pressure(4), pressure(3)],
        ["normal", "warn", "critical", "unknown"]
    );
}

/// The tracker fed JSON: a verdict moves it, anything else leaves it.
#[test]
fn the_tracker_reads_json() {
    let mut tracker = Tracker::new(1);
    let critical = serde_json::to_string(&gray(2.0, 4, 0.5, 0.0, &Budget::default())).unwrap();
    assert_eq!(feed(&mut tracker, &critical), Some(Some(Level::Critical)));
    assert_eq!(feed(&mut tracker, &critical), Some(None));
    assert_eq!(feed(&mut tracker, "not json"), None);
    assert_eq!(feed(&mut tracker, r#"{"ok":null,"over":[]}"#), None);
    assert_eq!(tracker.level(), Level::Critical);
}

/// The Debug Settings sample: the cosmic-gray incident's numbers on 12 performance cores.
#[test]
fn given_numbers_are_judged_with_the_built_in_formula() {
    let input = r#"{"host":"cosmic-gray","sample":{"load1":146,"performance_cores":12,"logical_cpus":12,
        "vm_pressure_level":2,"available_ram_fraction":0.04},"swap_mb_per_min":410}"#;
    let v: Value = serde_json::from_str(&judge(input).unwrap()).unwrap();
    assert_eq!(
        v["over"],
        serde_json::json!([
            "load1 146.0 >= 12 (12 P-cores)",
            "memory pressure warn",
            "available RAM 4% < 10%",
            "swap +410 MB/min"
        ])
    );
    assert_eq!(v["load_limit"], 12.0);
    assert_eq!(judge("{}"), None);
    assert_eq!(judge("[]"), None);
}

/// The process's own meter answers with a verdict of this host.
#[test]
fn the_local_verdict_is_this_hosts() {
    let v: Value = serde_json::from_str(&local_verdict().unwrap()).unwrap();
    assert_eq!(v["host"], crate::host_name());
    assert!(v["load_limit"].as_f64().unwrap() > 0.0);
    assert!(reading(&local_verdict().unwrap()).is_some());
}
