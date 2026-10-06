//! D10 (2026-10-06): a remote (Web) connection never drives Codex or
//! opencode. Neither harness has a mode that asks before every edit and
//! every command (plans/cmux-next/acp-remote-guard.md), so the guard refuses
//! both families whatever config.json says: a `webAskingModes` entry for
//! them is ignored, and so is one for a family whose profile runs one of
//! them under another name. The refusal holds at check time and again when
//! a queued prompt is dispatched.

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
    let d = std::env::temp_dir().join(format!("arf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// The fake agent as Codex, as opencode, and as Codex under the family
/// `alias` (its argv names `codex-acp`, its explicit family does not). The
/// config tries to open every one of them to the Web, and makes Codex the
/// default harness.
fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
            "fopencode": {"argv": ["python3", FAKE], "family": "opencode"},
            "falias": {"argv": ["python3", FAKE, "codex-acp"], "family": "alias"},
            "flater": {"argv": ["python3", FAKE], "family": "later"},
        },
        "defaultHarness": "fcodex",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {
            "codex": ["read-only", "agent", "normal"],
            "opencode": ["plan", "build", "normal"],
            "alias": ["normal"],
            "later": ["normal"],
        },
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
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

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.reply(id).await
    }

    async fn new_on(&mut self, d: &Path, harness: Option<&str>) -> Value {
        let mut p = json!({"cwd": d.join("work"), "mcpServers": []});
        if let Some(h) = harness {
            p["_meta"] = json!({"acpmux": {"harness": h}});
        }
        self.call("session/new", p).await
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        self.call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]}))
            .await
    }

    async fn count(&mut self) -> usize {
        self.call("_acpmux/sessions", json!({})).await["result"]["sessions"]
            .as_array()
            .unwrap()
            .len()
    }
}

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

fn id(v: &Value) -> String {
    v["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
}

/// (harness, the modes a config tries to open to the Web)
const REFUSED: &[(&str, &[&str])] = &[
    ("fcodex", &["read-only", "agent", "normal"]),
    ("fopencode", &["plan", "build", "normal"]),
    ("falias", &["normal"]),
];

#[tokio::test]
async fn the_unix_socket_table_lists_no_codex_or_opencode_row() {
    let d = dir("table");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let r = local.call("_acpmux/web_modes", json!({})).await;
    let families = &r["result"]["families"];
    for f in ["codex", "opencode", "alias"] {
        let modes = families.get(f).and_then(Value::as_array).cloned().unwrap_or_default();
        assert!(modes.is_empty(), "{f} has Web modes: {r}");
    }
    assert_eq!(families["later"], json!(["normal"]), "{r}");
    assert_eq!(families["claude"], json!(["default", "plan"]), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_session_new_on_codex_or_opencode_is_refused_and_ended() {
    let d = dir("new");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let before = local.count().await;
    for (harness, _) in REFUSED {
        let r = web.new_on(&d, Some(harness)).await;
        assert!(err(&r).contains("no reviewed asking mode"), "{harness}: {r}");
    }
    // No harness named: the default harness, Codex, is refused too.
    let r = web.new_on(&d, None).await;
    assert!(err(&r).contains("no reviewed asking mode"), "default: {r}");
    assert_eq!(local.count().await, before, "every refused session was ended");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn web_control_of_codex_or_opencode_is_refused_in_every_mode() {
    let d = dir("control");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    for (harness, modes) in REFUSED {
        let s = id(&local.new_on(&d, Some(harness)).await);
        for mode in *modes {
            let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": mode})).await;
            assert!(r.get("error").is_none(), "local {harness} {mode}: {r}");
            let r = web.prompt(&s, "from a paired device").await;
            assert_eq!(reason(&r), "remote.mode_not_asking", "{harness} {mode}: {r}");
            let r = web
                .call(
                    "_acpmux/permission_respond",
                    json!({"sessionId": s, "permissionId": "p", "optionId": "o"}),
                )
                .await;
            assert_eq!(reason(&r), "remote.mode_not_asking", "{harness} {mode} answer: {r}");
            let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": mode})).await;
            assert!(r.get("error").is_some(), "web set_mode {harness} {mode}: {r}");
            let r = web
                .call("session/set_config_option", json!({"sessionId": s, "configId": "mode", "value": mode}))
                .await;
            assert!(r.get("error").is_some(), "web mode option {harness} {mode}: {r}");
            let r = web.call("session/fork", json!({"sessionId": s})).await;
            assert!(err(&r).contains("does not ask"), "web fork {harness} {mode}: {r}");
        }
        // The unix socket keeps full control.
        assert!(local.prompt(&s, "mine").await.get("error").is_none(), "{harness}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Poll `_acpmux/events` until its text contains `needle`.
async fn wait_events(c: &mut Client, s: &str, needle: &str) -> String {
    for _ in 0..500 {
        let r = c.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        let text = r.to_string();
        if text.contains(needle) {
            return text;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no {needle:?} in the events of {s}");
}

#[tokio::test]
async fn a_queued_web_prompt_is_dropped_when_its_harness_turns_out_to_run_codex() {
    let d = dir("queue");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::new(&hub, Origin::Local);
    // `later` asks (config lists its mode), so the Web may drive it.
    let s = id(&local.new_on(&d, Some("flater")).await);
    assert!(web.prompt(&s, "hello").await.get("error").is_none());
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    let queued = json!({"sessionId": s, "prompt": [{"type": "text", "text": "queued-web"}]});
    let web_id = web.send("session/prompt", queued).await;
    wait_events(&mut local, &s, "queued-web").await;
    // While the prompt waits, the profile is changed to run Codex.
    hub.config
        .write()
        .await
        .harnesses
        .get_mut("flater")
        .unwrap()
        .argv
        .push("codex-acp".into());
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_queued_web_prompt_is_dropped_when_codex_moves_to_read_only_before_dispatch() {
    let d = dir("queue-mode");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::new(&hub, Origin::Local);
    // A session on `later`, the fake agent in `normal`, which its row lists.
    let s = id(&local.new_on(&d, Some("flater")).await);
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    let queued = json!({"sessionId": s, "prompt": [{"type": "text", "text": "queued-web"}]});
    let web_id = web.send("session/prompt", queued).await;
    wait_events(&mut local, &s, "queued-web").await;
    // Codex's `read-only` mode id, which writes in the workspace without asking.
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "read-only"})).await;
    assert!(r.get("error").is_none(), "{r}");
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}
