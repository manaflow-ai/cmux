//! `appearance.backgroundRecents`: the backgrounds shown before, newest first, recorded by the
//! one settings write every surface shares (CLI, MCP, palette, the app), so one click goes back
//! (Leo, 2026-11-22: "it was cumbersome back then to switch back").

use cmux_config::schema::{Kind, previous_background};
use cmux_config::theme_file::is_look;
use cmux_config::{
    Domains, Edit, EditKind, FileRead, ManagedPreferences, Op, Origin, Schema, State, Target,
    TeamPolicyLayer, ThemeRead, WriteMeta, apply,
};
use serde_json::{Value, json};

const KEY: &str = "appearance.backgroundRecents";

fn state_with(text: &str, managed: ManagedPreferences) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        7,
    )
}

fn user() -> WriteMeta {
    WriteMeta { origin: Origin::User, ..WriteMeta::default() }
}

/// Sets the background with `settings.set` and returns the new file text.
fn set(text: &str, value: &str) -> String {
    let op = Op::Set {
        target: Target::Key("appearance.background".to_string()),
        value: json!(value),
        meta: user(),
    };
    apply(&state_with(text, ManagedPreferences::default()), op)
        .expect("the write applies")
        .write
        .expect("the file changes")
}

fn recents(text: &str) -> Value {
    let root: Value = serde_json::from_str(text).expect("JSON");
    root.pointer("/appearance/backgroundRecents").cloned().unwrap_or(Value::Null)
}

#[test]
fn the_recents_are_a_stored_list_with_no_default() {
    let schema = Schema::embedded();
    let row = schema.row(KEY).expect("appearance.backgroundRecents is a row");
    assert_eq!(row.kind, Kind::StringList);
    assert_eq!(row.default, None);
    assert!(row.agent_settable);
    assert!(!is_look(row), "a theme file never carries history");
}

#[test]
fn every_background_write_records_the_one_it_replaced() {
    let folder = "folder:/Users/me/Art";
    let picture = "file:/Users/me/Pictures/Harbor.png";
    let text = set("{}", folder);
    assert_eq!(recents(&text), json!(["none"]), "unset was its default: {text}");
    let text = set(&text, picture);
    assert_eq!(recents(&text), json!([folder, "none"]));
    let text = set(&text, folder);
    assert_eq!(recents(&text), json!([picture, "none"]), "each once, newest first");
    // Back to the default removes the key and still records.
    let text = set(&text, "none");
    assert_eq!(recents(&text), json!([folder, picture]));
}

#[test]
fn switching_back_toggles_between_a_folder_and_a_picture() {
    let folder = "folder:/Users/me/Art";
    let picture = "munch-scream";
    let mut text = set(&set("{}", folder), picture);
    for expected in [folder, picture, folder] {
        let root: Value = serde_json::from_str(&text).unwrap();
        let current = root.pointer("/appearance/background").and_then(Value::as_str).unwrap();
        let list: Vec<String> = serde_json::from_value(recents(&text)).unwrap();
        let back = previous_background(current, &list).expect("something to go back to");
        assert_eq!(back, expected);
        text = set(&text, &back);
    }
}

#[test]
fn an_unchanged_background_records_nothing() {
    let text = r#"{"appearance": {"background": "daily"}}"#;
    let op = Op::Edit {
        edits: vec![Edit {
            target: Target::Key("appearance.background".to_string()),
            kind: EditKind::SetExact(json!("daily")),
        }],
        meta: user(),
    };
    let applied = apply(&state_with(text, ManagedPreferences::default()), op).unwrap();
    if let Some(written) = applied.write {
        assert_eq!(recents(&written), Value::Null, "{written}");
    }
}

#[test]
fn managed_recents_are_left_alone() {
    let mut managed = ManagedPreferences::default();
    managed.forced.insert(KEY.to_string(), json!([]));
    let op = Op::Set {
        target: Target::Key("appearance.background".to_string()),
        value: json!("daily"),
        meta: user(),
    };
    let written = apply(&state_with("{}", managed), op).unwrap().write.unwrap();
    assert_eq!(recents(&written), Value::Null, "{written}");
}

fn edit(state: &State, edits: Vec<Edit>) -> String {
    apply(state, Op::Edit { edits, meta: user() })
        .expect("the edit applies")
        .write
        .expect("the file changes")
}

fn set_edit(key: &str, value: Value) -> Edit {
    Edit { target: Target::Key(key.to_string()), kind: EditKind::Set(value) }
}

#[test]
fn a_background_from_below_the_file_is_the_one_recorded() {
    // Not the schema default: the recommended background was the one on screen.
    let mut managed = ManagedPreferences::default();
    managed.recommended.insert("appearance.background".to_string(), json!("daily"));
    let op = Op::Set {
        target: Target::Key("appearance.background".to_string()),
        value: json!("folder:/Users/me/Art"),
        meta: user(),
    };
    let written = apply(&state_with("{}", managed), op).unwrap().write.unwrap();
    assert_eq!(recents(&written), json!(["daily"]), "{written}");
}

#[test]
fn a_theme_background_is_the_one_recorded() {
    let file = r#"{"appearance":{"themeFile":"mine"}}"#;
    let (state, _) = state_with("{}", ManagedPreferences::default()).reload_with_theme(
        FileRead::Text(file.to_string()),
        ManagedPreferences::default(),
        |name| {
            Some(ThemeRead {
                name: name.to_string(),
                read: Some(Ok(r#"{"appearance.background": "daily"}"#.to_string())),
                folder: None,
            })
        },
    );
    // The app keeps a background picked over a theme as a theme file exception.
    let written = edit(
        &state,
        vec![
            set_edit("appearance.themeFileExceptions", json!(["appearance.background"])),
            set_edit("appearance.background", json!("folder:/Users/me/Art")),
        ],
    );
    assert_eq!(recents(&written), json!(["daily"]), "{written}");
}

#[test]
fn an_edit_batch_records_only_the_background_it_started_from() {
    let start = set("{}", "daily");
    let state = state_with(&start, ManagedPreferences::default());
    let written = edit(
        &state,
        vec![
            set_edit("appearance.background", json!("folder:/Users/me/Art")),
            set_edit("appearance.background", json!("folder:/Users/me/Photos")),
        ],
    );
    let list = recents(&written);
    assert_eq!(list.get(0), Some(&json!("daily")), "{written}");
    assert!(!list.as_array().unwrap().contains(&json!("folder:/Users/me/Art")), "{written}");
}
