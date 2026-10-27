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
    /// The whole response to `m` (its error with its data, or its result).
    async fn raw(&mut self, m: &str, p: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
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

/// An agent on A reports to a chat on B through A's peer link (`acpmux send b/chat` in an acpmux
/// session): B records it as that agent's message. B sees neither A's session nor its caller
/// proof, so A names the sender; the person's prompt through A names no one (claude-sr2,
/// 2026-10-24: every remote lane's report read as the person's own words).
#[tokio::test]
async fn a_prompt_an_agent_sends_through_a_peer_names_that_agent_on_the_owning_daemon() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "named").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "coordinator"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let lane = ca.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "codex-lane"}}})).await.unwrap();
    let lane_id = lane["sessionId"].as_str().unwrap().to_owned();

    // The agent in `codex-lane` runs `acpmux send`: its caller token proves the session to A.
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(a.clone(), in_rx, out_tx));
    let mut agent = C { tx: in_tx, rx: out_rx, next: 0 };
    let token = acpmux::hub::person::caller_token(&lane_id);
    let caller = json!({"callerSession": {"sessionId": lane_id, "token": token}});
    agent
        .call(method::INITIALIZE, json!({"protocolVersion": 1, "_meta": {"acpmux": caller}}))
        .await
        .unwrap();
    let report = |id: &str| json!({"sessionId": "b/coordinator", "prompt": [{"type": "text", "text": id}], "_meta": {"acpmux": {"promptId": id}}});
    agent.call(method::SESSION_PROMPT, report("from-lane")).await.unwrap();
    ca.call(method::SESSION_PROMPT, report("from-person")).await.unwrap();

    let page = cb
        .call("_acpmux/events", json!({"sessionId": remote_id, "kinds": ["user_message"]}))
        .await
        .unwrap();
    let messages: Vec<&Value> =
        page["events"].as_array().unwrap().iter().map(|e| &e["msg"]).collect();
    let by_id = |id: &str| *messages.iter().find(|m| m["promptId"] == id).expect(id);
    let stamped = json!({"kind": "agent_message", "from": "fromAgent", "fromName": "codex-lane", "to": remote_id});
    assert_eq!(by_id("from-lane").pointer("/_meta/provenance"), Some(&stamped), "{messages:?}");
    assert!(by_id("from-person").pointer("/_meta/provenance").is_none(), "{messages:?}");
}

/// A person's prompt through a peer (chat multiplayer, `author.rs`): A forwards its `author`, and
/// B, which runs the chat, stamps the `person_message` provenance itself.
#[tokio::test]
async fn a_persons_prompt_through_a_peer_is_recorded_as_theirs_on_the_owning_daemon() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "author").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "shared"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let ana = json!({"id": "tailnet:ana@example.com", "name": "Ana", "node": "ana-mbp"});
    let sent = json!({"sessionId": "b/shared", "prompt": [{"type": "text", "text": "hi"}],
                      "_meta": {"acpmux": {"promptId": "from-ana", "author": ana.clone()}}});
    ca.call(method::SESSION_PROMPT, sent).await.unwrap();

    let page = cb
        .call("_acpmux/events", json!({"sessionId": remote_id, "kinds": ["user_message"]}))
        .await
        .unwrap();
    let message = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| &e["msg"])
        .find(|m| m["promptId"] == "from-ana")
        .expect("her prompt ran on B")
        .clone();
    // One that also names an agent's provenance is refused here, before the forward drops it.
    let agent = json!({"kind": "agent_message", "from": "acp:x", "to": "acp:y", "msgId": "m-1", "threadId": "t-1"});
    let both = json!({"sessionId": "b/shared", "prompt": [{"type": "text", "text": "hi"}],
                      "_meta": {"acpmux": {"promptId": "from-both", "author": ana, "provenance": agent}}});
    let refused = ca.call(method::SESSION_PROMPT, both).await.unwrap_err();
    assert!(refused.contains("never both"), "{refused}");
    let stamped = json!({"kind": "person_message", "from": "tailnet:ana@example.com", "fromName": "Ana", "node": "ana-mbp"});
    assert_eq!(message.pointer("/_meta/provenance"), Some(&stamped), "{message}");
}

/// A teammate's prompt queued through a peer is listed with its author on the peer's session list
/// too (the summary passes as B lists it; only its `prompt` is masked), so a pane on A that opens
/// the chat cold knows the row is hers.
#[tokio::test]
async fn a_peer_lists_a_persons_queued_prompt_with_its_author() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "qauthor").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "shared"}}})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let hang = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hang"}],
                      "_meta": {"acpmux": {"promptId": "p-hang"}}});
    cb.tx.send(Message::request(900, method::SESSION_PROMPT, hang).to_line()).await.unwrap();
    cb.wait("_acpmux/prompt_accepted", |p| p["promptId"] == "p-hang").await;
    cb.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();

    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let ana = json!({"id": "tailnet:ana@example.com", "name": "Ana", "node": "ana-mbp"});
    let sent = json!({"sessionId": "b/shared", "prompt": [{"type": "text", "text": "from ana"}],
                      "_meta": {"acpmux": {"promptId": "from-ana", "author": ana}}});
    ca.tx.send(Message::request(901, method::SESSION_PROMPT, sent).to_line()).await.unwrap();
    cb.wait(method::MUX_SESSION_CHANGED, |p| p["kind"] == "queue" && p["recordKind"] == "queued")
        .await;

    let listed = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    let on_a = listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["name"] == "b/shared")
        .cloned()
        .unwrap();
    assert_eq!(on_a["queue"][0]["promptId"], "from-ana", "{on_a}");
    assert_eq!(on_a["queue"][0]["prompt"], "from ana", "{on_a}");
    assert_eq!(
        on_a["queue"][0]["author"],
        json!({"id": "tailnet:ana@example.com", "name": "Ana"}),
        "{on_a}"
    );
    let cancel = Message::notification(method::SESSION_CANCEL, json!({"sessionId": id}));
    cb.tx.send(cancel.to_line()).await.unwrap();
}

/// Chat presence is this daemon's own (`hub/presence.rs`): a peer's link carries all of that
/// daemon's clients, so it stands for none of them. A's client attached to B's chat gets no
/// participants, B records no one for the link (its visible attach included), and typing or an
/// authored view through the link is refused `presence.peer_unsupported`.
#[tokio::test]
async fn a_peers_link_makes_no_presence_and_typing_through_it_is_refused() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "presence").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "shared"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let attached =
        ca.call("_acpmux/attach", json!({"sessionId": "b/shared", "limit": 0})).await.unwrap();
    assert_eq!(attached["presence"]["participants"], json!([]), "{attached}");
    let author =
        json!({"_meta": {"acpmux": {"author": {"id": "tailnet:ana@example.com", "name": "Ana"}}}});
    for (m, mut params) in [
        ("_acpmux/typing", json!({"sessionId": "b/shared", "on": true})),
        ("_acpmux/view", json!({"sessionId": "b/shared", "visible": true})),
    ] {
        params["_meta"] = author["_meta"].clone();
        let refused = ca.call(m, params).await.unwrap_err();
        assert!(refused.contains("a peer daemon's link carries none"), "{m}: {refused}");
    }
    // B holds no one for the link, though A's client attached showing the chat.
    let held = cb
        .call("_acpmux/attach", json!({"sessionId": remote_id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    assert_eq!(held["presence"]["participants"], json!([]), "{held}");
}

/// A peer added with the dashboard token only serves this daemon's link as Web, not Peer: the
/// link still stands for no one there (`hub/presence.rs`). Typing in that peer's chat is refused
/// here, before it is forwarded, and a visible attach or view through the link records no owner
/// on the peer, before or after the client that sent it leaves.
#[tokio::test]
async fn typing_in_a_chat_on_a_dashboard_token_peer_is_refused_before_forwarding() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, _) = listen_with_peer_token(b.clone(), "presence-web").await;
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "web-shared"}}})).await.unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    ca.call("_acpmux/attach", json!({"sessionId": "b/web-shared", "limit": 0})).await.unwrap();
    let refused = ca.call("_acpmux/typing", json!({"sessionId": "b/web-shared", "on": true})).await;
    assert!(refused.unwrap_err().contains("a peer daemon's link carries none"));
    let held = cb
        .call("_acpmux/attach", json!({"sessionId": remote_id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    assert_eq!(held["presence"]["participants"], json!([]), "{held}");
    ca.call("_acpmux/view", json!({"sessionId": "b/web-shared", "visible": true})).await.unwrap();
    drop(ca);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(a.peers()[0]["connected"], true, "the link outlives its client");
    let held = cb
        .call("_acpmux/attach", json!({"sessionId": remote_id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    assert_eq!(held["presence"]["participants"], json!([]), "{held}");
}

/// A peer that lists a chat under one of this daemon's own raw ids: a client attached to the
/// peer's chat never hears this daemon's presence for its own chat of that id.
#[tokio::test]
async fn a_peer_chat_sharing_a_local_id_never_hears_local_presence() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut local = client(a.clone()).await;
    let own = local
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let own = own["sessionId"].as_str().unwrap().to_owned();
    let sessions = vec![json!({"sessionId": own, "name": "twin"})];
    let says = Lying { instance: json!("l-run"), sessions, ..Lying::default() };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // The peer's chat, once this daemon has its list.
    let mut far = client(a.clone()).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let reply = loop {
        match far.call("_acpmux/attach", json!({"sessionId": "l/twin", "limit": 0})).await {
            Ok(reply) => break reply,
            Err(e) => assert!(tokio::time::Instant::now() < deadline, "never listed: {e}"),
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(reply["presence"]["participants"], json!([]), "{reply}");
    hears_no_local_presence(&mut local, &mut far, &own).await;
}

/// `local` types in its chat `own`; `far`, attached to a peer's chat of the same raw id, hears
/// none of it, up to the reply of a later request.
async fn hears_no_local_presence(local: &mut C, far: &mut C, own: &str) {
    local
        .call("_acpmux/attach", json!({"sessionId": own, "limit": 0, "visible": false}))
        .await
        .unwrap();
    let ana = json!({"id": "tailnet:ana", "name": "Ana"});
    local
        .call(
            "_acpmux/typing",
            json!({"sessionId": own, "on": true, "_meta": {"acpmux": {"author": ana}}}),
        )
        .await
        .unwrap();
    local.wait("_acpmux/presence", |p| p["sessionId"] == own).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    far.next += 1;
    far.tx.send(Message::request(far.next, method::MUX_STATUS, json!({})).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(20), far.rx.recv()).await.unwrap().unwrap();
        assert!(!line.contains("_acpmux/presence"), "{line}");
        if matches!(Message::parse(&line), Ok(Message::Response { id, .. }) if id == far.next) {
            break;
        }
    }
}

/// A chat made on a peer (`session/new` with `_meta.acpmux.peer`) whose id is one of this
/// daemon's own: its creator is subscribed to the peer's chat, never this daemon's presence.
#[tokio::test]
async fn a_chat_made_on_a_peer_under_a_local_id_never_hears_local_presence() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut local = client(a.clone()).await;
    let own = local
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let own = own["sessionId"].as_str().unwrap().to_owned();
    let says =
        Lying { instance: json!("l-run"), created: json!({"sessionId": own}), ..Lying::default() };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut far = client(a.clone()).await;
    let made = far
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"peer": "l"}}}))
        .await
        .unwrap();
    assert_eq!(made["sessionId"], own, "{made}");
    hears_no_local_presence(&mut local, &mut far, &own).await;
    // Its close lets go of the peer's chat only: the local attachment still counts.
    let attached = || a.session_summary(&a.resolve(&own).unwrap())["attached"].clone();
    assert_eq!(attached(), 1);
    drop(far);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(attached(), 1, "a remote close took a local attachment");
}

