//! cmux Computer Use settings (Swift `ComputerUseSettings`): `computerUse.mode` is a `choice` of the
//! engine's five modes and `computerUse.deniedApps` a `string_list` of non-empty app matchers. The
//! daemon (the CLI's `settings validate|set`) must agree with Swift on both, refuse the retired
//! `computerUse.enabled` and `computerUse.driver` as removed, and the embedded schema must carry the
//! rows user-only (never agent-settable).

use cmux_config::Domains;
use cmux_config::schema::{Schema, accepts, retired_reason};
use serde_json::{Value, json};

const MODES: [&str; 5] = ["off", "lookOnly", "askEveryTime", "approvedApps", "fullAccess"];

fn text(value: &str) -> Value {
    json!({"text": value, "key": null})
}

fn schema() -> Schema {
    let group = text("Computer Use");
    let mode = json!({
        "key": "computerUse.mode", "path": ["computerUse", "mode"], "section": "general",
        "group": group, "title": text("Computer Use"), "kind": "choice",
        "choices": MODES.iter().map(|value| json!({"value": value, "title": text(value)})).collect::<Vec<_>>(),
        "default": "fullAccess", "keywords": [], "agent_settable": false, "kept_on_reset_all": false,
        "validation": "portable", "accepts": [], "refuses": [],
    });
    let denied = json!({
        "key": "computerUse.deniedApps", "path": ["computerUse", "deniedApps"], "section": "general",
        "group": group, "title": text("Denied Apps"), "kind": "string_list",
        "default": ["com.apple.Terminal", "com.1password.*"], "keywords": [], "agent_settable": false,
        "kept_on_reset_all": false, "validation": "portable", "accepts": [], "refuses": [],
    });
    let document = json!({"version": 1, "sections": [], "page": {"categories": []}, "rows": [mode, denied]});
    Schema::parse(&document.to_string()).expect("the Computer Use rows parse")
}

fn accepted(key: &str, value: Value) -> bool {
    let schema = schema();
    let row = schema.row(key).expect("row");
    accepts(row, &value, &Domains::default()).is_ok()
}

#[test]
fn every_engine_mode_is_accepted_and_nothing_else() {
    for mode in MODES {
        assert!(accepted("computerUse.mode", json!(mode)), "{mode}");
    }
    for value in [json!("unrestricted"), json!("full_access"), json!(true), json!(null), json!(["off"])] {
        assert!(!accepted("computerUse.mode", value.clone()), "{value}");
    }
}

#[test]
fn denied_apps_are_non_empty_matchers() {
    for value in [
        json!([]),
        json!(["com.apple.Terminal", "com.1password.*", "name:Notes"]),
    ] {
        assert!(accepted("computerUse.deniedApps", value.clone()), "{value}");
    }
    for value in [json!("com.apple.Terminal"), json!([""]), json!([1]), json!({})] {
        assert!(!accepted("computerUse.deniedApps", value.clone()), "{value}");
    }
}

#[test]
fn the_old_switch_and_driver_are_retired() {
    for key in ["enabled", "driver"] {
        let path = vec!["computerUse".to_string(), key.to_string()];
        let reason = retired_reason(&path).unwrap_or_else(|| panic!("computerUse.{key} is not retired"));
        assert!(!reason.is_empty());
    }
    assert!(retired_reason(&["computerUse".to_string(), "mode".to_string()]).is_none());
}

/// Once the export lists the new rows, none of them is agent-settable.
#[test]
fn no_computer_use_row_is_agent_settable() {
    for row in Schema::embedded().rows_in(None).filter(|row| row.key.starts_with("computerUse.")) {
        assert!(!row.agent_settable, "{} is agent-settable", row.key);
    }
}
