//! `sidebar.sections.hidden` and `sidebar.sections.order` are settings rows
//! whose values are the lists the sidebar planner (cmux-layout-reducer
//! `sidebar_section_customization`) reads with no problem: at most 256
//! distinct ids of 1 to 128 characters. Before they were rows, `cmux settings`,
//! MCP and a customize profile refused both keys as unknown (hq RFD 0008 G16).

use cmux_config::Domains;
use cmux_config::schema::{Schema, accepts};
use serde_json::{Value, json};

const KEYS: [&str; 2] = ["sidebar.sections.hidden", "sidebar.sections.order"];

fn accepted(key: &str, value: &Value) -> bool {
    let schema = Schema::embedded();
    let row = schema.row(key).unwrap_or_else(|| panic!("{key} is a row"));
    accepts(row, value, &Domains::default()).is_ok()
}

#[test]
fn section_lists_are_agent_settable_rows_that_default_to_empty() {
    let schema = Schema::embedded();
    for key in KEYS {
        let row = schema.row(key).unwrap_or_else(|| panic!("{key} is a row"));
        assert!(row.agent_settable, "{key}: a look sets it, so an agent may");
        assert_eq!(row.path, ["sidebar", "sections", key.rsplit('.').next().unwrap()]);
    }
}

#[test]
fn section_lists_accept_distinct_ids() {
    let longest = "s".repeat(128);
    let most: Vec<String> = (0..256).map(|index| format!("section-{index}")).collect();
    for key in KEYS {
        for value in [
            json!([]),
            json!(["recents"]),
            json!(["projects", "pinned"]),
            json!([longest]),
            json!(most),
        ] {
            assert!(accepted(key, &value), "{key} takes {value}");
        }
    }
}

#[test]
fn section_lists_refuse_what_the_planner_drops() {
    let too_long = "s".repeat(129);
    let too_many: Vec<String> = (0..257).map(|index| format!("section-{index}")).collect();
    for key in KEYS {
        for value in [
            json!("recents"),
            json!([""]),
            json!(["pinned", "pinned"]),
            json!([1]),
            json!([too_long]),
            json!(too_many),
            json!({ "hidden": ["recents"] }),
            Value::Null,
        ] {
            assert!(!accepted(key, &value), "{key} refuses {value}");
        }
    }
}