/// One connection, one raw id, this daemon's chat and a peer's of that id in turn: each switch
/// ends the attachment it replaces, so the local count comes out even, and a prompt to the local
/// chat after the peer's makes the subscription local again (typing allowed, counted).
#[tokio::test]
async fn switching_one_raw_id_between_a_local_and_a_peer_chat_keeps_the_count_even() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut local = client(a.clone()).await;
    let own = local
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let own = own["sessionId"].as_str().unwrap().to_owned();
    let sessions = vec![json!({"sessionId": own, "name": "twin"})];
    let says = Lying { instance: json!("l-run"), sessions, ..Lying::default() };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // Counted from here: the creator's `session/new` holds one attachment of its own.
    let base = a.session_summary(&a.resolve(&own).unwrap())["attached"].as_i64().unwrap();
    let attached =
        || a.session_summary(&a.resolve(&own).unwrap())["attached"].as_i64().unwrap() - base;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while a.resolve_remote("l/twin").is_none() {
        assert!(tokio::time::Instant::now() < deadline, "the peer's chat never arrived");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let local_attach = json!({"sessionId": own, "limit": 0});
    let remote_attach = json!({"sessionId": "l/twin", "limit": 0});

    // Local, then the peer's, then close.
    let mut c = client(a.clone()).await;
    c.call("_acpmux/attach", local_attach.clone()).await.unwrap();
    assert_eq!(attached(), 1);
    c.call("_acpmux/attach", remote_attach.clone()).await.unwrap();
    assert_eq!(attached(), 0, "the peer's chat replaced the local attachment");
    drop(c);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(attached(), 0);

    // The peer's, then a view of the raw id: not this daemon's chat, so nothing is counted.
    let shown = || a.session_summary(&a.resolve(&own).unwrap())["shown"].clone();
    let mut c = client(a.clone()).await;
    c.call("_acpmux/attach", remote_attach.clone()).await.unwrap();
    let hide = json!({"sessionId": own, "visible": false});
    assert!(c.call("_acpmux/view", hide).await.is_err(), "a view of the peer's chat counted here");
    drop(c);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(attached(), 0);
    let mut viewer = client(a.clone()).await;
    viewer.call("_acpmux/attach", local_attach.clone()).await.unwrap();
    assert_eq!(shown(), true, "a visible local client shows the chat");
    drop(viewer);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Local, the peer's, local again, then close.
    let mut c = client(a.clone()).await;
    c.call("_acpmux/attach", local_attach.clone()).await.unwrap();
    c.call("_acpmux/attach", remote_attach.clone()).await.unwrap();
    c.call("_acpmux/attach", local_attach.clone()).await.unwrap();
    assert_eq!(attached(), 1);
    drop(c);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(attached(), 0);

    // The peer's, then a prompt to the local chat: local again, counted, typing allowed.
    let mut c = client(a.clone()).await;
    c.call("_acpmux/attach", remote_attach).await.unwrap();
    let prompt = json!({"sessionId": own, "prompt": [{"type": "text", "text": "hi"}]});
    c.call(method::SESSION_PROMPT, prompt).await.unwrap();
    assert_eq!(attached(), 1);
    c.call("_acpmux/typing", json!({"sessionId": own, "on": true})).await.unwrap();
    c.wait("_acpmux/presence", |p| p["sessionId"] == own).await;
    drop(c);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(attached(), 0);
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

/// Leo, 2026-10-21 ("this literally doesn't work"): the app showed Allow,
/// Always and Deny for a peer chat's asks under approve-reads, and every
/// answer came back "this session's permission settings do not ask before it
/// acts (policy approve-reads); a paired device cannot prompt it or answer
/// its permissions": the peer served this daemon as Web and held the answer
/// to the Web's asking rule. A deny only narrows and now goes through. A
/// group allow from this daemon is never the peer's person (`hub/person.rs`),
/// and the read through this daemon says so before anyone clicks.
#[tokio::test]
async fn a_peer_chats_deny_goes_through_under_approve_reads_and_its_read_refuses_allows() {
    let mut cfg_b = config(PermissionPolicy::ApproveReads);
    // On B the fake harness's `normal` mode asks: only the policy does not.
    cfg_b.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    let b = hub(cfg_b).await;
    let port = free_port();
    tokio::spawn(listen_ws(b.clone(), format!("127.0.0.1:{port}"), "tok".into()));
    let mut cb = client(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "reviewer"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // No peer token: B serves A as a Web client.
    assert_eq!(a.peers()[0]["servedAs"], "remote", "{:?}", a.peers());
    // The turn runs on B (an agent there started it); A's app sees its ask.
    let mut turns = plain(b.clone()).await;
    turns.next += 1;
    let text = json!([{"type": "text", "text": "ask: touch marker"}]);
    let prompt = Message::request(
        turns.next,
        method::SESSION_PROMPT,
        json!({"sessionId": remote_id, "prompt": text}),
    );
    turns.tx.send(prompt.to_line()).await.unwrap();
    let mut app = client(a.clone()).await;
    let mut read = Value::Null;
    for _ in 0..500 {
        let key = json!({"sessionId": remote_id});
        read = app.call(method::MUX_PERMISSION_GROUPS, key).await.unwrap();
        if read["groups"].as_array().into_iter().flatten().any(|g| g["state"] == "pending") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(read["allowRefused"], "permission.person_required", "{read}");
    let groups = read["groups"].as_array().unwrap();
    let group = groups.iter().find(|g| g["state"] == "pending").unwrap();
    let answer = |decision: &str| {
        json!({"sessionId": remote_id, "groupId": group["groupId"], "revision": group["revision"],
               "decisionKey": format!("k-{decision}"), "decision": decision})
    };
    assert!(app.call(method::MUX_PERMISSION_GROUP_RESPOND, answer("allow_once")).await.is_err());
    let r = app.call(method::MUX_PERMISSION_GROUP_RESPOND, answer("deny")).await;
    assert!(r.is_ok(), "a deny through the peer: {r:?}");
    for _ in 0..500 {
        let key = json!({"sessionId": remote_id, "limit": 500});
        let events = cb.call(method::MUX_EVENTS, key).await.unwrap();
        if events.to_string().contains("chose no") {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the agent never heard the deny");
}

#[tokio::test]
async fn a_web_notification_cancel_forwarded_by_a_peer_keeps_web_control() {
    let mut cfg_b = config(PermissionPolicy::Ask);
    cfg_b.web_roots = vec![std::env::temp_dir().to_string_lossy().into_owned()];
    cfg_b.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    let b = hub(cfg_b).await;
    let (b_in, b_rx) = mpsc::channel(64);
    let (b_out, b_tx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        b.clone(),
        b_rx,
        b_out,
        acpmux::server::Origin::Web,
    ));
    let mut web_b = C { tx: b_in, rx: b_tx, next: 0 };
    let session = web_b
        .call(
            method::SESSION_NEW,
            json!({
                "cwd": std::env::temp_dir(),
                "mcpServers": [],
                "_meta": {"acpmux": {"name": "web-cancel"}}
            }),
        )
        .await
        .unwrap();
    let remote_id = session["sessionId"].as_str().unwrap().to_owned();

    let mut cb = client(b.clone()).await;
    cb.call(method::MUX_ATTACH, json!({"sessionId": remote_id, "limit": 0})).await.unwrap();
    let policy = cb
        .call(method::MUX_SET_POLICY, json!({"sessionId": remote_id, "policy": "approve-all"}))
        .await;
    assert!(policy.is_ok(), "{policy:?}");
    cb.next += 1;
    cb.tx
        .send(
            Message::request(
                cb.next,
                method::SESSION_PROMPT,
                json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
            )
            .to_line(),
        )
        .await
        .unwrap();
    cb.wait(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;

    let a = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "cancel-via-peer").await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let (a_in, a_rx) = mpsc::channel(64);
    let (a_out, a_tx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        a,
        a_rx,
        a_out,
        acpmux::server::Origin::Web,
    ));
    let web_a = C { tx: a_in, rx: a_tx, next: 0 };
    web_a
        .tx
        .send(
            Message::notification(method::SESSION_CANCEL, json!({"sessionId": "b/web-cancel"}))
                .to_line(),
        )
        .await
        .unwrap();

    let ended = tokio::time::timeout(
        Duration::from_millis(300),
        cb.wait(method::MUX_EVENT, |p| p["kind"] == "turn_end" && p["sessionId"] == remote_id),
    )
    .await;
    assert!(ended.is_err(), "a Web cancel through a peer ended the turn: {ended:?}");

    cb.tx
        .send(
            Message::notification(method::SESSION_CANCEL, json!({"sessionId": remote_id}))
                .to_line(),
        )
        .await
        .unwrap();
    let ended = cb
        .wait(method::MUX_EVENT, |p| p["kind"] == "turn_end" && p["sessionId"] == remote_id)
        .await;
    assert_eq!(ended["msg"]["stopReason"], "cancelled", "{ended}");
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
        cmux_worktrees: None,
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

/// A TCP relay in front of `port` that keeps every byte the server sends:
/// a WebSocket server's frames are not masked, so B's replies to A read as
/// text there.
async fn recording_relay(port: u16) -> (u16, Arc<std::sync::Mutex<Vec<u8>>>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_port = l.local_addr().unwrap().port();
    let kept = seen.clone();
    tokio::spawn(async move {
        while let Ok((client, _)) = l.accept().await {
            let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
                continue;
            };
            let (mut cr, mut cw) = client.into_split();
            let (mut sr, mut sw) = server.into_split();
            let kept = kept.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 64 * 1024];
                while let Ok(n) = sr.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    kept.lock().unwrap().extend_from_slice(&buf[..n]);
                    if cw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            });
            tokio::spawn(async move {
                let _ = tokio::io::copy(&mut cr, &mut sw).await;
            });
        }
    });
    (relay_port, seen)
}

