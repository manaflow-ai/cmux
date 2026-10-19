//! Two hubs: B serves WebSocket, A mirrors B as a peer. Everything for B's
//! sessions is driven through A's protocol handler.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, listen_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn config(policy: PermissionPolicy) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = policy;
    cfg
}

async fn hub(cfg: Config) -> Arc<Hub> {
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}
impl C {
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
    async fn wait(&mut self, m: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Notification { method: got, params } = Message::parse(&line).unwrap() {
                let p = params.unwrap_or(Value::Null);
                if got == m && pred(&p) {
                    return p;
                }
            }
        }
    }
}

/// The person key these hubs hold (`hub/person.rs`): each client stands for
/// the person at that machine's app.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await.unwrap();
    // The app's proof of the key for this connection's challenge (`hub/person.rs`).
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
    c
}

/// B's WebSocket listener with a peer token (`server/peer_auth.rs`);
/// returns its port and the token, which A gets as `peerToken`.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("api-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

#[tokio::test]
async fn peer_sessions_are_listed_prompted_and_permission_routed() {
    // B: serves WebSocket with a token, owns the agent.
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "routed").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "remote-one"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();

    // A: mirrors B.
    let a = hub(config(PermissionPolicy::Ask)).await;
    // `wait`: add_peer answers once the first connect settled, with B's
    // sessions already listed on A.
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    // B serves A as a peer, not as a Web client.
    assert_eq!(a.peers()[0]["servedAs"], "peer", "{:?}", a.peers());
    let mut ca = client(a.clone()).await;
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(
        v["sessions"].as_array().unwrap().iter().any(|x| x["name"] == "b/remote-one"),
        "peer session not listed after add_peer settled: {v}"
    );
    // cx-v9k2f: a peer's session carries its lane like a local one.
    let listed = v["sessions"].as_array().unwrap().iter().find(|x| x["name"] == "b/remote-one");
    assert_eq!(listed.unwrap()["lane"]["state"], "idle", "{v}");

    // Prompt through A by the prefixed name; the reply streams to A's client.
    ca.call(method::MUX_ATTACH, json!({"session": "b/remote-one", "limit": 0})).await.unwrap();
    let r = ca
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/remote-one", "prompt": [{"type": "text", "text": "via a"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    assert_eq!(r["peer"], "b");
    let info = ca.call(method::MUX_INFO, json!({"session": remote_id.clone()})).await.unwrap();
    assert_eq!(info["preview"], "echo: via a");

    // Permission raised on B is answered from A.
    ca.next += 1;
    let pid = ca.next;
    ca.tx
        .send(
            Message::request(
                pid,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "ask: rm"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let pending = ca.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == remote_id).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();
    // B allows only from its own person (`hub/person.rs`): a peer forwarding
    // for A's app is not that person, so A's allow is refused there (cx-aocz
    // brings a device-bound proof); A's deny goes through.
    let e = ca
        .call(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes"}),
        )
        .await
        .unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");
    ca.call(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": remote_id, "permissionId": perm, "optionId": "no"}),
    )
    .await
    .unwrap();
    let end = ca
        .wait(method::MUX_EVENT, |p| p["kind"] == "turn_end" && p["sessionId"] == remote_id)
        .await;
    assert_eq!(end["msg"]["stopReason"], "end_turn");

    // Watchers on A get session_changed for the remote session.
    ca.call(method::MUX_WATCH, json!({})).await.unwrap();
    ca.next += 1;
    let pid = ca.next;
    ca.tx
        .send(
            Message::request(
                pid,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "z"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let changed = ca
        .wait(method::MUX_SESSION_CHANGED, |p| {
            p["session"]["sessionId"] == remote_id && p["kind"] == "turn_end"
        })
        .await;
    assert_eq!(changed["peer"], "b");
    assert_eq!(changed["session"]["name"], "b/remote-one");

    // A's status names the peer.
    let st = ca.call(method::MUX_STATUS, json!({})).await.unwrap();
    assert_eq!(st["peers"][0]["name"], "b");
    assert_eq!(st["peers"][0]["connected"], true);
}

/// Two daemons peered both ways (a real pair on 10-14 grew names
/// like `a/b/a/b/.../cycle` to 346k characters): a daemon serves only its own
/// sessions to a peer, both in the watch snapshot and in later changes, so a
/// mirror never comes back as `b/a/cycle` and never nests.
#[tokio::test]
async fn bidirectional_peers_do_not_reexport_mirrored_sessions() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (a_port, a_peer_token) = listen_with_peer_token(a.clone(), "cycle-a").await;
    let (b_port, b_peer_token) = listen_with_peer_token(b.clone(), "cycle-b").await;

    let mut owner = client(a.clone()).await;
    let created = owner
        .call(
            method::SESSION_NEW,
            json!({
                "cwd": std::env::temp_dir(),
                "mcpServers": [],
                "_meta": {"acpmux": {"name": "cycle"}}
            }),
        )
        .await
        .unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();

    a.add_peer(
        "b",
        &format!("ws://127.0.0.1:{b_port}"),
        Some("tok".into()),
        Some(b_peer_token),
        true,
    )
    .await
    .unwrap();
    b.add_peer(
        "a",
        &format!("ws://127.0.0.1:{a_port}"),
        Some("tok".into()),
        Some(a_peer_token),
        true,
    )
    .await
    .unwrap();
    let mut mirror = client(b.clone()).await;

    let rows = |v: &Value| {
        v["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                (
                    s["sessionId"].as_str().unwrap_or("").to_owned(),
                    s["name"].as_str().unwrap_or("").to_owned(),
                )
            })
            .collect::<Vec<_>>()
    };

    // A change after the snapshot travels as `session_changed`, the path that
    // ping-ponged: rename on A, then wait until B shows the new name.
    owner.call(method::MUX_RENAME, json!({"sessionId": id, "newName": "renamed"})).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let b_now = mirror.call(method::MUX_SESSIONS, json!({})).await.unwrap();
        if rows(&b_now).iter().any(|(_, n)| n == "a/renamed") {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "B never mirrored the rename: {b_now}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    // An echo needs one more round trip each way; give it several before
    // taking the public views. Each list must hold exactly one row for the
    // one session, under its exact name.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let a_rows = rows(&owner.call(method::MUX_SESSIONS, json!({})).await.unwrap());
    let b_rows = rows(&mirror.call(method::MUX_SESSIONS, json!({})).await.unwrap());
    assert_eq!(
        a_rows,
        vec![(id.clone(), "renamed".to_owned())],
        "owner re-imported its own session from the peer"
    );
    assert_eq!(
        b_rows,
        vec![(id.clone(), "a/renamed".to_owned())],
        "peer exposed recursive mirrors"
    );
}

