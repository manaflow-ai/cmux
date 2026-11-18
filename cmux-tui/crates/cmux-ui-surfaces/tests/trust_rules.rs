//! The trust rules (design "Trust and permission mediation", 6236-31): inert
//! text, caps, unknown catalogs, the bridge table, no outbound without
//! confirm, stale requests.

use cmux_ui_surfaces::actions::Outbound;
use cmux_ui_surfaces::catalog::CMUX;
use cmux_ui_surfaces::coalesce::Coalescer;
use cmux_ui_surfaces::mcp_apps::{self, Allowed, ToolInfo, ToolUi};
use cmux_ui_surfaces::model::*;
use cmux_ui_surfaces::store::Bridge;
use cmux_ui_surfaces::{SurfaceStore, caps};
use serde_json::{Map, Value, json};

fn src() -> Source {
    Source { kind: SourceKind::A2ui, ..Default::default() }
}

fn store_with(msgs: Value) -> SurfaceStore {
    let mut s = SurfaceStore::new();
    let out = s.apply_value(&msgs, &src(), true);
    assert!(out.errors.is_empty(), "{:?}", out.errors);
    s.finish_all();
    s
}

fn json_of(s: &SurfaceStore, id: &str) -> Value {
    serde_json::to_value(s.surface(id).unwrap()).unwrap()
}

fn find<'a>(node: &'a Value, id: &str) -> Option<&'a Value> {
    if node["id"] == id {
        return Some(node);
    }
    node["children"].as_array().into_iter().flatten().find_map(|c| find(c, id))
}

fn form() -> Value {
    json!([
        {"version": "1.0", "createSurface": {"surfaceId": "f", "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}},
        {"version": "1.0", "updateComponents": {"surfaceId": "f", "components": [
            {"id": "root", "component": "Column", "children": ["name", "go"]},
            {"id": "name", "component": "TextField", "label": "Name", "value": {"@path": "/who/name"}},
            {"id": "go_t", "component": "Text", "text": "Go"},
            {"id": "go", "component": "Button", "child": "go_t", "action": {"event": {"name": "submit", "context": {"name": {"@path": "/who/name"}}}}}
        ]}},
        {"version": "1.0", "updateDataModel": {"surfaceId": "f", "path": "/who", "value": {"name": "Ada"}}}
    ])
}

fn values(pairs: &[(&str, Value)]) -> Map<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

#[test]
fn html_and_script_strings_stay_inert_text() {
    let evil = "<script>alert(1)</script><img src=x onerror=alert(2)>";
    let s = store_with(json!([
        {"version": "1.0", "createSurface": {"surfaceId": "x", "components": [
            {"id": "root", "component": "Text", "text": evil},
        ]}}
    ]));
    let v = json_of(&s, "x");
    assert_eq!(v["root"]["type"], "text");
    assert_eq!(v["root"]["text"], evil);
    assert_eq!(v["frame"], Value::Null);
    // An Image never carries its URL; only alt text reaches the renderer.
    let s = store_with(json!([
        {"version": "1.0", "createSurface": {"surfaceId": "i", "components": [
            {"id": "root", "component": "Image", "url": "javascript:alert(1)", "description": "A cat"},
        ]}}
    ]));
    let text = serde_json::to_string(&s.surface("i").unwrap()).unwrap();
    assert!(!text.contains("javascript:"), "{text}");
}

#[test]
fn caps_hold_and_say_what_was_cut() {
    let long = "x".repeat(10_000);
    let mut comps = vec![
        json!({"id": "root", "component": "Column", "children": (0..600).map(|i| format!("t{i}")).collect::<Vec<_>>()}),
    ];
    for i in 0..600 {
        comps.push(json!({"id": format!("t{i}"), "component": "Text", "text": if i == 0 { long.clone() } else { format!("row {i}") }}));
    }
    let s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "big", "components": comps}}]),
    );
    let v = json_of(&s, "big");
    assert!(serde_json::to_string(&v).unwrap().len() <= caps::SURFACE_BYTES);
    let t0 = find(&v["root"], "t0").unwrap();
    assert!(t0["text"].as_str().unwrap().len() <= caps::STRING_BYTES);
    assert!(serde_json::to_string(&v).unwrap().contains("over the 512 cap"));

    // Table rows and chart points.
    let rows: Vec<Value> = (0..300).map(|i| json!([i.to_string()])).collect();
    let pts: Vec<Value> = (0..1500).map(|i| json!({"x": i.to_string(), "y": i})).collect();
    let s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "t", "catalogId": CMUX, "components": [
            {"id": "root", "component": "Column", "children": ["tbl", "ch"]},
            {"id": "tbl", "component": "Table", "columns": ["n"], "rows": rows},
            {"id": "ch", "component": "Chart", "kind": "line", "series": [{"name": "a", "points": pts}]},
        ]}}]),
    );
    let v = json_of(&s, "t");
    let tbl = find(&v["root"], "tbl").unwrap();
    assert_eq!(tbl["rows"].as_array().unwrap().len(), caps::TABLE_ROWS);
    assert_eq!(tbl["truncated"], true);
    let ch = find(&v["root"], "ch").unwrap();
    assert_eq!(ch["series"][0]["points"].as_array().unwrap().len(), caps::CHART_POINTS);
}