/// The pane's Trust for a chat on a peer (Leo, 2026-10-21: only `cmux setup
/// trust` on the peer cleared it). The folder is the peer's, so A's app sends
/// `acp.trust.set` for it and A forwards it without looking for the folder on
/// its own disk: B checks the folder itself (one B lacks is refused by B) and
/// records the answer, and the pane's prompt then goes. A's Web client still
/// cannot answer, and a set for no peer's session is still checked on A.
#[tokio::test]
async fn an_app_trust_answer_for_a_peers_folder_is_checked_and_recorded_by_the_peer() {
    let root = std::env::temp_dir().join(format!("api-tp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("work")).unwrap();
    std::fs::create_dir_all(root.join("home")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let work = root.join("work");
    let record = root.join("home").join("trust.json");
    let b = hub(config(PermissionPolicy::ApproveAll)).await;
    b.set_trust_gate(Some(acpmux::trust::Paths {
        claude_json: root.join("home").join(".claude.json"),
        codex_config: root.join("home").join("config.toml"),
        record: record.clone(),
        agent_home: None,
        cmux_worktrees: None,
    }));
    let (port, peer_token) = listen_with_peer_token(b.clone(), "trust-set").await;
    let (relay, from_b) = recording_relay(port).await;
    let mut cb = client(b.clone()).await;
    cb.call(
        method::SESSION_NEW,
        json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"name": "t2"}}}),
    )
    .await
    .unwrap();
    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{relay}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let connect = |origin: acpmux::server::Origin| {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(acpmux::server::serve_connection_with(a.clone(), in_rx, out_tx, origin));
        C { tx: in_tx, rx: out_rx, next: 0 }
    };
    let mut app = connect(acpmux::server::Origin::LocalApp);
    let mut web = connect(acpmux::server::Origin::Web);
    let set = |cwd: &std::path::Path, session: Option<&str>| {
        let mut p = json!({"cwd": cwd, "level": "trusted"});
        if let Some(s) = session {
            p["sessionId"] = json!(s);
        }
        p
    };
    let refused_by_b =
        || String::from_utf8_lossy(&from_b.lock().unwrap()).contains("cwd is refused");

    // A folder that is not on this disk, for the chat on B: A passes it on, and B, which lacks
    // it too, refuses it.
    let elsewhere = root.join("only-on-the-peer");
    let err = app.call("acp.trust.set", set(&elsewhere, Some("b/t2"))).await.unwrap_err();
    assert!(err.starts_with("cwd is refused"), "{err}");
    assert!(refused_by_b(), "A refused the peer's folder itself instead of forwarding it");
    assert!(!record.exists(), "a folder B lacks was recorded");

    // A Web client of A answers nothing, whatever the folder.
    for cwd in [&work, &elsewhere] {
        let err = web.call("acp.trust.set", set(cwd, Some("b/t2"))).await.unwrap_err();
        assert!(err.starts_with("trust.remote"), "{err}");
    }
    assert!(!record.exists(), "a Web client's answer was recorded");

    // With no peer's session named, A still checks the folder on its own disk.
    for session in [None, Some("no-such-chat")] {
        let err = app.call("acp.trust.set", set(&elsewhere, session)).await.unwrap_err();
        assert!(err.starts_with("cwd is refused"), "{err}");
    }

    // B's folder: forwarded, recorded on B, and the pane's prompt goes.
    let prompt =
        |text: &str| json!({"sessionId": "b/t2", "prompt": [{"type": "text", "text": text}]});
    let err = app.call(method::SESSION_PROMPT, prompt("before-trust")).await.unwrap_err();
    assert!(err.starts_with("trust.pending"), "{err}");
    let ok = app.call("acp.trust.set", set(&work, Some("b/t2"))).await.unwrap();
    assert_eq!(ok["peer"], "b", "{ok}");
    assert_eq!(ok["level"], "trusted", "{ok}");
    let on_b = cb.call("acp.trust.get", json!({"cwd": work})).await.unwrap();
    assert_eq!(on_b["level"], "trusted", "{on_b}");
    let r = app.call(method::SESSION_PROMPT, prompt("after-trust")).await;
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

