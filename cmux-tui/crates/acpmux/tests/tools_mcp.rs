//! acpmux's own agent tool servers in one process per chat (`tools_mcp.rs`, acpmux audit
//! finding 10). The process answers each server's `initialize` and `tools/list` exactly as that
//! server's own process does (name, instructions, tool names, descriptions and schemas: the
//! harness's prompt cache and the skills name them), and its calls act as the chat's session.
//! The "before" side is each server's own command (`secret-mcp`, ...), run here as it was.
//!
//! On Linux it also prints what the processes hold, after each listed its tools: the five
//! servers' processes against the one (`tools_mcp measure:` lines in the test output).

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::sync::mpsc;

/// Each server, its own command word, and the env key its session is in.
const SERVERS: [(&str, &str, &str); 5] = [
    ("cmux-secrets", "secret-mcp", "ACPMUX_SECRET_SESSION"),
    ("cmux-sessions", "offer-mcp", "ACPMUX_OFFER_SESSION"),
    ("cmux-subsessions", "subsession-mcp", "ACPMUX_SESSION_ID"),
    ("cmux-forum", "forum-mcp", "ACPMUX_SESSION_ID"),
    ("acpmux", "acpmux-mcp", "ACPMUX_SESSION_ID"),
];
/// The `_meta` key naming the server a request is for (`tools_mcp::SERVER_META`).
const SERVER_META: &str = "cmux/server";
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

/// The app's connection, proven as the person.
struct App(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl App {
    async fn person(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut app = App(in_tx, out_rx, 0);
        let init = app.ok("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        app.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        app
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// `hub` on a unix socket of its own, as the daemon listens; its path.
async fn listen(hub: &Arc<Hub>) -> PathBuf {
    // `/tmp`, not the temp dir: a worker's can be too long for a socket path.
    let path = PathBuf::from("/tmp").join(format!(
        "acpmux-tools-mcp-{}-{}.sock",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

/// One MCP stdio process of the binary under test.
struct Mcp {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next: i64,
}

impl Mcp {
    /// `acpmux <word>` with session `id`'s env, as `agent_tools.rs` gives it: every server's
    /// session key, the caller token and this test's daemon socket.
    fn start(word: &str, scratch: &Path, socket: &Path, id: &str) -> Self {
        let mut command = daemon_env::tokio_command(scratch, daemon_env::Agents::Deny);
        command.arg(word);
        for (_, _, key) in SERVERS {
            command.env(key, id);
        }
        let mut child = command
            .env("ACPMUX_SOCKET", socket)
            .env("ACPMUX_SESSION_TOKEN", acpmux::hub::person::caller_token(id))
            .env("ACPMUX_SESSION_TOKEN_SOCKET", socket)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let lines = BufReader::new(child.stdout.take().unwrap()).lines();
        Mcp { child, stdin, lines, next: 0 }
    }

    /// The reply to one request (for `server` when given: the shared process's selector).
    async fn ask(&mut self, method: &str, mut params: Value, server: Option<&str>) -> Value {
        if let Some(server) = server {
            params["_meta"] = json!({SERVER_META: server});
        }
        self.next += 1;
        let id = self.next;
        let r = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin.write_all(format!("{r}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .unwrap_or_else(|_| panic!("{method} timed out"))
                .unwrap()
                .unwrap_or_else(|| panic!("the server closed during {method}"));
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }

    /// `initialize` and `tools/list`: what a harness learns of the server.
    async fn inventory(&mut self, server: Option<&str>) -> Value {
        let init = self.ask("initialize", json!({"protocolVersion": "2025-06-18"}), server).await;
        let list = self.ask("tools/list", json!({}), server).await;
        let init = &init["result"];
        json!({
            "name": init["serverInfo"]["name"],
            "protocolVersion": init["protocolVersion"],
            "instructions": init["instructions"],
            "tools": list["result"]["tools"],
        })
    }

    /// Resident memory (kB) and threads of the process, from /proc (Linux only).
    fn held(&self) -> Option<(u64, u64)> {
        let status = std::fs::read_to_string(format!("/proc/{}/status", self.child.id()?)).ok()?;
        let field = |name: &str| -> Option<u64> {
            let line = status.lines().find(|l| l.starts_with(name))?;
            line.split_whitespace().nth(1)?.parse().ok()
        };
        Some((field("VmRSS:")?, field("Threads:")?))
    }
}

#[tokio::test]
async fn one_process_serves_every_server_s_tools_as_its_own_process_did() {
    let hub = hub();
    let mut app = App::person(&hub).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let id = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let socket = listen(&hub).await;
    let scratch = std::env::temp_dir().join(format!("amx-tools-mcp-{}", std::process::id()));

    // Before: each server in its own process, as `cmux mcp serve` started them.
    let mut before = Vec::new();
    let mut own = Vec::new();
    for (name, word, _) in SERVERS {
        let mut mcp = Mcp::start(word, &scratch, &socket, &id);
        let inventory = mcp.inventory(None).await;
        assert_eq!(inventory["name"], name, "{inventory}");
        assert!(!inventory["tools"].as_array().unwrap().is_empty(), "{inventory}");
        before.push(inventory);
        own.push(mcp);
    }

    // After: one process; each request names its server.
    let mut shared = Mcp::start("tools-mcp", &scratch, &socket, &id);
    for ((name, _, _), was) in SERVERS.iter().zip(&before) {
        let now = shared.inventory(Some(name)).await;
        // Byte for byte: the same names, descriptions and schemas, the same instructions.
        assert_eq!(now.to_string(), was.to_string(), "{name}");
    }

    if let (Some(one), Some(five)) =
        (shared.held(), own.iter().map(Mcp::held).collect::<Option<Vec<_>>>())
    {
        let (rss, threads) = five.iter().fold((0, 0), |(r, t), (r1, t1)| (r + r1, t + t1));
        eprintln!("tools_mcp measure: before 5 processes {rss} kB RSS {threads} threads");
        eprintln!("tools_mcp measure: after 1 process {} kB RSS {} threads", one.0, one.1);
    }
    drop(own);

    // A request that names no server, or one it does not serve, is refused, never guessed.
    let refused = shared.ask("tools/list", json!({}), None).await;
    assert!(refused.get("error").is_some(), "{refused}");
    let refused = shared.ask("tools/list", json!({}), Some("cmux-cua")).await;
    assert!(refused.get("error").is_some(), "{refused}");

    // Calls act as the chat's session, over the process's one daemon connection.
    let announce = json!({"name": "announce", "arguments": {"key": "merges", "body": "Merge green.", "account": "leo"}});
    let posted = shared.ask("tools/call", announce, Some("cmux-forum")).await;
    let posted = &posted["result"];
    assert_eq!(posted["isError"], false, "{posted}");
    assert_eq!(posted["structuredContent"]["post"]["author"]["kind"], "agent", "{posted}");
    assert_eq!(posted["structuredContent"]["post"]["author"]["sessionId"], id.as_str(), "{posted}");
    let rules = json!({"name": "rules", "arguments": {}});
    let rules = shared.ask("tools/call", rules, Some("cmux-forum")).await;
    let text = rules["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("[merges]"), "{text}");
    // A tool of another server, named for the forum: refused as the forum's unknown tool.
    let wrong = json!({"name": "start_session", "arguments": {}});
    let wrong = shared.ask("tools/call", wrong, Some("cmux-forum")).await;
    assert_eq!(wrong["result"]["isError"], true, "{wrong}");
    let _ = std::fs::remove_file(&socket);
}
