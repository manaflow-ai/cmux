//! A policy raise the person approved in another machine's app (`hub/person/policy_grant.rs`):
//! the daemon that owns the chat counts it only with a proof made with its own person key (or an
//! enrolled Mac's signature) over a challenge it issued. A peer link, a forwarding daemon's own
//! person, a forged marker or a replayed proof count for nothing.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::hub::person::policy_grant::{CHALLENGE_FIELD, NONCE_FIELD, PROOF_FIELD};
use acpmux::hub::person::{TRANSPORT_UNIX, person_proof, policy_proof};
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    ConnAuth, Origin, WsAuth, bind_ws, serve_connection, serve_connection_authed, serve_ws_with,
};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The key of the daemon that owns the chat (B): the person's app holds it.
const B_KEY: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";
/// The key of the person's own Mac daemon (A), which forwards the raise.
const A_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const RAISED: &str = "approve-edits";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "webRoots": [std::env::temp_dir()],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One connection, kept open: requests go out in order and each answer is read whole.
struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    fn open(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> C {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        C { tx: in_tx, rx: out_rx, next: 0 }
    }

    /// The unix socket, proven as the person with `key` (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>, key: &str) -> C {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let init = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = person_proof(
            key,
            TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

/// A chat on `hub`, made by its own person; its id.
async fn chat(hub: &Arc<Hub>, name: &str) -> String {
    let mut c = C::person(hub, B_KEY).await;
    let r = c
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await;
    r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
}

fn policy_of(hub: &Arc<Hub>, id: &str) -> Option<String> {
    hub.resolve(id).unwrap().meta().permission_policy.clone()
}

fn challenge_of(r: &Value) -> Value {
    r["error"]["data"][CHALLENGE_FIELD].clone()
}

/// `_acpmux/set_policy` of `session` to `policy`, proved with `key` for `challenge`.
fn raise(session: &str, policy: &str, key: &str, challenge: &Value) -> Value {
    let nonce = challenge["nonce"].as_str().unwrap();
    let proof = policy_proof(
        key,
        challenge["personInstance"].as_str().unwrap(),
        challenge["sessionId"].as_str().unwrap(),
        policy,
        nonce,
    )
    .unwrap();
    json!({"sessionId": session, "policy": policy, "_meta": {"acpmux": {NONCE_FIELD: nonce, PROOF_FIELD: proof}}})
}

#[tokio::test]
async fn over_a_peer_link_only_the_owning_daemons_key_raises_and_only_once() {
    let b = hub();
    b.person.install_spawn_key(B_KEY).unwrap();
    let id = chat(&b, "grant-direct").await;
    let other = chat(&b, "grant-other").await;
    let mut link = C::open(&b, Origin::Peer, ConnAuth::PeerToken);

    // Unproved: refused as before, with a challenge for this chat on this run.
    let r = link.call(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": RAISED})).await;
    let challenge = challenge_of(&r);
    assert_eq!(challenge["sessionId"], id.as_str(), "{r}");
    assert_eq!(challenge["personInstance"], b.person.instance(), "{r}");
    assert_ne!(policy_of(&b, &id).as_deref(), Some(RAISED));

    // A narrowing needs nothing and gets no challenge.
    let r = link.call(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "deny-all"})).await;
    assert!(r.get("error").is_none(), "{r}");

    // Forged: the forwarding daemon's own key, another policy, another chat, a made-up nonce,
    // and the old per-link owner marker. None counts, none spends the challenge.
    let mut made_up = challenge.clone();
    made_up["nonce"] = json!("5a".repeat(32));
    for params in [
        raise(&id, RAISED, A_KEY, &challenge),
        {
            let mut p = raise(&id, "approve-reads", B_KEY, &challenge);
            p["policy"] = json!(RAISED);
            p
        },
        raise(&other, RAISED, B_KEY, &challenge),
        raise(&id, RAISED, B_KEY, &made_up),
        json!({"sessionId": id, "policy": RAISED, "_meta": {"acpmux": {
            "ownerPolicyGrant": true, "ownerPolicyHost": "mac", "ownerPolicyProof": "00",
            "ownerPolicyNonce": "22".repeat(32)}}}),
    ] {
        let r = link.call(method::MUX_SET_POLICY, params.clone()).await;
        assert!(r.get("error").is_some(), "{params}: {r}");
        assert_ne!(policy_of(&b, &id).as_deref(), Some(RAISED), "{params}");
        assert_ne!(policy_of(&b, &other).as_deref(), Some(RAISED), "{params}");
    }

    // The person's proof counts once.
    let proved = raise(&id, RAISED, B_KEY, &challenge);
    let r = link.call(method::MUX_SET_POLICY, proved.clone()).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(policy_of(&b, &id).as_deref(), Some(RAISED));

    // Sent again (a capture replayed, on this link or another): refused.
    link.call(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "ask"})).await;
    let mut again = C::open(&b, Origin::Peer, ConnAuth::PeerToken);
    let r = again.call(method::MUX_SET_POLICY, proved).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_eq!(policy_of(&b, &id).as_deref(), Some("ask"));
}