#[tokio::test]
async fn watchers_learn_peer_sessions_that_arrive_after_their_snapshot() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let port = free_port();
    tokio::spawn(listen_ws(b.clone(), format!("127.0.0.1:{port}"), "tok".into()));
    let mut cb = client(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "late"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();

    // A client watches A before A knows about B, as a TUI does when it
    // starts the daemon and the ssh tunnel is still opening.
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(v["sessions"].as_array().unwrap().is_empty());
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, false)
        .await
        .unwrap();
    let changed =
        ca.wait(method::MUX_SESSION_CHANGED, |p| p["session"]["sessionId"] == remote_id).await;
    assert_eq!(changed["peer"], "b");
    assert_eq!(changed["session"]["name"], "b/late");

    // Removing the session on B tells A's watcher it is gone.
    cb.call(method::SESSION_DELETE, json!({"sessionId": remote_id.clone()})).await.unwrap();
    ca.wait(method::MUX_SESSION_CHANGED, |p| {
        p["session"]["sessionId"] == remote_id && p["kind"] == "purged"
    })
    .await;
}

#[tokio::test]
async fn waiting_peer_add_answers_after_a_failed_first_attempt() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    // Nothing listens on this port: the first attempt fails at once.
    let port = free_port();
    let started = std::time::Instant::now();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    assert!(started.elapsed() < Duration::from_secs(15), "{:?}", started.elapsed());
    let peers = a.peers();
    assert_eq!(peers[0]["connected"], false);
    assert!(peers[0]["error"].is_string(), "{peers:?}");
}

/// ACP-REMOTE-GUARD P1: a peer proven by its peer token has no mode rule
/// for its own local user, but a request it forwards for its Web client
/// carries `via: web`, and the owning daemon applies the Web's rules on its
/// own fresh state.
#[tokio::test]
async fn a_web_prompt_forwarded_by_a_peer_meets_the_web_rules_on_the_owning_daemon() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "via").await;
    let mut cb = client(b.clone()).await;
    // A local session on B in the fake harness's own mode, which no
    // asking-mode row lists.
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "via-one"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    // A's own user (unix socket on A) prompts through the peer.
    let mut ca = client(a.clone()).await;
    let prompt =
        |text: &str| json!({"sessionId": "b/via-one", "prompt": [{"type": "text", "text": text}]});
    let r = ca.call(method::SESSION_PROMPT, prompt("from a's user")).await;
    assert!(r.is_ok(), "{r:?}");
    // A Web client of A: refused by B.
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        a.clone(),
        in_rx,
        out_tx,
        acpmux::server::Origin::Web,
    ));
    let mut web = C { tx: in_tx, rx: out_rx, next: 0 };
    let r = web.call(method::SESSION_PROMPT, prompt("from a's paired device")).await;
    let err = r.expect_err("a Web prompt to a session that does not ask");
    assert!(err.contains("does not ask"), "{err}");
    let info = cb.call(method::MUX_INFO, json!({"sessionId": remote_id})).await.unwrap();
    assert!(!info.to_string().contains("from a's paired device"), "{info}");
}

