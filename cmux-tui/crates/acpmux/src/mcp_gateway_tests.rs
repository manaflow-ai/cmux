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
    // No handover wait: a test that binds a second gateway over a live one wants the fallback at
    // once, not the window a daemon gives the daemon it replaces.
    bind_at(home, crate::config::socket_path(), idle, Duration::from_millis(50), Duration::ZERO)
        .await
        .expect("gateway binds")
}

/// A gateway that waits `handover` for the port in the home's record, as the daemon's does.
async fn gateway_waiting(home: &Path, handover: Duration) -> Arc<Gateway> {
    bind_at(home, home.join("d.sock"), IDLE_STOP, Duration::from_millis(50), handover)
        .await
        .expect("gateway binds")
}

/// A loopback port nothing listens on: bound to learn its number, then let go.
async fn free_port() -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("a free port");
    listener.local_addr().expect("its address").port()
}

/// The `run/mcp-gateway.json` an earlier daemon left: `port` is the one it advertised last and
/// `earlier` the ones it advertised before that.
fn keep_record(home: &Path, port: u16, earlier: &[u16]) {
    keep_record_held(home, port, earlier, None);
}

/// [`keep_record`] naming the daemon that holds `port`.
fn keep_record_held(home: &Path, port: u16, earlier: &[u16], holder: Option<Holder>) {
    let record = Listener { port, key: "ab".repeat(32), earlier: earlier.to_vec(), holder };
    crate::agent_tools::write_private(
        &home.join("run").join("mcp-gateway.json"),
        &serde_json::to_vec(&record).expect("the record"),
    )
    .expect("keeps the record");
}

fn read_record(home: &Path) -> Listener {
    let bytes = std::fs::read(home.join("run").join("mcp-gateway.json")).expect("the record");
    serde_json::from_slice(&bytes).expect("the record parses")
}

