//! A no-prompt preset the person approved once runs the chats agents start from it on another
//! machine with no prompt there; until then the start is refused and the starter's chat shows a
//! card to approve it (`hub/unattended_presets.rs`).
//!
//! Leo (2026-11-09): "A no-prompt preset approved once in the cmux app would let those sessions
//! run without anyone watching." "yeah we should have that too"

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

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

impl Client {
    /// The unix socket with no caller.
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The person's app on `hub`, which holds [`PERSON_KEY`]: `initialize`, then the proof.
    async fn person(hub: &Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let mut c = Self::new(hub);
        let init = c.ok("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = c.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(proved["person"], true, "{proved}");
        c
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

/// B's WebSocket listener: with a peer token B serves A as a peer, without one as a remote
/// client. Returns B's port and its peer token.
async fn listen(b: Arc<Hub>, tag: &str, peer: bool) -> (u16, Option<String>) {
    let home = std::env::temp_dir().join(format!("uap-{tag}-{}", std::process::id()));
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
    new_params(meta)
}

/// The first record of `kind` in chat `id` (its `msg`, or the record itself).
async fn record(app: &mut Client, id: &str, kind: &str) -> Option<Value> {
    let history = app.ok("_acpmux/events", json!({"sessionId": id, "kinds": [kind]})).await;
    fn find(v: &Value, kind: &str) -> Option<Value> {
        match v {
            Value::Object(o) if o.get("kind").and_then(Value::as_str) == Some(kind) => {
                Some(o.get("msg").cloned().unwrap_or_else(|| v.clone()))
            }
            Value::Object(o) => o.values().find_map(|x| find(x, kind)),
            Value::Array(a) => a.iter().find_map(|x| find(x, kind)),
            _ => None,
        }
    }
    find(&history, kind)
}

const PRESET: &str = "unattended";

#[test]
fn an_approved_no_prompt_preset_starts_unattended_chats_on_another_machine() {
    big_stack(async {
        let (a, b) = with_peer("approve", true).await;
        let mut app = Client::person(&a).await;
        let mut on_b_app = Client::new(&b);
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "approve-all"}}),
        )
        .await;
        let asking = starter(&mut app, "ask", "strict").await;
        let mut agent = Client::as_session(&a, &asking).await;
        // Not approved yet: refused, nothing started, and the starter's chat asks the person.
        let r = agent.call("session/new", on_b(json!({"preset": PRESET}))).await;
        assert_eq!(r["error"]["data"]["reason"], "preset.approval_required", "{r}");
        let card = record(&mut app, &asking, "preset_approval_request").await.expect("a card");
        assert_eq!(card["preset"], PRESET, "{card}");
        assert_eq!(card["policy"], "approve-all", "{card}");
        assert_eq!(card["host"], "b", "{card}");
        let digest = card["digest"].as_str().expect("a digest").to_owned();
        // Only the person approves: an agent's own approval, with the card's digest, is refused.
        let own = agent
            .call(
                "_acpmux/presets",
                json!({"name": PRESET, "approveMode": true, "approveDigest": digest, "sessionId": asking}),
            )
            .await;
        assert_eq!(own["error"]["data"]["reason"], "permission.person_required", "{own}");
        // An agent's Not now narrows, but never closes the person's card (review 3 F3).
        agent
            .ok(
                "_acpmux/presets",
                json!({"name": PRESET, "approveMode": false, "approveDigest": digest, "sessionId": asking}),
            )
            .await;
        assert!(
            record(&mut app, &asking, "preset_approval_decision").await.is_none(),
            "an agent closed the card"
        );
        // An answer for other contents approves nothing.
        let stale = app
            .call(
                "_acpmux/presets",
                json!({"name": PRESET, "approveMode": true, "approveDigest": "0", "sessionId": asking}),
            )
            .await;
        assert!(
            stale["error"]["message"].as_str().unwrap_or_default().contains("changed"),
            "{stale}"
        );
        // Approve, as the card does: the card closes and the same start now runs approve-all on B.
        let view = app
            .ok(
                "_acpmux/presets",
                json!({"name": PRESET, "approveMode": true, "approveDigest": digest, "sessionId": asking}),
            )
            .await;
        assert_eq!(view["policyApproved"], true, "{view}");
        let decision = record(&mut app, &asking, "preset_approval_decision").await.expect("closed");
        assert_eq!(decision["outcome"], "approved", "{decision}");
        let child = id(&agent.ok("session/new", on_b(json!({"preset": PRESET}))).await);
        assert_eq!(on_b_app.level(&child).await.1, json!("approve-all"), "unattended on B");
        // A field of the agent's own (a route) keeps the approval from applying (review 3 F2).
        let r = agent.call("session/new", on_b(json!({"preset": PRESET, "route": "r1"}))).await;
        if r.get("error").is_none() {
            assert_ne!(on_b_app.level(&id(&r["result"])).await.1, json!("approve-all"), "{r}");
        }
        // Any change to the preset drops the approval.
        app.ok("_acpmux/presets", json!({"name": PRESET, "set": {"model": "m1"}})).await;
        let r = agent.call("session/new", on_b(json!({"preset": PRESET}))).await;
        assert_eq!(r["error"]["data"]["reason"], "preset.approval_required", "{r}");
    });
}

