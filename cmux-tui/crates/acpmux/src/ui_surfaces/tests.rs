use super::*;

/// The flag is process-wide: tests that read or set it take turns.
static FLAG_LOCK: Mutex<()> = Mutex::new(());

fn on() -> std::sync::MutexGuard<'static, ()> {
    let g = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_enabled_for_test(true);
    g
}

fn messages() -> Value {
    json!([
        {"version": "1.0", "createSurface": {"surfaceId": "s1", "components": [
            {"id": "root", "component": "Column", "children": ["t", "b"]},
            {"id": "t", "component": "Text", "text": "Ship it?"},
            {"id": "bl", "component": "Text", "text": "Yes"},
            {"id": "b", "component": "Button", "child": "bl", "action": {"event": {"name": "yes"}}}
        ]}}
    ])
}

fn update(call: &str, status: &str, input: Value) -> Value {
    json!({"sessionUpdate": if status == "pending" { "tool_call" } else { "tool_call_update" },
           "toolCallId": call, "status": status, "title": "mcp__cmux__ui_surface",
           "_meta": {"claude": {"toolName": "mcp__cmux__ui_surface"}}, "rawInput": input})
}

fn meta() -> (String, PathBuf) {
    ("claude".into(), PathBuf::from("/tmp"))
}

/// A host that logs nothing and runs no fetch.
fn host() -> Host {
    Host { late: tokio::sync::mpsc::unbounded_channel().0, spawn: std::sync::Arc::new(|_| {}) }
}

#[test]
fn names() {
    for n in [
        "mcp__cmux__ui_surface",
        "cmux.ui_surface",
        "cmux/ui_surface",
        "ui_surface",
        "ui_surface (cmux)",
    ] {
        assert!(is_ui_surface_tool(n), "{n}");
    }
    assert!(!is_ui_surface_tool("mcp__cmux__render"));
    assert_eq!(
        mcp_parts("mcp__quickstart__get-time"),
        Some(("quickstart".into(), "get-time".into()))
    );
    assert_eq!(mcp_parts("mcp__cmux__ui_surface"), None);
}

#[test]
fn a_ui_surface_call_carries_its_surface_in_the_logged_update() {
    let _g = on();
    let mut u = update("call-a", "pending", json!({"messages": messages(), "title": "Ship"}));
    assert!(annotate("sess-a", &mut u, meta, host));
    let s = &u["_meta"]["acpmux"]["uiSurface"];
    assert_eq!(s["schema"], "cmux.ui-surface/1");
    assert_eq!(s["status"], "streaming");
    assert_eq!(s["title"], "Ship");
    // A second update within the same frame may be held; the last one always carries.
    let mut u2 = update("call-a", "in_progress", json!({"messages": messages()}));
    annotate("sess-a", &mut u2, meta, host);
    let mut done = update("call-a", "completed", json!({"messages": messages()}));
    assert!(annotate("sess-a", &mut done, meta, host));
    assert_eq!(done["_meta"]["acpmux"]["uiSurface"]["status"], "ready");

    // The page's button press: a Pending, nothing sent; confirm makes the prompt text.
    let p = action("sess-a", &json!({"surfaceId": "s1", "actionId": "b", "values": {}})).unwrap();
    assert_eq!(p["summary"], "Send \"yes\" to the agent (no values)");
    let Confirmed::Prompt(text) = confirm("sess-a", &json!({"requestId": p["requestId"]})).unwrap()
    else {
        panic!("not a prompt")
    };
    assert!(text.contains("\"name\": \"yes\""), "{text}");
    assert!(
        confirm("sess-a", &json!({"requestId": p["requestId"]})).is_err(),
        "one confirm, one send"
    );
}

#[test]
fn other_tools_are_untouched() {
    let _g = on();
    let mut u = json!({"sessionUpdate": "tool_call", "toolCallId": "x", "title": "Read", "rawInput": {"path": "/a"}});
    let before = u.clone();
    assert!(!annotate("sess-b", &mut u, meta, host));
    assert_eq!(u, before);
}

