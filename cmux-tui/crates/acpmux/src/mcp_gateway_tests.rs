use super::*;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A stdio MCP server like `cmux mcp serve`: answers `initialize`, `tools/list` and `tools/call`.
/// A call answers its pid and the client name of the last `initialize` it saw, and sends one
/// `notifications/progress` first when the request carries a progress token. A call before any
/// `initialize` is an error, as in a real server.
const FAKE: &str = r#"
import json, os, sys
client = None
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, i = m.get("method"), m["id"]
    if method == "initialize":
        client = m["params"]["clientInfo"]["name"]
        out = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
    elif client is None:
        print(json.dumps({"jsonrpc": "2.0", "id": i, "error": {"code": -32002, "message": "not initialized"}}), flush=True)
        continue
    elif method == "tools/list":
        out = {"tools": [{"name": "who", "inputSchema": {"type": "object"}}]}
    else:
        token = m.get("params", {}).get("_meta", {}).get("progressToken")
        if token is not None:
            print(json.dumps({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1}}), flush=True)
        out = {"content": [{"type": "text", "text": f"{os.getpid()} {client} {os.getcwd()}"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": i, "result": out}), flush=True)
"#;

fn launch(dir: &Path) -> Launch {
    Launch {
        command: "python3".into(),
        args: vec!["-c".into(), FAKE.into()],
        env: vec![("FAKE_ENV".into(), "1".into())],
        cwd: Some(dir.to_owned()),
    }
}

async fn gateway(home: &Path, idle: Duration) -> Arc<Gateway> {
    bind(home, idle, Duration::from_millis(50)).await.expect("gateway binds")
}

/// One HTTP request; answers the status line and the body.
async fn request(
    port: u16,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: &str,
) -> (String, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.expect("connects");
    let mut head = format!("{method} {path} HTTP/1.1\r\ncontent-length: {}\r\n", body.len());
    let mut host = false;
    for (k, v) in headers {
        host |= k.eq_ignore_ascii_case("host");
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    if !host {
        head.push_str(&format!("host: 127.0.0.1:{port}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await.unwrap();
    stream.write_all(body.as_bytes()).await.unwrap();
    let mut answer = String::new();
    stream.read_to_string(&mut answer).await.unwrap();
    let (head, body) = answer.split_once("\r\n\r\n").unwrap_or((&answer, ""));
    (head.lines().next().unwrap_or("").to_owned(), body.to_owned())
}

async fn rpc(g: &Gateway, session: &str, message: Value) -> Value {
    let auth = g.endpoint(session).authorization;
    let (status, body) = request(
        g.port(),
        "POST",
        &format!("/mcp/{session}"),
        &[("authorization", &auth), ("content-type", "application/json")],
        &message.to_string(),
    )
    .await;
    assert!(status.contains("200"), "{status}: {body}");
    serde_json::from_str(&body).expect("one JSON message")
}

fn call(id: u64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": "who", "arguments": {}}})
}

fn text(answer: &Value) -> String {
    answer.pointer("/result/content/0/text").and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn gone(pid: u32) -> bool {
    // A zombie still answers kill(0); `ps` says Z for it.
    let state =
        std::process::Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output();
    state.map_or(true, |o| {
        let s = String::from_utf8_lossy(&o.stdout);
        s.trim().is_empty() || s.trim_start().starts_with('Z')
    })
}

async fn until(what: &str, mut ok: impl AsyncFnMut() -> bool) {
    for _ in 0..200 {
        if ok().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("{what}");
}

#[tokio::test]
async fn no_server_runs_until_the_chats_first_request_and_one_answers_it() {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), IDLE_STOP).await;
    g.keep("chat-a", launch(home.path())).unwrap();
    assert_eq!(g.server_pid("chat-a").await, None, "a registered chat holds no process");
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness"}}});
    let answer = rpc(&g, "chat-a", init).await;
    assert_eq!(answer.pointer("/result/serverInfo/name"), Some(&json!("fake")));
    let answer = rpc(&g, "chat-a", call(2)).await;
    let pid = g.server_pid("chat-a").await.expect("runs after a request");
    let canonical = home.path().canonicalize().unwrap();
    assert_eq!(
        text(&answer),
        format!("{pid} harness {}", canonical.display()),
        "its folder is the chat's"
    );
}

#[tokio::test]
async fn an_idle_chats_server_stops_and_its_next_call_starts_one_that_was_initialized_as_the_harness()
 {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), Duration::from_millis(200)).await;
    g.keep("chat-b", launch(home.path())).unwrap();
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness"}}});
    rpc(&g, "chat-b", init).await;
    let first = g.server_pid("chat-b").await.expect("runs");
    until("the idle server stops", async || g.server_pid("chat-b").await.is_none() && gone(first))
        .await;
    // No `initialize` from the harness now: the gateway replays the one it kept.
    let answer = rpc(&g, "chat-b", call(7)).await;
    let second = g.server_pid("chat-b").await.expect("runs again");
    assert_ne!(first, second);
    assert!(text(&answer).starts_with(&format!("{second} harness ")), "{answer}");
    assert_eq!(answer["id"], json!(7));
}

#[tokio::test]
async fn thirty_chats_hold_no_process_while_idle() {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), Duration::from_millis(200)).await;
    for n in 0..30 {
        let id = format!("chat-{n}");
        g.keep(&id, launch(home.path())).unwrap();
        rpc(&g, &id, call(1)).await;
    }
    assert_eq!(g.running(), 30);
    until("every idle server stops", async || g.running() == 0).await;
}

#[tokio::test]
async fn a_request_without_its_chats_token_from_a_page_or_for_another_host_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), IDLE_STOP).await;
    g.keep("chat-c", launch(home.path())).unwrap();
    g.keep("chat-d", launch(home.path())).unwrap();
    let body = call(1).to_string();
    let port = g.port();
    let own = g.endpoint("chat-c").authorization;
    let other = g.endpoint("chat-d").authorization;
    let (status, _) = request(port, "POST", "/mcp/chat-c", &[], &body).await;
    assert!(status.contains("401"), "{status}");
    let (status, _) =
        request(port, "POST", "/mcp/chat-c", &[("authorization", &other)], &body).await;
    assert!(status.contains("401"), "another chat's token: {status}");
    let page = [("authorization", own.as_str()), ("origin", "https://example.com")];
    let (status, _) = request(port, "POST", "/mcp/chat-c", &page, &body).await;
    assert!(status.contains("403"), "a page: {status}");
    let rebound = [("authorization", own.as_str()), ("host", "evil.example:80")];
    let (status, _) = request(port, "POST", "/mcp/chat-c", &rebound, &body).await;
    assert!(status.contains("403"), "another host: {status}");
    assert_eq!(g.server_pid("chat-c").await, None, "nothing refused started a server");
}