/// What an enrolled Mac signs (`hub/mac_approvers.rs`), written out here so
/// the test states the wire contract: ECDSA P-256 / SHA-256, raw r || s as
/// hex, over the domain and each part after a NUL.
#[allow(clippy::too_many_arguments)]
fn mac_signature(
    key: &ring::signature::EcdsaKeyPair,
    instance: &str,
    mac: &str,
    session: &str,
    permission: &str,
    tool_call: &str,
    option: &str,
    nonce: &str,
    expires: u64,
) -> String {
    let expires = expires.to_string();
    let mut message = b"acpmux-mac-approver-decision-v1".to_vec();
    for part in [instance, mac, session, permission, tool_call, option, nonce, expires.as_str(), ""]
    {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    let sig = key.sign(&ring::rand::SystemRandom::new(), &message).unwrap();
    sig.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Peer-route approvals: the Mac's app signs a one-time Allow for a prompt of
/// a peer (B) that it reaches through its own daemon (A), and only the signed
/// answer crosses the link. B counts it against the Mac key enrolled in its
/// `mac-approvers.json`, once, for that prompt and tool call; an unsigned
/// Allow is refused, a deny from any client counts, and a Mac removed from
/// the file (with the reload `host approvals rm` sends) allows nothing more.
/// The session's policy and mode stay as they were.
#[tokio::test]
async fn a_peer_counts_an_enrolled_macs_signed_one_time_allow_until_it_is_unenrolled() {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let mac =
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
    let public: String = mac.public_key().as_ref().iter().map(|b| format!("{b:02x}")).collect();
    let home = std::env::temp_dir().join(format!("api-mac-file-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let file = home.join(acpmux::hub::mac_approvers::FILE);
    let write = |macs: Value| {
        acpmux::config::write_atomic(&file, json!({"macs": macs}).to_string().as_bytes()).unwrap()
    };
    write(json!([{"id": "mac-1", "publicKey": public, "name": "Leo's Mac"}]));

    let b = hub(config(PermissionPolicy::Ask)).await;
    b.person.macs.open(file.clone());
    let (port, peer_token) = listen_with_peer_token(b.clone(), "macs").await;
    let mut cb = plain(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "mac"}}}),
        )
        .await
        .unwrap();
    let remote_id = s["sessionId"].as_str().unwrap().to_owned();
    let before = cb.call(method::MUX_INFO, json!({"sessionId": remote_id})).await.unwrap();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut app = client(a.clone()).await;
    let mut relay = plain(a.clone()).await;
    app.call(method::MUX_ATTACH, json!({"sessionId": remote_id, "limit": 0})).await.unwrap();
    let ask = async |app: &mut C, text: &str, after: Option<&str>| {
        app.next += 1;
        let line = Message::request(
            app.next,
            method::SESSION_PROMPT,
            json!({"sessionId": remote_id, "prompt": [{"type": "text", "text": text}]}),
        );
        app.tx.send(line.to_line()).await.unwrap();
        app.wait(method::MUX_PERMISSION_PENDING, |p| {
            p["sessionId"] == remote_id && after.is_none_or(|a| p["permissionId"] != a)
        })
        .await
    };
    let pending = ask(&mut app, "ask: rm", None).await;
    let perm = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let tool_call = pending["request"]["toolCall"]["toolCallId"].as_str().unwrap().to_owned();
    let exp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 120;
    let respond = |perm: &str, nonce: &str, sig: &str| {
        json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes",
               "_meta": {"acpmux": {"decisionNonce": nonce,
                   "approverDecision": {"approver": "mac-1", "expiresAt": exp, "signature": sig}}}})
    };

    // The person on A, unsigned: refused on B (A holds no key of B's).
    let unsigned = json!({"sessionId": remote_id, "permissionId": perm, "optionId": "yes"});
    let e = app.call(method::MUX_PERMISSION_RESPOND, unsigned).await.unwrap_err();
    assert!(e.contains("approve this on the Mac app"), "{e}");
    // Signed for another tool call: refused.
    let other =
        mac_signature(&mac, &instance, "mac-1", &remote_id, &perm, "t9", "yes", &nonce, exp);
    let e = app.call(method::MUX_PERMISSION_RESPOND, respond(&perm, &nonce, &other)).await;
    assert!(e.unwrap_err().contains("approve this on the Mac app"));
    // The Mac's signature for this prompt and tool call: the allow counts.
    let good =
        mac_signature(&mac, &instance, "mac-1", &remote_id, &perm, &tool_call, "yes", &nonce, exp);
    app.call(method::MUX_PERMISSION_RESPOND, respond(&perm, &nonce, &good)).await.unwrap();
    let decided = app
        .wait(method::MUX_EVENT, |p| {
            p["kind"] == "permission_decision" && p["sessionId"] == remote_id
        })
        .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "yes", "{decided}");

    // Replayed on the next prompt: refused (its nonce and permission are spent).
    let next = ask(&mut app, "ask: again", Some(&perm)).await;
    let perm2 = next["permissionId"].as_str().unwrap().to_owned();
    let nonce2 = next["decisionNonce"].as_str().unwrap().to_owned();
    let e = app.call(method::MUX_PERMISSION_RESPOND, respond(&perm2, &nonce, &good)).await;
    assert!(e.unwrap_err().contains("approve this on the Mac app"));

    // Unenrolled (`host approvals rm`: the file, then the reload): a fresh,
    // valid signature counts nothing; a deny from a client that is no person does.
    write(json!([]));
    b.person.macs.view(&json!({"reload": true}));
    let fresh = mac_signature(
        &mac, &instance, "mac-1", &remote_id, &perm2, &tool_call, "yes", &nonce2, exp,
    );
    let e = app.call(method::MUX_PERMISSION_RESPOND, respond(&perm2, &nonce2, &fresh)).await;
    assert!(e.unwrap_err().contains("approve this on the Mac app"));
    relay
        .call(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": remote_id, "permissionId": perm2, "optionId": "no"}),
        )
        .await
        .unwrap();
    let decided = app
        .wait(method::MUX_EVENT, |p| {
            p["kind"] == "permission_decision"
                && p["sessionId"] == remote_id
                && p["msg"]["permissionId"] == perm2
        })
        .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "no", "{decided}");
    let after = cb.call(method::MUX_INFO, json!({"sessionId": remote_id})).await.unwrap();
    assert_eq!(after["policy"], before["policy"], "{after}");
    assert_eq!(after["modes"], before["modes"], "{after}");
    let _ = std::fs::remove_dir_all(&home);
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
    let prompt_seq = seq_of("user_message");
    // Neither a prompt nor an answer (a turn's `turn_result`), which a Pin also marks.
    let other_seq =
        events.iter().find(|e| e["kind"] != "user_message" && e["kind"] != "turn_result").unwrap()
            ["seq"]
            .clone();

    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let refused = ca
        .call(
            "_acpmux/bookmark_set",
            json!({"sessionId": remote_id, "seq": other_seq, "bookmarked": true}),
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

/// No message on a peer link is larger than one frame every acpmux reads (16 MiB). At
/// 2026-10-21 06:23Z a 32.8 MB reply from huge-blue reset cosmic-gray's link with its 29 chats:
/// a history read with no `maxBytes`, 5000 records of a chat with long tool outputs. Here a
/// 33 MB prompt pushed over the link fails alone, with an error; a 60 MB history comes in a page
/// that fits, and a record too large for any message comes as a stub; the link never drops.
#[tokio::test]
async fn a_payload_over_32_mb_fails_alone_and_the_peer_link_stays() {
    use acpmux::store::EventRecord;
    let dir = std::env::temp_dir().join(format!("acpmux-peer-frame-{}", uuid::Uuid::now_v7()));
    let mut cfg = config(PermissionPolicy::ApproveAll);
    cfg.store.mode = StoreMode::Local;
    cfg.store.segment_bytes = 64 * 1024 * 1024;

    // B owns a chat of 40 tool outputs of 1 MB, then one of 20 MB, written straight to its store:
    // no hub runs the chat before B, so no other record lands after them.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let id = uuid::Uuid::now_v7().to_string();
    let meta: acpmux::store::SessionMeta = serde_json::from_value(json!({
        "schema": acpmux::store::META_SCHEMA, "id": id, "name": "big", "harness": "fake",
        "cwd": std::env::temp_dir(), "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let mut seq = 0;
    let mut output = |bytes: usize| {
        seq += 1;
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1",
            "update": {"sessionUpdate": "tool_call_update", "toolCallId": format!("call-{seq}"),
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "x".repeat(bytes)}}]}}});
        let rec = EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "tool_call_update".into(),
            msg,
            host_seq: None,
        };
        store.append(&id, &rec).unwrap();
    };
    for _ in 0..40 {
        output(1024 * 1024);
    }
    output(20 * 1024 * 1024);
    let last = seq;
    let b = Hub::new(cfg.clone(), store);
    let _ = b.person.install_spawn_key(PERSON_KEY);
    let (port, peer_token) = listen_with_peer_token(b.clone(), "frame").await;
    let a = hub(config(PermissionPolicy::ApproveAll)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;

    // A 33 MB prompt for B's chat: refused with an error, never sent as one frame.
    let huge = "y".repeat(33 * 1024 * 1024);
    let refused = ca
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/big", "prompt": [{"type": "text", "text": huge}]}),
        )
        .await
        .expect_err("a 33 MB prompt went over the peer link");
    assert!(refused.contains("too large"), "{refused}");

    // The whole history, asked with no maxBytes: one page that fits in a frame, newest last.
    let att =
        ca.call(method::MUX_ATTACH, json!({"session": "b/big", "limit": 5000})).await.unwrap();
    let wire = serde_json::to_string(&att).unwrap().len();
    assert!(wire < 16 * 1024 * 1024, "the history page was {} MiB", wire >> 20);
    assert_eq!(att["peer"], "b");
    assert_eq!(att["hasMore"], true, "60 MB of history came in one page");
    let events = att["events"].as_array().unwrap();
    assert_eq!(events.last().unwrap()["seq"], last, "the page ends on the latest record");
    // The 20 MB record, too large for any message, is a stub that says what it left out.
    let omitted = &events.last().unwrap()["msg"]["_meta"]["acpmux"]["omitted"];
    assert!(omitted["bytes"].as_u64().unwrap() > 20 * 1024 * 1024, "{omitted}");

    // A live update too large for a frame: B leaves it out of A's link and says so, and A tells
    // its client reading that chat to read it again.
    let mut cb = client(b.clone()).await;
    let live = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "live"}}})).await.unwrap();
    let live = live["sessionId"].as_str().unwrap().to_owned();
    ca.call(method::MUX_ATTACH, json!({"session": "b/live", "limit": 1})).await.unwrap();
    cb.call(
        method::SESSION_PROMPT,
        json!({"sessionId": live, "prompt": [{"type": "text", "text": "big-output:16"}]}),
    )
    .await
    .unwrap();
    ca.wait("_acpmux/lagged", |_| true).await;

    // The link held through all of it: no reconnect, and B still answers.
    let peer = &a.peers()[0];
    assert_eq!(peer["connected"], true, "{peer}");
    assert!(peer["error"].is_null(), "the peer link dropped: {peer}");
    let page = ca
        .call(
            method::MUX_EVENTS,
            json!({"session": "b/big", "beforeSeq": last, "limit": 2, "maxBytes": 4 << 20}),
        )
        .await
        .unwrap();
    assert_eq!(page["events"].as_array().unwrap().len(), 2, "{}", page["hasMore"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// What a lying peer (`lying_peer`) says: `instance` is the daemon run it
/// names at its handshake (null: a build that names none), `sessions` what
/// it lists on `_acpmux/watch`, `pending` the `_acpmux/permission_pending`
/// it sends after that, `detail` any session's `_acpmux/info` and the
/// `session` of its `_acpmux/attach`, `events` the records both its
/// `_acpmux/attach` and `_acpmux/events` answer with, and `live` the
/// `_acpmux/event` records it sends after an attach.
#[derive(Clone, Default)]
struct Lying {
    instance: Value,
    sessions: Vec<Value>,
    pending: Vec<Value>,
    detail: Value,
    events: Vec<Value>,
    live: Vec<Value>,
    /// What `session/new` answers; null: `{}`.
    created: Value,
    /// The `_acpmux/session_changed` params it sends after its pending prompts.
    changed: Vec<Value>,
    /// The error every `_acpmux/permission_group_respond` answers with; null: none.
    refuses: Value,
    /// What every other request answers; null: `{}`.
    answers: Value,
}

/// A peer daemon that says what it likes (`hub/person.rs` (c)): a WebSocket
/// server that answers as `says` has it. Returns its port.
async fn lying_peer(says: Lying) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let says = says.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    if m == method::MUX_PERMISSION_GROUP_RESPOND && !says.refuses.is_null() {
                        let error = serde_json::from_value(says.refuses.clone()).unwrap();
                        let reply = Message::err(id, error).to_line();
                        if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                            return;
                        }
                        continue;
                    }
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "lying", "origin": "peer",
                            "personInstance": says.instance}}}),
                        method::MUX_WATCH => json!({"sessions": says.sessions}),
                        method::MUX_INFO => says.detail.clone(),
                        method::MUX_ATTACH => json!({"session": says.detail,
                            "events": says.events, "hasMore": false}),
                        method::MUX_EVENTS => json!({"events": says.events, "hasMore": false}),
                        method::SESSION_NEW if !says.created.is_null() => says.created.clone(),
                        _ if !says.answers.is_null() => says.answers.clone(),
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                    let notes: Vec<(&str, &Value)> = match m.as_str() {
                        method::MUX_WATCH => {
                            let pending = says.pending.iter();
                            let pending = pending.map(|p| (method::MUX_PERMISSION_PENDING, p));
                            let changed = says.changed.iter();
                            let changed = changed.map(|p| (method::MUX_SESSION_CHANGED, p));
                            pending.chain(changed).collect()
                        }
                        method::MUX_ATTACH => {
                            says.live.iter().map(|p| (method::MUX_EVENT, p)).collect()
                        }
                        _ => continue,
                    };
                    if m == method::MUX_WATCH {
                        // After this daemon took the session list in.
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    }
                    for (kind, p) in notes {
                        let note = Message::notification(kind, p.clone());
                        let line = note.to_line().trim_end().to_owned();
                        let _ = ws.send(Ws::Text(line.into())).await;
                    }
                }
            });
        }
    });
    port
}

