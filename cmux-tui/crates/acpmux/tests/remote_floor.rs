//! REMOTE-FLOOR (decisions.md REMOTE-CHIEF, REMOTE-FLOOR-ENFORCEMENT): a
//! turn a remote device started (a Web turn) never runs below the remote
//! floor, whatever changed after the guard and the dispatch let it start.
//! The permission step itself enforces it (`handle_permission_for`):
//!
//! - no auto-approval in a Web turn: a policy or a rule set to approve
//!   during the turn makes the request ask, never answer itself;
//! - an ACP file read outside the session's folder asks (symlinks resolved);
//! - a session that leaves the asking-mode table during a Web turn has the
//!   turn cancelled, and every later permission request in it is cancelled.
//!
//! The unix socket keeps its behavior: a local turn under `approve-all`
//! still answers itself.

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

/// The fake agent under the claude family: its asking modes are default and
/// plan, and a new Web session is moved to default.
fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "fnomode": {"argv": ["python3", FAKE], "family": "claude", "env": {"FAKE_NO_MODES": "1"}},
            "ftarget": {"argv": ["python3", FAKE], "family": "target"},
        },
        "defaultHarness": "fclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        // A handoff target family whose asking row lists the fake's `strict`.
        "webAskingModes": {"target": ["strict"]},
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

    async fn send_prompt(&mut self, s: &str, text: &str) -> i64 {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.send("session/prompt", p).await
    }

    async fn new_session(&mut self, d: &Path) -> String {
        let p = json!({"cwd": d.join("work"), "mcpServers": []});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }
}