#[test]
fn depth_and_cycles_become_fallbacks() {
    let mut comps = Vec::new();
    for i in 0..40 {
        let id = if i == 0 { "root".to_string() } else { format!("c{i}") };
        comps.push(json!({"id": id, "component": "Column", "children": [format!("c{}", i + 1)]}));
    }
    comps.push(json!({"id": "loop_a", "component": "Card", "child": "loop_b"}));
    comps.push(json!({"id": "loop_b", "component": "Card", "child": "loop_a"}));
    let s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "d", "components": comps}}]),
    );
    assert!(
        serde_json::to_string(&s.surface("d").unwrap()).unwrap().contains("Nested deeper than 32")
    );
    let s =
        store_with(json!([{"version": "1.0", "createSurface": {"surfaceId": "l", "components": [
            {"id": "root", "component": "Card", "child": "loop_a"},
            {"id": "loop_a", "component": "Card", "child": "loop_b"},
            {"id": "loop_b", "component": "Card", "child": "loop_a"},
        ]}}]));
    assert!(serde_json::to_string(&s.surface("l").unwrap()).unwrap().contains("contains itself"));
}

#[test]
fn unknown_catalog_is_an_error_surface_and_unknown_components_fall_back() {
    let s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "u", "catalogId": "https://evil.example/cat.json", "components": [
            {"id": "root", "component": "Text", "text": "hi"}
        ]}}]),
    );
    let v = json_of(&s, "u");
    assert_eq!(v["status"], "error");
    assert_eq!(v["root"]["type"], "fallback");
    let s =
        store_with(json!([{"version": "1.0", "createSurface": {"surfaceId": "w", "components": [
            {"id": "root", "component": "Column", "children": ["a", "b"]},
            {"id": "a", "component": "ApprovalCard", "title": "basic has no approval card"},
            {"id": "b", "component": "Text", "@catalogId": "https://other.example/x", "text": "x"},
        ]}}]));
    let v = json_of(&s, "w");
    assert_eq!(find(&v["root"], "a").unwrap()["type"], "fallback");
    assert_eq!(find(&v["root"], "b").unwrap()["type"], "fallback");
}