/// The lines of the unattended runs log (`<acpmux home>/unattended-presets.jsonl`) about chat
/// `id`: those it started or asked from, and the approvals its card sent.
fn logged(id: &str) -> Vec<Value> {
    let path = acpmux::config::home().join("unattended-presets.jsonl");
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|l| l["caller"] == id || l["sessionId"] == id)
        .collect()
}

/// #39876 (from #39318): what ran with no one watching can be read afterwards. Every start that
/// asked, every approval and withdrawal, and every start an approval let run unattended is one
/// line in the owner-only log.
#[test]
fn every_unattended_start_and_approval_is_logged() {
    big_stack(async {
        let (a, _b) = with_peer("log", true).await;
        let mut app = Client::person(&a).await;
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "approve-all"}}),
        )
        .await;
        let asking = starter(&mut app, "ask", "strict").await;
        let mut agent = Client::as_session(&a, &asking).await;
        let r = agent.call("session/new", on_b(json!({"preset": PRESET}))).await;
        assert_eq!(r["error"]["data"]["reason"], "preset.approval_required", "{r}");
        let digest =
            record(&mut app, &asking, "preset_approval_request").await.expect("a card")["digest"]
                .as_str()
                .expect("a digest")
                .to_owned();
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "approveMode": true, "approveDigest": digest, "sessionId": asking}),
        )
        .await;
        let child = id(&agent.ok("session/new", on_b(json!({"preset": PRESET}))).await);
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "approveMode": false, "approveDigest": digest, "sessionId": asking}),
        )
        .await;
        let lines = logged(&asking);
        let events: Vec<&str> = lines.iter().filter_map(|l| l["event"].as_str()).collect();
        assert_eq!(events, ["asked", "approved", "started", "withdrawn"], "{lines:?}");
        assert_eq!(lines[0]["host"], "b", "{lines:?}");
        assert_eq!(lines[1]["person"], true, "{lines:?}");
        assert_eq!(lines[2]["sessionId"], child, "{lines:?}");
        assert_eq!(lines[2]["digest"], digest, "{lines:?}");
        assert!(
            lines.iter().all(|l| l["preset"] == PRESET && l["at"].as_u64().is_some()),
            "{lines:?}"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let path = acpmux::config::home().join("unattended-presets.jsonl");
            let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "the log is owner-only");
        }
    });
}

/// #39916 (F1 of #39884's review): an approval whose config save fails changed nothing, so the
/// log says nothing about it.
#[test]
fn an_approval_that_is_not_saved_is_not_logged() {
    big_stack(async {
        let (a, _b) = with_peer("unsaved", true).await;
        let mut app = Client::person(&a).await;
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "approve-all"}}),
        )
        .await;
        // The log's home exists, as a daemon's does; the config file is a directory, so the
        // save's rename onto it fails.
        std::fs::create_dir_all(acpmux::config::home()).unwrap();
        let dir = std::env::temp_dir().join(format!("acpmux-unsaved-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("config.json")).unwrap();
        a.config.write().await.path = Some(dir.join("config.json"));
        let id = "unsaved-approval";
        let r = app
            .call("_acpmux/presets", json!({"name": PRESET, "approveMode": true, "sessionId": id}))
            .await;
        let _ = std::fs::remove_dir_all(&dir);
        assert!(r["error"]["message"].as_str().unwrap_or("").contains("save config"), "{r}");
        assert_eq!(logged(id), Vec::<Value>::new());
    });
}

#[test]
fn an_approved_preset_with_an_env_is_refused_on_another_machine() {
    big_stack(async {
        let (a, _b) = with_peer("env", true).await;
        let mut app = Client::person(&a).await;
        app.ok(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "approve-all",
                   "env": {"X": "1"}}, "approveMode": true}),
        )
        .await;
        let asking = starter(&mut app, "ask", "strict").await;
        let mut agent = Client::as_session(&a, &asking).await;
        let r = agent.call("session/new", on_b(json!({"preset": PRESET}))).await;
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("stay on this machine"), "{r}");
    });
}

#[tokio::test]
async fn approving_needs_a_mode_or_a_policy_that_does_not_ask() {
    let hub = hub();
    let mut app = Client::person(&hub).await;
    let r = app
        .call(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "ask"}, "approveMode": true}),
        )
        .await;
    assert!(
        r["error"]["message"].as_str().unwrap_or_default().contains("no mode or policy"),
        "{r}"
    );
    // Approve-reads still asks for writes, so a chat from it would still wait: no no-prompt preset
    // (review 5 F2 of #39333).
    let r = app
        .call(
            "_acpmux/presets",
            json!({"name": PRESET, "set": {"harness": "fake", "policy": "approve-reads"}, "approveMode": true}),
        )
        .await;
    assert!(
        r["error"]["message"].as_str().unwrap_or_default().contains("no mode or policy"),
        "{r}"
    );
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
