//! `cmux mcp serve` with the chat's other MCP servers behind it
//! (`upstream.rs`), against a real child server process.

use super::*;

/// A stdio MCP server like acpmux's computer use, secret and offer servers:
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
    let dir = std::env::temp_dir().join(format!("cmux-mcp-upstream-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("server.py");
    std::fs::write(&script, UPSTREAM_SERVER).unwrap();
    let specs = upstream::specs(Some(
        json!([{"name": name, "command": "python3", "args": [script], "env": {}}])
            .to_string()
            .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap())
}

#[test]
fn code_mode_runs_the_chats_other_servers_behind_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    // The other server's tools are in the list under its prefix, and the
    // index carries its own instructions.
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(listed["result"]["tools"][0]["description"].as_str().unwrap().contains("cua (3)"));
    // Listed directly (every tool), each carries its server's rules.
    let all = server.list();
    let look = all.iter().find(|t| t["name"] == "cua_look").expect("cua_look is listed");
    assert!(look["description"].as_str().unwrap().contains("Ask before you click."), "{look}");
    let index = call(&mut server, "cmux_docs", json!({}));
    assert_eq!(
        index["structuredContent"]["families"]["cua"],
        json!(["cua_look", "cua_fail", "cua_hold"])
    );
    assert_eq!(index["structuredContent"]["servers"]["cmux-cua"], "Ask before you click.");
    // A search that finds its tools carries the rules too; one that does not, none.
    let found = call(&mut server, "cmux_docs", json!({"query": "look screen"}));
    assert_eq!(found["structuredContent"]["tools"][0]["name"], "cua_look", "{found}");
    assert_eq!(found["structuredContent"]["servers"]["cmux-cua"], "Ask before you click.");
    let other = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    assert!(other["structuredContent"].get("servers").is_none(), "{other}");

    // A script calls it like any tool; the screenshot comes back as an image
    // block of the cmux_exec result, the script sees its index.
    let script = r#"
        const seen = await cmux.cua_look({x: 1});
        let failed;
        try { await cmux.cua_fail({}); } catch (e) { failed = e.message; }
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
    let refused = call(&mut server, "cmux_exec", json!({"script": "await cmux.cua_look({});"}));
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
/// text listed only cua_*, secrets_* and sessions_*, so an agent looked for
/// sub-session tools under the offer server's prefix.
#[test]
fn code_mode_instructions_name_every_folded_servers_prefix() {
    let text = code_mode::INSTRUCTIONS;
    for server in [
        acpmux::cua_v2::SERVER_NAME,
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
        "decide, say why",
        "never widens",
        "product taste",
    ] {
        assert!(rule.contains(phrase), "{phrase}: {rule}");
    }
    for code_mode in [false, true] {
        let init = initialize(&json!({}), false, code_mode);
        let text = init["instructions"].as_str().unwrap();
        assert!(text.ends_with(rule), "code mode {code_mode}: {text}");
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
