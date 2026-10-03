//! Helpers shared by the integration tests.
#![allow(dead_code)]

use cmux_config::schema::{Kind, Row};
use cmux_config::value::value_at;
use cmux_config::{
    Domains, FileRead, ManagedPreferences, Op, Origin, Schema, State, Target, TeamPolicyLayer,
    WriteMeta, jsonc,
};
use serde_json::{Value, json};

pub fn state(source: &str, managed: ManagedPreferences) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(source.to_string()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

pub fn forced(entries: &[(&str, Value)]) -> ManagedPreferences {
    ManagedPreferences {
        forced: entries.iter().map(|(k, v)| (k.to_string(), v.clone())).collect(),
        ..Default::default()
    }
}

pub fn meta(origin: Origin, key: Option<&str>, if_revision: Option<u64>) -> WriteMeta {
    WriteMeta { origin, idempotency_key: key.map(str::to_string), if_revision }
}

pub fn set(key: &str, value: Value) -> Op {
    Op::Set { target: Target::Key(key.to_string()), value, meta: WriteMeta::default() }
}

pub fn set_with(key: &str, value: Value, meta: WriteMeta) -> Op {
    Op::Set { target: Target::Key(key.to_string()), value, meta }
}

pub fn reset(key: &str) -> Op {
    Op::Reset { target: Target::Key(key.to_string()), meta: WriteMeta::default() }
}

pub fn reset_all() -> Op {
    Op::ResetAll { meta: WriteMeta::default() }
}

/// The value at `path` in the state's file text.
pub fn file_value(state: &State, path: &[String]) -> Option<Value> {
    value_at(&jsonc::parse(state.source()).expect("file parses"), path).cloned()
}

pub fn path(dotted: &str) -> Vec<String> {
    cmux_config::keypath::key_path(dotted)
}

/// A value `accepts` takes: the default when there is one, else one that
/// fits the kind (Swift `SettingDescriptor.sampleValue`).
pub fn sample_value(row: &Row) -> Value {
    if let Some(default) = &row.default
        && cmux_config::schema::accepts(row, default, &Domains::default()).is_ok()
    {
        return default.clone();
    }
    match &row.kind {
        Kind::Choice(choices) => {
            json!(choices.first().map(|c| c.value.clone()).unwrap_or_default())
        }
        Kind::ChoiceOrNumber(choices, range) => {
            choices.first().map_or(json!(range.min), |c| json!(c.value))
        }
        Kind::Toggle => json!(false),
        Kind::Number(range) => cmux_config::value::number_value(range.min),
        Kind::Color => json!("#336699"),
        Kind::Sound => json!("default"),
        Kind::Url => json!(""),
        Kind::HostList => json!([]),
        Kind::TimeRange => json!({"start": "22:00", "end": "07:00"}),
        Kind::Theme => json!("Dracula"),
        Kind::FontFamily => json!("Menlo"),
    }
}