#[test]
fn an_a2ui_resource_in_a_tool_result_draws() {
    let _g = on();
    let text = serde_json::to_string(&messages()).unwrap();
    let mut u = json!({"sessionUpdate": "tool_call_update", "toolCallId": "r1", "status": "completed",
        "title": "mcp__recipes__show",
        "content": [{"type": "content", "content": {"type": "resource", "resource": {"uri": "a2ui://r", "mimeType": "application/a2ui+json", "text": text}}}]});
    assert!(annotate("sess-c", &mut u, meta, host));
    assert_eq!(u["_meta"]["acpmux"]["uiSurface"]["source"]["server"], "recipes");
}

#[test]
fn flag_off_builds_nothing() {
    let _g = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_enabled_for_test(false);
    let mut u = update("call-off", "completed", json!({"messages": messages()}));
    assert!(!annotate("sess-off", &mut u, meta, host));
    assert!(u["_meta"].get("acpmux").is_none());
    assert!(action("sess-off", &json!({"surfaceId": "s1", "actionId": "b"})).is_err());
    set_enabled_for_test(true);
}

#[test]
fn http_servers_only_and_sse_answers() {
    assert!(mcp_http::server_conf(&json!({"command": "npx", "args": []})).is_none());
    assert!(mcp_http::server_conf(&json!({"type": "stdio", "url": "https://x"})).is_none());
    assert!(
        mcp_http::server_conf(&json!({"type": "http", "url": "http://evil.example/mcp"})).is_none()
    );
    let c = mcp_http::server_conf(
        &json!({"type": "http", "url": "http://localhost:3001/mcp", "headers": {"x-k": "v"}}),
    )
    .unwrap();
    assert_eq!(c.headers, vec![("x-k".to_string(), "v".to_string())]);
    let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n\n";
    let v = mcp_http::parse_body(body, true, Some(&json!(2))).unwrap();
    assert_eq!(v["result"]["tools"], json!([]));
}

#[tokio::test]
#[allow(
    clippy::await_holding_lock,
    reason = "the flag lock serializes the process-wide flag across tests; only this test's task holds it, and no task it awaits takes it"
)]
async fn bridge_refuses_before_initialized_and_answers_the_view() {
    let _g = on();
    with_session("sess-d", |s| {
        let source =
            Source { kind: SourceKind::McpApp, server: Some("q".into()), ..Default::default() };
        s.store
            .put_frame("app-1", source, "<p>x</p>".into(), mcp_apps::csp(None), Vec::new())
            .unwrap();
    });
    let msg = |m: &str, p: Value| json!({"sessionId": "sess-d", "surfaceId": "app-1", "message": {"jsonrpc": "2.0", "id": 7, "method": m, "params": p}});
    let r = bridge("sess-d", &msg("tools/call", json!({"name": "x"}))).await.unwrap();
    assert!(r["blocked"].is_string());
    assert_eq!(r["reply"]["id"], 7);
    assert!(r["reply"]["error"].is_object());
    let r = bridge("sess-d", &msg("ui/initialize", json!({}))).await.unwrap();
    assert_eq!(r["reply"]["result"]["hostInfo"]["name"], "cmux");
    let r = bridge("sess-d", &msg("ui/notifications/size-changed", json!({"height": 5})))
        .await
        .unwrap();
    assert_eq!(r["height"], 40);
    let r = bridge("sess-d", &msg("sampling/createMessage", json!({}))).await.unwrap();
    assert!(r["blocked"].is_string());
}

