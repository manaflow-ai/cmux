//! A time watch a chat sets for itself wakes that chat at its due time, idle or not, with the
//! inbox on (the default). Its wake went to the inbox as the chat's own message with no class,
//! an FYI, which never wakes an idle chat: it waited for whatever woke the chat next, up to an
//! hour late (five timers, 1 to 67 minutes late, measured 2026-11-26).

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
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let _ = &HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.agent_inbox = Some(true);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn script(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// A command in chat `id`'s own shell (its `watch_add` tool, `acpmux watch add`): the
    /// connection proves that chat as its caller.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::script(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }
}

fn turns(hub: &Arc<Hub>, id: &str) -> u64 {
    hub.session_summary(&hub.resolve(id).unwrap())["turnCount"].as_u64().unwrap_or(0)
}

#[tokio::test]
async fn a_time_watch_a_chat_set_for_itself_wakes_it_when_idle() {
    let hub = hub();
    hub.start_watches();
    let mut script = Client::script(&hub);
    let p = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let id = script.ok("session/new", p).await["sessionId"].as_str().unwrap().to_owned();
    // A chat that ran a turn: its first work is behind it, and it is idle now.
    script
        .ok("session/prompt", json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(turns(&hub, &id), 1);

    let mut own = Client::as_session(&hub, &id).await;
    let due = acpmux::store::now_ms() + 500;
    own.ok(
        "_acpmux/watch_add",
        json!({"to": id, "atMs": due, "prompt": "check the helper past its stop time"}),
    )
    .await;

    // Well under the inbox's FYI flush (an hour) and result deadline (15 minutes): the wake is
    // the chat's own turn within seconds of its due time, not a message held for a later one.
    let started = std::time::Instant::now();
    while turns(&hub, &id) < 2 && started.elapsed() < Duration::from_secs(20) {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let late = acpmux::store::now_ms().saturating_sub(due);
    assert_eq!(turns(&hub, &id), 2, "no turn {late} ms after the watch was due");
    eprintln!("time watch woke its idle chat {late} ms after due");

    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}