/// ACP-REMOTE-GUARD B3: a Web prompt for a key this daemon cannot resolve is
/// refused, and one for a configured peer's session is forwarded and passes
/// when that session asks on its own daemon.
#[tokio::test]
async fn a_web_prompt_for_an_unresolved_key_is_refused_and_one_for_a_peer_session_passes() {
    let mut cfg_b = config(PermissionPolicy::Ask);
    // On B the fake harness's `normal` mode asks.
    cfg_b.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    let b = hub(cfg_b).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "b3").await;
    let mut cb = client(b.clone()).await;
    cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "asks"}}})).await.unwrap();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        a.clone(),
        in_rx,
        out_tx,
        acpmux::server::Origin::Web,
    ));
    let mut web = C { tx: in_tx, rx: out_rx, next: 0 };
    let prompt = |key: &str| json!({"sessionId": key, "prompt": [{"type": "text", "text": "hi"}]});
    // Not a session here and not a peer's.
    let err = web.call(method::SESSION_PROMPT, prompt("no-such-session")).await.unwrap_err();
    assert!(err.contains("no-such-session") || err.contains("not found"), "{err}");
    // A configured peer's session: forwarded, B applies the Web's rules.
    let ok = web.call(method::SESSION_PROMPT, prompt("b/asks")).await.unwrap();
    assert_eq!(ok["stopReason"], "end_turn", "{ok}");
    assert_eq!(ok["peer"], "b", "{ok}");
}

/// The folder-trust gate: A's app pane (LocalApp) prompting a session on B
/// is marked `via: app`, and B holds it until B's folder is trusted. A's own
/// user (its unix socket) is not gated.
#[tokio::test]
async fn an_app_prompt_forwarded_by_a_peer_waits_for_the_owning_daemons_trust() {
    let root = std::env::temp_dir().join(format!("api-tg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("work")).unwrap();
    std::fs::create_dir_all(root.join("home")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let work = root.join("work");
    let b = hub(config(PermissionPolicy::ApproveAll)).await;
    b.set_trust_gate(Some(acpmux::trust::Paths {
        claude_json: root.join("home").join(".claude.json"),
        codex_config: root.join("home").join("config.toml"),
        record: root.join("home").join("trust.json"),
        agent_home: None,
    }));
    let (port, peer_token) = listen_with_peer_token(b.clone(), "trust").await;
    let mut cb = client(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"name": "t1"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let prompt =
        |text: &str| json!({"sessionId": "b/t1", "prompt": [{"type": "text", "text": text}]});
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        a.clone(),
        in_rx,
        out_tx,
        acpmux::server::Origin::LocalApp,
    ));
    let mut app = C { tx: in_tx, rx: out_rx, next: 0 };
    let err = app.call(method::SESSION_PROMPT, prompt("app-before-trust")).await.unwrap_err();
    assert!(err.starts_with("trust.pending"), "{err}");
    let info = cb.call(method::MUX_INFO, json!({"sessionId": remote_id})).await.unwrap();
    assert!(!info.to_string().contains("app-before-trust"), "{info}");
    // A's own user is the peer's to judge: not gated.
    let mut ca = client(a.clone()).await;
    assert!(ca.call(method::SESSION_PROMPT, prompt("a-user")).await.is_ok());
    // Trusted on B (B's own user answers): A's pane prompt goes.
    cb.call("acp.trust.set", json!({"cwd": work, "level": "trusted"})).await.unwrap();
    let r = app.call(method::SESSION_PROMPT, prompt("app-after-trust")).await;
    assert!(r.is_ok(), "{r:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A connection that never proves the person key: what an agent, the CLI or
/// a relay reaches.
async fn plain(h: Arc<Hub>) -> C {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    c
}

/// cx-0q7o slice 2a: an allow for a peer's prompt, sent to this daemon (A),
/// is decided by the peer (B) with B's own person key. A cannot resolve the
/// session, so it forwards a proof-carrying allow and B checks the proof: a
/// proof made with A's key, or none, is refused on B; who answered
/// (`answeredBy`) is recorded only together with a proof that counts.
#[tokio::test]
async fn a_peer_decides_a_relayed_allow_with_its_own_decision_proof() {
    const B_KEY: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    let b = hub(config(PermissionPolicy::Ask)).await;
    b.person.install_spawn_key(B_KEY).unwrap();
    let (port, peer_token) = listen_with_peer_token(b.clone(), "decide").await;
    let mut cb = plain(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "keyed"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut app = client(a.clone()).await;
    let mut relay = plain(a.clone()).await;
    app.call(method::MUX_ATTACH, json!({"sessionId": remote_id, "limit": 0})).await.unwrap();
    app.next += 1;
    let prompt_id = app.next;
    app.tx
        .send(
            Message::request(
                prompt_id,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "ask: rm"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let pending = app.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == remote_id).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().expect("B's decision nonce").to_owned();
    let instance = pending["personInstance"].as_str().expect("B's daemon run").to_owned();
    let respond = |meta: Value| {
        json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes",
               "_meta": {"acpmux": meta}})
    };
    let by = json!({"device": "iphone-1", "feedItem": "feed-1"});

    // The person on A without B's proof: refused on B.
    let e = app.call(method::MUX_PERMISSION_RESPOND, respond(json!({}))).await.unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");
    // A proof made with A's key proves nothing on B.
    let wrong = acpmux::hub::person::decision_proof(
        PERSON_KEY, &instance, &remote_id, &perm, "yes", &nonce,
    )
    .unwrap();
    let e = relay
        .call(
            method::MUX_PERMISSION_RESPOND,
            respond(json!({"decisionNonce": nonce, "personDecision": wrong})),
        )
        .await
        .unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");
    // Who answered, without a proof: refused.
    let e = relay
        .call(method::MUX_PERMISSION_RESPOND, respond(json!({"answeredBy": by})))
        .await
        .unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");

    // B's proof through a relay that is not the person on A: A forwards, B
    // decides, and records who answered.
    let good =
        acpmux::hub::person::decision_proof(B_KEY, &instance, &remote_id, &perm, "yes", &nonce)
            .unwrap();
    relay
        .call(
            method::MUX_PERMISSION_RESPOND,
            respond(json!({"decisionNonce": nonce, "personDecision": good, "answeredBy": by})),
        )
        .await
        .unwrap();
    let decided = app
        .wait(method::MUX_EVENT, |p| {
            p["kind"] == "permission_decision" && p["sessionId"] == remote_id
        })
        .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "yes", "{decided}");
    assert_eq!(decided["msg"]["answeredBy"], by, "{decided}");
}

/// cx-0q7o slice 2b: every answer for a peer's prompt goes to the peer,
/// which is the only one that decides its prompts: a client that is not the
/// person here may deny (as on the peer itself). A forwarded answer carries a
/// hop count, and one past the limit is refused, so two daemons that each
/// think the other has the session cannot pass it back and forth.
#[tokio::test]
async fn every_answer_for_a_peers_prompt_goes_to_the_peer_within_a_hop_limit() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "deny").await;
    let mut cb = plain(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "deny"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut app = client(a.clone()).await;
    let mut relay = plain(a.clone()).await;
    app.call(method::MUX_ATTACH, json!({"sessionId": remote_id, "limit": 0})).await.unwrap();
    app.next += 1;
    let prompt_id = app.next;
    app.tx
        .send(
            Message::request(
                prompt_id,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "ask: rm"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let pending = app.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == remote_id).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();

    let e = relay
        .call(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": remote_id, "permissionId": perm, "optionId": "no",
                   "_meta": {"acpmux": {"peerHops": 8}}}),
        )
        .await
        .unwrap_err();
    assert!(e.contains("hops"), "{e}");
    relay
        .call(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": remote_id, "permissionId": perm, "optionId": "no"}),
        )
        .await
        .unwrap();
    let decided = app
        .wait(method::MUX_EVENT, |p| {
            p["kind"] == "permission_decision" && p["sessionId"] == remote_id
        })
        .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "no", "{decided}");
}