/// A streamable-HTTP MCP server shaped like ext-apps `examples/quickstart`: one tool, `get-time`,
/// whose `_meta.ui.resourceUri` names an HTML view. Its `tools/list` answer waits for `gate`, so
/// the call's result reaches the tap before the fetch ends. Answers in SSE, as the SDK does.
async fn quickstart_server(gate: std::sync::Arc<tokio::sync::Notify>) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://127.0.0.1:{}/mcp", listener.local_addr().unwrap().port());
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let gate = gate.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                let (head_end, len) = loop {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(at) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..at]).to_ascii_lowercase();
                        let len = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .and_then(|v| v.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        break (at + 4, len);
                    }
                };
                while buf.len() < head_end + len {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                let req: Value = serde_json::from_slice(&buf[head_end..head_end + len]).unwrap();
                let method = req["method"].as_str().unwrap_or("");
                let result = match method {
                    "initialize" => {
                        json!({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}, "resources": {}}, "serverInfo": {"name": "Quickstart MCP App Server", "version": "1.0.0"}})
                    }
                    "tools/list" => {
                        gate.notified().await;
                        json!({"tools": [{"name": "get-time", "description": "Returns the current server time.", "inputSchema": {"type": "object"}, "_meta": {"ui": {"resourceUri": "ui://get-time/mcp-app.html"}}}]})
                    }
                    "resources/read" => {
                        json!({"contents": [{"uri": "ui://get-time/mcp-app.html", "mimeType": "text/html;profile=mcp-app", "text": "<!doctype html><p id=\"server-time\">get-time view</p>"}]})
                    }
                    _ => Value::Null,
                };
                let (ctype, body) = if req.get("id").is_none() {
                    ("application/json", String::new())
                } else {
                    let answer = json!({"jsonrpc": "2.0", "id": req["id"], "result": result});
                    ("text/event-stream", format!("event: message\ndata: {answer}\n\n"))
                };
                let status = if body.is_empty() { "202 Accepted" } else { "200 OK" };
                let resp = format!(
                    "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\nmcp-session-id: s-1\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = sock.write_all(resp.as_bytes()).await;
            });
        }
    });
    url
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(
    clippy::await_holding_lock,
    reason = "the flag lock serializes the process-wide flag across tests; only this test's task holds it, and no task it awaits takes it"
)]
async fn an_mcp_app_draws_on_its_first_call_when_its_view_comes_after_the_result() {
    let _g = on();
    let gate = std::sync::Arc::new(tokio::sync::Notify::new());
    let url = quickstart_server(gate.clone()).await;
    mcp_http::TEST_CONF
        .lock()
        .unwrap()
        .push(("quickstart-late".into(), mcp_http::ServerConf { url, headers: Vec::new() }));
    let (late, mut sent) = tokio::sync::mpsc::unbounded_channel::<Value>();
    let host =
        move || Host { late: late.clone(), spawn: std::sync::Arc::new(|f| drop(tokio::spawn(f))) };
    let name = "mcp__quickstart-late__get-time";
    let mut start = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "status": "pending",
        "title": name, "kind": "other", "rawInput": {}, "_meta": {"claude": {"toolName": name, "tool": name}}});
    assert!(!annotate("sess-late", &mut start, meta, host.clone()), "not fetched yet");
    let mut done = json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
        "content": [{"type": "content", "content": {"type": "text", "text": "2026-11-18T12:00:00Z"}}]});
    assert!(!annotate("sess-late", &mut done, meta, host.clone()), "the result came first");
    assert!(sent.try_recv().is_err());
    gate.notify_one();
    let msg = tokio::time::timeout(std::time::Duration::from_secs(10), sent.recv())
        .await
        .expect("no late surface")
        .unwrap();
    assert_eq!(msg["toolCallId"], "t1");
    assert_eq!(msg["status"], "completed");
    assert_eq!(msg["kind"], "other");
    assert_eq!(msg["tool"], name);
    assert_eq!(msg["title"], name);
    assert_eq!(msg["rawInput"], json!({}));
    assert_eq!(msg["content"][0]["content"]["text"], "2026-11-18T12:00:00Z");
    let s = &msg["surface"];
    assert_eq!(s["status"], "ready");
    assert_eq!(s["source"]["kind"], "mcp-app");
    assert_eq!(s["source"]["resourceUri"], "ui://get-time/mcp-app.html");
    assert!(s["frame"]["html"].as_str().is_some_and(|h| h.contains("get-time view")), "{s}");
    // Its second call draws from the cache, on its own update.
    let mut again = json!({"sessionUpdate": "tool_call", "toolCallId": "t2", "status": "pending",
        "title": name, "_meta": {"claude": {"toolName": name}}});
    assert!(annotate("sess-late", &mut again, meta, host.clone()));
    assert!(sent.try_recv().is_err(), "one late record");
}