/// A prompt as a peer's `_acpmux/permission_pending` carries it.
fn peer_prompt(session: &str, permission: &str, instance: &str) -> Value {
    // Every peer prompt carries a display line its agent wrote (an older peer passes it on): it
    // never reaches this daemon's clients (`hub::drop_display_lines`). The tool's own input, a
    // display-shaped field in it included, reaches them as the peer asks it.
    json!({"sessionId": session, "permissionId": permission, "decisionNonce": "n-1",
           "personInstance": instance, "seq": 1,
           "request": {"toolCall": {"title": format!("{permission} text"),
                                    "rawInput": {"document": {"_meta": {"acpmux": {"display": {"headline": "the tool's own input"}}}}},
                                    "_meta": {"acpmux": {"display": {"headline": "Leo wants to say hi"}}}},
                       "options": [
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
    let says = Lying { instance: json!("l-run"), sessions, pending, ..Lying::default() };
    let port = lying_peer(says).await;
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
    assert!(!got[0].to_string().contains("Leo wants to say hi"), "{got:?}");
    assert!(got[0].to_string().contains("the tool's own input"), "{got:?}");
    assert_eq!(got[0]["sessionId"], "far-1", "{got:?}");
    assert_eq!(got[0]["decisionNonce"], "n-1", "{got:?}");
    assert_eq!(got[0]["peer"], "l", "{got:?}");
    assert_eq!(got[0]["via"], "peer", "{got:?}");
}

/// An ask as a peer's `_acpmux/event` record carries it: a
/// `permission_request` whose `msg` names the daemon run that asks.
fn ask_record(session: &str, permission: &str, instance: &str, seq: u64) -> Value {
    let mut msg = peer_prompt(session, permission, instance);
    msg.as_object_mut().unwrap().remove("sessionId");
    json!({"sessionId": session, "seq": seq, "at": 1, "dir": "mux",
           "kind": "permission_request", "msg": msg})
}

/// What A answers through the lying peer `l` for its session `far-1`.
struct Read {
    info: Value,
    attach: Value,
    events: Value,
}

/// A's `_acpmux/info`, `_acpmux/attach` and `_acpmux/events` for the lying
/// peer `l`'s session `far-1`, whose detail carries one pending ask
/// (`asked`) and whose log holds that ask's record, its answer and one agent
/// message: `runs` gets A's daemon run and names the run the peer claims at
/// its handshake (null: none) and the run the ask carries. Every read
/// answers: the watch rule drops asks, never a session (`Hub::peer_ask_counts`).
async fn detail_through_a_lying_peer(runs: impl FnOnce(&str) -> (Value, String)) -> Read {
    detail_through_a_lying_peer_beside(None, runs).await
}

/// `detail_through_a_lying_peer`, with a second peer `m` connected first
/// when `other` names the daemon run `m` claims at its handshake.
async fn detail_through_a_lying_peer_beside(
    other: Option<&str>,
    runs: impl FnOnce(&str) -> (Value, String),
) -> Read {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    if let Some(other) = other {
        let says = Lying {
            instance: json!(other),
            sessions: vec![json!({"sessionId": "near-1", "name": "near"})],
            ..Lying::default()
        };
        let port = lying_peer(says).await;
        a.add_peer("m", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
            .await
            .unwrap();
    }
    let (instance, asks_in) = runs(a.person.instance());
    let says = Lying {
        instance,
        sessions: vec![json!({"sessionId": "far-1", "name": "far"})],
        detail: json!({"sessionId": "far-1", "name": "far",
                       "pending": [peer_prompt("far-1", "asked", &asks_in)]}),
        events: vec![
            ask_record("far-1", "asked", &asks_in, 1),
            json!({"sessionId": "far-1", "seq": 2, "at": 1, "dir": "mux",
                   "kind": "permission_decision",
                   "msg": {"permissionId": "asked", "outcome": {"outcome": "selected", "optionId": "yes"}}}),
            json!({"sessionId": "far-1", "seq": 3, "at": 1, "dir": "mux",
                   "kind": "turn_result", "msg": {}}),
        ],
        ..Lying::default()
    };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let info = ca.call(method::MUX_INFO, json!({"sessionId": "far-1"})).await;
    let attach = ca.call(method::MUX_ATTACH, json!({"sessionId": "far-1", "limit": 0})).await;
    let events = ca.call(method::MUX_EVENTS, json!({"sessionId": "far-1"})).await;
    Read { info: info.unwrap(), attach: attach.unwrap(), events: events.unwrap() }
}

/// The kinds of `records`, in order.
fn kinds(records: &Value) -> Vec<&str> {
    records.as_array().unwrap().iter().map(|r| r["kind"].as_str().unwrap()).collect()
}

/// The session still reads, without its ask: no pending entry and no
/// `permission_request` record, the agent's other records kept.
fn assert_asks_stripped(read: &Read) {
    let Read { attach, events, .. } = read;
    assert_pending_stripped(read);
    assert_eq!(kinds(&attach["events"]), ["permission_decision", "turn_result"], "{attach}");
    assert_eq!(kinds(&events["events"]), ["permission_decision", "turn_result"], "{events}");
}

/// The session reads with no pending entry: the strict rule.
fn assert_pending_stripped(read: &Read) {
    let Read { info, attach, .. } = read;
    assert_eq!(info["peer"], "l", "{info}");
    assert_eq!(info["sessionId"], "far-1", "{info}");
    assert_eq!(info["pending"], json!([]), "{info}");
    assert_eq!(attach["session"]["sessionId"], "far-1", "{attach}");
    assert_eq!(attach["session"]["pending"], json!([]), "{attach}");
}

/// The ask stays in the log as history, in the run it names, with no nonce:
/// it draws its receipt, and nothing can answer it or prove an allow for it.
fn assert_ask_kept_as_history(read: &Read, run: &str) {
    let Read { attach, events, .. } = read;
    for page in [attach, events] {
        let kept = ["permission_request", "permission_decision", "turn_result"];
        assert_eq!(kinds(&page["events"]), kept, "{page}");
        let ask = &page["events"][0]["msg"];
        assert_eq!(ask["permissionId"], "asked", "{page}");
        assert_eq!(ask["personInstance"], run, "{page}");
        assert!(ask.get("decisionNonce").is_none(), "{page}");
    }
}

/// A peer's session whose detail and log carry an ask from an older run of
/// the peer (it restarted since): the pending ask is dropped, by the rule the
/// watch applies to the peer's `_acpmux/permission_pending` (`hub/peers.rs`),
/// while the log keeps the ask, without its nonce, so the chat still shows
/// what was asked and answered.
#[tokio::test]
async fn peer_detail_keeps_an_older_runs_ask_as_history_without_its_nonce() {
    let read = detail_through_a_lying_peer(|_| (json!("l-run"), "old-run".into())).await;
    assert_pending_stripped(&read);
    assert_ask_kept_as_history(&read, "old-run");
}

/// A peer that names this daemon's run as its own asks nothing here: its
/// session reads without its asks.
#[tokio::test]
async fn peer_detail_from_a_peer_in_this_daemons_run_strips_its_asks() {
    let read = detail_through_a_lying_peer(|mine| (json!(mine), mine.to_owned())).await;
    assert_asks_stripped(&read);
}

/// An ask in a peer's history that names this daemon's run is a forgery of
/// one of this daemon's prompts: dropped, though the peer names a run of its
/// own.
#[tokio::test]
async fn peer_history_ask_naming_this_daemons_run_is_dropped() {
    let read = detail_through_a_lying_peer(|mine| (json!("l-run"), mine.to_owned())).await;
    assert_asks_stripped(&read);
}

/// An ask in a peer's history that names another connected peer's run is
/// that peer's to show, never this one's: dropped.
#[tokio::test]
async fn peer_history_ask_naming_another_peers_run_is_dropped() {
    let read =
        detail_through_a_lying_peer_beside(Some("m-run"), |_| (json!("l-run"), "m-run".into()))
            .await;
    assert_asks_stripped(&read);
}

/// A peer that names no run at its handshake (a build before 6f214158cf1)
/// still opens its chats; its pending asks are dropped, its history keeps
/// them without their nonce.
#[tokio::test]
async fn peer_detail_from_a_peer_with_no_run_keeps_its_asks_only_as_history() {
    let read = detail_through_a_lying_peer(|_| (Value::Null, "l-run".into())).await;
    assert_pending_stripped(&read);
    assert_ask_kept_as_history(&read, "l-run");
}

/// A peer's own session in its own run forwards whole, its ask included.
#[tokio::test]
async fn peer_detail_in_the_peers_own_run_forwards() {
    let Read { info, attach, events } =
        detail_through_a_lying_peer(|_| (json!("l-run"), "l-run".into())).await;
    assert_eq!(info["peer"], "l", "{info}");
    assert_eq!(info["pending"][0]["permissionId"], "asked", "{info}");
    assert_eq!(info["pending"][0]["personInstance"], "l-run", "{info}");
    assert_eq!(attach["session"]["pending"][0]["permissionId"], "asked", "{attach}");
    let whole = ["permission_request", "permission_decision", "turn_result"];
    assert_eq!(kinds(&attach["events"]), whole, "{attach}");
    assert_eq!(attach["events"][0]["msg"]["personInstance"], "l-run", "{attach}");
    assert_eq!(attach["events"][0]["msg"]["decisionNonce"], "n-1", "{attach}");
    assert_eq!(kinds(&events["events"]), whole, "{events}");
}

/// A live ask a peer sends for its attached session in another daemon run
/// never reaches the client, as an event or as a pending prompt; the next
/// ask, in the peer's own run, does.
#[tokio::test]
async fn peer_live_ask_from_another_run_never_reaches_an_attached_client() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    let says = Lying {
        instance: json!("l-run"),
        sessions: vec![json!({"sessionId": "far-1", "name": "far"})],
        detail: json!({"sessionId": "far-1", "name": "far", "pending": []}),
        live: vec![
            ask_record("far-1", "stale", "old-run", 3),
            ask_record("far-1", "fresh", "l-run", 4),
        ],
        ..Lying::default()
    };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    ca.call(method::MUX_ATTACH, json!({"sessionId": "far-1", "limit": 0})).await.unwrap();
    let mut asks = Vec::new();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), ca.rx.recv())
            .await
            .expect("timeout")
            .expect("closed");
        let Message::Notification { method: m, params } = Message::parse(&line).unwrap() else {
            continue;
        };
        let p = params.unwrap_or(Value::Null);
        let permission = match m.as_str() {
            method::MUX_PERMISSION_PENDING => p["permissionId"].clone(),
            method::MUX_EVENT => p["msg"]["permissionId"].clone(),
            _ => continue,
        };
        asks.push((m.clone(), permission.clone()));
        if m == method::MUX_PERMISSION_PENDING && permission == "fresh" {
            break;
        }
    }
    assert!(asks.iter().all(|(_, p)| p == "fresh"), "{asks:?}");
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

/// The harness names in an `_acpmux/models` reply.
fn model_harnesses(v: &Value) -> Vec<String> {
    v["harnesses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["harness"].as_str().unwrap_or("").to_owned())
        .collect()
}

/// A and B list each other as peers. A models read on A lists B's harnesses
/// once, as `b/...`, and returns: before, each daemon asked the other for its
/// whole reply, so the request bounced between them until memory ran out.
async fn mutual_peers_answer_models_once(with_peer_tokens: bool, tag: &str) {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (a_port, a_peer_token) = listen_with_peer_token(a.clone(), &format!("{tag}-a")).await;
    let (b_port, b_peer_token) = listen_with_peer_token(b.clone(), &format!("{tag}-b")).await;
    let (a_token, b_token) =
        if with_peer_tokens { (Some(a_peer_token), Some(b_peer_token)) } else { (None, None) };
    a.add_peer("b", &format!("ws://127.0.0.1:{b_port}"), Some("tok".into()), b_token, true)
        .await
        .unwrap();
    b.add_peer("a", &format!("ws://127.0.0.1:{a_port}"), Some("tok".into()), a_token, true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let mut cb = client(b.clone()).await;
    for (c, me, other) in [(&mut ca, "a", "b"), (&mut cb, "b", "a")] {
        let names = model_harnesses(&c.call("_acpmux/models", json!({})).await.unwrap());
        assert!(names.contains(&"fake".to_owned()), "{me}: {names:?}");
        assert!(names.contains(&format!("{other}/fake")), "{me}: {names:?}");
        assert!(
            !names.iter().any(|n| n.matches('/').count() > 1 || n.starts_with(&format!("{me}/"))),
            "{me} relisted a peer's peers: {names:?}"
        );
    }
    assert_eq!(a.models_fanouts.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn mutual_peers_answer_models_once_as_peers() {
    mutual_peers_answer_models_once(true, "models-peer").await;
}

#[tokio::test]
async fn mutual_peers_answer_models_once_as_web() {
    mutual_peers_answer_models_once(false, "models-web").await;
}

/// A peer from before `localOnly`: on `_acpmux/models` it asks A for A's whole
/// reply over A's WebSocket listener (as Web), then answers with its own
/// harness plus A's rows labelled as its peer's.
async fn legacy_models_peer(a_port: u16) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            tokio::spawn(async move {
                let (mut sink, mut source) = ws.split();
                while let Some(Ok(Ws::Text(text))) = source.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "legacy", "origin": "peer",
                            "personInstance": "legacy-run"}}}),
                        "_acpmux/models" => {
                            let mut req =
                                format!("ws://127.0.0.1:{a_port}").into_client_request().unwrap();
                            req.headers_mut()
                                .insert("authorization", "Bearer tok".parse().unwrap());
                            let (mut back, _) =
                                tokio_tungstenite::connect_async(req).await.unwrap();
                            let ask = Message::request(1, "_acpmux/models", json!({})).to_line();
                            back.send(Ws::Text(ask.trim_end().to_owned().into())).await.unwrap();
                            let mut rows = vec![json!({"harness": "old-agent", "models": []})];
                            while let Some(Ok(Ws::Text(t))) = back.next().await {
                                if let Ok(Message::Response { result: Some(r), .. }) =
                                    Message::parse(&t)
                                {
                                    if r.get("peersOmitted") == Some(&json!(true)) {
                                        rows.push(json!({"harness": "saw-omitted", "models": []}));
                                    }
                                    for mut h in
                                        r["harnesses"].as_array().cloned().unwrap_or_default()
                                    {
                                        h["harness"] = json!(format!(
                                            "a/{}",
                                            h["harness"].as_str().unwrap_or("")
                                        ));
                                        h["peer"] = json!("a");
                                        rows.push(h);
                                    }
                                    break;
                                }
                            }
                            json!({"harnesses": rows})
                        }
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if sink.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

/// With a peer that ignores `localOnly` and asks back, the cycle ends at A:
/// while A asks its peers, a remote asker gets A's own catalog.
#[tokio::test]
async fn a_legacy_peer_that_asks_back_cannot_loop_models() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let (a_port, _) = listen_with_peer_token(a.clone(), "models-legacy").await;
    let old = legacy_models_peer(a_port).await;
    a.add_peer("old", &format!("ws://127.0.0.1:{old}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let names = model_harnesses(&ca.call("_acpmux/models", json!({})).await.unwrap());
    assert!(names.contains(&"fake".to_owned()), "{names:?}");
    assert!(names.contains(&"old/old-agent".to_owned()), "{names:?}");
    // A answered the legacy peer's ask-back from its own catalog, and said so.
    assert!(names.contains(&"old/saw-omitted".to_owned()), "{names:?}");
    assert!(!names.iter().any(|n| n.starts_with("old/a/")), "{names:?}");
    // The top-level asker got every peer; only the nested ask was cut short.
    let again = ca.call("_acpmux/models", json!({})).await.unwrap();
    assert_eq!(again.get("peersOmitted"), None, "{again}");
    assert_eq!(a.models_fanouts.load(std::sync::atomic::Ordering::SeqCst), 0);
}

/// `new --host auto -n NAME` (`cli::place::resolve`): a session of that name
/// already running, here or on a peer, is used only with --reuse, as for
/// `new -n`; without it the launch says where it runs and makes no second one,
/// and a name on two machines is left to --host.
#[tokio::test]
async fn auto_placement_takes_a_running_name_only_with_reuse_here_or_on_a_peer() {
    use acpmux::cli::place::resolve;
    let named = |n: &str| json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": n}}});
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "auto-name").await;
    let mut cb = client(b.clone()).await;
    cb.call(method::SESSION_NEW, named("far")).await.unwrap();
    cb.call(method::SESSION_NEW, named("both")).await.unwrap();
    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::SESSION_NEW, named("near")).await.unwrap();
    ca.call(method::SESSION_NEW, named("both")).await.unwrap();
    // The CLI's own client, on A's unix socket (short: sun_path is ~104 bytes).
    let dir = std::path::PathBuf::from(format!("/tmp/acpmux-auto-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("a.sock");
    let l = acpmux::server::bind_unix(&sock).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(a.clone(), l));
    let cli = acpmux::client::Client::connect(&sock).await.unwrap();

    let here = resolve(&cli, "agent", Some("near"), false).await.unwrap_err().to_string();
    assert!(here.contains("already runs on this machine") && here.contains("--reuse"), "{here}");
    assert_eq!(resolve(&cli, "agent", Some("near"), true).await.unwrap(), None);
    let there = resolve(&cli, "agent", Some("far"), false).await.unwrap_err().to_string();
    assert!(there.contains("already runs on b"), "{there}");
    assert_eq!(resolve(&cli, "agent", Some("far"), true).await.unwrap().as_deref(), Some("b"));
    // On two machines: not guessed at, even with --reuse.
    let two = resolve(&cli, "agent", Some("both"), true).await.unwrap_err().to_string();
    assert!(two.contains("this machine, b") && two.contains("--host"), "{two}");
    // A new name goes to the pick (which a busy test machine may refuse).
    if let Err(e) = resolve(&cli, "agent", Some("fresh"), false).await {
        let e = e.to_string();
        assert!(!e.contains("runs on") && !e.contains("--reuse"), "{e}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// `_acpmux/resolve` (`acpmux resolve`): an agent link, as a PR footer carries it, finds its
/// session by the harness's session id, on this daemon or on a peer, with its metadata; a name
/// finds a peer's session too; a link no daemon knows says where it looked.
#[tokio::test]
async fn an_agent_link_resolves_to_its_session_here_or_on_a_peer() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "resolve").await;
    let mut cb = client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "far-one"}}});
    let far =
        cb.call(method::SESSION_NEW, new).await.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let far_info = cb.call(method::MUX_INFO, json!({"session": far})).await.unwrap();
    let far_agent = far_info["agentSessionId"].as_str().expect("an agent session id").to_owned();

    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "near-one"}}});
    let near =
        ca.call(method::SESSION_NEW, new).await.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let near_info = ca.call(method::MUX_INFO, json!({"session": near})).await.unwrap();
    let near_agent = near_info["agentSessionId"].as_str().expect("an agent session id").to_owned();
    let family = near_info["family"].as_str().unwrap_or("fake").to_owned();

    // A local session, from a whole PR footer line.
    let footer = format!(
        "Agent session: [here](https://cmux.com/deeplink/agent?harness={family}&session={near_agent})"
    );
    let r = ca.call("_acpmux/resolve", json!({"query": footer})).await.unwrap();
    let s = &r["session"];
    assert_eq!(s["sessionId"], near, "{r}");
    assert_eq!(s["name"], "near-one", "{r}");
    assert_eq!(s["peer"], Value::Null, "{r}");
    assert_eq!(s["agentSessionId"], near_agent.as_str(), "{r}");
    assert_eq!(s["cwd"], near_info["cwd"], "{r}");
    assert!(s["status"].is_string() && s["lane"]["state"].is_string(), "{r}");
    assert!(s["pullRequests"].is_array(), "{r}");
    assert!(s["link"].as_str().unwrap().contains(&format!("session={near_agent}")), "{r}");
    // The stand-in agent numbers its sessions, so B's first has the same harness session id:
    // both match, this daemon's first when the link names no host.
    let hosts: Vec<&Value> = r["matches"].as_array().unwrap().iter().map(|m| &m["peer"]).collect();
    assert_eq!(hosts, [&Value::Null, &json!("b")], "{r}");
    assert_eq!(far_agent, near_agent, "the stand-in's ids changed; this test assumes they repeat");

    // A peer's session, from the native link the app opens: the host it names ranks first.
    let native = format!("cmux://agent/{family}/{far_agent}?host=b");
    let r = ca.call("_acpmux/resolve", json!({"query": native})).await.unwrap();
    let s = &r["session"];
    assert_eq!(s["host"], "b", "{r}");
    assert_eq!(s["peer"], "b", "{r}");
    assert_eq!(s["qualifiedSessionId"], format!("b/{far}"), "{r}");
    assert_eq!(s["name"], "b/far-one", "{r}");
    assert_eq!(s["agentSessionId"], far_agent.as_str(), "{r}");

    // By its bare name, from the daemon that only mirrors it.
    let r = ca.call("_acpmux/resolve", json!({"query": "far-one"})).await.unwrap();
    assert_eq!(r["session"]["qualifiedSessionId"], format!("b/{far}"), "{r}");

    // A link no daemon here knows, naming a host that is neither this one nor a peer.
    let unknown =
        format!("https://cmux.com/deeplink/agent?harness={family}&session=nope-1&host=elsewhere");
    let e = ca.call("_acpmux/resolve", json!({"query": unknown})).await.unwrap_err();
    assert!(e.contains("nope-1") && e.contains("peers (b)") && e.contains("elsewhere"), "{e}");
    // A link that names no session is refused as a link.
    let e = ca
        .call("_acpmux/resolve", json!({"query": "https://cmux.com/deeplink/agent?harness=claude"}))
        .await
        .unwrap_err();
    assert!(e.contains("no session"), "{e}");
}

