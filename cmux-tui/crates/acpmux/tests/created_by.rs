//! Who created a session (`hub/created_by.rs`): the daemon records `createdBy {kind, workspace?,
//! session?}` at creation from what the connection proved, and the summary the app lists shows
//! it. The person (the app), an agent (its shell's `acpmux new`, its `start_session` tool) and a
//! script (the CLI outside a chat) each get theirs; a `createdBy` a client sends is never read,
//! except the one a proven peer daemon stamps on a start it forwards.

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
const WORKSPACE: &str = "0196f0a4-9c1e-7d2a-8b3c-4d5e6f708192";

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

    /// `acpmux new` in chat `id`'s shell: `initialize` with the caller token acpmux gave it.
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

    /// A new session with `meta` as its `_meta.acpmux`: its id.
    async fn new_session(&mut self, meta: Value) -> String {
        let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        self.ok("session/new", p).await["sessionId"].as_str().expect("a session id").to_owned()
    }

    /// Session `id`'s `createdBy`, as the session list shows it.
    async fn created_by(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        let row = list["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id);
        row.unwrap_or_else(|| panic!("{id} is not listed: {list}"))["createdBy"].clone()
    }
}

#[tokio::test]
async fn the_person_an_agent_and_a_script_each_record_who_created_the_session() {
    let hub = hub();
    let mut app = Client::app(&hub);
    // The app starts a chat in a workspace: the person, from that workspace.
    let coord = app.new_session(json!({"name": "coord", "workspaceId": WORKSPACE})).await;
    assert_eq!(app.created_by(&coord).await, json!({"kind": "person", "workspace": WORKSPACE}),);

    // Its agent runs `acpmux new` (the proven caller): that agent, from its chat's workspace,
    // whatever the request says.
    let mut agent = Client::as_session(&hub, &coord).await;
    let kid = agent.new_session(json!({"name": "kid", "createdBy": {"kind": "person"}})).await;
    assert_eq!(
        app.created_by(&kid).await,
        json!({"kind": "agent", "workspace": WORKSPACE, "session": coord}),
    );

    // Its `start_session` tool: that agent too.
    let sub =
        agent.ok("_acpmux/subsession/start", json!({"prompt": "echo sub", "name": "sub"})).await;
    let sub = sub["sessionId"].as_str().unwrap();
    assert_eq!(
        app.created_by(sub).await,
        json!({"kind": "agent", "workspace": WORKSPACE, "session": coord}),
    );

    // The CLI outside a chat: a script, whatever it claims.
    let mut cli = Client::script(&hub);
    let ran = cli
        .new_session(json!({"name": "ran", "createdBy": {"kind": "agent", "session": coord}}))
        .await;
    assert_eq!(app.created_by(&ran).await, json!({"kind": "script"}));
    // Nor by saying it carries the person's phone (`via`, the Cloud mobile carrier's marker):
    // its connection proves no person.
    let ran = cli.new_session(json!({"name": "ran-via", "via": "cloud-mobile"})).await;
    assert_eq!(app.created_by(&ran).await, json!({"kind": "script"}));
    // A script naming a workspace: from that workspace.
    let ran = cli.new_session(json!({"name": "ran2", "workspaceId": WORKSPACE})).await;
    assert_eq!(app.created_by(&ran).await, json!({"kind": "script", "workspace": WORKSPACE}));

    // A fork the person makes records none.
    let fork =
        app.ok("session/fork", json!({"sessionId": coord, "cwd": std::env::temp_dir()})).await;
    assert_eq!(app.created_by(fork["sessionId"].as_str().unwrap()).await, Value::Null);
}

/// B serving A as a peer: a start A forwards carries A's own answer.
async fn with_peer() -> (Arc<Hub>, Arc<Hub>) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("created-by-{}", std::process::id()));
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
fn a_start_forwarded_to_a_peer_carries_who_created_it_here() {
    big_stack(async {
        let (a, b) = with_peer().await;
        let mut app = Client::app(&a);
        let mut on_b = Client::script(&b);
        let coord = app.new_session(json!({"name": "coord", "workspaceId": WORKSPACE})).await;
        // A's agent starts a chat on B: B records that agent.
        let mut agent = Client::as_session(&a, &coord).await;
        let child = agent.new_session(json!({"peer": "b", "name": "child"})).await;
        assert_eq!(
            on_b.created_by(&child).await,
            json!({"kind": "agent", "workspace": WORKSPACE, "session": coord}),
        );
        // A's app: the person. A's CLI, claiming an agent: a script.
        let child = app.new_session(json!({"peer": "b", "name": "by-app"})).await;
        assert_eq!(on_b.created_by(&child).await["kind"], "person");
        let mut cli = Client::script(&a);
        let child = cli
            .new_session(json!({"peer": "b", "name": "by-cli", "createdBy": {"kind": "agent"}}))
            .await;
        assert_eq!(on_b.created_by(&child).await, json!({"kind": "script"}));

        // A's agent dispatches a brief to B (as a workflow's `on: b` activity does): B's
        // session for it records that agent too.
        let sent = agent.ok("_acpmux/dispatch", json!({"brief": "echo hi", "host": "b"})).await;
        let sid = sent["brief"]["sessionId"].as_str().unwrap_or_else(|| panic!("{sent}"));
        assert_eq!(
            on_b.created_by(sid).await,
            json!({"kind": "agent", "workspace": WORKSPACE, "session": coord}),
        );
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
