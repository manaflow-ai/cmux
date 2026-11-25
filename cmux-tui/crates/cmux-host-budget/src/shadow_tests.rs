use super::*;
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../testdata/shadow-verdict-v2.json");

fn vectors() -> Vec<Value> {
    let file: Value = serde_json::from_str(VECTORS).expect("the vector file is JSON");
    assert_eq!(file["formula_version"], SHADOW_FORMULA_VERSION, "bump the file with the formula");
    file["vectors"].as_array().expect("vectors is an array").clone()
}

fn judge(input: &Value) -> Value {
    let inputs: ShadowInputs = serde_json::from_value(input.clone()).expect("vector input parses");
    serde_json::to_value(shadow_verdict(&inputs)).expect("verdict serializes")
}

#[test]
fn every_golden_vector_gives_its_verdict() {
    let all = vectors();
    assert!(all.len() >= 15, "the file lost vectors");
    for v in &all {
        let name = v["name"].as_str().unwrap_or("?");
        let got = judge(&v["input"]);
        let want = &v["expect"];
        assert_eq!(got["would_defer"], want["would_defer"], "{name}: would_defer");
        assert_eq!(got["reason"], want["reason"], "{name}: reason");
        assert_eq!(got["cpu"]["state"], want["cpu"], "{name}: cpu state");
        assert_eq!(got["mem"]["state"], want["mem"], "{name}: mem state");
        assert_eq!(got["next"], want["next"], "{name}: next state");
        assert_eq!(got["inputs_digest"], want["inputs_digest"], "{name}: inputs_digest");
        assert_eq!(got["formula_version"], SHADOW_FORMULA_VERSION, "{name}");
    }
}

#[test]
fn the_named_incidents_are_in_the_vectors() {
    let names: Vec<String> =
        vectors().iter().filter_map(|v| v["name"].as_str().map(str::to_owned)).collect();
    for wanted in [
        "cpu-saturated-load-205-on-32-cores",
        "swap-30.8-of-31.7-gb-no-buffer",
        "stale-health-240s",
        "warn-with-42-percent-available-stays-pressured",
        "warn-streak-with-low-available-saturates",
        "critical-saturates-at-once",
        "busy-mac-load-9.28-per-core-warn-swap-96-first-sample",
    ] {
        assert!(names.iter().any(|n| n == wanted), "missing vector {wanted}");
    }
}

#[test]
fn feeding_next_back_walks_the_hysteresis() {
    // Two hot samples enter, a deadband sample holds, three calm samples leave.
    let mut previous = None;
    let mut states = Vec::new();
    for (i, load) in [205.0, 205.0, 32.0, 16.0, 16.0, 16.0].into_iter().enumerate() {
        let at = 1_000_000 + i as u64 * 60_000;
        let inputs = ShadowInputs {
            now_ms: Some(at + 1_000),
            health_at_ms: Some(at),
            cores: Some(32),
            load1: Some(load),
            mem_pressure: Some("normal".into()),
            available_fraction: Some(0.5),
            previous,
            ..ShadowInputs::default()
        };
        let v = shadow_verdict(&inputs);
        states.push(v.cpu.state);
        previous = Some(v.next);
    }
    use SignalState::{Ok, Pressured, Saturated};
    assert_eq!(states, [Pressured, Saturated, Saturated, Saturated, Saturated, Ok]);
}

#[test]
fn the_digest_ignores_the_clock_and_follows_the_readings() {
    let a = ShadowInputs {
        host: "h".into(),
        now_ms: Some(10),
        health_at_ms: Some(5),
        load1: Some(3.0),
        cores: Some(4),
        ..ShadowInputs::default()
    };
    let later = ShadowInputs { now_ms: Some(99_999), ..a.clone() };
    let busier = ShadowInputs { load1: Some(3.5), ..a.clone() };
    assert_eq!(inputs_digest(&a), inputs_digest(&later));
    assert_ne!(inputs_digest(&a), inputs_digest(&busier));
    let d = inputs_digest(&a);
    assert!(d.starts_with("fnv1a64:") && d.len() == "fnv1a64:".len() + 16, "{d}");
}

