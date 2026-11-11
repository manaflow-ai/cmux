//! A client's `$/cancel_request` (the known gap in `hub/pool/mod.rs`): the cancelled request's
//! caller gets the JSON-RPC cancelled error (-32800) at once and its slot on the connection is
//! free again, the cancel reaches the agent, and the agent's late answer to it is dropped on
//! purpose and logged, never handed to anyone.
//!
//! 100 `session/set_mode` requests to an agent that holds them all (`FAKE_SET_MODE_HOLD` in
//! fake_agent.py), 50 on each of two connections (one connection admits 64 at a time). 99 are
//! cancelled; the agent then answers all 100. Exactly one answer reaches a client, 99 cancelled
//! errors do, the daemon logs 99 dropped late answers, and nothing waits on the agent after.
//!
//! One test function: it sets this process's tracing subscriber.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
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
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// Requests per connection; two connections.
const PER_CONN: i64 = 50;
const WAIT: Duration = Duration::from_secs(30);
/// JSON-RPC's RequestCancelled (LSP).
const REQUEST_CANCELLED: i64 = -32800;

/// The daemon's log lines, as its subscriber writes them.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Captured {
    fn install() -> Self {
        let captured = Self::default();
        let writer = captured.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new("acpmux::cancel=debug"))
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        tracing::subscriber::set_global_default(subscriber).unwrap();
        captured
    }

    /// The logged answers that came late for a cancelled request, by the id the line names.
    fn dropped_late(&self) -> Vec<String> {
        let text = String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned();
        text.lines()
            .filter(|l| l.contains("dropped the late answer to a cancelled request"))
            .map(str::to_owned)
            .collect()
    }
}

fn hub(hold: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "env": {"FAKE_SET_MODE_HOLD": hold}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(256);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx)
}

impl Client {
    async fn send(&self, msg: Message) {
        self.0.send(msg.to_line()).await.unwrap();
    }

    /// The next answer (a message with an id) within `within`; notifications are skipped.
    async fn answer(&mut self, within: Duration) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.1.recv()).await.ok()??;
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id").is_some() && v.get("method").is_none() {
                return Some(v);
            }
        }
    }

    async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params)).await;
        loop {
            let v = self.answer(WAIT).await.expect("no answer");
            if v["id"] == json!(id) {
                return v;
            }
        }
    }
}

/// Reads `path` as JSON until `done` holds for it.
async fn wait_for_file(path: &Path, done: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Some(v) =
            std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
            && done(&v)
        {
            return v;
        }
        assert!(tokio::time::Instant::now() < deadline, "{} never got there", path.display());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_requests_free_their_slots_reach_the_agent_and_drop_late_answers() {
    let logs = Captured::install();
    let scratch =
        Scratch(std::env::temp_dir().join(format!("amx-cancel-{}", uuid::Uuid::new_v4())));
    std::fs::create_dir_all(&scratch.0).unwrap();
    let hub = hub(&scratch.0);
    let mut a = client(&hub);
    let mut b = client(&hub);

    let new =
        a.call(1, "session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    assert!(new.get("error").is_none(), "{new}");
    let session = new["result"]["sessionId"].as_str().unwrap().to_owned();
    // The mode it runs in: setting it again needs no person (`hub/person.rs`), so the request
    // reaches the agent.
    let mode = new["result"]["modes"]["currentModeId"].as_str().expect("a mode").to_owned();

    // 100 requests the agent holds: ids 1000.. on `a`, 2000.. on `b`.
    let set_mode = |id: i64| {
        Message::request(id, "session/set_mode", json!({"sessionId": session, "modeId": mode}))
    };
    for i in 0..PER_CONN {
        a.send(set_mode(1000 + i)).await;
        b.send(set_mode(2000 + i)).await;
    }
    let held = scratch.0.join("held");
    let deadline = tokio::time::Instant::now() + WAIT;
    while std::fs::read_to_string(&held).ok().and_then(|t| t.trim().parse::<i64>().ok())
        != Some(2 * PER_CONN)
    {
        if tokio::time::Instant::now() > deadline {
            let mut seen = Vec::new();
            while let Some(v) = a.answer(Duration::from_millis(500)).await {
                seen.push(v);
            }
            while let Some(v) = b.answer(Duration::from_millis(500)).await {
                seen.push(v);
            }
            panic!("held {:?}; answers so far: {seen:#?}", std::fs::read_to_string(&held).ok());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let before = hub.agent_pending_requests(&session).await;
    assert_eq!(before, Some(2 * PER_CONN as usize), "every request waits on the agent");

    // Cancel all but 1000.
    let cancel = |id: i64| Message::notification("$/cancel_request", json!({"requestId": id}));
    for i in 1..PER_CONN {
        a.send(cancel(1000 + i)).await;
    }
    for i in 0..PER_CONN {
        b.send(cancel(2000 + i)).await;
    }

    // 49 cancelled and one answer on `a`, 50 cancelled on `b`.
    let mut cancelled = Vec::new();
    let mut answered = Vec::new();
    for (client, n) in [(&mut a, PER_CONN), (&mut b, PER_CONN)] {
        for _ in 0..n {
            let Some(v) = client.answer(WAIT).await else {
                panic!(
                    "{} cancelled and {} answered so far, of {}",
                    cancelled.len(),
                    answered.len(),
                    2 * PER_CONN
                );
            };
            if v["error"]["code"] == json!(REQUEST_CANCELLED) {
                cancelled.push(v["id"].as_i64().unwrap());
            } else {
                answered.push(v);
            }
        }
    }
    assert_eq!(cancelled.len(), 99, "cancelled: {cancelled:?}, answered: {answered:?}");
    assert_eq!(answered.len(), 1, "{answered:?}");
    assert_eq!(answered[0]["id"], json!(1000), "{answered:?}");
    assert!(answered[0].get("error").is_none(), "{answered:?}");

    // Every cancel reached the agent, by its own id for the request.
    let cancels =
        wait_for_file(&scratch.0.join("cancels"), |v| v.as_array().is_some_and(|c| c.len() >= 99))
            .await;
    assert_eq!(cancels.as_array().unwrap().len(), 99, "{cancels}");

    // Its 99 late answers are dropped on purpose and logged, each once.
    let deadline = tokio::time::Instant::now() + WAIT;
    while logs.dropped_late().len() < 99 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let dropped = logs.dropped_late();
    assert_eq!(dropped.len(), 99, "{dropped:#?}");
    assert!(dropped.iter().all(|l| l.contains("session/set_mode")), "{dropped:#?}");

    // No other answer reaches either client.
    assert_eq!(a.answer(Duration::from_millis(300)).await, None);
    assert_eq!(b.answer(Duration::from_millis(300)).await, None);

    // Nothing waits on the agent, and both connections' slots are free: 64 more requests on
    // each are all admitted (none answered `connection.busy`).
    let after = hub.agent_pending_requests(&session).await;
    eprintln!("agent pending requests: before cancel {before:?}, after {after:?}");
    assert_eq!(after, Some(0));
    for client in [&mut a, &mut b] {
        for id in 0..64 {
            client.send(Message::request(5000 + id, "_acpmux/unknown", json!({}))).await;
        }
        for _ in 0..64 {
            let v = client.answer(WAIT).await.expect("an answer");
            assert_eq!(v["error"]["code"], json!(-32601), "{v}");
        }
    }
}