#[test]
fn malformed_messages_are_refused_not_panics() {
    let mut s = SurfaceStore::new();
    for bad in [
        json!(null),
        json!({"version": "0.9", "createSurface": {"surfaceId": "a"}}),
        json!({"version": "1.0", "createSurface": {"surfaceId": "a"}, "deleteSurface": {"surfaceId": "a"}}),
        json!({"version": "1.0", "beginRendering": {}}),
        json!({"version": "1.0", "updateComponents": {"surfaceId": "nope", "components": [{"id": "root", "component": "Text"}]}}),
        json!({"version": "1.0", "createSurface": {"surfaceId": "<script>"}}),
    ] {
        let out = s.apply_value(&bad, &src(), true);
        assert_eq!(out.errors.len(), 1, "{bad}");
    }
    let out = s.apply_value(
        &Value::String(
            "{\"version\":\"1.0\",\"createSurface\":{\"surfaceId\":\"s\"}}\n{\"vers".into(),
        ),
        &src(),
        false,
    );
    assert!(out.errors.is_empty(), "a partial last JSONL line waits while streaming");
    assert_eq!(s.surface("s").unwrap().status, Status::Streaming);
}

#[test]
fn nothing_is_sent_without_confirm_and_the_summary_lists_the_sends() {
    let mut s = store_with(form());
    let p = s.request_action("f", "go", &values(&[("/who/name", json!("Grace"))])).unwrap();
    assert_eq!(p.target, "agent");
    assert_eq!(p.sends, vec![Send { label: "name".into(), value: "Grace".into() }]);
    assert_eq!(p.summary, "Send \"submit\" to the agent with: name = Grace");
    assert_eq!(s.surface("f").unwrap().pending.as_ref(), Some(&p));

    // Cancel drops it: confirm then has nothing to send.
    assert!(s.cancel(&p.request_id));
    assert!(s.confirm(&p.request_id, None, "2026-11-18T00:00:00Z").is_err());

    let p = s.request_action("f", "go", &Map::new()).unwrap();
    let out = s.confirm(&p.request_id, None, "2026-11-18T00:00:00Z").unwrap();
    let Outbound::Agent { message, .. } = &out else { panic!("{out:?}") };
    assert_eq!(message["action"]["context"]["name"], "Grace");
    assert_eq!(message["action"]["timestamp"], "2026-11-18T00:00:00Z");
    cmux_ui_surfaces::a2ui::validate_client_message(message).unwrap();
    assert!(out.prompt_text().unwrap().contains("```json"));
    // One confirm, one send.
    assert!(s.confirm(&p.request_id, None, "t").is_err());
}

#[test]
fn a_changed_value_makes_the_request_stale() {
    let mut s = store_with(form());
    let p = s.request_action("f", "go", &Map::new()).unwrap();
    let err = s
        .confirm(&p.request_id, Some(&values(&[("/who/name", json!("Mallory"))])), "t")
        .unwrap_err();
    assert!(err.0.contains("changed"), "{err}");

    // The agent changing the bound data after the summary does too.
    let p = s.request_action("f", "go", &Map::new()).unwrap();
    s.apply_value(&json!({"version": "1.0", "updateDataModel": {"surfaceId": "f", "path": "/who/name", "value": "Eve"}}), &src(), true);
    assert!(s.confirm(&p.request_id, None, "t").is_err());

    // A field edit reported without a press drops the strip.
    let p = s.request_action("f", "go", &Map::new()).unwrap();
    assert!(s.values_changed("f", &values(&[("/who/name", json!("Zed"))])).unwrap());
    assert!(s.surface("f").unwrap().pending.is_none());
    assert!(s.confirm(&p.request_id, None, "t").is_err());

    // Values may only name bound fields.
    assert!(s.request_action("f", "go", &values(&[("/secret", json!("x"))])).is_err());
}

