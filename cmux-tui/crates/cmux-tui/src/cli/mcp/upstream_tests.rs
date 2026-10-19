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
            {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object"}}]}
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
    server.upstreams = vec![upstream_server("cmux-cua")];
    // The other server's tools are in the list under its prefix, and the
    // index carries its own instructions.
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(listed["result"]["tools"][0]["description"].as_str().unwrap().contains("cua (2)"));
    let index = call(&mut server, "cmux_docs", json!({}));
    assert_eq!(index["structuredContent"]["families"]["cua"], json!(["cua_look", "cua_fail"]));
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
    .map(upstream::Upstream::new)
    .collect();
    let listed =
        broken.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(!listed["result"]["tools"][0]["description"].as_str().unwrap().contains("secrets"));
    let ran = call(&mut broken, "cmux_exec", json!({"script": "return 1;"}));
    assert_eq!(ran["structuredContent"]["result"], 1);
}