/// [`rpc`] at `port`, which a chat's config may name instead of the gateway's current one.
async fn rpc_at(g: &Gateway, port: u16, session: &str, message: Value) -> Value {
    let auth = g.endpoint(session).authorization;
    let (status, body) = request(
        port,
        "POST",
        &format!("/mcp/{session}"),
        &[("authorization", &auth), ("content-type", "application/json")],
        &message.to_string(),
    )
    .await;
    assert!(status.contains("200"), "{status}: {body}");
    serde_json::from_str(&body).expect("one JSON message")
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
    // Each chat's call starts its server; on a slow host the first ones may
    // already be idle and stopped before the last call, so count the answers.
    for n in 0..30 {
        let id = format!("chat-{n}");
        g.keep(&id, launch(home.path())).unwrap();
        let answer = rpc(&g, &id, call(1)).await;
        assert_eq!(answer["id"], json!(1), "{answer}");
        assert!(!text(&answer).is_empty(), "{answer}");
    }
    assert!(g.running() >= 1);
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

/// The daemon a restart replaces still holds the port for a moment after its successor starts
/// (`daemon.stops.json`, `handover: another daemon of this home starts`). The successor waits for
/// it instead of taking a free port, which every live chat's config would then miss.
#[tokio::test]
async fn a_gateway_waits_out_the_handover_and_keeps_the_port_its_chats_are_configured_at() {
    let home = tempfile::tempdir().unwrap();
    let kept = free_port().await;
    keep_record(home.path(), kept, &[]);
    // The daemon being replaced, letting the port go a moment after its successor starts.
    let predecessor = TcpListener::bind(("127.0.0.1", kept)).await.expect("holds the kept port");
    let (g, ()) = tokio::join!(gateway_waiting(home.path(), Duration::from_secs(10)), async move {
        tokio::time::sleep(Duration::from_millis(400)).await;
        drop(predecessor);
    });
    assert_eq!(g.port(), kept, "it waited for the port the chats name, instead of moving");
    assert_eq!(read_record(home.path()).earlier, Vec::<u16>::new(), "nothing was left behind");
}

/// A port it cannot have (another program's, not a predecessor's) still moves the gateway, and the
/// port it leaves is written down, so a later daemon can take it back.
#[tokio::test]
async fn a_port_it_cannot_take_moves_the_gateway_and_is_remembered() {
    let home = tempfile::tempdir().unwrap();
    let kept = free_port().await;
    keep_record(home.path(), kept, &[]);
    let _squatter = TcpListener::bind(("127.0.0.1", kept)).await.expect("holds the kept port");
    let g = gateway_waiting(home.path(), Duration::ZERO).await;
    assert_ne!(g.port(), kept, "the port is taken, so new chats get a free one");
    assert_eq!(g.recovered_ports(), Vec::<u16>::new(), "it is still taken, so not served");
    let record = read_record(home.path());
    assert_eq!(record.port, g.port());
    assert_eq!(record.earlier, vec![kept], "the port the chats name is remembered");
}

/// The record names the daemon that holds the port: a live one of this home is waited for, as
/// any handover is.
#[tokio::test]
async fn a_gateway_waits_for_a_live_predecessor_of_its_own_home() {
    let home = tempfile::tempdir().unwrap();
    let kept = free_port().await;
    keep_record_held(home.path(), kept, &[], Holder::of_self(home.path()));
    let predecessor = TcpListener::bind(("127.0.0.1", kept)).await.expect("holds the kept port");
    let (g, ()) = tokio::join!(gateway_waiting(home.path(), Duration::from_secs(10)), async move {
        tokio::time::sleep(Duration::from_millis(400)).await;
        drop(predecessor);
    });
    assert_eq!(g.port(), kept, "it waited for its own home's predecessor");
    assert_eq!(read_record(home.path()).holder, Holder::of_self(home.path()), "it names itself");
}

/// A home copied from another (a cloned machine): its record names the original home's daemon,
/// which keeps the port. The copy's start takes a free port at once instead of waiting
/// HANDOVER_WAIT, which made `daemon start` miss its readiness budget (own-machines-e2e
/// clone-own-identity, 2026-11-22).
#[tokio::test]
async fn a_copied_home_does_not_wait_for_the_port_its_original_holds() {
    let original = tempfile::tempdir().unwrap();
    let copy = tempfile::tempdir().unwrap();
    let kept = free_port().await;
    keep_record_held(copy.path(), kept, &[], Holder::of_self(original.path()));
    let _original = TcpListener::bind(("127.0.0.1", kept)).await.expect("holds the kept port");
    let started = Instant::now();
    let g = gateway_waiting(copy.path(), Duration::from_secs(10)).await;
    assert!(started.elapsed() < Duration::from_secs(3), "waited {:?}", started.elapsed());
    assert_ne!(g.port(), kept, "the original's port is not this home's to wait for");
    assert_eq!(read_record(copy.path()).earlier, vec![kept]);
}

/// A holder that is gone (its pid now another process, or none) never lets the port go: whatever
/// holds it is another program, so the gateway moves at once.
#[tokio::test]
async fn a_port_its_gone_holder_left_to_another_program_is_not_waited_for() {
    let home = tempfile::tempdir().unwrap();
    let kept = free_port().await;
    let mut gone = Holder::of_self(home.path()).expect("this process's start time");
    gone.started_ms = gone.started_ms.saturating_sub(1);
    keep_record_held(home.path(), kept, &[], Some(gone));
    let _squatter = TcpListener::bind(("127.0.0.1", kept)).await.expect("holds the kept port");
    let started = Instant::now();
    let g = gateway_waiting(home.path(), Duration::from_secs(10)).await;
    assert!(started.elapsed() < Duration::from_secs(3), "waited {:?}", started.elapsed());
    assert_ne!(g.port(), kept);
}

/// The chats stranded by an earlier move: the gateway binds every port it advertised before that
/// is free again and serves the same routes and tokens there, so a config written at the old port
/// reaches its tools without being rewritten.
#[tokio::test]
async fn a_chat_configured_before_a_restart_moved_the_gateway_is_served_at_its_old_port() {
    let home = tempfile::tempdir().unwrap();
    let stranded = free_port().await;
    let now = free_port().await;
    keep_record(home.path(), now, &[stranded]);
    let g = gateway_waiting(home.path(), Duration::ZERO).await;
    assert_eq!(g.port(), now, "new chats get the port the record advertises");
    assert_eq!(g.recovered_ports(), vec![stranded], "the stranded port is free, so it is served");
    g.keep("chat-h", launch(home.path())).unwrap();
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness"}}});
    let answer = rpc_at(&g, stranded, "chat-h", init).await;
    assert_eq!(
        answer.pointer("/result/serverInfo/name"),
        Some(&json!("fake")),
        "the old port answers, instead of ECONNREFUSED"
    );
    let answer = rpc_at(&g, stranded, "chat-h", call(2)).await;
    assert!(text(&answer).starts_with(&g.server_pid("chat-h").await.unwrap().to_string()));
    // Its endpoint still names the current port: the old one is for the chats already configured.
    assert_eq!(g.endpoint("chat-h").url, format!("http://127.0.0.1:{now}/mcp/chat-h"));
    assert_eq!(read_record(home.path()).earlier, vec![stranded], "still remembered for the next");
}

/// `stdio_view` reads a chat's `cmux` entry at an earlier port as its stdio launch too; a reader
/// that judged it by url alone (`bg_hook::route`) saw a stranded chat as somebody else's server.
#[test]
fn the_bg_hook_reads_a_gateway_server_at_an_earlier_port_as_its_stdio_launch() {
    let home = tempfile::tempdir().unwrap();
    keep_record(home.path(), 41_000, &[41_227]);
    let launch = Launch {
        command: "/bin/cmux".into(),
        args: vec!["mcp".into(), "serve".into()],
        env: vec![("CMUX_SESSION".into(), "chat-i".into())],
        cwd: None,
    };
    let kept = Kept { launch, initialize: None };
    crate::agent_tools::write_private(
        &launch_path(home.path(), "chat-i"),
        &serde_json::to_vec(&kept).unwrap(),
    )
    .unwrap();
    let config = json!({"mcpServers": {"cmux": {"type": "http", "url": "http://127.0.0.1:41227/mcp/chat-i"}}});
    let view = stdio_view(home.path(), "chat-i", config);
    assert_eq!(view.pointer("/mcpServers/cmux/type"), Some(&json!("stdio")));
    assert_eq!(view.pointer("/mcpServers/cmux/command"), Some(&json!("/bin/cmux")));
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

/// The specs acpmux gives a chat's `cmux` server for its own five servers (`agent_tools.rs`
/// `for_session`, `folded`): each its own command and env, the acpmux server's with `allow`
/// as its tool allowlist when set.
fn tool_specs(session: &str, socket: &Path, allow: Option<&str>) -> Vec<Value> {
    let socket = socket.to_string_lossy().into_owned();
    let base = |session_env: &str| {
        let mut env = json!({"ACPMUX_SOCKET": socket, "ACPMUX_HOME": "/nonexistent"});
        env[session_env] = json!(session);
        env
    };
    let caller = |mut env: Value| {
        // What the daemon that registered the chat gave it: this gateway puts its own run's
        // token in its place.
        env["ACPMUX_SESSION_TOKEN"] = json!("a-token-of-an-earlier-daemon-run");
        env["ACPMUX_SESSION_TOKEN_SOCKET"] = json!(socket);
        env
    };
    let mut acpmux = caller(base("ACPMUX_SESSION_ID"));
    if let Some(allow) = allow {
        acpmux[crate::agent_tools::MCP_TOOLS_ENV] = json!(allow);
    }
    let spec = |name: &str, word: &str, env: Value| json!({"name": name, "command": "/bin/acpmux", "args": ["acp", word], "env": env});
    vec![
        spec("cmux-secrets", "secret-mcp", base("ACPMUX_SECRET_SESSION")),
        spec("cmux-sessions", "offer-mcp", base("ACPMUX_OFFER_SESSION")),
        spec("cmux-subsessions", "subsession-mcp", caller(base("ACPMUX_SESSION_ID"))),
        spec("cmux-forum", "forum-mcp", caller(base("ACPMUX_SESSION_ID"))),
        spec("acpmux", "acpmux-mcp", acpmux),
    ]
}

fn tools_launch(dir: &Path, specs: &[Value]) -> Launch {
    Launch {
        command: "/bin/cmux".into(),
        args: vec!["mcp".into(), "serve".into()],
        env: vec![
            ("CMUX_AGENT_SESSION".into(), "x".into()),
            (crate::agent_tools::UPSTREAMS_ENV.into(), Value::Array(specs.to_vec()).to_string()),
        ],
        cwd: Some(dir.to_owned()),
    }
}

/// A daemon on `socket` that answers each connection's `initialize` with the caller it proved
/// (the session its caller token names, as the daemon checks it) and any other request with
/// `{"rules": [], "caller": ..., "token": ...}`: the session and token that connection said.
#[cfg(unix)]
fn fake_daemon(socket: &Path, scope: Arc<cmux_scope::Scope>) {
    let listener = tokio::net::UnixListener::bind(socket).expect("binds the fake daemon");
    let tasks = scope.clone();
    scope.spawn_named("fake daemon", async move {
        while let Ok((stream, _)) = listener.accept().await {
            tasks.spawn_named("fake daemon connection", async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let mut caller = Value::Null;
                while let Ok(Some(line)) = lines.next_line().await {
                    let Ok(m) = serde_json::from_str::<Value>(&line) else { continue };
                    let Some(id) = m.get("id").cloned() else { continue };
                    let result = if m["method"] == "initialize" {
                        caller = m.pointer("/params/_meta/acpmux/callerSession").cloned().unwrap_or_default();
                        let proven = caller["token"]
                            .as_str()
                            .zip(caller["sessionId"].as_str())
                            .filter(|(t, s)| *t == crate::person_tokens::caller_token(s))
                            .map(|(_, s)| s.to_owned());
                        json!({"protocolVersion": 1, "_meta": {"acpmux": {"callerSessionId": proven}}})
                    } else {
                        json!({"rules": [], "caller": caller["sessionId"], "token": caller["token"]})
                    };
                    let line = json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string();
                    if write.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
}

async fn tools_rpc(g: &Gateway, session: &str, token_of: &str, message: Value) -> (String, Value) {
    let auth = g.endpoint(token_of).authorization;
    let (status, body) = request(
        g.port(),
        "POST",
        &format!("/mcp/{session}/tools"),
        &[("authorization", &auth), ("content-type", "application/json")],
        &message.to_string(),
    )
    .await;
    (status, serde_json::from_str(&body).unwrap_or(Value::Null))
}

fn for_server(server: &str, method: &str, params: Value) -> Value {
    let mut params = params;
    params["_meta"] = json!({crate::tools_mcp::SERVER_META: server});
    json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
}

/// What a server's own `acpmux *-mcp` process (and `tools-mcp`, which runs the same makers over
/// the same env) serves today: the server made in its spec's env alone.
fn stdio_served(spec: &Value) -> crate::tools_mcp::Served {
    let env: HashMap<String, String> = spec["env"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned()))
        .collect();
    let name = spec["name"].as_str().unwrap();
    let at = crate::tools_mcp::SERVERS.iter().position(|(n, _)| *n == name).unwrap();
    crate::tool_env::sync_scope(env, || {
        crate::tools_mcp::MAKERS[at](&Arc::default()).expect("its own process serves it")
    })
}

#[tokio::test]
async fn each_of_acpmux_s_own_servers_answers_at_the_tool_endpoint_as_its_own_process_does() {
    let home = tempfile::tempdir().unwrap();
    let socket = home.path().join("d.sock");
    let g =
        bind_at(home.path(), socket.clone(), IDLE_STOP, Duration::from_secs(60), Duration::ZERO)
            .await
            .unwrap();
    // One chat with an allowlist on the acpmux server, one without: each answers by its own.
    let narrow = tool_specs("chat-t", &socket, Some("acpmux_ls,acpmux_send"));
    let wide = tool_specs("chat-u", &socket, None);
    g.keep("chat-t", tools_launch(home.path(), &narrow)).unwrap();
    g.keep("chat-u", tools_launch(home.path(), &wide)).unwrap();
    for (session, specs) in [("chat-t", &narrow), ("chat-u", &wide)] {
        for spec in specs.iter() {
            let name = spec["name"].as_str().unwrap();
            let own = stdio_served(spec);
            let init = json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cmux"}});
            let (status, answer) =
                tools_rpc(&g, session, session, for_server(name, "initialize", init)).await;
            assert!(status.contains("200"), "{status}");
            assert_eq!(answer.pointer("/result/serverInfo/name"), Some(&json!(name)), "{answer}");
            assert_eq!(
                answer.pointer("/result/instructions").and_then(Value::as_str),
                own.instructions.as_deref(),
                "{name}"
            );
            let (_, answer) =
                tools_rpc(&g, session, session, for_server(name, "tools/list", json!({}))).await;
            assert_eq!(
                answer["result"]["tools"].to_string(),
                own.tools.to_string(),
                "{session} {name}: the same tools, byte for byte"
            );
        }
    }
    let names = |session: &str| {
        let g = &g;
        let session = session.to_owned();
        async move {
            let (_, answer) =
                tools_rpc(g, &session, &session, for_server("acpmux", "tools/list", json!({})))
                    .await;
            answer["result"]["tools"].as_array().unwrap().len()
        }
    };
    assert_eq!(names("chat-t").await, 2, "the chat's own allowlist");
    assert!(names("chat-u").await > 2, "another chat's server is not narrowed by it");
}

#[cfg(unix)]
#[tokio::test]
async fn a_tool_call_acts_as_the_session_in_its_url_and_another_chats_token_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let socket = home.path().join("d.sock");
    let scope = Arc::new(cmux_scope::Scope::new("fake daemon"));
    fake_daemon(&socket, scope.clone());
    let g =
        bind_at(home.path(), socket.clone(), IDLE_STOP, Duration::from_secs(60), Duration::ZERO)
            .await
            .unwrap();
    for session in ["chat-v", "chat-w"] {
        g.keep(session, tools_launch(home.path(), &tool_specs(session, &socket, None))).unwrap();
    }
    for session in ["chat-v", "chat-w"] {
        let call =
            for_server("cmux-forum", "tools/call", json!({"name": "rules", "arguments": {}}));
        let (status, answer) = tools_rpc(&g, session, session, call).await;
        assert!(status.contains("200"), "{status}");
        let said = &answer["result"]["structuredContent"];
        assert_eq!(said["caller"], json!(session), "{answer}");
        assert_eq!(said["token"], json!(crate::person_tokens::caller_token(session)), "{answer}");
        assert_eq!(answer["result"]["isError"], json!(false), "{answer}");
    }
    let call = for_server("cmux-forum", "tools/call", json!({"name": "rules", "arguments": {}}));
    let (status, _) = tools_rpc(&g, "chat-v", "chat-w", call.clone()).await;
    assert!(status.contains("401"), "another chat's token: {status}");
    let (status, _) = tools_rpc(&g, "chat-none", "chat-none", call).await;
    assert!(status.contains("404"), "a chat the daemon never registered: {status}");
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
    let listener = Listener { port: 1, key: String::new(), earlier: Vec::new(), holder: None };
    crate::agent_tools::write_private(
        &home.path().join("run").join("mcp-gateway.json"),
        &serde_json::to_vec(&listener).unwrap(),
    )
    .unwrap();
    // A user's own HTTP server whose path also holds `/mcp/`, and one on another port: not ours.
    let theirs = json!({"type": "http", "url": "http://127.0.0.1:9/mcp/chat-h", "headers": {}});
    let config = json!({"mcpServers": {
        "cmux": {"type": "http", "url": "http://127.0.0.1:1/mcp/chat-h", "headers": {}},
        "users": {"type": "http", "url": "https://example.test/mcp/v1", "headers": {}},
        "other-port": theirs,
    }});
    let view = stdio_view(home.path(), "chat-h", config);
    assert_eq!(view.pointer("/mcpServers/cmux/command"), Some(&json!("python3")));
    assert_eq!(view.pointer("/mcpServers/cmux/env/FAKE_ENV"), Some(&json!("1")));
    assert_eq!(view.pointer("/mcpServers/users/type"), Some(&json!("http")), "the user's stays");
    assert_eq!(view.pointer("/mcpServers/other-port"), Some(&theirs), "another port stays");
}

#[tokio::test]
async fn a_chat_whose_folder_is_gone_gets_an_error_not_a_server_in_the_daemons_folder() {
    let home = tempfile::tempdir().unwrap();
    let gone = home.path().join("removed-checkout");
    let g = gateway(home.path(), IDLE_STOP).await;
    g.keep("chat-z", launch(&gone)).unwrap();
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "harness"}}});
    let answer = rpc(&g, "chat-z", init).await;
    assert!(answer.get("error").is_some(), "an error, not an answer: {answer}");
    assert_eq!(g.server_pid("chat-z").await, None, "no server started anywhere");
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
