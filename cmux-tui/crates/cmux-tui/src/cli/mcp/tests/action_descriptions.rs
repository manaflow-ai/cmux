//! An action's own prose (`description` in `action.list`) heads its MCP tool
//! description; an action without one keeps the generic text.

use serde_json::{Value, json};

use super::from_list;

fn exec_action(description: Value) -> Value {
    json!({"actions": [{
        "id": "cloudExec", "title": "Run Command on Cloud Machine…", "cli_name": "cloud exec",
        "description": description, "targets": ["machine"], "requires": ["cloudWorkspace"],
        (crate::app_identity::ACTION_SURFACE_PLAN): {"cli": "offered", "mcp": "offered"},
        "arguments": [{"name": "command", "title": "Command", "kind": "string", "required": true}],
    }]})
}

fn tool_description(action: Value) -> String {
    let (tools, excluded) = from_list(&action);
    assert!(excluded.is_empty(), "{}", excluded.len());
    let [tool] = tools.as_slice() else { panic!("one tool") };
    let descriptor = tool.descriptor_json();
    assert_eq!(descriptor["description"].as_str(), Some(tool.description().as_str()));
    tool.description()
}

#[test]
fn an_actions_own_description_comes_first_and_the_generic_text_follows() {
    let own = "Runs a shell command on the machine and returns exit_code, stdout and stderr.";
    let text = tool_description(exec_action(json!(format!("  {own}  "))));
    assert!(text.starts_with(&format!("{own}\n\n")), "{text}");
    assert!(
        text.contains(
            "Run Command on Cloud Machine. cmux app action `cloudExec` (CLI: `cmux cloud exec`)."
        ),
        "{text}"
    );
    assert!(text.ends_with("Needs: cloudWorkspace."), "{text}");
}

#[test]
fn an_action_without_a_description_keeps_the_generic_text() {
    for missing in [Value::Null, json!(""), json!("   ")] {
        let text = tool_description(exec_action(missing));
        assert!(text.starts_with("Run Command on Cloud Machine. cmux app action"), "{text}");
    }
}