/// A pending prompt that only the person may allow reaches every app that
/// watches the session, also through a peer: a watcher on A that never
/// attached B's session gets `_acpmux/permission_pending` with B's decision
/// nonce and run, so A's app can show it and notify. An allow from a
/// connection that is not the person, without B's proof, is refused on B
/// and the prompt stays pending; B's proof counts.
#[tokio::test]
async fn peered_watcher_sees_a_pending_prompt_and_only_the_persons_proof_allows_it() {
    const B_KEY: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    let b = hub(config(PermissionPolicy::Ask)).await;
    b.person.install_spawn_key(B_KEY).unwrap();
    let (port, peer_token) = listen_with_peer_token(b.clone(), "watchpend").await;
    let mut cb = plain(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "far"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    cb.call(method::MUX_ATTACH, json!({"sessionId": remote_id, "limit": 0})).await.unwrap();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    // A's watcher: watches everything, attaches nothing, is not the person.
    let mut watcher = plain(a.clone()).await;
    watcher.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();

    // The prompt is raised on B by B's own client.
    cb.next += 1;
    let prompt_id = cb.next;
    cb.tx
        .send(
            Message::request(
                prompt_id,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "ask: deploy"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    let pending =
        watcher.wait(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == remote_id).await;
    let perm = pending["permissionId"].as_str().expect("the prompt's id").to_owned();
    let nonce = pending["decisionNonce"].as_str().expect("B's decision nonce").to_owned();
    let instance = pending["personInstance"].as_str().expect("B's daemon run").to_owned();
    assert_eq!(pending["peer"], "b", "{pending}");
    assert_eq!(pending["request"]["toolCall"]["title"], "deploy", "{pending}");

    // Not the person, no proof: refused on B; still pending there.
    let allow = |meta: Value| {
        json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes",
               "_meta": {"acpmux": meta}})
    };
    let e = watcher.call(method::MUX_PERMISSION_RESPOND, allow(json!({}))).await.unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");
    let info = cb.call(method::MUX_INFO, json!({"sessionId": remote_id})).await.unwrap();
    assert_eq!(info["pending"][0]["permissionId"], perm.as_str(), "{info}");

    // The person's proof (made by the app that holds B's key) counts.
    let good =
        acpmux::hub::person::decision_proof(B_KEY, &instance, &remote_id, &perm, "yes", &nonce)
            .unwrap();
    watcher
        .call(
            method::MUX_PERMISSION_RESPOND,
            allow(json!({"decisionNonce": nonce, "personDecision": good})),
        )
        .await
        .unwrap();
    let decided = cb
        .wait(method::MUX_EVENT, |p| {
            p["kind"] == "permission_decision" && p["sessionId"] == remote_id
        })
        .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "yes", "{decided}");
}