#[test]
fn checks_block_the_action_and_send_data_model_lists_every_path() {
    let mut s = store_with(json!([
        {"version": "1.0", "createSurface": {"surfaceId": "c", "sendDataModel": true, "dataModel": {"email": "nope", "plan": "pro"}, "components": [
            {"id": "root", "component": "Column", "children": ["e", "b"]},
            {"id": "e", "component": "TextField", "label": "Email", "value": {"@path": "/email"}},
            {"id": "bt", "component": "Text", "text": "Save"},
            {"id": "b", "component": "Button", "child": "bt", "action": {"event": {"name": "save"}},
             "@checks": [{"condition": {"@call": "email", "args": {"value": {"@path": "/email"}}}, "message": "Enter an email"}]}
        ]}}
    ]));
    assert_eq!(s.request_action("c", "b", &Map::new()).unwrap_err().0, "Enter an email");
    let p = s.request_action("c", "b", &values(&[("/email", json!("a@b.co"))])).unwrap();
    let labels: Vec<&str> = p.sends.iter().map(|x| x.label.as_str()).collect();
    assert_eq!(labels, ["/email", "/plan"]);
    let out = s.confirm(&p.request_id, None, "t").unwrap();
    let Outbound::Agent { metadata: Some(meta), .. } = out else { panic!() };
    assert_eq!(meta["a2uiRendererDataModel"]["surfaces"]["c"]["plan"], "pro");
}

#[test]
fn open_url_is_https_only_and_confirmed() {
    let mk = |url: &str| {
        store_with(json!([{"version": "1.0", "createSurface": {"surfaceId": "o", "components": [
            {"id": "lt", "component": "Text", "text": "Docs"},
            {"id": "root", "component": "Button", "child": "lt", "action": {"functionCall": {"@call": "openUrl", "args": {"url": url}}}}
        ]}}]))
    };
    let mut s = mk("javascript:alert(1)");
    assert!(s.request_action("o", "root", &Map::new()).is_err());
    let mut s = mk("https://a2ui.org/docs");
    let p = s.request_action("o", "root", &Map::new()).unwrap();
    assert_eq!(p.target, "link:https://a2ui.org/docs");
    assert!(matches!(s.confirm(&p.request_id, None, "t").unwrap(), Outbound::OpenLink { .. }));
}

#[test]
fn renderer_function_calls_from_the_agent_are_allowlisted() {
    let mut s = SurfaceStore::new();
    let out = s.apply_value(&json!([
        {"version": "1.0", "callRendererFunction": {"functionCallId": "1", "callFunction": {"@call": "openUrl", "catalogId": "x", "args": {"url": "https://e.com"}}}},
        {"version": "1.0", "callRendererFunction": {"functionCallId": "2", "callFunction": {"@call": "formatNumber", "catalogId": "x", "args": {"value": 1234.5, "decimals": 1}}}},
    ]), &src(), true);
    assert!(out.replies[0]["rendererFunctionResponse"]["error"].is_object());
    assert_eq!(out.replies[1]["rendererFunctionResponse"]["value"], "1,234.5");
}

#[test]
fn format_string_binds_relative_paths_in_templates() {
    let s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "t", "dataModel": {"cur": "EUR", "items": [{"n": "A", "p": 3}, {"n": "B", "p": 1}]}, "components": [
            {"id": "root", "component": "List", "children": {"path": "/items", "componentId": "row"}},
            {"id": "row", "component": "Text", "text": {"@call": "formatString", "args": {"value": "${n}: ${p} ${pluralize(value: ${p}, one: 'item', other: 'items')} in ${/cur}"}}}
        ]}}]),
    );
    let v = json_of(&s, "t");
    assert_eq!(v["root"]["children"][0]["id"], "row#0");
    assert_eq!(v["root"]["children"][0]["text"], "A: 3 items in EUR");
    assert_eq!(v["root"]["children"][1]["text"], "B: 1 item in EUR");
}

#[test]
fn cmux_catalog_cards() {
    let mut s = store_with(
        json!([{"version": "1.0", "createSurface": {"surfaceId": "k", "catalogId": CMUX, "components": [
            {"id": "root", "component": "Column", "children": ["ap", "rv", "pg"]},
            {"id": "ap", "component": "ApprovalCard", "title": "Deploy", "detail": "Ship to prod", "risk": "high",
             "facts": [{"label": "Branch", "value": "main"}],
             "approveAction": {"event": {"name": "approve_deploy"}}, "denyAction": {"event": {"name": "deny_deploy"}}},
            {"id": "rv", "component": "ReviewCard", "title": "Pick", "prompt": "Which?", "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
             "value": {"@path": "/pick"}, "submitAction": {"event": {"name": "picked"}}},
            {"id": "pg", "component": "Progress", "label": "Build", "value": 3, "max": 10}
        ]}}]),
    );
    let v = json_of(&s, "k");
    let ap = find(&v["root"], "ap").unwrap();
    assert_eq!(ap["type"], "approval");
    assert_eq!(ap["approve"]["id"], "ap.approve");
    let p = s.request_action("k", "rv.submit", &values(&[("/pick", json!(["b"]))])).unwrap();
    assert_eq!(p.summary, "Send \"picked\" to the agent with: selected = b");
}

