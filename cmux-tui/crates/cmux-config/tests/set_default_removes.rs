//! `settings.set` of a row's default removes the key, so the key follows the
//! default when a later release changes it (Swift `setSetting`, Leo
//! 2026-11-08); another value is still stored, and a layer below the file
//! that fills the key keeps the explicit default.

use cmux_config::{
    Domains, FileRead, ManagedPreferences, Op, Origin, Schema, State, Target, TeamPolicyLayer,
    WriteMeta, apply,
};
use serde_json::{Value, json};

fn set(state: &State, key: &str, value: Value) -> Option<String> {
    let meta = WriteMeta { origin: Origin::User, ..WriteMeta::default() };
    apply(state, Op::Set { target: Target::Key(key.to_string()), value, meta })
        .expect("the write applies")
        .write
}

fn state(text: &str, managed: ManagedPreferences) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

#[test]
fn setting_the_default_removes_the_key() {
    let key = "appearance.chromeStyle";
    let default = Schema::embedded()
        .rows
        .iter()
        .find(|row| row.key == key)
        .and_then(|row| row.default.clone());
    let default = default.expect("appearance.chromeStyle has a default");
    let other = if default == json!("flat") { json!("flat-sidebar-line") } else { json!("flat") };

    let stored = state(
        &format!(r#"{{"appearance": {{"chromeStyle": {other}}}, "layout": {{"panePadding": 4}}}}"#),
        ManagedPreferences::default(),
    );
    let written = set(&stored, key, default.clone()).expect("the file changes");
    let root: Value = serde_json::from_str(&written).expect("JSON");
    assert_eq!(root.pointer("/appearance/chromeStyle"), None, "{written}");
    assert_eq!(root.get("appearance"), None, "the emptied object goes too: {written}");
    assert_eq!(root.pointer("/layout/panePadding"), Some(&json!(4)));

    let written = set(&state("{}", ManagedPreferences::default()), key, other.clone())
        .expect("the file changes");
    let root: Value = serde_json::from_str(&written).expect("JSON");
    assert_eq!(
        root.pointer("/appearance/chromeStyle"),
        Some(&other),
        "a value other than the default is stored"
    );

    let mut managed = ManagedPreferences::default();
    managed.recommended.insert(key.to_string(), other);
    let written = set(&state("{}", managed), key, default.clone()).expect("the file changes");
    let root: Value = serde_json::from_str(&written).expect("JSON");
    assert_eq!(
        root.pointer("/appearance/chromeStyle"),
        Some(&default),
        "MDM recommends another value, so the default stays"
    );
}
