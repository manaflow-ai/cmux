use super::*;

const MACHINE: &str = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[test]
fn cmux_next_machine_catalog_agent_surface_list_preserves_owner_metadata() {
    let machine = json!({"id":MACHINE,"name":"Linux server","origin":"ssh","status":"running",
        "platform":{"os":"linux","arch":"aarch64"},"capabilities":["terminal"]});
    let fake = Fake { resource_result: Some(json!([machine.clone()])), ..Fake::default() };
    let mut server = Server::new(fake, None);
    let result = call(&mut server, "machine_list", json!({"limit":1}));
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["items"], json!([machine]));
    let sent = server.backend.sent.borrow();
    let request = &sent.last().unwrap()["request"];
    assert_eq!(request["operation"], "machine.list");
    assert_eq!(request["params"], json!({}));
    assert!(request.get("idempotency_key").is_none());
}

#[test]
fn cmux_next_machine_catalog_agent_surface_get_selects_metadata_without_routing() {
    let tool = v2_tools::find("machine_get").expect("catalog lookup tool");
    let schema = tool.input_schema();
    assert_eq!(schema["properties"]["machine"]["type"], "string");
    assert!(schema["required"].as_array().unwrap().contains(&json!("machine")));
    assert_eq!(tool.descriptor_json()["annotations"]["readOnlyHint"], true);
    let selected = tool.plan(&object(json!({"machine":MACHINE}))).unwrap();
    assert_eq!(selected.plan.params, json!({"machine":MACHINE}));
    assert!(selected.session.is_none() && selected.prefixes.is_empty());
    assert!(selected.plan.idempotency_key.is_none());
    let partial = tool.plan(&object(json!({"machine":"machine_abcd"}))).unwrap();
    assert_eq!(
        partial.prefixes,
        [Prefix { field: "machine".into(), list: ResourceOperation::MachineList }]
    );
    assert!(partial.session.is_none());
    assert!(
        tool.plan(&object(json!({}))).is_err(),
        "no implicit local lookup for a missing selection"
    );
    for extra in ["command", "socket", "endpoint", "expected_machine_id", "idempotency_key"] {
        assert!(tool.plan(&object(json!({"machine":MACHINE,extra:"value"}))).is_err(), "{extra}");
    }
}

#[test]
fn cmux_next_machine_catalog_agent_surface_never_admits_session_effects_or_other_machine_routes() {
    for name in [
        "session_list",
        "session_get",
        "session_open",
        "session_shutdown",
        "machine_catalog_publish",
    ] {
        assert!(v2_tools::find(name).is_none(), "{name}");
    }
    let workspace = v2_tools::find("workspace_get").unwrap();
    assert!(workspace.plan(&object(json!({"workspace":"current","machine":MACHINE}))).is_err());
}