#[tokio::test]
async fn a_unix_socket_client_that_is_not_the_person_needs_the_same_proof() {
    let b = hub();
    b.person.install_spawn_key(B_KEY).unwrap();
    let id = chat(&b, "grant-socket").await;
    // An agent of this daemon, on its socket, without the person key.
    let mut agent = C::open(&b, Origin::Local, ConnAuth::LocalSocket);
    let r = agent.call(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": RAISED})).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let challenge = challenge_of(&r);
    let r = agent.call(method::MUX_SET_POLICY, raise(&id, RAISED, A_KEY, &challenge)).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_ne!(policy_of(&b, &id).as_deref(), Some(RAISED));
}

/// B's WebSocket listener with a peer token (`server/peer_auth.rs`): its port and the token.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("grant-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

/// #26987's own flow: the person on Mac A raises a chat on peer B. A's person proves nothing to
/// B; B's challenge comes back through A, the app proves it with B's key, and B counts it once.
#[tokio::test]
async fn the_person_on_the_mac_raises_a_peer_chat_with_the_peers_challenge() {
    let b = hub();
    b.person.install_spawn_key(B_KEY).unwrap();
    let id = chat(&b, "grant-mesh").await;
    let a = hub();
    a.person.install_spawn_key(A_KEY).unwrap();
    let (port, token) = listen_with_peer_token(b.clone(), "mesh").await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut app = C::person(&a, A_KEY).await;

    let r = app
        .call(method::MUX_SET_POLICY, json!({"session": "b/grant-mesh", "policy": RAISED}))
        .await;
    let challenge = challenge_of(&r);
    assert_eq!(challenge["sessionId"], id.as_str(), "{r}");
    assert_ne!(policy_of(&b, &id).as_deref(), Some(RAISED), "A's own person is not B's");

    let proved = raise("b/grant-mesh", RAISED, B_KEY, &challenge);
    let r = app.call(method::MUX_SET_POLICY, proved.clone()).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(policy_of(&b, &id).as_deref(), Some(RAISED));

    app.call(method::MUX_SET_POLICY, json!({"session": "b/grant-mesh", "policy": "ask"})).await;
    let r = app.call(method::MUX_SET_POLICY, proved).await;
    assert!(r.get("error").is_some(), "a replay through A counts for nothing: {r}");
    assert_eq!(policy_of(&b, &id).as_deref(), Some("ask"));
}

/// The chat a proof counted for is the one the raise changes: once counted, a purge of that chat
/// and a rename of another to its id (so the request's key names the other one) change nothing.
/// The request path dispatches with the chat `take_person_policy` returns (`server/requests.rs`).
#[tokio::test]
async fn a_counted_proof_stays_with_its_chat_when_the_key_names_another_chat_later() {
    let b = hub();
    b.person.install_spawn_key(B_KEY).unwrap();
    let first = chat(&b, "grant-first").await;
    let second = chat(&b, "grant-second").await;
    let mut link = C::open(&b, Origin::Peer, ConnAuth::PeerToken);
    let r = link.call(method::MUX_SET_POLICY, json!({"sessionId": first, "policy": RAISED})).await;
    let proved = raise(&first, RAISED, B_KEY, &challenge_of(&r));

    let counted = b.take_person_policy(method::MUX_SET_POLICY, &proved).expect("the proof counts");
    assert_eq!(counted.id, first);
    // Meanwhile: the first chat is purged and the second takes its id as its name.
    b.kill(&b.resolve(&first).unwrap(), true).await.unwrap();
    let other = b.resolve(&second).unwrap();
    b.rename(&other, first.clone()).await.unwrap();
    assert_eq!(b.resolve(&first).unwrap().id, second, "the key now names the second chat");
    // The counted chat is still the first; the proof is spent, so it cannot count for the second.
    assert_eq!(counted.id, first);
    assert!(b.take_person_policy(method::MUX_SET_POLICY, &proved).is_none());
    let r = link.call(method::MUX_SET_POLICY, proved).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_ne!(policy_of(&b, &second).as_deref(), Some(RAISED));
}