/// hq#2509 for `_acpmux/resolve`: a peer's connection reads a resolved session's own words
/// masked, as it reads them in a session list; the owning daemon's client reads them raw.
#[tokio::test]
async fn a_peer_resolves_a_sessions_text_masked() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let mut cb = client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "secret-resolve"}}});
    let id =
        cb.call(method::SESSION_NEW, new).await.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let text = format!("push with {}", github_token());
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    cb.call(method::SESSION_PROMPT, prompt).await.unwrap();
    let query = json!({"query": "secret-resolve"});
    let raw = cb.call("_acpmux/resolve", query.clone()).await.unwrap();
    assert_eq!(raw["session"]["lastPrompt"], text.as_str(), "{raw}");

    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(
        b.clone(),
        in_rx,
        out_tx,
        acpmux::server::Origin::Peer,
    ));
    let mut peer = C { tx: in_tx, rx: out_rx, next: 0 };
    let r = peer.call("_acpmux/resolve", query).await.unwrap();
    let mask = "[GitHub Personal Access Token]";
    assert!(!r.to_string().contains("ghp_"), "{r}");
    assert_eq!(r["session"]["lastPrompt"], format!("push with {mask}"), "{r}");
    assert_eq!(r["matches"][0]["lastMessage"]["text"], format!("echo: push with {mask}"), "{r}");
}

