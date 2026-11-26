//! Ports `SettingsBuildDefaultsChildEnvironmentTests` and the decisions of
//! `SettingsBuildDefaultsTests` (the controller's apply and file reads stay
//! in Swift's tests).

use serde_json::{Value, json};

use crate::app_ops::call;
use crate::schema::{Schema, build_defaults_from};

fn ask(op: &str, request: Value) -> Value {
    call(op, &request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

fn channel(downloads: bool, dev: bool, idle: bool) -> Value {
    ask(
        "build_defaults.channel",
        json!({ "downloads_automatically": downloads, "dev_build": dev, "installs_when_idle": idle }),
    )["values"]
        .clone()
}

fn child_environment(values: Value) -> Value {
    ask("build_defaults.child_environment", json!({ "values": values }))
        .get("value")
        .cloned()
        .unwrap_or(Value::Null)
}

fn fill(root: Value, values: Value) -> Value {
    ask("build_defaults.fill", json!({ "root": root, "values": values }))["root"].clone()
}

fn customized(request: Value) -> bool {
    ask("build_defaults.is_customized", request)["customized"] == json!(true)
}

const AUTOMATIC: &str = "updates.automatic";

// MARK: SettingsBuildDefaultsChildEnvironmentTests

#[test]
fn a_dev_build_passes_its_defaults() {
    assert_eq!(
        child_environment(channel(false, true, false)),
        json!(r#"{"mobile.allowIPhoneConnections":true}"#)
    );
    assert_eq!(
        child_environment(channel(true, true, false)),
        json!(r#"{"mobile.allowIPhoneConnections":true,"updates.automatic":"download"}"#)
    );
    assert_eq!(
        child_environment(channel(true, false, false)),
        json!(r#"{"updates.automatic":"download"}"#)
    );
}

#[test]
fn a_build_without_defaults_passes_nothing() {
    assert_eq!(ask("build_defaults.child_environment", json!({})), json!({}));
    assert_eq!(child_environment(channel(false, false, false)), Value::Null);
}

/// Every key it passes is a schema key, so the Rust owner (which ignores
/// unknown keys) applies each; and the owner reads the text back whole.
#[test]
fn every_key_is_a_setting_and_the_owner_reads_it_back() {
    let values = channel(true, true, true);
    let schema = Schema::embedded();
    for key in values.as_object().unwrap().keys() {
        assert!(schema.row(key).is_some(), "{key}");
    }
    let text = child_environment(values.clone());
    let read = build_defaults_from(text.as_str());
    assert_eq!(Value::Object(read.into_iter().collect()), values);
}

// MARK: SettingsBuildDefaultsTests

#[test]
fn the_channel_names_each_build_default() {
    assert_eq!(channel(false, false, false), json!({}));
    assert_eq!(channel(true, false, false), json!({ AUTOMATIC: "download" }));
    assert_eq!(channel(false, false, true), json!({ AUTOMATIC: "idle" }));
    assert_eq!(channel(true, false, true), json!({ AUTOMATIC: "idle" }));
    assert_eq!(channel(false, true, false), json!({ "mobile.allowIPhoneConnections": true }));
    assert_eq!(ask("build_defaults.channel", json!({}))["values"], json!({}));
}

/// The dogfood default fills the effective settings only: the root it was
/// given (the file's) is left as it was.
#[test]
fn the_dogfood_default_fills_the_effective_settings_only() {
    let file = json!({});
    let effective = fill(file.clone(), channel(true, false, false));
    assert_eq!(effective, json!({ "updates": { "automatic": "download" } }));
    assert_eq!(file, json!({}));
}

/// A value someone wrote is never filled by the build default, even one that
/// does not decode (the snapshot reads that as the schema's default), nor
/// one of the toggles the choice replaced that still reads as a pick
/// (retired-keys.json).
#[test]
fn a_value_someone_wrote_wins() {
    for written in [json!("notify"), json!("off"), json!("download"), json!(3)] {
        let file = json!({ "updates": { "automatic": written } });
        assert_eq!(fill(file.clone(), channel(true, false, false)), file);
        assert_eq!(fill(file.clone(), channel(false, false, false)), file);
    }
    for old in [
        json!({ "downloadAutomatically": false }),
        json!({ "checkAutomatically": false }),
        json!({ "installWhenIdle": true }),
    ] {
        let file = json!({ "updates": old });
        assert_eq!(fill(file.clone(), channel(true, false, true)), file, "{old}");
    }
}

/// Install When Idle is the Automatic Updates default in cmux NEXT NIGHTLY
/// and not in release (Leo, 2026-11-22: "auto be de facto able to click the
/// restart button"); an explicit pick in NIGHTLY wins.
#[test]
fn update_when_idle_follows_the_build() {
    let nightly = channel(true, false, true);
    assert_eq!(fill(json!({}), nightly.clone())["updates"]["automatic"], json!("idle"));
    let picked = json!({ "updates": { "automatic": "download" } });
    assert_eq!(fill(picked, nightly)["updates"]["automatic"], json!("download"));
    assert_eq!(fill(json!({}), channel(false, false, false)), json!({}));
    let release = ask("build_defaults.default_value", json!({ "key": AUTOMATIC }));
    assert_eq!(release["value"], json!("download"), "release downloads, never installs when idle");
}

/// Fill makes the objects along the way and keeps the file's other keys; a
/// non-object in the way is replaced, as Swift's `JSONValue.setting`.
#[test]
fn fill_keeps_the_other_keys_and_makes_the_objects() {
    let file = json!({ "updates": { "channel": "nightly" }, "mobile": 3 });
    assert_eq!(
        fill(file, channel(true, true, false)),
        json!({
            "updates": { "channel": "nightly", "automatic": "download" },
            "mobile": { "allowIPhoneConnections": true },
        })
    );
}

/// Automatic download is the schema's default (Leo 2026-11-07: "Yeah, let's
/// do that, man"); a build default is the row's default over it.
#[test]
fn the_default_is_the_build_default_over_the_schemas() {
    assert_eq!(
        ask("build_defaults.default_value", json!({ "key": AUTOMATIC }))["value"],
        json!("download")
    );
    assert_eq!(
        ask(
            "build_defaults.default_value",
            json!({ "key": AUTOMATIC, "values": { AUTOMATIC: "idle" } })
        )["value"],
        json!("idle")
    );
    assert_eq!(ask("build_defaults.default_value", json!({ "key": "no.suchKey" })), json!({}));
}

/// A pick other than Download Automatically in NIGHTLY differs from its
/// default, so Settings offers Reset; Download Automatically does not; an
/// unset key never does.
#[test]
fn reset_follows_the_build_default() {
    let nightly = channel(true, false, false);
    for (stored, expected) in [(json!("notify"), true), (json!("download"), false)] {
        let file = json!({ "updates": { "automatic": stored } });
        let request =
            json!({ "key": AUTOMATIC, "stored": stored, "file_root": file, "values": nightly });
        assert_eq!(customized(request), expected, "{stored}");
    }
    assert!(!customized(json!({ "key": AUTOMATIC, "file_root": {}, "values": nightly })));
    assert!(!customized(json!({ "key": AUTOMATIC, "stored": null, "file_root": {} })));
    // Release: Install When Idle is not the default, so picking it is the person's.
    assert!(customized(json!({ "key": AUTOMATIC, "stored": "idle", "file_root": {} })));
    assert!(!customized(json!({
        "key": AUTOMATIC, "stored": "idle", "file_root": {}, "values": channel(true, false, true)
    })));
    // Numbers compare as Swift's doubles.
    assert!(!customized(
        json!({ "key": "x.y", "stored": 1.0, "file_root": {}, "values": { "x.y": 1 } })
    ));
}

/// A value kept over the active theme file is the person's even at the
/// default (#44894), but only while that file sets the key.
#[test]
fn a_value_kept_over_the_theme_file_is_customized() {
    let key = "appearance.accent";
    let default = ask("build_defaults.default_value", json!({ "key": key }))["value"].clone();
    let file = json!({ "appearance": { "accent": default, "themeFileExceptions": [key] } });
    let request = |sets: bool| json!({ "key": key, "stored": default, "file_root": file, "theme_file_sets": sets });
    assert!(customized(request(true)));
    assert!(!customized(request(false)));
    let unkept = json!({ "key": key, "stored": default, "file_root": { "appearance": { "accent": default } }, "theme_file_sets": true });
    assert!(!customized(unkept));
}

/// Resetting an explicit sidebar group style returns ownership to the
/// sidebar look, so one over a look that sets it is customized at the default.
#[test]
fn an_explicit_group_style_over_the_look_is_customized() {
    let key = "sidebar.groupHeader.background";
    let file = json!({ "sidebar": { "groupHeader": { "background": "auto" } } });
    let request = |below: bool| json!({ "key": key, "stored": "auto", "file_root": file, "set_below_file": below });
    assert!(customized(request(true)));
    assert!(!customized(request(false)));
}

/// The default with nothing below the file is unset (the file leaves the key
/// out and follows a later change of the default).
#[test]
fn the_default_with_nothing_below_is_unset() {
    let unset =
        |request: Value| ask("build_defaults.is_unset_value", request)["unset"] == json!(true);
    assert!(unset(json!({ "key": AUTOMATIC, "value": "download" })));
    assert!(!unset(json!({ "key": AUTOMATIC, "value": "notify" })));
    assert!(!unset(json!({ "key": AUTOMATIC, "value": "download", "set_below_file": true })));
    assert!(unset(json!({ "key": AUTOMATIC, "value": "idle", "values": { AUTOMATIC: "idle" } })));
    assert!(!unset(json!({ "key": AUTOMATIC, "value": "idle" })));
}

#[test]
fn a_request_that_is_not_the_ops_json_is_refused() {
    assert!(call("build_defaults.fill", &json!({ "root": {}, "values": [1] })).is_err());
    assert!(call("build_defaults.default_value", &json!({})).is_err());
    assert!(call("build_defaults.is_customized", &json!({ "stored": true })).is_err());
}
