//! A chat started with `_meta.acpmux.stopCondition` keeps its agent working until the condition
//! holds: every start of its Claude Code, the first, a respawn and a restart, gets the condition
//! as a prompt Stop hook (`--settings`), the hook Claude Code's `/goal` adds. A Chief subagent
//! starts with it and one prompt, its task, instead of a "reply `ready`" turn and a `/goal`
//! prompt (user, 2026-11-18: "why wasn't it just one prompt?"). A Codex chat (codex-acp) gets it
//! as Codex's own goal (`_session/goal` `set`), once, after its first prompt is written. Another
//! ACP harness keeps none, and the session/new answer says whether it was kept.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
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

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

const CONDITION: &str = "The task in this session's first message is done and landed.";

fn hub() -> Arc<Hub> {
    hub_with(Path::new("/nonexistent"))
}

/// The hub, its fake Codex logging what reached it under `logs`.
fn hub_with(logs: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fake": {"argv": ["python3", FAKE_AGENT]},
            "fakecodex": {"argv": ["python3", FAKE_AGENT], "family": "codex", "env": {
                "FAKE_GOAL_LOG": logs.join("goal.jsonl"),
                "FAKE_WIRE_LOG": logs.join("wire.jsonl"),
            }},
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> (Result<Value, Value>, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => (Err(e.clone()), text),
                    None => (Ok(v["result"].clone()), text),
                };
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn new_session(&mut self, harness: &str, condition: Value) -> Result<Value, Value> {
        let mut acpmux = json!({"harness": harness});
        if !condition.is_null() {
            acpmux["stopCondition"] = condition;
        }
        let params =
            json!({"mcpServers": [], "cwd": std::env::temp_dir(), "_meta": {"acpmux": acpmux}});
        self.call("session/new", params).await.0
    }

    /// The `--settings` documents of the fake Claude Code's argv (it answers a prompt with it).
    async fn settings(&mut self, session: &str) -> Vec<Value> {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
        let (reply, said) = self.call("session/prompt", prompt).await;
        reply.expect("session/prompt");
        let args: Vec<String> =
            serde_json::from_str(&said).unwrap_or_else(|e| panic!("{e}: {said}"));
        args.windows(2)
            .filter(|w| w[0] == "--settings")
            .map(|w| serde_json::from_str(&w[1]).unwrap())
            .collect()
    }
}

/// The settings a stop condition's Claude Code starts with (`hub/stop_condition.rs` `settings`):
/// one prompt check and a cap of one block without a tool call between.
fn stop_hook(condition: &str) -> Value {
    json!({
        "env": {"CLAUDE_CODE_STOP_HOOK_BLOCK_CAP": "1"},
        "hooks": {"Stop": [{"hooks": [{"type": "prompt", "prompt": condition}]}]},
    })
}

#[tokio::test]
async fn claude_code_gets_the_stop_hook_at_every_start() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);

    let created = c.new_session("fakeclaude", json!(CONDITION)).await.expect("session/new");
    assert_eq!(
        created.pointer("/_meta/acpmux/stopCondition"),
        Some(&json!(true)),
        "the answer says it was kept: {created}"
    );
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.settings(&id).await, [stop_hook(CONDITION)], "the first start");

    // Its process ends; the next prompt respawns it and resumes the conversation.
    c.call("session/close", json!({"sessionId": id})).await.0.expect("close");
    assert_eq!(c.settings(&id).await, [stop_hook(CONDITION)], "the respawn");
    c.call("_acpmux/sessions/restart_harness", json!({"sessions": [id]})).await.0.expect("restart");
    assert_eq!(c.settings(&id).await, [stop_hook(CONDITION)], "a restart");

    // A chat started without one gets no hook, and its answer no flag.
    let plain = c.new_session("fakeclaude", Value::Null).await.expect("session/new");
    assert!(plain.pointer("/_meta/acpmux/stopCondition").is_none(), "{plain}");
    assert!(c.settings(plain["sessionId"].as_str().unwrap()).await.is_empty());
}

#[tokio::test]
async fn another_acp_harness_keeps_none_and_says_so() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let created = c.new_session("fake", json!(CONDITION)).await.expect("session/new");
    assert!(created.pointer("/_meta/acpmux/stopCondition").is_none(), "{created}");
}

fn lines(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[tokio::test]
async fn codex_gets_the_condition_as_its_goal_once_after_its_first_prompt() {
    let _hermetic = &HERMETIC;
    let logs = tempfile::tempdir().unwrap();
    let hub = hub_with(logs.path());
    let mut c = Client::new(&hub);
    let created = c.new_session("fakecodex", json!(CONDITION)).await.expect("session/new");
    assert_eq!(
        created.pointer("/_meta/acpmux/stopCondition"),
        Some(&json!(true)),
        "the answer says it was kept: {created}"
    );
    let id = created["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.call("session/prompt", prompt).await.0.expect("session/prompt");
    }
    // The goal goes out beside the first prompt, unanswered: wait (bounded) for it to land.
    let goal_log = logs.path().join("goal.jsonl");
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while lines(&goal_log).is_empty() && std::time::Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let wire = lines(&logs.path().join("wire.jsonl"));
    let method = |m: &str| wire.iter().position(|l| l["method"] == m);
    let first_prompt = method("session/prompt").expect("a prompt reached Codex");
    let goal = method("_session/goal").expect("the goal reached Codex");
    assert!(first_prompt < goal, "the goal follows the first prompt: {wire:?}");
    assert_eq!(
        wire.iter().filter(|l| l["method"] == "_session/goal").count(),
        1,
        "once, not at every prompt: {wire:?}"
    );
    let goals = lines(&goal_log);
    assert_eq!(goals.len(), 1, "{goals:?}");
    assert_eq!(goals[0]["action"], "set");
    assert_eq!(goals[0]["objective"], CONDITION);
    assert_eq!(goals[0]["sessionId"], wire[first_prompt]["session"], "the agent's own session");
}

#[tokio::test]
async fn a_bad_condition_is_refused() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    for bad in [json!(""), json!(7), json!("x".repeat(4001))] {
        let err = c.new_session("fakeclaude", bad.clone()).await.expect_err("refused");
        assert!(err.to_string().contains("stopCondition"), "{bad}: {err}");
    }
}
