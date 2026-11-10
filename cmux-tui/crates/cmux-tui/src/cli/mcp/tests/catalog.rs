use super::*;

#[test]
fn every_catalog_operation_is_a_tool_or_excluded_with_a_reason() {
    let catalog: Value =
        serde_json::from_str(v2_tools::CATALOG_JSON).expect("the checked-in catalog");
    let operations = catalog["operations"].as_object().expect("operations");
    let tools = v2_tools::tools().iter().map(|tool| tool.wire).collect::<BTreeSet<_>>();
    let excluded = v2_tools::exclusions()
        .into_iter()
        .map(|exclusion| (exclusion.name, exclusion.reason))
        .collect::<BTreeMap<_, _>>();
    for name in operations.keys() {
        assert!(
            tools.contains(name.as_str()) != excluded.contains_key(name),
            "{name} must be exactly one of a tool or an exclusion"
        );
    }
    assert_eq!(tools.len() + excluded.len(), operations.len());
    assert!(excluded.values().all(|reason| reason.len() > 10), "every exclusion has a reason");
    for tool in v2_tools::tools() {
        assert!(matches!(tool.operation.class(), OperationClass::Read | OperationClass::Mutation));
        assert_eq!(tool.mutation, tool.operation.class() == OperationClass::Mutation);
    }
    for (name, _) in v2_tools::EXCLUDED {
        assert!(operations.contains_key(*name), "stale exclusion {name}");
    }
}

#[test]
fn every_tool_is_reachable_from_the_cmux_cli_and_no_excluded_operation_is() {
    let cases = crate::cli::command::cases::safe_operation_cases();
    let sends = |args: &[&str]| match crate::cli::parse(&strings(args), crate::cli::Surface::Cmux) {
        Ok(ParsedCommand::Command { plan: CommandPlan::Protocol(request), .. }) => {
            request.operation.name().ok()
        }
        _ => None,
    };
    for tool in v2_tools::tools() {
        if crate::cli::command::cases::MULTI_REQUEST_OPERATIONS.contains(&tool.wire) {
            continue;
        }
        let (args, _) = cases
            .iter()
            .find(|(_, operation)| *operation == tool.wire)
            .unwrap_or_else(|| panic!("the CLI has no command for {}", tool.wire));
        assert_eq!(
            sends(args.as_slice()).as_deref(),
            Some(tool.wire),
            "`cmux {}` must send {}",
            args.join(" "),
            tool.wire
        );
    }
    for (wire, _) in v2_tools::EXCLUDED {
        // `agent.report` is reserved by the dispatch MCP adapter even though the
        // CLI keeps its resource-operation case for direct command coverage.
        if *wire == "agent.report" {
            continue;
        }
        if let Some((args, _)) = cases.iter().find(|(_, operation)| operation == wire) {
            // The `session` and `client` scopes are on `cmux` too since #38290, and their
            // operations stay off MCP (v2_tools.rs, SESSION_REASON and its siblings).
            if matches!(args.first(), Some(&"session" | &"client")) {
                continue;
            }
            assert_eq!(
                sends(args.as_slice()),
                None,
                "`cmux {}` offers excluded {wire}",
                args.join(" ")
            );
        }
    }
}

