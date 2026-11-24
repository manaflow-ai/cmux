//! `appearance.backgroundMemory` keeps what each background mode last showed,
//! so switching modes never loses Rotate's folder or Off's picture, even in a
//! new Settings page or after a restart (Leo, 2026-11-19: "switched around from
//! the rotating to day/night/whatever but it lost the folder ... i couldn't get
//! back into it"). It is a settings key, so it lives in the settings file on
//! disk; the owner checks its shape, and no theme file carries it.

use cmux_config::Domains;
use cmux_config::schema::{Kind, Schema, accepts};
use cmux_config::theme_file::is_look;
use serde_json::{Value, json};

const KEY: &str = "appearance.backgroundMemory";

fn accepted(value: Value) -> bool {
    let schema = Schema::embedded();
    let row = schema.row(KEY).expect("appearance.backgroundMemory is a row");
    accepts(row, &value, &Domains::default()).is_ok()
}

#[test]
fn the_memory_is_a_stored_setting_with_no_default() {
    let schema = Schema::embedded();
    let row = schema.row(KEY).expect("appearance.backgroundMemory is a row");
    assert_eq!(row.kind, Kind::StringMap);
    assert_eq!(row.default, None, "unset means nothing remembered");
    assert!(row.agent_settable, "settable like the other background keys");
    assert!(!is_look(row), "a theme file never carries what a mode last showed");
}

#[test]
fn the_memory_accepts_each_modes_last_value() {
    assert!(accepted(json!({})));
    assert!(accepted(json!({
        "rotate": "folder:/Users/me/Art",
        "folder": "folder:/Users/me/Art",
        "off": "file:/Users/me/Pictures/Harbor.png",
    })));
    assert!(accepted(
        json!({ "rotate": "daily", "folder": "folder:/Users/me/Art", "off": "none" })
    ));
    assert!(accepted(json!({ "off": "munch-scream" })));
    assert!(accepted(json!({ "off": "system:/System/Library/Desktop Pictures/Sonoma.heic" })));
}

#[test]
fn the_memory_refuses_values_no_mode_shows() {
    for value in [
        json!("folder:/Users/me/Art"),
        json!([]),
        json!({ "rotate": "munch-scream" }),
        json!({ "rotate": "appearance" }),
        json!({ "folder": "daily" }),
        json!({ "folder": "folder:/" }),
        json!({ "folder": "folder:relative" }),
        json!({ "off": "daily" }),
        json!({ "off": "schedule" }),
        json!({ "off": "folder:/Users/me/Art" }),
        json!({ "off": "__not_a_backdrop__" }),
        json!({ "light": "munch-scream" }),
        json!({ "rotate": 1 }),
    ] {
        assert!(!accepted(value.clone()), "{value} is refused");
    }
}