#[test]
fn mcp_app_bridge_follows_the_table() {
    let tools = vec![
        ToolInfo {
            name: "refresh".into(),
            ui: Some(ToolUi {
                resource_uri: "ui://x/a.html".into(),
                visibility: vec!["app".into()],
            }),
        },
        ToolInfo {
            name: "delete_all".into(),
            ui: Some(ToolUi {
                resource_uri: "ui://x/a.html".into(),
                visibility: vec!["model".into()],
            }),
        },
    ];
    let mut s = SurfaceStore::new();
    let source = Source {
        kind: SourceKind::McpApp,
        server: Some("x".into()),
        tool: Some("show".into()),
        ..Default::default()
    };
    s.put_frame("app", source, "<p>hi</p>".into(), mcp_apps::csp(None), tools).unwrap();
    let rpc = |method: &str, params: Value| json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});

    assert!(
        matches!(
            s.bridge("app", &rpc("tools/call", json!({"name": "refresh"}))).unwrap(),
            Bridge::Refused(_)
        ),
        "nothing before initialized"
    );
    assert_eq!(
        s.bridge("app", &rpc("ui/initialize", json!({}))).unwrap(),
        Bridge::Allowed(Allowed::Initialize)
    );
    assert_eq!(
        s.bridge("app", &rpc("ui/notifications/initialized", json!({}))).unwrap(),
        Bridge::Allowed(Allowed::Initialized)
    );
    assert_eq!(
        s.bridge("app", &rpc("ui/notifications/size-changed", json!({"height": 99999}))).unwrap(),
        Bridge::Allowed(Allowed::SizeChanged { height: 1200 })
    );
    assert_eq!(s.surface("app").unwrap().frame.unwrap().height, 1200);
    assert!(matches!(
        s.bridge("app", &rpc("tools/call", json!({"name": "delete_all"}))).unwrap(),
        Bridge::Refused(_)
    ));
    for m in ["sampling/createMessage", "ui/download-file", "tools/list", "notifications/message"] {
        assert!(matches!(s.bridge("app", &rpc(m, json!({}))).unwrap(), Bridge::Refused(_)), "{m}");
    }
    assert!(matches!(
        s.bridge("app", &rpc("ui/open-link", json!({"url": "http://x.com"}))).unwrap(),
        Bridge::Refused(_)
    ));
    assert!(matches!(
        s.bridge("app", &rpc("resources/read", json!({"uri": "file:///etc/passwd"}))).unwrap(),
        Bridge::Refused(_)
    ));
    assert!(matches!(
        s.bridge(
            "app",
            &rpc("ui/message", json!({"role": "user", "content": {"type": "text", "text": "hi"}}))
        )
        .unwrap(),
        Bridge::Allowed(Allowed::Draft { .. })
    ));
    let Bridge::NeedsConfirm(p) = s
        .bridge("app", &rpc("tools/call", json!({"name": "refresh", "arguments": {"q": 1}})))
        .unwrap()
    else {
        panic!()
    };
    assert_eq!(p.target, "tool:refresh");
    assert_eq!(p.sends, vec![Send { label: "q".into(), value: "1".into() }]);
    let out = s.confirm(&p.request_id, None, "t").unwrap();
    assert!(
        matches!(out, Outbound::ToolCall { ref tool, view_request_id: Some(_), .. } if tool == "refresh")
    );
    // Model context is refused with its reason, never held for a Confirm that sends nothing.
    let Bridge::Refused(why) =
        s.bridge("app", &rpc("ui/update-model-context", json!({"content": []}))).unwrap()
    else {
        panic!()
    };
    assert_eq!(why, mcp_apps::MODEL_CONTEXT_REFUSED);
    assert!(s.surface("app").unwrap().pending.is_none());
}