/// Prompt bookmarks of a peer's chat live on the daemon that owns it: A forwards both
/// `_acpmux/bookmark_set` and `_acpmux/bookmark_get` to B, which checks the seq in its own log.
#[tokio::test]
async fn a_peer_sessions_bookmarks_are_kept_by_the_daemon_that_owns_it() {
    let b = hub(config(PermissionPolicy::ApproveAll)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "marks").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "marked"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "hi"}]});
    cb.call(method::SESSION_PROMPT, prompt).await.unwrap();
    let page = cb.call(method::MUX_EVENTS, json!({"sessionId": remote_id, "limit": 5000})).await;
    let page = page.unwrap();
    let events = page["events"].as_array().unwrap();
    let seq_of = |kind: &str| events.iter().find(|e| e["kind"] == kind).unwrap()["seq"].clone();
    let (prompt_seq, reply_seq) = (seq_of("user_message"), seq_of("turn_result"));

    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let refused = ca
        .call(
            "_acpmux/bookmark_set",
            json!({"sessionId": remote_id, "seq": reply_seq, "bookmarked": true}),
        )
        .await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("not a prompt")), "{refused:?}");
    let set = ca
        .call(
            "_acpmux/bookmark_set",
            json!({"sessionId": remote_id, "seq": prompt_seq, "bookmarked": true}),
        )
        .await
        .unwrap();
    assert_eq!(set["peer"], "b", "{set}");
    assert_eq!(set["bookmarks"], json!([prompt_seq]), "{set}");
    let got = ca.call("_acpmux/bookmark_get", json!({"sessionId": remote_id})).await.unwrap();
    assert_eq!(got["peer"], "b", "{got}");
    assert_eq!(got["bookmarks"], json!([prompt_seq]), "{got}");
    // B holds it, in its own session.
    let on_b = cb.call("_acpmux/bookmark_get", json!({"sessionId": remote_id})).await.unwrap();
    assert_eq!(on_b["bookmarks"], json!([prompt_seq]), "{on_b}");
    assert!(on_b.get("peer").is_none(), "{on_b}");
}

/// A TCP relay in front of `port` that counts the bytes each way: what
/// crosses the peer link between two daemons. Returns its port and the
/// counters (toward the client, toward the server).
async fn counting_relay(
    port: u16,
) -> (u16, Arc<std::sync::atomic::AtomicU64>, Arc<std::sync::atomic::AtomicU64>) {
    use std::sync::atomic::{AtomicU64, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let down = Arc::new(AtomicU64::new(0));
    let up = Arc::new(AtomicU64::new(0));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_port = l.local_addr().unwrap().port();
    let (d, u) = (down.clone(), up.clone());
    tokio::spawn(async move {
        while let Ok((client, _)) = l.accept().await {
            let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
                continue;
            };
            let (mut cr, mut cw) = client.into_split();
            let (mut sr, mut sw) = server.into_split();
            let (d, u) = (d.clone(), u.clone());
            tokio::spawn(async move {
                let mut buf = vec![0u8; 64 * 1024];
                while let Ok(n) = sr.read(&mut buf).await {
                    if n == 0 || cw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    d.fetch_add(n as u64, Ordering::SeqCst);
                }
            });
            tokio::spawn(async move {
                let mut buf = vec![0u8; 64 * 1024];
                while let Ok(n) = cr.read(&mut buf).await {
                    if n == 0 || sw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    u.fetch_add(n as u64, Ordering::SeqCst);
                }
            });
        }
    });
    (relay_port, down, up)
}

