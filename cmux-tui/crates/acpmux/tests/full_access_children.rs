//! A chat an agent in full access starts runs in full access wherever it is placed, with no new
//! prompt; a starter below full access never names more than it has (`hub/full_access_children.rs`).
//!
//! Leo (2026-11-07): "if you're already starting one in that, it doesn't make sense to suddenly
//! start gating. if you're on auto, sure, these can be perms checks"

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
const REASON: &str = "permission.person_required";

/// `fake` and `kin`, two families of one stand-in that offer `normal`, `strict` (they ask) and
/// `full-access`. The daemon policy is `ask` and the start level `standard`, so a chat ends in
/// full access only by its starter.
fn hub() -> Arc<Hub> {
    let _ = &HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "env": {"FAKE_FULL_ACCESS": "1"}},
            "kin": {"argv": ["python3", FAKE], "family": "kin", "env": {"FAKE_FULL_ACCESS": "1"}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "defaultPermissionMode": "standard",
        "webRoots": [std::env::temp_dir()],
        "webAskingModes": {"fake": ["normal", "strict"], "kin": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The unix socket with no caller.
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The CLI inside chat `id`: `initialize` with the caller token acpmux gave its agent.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
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

    /// A session's mode and own policy (null: the daemon default).
    async fn level(&mut self, id: &str) -> (String, Value) {
        let r = self.ok("_acpmux/info", json!({"sessionId": id})).await;
        let mode = r["modes"]["currentModeId"].as_str().unwrap_or_default().to_owned();
        (mode, r["policy"].clone())
    }
}

fn new_params(meta: Value) -> Value {
    json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}})
}

fn id(v: &Value) -> String {
    v["sessionId"].as_str().expect("a session id").to_owned()
}

/// A starter chat on `fake` with own policy `policy`, whose harness then moves itself to `mode`.
async fn starter(app: &mut Client, policy: &str, mode: &str) -> String {
    let parent =
        id(&app.ok("session/new", new_params(json!({"harness": "fake", "policy": policy}))).await);
    let text = format!("set-mode: {mode}");
    app.ok(
        "session/prompt",
        json!({"sessionId": parent, "prompt": [{"type": "text", "text": text}]}),
    )
    .await;
    assert_eq!(app.level(&parent).await.0, mode, "the starter runs in {mode}");
    parent
}

#[tokio::test]
async fn a_full_access_agent_names_full_access_for_a_child_of_another_family_and_gets_it() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, "approve-all", "full-access").await;
    let mut agent = Client::as_session(&hub, &parent).await;
    // `acpmux new -m kin --mode full-access --policy approve-all` from the parent's shell.
    let r = agent
        .call(
            "session/new",
            new_params(json!({"harness": "kin", "mode": "full-access", "policy": "approve-all"})),
        )
        .await;
    assert!(r.get("error").is_none(), "a full-access starter was gated: {r}");
    assert_eq!(app.level(&id(&r["result"])).await, ("full-access".into(), json!("approve-all")));
}

/// "if you're on auto, sure, these can be perms checks": a starter whose mode still asks keeps
/// the gate on a full-access mode, whatever its policy.
#[tokio::test]
async fn an_agent_in_a_mode_that_asks_still_needs_the_person_for_a_full_access_child() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, "approve-all", "normal").await;
    let mut agent = Client::as_session(&hub, &parent).await;
    for harness in ["fake", "kin"] {
        let r = agent
            .call("session/new", new_params(json!({"harness": harness, "mode": "full-access"})))
            .await;
        assert_eq!(r["error"]["data"]["reason"], REASON, "{harness}: {r}");
    }
}