#[tokio::test]
async fn a_call_with_a_progress_token_streams_its_progress_then_its_answer() {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), IDLE_STOP).await;
    g.keep("chat-e", launch(home.path())).unwrap();
    let auth = g.endpoint("chat-e").authorization;
    let mut message = call(3);
    message["params"]["_meta"] = json!({"progressToken": "p1"});
    let (status, body) = request(
        g.port(),
        "POST",
        "/mcp/chat-e",
        &[("authorization", &auth), ("accept", "application/json, text/event-stream")],
        &message.to_string(),
    )
    .await;
    assert!(status.contains("200"), "{status}");
    let events: Vec<Value> = body
        .lines()
        .filter_map(|l| l.strip_prefix("data: "))
        .map(|d| serde_json::from_str(d).unwrap())
        .collect();
    assert_eq!(events.len(), 2, "{body}");
    assert_eq!(events[0]["method"], json!("notifications/progress"));
    assert_eq!(events[1]["id"], json!(3));
}

#[tokio::test]
async fn the_next_daemon_takes_the_same_tokens_and_finds_the_chat() {
    let home = tempfile::tempdir().unwrap();
    let first = gateway(home.path(), IDLE_STOP).await;
    first.keep("chat-f", launch(home.path())).unwrap();
    let endpoint = first.endpoint("chat-f");
    // A second gateway on the same home stands for the daemon after an update.
    let next = gateway(home.path(), IDLE_STOP).await;
    assert_eq!(next.endpoint("chat-f").authorization, endpoint.authorization);
    let answer = rpc(&next, "chat-f", call(4)).await;
    assert!(text(&answer).starts_with(&next.server_pid("chat-f").await.unwrap().to_string()));
}

#[tokio::test]
async fn a_closed_chats_server_ends_with_it() {
    let home = tempfile::tempdir().unwrap();
    let g = gateway(home.path(), IDLE_STOP).await;
    g.keep("chat-g", launch(home.path())).unwrap();
    rpc(&g, "chat-g", call(1)).await;
    let pid = g.server_pid("chat-g").await.unwrap();
    let chat = g.chats.lock().unwrap().remove("chat-g").unwrap();
    chat.stop().await;
    until("the closed chat's server ends", async || gone(pid)).await;
}

#[test]
fn the_bg_hook_reads_a_gateway_server_as_its_stdio_launch() {
    let home = tempfile::tempdir().unwrap();
    let kept = Kept { launch: launch(home.path()), initialize: None };
    crate::agent_tools::write_private(
        &launch_path(home.path(), "chat-h"),
        &serde_json::to_vec(&kept).unwrap(),
    )
    .unwrap();
    let config = json!({"mcpServers": {"cmux": {"type": "http", "url": "http://127.0.0.1:1/mcp/chat-h", "headers": {}}}});
    let view = stdio_view(home.path(), "chat-h", config);
    assert_eq!(view.pointer("/mcpServers/cmux/command"), Some(&json!("python3")));
    assert_eq!(view.pointer("/mcpServers/cmux/env/FAKE_ENV"), Some(&json!("1")));
}

#[test]
fn a_gateway_server_is_an_http_entry_for_claude_code_and_acp() {
    let tools = crate::agent_tools::AgentTools {
        servers: vec![crate::agent_tools::McpServer {
            name: "cmux".into(),
            command: "/bin/cmux".into(),
            args: vec!["mcp".into(), "serve".into()],
            env: vec![("CMUX_AGENT_SESSION".into(), "s".into())],
        }],
        http: [(
            "cmux".to_owned(),
            Endpoint { url: "http://127.0.0.1:9/mcp/s".into(), authorization: "Bearer t".into() },
        )]
        .into(),
        ..Default::default()
    };
    let config = tools.mcp_config().unwrap();
    assert_eq!(
        config["mcpServers"]["cmux"],
        json!({"type": "http", "url": "http://127.0.0.1:9/mcp/s", "headers": {"Authorization": "Bearer t"}})
    );
    let acp = tools.acp_servers();
    assert_eq!(
        acp[0],
        json!({"type": "http", "name": "cmux", "url": "http://127.0.0.1:9/mcp/s", "headers": [{"name": "Authorization", "value": "Bearer t"}]})
    );
    assert!(crate::agent_tools::takes_http(Some(&json!({"mcpCapabilities": {"http": true}}))));
    assert!(!crate::agent_tools::takes_http(Some(&json!({"mcpCapabilities": {"http": false}}))));
    assert!(!crate::agent_tools::takes_http(None));
}