#[test]
fn csp_defaults_to_no_connect_and_drops_loosening_sources() {
    let d = mcp_apps::csp(None);
    assert!(d.contains("connect-src 'none'"));
    assert!(d.starts_with("default-src 'none'"));
    let c = mcp_apps::csp(Some(&json!({
        "connectDomains": ["https://api.example.com", "*", "'unsafe-eval'", "http://plain.example", "https://x.com; script-src *"],
        "resourceDomains": ["https://cdn.example.com"]
    })));
    assert!(c.contains("connect-src https://api.example.com;"), "{c}");
    assert!(
        !c.contains("unsafe-eval") && !c.contains("plain.example") && !c.contains("script-src *"),
        "{c}"
    );
    assert!(c.contains("script-src 'self' 'unsafe-inline' https://cdn.example.com"));
}

#[test]
fn tool_meta_and_resources() {
    let ui = mcp_apps::tool_ui(
        &json!({"name": "t", "_meta": {"ui": {"resourceUri": "ui://t/app.html"}}}),
    )
    .unwrap();
    assert!(ui.app_visible());
    assert!(mcp_apps::tool_ui(&json!({"_meta": {"ui/resourceUri": "ui://legacy"}})).is_some());
    assert!(mcp_apps::tool_ui(&json!({"_meta": {"ui": {"resourceUri": "https://x"}}})).is_none());
    let html = mcp_apps::resource_view(&json!({"contents": [{"uri": "ui://t", "mimeType": "text/html;profile=mcp-app", "text": "<b>x</b>",
        "_meta": {"ui": {"csp": {"connectDomains": ["https://api.t.dev"]}}}}]}), None).unwrap();
    assert!(
        matches!(html, mcp_apps::ResourceView::Html { ref csp, .. } if csp.contains("https://api.t.dev"))
    );
    let blob = mcp_apps::resource_view(&json!({"contents": [{"uri": "ui://t", "mimeType": "text/html;profile=mcp-app", "blob": "PGI+eDwvYj4="}]}), None).unwrap();
    assert!(matches!(blob, mcp_apps::ResourceView::Html { ref html, .. } if html == "<b>x</b>"));
    assert!(
        mcp_apps::resource_view(
            &json!({"contents": [{"uri": "ui://t", "mimeType": "text/html", "text": "x"}]}),
            None
        )
        .is_err()
    );
    let a = mcp_apps::resource_view(&json!({"contents": [{"uri": "a2ui://c", "mimeType": "application/a2ui+json", "text": "[]"}]}), None).unwrap();
    assert_eq!(a, mcp_apps::ResourceView::A2ui(json!([])));
    let r = mcp_apps::a2ui_in_tool_result(
        &json!({"content": [{"type": "text", "text": "x"}, {"type": "resource", "resource": {"uri": "a2ui://r", "mimeType": "application/a2ui+json", "text": "{\"version\":\"1.0\",\"deleteSurface\":{\"surfaceId\":\"a\"}}"}}]}),
    );
    assert!(r.is_some());
}

#[test]
fn coalescer_emits_once_per_frame() {
    let mut c = Coalescer::default();
    assert!(c.offer("s", 0));
    assert!(!c.offer("s", 5));
    assert!(!c.offer("s", 10));
    assert!(c.offer("other", 10));
    assert_eq!(c.next_due(), Some(16));
    assert!(c.due(15).is_empty());
    assert_eq!(c.due(16), vec!["s"]);
    assert!(!c.offer("s", 20));
    assert!(c.offer("s", 40));
}
