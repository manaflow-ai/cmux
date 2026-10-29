use super::*;

#[test]
fn settings_tools_are_discoverable_without_the_app() {
    let mut server = Server::new(Fake { fail_apps: true, ..Fake::default() }, None);
    let tools = server.list();
    for name in
        ["settings_list", "settings_get", "settings_set", "settings_reset", "settings_unset"]
    {
        assert_eq!(tools.iter().filter(|tool| tool["name"] == name).count(), 1, "{name}");
    }
}

#[test]
fn settings_reads_hide_raw_configuration_and_unknown_rows() {
    let mut server = Server::new(
        Fake {
            resource_result: Some(json!([
                {"key": "mcp.enabled", "value": true, "secret": "raw-secret"},
                {"key": "appearance.theme", "value": "dark", "file_value": "raw-secret",
                 "default": "raw-secret", "extra": "raw-secret", "customized": true}
            ])),
            ..Fake::default()
        },
        None,
    );
    let result = call(&mut server, "settings_list", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    assert!(!result.to_string().contains("raw-secret"));
    assert!(!result.to_string().contains("mcp.enabled"));
    assert_eq!(result["structuredContent"]["items"][0]["key"], "appearance.theme");
}

#[test]
fn settings_get_returns_effective_value_without_raw_file_value() {
    let mut server = Server::new(
        Fake {
            resource_result: Some(json!({"key": "appearance.theme", "value": "dark",
                "file_value": {"token": "raw-secret"}, "row": {"secret": "raw-secret"}})),
            ..Fake::default()
        },
        None,
    );
    let result = call(&mut server, "settings_get", json!({"key": "appearance.theme"}));
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["value"], "dark");
    assert!(!result.to_string().contains("raw-secret"));
}

#[test]
fn settings_tools_refuse_raw_paths_and_policy_overrides_without_sending() {
    let mut server = Server::new(Fake::default(), None);
    for (name, arguments) in [
        ("settings_get", json!({"key": "mcp.enabled"})),
        ("settings_get", json!({"path": ["appearance"]})),
        ("settings_set", json!({"key": "appearance.theme", "value": "dark", "origin": "user"})),
        ("settings_reset", json!({"key": "appearance.theme", "confirm": true})),
        ("settings_set", json!({"key": "browser.remoteLocalhost", "value": true})),
        ("settings_reset", json!({"key": "browser.remoteLocalhost"})),
    ] {
        let result = call(&mut server, name, arguments);
        assert_eq!(result["isError"], true, "{name}: {result}");
    }
    assert!(server.backend.sent.borrow().iter().all(|sent| sent["kind"] != "resource"));
}

#[test]
fn settings_mutations_force_mcp_origin_and_keep_idempotency() {
    let mut server = Server::new(Fake::default(), None);
    for (name, operation, arguments) in [
        (
            "settings_set",
            "settings.set",
            json!({"key": "appearance.theme", "value": "dark", "idempotency_key": "set-1"}),
        ),
        (
            "settings_reset",
            "settings.reset",
            json!({"key": "appearance.theme", "idempotency_key": "reset-1"}),
        ),
        (
            "settings_unset",
            "settings.reset",
            json!({"key": "appearance.theme", "idempotency_key": "unset-1"}),
        ),
    ] {
        let key = arguments["idempotency_key"].clone();
        let result = call(&mut server, name, arguments);
        assert_eq!(result["isError"], false, "{result}");
        let sent = server.backend.sent.borrow();
        let request = &sent.last().unwrap()["request"];
        assert_eq!(request["operation"], operation);
        assert_eq!(request["params"]["origin"], "mcp");
        assert_eq!(request["params"]["key"], "appearance.theme");
        assert_eq!(request["idempotency_key"], key);
    }
}

#[test]
fn settings_owner_refusals_and_retry_keys_are_preserved() {
    for code in
        ["settings.managed", "settings.invalid", "settings.agent_refused", "revision.conflict"]
    {
        let error = json!({"code": code, "message": "owner refused", "details": {"key": "appearance.theme"}, "retryable": false});
        let mut server =
            Server::new(Fake { resource_error: Some(error.clone()), ..Fake::default() }, None);
        let result = call(
            &mut server,
            "settings_set",
            json!({"key": "appearance.theme", "value": "dark", "idempotency_key": "write-1"}),
        );
        assert_eq!(result["isError"], true);
        assert_eq!(result["structuredContent"]["error"], error);
        assert_eq!(result["structuredContent"]["state"], "rejected");
        assert_eq!(result["structuredContent"]["idempotency_key"], "write-1");
    }
}

#[test]
fn settings_list_is_sorted_and_pages_after_filtering_raw_rows() {
    let mut server = Server::new(
        Fake {
            resource_result: Some(json!([
                {"key": "terminal.fontSize", "value": 14},
                {"key": "private.token", "value": "secret"},
                {"key": "appearance.theme", "value": "dark"}
            ])),
            ..Fake::default()
        },
        None,
    );
    let result = call(&mut server, "settings_list", json!({"offset": 1, "limit": 1}));
    assert_eq!(result["structuredContent"]["items"][0]["key"], "terminal.fontSize");
    assert_eq!(result["structuredContent"]["total"], 2);
    assert_eq!(result["structuredContent"]["next_offset"], Value::Null);
}

#[test]
fn settings_get_redacts_invalid_effective_values() {
    let mut server = Server::new(
        Fake {
            resource_result: Some(
                json!({"key": "terminal.fontSize", "value": {"token": "secret"}}),
            ),
            ..Fake::default()
        },
        None,
    );
    let result = call(&mut server, "settings_get", json!({"key": "terminal.fontSize"}));
    assert_eq!(result["structuredContent"]["value"], Value::Null);
    assert_eq!(result["structuredContent"]["value_redacted"], true);
    assert!(!result.to_string().contains("secret"));
}
