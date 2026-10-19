//! Forum announcements at the daemon's socket (`forum.rs`, `hub/forum.rs`,
//! `server/forum.rs`, hq#2570): one rule per key, the newest wins; a session
//! reads the current rules in a hidden block of its next prompt (its first
//! one too, so a session started later gets them); an urgent rule is also
//! queued as a prompt to every live session, and a rule superseded while that
//! prompt still waits is taken back, so an old rule never reaches an agent as
//! current; acks are recorded per session; a person's rule outranks an
//! agent's: an agent's post on that key is only a proposal.
//!
//! Stand-in agents (fake_agent.py) echo the whole prompt they get, hidden
//! blocks included, which is how these tests see what an agent was told.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

const ANNOUNCE: &str = "_acpmux/forum/announce";
const RULES: &str = "_acpmux/forum/rules";
const ACK: &str = "_acpmux/forum/ack";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The app: `initialize`, then the person proof (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
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
        let r = c.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(r["person"], json!(true), "{r}");
        c
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
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

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        self.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// One prompt, to its turn's end; the agent's reply (the echo of all it got).
    async fn prompt(&mut self, id: &str, text: &str) -> String {
        self.ok(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
        self.replies(id).await.pop().unwrap_or_default()
    }

    /// Every reply the session's agent gave, in order.
    async fn replies(&mut self, id: &str) -> Vec<String> {
        let events = self
            .ok("_acpmux/events", json!({"sessionId": id, "kinds": ["agent_message_chunk"]}))
            .await;
        events["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .filter(|t| t.starts_with("echo: "))
            .map(str::to_owned)
            .collect()
    }

    async fn rule(&mut self, key: &str) -> Option<Value> {
        let rules = self.ok(RULES, json!({})).await;
        rules["rules"].as_array().unwrap().iter().find(|r| r["key"] == key).cloned()
    }
}

#[tokio::test]
async fn announcements_supersede_reach_late_sessions_and_record_acks() {
    let hub = hub();
    let mut app = Client::person(&hub).await;
    let a = app.new_session().await;
    // A live session, before any rule.
    assert!(!app.prompt(&a, "hello").await.contains("cmux-rules-context"));

    // Without a caller token or the person proof nobody posts.
    let mut anon = Client::new(&hub);
    anon.ok("initialize", json!({"protocolVersion": 1})).await;
    let e = anon.refused(ANNOUNCE, json!({"key": "builds", "body": "x"})).await;
    assert_eq!(e["data"]["reason"], "forum.author_required", "{e}");

    // The person posts a rule: their account is its author.
    let b1 = app
        .ok(
            ANNOUNCE,
            json!({"key": "builds", "body": "Builds run on huge-blue.", "account": "leo"}),
        )
        .await;
    assert_eq!(b1["post"]["author"]["kind"], "person", "{b1}");
    assert_eq!(b1["post"]["author"]["account"], "leo", "{b1}");
    assert_eq!(b1["post"]["kind"], "announce", "{b1}");
    let b1_id = b1["post"]["id"].as_str().unwrap().to_owned();

    // Not urgent: no prompt is pushed. The next prompt carries it, once,
    // marked as a person's instruction.
    assert_eq!(app.replies(&a).await.len(), 1);
    let got = app.prompt(&a, "next").await;
    assert!(got.contains("Builds run on huge-blue."), "{got}");
    assert!(got.contains("leo") && got.contains("instruction"), "{got}");
    assert!(!app.prompt(&a, "again").await.contains("huge-blue"));

    // Superseding: a new post on the key replaces the old one.
    let b2 = app
        .ok(
            ANNOUNCE,
            json!({"key": "builds", "body": "Builds run on the fleet.", "account": "leo"}),
        )
        .await;
    let b2_id = b2["post"]["id"].as_str().unwrap().to_owned();
    assert_eq!(b2["post"]["supersedes"], b1_id.as_str(), "{b2}");
    let rules = app.ok(RULES, json!({})).await;
    let builds: Vec<&Value> =
        rules["rules"].as_array().unwrap().iter().filter(|r| r["key"] == "builds").collect();
    assert_eq!(builds.len(), 1, "{rules}");
    assert_eq!(builds[0]["id"], b2_id.as_str(), "{rules}");
    let got = app.prompt(&a, "after").await;
    assert!(got.contains("the fleet") && !got.contains("huge-blue"), "{got}");

    // A session started later gets the current rule on its first prompt, never the old one.
    let c = app.new_session().await;
    let got = app.prompt(&c, "first").await;
    assert!(got.contains("Builds run on the fleet."), "{got}");
    assert!(!got.contains("huge-blue"), "{got}");

    // An agent cannot supersede a person's rule: its post is a proposal.
    let mut sa = Client::as_session(&hub, &a).await;
    let p = sa.ok(ANNOUNCE, json!({"key": "builds", "body": "Builds run anywhere."})).await;
    assert_eq!(p["proposed"], true, "{p}");
    assert_eq!(p["post"]["kind"], "question", "{p}");
    assert_eq!(p["post"]["author"]["kind"], "agent", "{p}");
    assert_eq!(app.rule("builds").await.unwrap()["id"], b2_id.as_str());
    // An agent's own rule is information, and it may replace it.
    let n1 = sa.ok(ANNOUNCE, json!({"key": "notes", "body": "Notes go in hq issues."})).await;
    assert_eq!(n1["proposed"], false, "{n1}");
    let n2 = sa.ok(ANNOUNCE, json!({"key": "notes", "body": "Notes go in the forum."})).await;
    assert_eq!(n2["post"]["supersedes"], n1["post"]["id"], "{n2}");
    let got = app.prompt(&c, "more").await;
    assert!(got.contains("Notes go in the forum.") && got.contains("information"), "{got}");
    // The author's own session is not told its own rule.
    assert!(!app.prompt(&a, "own").await.contains("Notes go in"));

    // Acks: a session acks a rule, and the poster sees who read it.
    let mut sc = Client::as_session(&hub, &c).await;
    sc.ok(ACK, json!({"postId": b2_id})).await;
    sc.ok(ACK, json!({"postId": b2_id})).await;
    let rule = app.rule("builds").await.unwrap();
    let acks: Vec<&str> =
        rule["acks"].as_array().unwrap().iter().filter_map(|a| a["sessionId"].as_str()).collect();
    assert_eq!(acks, [c.as_str()], "{rule}");
    let delivered: Vec<&str> = rule["delivered"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|a| a["sessionId"].as_str())
        .collect();
    assert!(delivered.contains(&a.as_str()) && delivered.contains(&c.as_str()), "{rule}");
    let e = sc.refused(ACK, json!({"postId": "nope"})).await;
    assert_eq!(e["data"]["reason"], "forum.not_found", "{e}");

    // The person retires a rule: it is no longer current anywhere.
    app.ok(ANNOUNCE, json!({"key": "notes", "retire": true, "account": "leo"})).await;
    assert!(app.rule("notes").await.is_none());
}

#[tokio::test]
async fn urgent_rules_are_pushed_and_a_superseded_one_is_never_delivered() {
    let hub = hub();
    let mut app = Client::person(&hub).await;
    let d = app.new_session().await;
    app.prompt(&d, "warm up").await;

    // A running turn: the urgent rule waits behind it as a prompt.
    let mut bg = Client::person(&hub).await;
    let slow = json!({"sessionId": d, "prompt": [{"type": "text", "text": "slow"}]});
    tokio::spawn(async move { bg.call("session/prompt", slow).await });
    app.ok("_acpmux/wait", json!({"sessions": [d], "until": ["running"], "timeoutMs": 5000})).await;
    let u1 = app
        .ok(ANNOUNCE, json!({"key": "load", "body": "Stop building on cosmic-gray.", "urgent": true, "account": "leo"}))
        .await;
    assert_eq!(u1["pushed"], json!([d.as_str()]), "{u1}");
    // Superseded while it still waits: taken back before it runs.
    app.ok(ANNOUNCE, json!({"key": "load", "body": "Builds may use cosmic-gray again.", "urgent": true, "account": "leo"}))
        .await;
    app.ok("_acpmux/wait", json!({"sessions": [d], "until": ["ready"], "timeoutMs": 20000})).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    app.ok("_acpmux/wait", json!({"sessions": [d], "until": ["ready"], "timeoutMs": 20000})).await;
    let all = app.replies(&d).await.join("\n");
    assert!(all.contains("Builds may use cosmic-gray again."), "{all}");
    assert!(!all.contains("Stop building on cosmic-gray."), "{all}");
    // Delivered once: the next prompt does not repeat it.
    assert!(!app.prompt(&d, "later").await.contains("cosmic-gray"));
}
