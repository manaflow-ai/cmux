//! ACP-REMOTE-GUARD A1 to A3: a Web source is resolved like its handler
//! resolves it (refused when it cannot be), carries no mode field, and is
//! accepted only in a mode the reviewed per-harness table lists.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("agm-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// A hub whose harnesses all run the fake agent, under the families of the
/// reviewed table (claude, codex, opencode), an unknown one (gemini) and
/// `fake` (asking modes from config). `store_root`: a local store there.
fn hub(d: &Path, store_root: Option<&Path>) -> Arc<Hub> {
    let profile = |family: &str| json!({"argv": ["python3", FAKE], "family": family});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fclaude": profile("claude"),
            "fcodex": profile("codex"),
            "fopencode": profile("opencode"),
            "fgemini": profile("gemini"),
        },
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    match store_root {
        Some(_) => cfg.store.mode = StoreMode::Local,
        None => cfg.store.mode = StoreMode::Memory,
    }
    let store = acpmux::store::open(&cfg.store, store_root.unwrap_or(Path::new("/nonexistent"))).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv()).await.unwrap().unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn new_on(&mut self, d: &Path, harness: &str, extra: Value) -> Value {
        let mut p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        self.call("session/new", p).await
    }
}

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

fn id(v: &Value) -> String {
    v["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
}

#[tokio::test]
async fn a_web_source_is_resolved_like_its_handler_and_refused_when_it_cannot_be() {
    let d = dir("a1");
    let store = d.join("store");
    let (name, sid) = {
        let hub = hub(&d, Some(&store));
        let mut local = Client::new(&hub, Origin::Local);
        let created = local.new_on(&d, "fake", json!({"policy": "approve-all", "_meta": {"acpmux": {"harness": "fake", "name": "loose-one"}}})).await;
        let sid = id(&created);
        let _ = local.call("_acpmux/kill", json!({"sessionId": sid})).await;
        ("loose-one".to_owned(), sid)
    };
    // A new daemon: the session is stored, not live.
    let hub = hub(&d, Some(&store));
    let mut web = Client::new(&hub, Origin::Web);
    for p in [
        json!({"sessionId": sid, "cwd": d.join("work"), "mcpServers": []}),
        // The handler also resolves `session` and `name`.
        json!({"session": name, "cwd": d.join("work"), "mcpServers": []}),
        json!({"name": name, "cwd": d.join("work"), "mcpServers": []}),
    ] {
        for m in ["session/load", "session/resume"] {
            let r = web.call(m, p.clone()).await;
            assert!(err(&r).contains("does not ask"), "{m} {p}: {r}");
        }
    }
    // Not found, and an ambiguous prefix: refused, never passed unchecked.
    let mut local = Client::new(&hub, Origin::Local);
    for n in ["dup-a", "dup-b"] {
        id(&local.new_on(&d, "fake", json!({"_meta": {"acpmux": {"harness": "fake", "name": n}}})).await);
    }
    for key in ["no-such-session", "dup"] {
        let r = web.call("session/load", json!({"sessionId": key, "cwd": d.join("work"), "mcpServers": []})).await;
        assert!(err(&r).contains("cannot be resolved"), "{key}: {r}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_fork_load_resume_or_handoff_carries_no_mode_field() {
    let d = dir("a2");
    let hub = hub(&d, None);
    let mut local = Client::new(&hub, Origin::Local);
    let sid = id(&local.new_on(&d, "fake", json!({})).await);
    let mut web = Client::new(&hub, Origin::Web);
    for m in ["session/fork", "session/load", "session/resume", "_acpmux/handoff_prepare"] {
        for extra in [json!({"modeId": "bypassPermissions"}), json!({"_meta": {"acpmux": {"permissionMode": "acceptEdits"}}})] {
            let mut p = json!({"sessionId": sid, "harness": "fcodex", "handoffKey": "k"});
            for (k, v) in extra.as_object().unwrap() {
                p[k] = v.clone();
            }
            let r = web.call(m, p).await;
            assert!(err(&r).contains("carries a mode field"), "{m} {extra}: {r}");
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn each_harness_starts_and_stays_in_a_reviewed_asking_mode_for_the_web() {
    let d = dir("a3");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    // (harness, its asking default, a mode it offers that does not ask)
    for (harness, asking, loose) in [
        ("fclaude", "default", "bypassPermissions"),
        ("fcodex", "read-only", "agent"),
        ("fopencode", "plan", "build"),
    ] {
        // A new Web session is moved to the asking default.
        let s = id(&web.new_on(&d, harness, json!({})).await);
        let info = web.call("_acpmux/info", json!({"sessionId": s})).await;
        assert_eq!(info["result"]["modes"]["currentModeId"], json!(asking), "{harness}: {info}");
        let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": loose})).await;
        assert!(err(&r).contains("never from a remote WebSocket"), "{harness} {loose}: {r}");
        let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": "invented"})).await;
        assert!(err(&r).contains("never from a remote WebSocket"), "{harness} invented: {r}");
        let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": asking})).await;
        assert!(r.get("error").is_none(), "{harness} {asking}: {r}");
        // A source in a mode that does not ask (the unix socket set it) is
        // refused; the fake agent reports the harness default "normal",
        // which no reviewed harness lists.
        let src = id(&local.new_on(&d, harness, json!({})).await);
        let _ = local.call("session/set_mode", json!({"sessionId": src, "modeId": loose})).await;
        let r = web.call("session/fork", json!({"sessionId": src})).await;
        assert!(err(&r).contains("does not ask"), "{harness}: {r}");
    }
    // An unknown harness: refused, and nothing is left behind.
    let before = local.call("_acpmux/sessions", json!({})).await["result"]["sessions"].as_array().unwrap().len();
    let r = web.new_on(&d, "fgemini", json!({})).await;
    assert!(err(&r).contains("no reviewed asking mode"), "{r}");
    let after = local.call("_acpmux/sessions", json!({})).await["result"]["sessions"].as_array().unwrap().len();
    assert_eq!(before, after, "the refused session was ended");
    let _ = std::fs::remove_dir_all(&d);
}