/// Opening a long chat that lives on a peer daemon (cmux server, a remote
/// over ssh) stays within the same payload budget as a local one (cx-2lv1k):
/// the local daemon forwards the pane's `maxBytes` to the owning daemon, so a
/// 5000-turn chat with 4 KB tool outputs crosses the peer link as one page of
/// at most 160 KiB that ends on the newest record. An older page asked with
/// `beforeSeq` is forwarded the same way. Bytes are counted on the link itself.
#[tokio::test]
async fn opening_a_long_peer_chat_stays_within_its_payload_budget_on_the_link() {
    use acpmux::store::EventRecord;
    use std::sync::atomic::Ordering;
    let dir = std::env::temp_dir().join(format!("acpmux-peer-budget-{}", uuid::Uuid::now_v7()));
    let mut cfg = config(PermissionPolicy::ApproveAll);
    cfg.store.mode = StoreMode::Local;
    cfg.store.segment_bytes = 8 * 1024 * 1024;

    // B owns a chat of 5000 turns, written straight into its store.
    let b = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "long"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let mut seq = b.resolve("long").unwrap().meta().last_seq;
    b.shutdown_all().await;
    drop(cb);
    drop(b);
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let output = "x".repeat(4000);
    let mut append = |dir: &str, kind: &str, msg: Value| {
        seq += 1;
        store
            .append(
                &id,
                &EventRecord {
                    seq,
                    at: seq,
                    dir: dir.into(),
                    kind: kind.into(),
                    msg,
                    host_seq: None,
                },
            )
            .unwrap();
    };
    let update = |body: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1", "update": body}});
    for turn in 0..5000 {
        append("mux", "user_message", json!({"text": format!("Question {turn}")}));
        append("mux", "turn_started", json!({}));
        let call = format!("call-{turn}");
        append(
            "in",
            "tool_call",
            update(json!({"sessionUpdate": "tool_call", "toolCallId": call,
            "title": "cat build.log", "kind": "read", "status": "in_progress"})),
        );
        append(
            "in",
            "tool_call_update",
            update(json!({"sessionUpdate": "tool_call_update",
            "toolCallId": call, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": output}}]})),
        );
        append(
            "in",
            "agent_message_chunk",
            update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": format!("Answer {turn}")}})),
        );
        append("mux", "turn_result", json!({"status": "completed"}));
    }
    let last = seq;
    let b = Hub::new(cfg.clone(), store);
    let _ = b.person.install_spawn_key(PERSON_KEY);
    let (port, peer_token) = listen_with_peer_token(b.clone(), "budget").await;
    let (relay, down, up) = counting_relay(port).await;

    // A reaches B through the counting relay.
    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{relay}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let kinds = json!([
        "transcript",
        "available_commands_update",
        "usage_update",
        "config_option_update",
        "secret_request",
        "secret_decision"
    ]);

    let before = down.load(Ordering::SeqCst);
    let att = ca
        .call(
            method::MUX_ATTACH,
            json!({"session": "b/long", "limit": 400, "maxBytes": 128 * 1024,
                "eventStream": true, "kinds": kinds}),
        )
        .await
        .unwrap();
    let link = down.load(Ordering::SeqCst) - before;
    let wire = serde_json::to_string(&att).unwrap().len();
    eprintln!(
        "peer open: {link} bytes on the link, {wire} bytes to the client, {} records, {} bytes on the link in all",
        att["events"].as_array().unwrap().len(),
        down.load(Ordering::SeqCst) + up.load(Ordering::SeqCst)
    );
    assert_eq!(att["peer"], "b");
    assert!(link <= 160 * 1024, "opening sent {} KiB over the peer link", link / 1024);
    assert!(wire <= 160 * 1024, "opening sent {} KiB to the client", wire / 1024);
    let events = att["events"].as_array().unwrap();
    assert_eq!(events.last().unwrap()["seq"], last, "the page ends on the latest record");
    assert!(events.len() >= 6, "the page holds at least the last turn: {}", events.len());
    assert_eq!(att["hasMore"], true);
    // Linking and opening never pull the history: it is about 25 MB.
    assert!(
        down.load(Ordering::SeqCst) <= 512 * 1024,
        "the link carried {} KiB in all",
        down.load(Ordering::SeqCst) / 1024
    );

    // Scrolling up: beforeSeq and maxBytes reach B too.
    let first = events[0]["seq"].as_u64().unwrap();
    let before = down.load(Ordering::SeqCst);
    let older = ca
        .call(
            method::MUX_EVENTS,
            json!({"session": "b/long", "beforeSeq": first, "limit": 400,
                "maxBytes": 64 * 1024, "kinds": kinds}),
        )
        .await
        .unwrap();
    let link = down.load(Ordering::SeqCst) - before;
    let seqs: Vec<u64> =
        older["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert!(!seqs.is_empty(), "an older page has records");
    // Dropping beforeSeq would page from the start of the chat instead.
    assert!(
        *seqs.last().unwrap() + 6 >= first,
        "the older page ends just before {first}: {:?}",
        &seqs[seqs.len().saturating_sub(3)..]
    );
    assert!(
        seqs.iter().all(|s| *s < first),
        "the older page holds only records before {first}: {:?}",
        &seqs[seqs.len().saturating_sub(3)..]
    );
    assert!(link <= 80 * 1024, "an older page sent {} KiB over the peer link", link / 1024);
    assert_eq!(older["hasMore"], true);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A peer daemon that says what it likes (`hub/person.rs` (c)): a WebSocket
/// server that answers `initialize` with `instance` as its daemon run,
/// lists `sessions` on `_acpmux/watch`, then sends each of `pending` as
/// `_acpmux/permission_pending`. Returns its port.
async fn lying_peer(instance: String, sessions: Vec<Value>, pending: Vec<Value>) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let (instance, sessions, pending) =
                (instance.clone(), sessions.clone(), pending.clone());
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "lying", "origin": "peer",
                            "personInstance": instance}}}),
                        method::MUX_WATCH => json!({"sessions": sessions}),
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                    if m == method::MUX_WATCH {
                        // After this daemon took the session list in.
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        for p in &pending {
                            let note =
                                Message::notification(method::MUX_PERMISSION_PENDING, p.clone());
                            let line = note.to_line().trim_end().to_owned();
                            let _ = ws.send(Ws::Text(line.into())).await;
                        }
                    }
                }
            });
        }
    });
    port
}

