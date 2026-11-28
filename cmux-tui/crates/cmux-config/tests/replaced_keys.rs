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
        replaced_by_row(&row.path).next().is_some(),
        "retired-keys.json says remote.ultra replaced it"
    );
    let read = |root: Value| effective_value(&row, &root, &Domains::default());
    assert_eq!(read(json!({"remote": {"ultraMode": true}})), Some(json!("always")));
    assert_eq!(read(json!({"remote": {"ultraMode": false}})), Some(json!("auto")), "the default");
    assert_eq!(read(json!({"remote": {"ultraMode": true, "ultra": "off"}})), Some(json!("off")));
    assert_eq!(read(json!({})), Some(json!("auto")));
}

/// `updates.automatic` replaced three toggles (retired-keys.json): while it is
/// unset the first of them, in the file's order, whose value the table lists
/// answers for it (checks off, then idle install on, then downloads), and a
/// write or reset of it removes all three.
#[test]
fn a_row_that_replaced_several_keys_reads_them_in_order_and_removes_all() {
    let path = ["updates".to_string(), "automatic".to_string()];
    assert_eq!(replaced_by_row(&path).count(), 3, "retired-keys.json lists three");
    let read = |root: Value| cmux_config::schema::replaced_value(&path, &root).cloned();
    let both = json!({"updates": {"checkAutomatically": false, "installWhenIdle": true}});
    assert_eq!(read(both), Some(json!("off")), "checks off wins");
    let idle = json!({"updates": {"installWhenIdle": true, "downloadAutomatically": false}});
    assert_eq!(read(idle), Some(json!("idle")));
    assert_eq!(read(json!({"updates": {"downloadAutomatically": true}})), Some(json!("download")));
    assert_eq!(read(json!({"updates": {"downloadAutomatically": false}})), Some(json!("notify")));
    assert_eq!(read(json!({"updates": {"checkAutomatically": true}})), None, "the default");
    assert_eq!(read(json!({})), None);

    let old = r#"{"updates": {"checkAutomatically": true, "downloadAutomatically": true, "installWhenIdle": false, "channel": "dev"}}"#;
    for op in [
        Op::Set { target: key("updates.automatic"), value: json!("idle"), meta: user() },
        Op::Reset { target: key("updates.automatic"), meta: user() },
    ] {
        let text = apply(&state(old), op).expect("applies").write.expect("a change");
        let root: Value = serde_json::from_str(&text).expect("JSON");
        for gone in ["checkAutomatically", "downloadAutomatically", "installWhenIdle"] {
            assert_eq!(root.pointer(&format!("/updates/{gone}")), None, "{gone}: {root}");
        }
        assert_eq!(root.pointer("/updates/channel"), Some(&json!("dev")));
    }
}

/// A managed profile or team policy that still forces an old update toggle
/// forces and locks `updates.automatic` in that layer (greptile on cmux#51125).
#[test]
fn a_forced_old_update_toggle_forces_and_locks_the_choice() {
    let schema = Schema::embedded();
    let mut managed = ManagedPreferences::default();
    managed.forced.insert("updates.checkAutomatically".into(), json!(false));
    let file = json!({"updates": {"automatic": "download"}});
    let merged =
        cmux_config::EffectiveSettings::merge(&file, &managed, &TeamPolicyLayer::default(), schema);
    assert_eq!(merged.root.pointer("/updates/automatic"), Some(&json!("off")));
    assert!(merged.managed_keys.contains_key("updates.automatic"), "{:?}", merged.managed_keys);

    let mut team = TeamPolicyLayer::default();
    team.enforced.insert("updates.downloadAutomatically".into(), json!(false));
    let merged = cmux_config::EffectiveSettings::merge(
        &json!({}),
        &ManagedPreferences::default(),
        &team,
        schema,
    );
    assert_eq!(merged.root.pointer("/updates/automatic"), Some(&json!("notify")));
    assert!(merged.managed_keys.contains_key("updates.automatic"));

    // A team default for the row does not beat the person's old toggle in their file.
    let mut team = TeamPolicyLayer::default();
    team.defaults.insert("updates.automatic".into(), json!("idle"));
    let file = json!({"updates": {"checkAutomatically": false}});
    let merged =
        cmux_config::EffectiveSettings::merge(&file, &ManagedPreferences::default(), &team, schema);
    assert_eq!(merged.root.pointer("/updates/automatic"), Some(&json!("off")));
}

/// A plain rename (`replaced_by`, no `values`): the old key's value reads as
/// is, as Swift `RenamedSettingKeys` read the Session Info placement by hand.
#[test]
fn a_plain_rename_reads_the_old_value_as_is() {
    let row = Schema::embedded().row("sidebar.workspaceRow.tabCount").expect("the row").clone();
    assert!(
        replaced_by_row(&row.path).next().is_some(),
        "retired-keys.json renames sidebar.showCounts"
    );
    let read = |root: Value| effective_value(&row, &root, &Domains::default());
    let default = row.default.clone().expect("a default");
    let other = json!(!default.as_bool().expect("a toggle"));
    assert_eq!(read(json!({"sidebar": {"showCounts": other}})), Some(other.clone()));
    let new = json!({"sidebar": {"showCounts": other, "workspaceRow": {"tabCount": default}}});
    assert_eq!(read(new), Some(default), "the new key wins");
}
