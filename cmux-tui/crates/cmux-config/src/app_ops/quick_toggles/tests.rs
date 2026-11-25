//! Ports the schema half of `QuickToggleGroupsTests` (the click and the
//! managed lock go through the controller's guarded write and stay in
//! Swift's tests).

use serde_json::{Value, json};

use super::is_palette_listed;
use crate::app_ops::call;
use crate::schema::{Kind, Schema};

fn groups(developer_tools: bool) -> Vec<Value> {
    let reply =
        call("quick_toggles.groups", &json!({ "developer_tools": developer_tools })).unwrap();
    reply["groups"].as_array().unwrap().clone()
}

fn ids(group: &Value) -> Vec<String> {
    group["rows"].as_array().unwrap().iter().map(|id| id.as_str().unwrap().to_owned()).collect()
}

fn toggle(key: &str) -> bool {
    Schema::embedded().row(key).is_some_and(|row| matches!(row.kind, Kind::Toggle))
}

#[test]
fn experiments_then_labs_with_every_switch_in_schema_order() {
    let schema = Schema::embedded();
    let groups = groups(true);
    assert_eq!(groups.len(), 2);
    assert_eq!(
        groups[0]["title"],
        json!({ "key": "settings.group.experiments", "text": "Experiments" })
    );
    assert_eq!(groups[1]["title"], json!({ "key": "settings.group.labs", "text": "Labs" }));
    let experiments = ids(&groups[0]);
    let labs = ids(&groups[1]);
    let every_experiment: Vec<String> = schema
        .rows
        .iter()
        .filter(|row| row.path.first().map(String::as_str) == Some("experiments"))
        .filter(|row| matches!(row.kind, Kind::Toggle) && is_palette_listed(row, true))
        .map(|row| row.key.clone())
        .collect();
    assert_eq!(experiments, every_experiment);
    assert!(experiments.contains(&"experiments.agentBadges".to_owned()));
    assert!(labs.contains(&"labs.previewFeatures".to_owned()));
    assert!(labs.contains(&"customize.fromTheApp".to_owned()));
    for row in schema.rows.iter().filter(|row| row.path.first().map(String::as_str) == Some("labs"))
    {
        if matches!(row.kind, Kind::Toggle) && is_palette_listed(row, true) {
            assert!(labs.contains(&row.key), "{}", row.key);
        }
    }
    // Schema order, and nothing but on/off switches (the Voice Room address is text).
    let order = |key: &String| schema.rows.iter().position(|row| &row.key == key).unwrap();
    assert!(labs.windows(2).all(|pair| order(&pair[0]) < order(&pair[1])));
    assert!(experiments.windows(2).all(|pair| order(&pair[0]) < order(&pair[1])));
    assert!(!labs.contains(&"labs.voiceRoomURL".to_owned()));
    assert!(experiments.iter().chain(&labs).all(|key| toggle(key)));
    assert!(experiments.iter().all(|key| !labs.contains(key)));
}

#[test]
fn only_rows_the_palette_lists_in_this_build() {
    let schema = Schema::embedded();
    for developer_tools in [true, false] {
        for group in groups(developer_tools) {
            for key in ids(&group) {
                let row = schema.row(&key).unwrap();
                assert!(is_palette_listed(row, developer_tools), "{key}");
            }
        }
    }
}

/// Swift `isPaletteListed`: the palette surface offers it, and a
/// Development row only in a build with developer tools.
#[test]
fn a_development_row_is_listed_only_with_developer_tools() {
    let row = Schema::embedded().row("app.internalDeveloperMode").unwrap();
    assert_eq!(row.section, "development");
    assert!(is_palette_listed(row, true));
    assert!(!is_palette_listed(row, false));
    let listed = Schema::embedded().row("experiments.agentBadges").unwrap();
    assert!(is_palette_listed(listed, false));
}

/// A schema with no such switch has no group: an empty group is left out.
#[test]
fn an_empty_group_is_left_out() {
    let row = |key: &str, section: &str, offered: bool| {
        let path: Vec<&str> = key.split('.').collect();
        json!({
            "key": key, "path": path, "section": section, "kind": "toggle", "default": false,
            "group": { "key": "settings.group.labs", "text": "Labs" },
            "title": { "key": null, "text": key }, "summary": null, "help": null, "range": null,
            "default_label": null, "keywords": [], "agent_settable": true, "agent_refusal": null,
            "kept_on_reset_all": false, "validation": "portable", "accepts": [], "refuses": [],
            "surfaces": { "palette": { "offered": offered } },
        })
    };
    let document =
        |rows: Vec<Value>| json!({ "version": 1, "sections": [], "rows": rows }).to_string();
    let only_labs = Schema::parse(&document(vec![row("labs.one", "advanced", true)])).unwrap();
    let groups = super::groups(&only_labs, false);
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0]["rows"], json!(["labs.one"]));
    let none = Schema::parse(&document(vec![
        row("labs.hidden", "advanced", false),
        row("labs.dev", "development", true),
    ]))
    .unwrap();
    assert!(super::groups(&none, false).is_empty());
    assert_eq!(super::groups(&none, true)[0]["rows"], json!(["labs.dev"]));
}
