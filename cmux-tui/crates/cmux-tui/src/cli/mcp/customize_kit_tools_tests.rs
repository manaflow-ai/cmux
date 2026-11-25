use serde_json::{Map, Value, json};

use super::super::tool_list;
use super::{COMPONENTS, TOKENS, call};

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn both_tools_are_listed_read_only() {
    let tools = tool_list::first_party();
    for name in [COMPONENTS, TOKENS] {
        let tool = tools.iter().find(|t| t["name"] == name).unwrap_or_else(|| panic!("{name}"));
        assert_eq!(tool["annotations"]["readOnlyHint"], true, "{tool}");
    }
    let groups = tools
        .iter()
        .find(|t| t["name"] == TOKENS)
        .map(|t| t["inputSchema"]["properties"]["group"]["enum"].clone());
    assert_eq!(groups, Some(json!(cmux_customize::kit::TOKEN_GROUPS)));
}

#[test]
fn components_answers_one_component_with_an_example() {
    let answer = call(COMPONENTS, &args(json!({"name": "Pill"}))).expect("a kit tool");
    assert_eq!(answer["isError"], false, "{answer}");
    let pill = &answer["structuredContent"]["components"][0];
    assert_eq!(pill["name"], "Pill");
    assert!(pill["example"].as_str().unwrap_or_default().starts_with("<Pill"), "{pill}");
}

#[test]
fn tokens_answers_a_group() {
    let answer = call(TOKENS, &args(json!({"group": "radius"}))).expect("a kit tool");
    assert_eq!(answer["isError"], false, "{answer}");
    assert!(
        answer["structuredContent"]["radius"].as_array().is_some_and(|r| !r.is_empty()),
        "{answer}"
    );
    let all = call(TOKENS, &Map::new()).expect("a kit tool");
    assert_eq!(all["isError"], false, "{all}");
}

#[test]
fn bad_arguments_are_errors_and_other_tools_pass() {
    for (name, arguments) in [
        (COMPONENTS, json!({"name": "NoSuchThing"})),
        (COMPONENTS, json!({"name": 3})),
        (TOKENS, json!({"group": "nope"})),
    ] {
        let answer = call(name, &args(arguments.clone())).expect("a kit tool");
        assert_eq!(answer["isError"], true, "{name} {arguments}: {answer}");
    }
    // An argument a newer or older peer sends is ignored, not refused.
    let answer = call(COMPONENTS, &args(json!({"name": "Pill", "extra": 1}))).expect("a kit tool");
    assert_ne!(answer["isError"], true, "{answer}");
    assert!(call("customize_status", &Map::new()).is_none());
}