#[test]
fn tool_schemas_follow_the_catalog() {
    let name_ok = |name: &str| {
        !name.is_empty()
            && name.len() <= 64
            && name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    };
    for tool in v2_tools::tools() {
        assert!(name_ok(&tool.name), "{}", tool.name);
        let schema = tool.input_schema();
        let properties = schema["properties"].as_object().expect("properties");
        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(
            properties.contains_key("machine"),
            // workspace_list's `machine` picks a Cloud machine's workspaces (cloud_workspaces.rs).
            matches!(
                tool.operation,
                ResourceOperation::MachineGet | ResourceOperation::WorkspaceList
            ),
            "{}",
            tool.name
        );
        // `git.checkpoint.get` looks a create up by the key it ran under.
        let lookup = tool.wire == "git.checkpoint.get";
        let keyed = properties.contains_key("idempotency_key");
        assert_eq!(keyed, tool.mutation || lookup, "{}", tool.name);
        assert_eq!(properties.contains_key("offset"), tool.paginated, "{}", tool.name);
        for required in schema["required"].as_array().unwrap() {
            assert!(properties.contains_key(required.as_str().unwrap()), "{}", tool.name);
        }
        let annotations = &tool.descriptor_json()["annotations"];
        assert_eq!(annotations["readOnlyHint"], !tool.mutation);
        assert_eq!(annotations["openWorldHint"], tool.wire == "git.push", "{}", tool.name);
    }
    let create = v2_tools::find("workspace_create").expect("workspace_create").input_schema();
    assert_eq!(create["properties"]["initial_content"]["enum"], json!(["terminal", "empty"]));
    // The wire requires it; an MCP call may leave it out for a terminal, as the CLI.
    assert!(!create["required"].as_array().unwrap().contains(&json!("initial_content")));
    assert_eq!(create["properties"]["initial_content"]["default"], "terminal");
    assert_eq!(create["properties"]["ephemeral"]["type"], "boolean");
    assert!(v2_tools::find("workspace_list").unwrap().paginated);
    assert!(!v2_tools::find("notification_list").unwrap().paginated, "owner's own limit");
}

#[test]
fn ids_take_a_unique_prefix_and_a_session_qualifier() {
    let tool = v2_tools::find("workspace_get").expect("workspace_get");
    let call = tool.plan(&object(json!({"workspace": "build-box:ws_1a2b"}))).expect("plan");
    assert_eq!(call.session.as_deref(), Some("build-box"));
    // The daemon's one selector resolver expands a selector's prefix (W5-P).
    assert_eq!(call.plan.params["workspace"], "ws_1a2b");
    assert!(call.prefixes.is_empty());
    assert_eq!(call.plan.params["machine"], "current");
    assert_eq!(call.plan.params["session"], "current");

    for whole in [WORKSPACE, "current", "name:ws_1", "workspace:ws_1a"] {
        let call = tool.plan(&object(json!({"workspace": whole}))).expect("plan");
        assert!(call.prefixes.is_empty(), "{whole}");
        assert_eq!(call.session, None, "{whole}");
        assert_eq!(call.plan.params["workspace"], whole);
    }
    let two = tool.plan(&object(json!({"workspace": "a:ws_1", "session": "b"})));
    assert!(two.is_err(), "one call reaches one session");
    assert!(tool.plan(&object(json!({"bogus": "x"}))).is_err());
}

/// A workspace, screen, pane, tab, terminal or browser id prefix in a
/// selector goes to the daemon as given: the daemon's one selector resolver
/// (W5-P) expands it with the rules of every other client (at least 4 hex
/// digits, every candidate when two match). A resource-id field the daemon
/// reads as a whole id is still looked up first, but a prefix of fewer than
/// 4 hex digits is refused here with the daemon's own hint, not guessed.
#[test]
fn w5p_a_selector_prefix_goes_to_the_daemons_resolver() {
    let tool = v2_tools::find("workspace_get").expect("workspace_get");
    for (given, sent) in
        [("ws_1a2b", "ws_1a2b"), ("ws_1a", "ws_1a"), ("build-box:ws_1a2b", "ws_1a2b")]
    {
        let call = tool.plan(&object(json!({"workspace": given}))).expect("plan");
        assert!(call.prefixes.is_empty(), "{given}: {:?}", call.prefixes);
        assert_eq!(call.plan.params["workspace"], sent, "{given}");
    }

    let list = v2_tools::find("agent_list").expect("agent_list");
    let call = list.plan(&object(json!({"terminal_id": "term_c1a0"}))).expect("plan");
    assert_eq!(
        call.prefixes,
        [Prefix { field: "terminal_id".into(), list: ResourceOperation::TerminalList }]
    );
    let short = list.plan(&object(json!({"terminal_id": "term_c1"}))).err().expect("refused");
    assert_eq!(short["code"], "validation.invalid");
    assert!(
        short["message"].as_str().is_some_and(|message| message.contains("at least 4 hex digits")),
        "{short}"
    );
}
