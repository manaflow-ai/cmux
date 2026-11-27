//! Supervisor tests of the budget ladder (`budget.rs`): what pauses an app,
//! what an agent reads (`apps.list`, `apps.catalog.get`, `apps.logs`), and
//! `apps.resume`. The batch-rate timing is tested with injected instants in
//! `budget.rs` itself.

use super::*;

const PAUSED: &str = "Paused: this app used too much time";

fn wait_log(f: &Fixture, app: &str, text: &str) -> Value {
    f.wait(text, |e| {
        e["event"] == "apps-log"
            && e["app"] == app
            && e["message"].as_str().is_some_and(|m| m.contains(text))
    })
}

fn info_install(f: &Fixture, app: &str) -> Value {
    let detail = f
        .supervisor
        .store_call(CLIENT, "apps.catalog.get", json!({ "app": app }), Origin::User)
        .unwrap();
    detail["install"].clone()
}

#[test]
fn three_entry_timeouts_pause_the_app_until_resume() {
    let f = fixture();
    f.install("cmux/demo");
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    assert_eq!(app_entry(&f.supervisor.list(), "cmux/demo")["budget"], "normal");
    // The render runs past its deadline each time; each restart renders again.
    f.supervisor
        .mount(CLIENT, "t1", "cmux/demo", "cmux.section/1", json!({ "timeout": true }))
        .unwrap();
    // The log line comes first, then the mount fails (the event order).
    wait_log(&f, "cmux/demo", "paused: 3 entry timeouts in 60 s");
    let failed = f.wait("the paused mount", |e| {
        e["event"] == "apps-mount-failed" && e["mount_id"] == "t1" && e["reason"] == PAUSED
    });
    assert_eq!(failed["reason"], PAUSED);

    // Agents read the step where they read the app.
    let row = app_entry(&f.supervisor.list(), "cmux/demo");
    assert_eq!(row["budget"], "paused");
    assert_eq!(row["run_state"], "paused: 3 entry timeouts in 60 s");
    assert_eq!(info_install(&f, "cmux/demo")["budget"], "paused");

    // Paused: no host starts, the place keeps its native view.
    let refused =
        f.supervisor.mount(CLIENT, "t2", "cmux/demo", "cmux.section/1", json!({})).unwrap_err();
    assert_eq!((refused.code.as_str(), refused.message.as_str()), ("apps.paused", PAUSED));

    // Resume (the header's button, or an agent that fixed its code).
    f.supervisor
        .store_call(CLIENT, "apps.resume", json!({ "app": "cmux/demo" }), Origin::Cli)
        .unwrap();
    wait_log(&f, "cmux/demo", "resumed");
    let row = app_entry(&f.supervisor.list(), "cmux/demo");
    assert_eq!(row["budget"], "normal");
    assert!(row.get("run_state").is_none_or(Value::is_null), "{row}");
    assert_eq!(info_install(&f, "cmux/demo")["budget"], "normal");
    f.mount("t3", "cmux/demo", "cmux.section/1", json!({}));

    // Resuming an app that is not paused is a no-op; an unknown app is refused.
    f.supervisor
        .store_call(CLIENT, "apps.resume", json!({ "app": "cmux/demo" }), Origin::User)
        .unwrap();
    let unknown = f
        .supervisor
        .store_call(CLIENT, "apps.resume", json!({ "app": "cmux/nope" }), Origin::User)
        .unwrap_err();
    assert_eq!(unknown.code, "apps.unknown");
}

#[test]
fn turning_a_paused_app_off_and_on_starts_it_normal() {
    let f = fixture();
    f.install("cmux/demo");
    f.supervisor
        .mount(CLIENT, "t1", "cmux/demo", "cmux.section/1", json!({ "timeout": true }))
        .unwrap();
    f.wait("the paused mount", |e| e["event"] == "apps-mount-failed" && e["reason"] == PAUSED);
    f.set("off", "cmux/demo", Origin::User, |o| o.enabled = Some(false)).unwrap();
    f.set("on", "cmux/demo", Origin::User, |o| o.enabled = Some(true)).unwrap();
    assert_eq!(app_entry(&f.supervisor.list(), "cmux/demo")["budget"], "normal");
    f.mount("t2", "cmux/demo", "cmux.section/1", json!({}));
}

#[test]
fn one_changed_row_under_budget_sends_one_update_op() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("r1", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor
        .dispatch(CLIENT, "r1", "n1", "tap", json!({ "op": "demo.go", "params": {} }), true)
        .unwrap();
    let update = f.wait("the row update", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "r1" && e["ops"][0]["op"] == "update"
    });
    assert_eq!(update["ops"].as_array().map(Vec::len), Some(1), "{update}");
}
