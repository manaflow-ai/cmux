//! An extension's own settings (the manifest's `settings`, a JSON Schema object): the daemon lists
//! them for Settings > Extensions, validates and stores a change, and a running host gets the new
//! values live (`ToHost::Settings`) with a `settings.changed` event.

use super::*;

/// A bundled app `cmux/prefs` whose manifest declares three settings.
fn prefs_fixture() -> Fixture {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    write_app(&bundled, "prefs", "cmux/prefs", json!({ "workspace:read": "r" }));
    let path = bundled.join("prefs/cmux-app.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["settings"] = json!({
        "type": "object",
        "properties": {
            "greeting": { "type": "string", "title": "Greeting", "default": "Hello", "maxLength": 40 },
            "compact": { "type": "boolean", "title": "Compact rows", "default": false },
            "size": { "type": "string", "enum": ["small", "large"], "default": "small" },
            "limit": { "type": "integer", "minimum": 1, "maximum": 50, "default": 10 }
        }
    });
    std::fs::write(&path, manifest.to_string()).unwrap();
    fixture_with(&[], Duration::from_secs(60), root)
}

fn set(f: &Fixture, key: &str, values: Value) -> Result<Value, super::super::supervisor::ApiError> {
    f.supervisor.store_call(
        CLIENT,
        "apps.settings.set",
        json!({ "app": "cmux/prefs", "values": values, "idempotency_key": key }),
        Origin::User,
    )
}

fn listed(f: &Fixture) -> Value {
    let list =
        f.supervisor.store_call(CLIENT, "apps.settings.list", json!({}), Origin::User).unwrap();
    list["apps"].as_array().unwrap().iter().find(|a| a["app"] == "cmux/prefs").cloned().unwrap()
}

#[test]
fn extension_settings_are_listed_with_their_schema_and_defaults() {
    let f = prefs_fixture();
    f.install("cmux/prefs");
    f.install("cmux/demo");
    let list =
        f.supervisor.store_call(CLIENT, "apps.settings.list", json!({}), Origin::User).unwrap();
    let apps: Vec<_> = list["apps"].as_array().unwrap().iter().map(|a| a["app"].clone()).collect();
    // An app whose manifest has no settings is not listed.
    assert_eq!(apps, [json!("cmux/prefs")]);
    let prefs = listed(&f);
    assert_eq!(prefs["schema"]["properties"]["compact"]["title"], "Compact rows");
    assert_eq!(
        prefs["values"],
        json!({ "greeting": "Hello", "compact": false, "size": "small", "limit": 10 })
    );
}

#[test]
fn a_changed_setting_is_validated_stored_and_reaches_the_running_host_live() {
    let f = prefs_fixture();
    f.install("cmux/prefs");
    f.mount("p", "cmux/prefs", "cmux.palette.scope/1", json!({ "stream": "settings.changed" }));
    f.supervisor.logs(CLIENT, "cmux/prefs", true);

    let answer = set(&f, "k1", json!({ "compact": true, "limit": 25 })).unwrap();
    assert_eq!(answer["values"]["compact"], true);
    // The host gets the whole effective value set, then the event.
    let pushed = f.wait("settings pushed", |e| {
        e["event"] == "apps-log"
            && e["message"].as_str().is_some_and(|m| m.starts_with("settings "))
    });
    let values: Value =
        serde_json::from_str(pushed["message"].as_str().unwrap().trim_start_matches("settings "))
            .unwrap();
    assert_eq!(
        values,
        json!({ "greeting": "Hello", "compact": true, "size": "small", "limit": 25 })
    );
    f.wait("settings.changed", |e| e["event"] == "apps-log" && e["message"] == "event 1");
    assert_eq!(listed(&f)["values"]["limit"], 25);

    // Same key, same change: a replay. Same key, another change: a conflict.
    assert!(set(&f, "k1", json!({ "compact": true, "limit": 25 })).is_ok());
    assert_eq!(
        set(&f, "k1", json!({ "compact": false })).unwrap_err().code,
        "idempotency.conflict"
    );

    // null resets one key to its default.
    set(&f, "k2", json!({ "limit": null })).unwrap();
    assert_eq!(listed(&f)["values"]["limit"], 10);
}

#[test]
fn a_setting_outside_the_manifest_schema_is_refused_and_nothing_changes() {
    let f = prefs_fixture();
    f.install("cmux/prefs");
    for (key, values) in [
        ("b1", json!({ "compact": "yes" })),
        ("b2", json!({ "size": "huge" })),
        ("b3", json!({ "limit": 0 })),
        ("b4", json!({ "limit": 2.5 })),
        ("b5", json!({ "greeting": "x".repeat(41) })),
        ("b6", json!({ "unknown": 1 })),
        ("b7", json!("not an object")),
    ] {
        let error = set(&f, key, values.clone()).unwrap_err();
        assert_eq!(error.code, "apps.settings.invalid", "{values}");
    }
    assert_eq!(listed(&f)["values"]["limit"], 10);
    let missing = f
        .supervisor
        .store_call(
            CLIENT,
            "apps.settings.set",
            json!({ "app": "cmux/demo", "values": { "x": 1 }, "idempotency_key": "d" }),
            Origin::User,
        )
        .unwrap_err();
    assert_eq!(missing.code, "apps.settings.invalid");
}

#[test]
fn a_host_that_starts_later_loads_the_stored_values() {
    let f = prefs_fixture();
    f.install("cmux/prefs");
    set(&f, "k1", json!({ "size": "large" })).unwrap();
    // The host logs its init settings before the first scene, which `mount` waits past: read the
    // app's log, which holds every line the host sent before that scene.
    f.mount("p", "cmux/prefs", "cmux.palette.scope/1", json!({}));
    let logs = f.supervisor.logs(CLIENT, "cmux/prefs", false);
    let init = logs["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|line| line["message"].as_str()?.strip_prefix("init-settings "))
        .next()
        .expect("the host logged the settings it loaded with");
    let values: Value = serde_json::from_str(init).unwrap();
    assert_eq!(values["size"], "large");
    assert_eq!(values["greeting"], "Hello");
}

#[test]
fn stored_settings_are_written_with_the_install_record() {
    let f = prefs_fixture();
    f.install("cmux/prefs");
    set(&f, "k1", json!({ "greeting": "Hi there" })).unwrap();
    let file: Value =
        serde_json::from_slice(&std::fs::read(f.state.join("apps.json")).unwrap()).unwrap();
    assert_eq!(file["mirror"]["apps"]["cmux/prefs"]["settings"], json!({ "greeting": "Hi there" }));
}
