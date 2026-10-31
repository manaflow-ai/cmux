//! Run slots (`hub/subsession_runs.rs`): a session runs at most `maxRunning` of its sub-sessions
//! at once. A start past it is created and queued (`waitsForSlot`), and starts by itself when a
//! running one ends; raising the limit starts a waiting one at once, lowering it stops none; a
//! workspace's value sits between the session's own and the settings; the person's own prompt
//! to a waiting sub-session never waits for a slot.
//!
//! Stand-in agents (fake_agent.py): `gate: FIFO` holds a turn until the test writes the FIFO.
//! One test function: the settings file is read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// 32 bytes as hex: the person key the app makes at each launch.
const KEY: &str = "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b";
const START: &str = "_acpmux/subsession/start";
const LIMITS: &str = "_acpmux/subsession/limits";
const WORKSPACE: &str = "6f1c0b9e-2d3a-4c5b-8e7f-0a1b2c3d4e5f";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn plain(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The app's agent pane: a LocalApp connection that proved this launch's person key.
    async fn app(hub: &Arc<Hub>) -> Self {
        hub.person.enroll(KEY, true).unwrap();
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::LocalApp,
            ConnAuth::LocalApp,
        ));
        let mut c = Client(in_tx, out_rx, 0);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            KEY,
            acpmux::hub::person::TRANSPORT_APP,
            challenge["nonce"].as_str().unwrap_or_else(|| panic!("{r}")),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::plain(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
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

    async fn refused(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_some(), "{m} should be refused: {r}");
        r["error"].clone()
    }

    async fn summary(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{id} is not listed: {list}"))
    }

    async fn limits(&mut self, id: &str) -> Value {
        self.ok("_acpmux/info", json!({"sessionId": id})).await["subsessionLimits"].clone()
    }

    /// Reads the session summary until `done` holds, for at most 20 s.
    async fn until(&mut self, id: &str, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let s = self.summary(id).await;
            if done(&s) {
                return s;
            }
            assert!(Instant::now() < deadline, "{id} never {what}: {s}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    async fn until_running(&mut self, id: &str) -> Value {
        self.until(id, "ran", |s| s["status"] == "running").await
    }

    /// Reads `parent`'s limits until `done` holds, for at most 20 s.
    async fn until_limits(&mut self, parent: &str, what: &str, done: impl Fn(&Value) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let l = self.limits(parent).await;
            if done(&l) {
                return;
            }
            assert!(Instant::now() < deadline, "{parent}'s limits never {what}: {l}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

/// Lets a gated turn go on: opens its FIFO for writing off the runtime (it blocks until the
/// stand-in agent reads it).
async fn release(path: &Path) {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || std::fs::write(path, b"go")).await.unwrap().unwrap();
}

fn fifo(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

fn gate(path: &Path) -> String {
    format!("gate: {}", path.display())
}

fn id(v: &Value) -> String {
    v["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sub_sessions_wait_for_a_run_slot_and_start_when_one_frees() {
    let root = std::env::temp_dir().join(format!("acpmux-runs-it-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"maxRunning": 1}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();
    let mut app = Client::app(&hub).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"harness": "fake", "workspaceId": WORKSPACE}}});
    let parent = id(&app.ok("session/new", new).await);
    let mut p = Client::as_session(&hub, &parent).await;

    // The settings allow one at a time: the first child runs, the second is queued for a slot.
    let gate_a = fifo(&root, "a");
    let a = p.ok(START, json!({"prompt": gate(&gate_a), "name": "a"})).await;
    assert_eq!(a["waitsForSlot"], false, "{a}");
    let a = id(&a);
    app.until_running(&a).await;
    let b = p.ok(START, json!({"prompt": "echo child b", "name": "b"})).await;
    assert_eq!(b["waitsForSlot"], true, "{b}");
    let b = id(&b);
    let sb = app.summary(&b).await;
    assert_eq!(sb["waitsForSlot"], true, "{sb}");
    assert_ne!(sb["status"], "running", "{sb}");
    assert!(app.summary(&a).await.get("waitsForSlot").is_none(), "absent when false");
    let l = app.limits(&parent).await;
    assert_eq!(
        (&l["maxRunning"], &l["maxRunningSource"], &l["running"], &l["queued"]),
        (&json!(1), &json!("settings"), &json!(1), &json!(1)),
        "{l}"
    );
    // The agent reads its own limits and counts with list_sessions.
    let me = p.ok("_acpmux/subsession/list", json!({})).await["self"].clone();
    assert_eq!(
        (&me["maxRunning"], &me["running"], &me["queued"]),
        (&json!(1), &json!(1), &json!(1))
    );
    // A message to a child that waits for a slot says so.
    let sent = p.ok("_acpmux/subsession/send", json!({"sessionId": b, "text": "echo later"})).await;
    assert_eq!(sent["delivery"], "queued", "{sent}");
    // A child queued for a slot is not ready: a wait on it waits (wait_for_sessions), and its
    // row tells the parent why.
    let w =
        p.ok("_acpmux/wait", json!({"sessions": [b], "until": ["ready"], "timeoutMs": 300})).await;
    assert_eq!(w["timedOut"], true, "{w}");
    let row = p.ok("_acpmux/subsession/get", json!({"sessionId": b})).await;
    assert_eq!(row["waitsForSlot"], true, "{row}");

    // Stopped or closed while queued, a child never starts later.
    let x = id(&p.ok(START, json!({"prompt": "echo child x", "name": "x"})).await);
    let y = id(&p.ok(START, json!({"prompt": "echo child y", "name": "y"})).await);
    p.ok("_acpmux/subsession/stop", json!({"sessionId": x})).await;
    assert_eq!(app.summary(&x).await["queued"], 0, "its start is withdrawn");
    p.ok("_acpmux/subsession/stop", json!({"sessionId": y, "close": true})).await;
    assert_eq!(app.summary(&y).await["queued"], 0);
    app.until(&x, "stopped waiting", |s| s.get("waitsForSlot").is_none()).await;
    app.until_limits(&parent, "counted only b", |l| l["queued"] == 1).await;

    // The first ends: the second gets its slot and runs its prompts.
    release(&gate_a).await;
    app.until(&b, "ran its prompts", |s| {
        s["queued"] == 0 && s["status"] == "ready" && s["turnCount"].as_u64() >= Some(1)
    })
    .await;
    assert!(app.summary(&b).await.get("waitsForSlot").is_none());
    app.until_limits(&parent, "freed", |l| l["running"] == 0 && l["queued"] == 0).await;
    let (sx, sy) = (app.summary(&x).await, app.summary(&y).await);
    assert_eq!((&sx["turnCount"], &sy["turnCount"]), (&json!(0), &json!(0)), "{sx} {sy}");
    assert_eq!(sy["status"], "closed", "{sy}");

    // Raised by the person, a waiting child starts at once.
    let (gate_c, gate_d, gate_e) = (fifo(&root, "c"), fifo(&root, "d"), fifo(&root, "e"));
    let c = id(&p.ok(START, json!({"prompt": gate(&gate_c), "name": "c"})).await);
    app.until_running(&c).await;
    let d = p.ok(START, json!({"prompt": gate(&gate_d), "name": "d"})).await;
    assert_eq!(d["waitsForSlot"], true, "{d}");
    let d = id(&d);
    // Never by the session itself, and only up to the ceiling.
    let e = p.refused(LIMITS, json!({"sessionId": parent, "maxRunning": 2})).await;
    assert_eq!(e["data"]["reason"], "subsessions.limits_person_required", "{e}");
    let e = app.refused(LIMITS, json!({"sessionId": parent, "maxRunning": 1001})).await;
    assert_eq!(e["data"]["reason"], "subsessions.limit_out_of_range", "{e}");
    let set = app.ok(LIMITS, json!({"sessionId": parent, "maxRunning": 2})).await;
    assert_eq!(set["subsessionLimits"]["maxRunning"], 2, "{set}");
    assert_eq!(set["subsessionLimits"]["maxRunningSource"], "session", "{set}");
    app.until_running(&d).await;

    // Lowered, it stops none: both keep running, and the next start waits until one slot is
    // left under the new limit.
    app.ok(LIMITS, json!({"sessionId": parent, "maxRunning": 1})).await;
    let e = p.ok(START, json!({"prompt": gate(&gate_e), "name": "e"})).await;
    assert_eq!(e["waitsForSlot"], true, "{e}");
    let e = id(&e);
    assert_eq!(app.summary(&c).await["status"], "running");
    assert_eq!(app.summary(&d).await["status"], "running");
    release(&gate_c).await;
    app.until(&c, "ended its turn", |s| s["status"] != "running").await;
    let se = app.summary(&e).await;
    assert_eq!(se["waitsForSlot"], true, "one running is the limit now: {se}");
    release(&gate_d).await;
    app.until_running(&e).await;

    // The person's own prompt to a waiting child never waits for a slot.
    let gate_f = fifo(&root, "f");
    let f = p.ok(START, json!({"prompt": gate(&gate_f), "name": "f"})).await;
    assert_eq!(f["waitsForSlot"], true, "{f}");
    let f = id(&f);
    let g = id(&p.ok(START, json!({"prompt": "echo child g", "name": "g"})).await);
    let r = app
        .ok(
            "session/prompt",
            json!({"sessionId": g, "prompt": [{"type": "text", "text": "echo from the person"}]}),
        )
        .await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    assert_eq!(app.summary(&f).await["waitsForSlot"], true);
    assert_eq!(app.summary(&g).await["waitsForSlot"], true, "its own start prompt still waits");

    // The workspace's value sits between the session's own and the settings; only the person
    // sets it, and a cleared session value falls back to it.
    let e2 = p.refused(LIMITS, json!({"workspaceId": WORKSPACE, "maxRunning": 3})).await;
    assert_eq!(e2["data"]["reason"], "permission.person_required", "{e2}");
    let ws =
        app.ok(LIMITS, json!({"workspaceId": WORKSPACE.to_uppercase(), "maxRunning": 3})).await;
    assert_eq!(ws, json!({"workspaceId": WORKSPACE, "maxRunning": 3}));
    assert_eq!(app.limits(&parent).await["maxRunningSource"], "session");
    app.ok(LIMITS, json!({"sessionId": parent, "maxRunning": null})).await;
    let l = app.limits(&parent).await;
    assert_eq!((&l["maxRunning"], &l["maxRunningSource"]), (&json!(3), &json!("workspace")), "{l}");
    // Two slots are free under it: the waiting gated child starts.
    app.until_running(&f).await;
    let saved = std::fs::read_to_string(root.join("home/subsession-workspaces.json")).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&saved).unwrap(), json!({WORKSPACE: 3}));
    let cleared = app.ok(LIMITS, json!({"workspaceId": WORKSPACE, "maxRunning": null})).await;
    assert_eq!(cleared["maxRunning"], Value::Null, "{cleared}");
    assert_eq!(app.limits(&parent).await["maxRunningSource"], "settings");

    release(&gate_e).await;
    release(&gate_f).await;
    let _ = std::fs::remove_dir_all(&root);
}
