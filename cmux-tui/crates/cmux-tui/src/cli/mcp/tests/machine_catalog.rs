use super::*;

const MACHINE: &str = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[test]
fn cmux_next_machine_catalog_agent_surface_list_preserves_owner_metadata() {
    let machine = json!({"id":MACHINE,"name":"Linux server","origin":"ssh","status":"running",
        "platform":{"os":"linux","arch":"aarch64"},"capabilities":["terminal"]});
    let fake = Fake { resource_result: Some(json!([machine])), ..Fake::default() };
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
        let mut arguments = object(json!({"machine":MACHINE}));
        arguments.insert(extra.into(), json!("value"));
        assert!(tool.plan(&arguments).is_err(), "{extra}");
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

#[cfg(unix)]
#[test]
fn cmux_next_machine_catalog_agent_surface_prefix_lookup_uses_one_connection_and_no_ancestors() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    let suffix =
        crate::cli::wire::random_request_id().unwrap().chars().take(16).collect::<String>();
    let path = std::env::temp_dir().join(format!("mc-{suffix}.sock"));
    let listener = UnixListener::bind(&path).unwrap();
    let worker = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(stream);
        let mut seen = Vec::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            let machine = json!({"id":MACHINE,"origin":"ssh","status":"running","platform":{"os":"linux","arch":"aarch64"}});
            let response = if request["cmd"] == "set-client-info" {
                json!({"id":request["id"],"ok":true,"data":{}})
            } else if request["cmd"] == "identify" {
                json!({"id":request["id"],"ok":true,"data":{"app":"cmux-tui","protocol":12,"capabilities":[]}})
            } else {
                let result =
                    if request["operation"] == "machine.list" { json!([machine]) } else { machine };
                seen.push(request.clone());
                json!({"protocol":"cmux.protocol/2","type":"response","id":request["id"],"ok":true,"result":result})
            };
            writeln!(reader.get_mut(), "{response}").unwrap();
        }
        seen
    });
    let tool = v2_tools::find("machine_get").unwrap();
    let plan = tool.plan(&object(json!({"machine":"machine_aaaa","catalog":true}))).unwrap();
    let global = GlobalArgs {
        socket: Some(path.clone()),
        session: Some("catalog-owner".into()),
        ..Default::default()
    };
    let result = transport::resource(&global, plan.plan, &plan.prefixes);
    let seen = worker.join().unwrap();
    std::fs::remove_file(path).unwrap();
    let result = result.unwrap();
    assert_eq!(result["id"], MACHINE);
    assert_eq!(result["platform"]["os"], "linux");
    assert_eq!(seen.len(), 2, "one lookup and one read on the accepted connection");
    assert_eq!(seen[0]["operation"], "machine.list");
    assert_eq!(seen[0]["params"], json!({"catalog":true}));
    assert_eq!(seen[1]["operation"], "machine.get");
    assert_eq!(seen[1]["params"], json!({"machine":MACHINE,"catalog":true}));
}

#[test]
fn cmux_next_machine_catalog_agent_surface_mcp_exposes_the_typed_reader_opt_in() {
    for (tool, args) in [
        ("machine_list", json!({"catalog":true})),
        ("machine_get", json!({"machine":MACHINE,"catalog":true})),
    ] {
        let tool = v2_tools::find(tool).unwrap();
        assert_eq!(tool.input_schema()["properties"]["catalog"]["type"], "boolean");
        let plan = tool.plan(&object(args)).unwrap();
        assert_eq!(plan.plan.params["catalog"], true);
        assert!(plan.plan.params.get("session").is_none());
        let mut bad = object(json!({"catalog":"true","machine":MACHINE}));
        if tool.operation == ResourceOperation::MachineList {
            bad.remove("machine");
        }
        // Field types are checked by the authoritative native catalog, not
        // duplicated in the MCP planner. Preserve malformed input for that refusal.
        assert_eq!(tool.plan(&bad).unwrap().plan.params["catalog"], "true");
    }
}
