//! `acpmux uniichat-agent`: a UniiChat server as an ACP agent, end to end
//! over stdio against a fake server that speaks UniiChat's wire protocol
//! (View.ts wire 2: a WebSocket `/ws` and the `say` act's POST `/api/act`).

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

const TOKEN: &str = "test-token-123";

/// What the fake server saw: each `say` (its query and body), each socket
/// act (`stop`), and the socket queries.
#[derive(Default)]
struct Seen {
    says: Vec<(String, Vec<u8>)>,
    acts: Vec<Value>,
    sockets: Vec<String>,
}

/// A fake UniiChat on 127.0.0.1: a say whose text holds "slow" streams one
/// delta and waits for a stop; "broke" ends in an out-of-credit note; any
/// other replies "Hello " + its text, streamed in two deltas.
struct Fake {
    port: u16,
    seen: Arc<Mutex<Seen>>,
}

fn fake() -> Fake {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (port_tx, port_rx) = std::sync::mpsc::channel();
    let shared = seen.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
        rt.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            port_tx.send(listener.local_addr().unwrap().port()).unwrap();
            let (events, _) = broadcast::channel::<String>(64);
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let (seen, events) = (shared.clone(), events.clone());
                tokio::spawn(async move { serve(stream, seen, events).await });
            }
        });
    });
    Fake { port: port_rx.recv().unwrap(), seen }
}

async fn serve(
    stream: tokio::net::TcpStream,
    seen: Arc<Mutex<Seen>>,
    events: broadcast::Sender<String>,
) {
    let mut head = [0u8; 8];
    let n = stream.peek(&mut head).await.unwrap_or(0);
    if head[..n].starts_with(b"GET") {
        socket(stream, seen, events).await;
    } else {
        post(stream, seen, events).await;
    }
}

// tungstenite's handshake callback fixes its error type (an HTTP response).
#[allow(clippy::result_large_err)]
async fn socket(
    stream: tokio::net::TcpStream,
    seen: Arc<Mutex<Seen>>,
    events: broadcast::Sender<String>,
) {
    let mut query = String::new();
    let callback =
        |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
         res: tokio_tungstenite::tungstenite::handshake::server::Response| {
            query = req.uri().query().unwrap_or("").to_owned();
            let authorized = req.headers().get("authorization").and_then(|v| v.to_str().ok())
                == Some(&format!("Bearer {TOKEN}"));
            if authorized {
                Ok(res)
            } else {
                let mut refuse =
                    tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(Some(
                        "signed out".into(),
                    ));
                *refuse.status_mut() =
                    tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
                Err(refuse)
            }
        };
    let Ok(ws) = tokio_tungstenite::accept_hdr_async(stream, callback).await else { return };
    seen.lock().unwrap().sockets.push(query);
    let (mut sink, mut source) = ws.split();
    let mut rx = events.subscribe();
    let state = json!({"$": "state", "busy": false, "wait": "", "agents": [], "pick": null,
        "vendors": [], "models": [], "bills": true, "credits": 1000, "importing": null});
    sink.send(Message::Text(state.to_string().into())).await.unwrap();
    sink.send(Message::Text(json!({"$": "view", "parts": [], "turn": 0}).to_string().into()))
        .await
        .unwrap();
    sink.send(Message::Text(json!({"$": "live", "live": []}).to_string().into())).await.unwrap();
    loop {
        tokio::select! {
            ev = rx.recv() => match ev {
                Ok(text) => if sink.send(Message::Text(text.into())).await.is_err() { return },
                Err(_) => return,
            },
            msg = source.next() => match msg {
                Some(Ok(Message::Text(t))) => {
                    let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                    seen.lock().unwrap().acts.push(v.clone());
                    if v.get("$").and_then(Value::as_str) == Some("stop") {
                        let ack = json!({"$": "ack", "id": v["id"]});
                        let _ = sink.send(Message::Text(ack.to_string().into())).await;
                        let _ = events.send(json!({"$": "entry", "id": 3, "kind": "note", "text": "Stopped by the user: Unii's turn."}).to_string());
                        let _ = events.send(json!({"$": "state", "busy": false}).to_string());
                    }
                }
                Some(Ok(_)) => {}
                _ => return,
            }
        }
    }
}

