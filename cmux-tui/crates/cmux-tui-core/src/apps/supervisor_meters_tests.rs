//! Supervisor tests of `apps.meters` (`meters.rs`), the Settings > Extensions meter rows.

use super::*;

fn meters(f: &Fixture) -> Vec<Value> {
    let answer = f.supervisor.store_call(CLIENT, "apps.meters", json!({}), Origin::Cli).unwrap();
    answer["meters"].as_array().expect("meters").clone()
}

fn row(f: &Fixture, app: &str) -> Value {
    meters(f).into_iter().find(|r| r["app"] == app).unwrap_or(Value::Null)
}

#[test]
fn every_installed_extension_has_a_meter_row_with_its_views_and_batches() {
    let f = fixture();
    f.install("cmux/demo");
    f.install("local/spy");
    let idle = row(&f, "local/spy");
    assert_eq!(idle["step"], "normal");
    assert_eq!(idle["host"], "none");
    assert_eq!((idle["mounts"].clone(), idle["batches"]["in"].clone()), (json!(0), json!(0)));
    assert!(idle.get("paused").is_none() && idle.get("runState").is_none(), "{idle}");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    let live = row(&f, "local/spy");
    assert_eq!(live["host"], "running", "{live}");
    assert_eq!((live["mounts"].clone(), live["widgets"].clone()), (json!(1), json!(0)));
    assert!(live["batches"]["in"].as_u64().unwrap() >= 1, "{live}");
    assert!(live["batches"]["out"].as_u64().unwrap() >= 1, "{live}");
    assert_eq!(live["slowedMounts"], 0);
    // Rows are in app id order, installed apps only, and the op takes no args.
    let apps: Vec<String> = meters(&f).iter().map(|r| r["app"].as_str().unwrap().into()).collect();
    let mut sorted = apps.clone();
    sorted.sort();
    assert_eq!(apps, sorted);
    assert!(apps.iter().any(|a| a == "cmux/demo"));
    let bad = f.supervisor.store_call(CLIENT, "apps.meters", json!({ "x": 1 }), Origin::Cli);
    assert!(bad.is_err());
}

#[test]
fn a_paused_extension_says_why_on_its_meter() {
    let f = fixture();
    f.install("cmux/demo");
    f.supervisor
        .mount(CLIENT, "t1", "cmux/demo", "cmux.section/1", json!({ "timeout": true }))
        .unwrap();
    f.wait("the paused mount", |e| {
        e["event"] == "apps-mount-failed"
            && e["mount_id"] == "t1"
            && e["reason"] == "Paused: this app used too much time"
    });
    let paused = row(&f, "cmux/demo");
    assert_eq!(paused["step"], "paused", "{paused}");
    assert_eq!(paused["paused"], "3 entry timeouts in 60 s");
    assert_eq!(paused["runState"], "paused: 3 entry timeouts in 60 s");
    assert_eq!(paused["mounts"], 0);
}