/// Beads ↔ sessions (`beads.rs`): a bead linked to a peer's session through this daemon (its
/// `bead:<id>` tag, forwarded to the peer) reaches this daemon's mirror, and resolving the bead
/// id finds that session with its beads listed; the session's own card lists them too.
#[tokio::test]
async fn a_bead_linked_to_a_peers_session_resolves_to_it() {
    let b = hub(config(PermissionPolicy::Ask)).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), "beads").await;
    let mut cb = client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "bead-lane"}}});
    let far =
        cb.call(method::SESSION_NEW, new).await.unwrap()["sessionId"].as_str().unwrap().to_owned();

    let a = hub(config(PermissionPolicy::Ask)).await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    let mut watcher = client(a.clone()).await;
    watcher.call(method::MUX_WATCH, json!({})).await.unwrap();

    // Not linked yet: the bead id names no session.
    let e = ca.call("_acpmux/resolve", json!({"query": "cx-ab1.2"})).await.unwrap_err();
    assert!(e.contains("carrying the bead") && e.contains("cx-ab1.2"), "{e}");

    // `acpmux bead link b/bead-lane cx-ab1.2` is this tag, set through A.
    let set = json!({"sessionId": "b/bead-lane", "set": {"bead:cx-ab1.2": "1"}});
    ca.call(method::MUX_TAG, set).await.unwrap();
    watcher
        .wait(method::MUX_SESSION_CHANGED, |p| {
            p["session"]["sessionId"] == far.as_str()
                && p["session"]["tags"].get("bead:cx-ab1.2").is_some()
        })
        .await;

    let r = ca.call("_acpmux/resolve", json!({"query": "cx-ab1.2"})).await.unwrap();
    assert_eq!(r["session"]["qualifiedSessionId"], format!("b/{far}"), "{r}");
    assert_eq!(r["session"]["beads"], json!(["cx-ab1.2"]), "{r}");
    let r = ca.call("_acpmux/resolve", json!({"query": "b/bead-lane"})).await.unwrap();
    assert_eq!(r["session"]["beads"], json!(["cx-ab1.2"]), "{r}");

    // A session named like the bead answers a plain lookup; `bead ls` (bead only) still finds
    // the session carrying it.
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "cx-ab1.2"}}});
    ca.call(method::SESSION_NEW, new).await.unwrap();
    let r = ca.call("_acpmux/resolve", json!({"query": "cx-ab1.2"})).await.unwrap();
    assert_eq!(r["session"]["name"], "cx-ab1.2", "{r}");
    let r = ca.call("_acpmux/resolve", json!({"query": "cx-ab1.2", "bead": true})).await.unwrap();
    assert_eq!(r["session"]["qualifiedSessionId"], format!("b/{far}"), "{r}");
    assert_eq!(r["matches"].as_array().unwrap().len(), 1, "{r}");
}

