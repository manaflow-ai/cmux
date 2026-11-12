//! Forking a chat on another computer (a peer's) from this computer's app: the pane's
//! `acp.session.fork` is forwarded whole to the peer, which forks the chat it holds
//! (`server/fork_through.rs`). Leo, 2026-11-11: "why are only some chats forkable".

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
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
        // A peer's start may use this folder (`remote.cwd_outside_roots` otherwise).
        "webRoots": [std::env::temp_dir()],
        // A peer's start runs in an asking mode (`remote.mode_not_asking` otherwise).
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn on(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The CLI outside any chat: the unix socket with no caller.
    fn script(hub: &Arc<Hub>) -> Self {
        Self::on(hub, Origin::Local)
    }

    /// This host's app.
    fn app(hub: &Arc<Hub>) -> Self {
        Self::on(hub, Origin::LocalApp)
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

    /// A new session with `meta` as its `_meta.acpmux`: its id.
    async fn new_session(&mut self, meta: Value) -> String {
        let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        self.ok("session/new", p).await["sessionId"].as_str().expect("a session id").to_owned()
    }

    /// The seqs of chat `id`'s events of `kind`.
    async fn seqs(&mut self, id: &str, kind: &str) -> Vec<u64> {
        let page =
            self.ok("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
        let events = page["events"].as_array().unwrap_or_else(|| panic!("{page}"));
        events.iter().filter(|e| e["kind"] == kind).filter_map(|e| e["seq"].as_u64()).collect()
    }

    /// Whether this daemon lists chat `id` as its own.
    async fn lists(&mut self, id: &str) -> bool {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"].as_array().unwrap().iter().any(|s| s["sessionId"] == id)
    }
}

/// B serving A as a peer.
async fn with_peer() -> (Arc<Hub>, Arc<Hub>) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("peer-fork-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), auth));
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    (a, b)
}

#[test]
fn the_app_forks_a_chat_on_another_computer() {
    big_stack(async {
        let (a, b) = with_peer().await;
        let mut app = Client::app(&a);
        let mut on_b = Client::script(&b);
        let chat = app.new_session(json!({"peer": "b", "name": "on-b"})).await;
        for text in ["first", "second"] {
            app.ok(
                "session/prompt",
                json!({"sessionId": chat, "prompt": [{"type": "text", "text": text}]}),
            )
            .await;
        }
        assert!(on_b.lists(&chat).await, "the chat lives on b");

        // Fork Conversation: the whole chat as it is now.
        let live = app.ok("acp.session.fork", json!({"sessionId": chat, "live": true})).await;
        let live = live["sessionId"].as_str().unwrap_or_else(|| panic!("{live}")).to_owned();
        assert_ne!(live, chat);
        assert!(on_b.lists(&live).await, "b holds the fork");

        // Fork from here: through the chat's last completed turn.
        let through = *on_b.seqs(&chat, "turn_result").await.last().expect("a completed turn");
        let turn =
            app.ok("acp.session.fork", json!({"sessionId": chat, "throughSeq": through})).await;
        let turn = turn["sessionId"].as_str().unwrap_or_else(|| panic!("{turn}")).to_owned();
        assert!(on_b.lists(&turn).await, "b holds the turn fork");
        assert_eq!(on_b.seqs(&turn, "user_message").await.len(), 2, "it copies both prompts");
    });
}

/// The session/new handler's future is deeper than a debug build's 2 MiB worker stack, as in
/// `tests/inherit_start.rs`.
fn big_stack(f: impl std::future::Future<Output = ()>) {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
        .block_on(f);
}
