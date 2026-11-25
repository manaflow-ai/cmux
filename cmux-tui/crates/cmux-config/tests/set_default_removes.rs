//! `settings.set` of a row's default removes the key, so the key follows the
//! default when a later release changes it (Swift `setSetting`, Leo
//! 2026-11-08); another value is still stored, and a layer below the file
//! that fills the key keeps the explicit default.

use cmux_config::{
    Domains, Edit, EditKind, FileRead, ManagedPreferences, Op, Origin, Schema, State, Target,
    TeamPolicyLayer, WriteMeta, apply,
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

#[test]
fn explicit_automatic_groups_override_a_preset_until_reset() {
    let key = "sidebar.groupHeader.background";
    let target = Target::Key(key.to_string());
    for look in ["claude", "codex", "studio"] {
        let inherited = state(&json!({"sidebar": {"look": look}}).to_string(), Default::default());
        assert_eq!(inherited.get(&target).value, Some(json!("sections")));
        let written = set(&inherited, key, json!("auto")).expect("an explicit choice is stored");
        let chosen = state(&written, Default::default());
        let view = chosen.get(&target);
        assert_eq!(view.file_value, Some(json!("auto")));
        assert_eq!(view.value, Some(json!("auto")));
        assert!(view.row.unwrap().customized);

        let reset =
            apply(&chosen, Op::Reset { target: target.clone(), meta: WriteMeta::default() })
                .unwrap()
                .write
                .expect("reset removes the override");
        let inherited = state(&reset, Default::default()).get(&target);
        assert_eq!(inherited.file_value, None);
        assert_eq!(inherited.value, Some(json!("sections")));
        assert!(!inherited.row.unwrap().customized);
    }
}

#[test]
fn automatic_groups_follow_the_next_preset_when_the_current_look_has_no_override() {
    let key = "sidebar.groupHeader.background";
    let target = Target::Key(key.to_string());
    let initial =
        state(r#"{"sidebar":{"groupHeader":{"background":"folder"}}}"#, Default::default());
    let written = set(&initial, key, json!("auto")).expect("the old choice is removed");
    let standard = state(&written, Default::default());
    let row = standard.get(&target);
    assert_eq!(row.file_value, None);
    assert!(!row.row.unwrap().customized);

    let switched = set(&standard, "sidebar.look", json!("codex")).unwrap();
    let inherited = state(&switched, Default::default()).get(&target);
    assert_eq!(inherited.value, Some(json!("sections")));
    assert_eq!(inherited.file_value, None);
}

#[test]
fn automatic_groups_follow_the_look_selected_earlier_in_a_batch() {
    let key = "sidebar.groupHeader.background";
    let target = Target::Key(key.to_string());
    for (before, after, expected) in
        [("cmux", "studio", Some(json!("auto"))), ("studio", "cmux", None)]
    {
        let initial = state(
            &json!({"sidebar":{"look":before,"groupHeader":{"background":"folder"}}}).to_string(),
            Default::default(),
        );
        let chosen = apply(
            &initial,
            Op::Edit {
                edits: vec![
                    Edit {
                        target: Target::Key("sidebar.look".into()),
                        kind: EditKind::Set(json!(after)),
                    },
                    Edit { target: target.clone(), kind: EditKind::Set(json!("auto")) },
                ],
                meta: WriteMeta { origin: Origin::User, ..WriteMeta::default() },
            },
        )
        .unwrap()
        .state;
        let view = chosen.get(&target);
        assert_eq!(view.file_value, expected, "{before} -> {after}");
        assert_eq!(view.row.unwrap().customized, expected.is_some());
    }
}