/// #24337 review: a display line in a peer's reply (its info, attach and events, here a valid ask
/// of its own session in its own run) never reaches this daemon's clients; the ask itself does.
/// A peer's session summary, as its `_acpmux/watch` list or its `session_changed` carries it,
/// keeps no display line of the peer's own on a pending ask (`Hub::remote_summary`): not in
/// `_acpmux/sessions`, not in `_acpmux/watch`, and not in the `session_changed` this daemon
/// sends its watchers. The tool's own input reaches them whole.
#[tokio::test]
async fn a_peers_session_summary_carries_no_display_line() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_WATCH, json!({})).await.unwrap();
    let summary = |permission: &str| {
        json!({"sessionId": "far-1", "name": "far",
               "pending": [peer_prompt("far-1", permission, "l-run")]})
    };
    let says = Lying {
        instance: json!("l-run"),
        sessions: vec![summary("listed")],
        changed: vec![json!({"session": summary("changed"), "kind": "turn_end", "seq": 7})],
        ..Lying::default()
    };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let listed =
        ca.wait(method::MUX_SESSION_CHANGED, |p| p["session"]["sessionId"] == "far-1").await;
    let changed = ca
        .wait(method::MUX_SESSION_CHANGED, |p| {
            p["session"]["sessionId"] == "far-1" && p["kind"] == "turn_end"
        })
        .await;
    let sessions = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    let watch = ca.call(method::MUX_WATCH, json!({})).await.unwrap();
    for reply in [&listed, &changed, &sessions, &watch] {
        let text = reply.to_string();
        assert!(text.contains("far-1"), "{reply}");
        assert!(!text.contains("Leo wants to say hi"), "{reply}");
        assert!(text.contains("the tool's own input"), "{reply}");
    }
    assert!(changed.to_string().contains("changed text"), "{changed}");
}

/// Round 11 of #24337: an error a peer answers with is cleaned as a result is. A stale
/// `_acpmux/permission_group_respond` answer carries the current group, whose requests an older
/// peer passes on with its agent's display line: the line is gone, while the group, the reason
/// and the tool's own input stay.
#[tokio::test]
async fn a_peers_error_carries_no_display_line() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    let ask = peer_prompt("far-1", "asked", "l-run");
    let group = json!({"groupId": "g-1", "revision": 2,
                       "items": [{"permissionId": "asked", "request": ask["request"]}]});
    let says = Lying {
        instance: json!("l-run"),
        sessions: vec![json!({"sessionId": "far-1", "name": "far"})],
        refuses: json!({"code": -32000, "message": "stale_revision",
                        "data": {"reason": "stale_revision", "group": group}}),
        ..Lying::default()
    };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let answer = json!({"sessionId": "far-1", "groupId": "g-1", "revision": 1, "answers": []});
    let reply = ca.raw(method::MUX_PERMISSION_GROUP_RESPOND, answer).await;
    let error = &reply["error"];
    assert_eq!(error["data"]["reason"], "stale_revision", "{reply}");
    assert_eq!(error["data"]["group"]["items"][0]["permissionId"], "asked", "{reply}");
    assert!(!reply.to_string().contains("Leo wants to say hi"), "the peer's display line: {reply}");
    assert!(reply.to_string().contains("the tool's own input"), "{reply}");
}

/// Review 35 of #24337: every reply a peer gives carries no display line of its own, on every
/// route that returns it (here the trust answer, which `peer_forward.rs` returns on its own path).
#[tokio::test]
async fn a_peers_reply_on_every_route_carries_no_display_line() {
    let a = hub(config(PermissionPolicy::Ask)).await;
    let mut ca = client(a.clone()).await;
    let says = Lying {
        instance: json!("l-run"),
        sessions: vec![json!({"sessionId": "far-1", "name": "far"})],
        answers: json!({"pending": [peer_prompt("far-1", "asked", "l-run")]}),
        ..Lying::default()
    };
    let port = lying_peer(says).await;
    a.add_peer("l", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let reply = ca.raw(method::ACP_TRUST_GET, json!({"sessionId": "far-1"})).await;
    assert!(reply.to_string().contains("the tool's own input"), "{reply}");
    assert!(!reply.to_string().contains("Leo wants to say hi"), "the peer's display line: {reply}");
}

#[tokio::test]
async fn a_peers_display_line_never_reaches_a_client() {
    let read = detail_through_a_lying_peer(|_| (json!("l-run"), "l-run".to_owned())).await;
    let Read { info, attach, events } = &read;
    assert_eq!(info["pending"][0]["permissionId"], "asked", "{info}");
    for reply in [info, attach, events] {
        assert!(!reply.to_string().contains("Leo wants to say hi"), "{reply}");
    }
    // The tool's own input is the peer's, kept whole.
    for reply in [info, events] {
        assert!(reply.to_string().contains("the tool's own input"), "{reply}");
    }
}
