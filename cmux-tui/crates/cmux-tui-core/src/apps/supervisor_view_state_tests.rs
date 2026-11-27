//! Supervisor tests of a view's kept state (`view_state.rs`): what a view's
//! runtime sends with `app.view.state` stays in its mount context, so the
//! mount a restarted host (a `cmux ext dev` save) or a Reload gets has it.

use super::super::supervisor::MountKey;
use super::*;

fn kept(f: &Fixture, mount_id: &str) -> Value {
    let inner = f.supervisor.inner.lock().unwrap();
    inner
        .mounts
        .get(&MountKey { client: CLIENT, mount_id: mount_id.into() })
        .map_or(Value::Null, |m| m.context.get("state").cloned().unwrap_or(Value::Null))
}

/// A code save restarts the host; the section it mounts again carries the
/// state its runtime kept (base red: the remount had the context the client
/// first sent, so a hot reload lost every ctx value the view held).
#[test]
fn kept_state_survives_a_code_save() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("s1", "local/spy", "cmux.section/1", json!({ "surface": "sidebarSection" }));
    let state = json!({ "tab": "closed", "count": 2 });
    let result = f.call("s1", "app.view.state", json!({ "mount": "7:s1", "state": state }), false);
    assert_eq!(result, json!({ "ok": true, "body": { "value": { "kept": true } } }));
    assert_eq!(kept(&f, "s1"), state);

    std::fs::write(f.state.join("apps/local/spy/dist/main.js"), "var __cmuxAppExports = { v: 2 };")
        .unwrap();
    f.supervisor.reload_local_apps(&prints);
    f.wait("the save's scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "s1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(kept(&f, "s1"), state, "the re-sent mount keeps the state");
}

/// A Reload (the same view mounted again under its id) keeps the state; a
/// new context with its own state, null state, or the view closing drops it.
#[test]
fn a_reload_keeps_state_and_closing_forgets_it() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    f.call("s1", "app.view.state", json!({ "mount": "7:s1", "state": { "n": 1 } }), false);
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    assert_eq!(kept(&f, "s1"), json!({ "n": 1 }), "a Reload keeps it");
    f.mount("s1", "local/spy", "cmux.section/1", json!({ "state": { "n": 9 } }));
    assert_eq!(kept(&f, "s1"), json!({ "n": 9 }), "the client's own state wins");
    f.call("s1", "app.view.state", json!({ "mount": "7:s1", "state": null }), false);
    assert_eq!(kept(&f, "s1"), Value::Null, "null forgets it");
    f.call("s1", "app.view.state", json!({ "mount": "7:s1", "state": { "n": 2 } }), false);
    f.supervisor.unmount(CLIENT, "s1").unwrap();
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    assert_eq!(kept(&f, "s1"), Value::Null, "a closed view starts again");
}

/// State that is not an object or is too big, and a mount that is not one
/// of the caller's, are refused.
#[test]
fn bad_state_and_foreign_mounts_are_refused() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("s1", "local/spy", "cmux.section/1", json!({}));
    let big = "x".repeat(super::super::view_state::MAX_BYTES + 1);
    for params in [
        json!({ "mount": "7:s1", "state": [1] }),
        json!({ "mount": "7:s1", "state": { "big": big } }),
        json!({ "mount": "7:nope", "state": {} }),
        json!({ "mount": "8:s1", "state": {} }),
        json!({ "state": {} }),
    ] {
        let result = f.call("s1", "app.view.state", params, false);
        assert_eq!(result["ok"], false, "{result}");
        assert_eq!(result["body"]["code"], "validation.invalid", "{result}");
    }
    assert_eq!(kept(&f, "s1"), Value::Null);
}
