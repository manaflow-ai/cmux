use super::*;

#[test]
fn keys_tools_are_listed_and_take_a_name_never_a_value() {
    let mut server = Server::new(Fake { fail_apps: true, ..Fake::default() }, None);
    let tools = server.list();
    for name in ["keys_list", "keys_write", "keys_fill"] {
        let tool =
            tools.iter().find(|tool| tool["name"] == name).unwrap_or_else(|| panic!("{name}"));
        let properties = tool["inputSchema"]["properties"].as_object().unwrap();
        for field in ["value", "text", "secret"] {
            assert!(!properties.contains_key(field), "{name} takes no {field}");
        }
    }
}

#[test]
fn keys_fill_refuses_a_value_the_agent_passes_itself() {
    let mut server = Server::new(Fake { fail_apps: true, ..Fake::default() }, None);
    let result = call(
        &mut server,
        "keys_fill",
        json!({"name": "PAY_KEY", "target": "app", "tool": "type_text",
               "arguments": {"text": "sk_live_typed_by_the_agent"}}),
    );
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("this server adds the key"), "{result}");
    let result = call(&mut server, "keys_fill", json!({"name": "lower", "target": "browser"}));
    assert_eq!(result["isError"], true, "{result}");
}
