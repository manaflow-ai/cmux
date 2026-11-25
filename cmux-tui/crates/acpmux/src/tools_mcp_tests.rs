use super::*;

fn server(name: &'static str) -> Served {
    Served {
        name,
        session: "s".into(),
        tools: json!([]),
        instructions: None,
        call: boxed(|_, _| async { json!({}) }),
        on_initialize: None,
        list: None,
        handle: None,
    }
}

#[test]
fn a_request_names_its_server_and_the_call_keeps_the_rest_of_its_meta() {
    let servers = [server("cmux-forum"), server("acpmux")];
    let mut params =
        json!({"name": "ls", "_meta": {SERVER_META: "acpmux", "claudecode/toolUseId": "t1"}});
    assert_eq!(pick(&servers, &mut params).unwrap().name, "acpmux");
    assert_eq!(params, json!({"name": "ls", "_meta": {"claudecode/toolUseId": "t1"}}));
    // Only the selector in `_meta`: the call sees no `_meta`, as before.
    let mut params = json!({"name": "rules", "_meta": {SERVER_META: "cmux-forum"}});
    assert_eq!(pick(&servers, &mut params).unwrap().name, "cmux-forum");
    assert_eq!(params, json!({"name": "rules"}));
    // Several servers and none named, or one it does not serve: refused, never guessed.
    assert!(pick(&servers, &mut json!({"name": "ls"})).is_err());
    assert!(pick(&servers, &mut json!({"_meta": {SERVER_META: "cmux-secrets"}})).is_err());
    // A process of one server needs no name.
    let one = [server("cmux-forum")];
    assert_eq!(pick(&one, &mut json!({})).unwrap().name, "cmux-forum");
}

/// A server whose instructions are already in the harness's system prompt gives none at
/// `initialize`; otherwise it gives exactly what that prompt would carry (`instructions_of`).
#[test]
fn a_server_leaves_out_instructions_already_in_the_system_prompt() {
    let env = |flag: bool| {
        let mut env: std::collections::HashMap<String, String> = [
            crate::offer_mcp::SESSION_ENV,
            crate::subsession_mcp::SESSION_ENV,
            crate::acpmux_mcp_names::SESSION_ENV,
        ]
        .into_iter()
        .map(|k| (k.to_owned(), "s".to_owned()))
        .collect();
        if flag {
            env.insert(INSTRUCTIONS_IN_PROMPT_ENV.to_owned(), "1".to_owned());
        }
        env
    };
    let makers: [fn(&Arc<Daemon>) -> Result<Served>; 2] =
        [crate::offer_mcp::served, crate::subsession_mcp::served];
    for make in makers {
        let given = crate::tool_env::sync_scope(env(false), || {
            let served = make(&Arc::default()).unwrap();
            (served.instructions, instructions_of(served.name))
        });
        assert!(given.0.is_some());
        assert_eq!(given.0, given.1);
        let left_out = crate::tool_env::sync_scope(env(true), || make(&Arc::default()).unwrap());
        assert_eq!(left_out.instructions, None, "{}", left_out.name);
    }
    // The acpmux server's follow its tool allowlist: none without the tools they name.
    let only_send = std::collections::HashMap::from([(
        crate::agent_tools::MCP_TOOLS_ENV.to_owned(),
        "acpmux_send".to_owned(),
    )]);
    let name = crate::acpmux_mcp_names::SERVER_NAME;
    assert_eq!(crate::tool_env::sync_scope(only_send, || instructions_of(name)), None);
    let all = crate::tool_env::sync_scope(Default::default(), || instructions_of(name));
    assert!(all.is_some_and(|t| t.contains("bg_start")));
}

#[test]
fn it_owns_only_acpmux_s_own_server_commands() {
    let args = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
    assert!(owns("cmux-forum", &args(&["forum-mcp"])));
    assert!(owns("acpmux", &args(&["acp", "acpmux-mcp"])));
    assert!(!owns("cmux-forum", &args(&["acpmux-mcp"])));
    assert!(!owns("cmux-repo", &args(&["repo-mcp"])));
    assert!(owns("cmux-cloud-repos", &args(&["repo-mcp"])));
    assert!(owns("cmux-hosted", &args(&["acp", "hosted-mcp"])));
    assert!(!owns("cmux-cua", &args(&["cua-mcp"])));
    assert!(owns("cmux-computer-use", &args(&["computer-use-mcp"])));
}