/// The session's events, polled until one of `needles` shows.
async fn wait_any(c: &mut Client, s: &str, needles: &[&str]) -> Vec<Value> {
    for _ in 0..500 {
        let r = c.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        let text = r.to_string();
        if needles.iter().any(|n| text.contains(n)) {
            return r["result"]["events"].as_array().cloned().unwrap_or_default();
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("none of {needles:?} in the events of {s}");
}

/// The session's events, polled until it has `n` permission requests or
/// the agent streamed the secret.
async fn wait_asks(c: &mut Client, s: &str, n: usize) -> Vec<Value> {
    for _ in 0..500 {
        let events = wait_any(c, s, &["\"kind\""]).await;
        let asks = events.iter().filter(|e| e["kind"] == "permission_request").count();
        if asks >= n || said(&events).contains("s3cret") {
            return events;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no permission request {n} in the events of {s}");
}

fn kinds(events: &[Value]) -> Vec<&str> {
    events.iter().filter_map(|e| e["kind"].as_str()).collect()
}

/// The text the agent streamed, joined.
fn said(events: &[Value]) -> String {
    events
        .iter()
        .filter(|e| {
            e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
        })
        .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
        .collect()
}

fn pending_id(events: &[Value]) -> String {
    events
        .iter()
        .rev()
        .find(|e| e["kind"] == "permission_request")
        .and_then(|e| e["msg"]["permissionId"].as_str())
        .unwrap_or_else(|| panic!("no permission_request in {events:?}"))
        .to_owned()
}

/// A Web turn blocked on a FIFO; `change` runs from the unix socket while
/// it waits, then the agent asks. The request must ask (be pending), never
/// be answered by the changed policy or rules.
async fn web_turn_after(tag: &str, change: (&str, Value)) {
    let d = dir(tag);
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let turn = web.send_prompt(&s, &format!("gate-ask: {}", fifo.display())).await;
    wait_any(&mut local, &s, &["before-gate"]).await;
    let mut params = change.1;
    params["sessionId"] = json!(s);
    let r = local.call(change.0, params).await;
    assert!(r.get("error").is_none(), "{r}");
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    let events = wait_any(&mut local, &s, &["permission_request", "chose "]).await;
    assert!(
        !kinds(&events).contains(&"permission_auto"),
        "a Web turn's request answered itself: {events:?}"
    );
    assert!(!said(&events).contains("chose yes"), "{events:?}");
    // The local user rejects it; the turn ends.
    let pid = pending_id(&events);
    let r = local
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": pid, "optionId": "no"}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.reply(turn).await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_turn_asks_after_the_policy_changes_to_approve_all() {
    web_turn_after("policy", ("_acpmux/set_policy", json!({"policy": "approve-all"}))).await;
}

#[tokio::test]
async fn a_web_turn_asks_after_an_auto_approve_rule_is_set() {
    let rules = json!({"rules": {"autoApprove": ["*"]}});
    web_turn_after("rules", ("_acpmux/set_rules", rules)).await;
}

#[tokio::test]
async fn a_web_turn_asks_before_an_acp_read_outside_its_folder() {
    let d = dir("read");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    std::fs::write(d.join("secret.txt"), "s3cret\n").unwrap();
    std::fs::write(d.join("work/inside.txt"), "inside\n").unwrap();
    std::os::unix::fs::symlink(d.join("secret.txt"), d.join("work/link.txt")).unwrap();
    // Inside the folder: read without a question, as before.
    let turn =
        web.send_prompt(&s, &format!("fsread: {}", d.join("work/inside.txt").display())).await;
    assert!(web.reply(turn).await.get("error").is_none());
    let events = wait_any(&mut local, &s, &["read: inside"]).await;
    assert!(!kinds(&events).contains(&"permission_request"), "{events:?}");
    // Outside it, directly or through a symlink inside: ask; a reject ends it.
    for (n, path) in [(1, d.join("secret.txt")), (2, d.join("work/link.txt"))] {
        let turn = web.send_prompt(&s, &format!("fsread: {}", path.display())).await;
        let events = wait_asks(&mut local, &s, n).await;
        let asks = events.iter().filter(|e| e["kind"] == "permission_request").count();
        assert!(!said(&events).contains("s3cret"), "read {n} ran without asking: {events:?}");
        assert_eq!(asks, n, "{events:?}");
        // The question names the file the read lands on.
        let asked = events.iter().rev().find(|e| e["kind"] == "permission_request").unwrap();
        let title = asked["msg"]["request"]["toolCall"]["title"].as_str().unwrap_or_default();
        assert!(title.ends_with("/secret.txt"), "{title}");
        let pid = pending_id(&events);
        let r = local
            .call(
                "_acpmux/permission_respond",
                json!({"sessionId": s, "permissionId": pid, "optionId": "reject_once"}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        assert!(web.reply(turn).await.get("error").is_none());
    }
    let events = wait_any(&mut local, &s, &["rejected: "]).await;
    assert!(!said(&events).contains("s3cret"), "{events:?}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_turn_is_cancelled_when_its_harness_leaves_the_asking_modes() {
    let d = dir("drift");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    // The harness moves itself to a mode that never asks, then asks once:
    // the request is cancelled at the permission step, not shown.
    let turn = web.send_prompt(&s, "drift-ask: bypassPermissions").await;
    let events = wait_any(&mut local, &s, &["permission_request", "chose "]).await;
    assert!(!kinds(&events).contains(&"permission_request"), "{events:?}");
    assert!(said(&events).contains("chose cancelled"), "{events:?}");
    assert!(kinds(&events).contains(&"remote_floor_cancel"), "{events:?}");
    assert!(web.reply(turn).await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_local_turn_under_approve_all_still_answers_itself() {
    let d = dir("local");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d).await;
    let r =
        local.call("_acpmux/set_policy", json!({"sessionId": s, "policy": "approve-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let turn = local.send_prompt(&s, "ask: local command").await;
    assert!(local.reply(turn).await.get("error").is_none());
    let events = wait_any(&mut local, &s, &["chose "]).await;
    assert!(said(&events).contains("chose yes"), "{events:?}");
    assert!(kinds(&events).contains(&"permission_auto"), "{events:?}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_turn_is_cancelled_when_a_harness_with_no_modes_reports_one_that_never_asks() {
    let d = dir("nomode");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fnomode"}}});
    let r = web.call("session/new", p).await;
    let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let turn = web.send_prompt(&s, "drift-ask: bypassPermissions").await;
    let events = wait_any(&mut local, &s, &["permission_request", "chose "]).await;
    assert!(!kinds(&events).contains(&"permission_request"), "{events:?}");
    assert!(said(&events).contains("chose cancelled"), "{events:?}");
    assert!(kinds(&events).contains(&"remote_floor_cancel"), "{events:?}");
    assert!(web.reply(turn).await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_turn_records_who_started_it_and_a_web_handoff_prompts_its_target_as_web() {
    let d = dir("handoff");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let src = web.new_session(&d).await;
    let turn = web.send_prompt(&src, "some work").await;
    assert!(web.reply(turn).await.get("error").is_none());
    let events = wait_any(&mut local, &src, &["turn_started"]).await;
    let started = events.iter().find(|e| e["kind"] == "turn_started").unwrap();
    assert_eq!(started["msg"]["control"], json!("web"), "{started}");
    let p = json!({"sessionId": src, "harness": "ftarget", "handoffKey": "k1"});
    let h = web.call("_acpmux/handoff_prepare", p).await;
    let id = h["result"]["handoffId"].as_str().unwrap_or_else(|| panic!("{h}")).to_owned();
    let target = h["result"]["target"]["sessionId"].as_str().unwrap().to_owned();
    let start =
        json!({"handoffId": id, "revision": 1, "checkpoint": {"ref": "abc123", "attest": true}});
    let r = web.call("_acpmux/handoff_start", start).await;
    assert_eq!(r["result"]["outcome"], json!("started"), "{r}");
    let events = wait_any(&mut local, &target, &["turn_started"]).await;
    let started = events.iter().find(|e| e["kind"] == "turn_started").unwrap();
    assert_eq!(started["msg"]["control"], json!("web"), "the handoff's turn: {started}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_turn_never_writes_through_a_symlink() {
    let d = dir("write");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    std::fs::write(d.join("secret.txt"), "s3cret\n").unwrap();
    std::os::unix::fs::symlink(d.join("secret.txt"), d.join("work/link.txt")).unwrap();
    let turn =
        web.send_prompt(&s, &format!("fswrite: {}", d.join("work/link.txt").display())).await;
    let events = wait_any(&mut local, &s, &["permission_request", "rejected: ", "wrote"]).await;
    assert!(!kinds(&events).contains(&"permission_request"), "{events:?}");
    assert!(said(&events).contains("rejected: "), "{events:?}");
    assert!(web.reply(turn).await.get("error").is_none());
    assert_eq!(std::fs::read_to_string(d.join("secret.txt")).unwrap(), "s3cret\n");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_lasting_grant_the_local_user_gave_ends_web_control_until_the_agent_restarts() {
    let d = dir("grant");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let s = web.new_session(&d).await;
    // A local turn; the local user allows the tool always.
    let turn = local.send_prompt(&s, "ask-always: make").await;
    let events = wait_any(&mut local, &s, &["permission_request"]).await;
    let pid = pending_id(&events);
    let r = local
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": pid, "optionId": "always"}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(local.reply(turn).await.get("error").is_none());
    // The agent may now run that tool without a request: no Web prompt.
    let r = web
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], json!("remote.harness_grant"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}
