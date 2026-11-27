//! An error says what kind of failure it is and how to recover (`recovery.rs`).
//!
//! Leo, 2026-10-22: "we also wanna make sure we have good recoverable/informative disk errors
//! tailscale erros for acpmux". A client got a bare "agent process closed" or the agent's own
//! "No space left on device" with nothing to do about it. Each failure now carries `errorKind`,
//! a `recovery` sentence and the `details` that apply, in the request's error data and in the
//! failed turn's records.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, RpcError, method};
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn harness(argv: Vec<String>) -> HarnessProfile {
    HarnessProfile {
        kind: Default::default(),
        argv,
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

fn hub_with(edit: impl FnOnce(&mut Config)) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert("fake".to_owned(), harness(vec!["python3".into(), fake.into()]));
    agents.insert(
        "missing".to_owned(),
        harness(vec!["/nonexistent/acpmux-typed-errors-no-such-harness".into()]),
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    edit(&mut cfg);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(h: Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        c
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, RpcError> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Ok(Message::Response { id: rid, result, error }) = Message::parse(&line)
                && rid == id
            {
                return match error {
                    Some(e) => Err(e),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }

    async fn session(&mut self, harness: &str, cwd: &std::path::Path) -> Result<String, RpcError> {
        let v = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
            )
            .await?;
        Ok(v["sessionId"].as_str().unwrap().to_owned())
    }

    async fn prompt(&mut self, id: &str, text: &str) -> Result<Value, RpcError> {
        self.call(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }

    /// The session's `lastTurn`, as `_acpmux/sessions` lists it.
    async fn last_turn(&mut self, id: &str) -> Value {
        let v = self.call(method::MUX_SESSIONS, json!({})).await.unwrap();
        let list = v.get("sessions").cloned().unwrap_or(v);
        list.as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id || s["id"] == id)
            .map(|s| s["lastTurn"].clone())
            .unwrap_or(Value::Null)
    }
}

/// A fresh folder for one chat, under the test process's temp directory.
fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("typed-errors-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn data(e: &RpcError) -> Value {
    e.data.clone().unwrap_or(Value::Null)
}

/// An agent that hits a full disk fails its turn as `disk.full`, naming the disk's free space
/// and what to free, in the prompt's error and in `lastTurn`.
#[tokio::test]
async fn typed_error_a_turn_that_hits_a_full_disk_says_how_to_free_space() {
    let dir = scratch("disk");
    let mut c = C::new(hub_with(|_| {})).await;
    let id = c.session("fake", &dir).await.unwrap();
    let e = c
        .prompt(&id, "fail-streamed: failed to write the session file: No space left on device (os error 28)")
        .await
        .expect_err("the turn fails");
    let d = data(&e);
    assert_eq!(d["errorKind"], "disk.full", "{e:?}");
    let recovery = d["recovery"].as_str().unwrap_or_default();
    assert!(recovery.contains("Free space on the disk that holds"), "{recovery}");
    assert!(recovery.contains(" GB free of "), "{recovery}");
    assert!(d.pointer("/details/freeBytes").and_then(Value::as_u64).is_some(), "{d}");
    assert!(d.pointer("/details/totalBytes").and_then(Value::as_u64).is_some(), "{d}");
    assert!(d.pointer("/details/path").and_then(Value::as_str).is_some(), "{d}");
    assert!(e.message.contains("No space left on device"), "the message stays whole: {e:?}");

    let last = c.last_turn(&id).await;
    assert_eq!(last["status"], "failed", "{last}");
    assert_eq!(last["errorKind"], "disk.full", "{last}");
    assert_eq!(last["recovery"].as_str(), Some(recovery), "{last}");
}

/// An agent process that dies mid-turn fails it as `agent.exited` with what to do, never a bare
/// "agent process closed".
#[tokio::test]
async fn typed_error_an_agent_that_exits_mid_turn_says_how_to_recover() {
    let dir = scratch("exit");
    let mut c = C::new(hub_with(|_| {})).await;
    let id = c.session("fake", &dir).await.unwrap();
    let e = c.prompt(&id, "die: segfault in the model client").await.expect_err("the turn fails");
    let d = data(&e);
    assert_eq!(d["errorKind"], "agent.exited", "{e:?}");
    assert!(d["recovery"].as_str().unwrap_or_default().contains("Send the message again"), "{d}");
    let last = c.last_turn(&id).await;
    assert_eq!(last["errorKind"], "agent.exited", "{last}");
}

/// A short -32603 answer, which the turn finalizer treats as a dead process, fails the turn as
/// `agent.exited` too, on the reply and in `lastTurn`.
#[tokio::test]
async fn typed_error_a_short_internal_error_says_how_to_recover() {
    let dir = scratch("internal");
    let mut c = C::new(hub_with(|_| {})).await;
    let id = c.session("fake", &dir).await.unwrap();
    let e = c.prompt(&id, "fail-once: hello").await.expect_err("the turn fails");
    assert_eq!(e.code, -32603, "{e:?}");
    let d = data(&e);
    assert_eq!(d["errorKind"], "agent.exited", "{e:?}");
    assert!(d["recovery"].as_str().unwrap_or_default().contains("Send the message again"), "{d}");
    let last = c.last_turn(&id).await;
    assert_eq!(last["errorKind"], "agent.exited", "{last}");
}

/// An agent that says it is not signed in fails its turn as `auth.signed_out`, and one whose
/// sign-in expired as `auth.expired`, on the prompt's error and in `lastTurn`, so a client reads
/// the kind instead of the agent's words.
#[tokio::test]
async fn typed_error_a_turn_that_is_not_signed_in_says_so() {
    let dir = scratch("auth");
    let mut c = C::new(hub_with(|_| {})).await;
    for (text, kind) in [
        ("Not logged in · Please run /login", "auth.signed_out"),
        ("API Error: 401 OAuth token has expired. Please obtain a new token.", "auth.expired"),
    ] {
        let id = c.session("fake", &dir).await.unwrap();
        let e = c.prompt(&id, &format!("fail-streamed: {text}")).await.expect_err("it fails");
        let d = data(&e);
        assert_eq!(d["errorKind"], kind, "{e:?}");
        assert!(d["recovery"].as_str().unwrap_or_default().contains("Sign in"), "{d}");
        let last = c.last_turn(&id).await;
        assert_eq!(last["status"], "failed", "{last}");
        assert_eq!(last["errorKind"], kind, "{last}");
    }
}

/// A harness whose program is missing fails as `spawn.failed` with what to check.
#[tokio::test]
async fn typed_error_a_harness_that_cannot_start_says_what_to_check() {
    let dir = scratch("spawn");
    let mut c = C::new(hub_with(|_| {})).await;
    let e = match c.session("missing", &dir).await {
        Err(e) => e,
        Ok(id) => c.prompt(&id, "hello").await.expect_err("the agent cannot start"),
    };
    let d = data(&e);
    assert_eq!(d["errorKind"], "spawn.failed", "{e:?}");
    assert!(
        d["recovery"].as_str().unwrap_or_default().contains("acpmux harness doctor missing"),
        "{d}"
    );
}

/// `daemon status` reports the space of acpmux's disk, and under `diskLowBytes` says
/// `disk.low` with what to free.
#[tokio::test]
async fn typed_error_daemon_status_names_a_low_disk() {
    // `diskLowBytes` 0: no disk is under it, whatever the runner has free.
    let mut c = C::new(hub_with(|cfg| {
        let mut v = serde_json::to_value(&*cfg).unwrap();
        v["diskLowBytes"] = json!(0);
        *cfg = serde_json::from_value(v).unwrap();
    }))
    .await;
    let v = c.call(method::MUX_STATUS, json!({})).await.unwrap();
    assert!(v.pointer("/disk/freeBytes").and_then(Value::as_u64).is_some(), "{v}");
    assert_eq!(v.pointer("/disk/low"), Some(&json!(false)), "{v}");
    assert!(v.pointer("/disk/errorKind").is_none(), "{v}");

    // `diskLowBytes` above any disk's free space: the disk reads as low.
    let mut c = C::new(hub_with(|cfg| {
        let mut v = serde_json::to_value(&*cfg).unwrap();
        v["diskLowBytes"] = json!(u64::MAX);
        *cfg = serde_json::from_value(v).unwrap();
    }))
    .await;
    let v = c.call(method::MUX_STATUS, json!({})).await.unwrap();
    assert_eq!(v.pointer("/disk/low"), Some(&json!(true)), "{v}");
    assert_eq!(v.pointer("/disk/errorKind"), Some(&json!("disk.low")), "{v}");
    let recovery = v.pointer("/disk/recovery").and_then(Value::as_str).unwrap_or_default();
    assert!(recovery.contains("nearly full"), "{recovery}");
}
