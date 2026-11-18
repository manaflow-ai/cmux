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
    assert!(annotate("sess-a", &mut u, meta));
    let s = &u["_meta"]["acpmux"]["uiSurface"];
    assert_eq!(s["schema"], "cmux.ui-surface/1");
    assert_eq!(s["status"], "streaming");
    assert_eq!(s["title"], "Ship");
    // A second update within the same frame may be held; the last one always carries.
    let mut u2 = update("call-a", "in_progress", json!({"messages": messages()}));
    annotate("sess-a", &mut u2, meta);
    let mut done = update("call-a", "completed", json!({"messages": messages()}));
    assert!(annotate("sess-a", &mut done, meta));
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
    assert!(!annotate("sess-b", &mut u, meta));
    assert_eq!(u, before);
}

#[test]
fn an_a2ui_resource_in_a_tool_result_draws() {
    let _g = on();
    let text = serde_json::to_string(&messages()).unwrap();
    let mut u = json!({"sessionUpdate": "tool_call_update", "toolCallId": "r1", "status": "completed",
        "title": "mcp__recipes__show",
        "content": [{"type": "content", "content": {"type": "resource", "resource": {"uri": "a2ui://r", "mimeType": "application/a2ui+json", "text": text}}}]});
    assert!(annotate("sess-c", &mut u, meta));
    assert_eq!(u["_meta"]["acpmux"]["uiSurface"]["source"]["server"], "recipes");
}

#[test]
fn flag_off_builds_nothing() {
    let _g = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_enabled_for_test(false);
    let mut u = update("call-off", "completed", json!({"messages": messages()}));
    assert!(!annotate("sess-off", &mut u, meta));
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
