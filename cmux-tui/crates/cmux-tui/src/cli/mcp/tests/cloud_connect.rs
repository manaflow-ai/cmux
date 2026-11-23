use super::super::cloud_connect_tools::{self as tools, words};
use super::*;
use serde_json::{Map, Value, json};

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn cloud_connection_tools_are_listed_and_never_take_a_secret() {
    let mut server = Server::new(Fake { fail_apps: true, ..Fake::default() }, None);
    let listed = server.list();
    for name in [tools::LIST, tools::CHATGPT, tools::CHATGPT_WAIT, tools::CHATGPT_CANCEL] {
        let tool =
            listed.iter().find(|tool| tool["name"] == name).unwrap_or_else(|| panic!("{name}"));
        let properties = tool["inputSchema"]["properties"].as_object().cloned().unwrap_or_default();
        for field in ["token", "key", "secret", "value", "api_key"] {
            assert!(!properties.contains_key(field), "{name} takes no {field}");
        }
    }
    // claude and api-key need a person at a terminal: no tool for them.
    assert!(!listed.iter().any(|tool| tool["name"] == "cloud_connect_claude"));
    assert!(!listed.iter().any(|tool| tool["name"] == "cloud_connect_api_key"));
}

#[test]
fn cloud_connection_tools_build_the_cli_words() {
    assert_eq!(words(tools::LIST, &args(json!({}))).unwrap().unwrap(), ["cloud", "connections"]);
    assert_eq!(
        words(tools::CHATGPT, &args(json!({"id": "work"}))).unwrap().unwrap(),
        ["cloud", "connect", "chatgpt", "--no-wait", "--id", "work"]
    );
    assert_eq!(
        words(tools::CHATGPT_WAIT, &args(json!({"attempt": "att-1"}))).unwrap().unwrap(),
        ["cloud", "connect", "chatgpt", "--wait", "att-1", "--keep", "--timeout", "60"]
    );
    assert_eq!(
        words(tools::CHATGPT_CANCEL, &args(json!({"attempt": "att-1"}))).unwrap().unwrap(),
        ["cloud", "connect", "chatgpt", "--cancel", "att-1"]
    );
    assert!(words("keys_list", &args(json!({}))).is_none());
}

#[test]
fn cloud_connection_tools_refuse_bad_arguments_without_running() {
    for (name, arguments) in [
        (tools::CHATGPT_WAIT, json!({})),
        (tools::CHATGPT_WAIT, json!({"attempt": "att-1", "timeout_seconds": 0})),
        (tools::CHATGPT_WAIT, json!({"attempt": "att-1", "timeout_seconds": 111})),
        (tools::CHATGPT_CANCEL, json!({"attempt": 7})),
        (tools::CHATGPT, json!({"id": "--wait"})),
    ] {
        assert!(words(name, &args(arguments.clone())).unwrap().is_err(), "{name} {arguments}");
        let result = tools::call(name, &args(arguments)).unwrap();
        assert_eq!(result["isError"], true, "{result}");
    }
}
