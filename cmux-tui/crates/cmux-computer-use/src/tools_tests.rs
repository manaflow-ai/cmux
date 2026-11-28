use super::*;

#[test]
fn every_tool_has_an_object_schema_with_machine() {
    for t in TOOLS {
        let s = t.schema();
        assert_eq!(s["type"], "object", "{}", t.name);
        assert!(s["properties"]["machine"].is_object(), "{}", t.name);
        assert_eq!(
            s["properties"]["observe"].is_object(),
            OBSERVES.contains(&t.name),
            "{}",
            t.name
        );
    }
    let names: std::collections::HashSet<_> = TOOLS.iter().map(|t| t.name).collect();
    assert_eq!(names.len(), TOOLS.len(), "duplicate tool names");
}

/// An acting tool takes an optional `cursor_tag`; a look-only one does not.
#[test]
fn acting_tools_take_a_cursor_tag_and_it_is_kept_short_and_on_one_line() {
    for t in TOOLS {
        let s = t.schema();
        assert_eq!(s["properties"][CURSOR_TAG_ARG].is_object(), t.acts(), "{}", t.name);
        let required = s["required"].as_array().cloned().unwrap_or_default();
        assert!(!required.contains(&serde_json::json!(CURSOR_TAG_ARG)), "{}", t.name);
    }
    assert_eq!(safe_tag("Fix\nthe\tbuild").as_deref(), Some("Fix the build"));
    assert_eq!(safe_tag(" \u{7} "), None);
    assert_eq!(safe_tag(&"y".repeat(61)).map(|t| t.chars().count()), Some(60));
}

/// `record` is listed only where the desktop can encode H.264 (macOS);
/// every other tool is listed everywhere, and `find` reaches them all.
#[test]
fn record_is_listed_only_on_macos() {
    let list = mcp_list();
    let names: Vec<&str> =
        list["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(names.contains(&"record"), cfg!(target_os = "macos"), "{names:?}");
    assert_eq!(names.len(), TOOLS.iter().filter(|t| t.listed()).count());
    assert!(TOOLS.iter().filter(|t| t.name != "record").all(Tool::listed));
    assert!(find("record").is_some());
}

/// The batch schema names every step field an agent can use.
#[test]
fn the_batch_schema_lists_its_step_fields() {
    let s = find("batch").unwrap().schema();
    let step = &s["properties"]["actions"]["items"]["properties"];
    assert_eq!(s["properties"]["actions"]["maxItems"], crate::engine::BATCH_MAX);
    for key in
        ["action", "require", "target", "until", "value_equals", "value_contains", "timeout_ms"]
    {
        assert!(step[key].is_object(), "{key}");
    }
    let actions = step["action"]["enum"].as_array().unwrap();
    assert!(actions.contains(&json!("wait_for")));
    assert_eq!(step["require"]["enum"], json!(["confirmed", "not_no_effect", "no_error"]));
    assert_eq!(step["target"]["additionalProperties"], false);
}