/// A prompt as a peer's `_acpmux/permission_pending` carries it.
fn peer_prompt(session: &str, permission: &str, instance: &str) -> Value {
    json!({"sessionId": session, "permissionId": permission, "decisionNonce": "n-1",
           "personInstance": instance, "seq": 1,
           "request": {"toolCall": {"title": format!("{permission} text")}, "options": [
               {"optionId": "yes", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]}})
}

/// A's watcher with a session of its own and the lying peer `l` that asks
/// `forged` first, then one prompt that it may relay (`legit`, for its own
/// session `far-1` in its own run `l-run`). Returns every pending prompt the
/// watcher got up to the legit one.
async fn pendings_through_a_lying_peer(
    forged: impl FnOnce(&str, &str) -> Vec<Value>,
) -> Vec<Value> {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = plain(a.clone()).await;
    let own = ca
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let own = own["sessionId"].as_str().unwrap().to_owned();
    let mine = a.person.instance().to_owned();
    let mut pending = forged(&own, &mine);
    pending.push(peer_prompt("far-1", "legit", "l-run"));
    // It lists A's own session as its own too: a claim, never a proof.
    let sessions = vec![
        json!({"sessionId": "far-1", "name": "far"}),
        json!({"sessionId": own, "name": "mine"}),
    ];
    let port = lying_peer("l-run".to_owned(), sessions, pending).await;
    let mut watcher = plain(a.clone()).await;
    watcher.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut got = Vec::new();
    loop {
        let p = watcher.wait(method::MUX_PERMISSION_PENDING, |_| true).await;
        let legit = p["permissionId"] == "legit";
        got.push(p);
        if legit {
            return got;
        }
    }
}

/// A peer's pending prompt for a session of this daemon is never relayed:
/// with this daemon's own nonce, the person's allow of its text would be a
/// proof for the real local prompt.
#[tokio::test]
async fn peer_pending_for_a_local_session_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|own, _| vec![peer_prompt(own, "forged", "l-run")]).await;
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["peer"], "l", "{got:?}");
}

/// A peer's pending prompt in this daemon's own run is never relayed: the
/// app on this host holds this run's key.
#[tokio::test]
async fn peer_pending_with_this_daemons_instance_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|_, mine| vec![peer_prompt("far-1", "forged", mine)]).await;
    assert_eq!(got.len(), 1, "{got:?}");
}

/// A peer's pending prompt for a session it never listed is never relayed.
#[tokio::test]
async fn peer_pending_for_an_unknown_session_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|_, _| vec![peer_prompt("nobody", "forged", "l-run")]).await;
    assert_eq!(got.len(), 1, "{got:?}");
}

/// A peer's prompt for its own session in its own run reaches the watcher,
/// with which peer asks.
#[tokio::test]
async fn peer_pending_legit_is_relayed() {
    let got = pendings_through_a_lying_peer(|_, _| vec![]).await;
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["sessionId"], "far-1", "{got:?}");
    assert_eq!(got[0]["decisionNonce"], "n-1", "{got:?}");
    assert_eq!(got[0]["peer"], "l", "{got:?}");
    assert_eq!(got[0]["via"], "peer", "{got:?}");
}

/// A fake token, assembled so no file holds one.
fn github_token() -> String {
    format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234")
}

/// B's session after a prompt with a pasted token, as A's client lists it,
/// as B's own client lists it, and as A's watcher hears of it live after a
/// second such prompt.
async fn listed_through_a_peer(tag: &str) -> (Value, Value, Value) {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), tag).await;
    let mut cb = client(b.clone()).await;
    let name = format!("secret-{tag}");
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let text = format!("push with {}", github_token());
    cb.call(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
    )
    .await
    .unwrap();

    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    assert_eq!(a.peers()[0]["servedAs"], "peer", "{:?}", a.peers());
    let mut ca = client(a.clone()).await;
    let pick = |v: Value, want: &str| {
        v["sessions"].as_array().unwrap().iter().find(|x| x["name"] == want).cloned().unwrap_or(v)
    };
    let on_a = pick(ca.call(method::MUX_SESSIONS, json!({})).await.unwrap(), &format!("b/{name}"));
    let on_b = pick(cb.call(method::MUX_SESSIONS, json!({})).await.unwrap(), &name);
    ca.call(method::MUX_WATCH, json!({})).await.unwrap();
    let again = format!("again {}", github_token());
    cb.call(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": again}]}),
    )
    .await
    .unwrap();
    let mirrored = format!("b/{name}");
    let changed = ca
        .wait(method::MUX_SESSION_CHANGED, |p| {
            p["session"]["name"] == mirrored.as_str() && p["kind"] == "turn_end"
        })
        .await;
    (on_a, on_b, changed["session"].clone())
}

