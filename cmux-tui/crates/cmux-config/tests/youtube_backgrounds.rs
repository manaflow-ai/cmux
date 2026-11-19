//! YouTube wallpapers in the settings file: every background row takes a
//! canonical `youtube:` id, and a pasted YouTube address is stored as that
//! id by every write (`settings.set`, `settings.edit`), whoever writes.

use cmux_config::domains::Domains;
use cmux_config::schema::accepts;
use cmux_config::value::nest;
use cmux_config::{
    Edit, EditKind, FileRead, ManagedPreferences, Op, Origin, Refusal, Schema, State, Target,
    TeamPolicyLayer, WriteMeta, apply,
};
use serde_json::{Value, json};

const ID: &str = "youtube:dQw4w9WgXcQ?start=90";
const PASTED: &str = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s";

fn state(text: &str) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        1,
    )
}

fn user() -> WriteMeta {
    WriteMeta { origin: Origin::User, ..WriteMeta::default() }
}

fn set(key: &str, value: Value) -> Result<Value, Refusal> {
    let op = Op::Set { target: Target::Key(key.into()), value, meta: user() };
    let applied = apply(&state("{}"), op)?;
    let written = applied.write.expect("a write");
    Ok(serde_json::from_str(&written).expect("JSON"))
}

#[test]
fn every_background_row_accepts_a_canonical_youtube_id() {
    let schema = Schema::embedded();
    let domains = Domains::default();
    for key in ["appearance.background", "appearance.backgroundLight", "appearance.backgroundDark"]
    {
        let row = schema.row(key).expect(key);
        for id in ["youtube:dQw4w9WgXcQ", ID, "youtube:dQw4w9WgXcQ?start=10&end=20&quality=720"] {
            assert!(accepts(row, &json!(id), &domains).is_ok(), "{key} takes {id}");
        }
        for bad in [
            "youtube:dQw4w9WgXcQ?start=0",
            "youtube:dQw4w9WgXcQ?end=20&start=10",
            "youtube:tooShort",
            PASTED,
        ] {
            let Err(Refusal::InvalidValue { accepted, .. }) = accepts(row, &json!(bad), &domains)
            else {
                panic!("{key} refuses {bad}");
            };
            let accepted = accepted.to_json().to_string();
            assert!(accepted.contains("youtube:<video id>"), "{key}: {accepted}");
        }
    }
    let schedule = schema.row("appearance.backgroundSchedule").expect("schedule");
    assert!(accepts(schedule, &json!({"07:00": ID, "sunset": "desktop"}), &domains).is_ok());
}

#[test]
fn the_editor_json_schema_takes_a_canonical_id_and_refuses_a_pasted_address() {
    let validator =
        jsonschema::validator_for(&Schema::embedded().json_schema()).expect("schema compiles");
    for key in ["appearance.background", "appearance.backgroundLight"] {
        let path: Vec<String> = key.split('.').map(str::to_owned).collect();
        assert!(validator.is_valid(&nest(json!(ID), &path)), "{key}");
        assert!(!validator.is_valid(&nest(json!(PASTED), &path)), "{key}");
        assert!(!validator.is_valid(&nest(json!("youtube:dQw4w9WgXcQ?start=0"), &path)), "{key}");
    }
}

#[test]
fn a_pasted_address_is_stored_as_its_youtube_id() {
    let file = set("appearance.background", json!(PASTED)).expect("written");
    assert_eq!(file.pointer("/appearance/background"), Some(&json!(ID)));
    let file =
        set("appearance.backgroundDark", json!("https://youtu.be/dQw4w9WgXcQ")).expect("dark");
    assert_eq!(file.pointer("/appearance/backgroundDark"), Some(&json!("youtube:dQw4w9WgXcQ")));
    let file = set("appearance.backgroundSchedule", json!({"07:00": PASTED, "sunset": "desktop"}))
        .expect("schedule");
    assert_eq!(
        file.pointer("/appearance/backgroundSchedule"),
        Some(&json!({"07:00": ID, "sunset": "desktop"}))
    );
    // A `youtube:` id in another order is written canonically.
    let file = set("appearance.background", json!("youtube:dQw4w9WgXcQ?quality=1080&t=90"))
        .expect("written");
    assert_eq!(file.pointer("/appearance/background"), Some(&json!(ID)));
}

#[test]
fn settings_edit_normalizes_each_edit() {
    let edits = vec![
        Edit {
            target: Target::Key("appearance.backgroundLight".into()),
            kind: EditKind::Set(json!(PASTED)),
        },
        Edit {
            target: Target::Key("appearance.background".into()),
            kind: EditKind::Set(json!("appearance")),
        },
    ];
    let applied = apply(&state("{}"), Op::Edit { edits, meta: user() }).expect("applies");
    let file: Value = serde_json::from_str(&applied.write.expect("a write")).expect("JSON");
    assert_eq!(file.pointer("/appearance/backgroundLight"), Some(&json!(ID)));
    assert_eq!(file.pointer("/appearance/background"), Some(&json!("appearance")));
}

#[test]
fn a_youtube_address_that_is_no_video_is_refused_and_other_values_stay_as_typed() {
    for bad in [
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/@channel",
        "https://vimeo.com/123",
    ] {
        assert!(set("appearance.background", json!(bad)).is_err(), "{bad}");
    }
    let file = set("appearance.background", json!("file:/Users/Shared/Rain.mov")).expect("file");
    assert_eq!(file.pointer("/appearance/background"), Some(&json!("file:/Users/Shared/Rain.mov")));
}