async fn post(
    mut stream: tokio::net::TcpStream,
    seen: Arc<Mutex<Seen>>,
    events: broadcast::Sender<String>,
) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let (head_end, length) = loop {
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..end]).to_lowercase();
            let length = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .and_then(|v| v.trim().parse::<usize>().ok())
                .unwrap_or(0);
            break (end + 4, length);
        }
    };
    while buf.len() < head_end + length {
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let line = head.lines().next().unwrap_or("").to_owned();
    let authorized = head
        .lines()
        .any(|l| l.to_lowercase() == format!("authorization: bearer {}", TOKEN.to_lowercase()));
    let body = buf[head_end..].to_vec();
    let (status, answer) = if !authorized {
        ("401 Unauthorized", json!({"error": "Sign in first."}))
    } else {
        let path = line.split(' ').nth(1).unwrap_or("").to_owned();
        seen.lock().unwrap().says.push((path, body.clone()));
        let text = String::from_utf8_lossy(&body).into_owned();
        let send = |v: Value| {
            let _ = events.send(v.to_string());
        };
        send(json!({"$": "state", "busy": true}));
        send(json!({"$": "entry", "id": 1, "kind": "user", "text": text}));
        if text.contains("broke") {
            send(json!({"$": "entry", "id": 2, "kind": "note", "text": "out of credit"}));
            send(json!({"$": "state", "busy": false}));
        } else if text.contains("slow") {
            send(json!({"$": "delta", "kind": "unii", "text": "Working"}));
        } else {
            send(json!({"$": "delta", "kind": "mind", "text": "thinking"}));
            send(json!({"$": "entry", "kind": "mind", "text": "thinking"}));
            send(json!({"$": "delta", "kind": "unii", "text": "Hello "}));
            send(json!({"$": "delta", "agent": "helper", "kind": "unii", "text": "not mine"}));
            send(json!({"$": "delta", "kind": "unii", "text": text}));
            send(json!({"$": "entry", "id": 2, "kind": "unii", "text": format!("Hello {text}")}));
            send(json!({"$": "live", "live": []}));
            send(json!({"$": "state", "busy": false}));
        }
        ("200 OK", json!({}))
    };
    let body = answer.to_string();
    let reply = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(reply.as_bytes()).await;
    let _ = stream.shutdown().await;
}

struct Agent {
    child: std::process::Child,
    lines: std::sync::mpsc::Receiver<Value>,
    _home: TempHome,
}

/// A UNII_HOME with (or without) the token `unii login` writes.
struct TempHome(std::path::PathBuf);

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(port: u16, token: Option<&str>) -> TempHome {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-uniichat-test-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let host = dir.join(format!("127.0.0.1:{port}"));
    std::fs::create_dir_all(&host).unwrap();
    if let Some(token) = token {
        std::fs::write(host.join("token"), format!("{token}\n")).unwrap();
    }
    TempHome(dir)
}

impl Agent {
    fn start(port: u16, token: Option<&str>) -> Agent {
        let home = home(port, token);
        let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .arg("uniichat-agent")
            .arg("--url")
            .arg(format!("http://127.0.0.1:{port}"))
            .env("UNII_HOME", &home.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start acpmux uniichat-agent");
        let out = child.stdout.take().unwrap();
        let (tx, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    let _ = tx.send(v);
                }
            }
        });
        Agent { child, lines, _home: home }
    }

    fn send(&mut self, v: Value) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{v}").unwrap();
        stdin.flush().unwrap();
    }

    /// Messages until the response to `id`: the response, the reply text
    /// and the thought text.
    fn until(&self, id: i64) -> (Value, String, String) {
        let deadline = Instant::now() + Duration::from_secs(30);
        let (mut text, mut thought) = (String::new(), String::new());
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let v = self.lines.recv_timeout(left).expect("agent answered in time");
            if v.get("id").and_then(Value::as_i64) == Some(id) {
                return (v, text, thought);
            }
            let kind = v.pointer("/params/update/sessionUpdate").and_then(Value::as_str);
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                match kind {
                    Some("agent_message_chunk") => text.push_str(t),
                    Some("agent_thought_chunk") => thought.push_str(t),
                    _ => {}
                }
            }
        }
    }

    /// The first update of `kind` before the response to `id`.
    fn wait_update(&self, kind: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let v = self.lines.recv_timeout(left).expect("update in time");
            if v.pointer("/params/update/sessionUpdate").and_then(Value::as_str) == Some(kind) {
                return v;
            }
        }
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn init(agent: &mut Agent) -> Value {
    agent
        .send(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}));
    agent.until(1).0
}

