//! `settings explain`: each layer, the winner, the last write and near keys.

use std::path::Path;

use serde_json::{Value, json};

use crate::history::HistoryEntry;
use crate::managed::{ManagedPreferences, TeamPolicyLayer};
use crate::project::ProjectLayer;
use crate::schema::Schema;
use crate::store::{State, Target};
use crate::{Domains, FileRead};

fn state(user: &str, managed: ManagedPreferences, team: TeamPolicyLayer) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(user.to_string()),
        managed,
        team,
        Domains::default(),
        1,
    )
}

fn key(key: &str) -> Target {
    Target::Key(key.to_string())
}

fn layer<'a>(explained: &'a Value, name: &str) -> &'a Value {
    explained["layers"]
        .as_array()
        .and_then(|layers| layers.iter().find(|layer| layer["layer"] == name))
        .unwrap_or_else(|| panic!("no {name} layer in {explained}"))
}

fn entry(revision: u64, keys: &[&str], origin: &str) -> HistoryEntry {
    HistoryEntry {
        revision,
        at: 1_000 + revision,
        origin: origin.to_string(),
        keys: keys.iter().map(|key| key.to_string()).collect(),
        before: String::new(),
        undoes: None,
    }
}

#[test]
fn the_users_file_wins_over_defaults_and_names_its_last_write() {
    let state =
        state(r#"{"agents": {"promptCache": "5m"}}"#, Default::default(), Default::default());
    let history = [
        entry(2, &["agents.promptCache"], "cli"),
        entry(3, &["appearance.theme"], "user"),
        entry(4, &["agents"], "file"),
    ];
    let explained = state.explain(&key("agents.promptCache"), &history, None);
    assert_eq!(explained["value"], json!("5m"));
    assert_eq!(explained["winner"], json!("user"));
    assert_eq!(layer(&explained, "user")["wins"], json!(true));
    assert_eq!(layer(&explained, "mdm_forced")["set"], json!(false));
    // A write of a parent key counts; one of another key does not.
    assert_eq!(explained["changes"], json!(2));
    assert_eq!(explained["last_change"]["revision"], json!("4"));
    assert_eq!(explained["last_change"]["origin"], json!("file"));
    assert_eq!(explained["near"], json!([]));
}

#[test]
fn a_forced_value_beats_the_users_file_and_says_so() {
    let managed = ManagedPreferences {
        forced: [("agents.promptCache".to_string(), json!("1h"))].into(),
        ..Default::default()
    };
    let state = state(r#"{"agents": {"promptCache": "5m"}}"#, managed, Default::default());
    let explained = state.explain(&key("agents.promptCache"), &[], None);
    assert_eq!(explained["value"], json!("1h"));
    assert_eq!(explained["winner"], json!("mdm_forced"));
    assert_eq!(layer(&explained, "user")["value"], json!("5m"));
    assert_eq!(layer(&explained, "user")["wins"], json!(false));
    assert_eq!(explained["managed"]["key"], json!("agents.promptCache"));
    assert_eq!(explained["last_change"], Value::Null);
}

#[test]
fn a_team_default_fills_under_the_user_and_a_project_sits_over_it() {
    let team = TeamPolicyLayer {
        team_name: "Acme".to_string(),
        defaults: [("agents.promptCache".to_string(), json!("1h"))].into(),
        ..Default::default()
    };
    let state = state("{}", Default::default(), team);
    let explained = state.explain(&key("agents.promptCache"), &[], None);
    assert_eq!(explained["winner"], json!("team_default"));
    assert_eq!(layer(&explained, "team_default")["team"], json!("Acme"));

    let project = ProjectLayer::from_text(
        Path::new("/p"),
        r#"{"agents": {"promptCache": "5m"}}"#,
        Schema::embedded(),
    );
    let explained = state.explain(&key("agents.promptCache"), &[], Some(&project));
    assert_eq!(explained["winner"], json!("project"));
    assert_eq!(explained["value"], json!("5m"));
    assert_eq!(layer(&explained, "project")["folder"], json!("/p"));
}

#[test]
fn an_unset_row_falls_to_its_default() {
    let state = state("{}", Default::default(), Default::default());
    let row = Schema::embedded().rows.iter().find(|row| row.default.is_some()).unwrap();
    let explained = state.explain(&key(&row.key), &[], None);
    assert!(
        ["build_default", "product_default"].contains(&explained["winner"].as_str().unwrap()),
        "{explained}"
    );
    assert_eq!(layer(&explained, "product_default")["value"], row.default.clone().unwrap());
}

#[test]
fn a_misspelled_key_lists_the_nearest_keys() {
    let state = state("{}", Default::default(), Default::default());
    let explained = state.explain(&key("agents.promptCach"), &[], None);
    assert_eq!(explained["known"], json!(false));
    assert_eq!(explained["winner"], Value::Null);
    assert_eq!(explained["near"][0], json!("agents.promptCache"));
}
