//! `_acpmux/wait` on a peer's chat whose turn a capacity error cut off answers with the
//! peer's retry, not with the row the peer sent before it set the retry: a waiter here reads
//! that turn as retried, never as done. The receiving daemon holds none of the peer's marks,
//! so the peer's row says it (`retryDeciding`, `hub/auto_resume.rs`). The gui-push
//! coordinator (2026-10-20): "acpmux wait --print after a turn that failed (capacity) prints
//! the previous turn's reply, not the error, so a failed turn reads as done".

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home = std::env::temp_dir().join(format!("acpmux-wait-peer-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        acpmux::config::set_home_override(home.clone());
        home
    })
}

fn hub() -> Arc<Hub> {
    home();
    // One retry, a minute out: it still waits when the test reads it.
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "autoResumeDelaysMs": [60000]
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn answer(&mut self, id: i64) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no answer in 30 s")
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.answer(id).await
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_wait_on_a_peers_cut_turn_answers_with_the_peers_retry() {
    let b = hub();
    let dir = home().join("peer-b");
    let auth = PeerAuth::create(&dir).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), auth));
    let folder = home().join("chat");
    std::fs::create_dir_all(&folder).unwrap();
    let mut cb = client(&b);
    let made = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": folder, "mcpServers": [], "_meta": {"acpmux": {"name": "far"}}}),
        )
        .await;
    let remote =
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned();
    let warm = cb
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": remote, "prompt": [{"type": "text", "text": "warm up"}]}),
        )
        .await;
    assert!(warm.get("error").is_none(), "{warm}");

    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    // This daemon's view of the peer's row, once it has one.
    let mut seen = Value::Null;
    for _ in 0..200 {
        seen = a
            .session_summaries_of(std::slice::from_ref(&remote))
            .remove(&remote)
            .unwrap_or_default();
        if seen["status"] == "ready" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(seen["status"], "ready", "the peer's row never came: {seen}");
    let seq0 = seen["stateSeq"].as_u64().unwrap_or_else(|| panic!("{seen}"));

    let mut ca = client(&a);
    let cut = cb
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": remote, "prompt": [{"type": "text", "text": "cap-fail-once: build it"}]}),
        )
        .await;
    let waited = ca
        .call(
            method::MUX_WAIT,
            json!({"sessions": [remote], "afterSeq": {remote.clone(): seq0}, "timeoutMs": 20000}),
        )
        .await;
    let failed = cb.answer(cut).await;
    assert!(failed["error"]["message"].as_str().unwrap_or_default().contains("no non-exhausted"));
    let w = &waited["result"];
    assert_eq!(w["timedOut"], false, "{waited}");
    let row = &w["resolved"][0];
    assert_eq!(row["lastTurn"]["status"], "failed", "{waited}");
    assert_eq!(
        row["retry"]["reason"], "capacity",
        "the wait answered before the peer's retry: {waited}"
    );
    assert_eq!(row["retry"]["attempt"], 1, "{waited}");
    assert_ne!(row["retryDeciding"], true, "{waited}");
    b.shutdown_all().await;
    a.shutdown_all().await;
}
