//! A build's defaults (Swift `SettingsBuildDefaults`, passed by the Mac app as
//! `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS`) are the defaults the Rust settings owner reports: a DEV build's
//! `cmux settings get mobile.allowIPhoneConnections` says true, as its app does, until someone sets the key.

use std::collections::BTreeMap;

use cmux_config::schema::{BUILD_DEFAULTS_ENV, build_defaults_from};
use cmux_config::{Domains, FileRead, ManagedPreferences, Schema, State, Target, TeamPolicyLayer};
use serde_json::{Value, json};

const SCHEMA: &str = include_str!("../../../../schemas/settings/settings-schema.json");
const MOBILE: &str = "mobile.allowIPhoneConnections";
const DOWNLOAD: &str = "updates.downloadAutomatically";

fn schema(defaults: &BTreeMap<String, Value>) -> &'static Schema {
    let parsed = Schema::parse(SCHEMA).expect("the settings schema parses");
    Box::leak(Box::new(parsed.with_build_defaults(defaults)))
}

fn state(schema: &'static Schema, file: &str) -> State {
    State::new(
        schema,
        FileRead::Text(file.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

fn dev_defaults() -> BTreeMap<String, Value> {
    build_defaults_from(Some(
        r#"{"mobile.allowIPhoneConnections":true,"updates.downloadAutomatically":true}"#,
    ))
}

#[test]
fn dev_build_own_settings_defaults_parse_the_apps_variable() {
    assert_eq!(BUILD_DEFAULTS_ENV, "CMUX_NEXT_SETTINGS_BUILD_DEFAULTS");
    let defaults = dev_defaults();
    assert_eq!(defaults.get(MOBILE), Some(&json!(true)));
    assert_eq!(defaults.get(DOWNLOAD), Some(&json!(true)));
    assert!(build_defaults_from(None).is_empty());
    assert!(build_defaults_from(Some("not json")).is_empty());
    assert!(build_defaults_from(Some("[true]")).is_empty());
}

#[test]
fn dev_build_own_settings_defaults_are_what_get_reports() {
    let schema = schema(&dev_defaults());
    let fresh = state(schema, "{}");
    let get = fresh.get(&Target::Key(MOBILE.into()));
    let row = get.row.as_ref().expect("the row");
    assert_eq!(row.value, Some(json!(true)), "a DEV build reports its app's default");
    assert_eq!(row.default, Some(json!(true)));
    assert!(!row.customized);
    assert_eq!(get.value, Some(json!(true)), "the effective settings carry the build default");
    assert_eq!(get.file_value, None, "the build default is not the person's");
    let download = fresh.get(&Target::Key(DOWNLOAD.into()));
    assert_eq!(download.row.as_ref().and_then(|row| row.value.clone()), Some(json!(true)));

    // A value someone wrote wins, and an explicit off differs from the default (Reset is offered).
    let off = state(schema, r#"{"mobile": {"allowIPhoneConnections": false}}"#);
    let row = off.get(&Target::Key(MOBILE.into())).row.expect("the row");
    assert_eq!(row.value, Some(json!(false)));
    assert!(row.customized);
}

#[test]
fn dev_build_own_settings_defaults_leave_other_builds_and_bad_values_alone() {
    // NIGHTLY and stable pass nothing: the schema's default.
    let shared = state(schema(&BTreeMap::new()), "{}");
    let row = shared.get(&Target::Key(MOBILE.into())).row.expect("the row");
    assert_eq!(row.value, Some(json!(false)));
    // A value the row refuses and a key no row has are ignored.
    let odd =
        build_defaults_from(Some(r#"{"mobile.allowIPhoneConnections":"yes","no.such.key":1}"#));
    let state = state(schema(&odd), "{}");
    let row = state.get(&Target::Key(MOBILE.into())).row.expect("the row");
    assert_eq!(row.value, Some(json!(false)));
    assert_eq!(row.default, Some(json!(false)));
}
