use super::*;
use serde_json::json;

fn server() -> McpServer<impl FnMut(&str, &Value) -> Result<ToolResult, String>> {
    McpServer {
        version: "1.2.3".into(),
        call_tool: |name: &str, arguments: &Value| {
            Ok(ToolResult::text(format!("{name} {arguments}"), false))
        },
    }
}

fn reply(
    server: &mut McpServer<impl FnMut(&str, &Value) -> Result<ToolResult, String>>,
    message: Value,
) -> Value {
    serde_json::from_str(&server.handle_line(&message.to_string()).expect("a reply")).unwrap()
}

#[test]
fn initialize_echoes_a_known_protocol_version() {
    let mut s = server();
    let r = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}),
    );
    assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
    assert_eq!(r["result"]["serverInfo"], json!({"name": "cmux-browser-repl", "version": "1.2.3"}));
    assert_eq!(r["result"]["capabilities"]["tools"]["listChanged"], false);
    let unknown = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}),
    );
    assert_eq!(unknown["result"]["protocolVersion"], "2025-06-18");
}

#[test]
fn tools_list_has_the_15570_tool_set() {
    let mut s = server();
    let r = reply(&mut s, json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}));
    let names: Vec<&str> = r["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["eval", "snapshot", "screenshot", "tabs", "reset"]);
    assert_eq!(r["result"]["tools"][0]["inputSchema"]["required"], json!(["code"]));
}

#[test]
fn tool_calls_return_content_and_error_flags() {
    let mut s = server();
    let r = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "tabs", "arguments": {}}}),
    );
    assert_eq!(r["id"], 7);
    assert_eq!(r["result"]["content"], json!([{"type": "text", "text": "tabs {}"}]));
    assert_eq!(r["result"]["isError"], false);
    let missing = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "eval", "arguments": {}}}),
    );
    assert_eq!(missing["error"]["code"], -32602);
    assert_eq!(missing["error"]["message"], "eval needs code, a string");
    let unknown = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "nope"}}),
    );
    assert_eq!(unknown["error"]["message"], "Unknown tool: nope");
}

#[test]
fn callback_failures_become_error_results() {
    let mut s = McpServer {
        version: "x".into(),
        call_tool: |_: &str, _: &Value| Err("host is down".to_owned()),
    };
    let r = reply(
        &mut s,
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "tabs"}}),
    );
    assert_eq!(
        r["result"],
        json!({"content": [{"type": "text", "text": "host is down"}], "isError": true})
    );
}

#[test]
fn protocol_errors_and_notifications() {
    let mut s = server();
    let parse: Value = serde_json::from_str(&s.handle_line("{not json").unwrap()).unwrap();
    assert_eq!(parse["error"]["code"], -32700);
    assert!(s.handle_line(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).is_none());
    assert!(
        s.handle_line(r#"{"jsonrpc":"2.0","id":3,"result":{}}"#).is_none(),
        "client responses get no reply"
    );
    assert!(s.handle_line("   ").is_none());
    let invalid = reply(&mut s, json!({"jsonrpc": "2.0", "id": 4}));
    assert_eq!(invalid["error"]["code"], -32600);
    let missing = reply(&mut s, json!({"jsonrpc": "2.0", "id": 5, "method": "resources/list"}));
    assert_eq!(missing["error"]["code"], -32601);
    assert_eq!(
        reply(&mut s, json!({"jsonrpc": "2.0", "id": 6, "method": "ping"}))["result"],
        json!({})
    );
}

#[test]
fn tools_map_to_repl_code() {
    assert_eq!(code_for_tool("eval", &json!({"code": "1 + 1"})).as_deref(), Some("1 + 1"));
    assert_eq!(
        code_for_tool("snapshot", &json!({"target": "e\"1", "interactive": true})).as_deref(),
        Some(r#"await snapshot("e\"1", { interactive: true, viewport: false })"#)
    );
    assert_eq!(
        code_for_tool("snapshot", &json!({})).as_deref(),
        Some("await snapshot(undefined, { interactive: false, viewport: false })")
    );
    assert_eq!(code_for_tool("tabs", &json!({})).as_deref(), Some("await tabs.list()"));
    assert_eq!(code_for_tool("screenshot", &json!({})), None);
    assert_eq!(
        screenshot_code(&json!({"fullPage": true}), "M:"),
        r#"console.log("M:" + (await page.screenshot({ fullPage: true })).toString("base64")); undefined"#
    );
    assert_eq!(
        screenshot_code(&json!({"target": "#a"}), "M:"),
        r##"console.log("M:" + (await page.locator("#a").screenshot()).toString("base64")); undefined"##
    );
}

#[test]
fn eval_results_end_with_the_status_line() {
    let ok = result_of_eval(&json!({"output": "a\nb\n", "error": null, "durationMs": 12}));
    assert_eq!(ok, ToolResult::text("a\nb\n[ok | 12ms]".into(), false));
    let failed =
        result_of_eval(&json!({"output": "a\n", "error": "TypeError: x", "durationMs": 3}));
    assert_eq!(failed, ToolResult::text("a\nTypeError: x\n[error | 3ms]".into(), true));
}

#[test]
fn screenshot_output_becomes_an_image() {
    let image = screenshot_result(&json!({"output": "note\nM:iVBOR\n", "error": null}), "M:");
    assert_eq!(
        image,
        ToolResult {
            content: vec![json!({"type": "image", "data": "iVBOR", "mimeType": "image/png"})],
            is_error: false
        }
    );
    let missing = screenshot_result(&json!({"output": "nothing\n", "error": null}), "M:");
    assert!(missing.is_error);
    let failed = screenshot_result(&json!({"output": "", "error": "Error: no tab"}), "M:");
    assert_eq!(failed, ToolResult::text("Error: no tab".into(), true));
}