#[test]
fn idle_sessions_cost_rss_and_no_cpu() {
    let inputs = ShadowInputs {
        sessions: vec![
            SessionLoad { active: true, cpu_cores: 1.5, rss_bytes: 1_000 },
            SessionLoad { active: false, cpu_cores: 3.0, rss_bytes: 500 },
            SessionLoad { active: false, cpu_cores: 0.0, rss_bytes: 250 },
        ],
        ..ShadowInputs::default()
    };
    let cost = shadow_verdict(&inputs).cost;
    assert_eq!(
        cost,
        Cost { active_sessions: 1, idle_sessions: 2, cpu_cores: 1.5, rss_bytes: 1_750 }
    );
}

#[test]
fn fits_measures_the_new_session_against_the_enter_lines() {
    let gib = 1u64 << 30;
    let base = ShadowInputs {
        now_ms: Some(1),
        health_at_ms: Some(1),
        cores: Some(32),
        load1: Some(39.5),
        available_fraction: Some(0.10),
        ram_total_bytes: Some(64 * gib),
        ..ShadowInputs::default()
    };
    // 32 * 1.25 - 39.5 = 0.5 cores of room; (0.10 - 0.08) * 64 GiB = 1.28 GiB.
    let v = shadow_verdict(&base);
    assert_eq!(v.fits, Fits { cpu: Some(false), mem: Some(true) });
    let small = ShadowInputs {
        new_session: Some(SessionCost { cpu_cores: 0.25, rss_bytes: 2 * gib }),
        ..base
    };
    assert_eq!(shadow_verdict(&small).fits, Fits { cpu: Some(true), mem: Some(false) });
    assert_eq!(shadow_verdict(&ShadowInputs::default()).fits, Fits { cpu: None, mem: None });
}

#[test]
fn an_unknown_input_field_is_an_error() {
    let typo = json!({"host": "h", "load_1": 3.0});
    assert!(serde_json::from_value::<ShadowInputs>(typo).is_err());
    let misspelled = json!({"host": "h", "mem_pressure": "critcal"});
    assert!(serde_json::from_value::<ShadowInputs>(misspelled).is_err());
    for level in MEM_PRESSURE_LEVELS {
        let ok = json!({"host": "h", "mem_pressure": level});
        assert!(serde_json::from_value::<ShadowInputs>(ok).is_ok(), "{level}");
    }
    let null = json!({"host": "h", "mem_pressure": null});
    assert_eq!(
        serde_json::from_value::<ShadowInputs>(null).map(|i| i.mem_pressure).ok(),
        Some(None)
    );
    let partial = json!({"host": "h", "previous": {"cpu": {"state": "saturated"}}});
    let inputs: ShadowInputs = serde_json::from_value(partial).expect("partial state parses");
    assert_eq!(inputs.previous.map(|p| p.cpu.state), Some(SignalState::Saturated));
}

#[test]
fn a_clock_behind_the_reading_counts_as_fresh() {
    let inputs = ShadowInputs {
        now_ms: Some(1_000),
        health_at_ms: Some(5_000),
        cores: Some(4),
        load1: Some(1.0),
        ..ShadowInputs::default()
    };
    let v = shadow_verdict(&inputs);
    assert_eq!((v.health_age_s, v.reason), (Some(0), "ok"));
}

#[test]
fn the_canonical_text_sorts_keys_and_drops_nulls_and_the_clock() {
    let inputs = ShadowInputs {
        host: "h".into(),
        now_ms: Some(5),
        cores: Some(8),
        load1: Some(205.0),
        available_fraction: Some(0.420_000_04),
        swap_growth_mb_per_min: Some(-0.0),
        ..ShadowInputs::default()
    };
    assert_eq!(
        canonical_inputs(&inputs),
        r#"{"available_fraction":0.42,"cores":8,"host":"h","load1":205,"swap_growth_mb_per_min":0}"#
    );
}
