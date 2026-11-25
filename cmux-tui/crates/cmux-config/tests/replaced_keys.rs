//! A retired key with `replaced_by` (schemas/settings/retired-keys.json):
//! `remote.ultra` (Off, Auto or Always) replaced the toggle
//! `remote.ultraMode`, whose `true` the tunnels still read as Always while
//! `remote.ultra` is absent. A write or reset of `remote.ultra`, and Reset
//! All, removes the old key, so Always never applies behind the new value;
//! and the row reads the old key through the table while it is unset (Swift
//! `RenamedSettingKeys`, from the same file).

use cmux_config::schema::{Kind, effective_value, replaced_by_row};
use cmux_config::{
    Domains, FileRead, ManagedPreferences, Op, Origin, Row, Schema, State, Target, TeamPolicyLayer,
    WriteMeta, apply,
};
use serde_json::{Value, json};

const LEGACY: &str = r#"{"remote": {"ultraMode": true, "endSharingOnQuit": true}}"#;

fn state(text: &str) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

fn user() -> WriteMeta {
    WriteMeta { origin: Origin::User, ..WriteMeta::default() }
}

fn written(op: Op) -> Value {
    let text = apply(&state(LEGACY), op).expect("the write applies").write.expect("a change");
    serde_json::from_str(&text).expect("JSON")
}

fn key(dotted: &str) -> Target {
    Target::Key(dotted.to_string())
}

#[test]
fn writing_or_resetting_the_row_removes_the_old_key() {
    for value in ["auto", "off", "always"] {
        let root =
            written(Op::Set { target: key("remote.ultra"), value: json!(value), meta: user() });
        assert_eq!(root.pointer("/remote/ultraMode"), None, "{value}: {root}");
        assert_eq!(root.pointer("/remote/endSharingOnQuit"), Some(&json!(true)));
        if value != "auto" {
            assert_eq!(root.pointer("/remote/ultra"), Some(&json!(value)));
        }
    }
    let root = written(Op::Reset { target: key("remote.ultra"), meta: user() });
    assert_eq!(root.pointer("/remote/ultraMode"), None, "{root}");
    let root = written(Op::ResetAll { meta: user() });
    assert_eq!(root.pointer("/remote/ultraMode"), None, "Reset All prunes retired keys: {root}");
}

#[test]
fn a_write_without_the_old_key_leaves_the_file_alone() {
    let text = r#"{"remote": {"endSharingOnQuit": true}}"#;
    let meta = user();
    let op = Op::Set { target: key("remote.ultra"), value: json!("off"), meta };
    let written = apply(&state(text), op).expect("applies").write.expect("a change");
    let root: Value = serde_json::from_str(&written).expect("JSON");
    assert_eq!(root, json!({"remote": {"endSharingOnQuit": true, "ultra": "off"}}));
}

/// The `remote.ultra` row: the schema's own once the export lists it, else
/// one built like it (the export is regenerated from Swift after merge).
fn ultra_row() -> Row {
    if let Some(row) = Schema::embedded().row("remote.ultra") {
        return row.clone();
    }
    let mut row = Schema::embedded()
        .rows
        .iter()
        .find(|row| matches!(row.kind, Kind::Choice(_)))
        .expect("a choice row")
        .clone();
    let Kind::Choice(template) = &row.kind else { unreachable!() };
    let choice = |value: &str| {
        let mut choice = template[0].clone();
        choice.value = value.to_string();
        choice
    };
    row.kind = Kind::Choice(vec![choice("off"), choice("auto"), choice("always")]);
    row.key = "remote.ultra".to_string();
    row.path = vec!["remote".to_string(), "ultra".to_string()];
    row.default = Some(json!("auto"));
    row
}

#[test]
fn the_unset_row_reads_the_old_key_as_the_tunnels_do() {
    let row = ultra_row();
    assert!(
        replaced_by_row(&row.path).is_some(),
        "retired-keys.json says remote.ultra replaced it"
    );
    let read = |root: Value| effective_value(&row, &root, &Domains::default());
    assert_eq!(read(json!({"remote": {"ultraMode": true}})), Some(json!("always")));
    assert_eq!(read(json!({"remote": {"ultraMode": false}})), Some(json!("auto")), "the default");
    assert_eq!(read(json!({"remote": {"ultraMode": true, "ultra": "off"}})), Some(json!("off")));
    assert_eq!(read(json!({})), Some(json!("auto")));
}
