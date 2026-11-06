//! `cmux mcp serve` with the chat's other MCP servers behind it
//! (`upstream.rs`), against a real child server process.

use super::*;

/// A stdio MCP server like acpmux's secret and offer servers:
/// `look` answers text and a screenshot, `fail` answers an error.
const UPSTREAM_SERVER: &str = r#"
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, rid = m["method"], m["id"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake"}, "instructions": "Ask before you click."}
    elif method == "tools/list":
        result = {"tools": [
            {"name": "look", "description": "Look at the screen", "inputSchema": {"type": "object"}},
            {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object"}},
            {"name": "hold", "description": "Waits for a file", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call" and m["params"]["name"] == "hold":
        import os, time
        while not os.path.exists(m["params"]["arguments"]["path"]):
            time.sleep(0.02)
        result = {"content": [{"type": "text", "text": "held"}]}
    elif method == "tools/call" and m["params"]["name"] == "look":
        result = {"content": [{"type": "text", "text": "saw " + json.dumps(m["params"]["arguments"])},
                              {"type": "image", "data": "aW1n", "mimeType": "image/png"}]}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "the window is gone"}], "isError": True}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
"#;

fn upstream_server(name: &str) -> upstream::Upstream {
    // Written once per process: a stored list keys the script by its modification
    // time, and tests run in parallel, so two writing it at once made a stored list
    // miss in one of them (a_stored_list_answers_…: 1 run in 3 on rbx, 2026-10-30).
    static SCRIPT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    let script = SCRIPT.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("cmux-mcp-upstream-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("server.py");
        std::fs::write(&script, UPSTREAM_SERVER).unwrap();
        script
    });
    let specs = upstream::specs(Some(
        json!([{"name": name, "command": "python3", "args": [script], "env": {}}])
            .to_string()
            .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}

#[test]
fn code_mode_runs_the_chats_other_servers_behind_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-probe"))];
    // The other server's tools are in the list under its prefix, and the
    // index carries its own instructions.
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(listed["result"]["tools"][0]["description"].as_str().unwrap().contains("probe (3)"));
    // Listed directly (every tool), each carries its server's rules.
    let all = server.list();
    let look = all.iter().find(|t| t["name"] == "probe_look").expect("probe_look is listed");
    assert!(look["description"].as_str().unwrap().contains("Ask before you click."), "{look}");
    let index = call(&mut server, "cmux_docs", json!({}));
    assert_eq!(
        index["structuredContent"]["families"]["probe"],
        json!(["probe_look", "probe_fail", "probe_hold"])
    );
    // The server's own instructions.
    let rules = "Ask before you click.";
    assert_eq!(index["structuredContent"]["servers"]["cmux-probe"], rules);
    // A search that finds its tools carries the rules too; one that does not, none.
    let found = call(&mut server, "cmux_docs", json!({"query": "look screen"}));
    assert_eq!(found["structuredContent"]["tools"][0]["name"], "probe_look", "{found}");
    assert_eq!(found["structuredContent"]["servers"]["cmux-probe"], rules);
    let other = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    assert!(other["structuredContent"].get("servers").is_none(), "{other}");
    // Search matches what a tool does, not the rules its server shares with every tool (they
    // name terminals and passwords).
    let rules_only = call(&mut server, "cmux_docs", json!({"query": "terminal password"}));
    let content = &rules_only["structuredContent"];
    let names =
        content["tools"].as_array().into_iter().flatten().filter_map(|tool| tool["name"].as_str());
    let more = content["more"].as_array().into_iter().flatten().filter_map(Value::as_str);
    assert!(!names.chain(more).any(|name| name.starts_with("probe_")), "{rules_only}");

    // A script calls it like any tool; the screenshot comes back as an image
    // block of the cmux_exec result, the script sees its index.
    let script = r#"
        const seen = await cmux.probe_look({x: 1});
        let failed;
        try { await cmux.probe_fail({}); } catch (e) { failed = e.message; }
        return {seen, failed};
    "#;
    let ran = call(&mut server, "cmux_exec", json!({"script": script}));
    assert_eq!(ran["isError"], false, "{ran}");
    let result = &ran["structuredContent"]["result"];
    assert_eq!(result["seen"]["content"][0]["text"], "saw {\"x\": 1}", "{ran}");
    assert_eq!(
        result["seen"]["content"][1],
        json!({"type": "image", "image": 0, "mimeType": "image/png"})
    );
    assert!(result["failed"].as_str().unwrap().contains("the window is gone"), "{ran}");
    let content = ran["content"].as_array().unwrap();
    assert_eq!(
        content.last().unwrap(),
        &json!({"type": "image", "data": "aW1n", "mimeType": "image/png"})
    );

    // The allowlist covers them too (fail closed).
    server.allowed = allowed_tools(Some("cmux_exec".into()));
    let refused = call(&mut server, "cmux_exec", json!({"script": "await cmux.probe_look({});"}));
    assert_eq!(
        refused["structuredContent"]["error"]["cmux"]["error"]["code"], "tool.not_allowed",
        "{refused}"
    );

    // A server that cannot start leaves its tools out; the rest still works.
    let mut broken = code_mode_server(Fake::with_actions());
    broken.upstreams = upstream::specs(Some(
        json!([{"name": "cmux-secrets", "command": "/nonexistent/server", "args": [], "env": {}}])
            .to_string()
            .into(),
    ))
    .into_iter()
    .map(|spec| upstream::Proxied::new(upstream::Upstream::new(spec)))
    .collect();
    let listed =
        broken.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(!listed["result"]["tools"][0]["description"].as_str().unwrap().contains("secrets"));
    let ran = call(&mut broken, "cmux_exec", json!({"script": "return 1;"}));
    assert_eq!(ran["structuredContent"]["result"], 1);
}

/// A proxied call that waits (a secret card the person has not answered)
/// holds only its own server: the other tools answer meanwhile.
#[test]
fn a_waiting_proxied_call_never_holds_up_the_other_tools() {
    let mut server = code_mode_server(Fake::with_actions());
    server.code_mode = false;
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-secrets"))];
    let release = std::env::temp_dir().join(format!("cmux-mcp-hold-{}", std::process::id()));
    let _ = std::fs::remove_file(&release);
    let input = format!(
        "{}\n{}\n",
        json!({"jsonrpc": "2.0", "id": "held", "method": "tools/call",
               "params": {"name": "secrets_hold", "arguments": {"path": release}}}),
        json!({"jsonrpc": "2.0", "id": "quick", "method": "tools/call",
               "params": {"name": "window_list", "arguments": {}}}),
    );
    let buffer = SharedBuffer::default();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    // stdin ended with the quick answer written; the held one still waits.
    let ids = |text: String| -> Vec<String> {
        text.lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v["id"].as_str().map(str::to_owned))
            .collect()
    };
    assert_eq!(ids(buffer.text()), ["quick"], "{}", buffer.text());
    std::fs::write(&release, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while ids(buffer.text()).len() < 2 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert_eq!(ids(buffer.text()), ["quick", "held"], "{}", buffer.text());
    let _ = std::fs::remove_file(&release);
}

/// The code-mode instructions name every server acpmux folds behind `cmux`
/// by its tool prefix, and say a folded call's in_progress has no key: the
/// text listed only cu_*, secrets_* and sessions_*, so an agent looked for
/// sub-session tools under the offer server's prefix.
#[test]
fn code_mode_instructions_name_every_folded_servers_prefix() {
    let text = code_mode::INSTRUCTIONS;
    assert!(text.contains(&format!("{}_*", acpmux::computer_use::tools::TOOL_PREFIX)), "{text}");
    for server in [
        acpmux::secret_mcp::SERVER_NAME,
        acpmux::offer_mcp::SERVER_NAME,
        acpmux::subsession_mcp::SERVER_NAME,
        acpmux::forum_mcp::SERVER_NAME,
    ] {
        let prefix = server.strip_prefix("cmux-").unwrap_or(server);
        assert!(text.contains(&format!("{prefix}_*")), "{server}: {text}");
    }
    assert!(text.contains("has no key and may have run"), "{text}");
}

/// Both modes' instructions end with the rule on asking the person (Leo 2026-10-21: an agent in
/// Full access asked a question that read "Waiting for you: allow this?"; decide, say why,
/// continue), and the bundled acpmux skill says the same.
#[test]
fn instructions_in_both_modes_tell_the_agent_never_to_ask_for_permission() {
    let rule = acpmux::agent_tools::ASKING_RULE;
    for phrase in [
        "Full access",
        "never ask them to allow",
        "Decide, say why",
        "never widens",
        "product taste",
    ] {
        assert!(rule.contains(phrase), "{phrase}: {rule}");
    }
    for (code_mode, wrap_up, offers) in [
        (false, false, false),
        (true, false, false),
        (true, true, false),
        (true, false, true),
        (true, true, true),
    ] {
        let init = initialize(&json!({}), false, code_mode, wrap_up, offers);
        let text = init["instructions"].as_str().unwrap();
        assert!(text.contains(rule), "code mode {code_mode}: {text}");
        // The next-step box's line comes after the rule, only where acpmux is folded in, and the
        // suggested-session line only where cmux-sessions is.
        assert_eq!(text.contains(code_mode::WRAP_UP_INSTRUCTION), wrap_up, "{text}");
        assert_eq!(text.ends_with(code_mode::OFFER_INSTRUCTION), offers, "{text}");
        // Claude Code may cut server instructions past 2048 characters, which would drop the rule.
        assert!(
            text.chars().count() <= 2048,
            "code mode {code_mode}: {} chars",
            text.chars().count()
        );
    }
    let skill = include_str!("../../../../acpmux/skills/acpmux/SKILL.md").replace('\n', " ");
    for phrase in [
        "Full access",
        "Never ask the user to allow",
        "decide, say",
        "never widens",
        "product taste",
    ] {
        assert!(skill.contains(phrase), "acpmux skill lacks {phrase}");
    }
}

/// A chat asked to "open Calculator" found no computer use in its one tool
/// and drove the app with osascript keystrokes, which macOS blocked
/// (2026-10-27). `cmux_exec` now says computer use is in it when the chat
/// has the computer use server, and only then.
#[test]
fn cmux_exec_says_it_includes_computer_use_only_when_the_chat_has_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(computer_use_server())];
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let with = listed["result"]["tools"][0]["description"].as_str().unwrap().to_owned();
    for phrase in [
        "cmux Computer Use, built into cmux",
        "nothing to install",
        "prefer it over any other computer-use driver",
        "cu_*",
        "other machines",
        "never osascript",
        "Never type into a terminal or script tool",
        "never copy app data out",
    ] {
        assert!(with.contains(phrase), "{phrase}: {with}");
    }

    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-secrets"))];
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let without = listed["result"]["tools"][0]["description"].as_str().unwrap();
    assert!(!without.contains("Computer Use"), "no computer use server: {without}");
}

