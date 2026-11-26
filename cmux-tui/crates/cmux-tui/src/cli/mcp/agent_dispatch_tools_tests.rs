use super::*;

#[test]
fn descriptors_are_harness_agnostic_and_do_not_offer_shell_or_paths() {
    let tools = descriptors();
    assert_eq!(tools.len(), 4);
    for tool in &tools {
        let text = tool["description"].as_str().unwrap();
        assert!(!text.contains("scp"), "{text}");
        assert!(!text.contains("ssh"), "{text}");
        assert!(!text.contains("remote path"), "{text}");
        assert_eq!(tool["inputSchema"]["additionalProperties"], false);
    }
    let dispatch = find(DISPATCH).unwrap();
    assert_eq!(dispatch.input_schema()["properties"]["harness"]["type"], "string");
    assert!(dispatch.input_schema()["properties"].get("cwd").is_none());
    assert!(
        dispatch.input_schema()["properties"]["target"]["description"]
            .as_str()
            .unwrap()
            .contains("auto")
    );
}

#[test]
fn dispatch_params_keep_non_claude_harness_names_and_wire_camel_case() {
    let tool = find(DISPATCH).unwrap();
    let args = serde_json::from_value::<Map<String, Value>>(json!({
        "title": "Qwen task",
        "brief": "Inspect the fixture and report the result.",
        "target": "auto",
        "harness": "qwen",
        "stop_condition": "Report findings",
        "idempotency_key": "dispatch-qwen-1"
    }))
    .unwrap();
    let params = tool.params(&args).unwrap();
    assert_eq!(params["model"], "qwen");
    assert_eq!(params["stopCondition"], "Report findings");
    assert_eq!(params["idempotencyKey"], "dispatch-qwen-1");
    assert_eq!(params["target"], "auto");

    let args = serde_json::from_value::<Map<String, Value>>(json!({
        "title": "DeepSeek task",
        "brief": "Inspect the fixture and report the result.",
        "target": "auto",
        "harness": "opencode",
        "model": "deepseek",
    }))
    .unwrap();
    assert_eq!(tool.params(&args).unwrap()["model"], "opencode/deepseek");

    let generated = serde_json::from_value::<Map<String, Value>>(json!({
        "title": "Generated key",
        "brief": "Retry this safely.",
        "target": "auto",
    }))
    .unwrap();
    assert!(
        tool.params(&generated).unwrap()["idempotencyKey"]
            .as_str()
            .is_some_and(|key| key.starts_with("mutation_"))
    );
}

#[test]
fn list_rejects_unknown_fields_and_out_of_range_limits() {
    let tool = find(BRIEFS_LIST).unwrap();
    let bad = serde_json::from_value::<Map<String, Value>>(json!({"limit": 0})).unwrap();
    assert!(tool.params(&bad).is_err());
    let unknown = serde_json::from_value::<Map<String, Value>>(json!({"shell": "ssh"})).unwrap();
    assert!(tool.params(&unknown).is_err());
    assert!(tool.params(&Map::new()).unwrap().get("idempotencyKey").is_none());
}
