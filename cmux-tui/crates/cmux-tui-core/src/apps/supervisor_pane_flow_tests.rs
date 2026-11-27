//! Supervisor tests of a pane's open arguments and result (`pane_flow.rs`):
//! `app.pane.open` from one view of an app waits for the app's pane to
//! answer with `app.pane.close`, or for the person to close it.

use super::super::supervisor::MountKey;
use super::*;

/// Gives `local/spy` a pane (export `renderPane`) next to its section, then
/// installs it.
fn spy_with_pane(f: &Fixture) {
    let prints = f.supervisor.reload_local_apps(&Default::default());
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.pane/1"] = json!({ "export": "renderPane", "title": "Spy" });
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&prints);
    f.install("local/spy");
}

/// Sends a scripted call from `mount_id` without waiting for its answer.
fn send_call(f: &Fixture, mount_id: &str, op: &str, params: Value) {
    f.supervisor
        .dispatch(CLIENT, mount_id, "n1", "tap", json!({ "op": op, "params": params }), false)
        .unwrap();
}

/// Collects call answers (`{ok, body}`) by mount until `n` have come.
fn answers(f: &Fixture, n: usize) -> Vec<(String, Value)> {
    let mut got = Vec::new();
    while got.len() < n {
        let update = f
            .wait("a call answer", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
        for op in update["ops"].as_array().unwrap() {
            if !op["props"]["result"].is_null() {
                got.push((
                    update["mount_id"].as_str().unwrap().to_string(),
                    op["props"]["result"].clone(),
                ));
            }
        }
    }
    got
}

fn pane_args(f: &Fixture, mount_id: &str) -> Value {
    let inner = f.supervisor.inner.lock().unwrap();
    inner.mounts[&MountKey { client: CLIENT, mount_id: mount_id.into() }].context["args"].clone()
}

/// A picker in the section opens the pane on screen with arguments; the
/// pane's close answers the picker with its result (base red: a pane had no
/// open arguments or result, so a panel flow went through app.storage).
#[test]
fn a_pane_answers_its_opener_with_its_result() {
    let f = fixture();
    spy_with_pane(&f);
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    f.mount("p1", "local/spy", "cmux.pane/1", json!({}));
    assert_eq!(pane_args(&f, "p1"), Value::Null, "opened by the person: no arguments");

    send_call(&f, "s1", "app.pane.open", json!({ "args": { "id": "42" } }));
    // The pane on screen mounts again with the arguments.
    f.wait("the pane's new scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "p1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(pane_args(&f, "p1"), json!({ "id": "42" }));

    send_call(&f, "p1", "app.pane.close", json!({ "mount": "7:p1", "result": { "picked": "a" } }));
    let mut got = answers(&f, 2);
    got.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        got[0],
        ("p1".into(), json!({ "ok": true, "body": { "value": { "closed": true } } }))
    );
    assert_eq!(
        got[1],
        (
            "s1".into(),
            json!({ "ok": true, "body": { "value": { "result": { "picked": "a" }, "dismissed": false } } })
        )
    );
}

/// The person closing the pane the open bound dismisses the open.
#[test]
fn closing_the_bound_pane_dismisses_the_open() {
    let f = fixture();
    spy_with_pane(&f);
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    send_call(&f, "s1", "app.pane.open", json!({ "args": { "id": "7" } }));
    // The tab the open asked for mounts with the arguments.
    std::thread::sleep(Duration::from_millis(200));
    f.mount("p1", "local/spy", "cmux.pane/1", json!({}));
    assert_eq!(pane_args(&f, "p1"), json!({ "id": "7" }));
    f.supervisor.unmount(CLIENT, "p1").unwrap();
    let got = answers(&f, 1);
    assert_eq!(
        got[0],
        (
            "s1".into(),
            json!({ "ok": true, "body": { "value": { "result": null, "dismissed": true } } })
        )
    );
}

/// A newer open dismisses the older one; a close with no mount (the tab did
/// not open) dismisses the open that lasts.
#[test]
fn a_newer_open_and_a_bare_close_dismiss() {
    let f = fixture();
    spy_with_pane(&f);
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    send_call(&f, "s1", "app.pane.open", json!({ "args": { "n": 1 } }));
    send_call(&f, "s1", "app.pane.open", json!({ "args": { "n": 2 } }));
    let dismissed =
        json!({ "ok": true, "body": { "value": { "result": null, "dismissed": true } } });
    assert_eq!(answers(&f, 1)[0].1, dismissed);
    send_call(&f, "s1", "app.pane.close", json!({}));
    let got = answers(&f, 2);
    assert!(got.contains(&("s1".into(), dismissed)), "{got:?}");
    assert!(
        got.contains(&(
            "s1".into(),
            json!({ "ok": true, "body": { "value": { "closed": true } } })
        )),
        "{got:?}"
    );
}

/// Arguments that are not an object, or too big, and a close naming a mount
/// that is not this app's pane, are refused.
#[test]
fn bad_arguments_and_foreign_mounts_are_refused() {
    let f = fixture();
    spy_with_pane(&f);
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    let big = "x".repeat(super::super::pane_flow::MAX_BYTES + 1);
    for params in
        [json!({ "args": [1] }), json!({ "args": { "big": big } }), json!({ "mount": "7:s1" })]
    {
        let op = if params.get("mount").is_some() { "app.pane.close" } else { "app.pane.open" };
        let result = f.call("s1", op, params, false);
        assert_eq!(result["ok"], false, "{result}");
        assert_eq!(result["body"]["code"], "validation.invalid", "{result}");
    }
}