/// hq#2509: a session's own words reach a peer masked, and B's own client
/// keeps them raw.
#[tokio::test]
async fn a_peer_lists_a_sessions_text_masked_and_the_owning_daemon_keeps_it_raw() {
    let (on_a, on_b, live) = listed_through_a_peer("masked").await;
    let mask = "[GitHub Personal Access Token]";
    assert_eq!(on_a["lastPrompt"], format!("push with {mask}"), "{on_a}");
    assert_eq!(on_a["preview"], format!("echo: push with {mask}"), "{on_a}");
    assert_eq!(on_a["lastMessage"]["text"], format!("echo: push with {mask}"), "{on_a}");
    assert!(!on_a.to_string().contains("ghp_"), "{on_a}");
    assert_eq!(on_b["lastPrompt"], format!("push with {}", github_token()), "{on_b}");
    // A change B sends while A watches is masked too.
    assert_eq!(live["lastPrompt"], format!("again {mask}"), "{live}");
    assert!(!live.to_string().contains("ghp_"), "{live}");
}

/// A fake AWS access key, assembled so no file holds one.
fn aws_key() -> String {
    format!("AK{}{}", "IA", "Z7QLPMN5HHFPXAM2")
}

/// hq#2509: a peer reads B's queued prompt masked, and may not edit one that
/// holds a secret: an edit from the masked text would either write the mask
/// over the secret or, put back, let the peer move the secret where the next
/// summary no longer masks it. A prompt without one it edits as before.
#[tokio::test]
async fn a_peer_may_not_edit_a_queued_prompt_that_holds_a_secret() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "queue").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "queue-edit"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let send = |n: i64, text: &str, prompt_id: &str| {
        Message::request(
            n,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
        )
        .to_line()
    };
    cb.tx.send(send(900, "hang", "p-hang")).await.unwrap();
    let queued = format!("deploy with {} and {} now", github_token(), aws_key());
    cb.tx.send(send(901, &queued, "p-q")).await.unwrap();
    cb.wait("_acpmux/prompt_accepted", |p| p["promptId"] == "p-q" && p["queued"] == true).await;
    cb.tx.send(send(902, "tidy the docs", "p-plain")).await.unwrap();
    cb.wait("_acpmux/prompt_accepted", |p| p["promptId"] == "p-plain" && p["queued"] == true).await;

    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let listed = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    let on_a = listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["name"] == "b/queue-edit")
        .cloned()
        .unwrap();
    let (gh, aws) = ("[GitHub Personal Access Token]", "[AWS access key]");
    assert_eq!(on_a["queue"][0]["prompt"], format!("deploy with {gh} and {aws} now"), "{on_a}");

    // Each would get the secret back to the peer, lose it, or copy it.
    let text = |t: String| json!({"sessionId": "b/queue-edit", "promptId": "p-q", "op": "update", "text": t});
    let attacks = [
        // Moved behind a name whose hex the next summary does not mask.
        text(format!("commit: {gh}")),
        // Two masks swapped.
        text(format!("deploy with {aws} and {gh} now")),
        // One mask repeated across blocks.
        json!({"sessionId": "b/queue-edit", "promptId": "p-q", "op": "update",
               "prompt": [{"type": "text", "text": format!("a {gh}")}, {"type": "text", "text": format!("b {gh}")}]}),
        // Even keeping every mask in place.
        text(format!("deploy with {gh} and {aws} now please")),
    ];
    for edit in attacks {
        let refused = ca.call("_acpmux/queue_edit", edit.clone()).await;
        let e = refused.expect_err(&format!("a peer edited a prompt with a secret: {edit}"));
        assert!(e.contains("masked secret"), "{e}");
    }
    let on_b = cb.call(method::MUX_INFO, json!({"session": id.clone()})).await.unwrap();
    assert_eq!(on_b["queue"][0]["prompt"], queued, "{on_b}");

    let plain = json!({"sessionId": "b/queue-edit", "promptId": "p-plain", "op": "update", "text": "tidy the docs please"});
    let edited = ca.call("_acpmux/queue_edit", plain).await.unwrap();
    assert_eq!(edited["ok"], true, "{edited}");
    let on_b = cb.call(method::MUX_INFO, json!({"session": id.clone()})).await.unwrap();
    assert_eq!(on_b["queue"][1]["prompt"], "tidy the docs please", "{on_b}");
    let cancel = Message::notification(method::SESSION_CANCEL, json!({"sessionId": id}));
    cb.tx.send(cancel.to_line()).await.unwrap();
}
