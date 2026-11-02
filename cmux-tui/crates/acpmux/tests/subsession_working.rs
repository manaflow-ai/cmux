//! manaflow-ai/cmux#25230: a session is not done while a sub-session it started works. Its
//! status dot and lane read `working` from the summary's `subagentsWorkingSince` while the child
//! runs a turn, and stop when the child's turn ends (`hub/work_below.rs`).
//!
//! manaflow-ai/cmux#25563: its unread dot waits for that work too. A turn that ends unseen
//! while the child runs leaves the parent read; it turns unread when the child's turn ends.
//!
//! Stand-in agents (fake_agent.py): `gate: FIFO` holds a turn until the test writes the FIFO.
//! One test function: the settings file is read from this process's environment.

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
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn plain(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::plain(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
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

    /// Reads the session summary until `done` holds, for at most 20 s.
    async fn until(&mut self, id: &str, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let list = self.ok("_acpmux/sessions", json!({})).await;
            let s = list["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id);
            if let Some(s) = s.filter(|s| done(s)) {
                return s.clone();
            }
            assert!(Instant::now() < deadline, "{id} never {what}: {list}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

fn id(v: &Value) -> String {
    v["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_works_while_its_sub_session_runs() {
    let root = std::env::temp_dir().join(format!("acpmux-work-below-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, "{}").unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();
    let mut c = Client::plain(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = id(&c.ok("session/new", new).await);
    let mut p = Client::as_session(&hub, &parent).await;

    // The parent runs no turn of its own; its child holds one open at the gate.
    let gate = root.join("gate");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let child = p
        .ok(
            "_acpmux/subsession/start",
            json!({"prompt": format!("gate: {}", gate.display()), "name": "child"}),
        )
        .await;
    let child = id(&child);
    c.until(&child, "ran", |s| s["status"] == "running").await;
    let s = c.until(&parent, "worked", |s| s["subagentsWorkingSince"].is_u64()).await;
    assert_ne!(s["status"], "running", "its own turn does not run: {s}");
    assert_eq!(s["indicator"], "working", "{s}");
    assert_eq!(s["lane"]["state"], "working", "{s}");

    // The child's turn ends: so does the parent's work.
    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    c.until(&child, "ended its turn", |s| s["status"] != "running").await;
    let s = c.until(&parent, "stopped", |s| s["subagentsWorkingSince"].is_null()).await;
    assert_ne!(s["indicator"], "working", "{s}");
    let kinds: Vec<_> = hub
        .events(&parent, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "subagents_working")
        .map(|e| e.msg["since"].is_u64())
        .collect();
    assert_eq!(kinds, [true, false], "watchers heard it start and end");

    // manaflow-ai/cmux#25563: no client shows the parent, and its own turn ends while a new
    // child still runs. The task is not done, so the parent is not unread yet.
    c.ok("_acpmux/view", json!({"sessionId": parent, "visible": false})).await;
    let gate = root.join("gate-2");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let child = p
        .ok(
            "_acpmux/subsession/start",
            json!({"prompt": format!("gate: {}", gate.display()), "name": "child-2"}),
        )
        .await;
    let child = id(&child);
    c.until(&child, "ran", |s| s["status"] == "running").await;
    c.until(&parent, "worked", |s| s["subagentsWorkingSince"].is_u64()).await;
    let turn = json!({"sessionId": parent, "prompt": [{"type": "text", "text": "hello"}]});
    c.ok("session/prompt", turn).await;
    c.until(&parent, "ended its turn", |s| s["lastTurn"]["status"] == "completed").await;
    let s = c.until(&parent, "settled", |s| s["status"] != "running").await;
    assert_eq!(s["unread"], false, "its child still runs: {s}");

    // The child's turn ends: the whole task is done and nobody saw it end.
    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    // A summary read while the change lands may see the work ended before the dot: wait for both.
    c.until(&parent, "turned unread", |s| {
        s["subagentsWorkingSince"].is_null() && s["unread"] == true
    })
    .await;
    let _ = std::fs::remove_dir_all(root);
}
