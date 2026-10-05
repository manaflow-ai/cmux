//! ACP-REMOTE-GUARD P1 and B1/B2: a Web connection controls a session (a
//! prompt, a permission answer) only while its CURRENT mode is in the
//! asking table, whatever wrote that mode, and the hub checks again when a
//! queued prompt is dispatched. Reads stay; the unix socket and the local
//! app keep full control.

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
    let d = std::env::temp_dir().join(format!("awc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// The fake agent under the claude family (asking: default, plan) and the
/// opencode family (asking: plan), a handoff target; its starting mode
/// `normal` is in neither row.
fn hub(d: &Path, store_root: Option<&Path>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "fopencode": {"argv": ["python3", FAKE], "family": "opencode"},
            "fnomode": {"argv": ["python3", FAKE], "env": {"FAKE_NO_MODES": "1"}},
        },
        "defaultHarness": "fclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = if store_root.is_some() { StoreMode::Local } else { StoreMode::Memory };
    let root = store_root.unwrap_or(Path::new("/nonexistent"));
    let store = acpmux::store::open(&cfg.store, root).unwrap();
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

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }

    async fn new_session(&mut self, d: &Path) -> String {
        let p = json!({"cwd": d.join("work"), "mcpServers": []});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn a_local_session_in_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("local");
    let hub = hub(&d, None);
    let mut local = Client::new(&hub, Origin::Local);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut web = Client::new(&hub, Origin::Web);
    // Created over the unix socket: it keeps the harness's mode `normal`.
    let s = local.new_session(&d).await;
    let r = web.prompt(&s, "from a paired device").await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["mode"], json!("normal"), "{r}");
    assert_eq!(r["error"]["data"]["harness"], json!("fclaude"), "{r}");
    for (m, p) in [
        (
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": "p", "optionId": "o"}),
        ),
        (
            "_acpmux/permission_group_respond",
            json!({"sessionId": s, "groupId": "g", "revision": 1, "decisionKey": "k", "decision": "deny"}),
        ),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(reason(&r), "remote.mode_not_asking", "{m}: {r}");
    }
    // Reads stay.
    for m in ["_acpmux/attach", "_acpmux/events", "_acpmux/info"] {
        let r = web.call(m, json!({"sessionId": s, "limit": 0})).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
    }
    // The unix socket and the local app keep control.
    assert!(local.prompt(&s, "mine").await.get("error").is_none());
    assert!(app.prompt(&s, "mine too").await.get("error").is_none());
    // An asking mode set locally opens it to the Web.
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "plan"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.prompt(&s, "now").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_internal_set_mode_to_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("internal");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    // A Web session is moved to the asking default.
    let s = web.new_session(&d).await;
    assert!(web.prompt(&s, "hello").await.get("error").is_none());
    // A hub-internal caller (a preset, a handoff, a harness switch).
    let session = hub.resolve(&s).unwrap();
    hub.set_mode(&session, "bypassPermissions").await.unwrap();
    let r = web.prompt(&s, "after").await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_session_loaded_in_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("loaded");
    let root = d.join("store");
    let s = {
        let hub = hub(&d, Some(&root));
        let mut local = Client::new(&hub, Origin::Local);
        let s = local.new_session(&d).await;
        let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "auto"})).await;
        assert!(r.get("error").is_none(), "{r}");
        hub.flush();
        let _ = hub.shutdown_all().await;
        s
    };
    // A new daemon loads it from the store, still in `auto`.
    let hub = hub(&d, Some(&root));
    let mut web = Client::new(&hub, Origin::Web);
    let r = web.prompt(&s, "after a restart").await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["mode"], json!("auto"), "{r}");
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
async fn a_queued_web_prompt_is_dropped_when_the_mode_left_the_table_before_dispatch() {
    let d = dir("queue");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    // A busy session: a local turn waits on a FIFO.
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    // A Web prompt, accepted in the asking mode, waits in the queue.
    let queued = json!({"sessionId": s, "prompt": [{"type": "text", "text": "queued-web"}]});
    let web_id = web.send("session/prompt", queued).await;
    wait_events(&mut local, &s, "queued-web").await;
    // The mode leaves the table while it waits.
    let r = local
        .call("session/set_mode", json!({"sessionId": s, "modeId": "bypassPermissions"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    // The busy turn ends; the queued Web prompt is dispatched next.
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A Web handoff from a Web session to a new target on another harness.
async fn web_handoff(web: &mut Client, d: &Path, key: &str) -> (String, String) {
    let src = web.new_session(d).await;
    assert!(web.prompt(&src, "some work").await.get("error").is_none());
    let p = json!({"sessionId": src, "harness": "fopencode", "handoffKey": key});
    let h = web.call("_acpmux/handoff_prepare", p).await;
    let id = h["result"]["handoffId"].as_str().unwrap_or_else(|| panic!("{h}")).to_owned();
    let target = h["result"]["target"]["sessionId"].as_str().unwrap().to_owned();
    (id, target)
}

fn start(id: &str) -> Value {
    json!({"handoffId": id, "revision": 1, "checkpoint": {"ref": "abc123", "attest": true}})
}

#[tokio::test]
async fn a_web_handoff_start_moves_a_new_target_to_an_asking_mode_first() {
    let d = dir("handoff-new");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let (id, target) = web_handoff(&mut web, &d, "k-new").await;
    // The target starts in the harness's own mode, which does not ask.
    let info = local.call("_acpmux/info", json!({"sessionId": target})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("normal"), "{info}");
    let r = web.call("_acpmux/handoff_start", start(&id)).await;
    assert_eq!(r["result"]["outcome"], json!("started"), "{r}");
    let info = local.call("_acpmux/info", json!({"sessionId": target})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("plan"), "{info}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_handoff_start_whose_target_does_not_resolve_is_refused() {
    let d = dir("handoff-gone");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let (id, target) = web_handoff(&mut web, &d, "k-gone").await;
    let r = local.call("_acpmux/kill", json!({"sessionId": target, "purge": true})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.call("_acpmux/handoff_start", start(&id)).await;
    let msg = r["error"]["message"].as_str().unwrap_or_default();
    assert!(msg.contains("target cannot be resolved"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A session over the unix socket on the harness that reports no mode.
async fn no_mode_session(local: &mut Client, d: &Path) -> String {
    let p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fnomode"}}});
    let r = local.call("session/new", p).await;
    let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert!(r["result"]["modes"].is_null(), "no mode: {r}");
    s
}

async fn set_policy(local: &mut Client, s: &str, policy: &str) {
    let r = local.call("_acpmux/set_policy", json!({"sessionId": s, "policy": policy})).await;
    assert!(r.get("error").is_none(), "{r}");
}

#[tokio::test]
async fn a_session_with_no_mode_needs_an_asking_policy_for_web_control() {
    let d = dir("policy");
    let hub = hub(&d, None);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    // With ask, the Web may prompt it.
    assert!(web.prompt(&s, "asks").await.get("error").is_none());
    // approve-all approves every tool call: refused, with the policy.
    set_policy(&mut local, &s, "approve-all").await;
    let r = web.prompt(&s, "approves").await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["policy"], json!("approve-all"), "{r}");
    let answer = json!({"sessionId": s, "permissionId": "p", "optionId": "o"});
    let r = web.call("_acpmux/permission_respond", answer).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    // The unix socket keeps control.
    assert!(local.prompt(&s, "mine").await.get("error").is_none());
    // deny-all asks nothing but approves nothing either.
    set_policy(&mut local, &s, "deny-all").await;
    assert!(web.prompt(&s, "denies").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_auto_approve_rule_refuses_web_control() {
    let d = dir("rules");
    let hub = hub(&d, None);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    for rules in [json!({"autoApprove": ["read"]}), json!({"default": "approve"})] {
        let r = local.call("_acpmux/set_rules", json!({"sessionId": s, "rules": rules})).await;
        assert!(r.get("error").is_none(), "{r}");
        let r = web.prompt(&s, "with rules").await;
        assert_eq!(reason(&r), "remote.policy_not_asking", "{rules}: {r}");
    }
    // Rules that only deny or ask keep it asking.
    let rules = json!({"autoDeny": ["rm -rf"], "ask": ["bash"], "default": "ask"});
    let r = local.call("_acpmux/set_rules", json!({"sessionId": s, "rules": rules})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.prompt(&s, "asking rules").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_queued_web_prompt_is_dropped_when_the_policy_stops_asking_before_dispatch() {
    let d = dir("policy-queue");
    let hub = hub(&d, None);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
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
    // The policy stops asking while it waits.
    set_policy(&mut local, &s, "approve-all").await;
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}