/// The Computer Use server as acpmux folds it, with a command that cannot
/// start: listing must never need it.
fn computer_use_server() -> upstream::Upstream {
    let specs = upstream::specs(Some(
        json!([{"name": acpmux::computer_use::tools::SERVER_NAME,
                "command": "/nonexistent/acpmux", "args": ["computer-use-mcp"], "env": {}}])
        .to_string()
        .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}

/// The Computer Use tools fold as `cu_*` from the catalog compiled into this
/// binary, with the server's instructions on each, without starting the
/// bridge: the list is stable whether or not anything runs.
#[test]
fn computer_use_folds_as_cu_from_the_compiled_catalog() {
    let mut cu = computer_use_server();
    let listed = cu.descriptors(&BTreeSet::new());
    assert!(!cu.started(), "listing Computer Use starts nothing");
    let names: Vec<&str> = listed.iter().filter_map(|t| t["name"].as_str()).collect();
    let catalog = acpmux::computer_use::tools::mcp_list();
    let want: Vec<String> = catalog["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| format!("cu_{}", t["name"].as_str().unwrap()))
        .collect();
    assert_eq!(names, want);
    for name in ["cu_screenshot", "cu_click", "cu_list_machines", "cu_status"] {
        assert!(names.contains(&name), "{name}: {names:?}");
    }
    let text = listed[0]["description"].as_str().unwrap();
    assert!(text.ends_with(acpmux::computer_use::tools::INSTRUCTIONS), "{text}");
    // A call that cannot reach the bridge says so, as not run, and is retryable.
    let mut server = code_mode_server(Fake::with_actions());
    server.code_mode = false;
    server.upstreams = vec![upstream::Proxied::new(computer_use_server())];
    let result = call(&mut server, "cu_status", json!({}));
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("not_run"), "{result}");
}

/// A chat's `cmux` server lists another server's tools from the list an
/// earlier start stored, and starts that server only on its first call: an
/// idle chat never runs its other servers (2026-10-29: one helper per chat).
#[test]
fn a_stored_list_answers_without_starting_the_server_until_a_call() {
    let dir = tempfile::tempdir().unwrap();
    let mut first = upstream_server("cmux-probe").with_listings(Some(dir.path().into()));
    let listed = first.descriptors(&BTreeSet::new());
    assert!(first.started(), "with nothing stored, listing starts the server");
    assert_eq!(listed.len(), 3);
    drop(first);
    let mut second = upstream_server("cmux-probe").with_listings(Some(dir.path().into()));
    assert_eq!(second.descriptors(&BTreeSet::new()), listed, "the stored list, rules included");
    assert!(!second.started(), "a stored list starts nothing");
    let result = second.call("look", json!({"at": 1}), None).unwrap();
    assert!(second.started(), "the first call starts it");
    assert_eq!(result["content"][0]["text"], "saw {\"at\": 1}");
}

/// A tool the stored list has but the started server no longer lists is
/// refused before it is sent, as not run.
#[test]
fn a_stored_tool_the_server_dropped_is_not_sent() {
    let dir = tempfile::tempdir().unwrap();
    let mut first = upstream_server("cmux-secrets").with_listings(Some(dir.path().into()));
    first.descriptors(&BTreeSet::new());
    drop(first);
    // Add a tool to the stored list that the server does not have.
    for entry in std::fs::read_dir(dir.path()).unwrap().filter_map(Result::ok) {
        let mut stored: Value =
            serde_json::from_slice(&std::fs::read(entry.path()).unwrap()).unwrap();
        stored["tools"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "gone", "inputSchema": {"type": "object"}}));
        std::fs::write(entry.path(), stored.to_string()).unwrap();
    }
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(
        upstream_server("cmux-secrets").with_listings(Some(dir.path().into())),
    )];
    let job = server.proxied_tool("secrets_gone", &Map::new()).expect("the stored list has it");
    let result = job.run(None);
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("no longer lists"), "{result}");
}