/// A client-sent approve-all from a starter that is not in full access is refused; one its own
/// policy already covers, or a narrower one, is not.
#[tokio::test]
async fn an_agent_below_full_access_cannot_name_a_wider_policy() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, "ask", "strict").await;
    let mut agent = Client::as_session(&hub, &parent).await;
    for policy in ["approve-all", "approve-edits"] {
        let r = agent
            .call("session/new", new_params(json!({"harness": "fake", "policy": policy})))
            .await;
        assert_eq!(r["error"]["data"]["reason"], REASON, "{policy}: {r}");
    }
    let ok = agent.ok("session/new", new_params(json!({"harness": "fake", "policy": "ask"}))).await;
    assert_eq!(app.level(&id(&ok)).await.1, json!("ask"));
    // The CLI outside any chat keeps the old rule: a policy is open to the unix socket.
    let mut cli = Client::new(&hub);
    cli.ok("session/new", new_params(json!({"harness": "fake", "policy": "approve-all"}))).await;
}

/// B's WebSocket listener: with a peer token B serves A as a peer, without one as a remote
/// client. Returns B's port and its peer token.
async fn listen(b: Arc<Hub>, tag: &str, peer: bool) -> (u16, Option<String>) {
    let home = std::env::temp_dir().join(format!("fac-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: peer.then(|| Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, peer.then_some(token))
}

/// A (`a`) with B added as peer `b`.
async fn with_peer(tag: &str, peer: bool) -> (Arc<Hub>, Arc<Hub>) {
    let b = hub();
    let (port, token) = listen(b.clone(), tag, peer).await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), token, true)
        .await
        .unwrap();
    (a, b)
}

fn on_b(meta: Value) -> Value {
    let mut meta = meta;
    meta["peer"] = json!("b");
    meta["harness"] = json!("fake");
    new_params(meta)
}

#[test]
fn a_full_access_agent_starts_a_full_access_child_on_another_machine() {
    big_stack(async {
        let (a, b) = with_peer("peer", true).await;
        let mut app = Client::new(&a);
        let mut on_b_app = Client::new(&b);
        // A full-access starter: its chat on B answers every ask, with no prompt there.
        let parent = starter(&mut app, "approve-all", "full-access").await;
        let mut agent = Client::as_session(&a, &parent).await;
        let child = id(&agent.ok("session/new", on_b(json!({}))).await);
        assert_eq!(on_b_app.level(&child).await.1, json!("approve-all"), "full access on B");
        // A starter that asks: its chat on B asks, as before; naming approve-all is refused here.
        let asking = starter(&mut app, "ask", "strict").await;
        let mut agent = Client::as_session(&a, &asking).await;
        let child = id(&agent.ok("session/new", on_b(json!({}))).await);
        assert_eq!(on_b_app.level(&child).await.1, json!("ask"), "an asking chat on B");
        let r = agent.call("session/new", on_b(json!({"policy": "approve-all"}))).await;
        assert_eq!(r["error"]["data"]["reason"], REASON, "{r}");
    });
}

/// A host that serves this machine as a remote client takes no approve-all: the full-access
/// starter's chat is refused there with that reason, never started asking instead.
#[test]
fn a_host_that_refuses_full_access_says_so_instead_of_starting_the_chat_asking() {
    big_stack(async {
        let (a, _b) = with_peer("remote", false).await;
        let mut app = Client::new(&a);
        let parent = starter(&mut app, "approve-all", "full-access").await;
        let mut agent = Client::as_session(&a, &parent).await;
        let r = agent.call("session/new", on_b(json!({}))).await;
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("does not start chats in full access"), "{r}");
        assert!(message.contains("serves this machine as a remote client"), "{r}");
        assert_eq!(r["error"]["data"]["fullAccessRefusedBy"], "b", "{r}");
        // Its way out starts the same chat there asking.
        let try_cmd = r["error"]["data"]["try"].as_str().unwrap_or_default();
        assert!(try_cmd.contains("--machine b") && try_cmd.contains("--policy ask"), "{r}");
        // Asking for less there still starts it.
        agent.ok("session/new", on_b(json!({"policy": "ask"}))).await;
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