fn session(agent: &mut Agent) -> String {
    let init = init(agent);
    assert_eq!(init.pointer("/result/protocolVersion"), Some(&json!(1)));
    let cwd = std::env::temp_dir();
    agent.send(json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd": cwd, "mcpServers": []}}));
    let (new, _, _) = agent.until(2);
    new.pointer("/result/sessionId").and_then(Value::as_str).expect("session id").to_owned()
}

#[test]
fn uniichat_agent_streams_a_reply_over_the_uniichat_protocol() {
    let server = fake();
    let mut agent = Agent::start(server.port, Some(TOKEN));
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid,
        "prompt": [{"type":"text","text":"the Chief's view\n"},{"type":"text","text":"world"}]
    }}));
    let (done, text, thought) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    // Streamed once: the logged entry and a subagent's delta add nothing.
    assert_eq!(text, "Hello world");
    assert_eq!(thought, "thinking");
    let seen = server.seen.lock().unwrap();
    // Only the last block (UniiChat keeps its own memory), as a say act.
    assert_eq!(seen.says.len(), 1);
    assert_eq!(seen.says[0].1, b"world");
    assert!(seen.says[0].0.starts_with("/api/act?"), "{}", seen.says[0].0);
    assert!(
        seen.says[0].0.contains("%24=say") || seen.says[0].0.contains("$=say"),
        "{}",
        seen.says[0].0
    );
    // A view on wire 2 that names no device (no tools on this computer).
    assert!(seen.sockets[0].contains("wire=2"), "{}", seen.sockets[0]);
    assert!(!seen.sockets[0].contains("device="), "{}", seen.sockets[0]);
}

#[test]
fn uniichat_agent_sends_images_before_the_text() {
    let server = fake();
    let mut agent = Agent::start(server.port, Some(TOKEN));
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid,
        "prompt": [{"type":"image","mimeType":"image/png","data":"iVBORw=="},{"type":"text","text":"see"}]
    }}));
    let (done, _, _) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    let seen = server.seen.lock().unwrap();
    let (query, body) = &seen.says[0];
    // "iVBORw==" is the 4 bytes of a PNG signature's start.
    assert!(query.contains("sizes=4"), "{query}");
    assert_eq!(&body[..4], b"\x89PNG");
    assert_eq!(&body[4..], b"see");
}

#[test]
fn uniichat_agent_cancel_stops_unii_turn() {
    let server = fake();
    let mut agent = Agent::start(server.port, Some(TOKEN));
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"slow please"}]
    }}));
    agent.wait_update("agent_message_chunk");
    agent.send(json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId": sid}}));
    let (done, _, _) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("cancelled")), "{done}");
    let seen = server.seen.lock().unwrap();
    let stop = seen.acts.iter().find(|a| a["$"] == "stop").expect("a stop act");
    assert_eq!(stop["name"], json!("Unii's turn"));
}

#[test]
fn uniichat_agent_a_failed_turn_shows_uniichat_s_note() {
    let server = fake();
    let mut agent = Agent::start(server.port, Some(TOKEN));
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"broke"}]
    }}));
    let (done, _, _) = agent.until(3);
    let message = done.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(message.contains("out of credit"), "{done}");
}

#[test]
fn uniichat_agent_without_a_sign_in_says_how_to_set_up() {
    let server = fake();
    let mut agent = Agent::start(server.port, None);
    init(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd": std::env::temp_dir(), "mcpServers": []}}));
    let (new, _, _) = agent.until(2);
    assert_eq!(new.pointer("/error/code"), Some(&json!(-32000)), "{new}");
    let message = new.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(message.contains("unii login"), "{message}");
}

#[test]
fn uniichat_agent_a_refused_sign_in_says_to_sign_in_again() {
    let server = fake();
    let mut agent = Agent::start(server.port, Some("stale-token"));
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"hi"}]
    }}));
    let (done, _, _) = agent.until(3);
    assert_eq!(done.pointer("/error/code"), Some(&json!(-32000)), "{done}");
    let message = done.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(message.contains("unii login"), "{message}");
}
