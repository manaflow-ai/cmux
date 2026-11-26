//! Context surgery (`hub/surgery.rs`) through the hub: `_acpmux/surgery` masks an idle Claude
//! chat's old tool output in a copy of its transcript beside the original, the chat resumes on
//! the copy as the same chat, and its next `turn_result` carries the
//! `harnessMagic.surgery.*` counters. One test function: the settings file is read from this
//! process's env.
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
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    async fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
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
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// The one transcript in `dir` other than `except`.
fn transcript(dir: &Path, except: Option<&Path>) -> PathBuf {
    let found: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "jsonl") && Some(p.as_path()) != except)
        .collect();
    assert_eq!(found.len(), 1, "{found:?}");
    found[0].clone()
}

/// Appends `turns` prompts to transcript `file`, each with one Read of a 6 KB file.
fn add_turns(file: &Path, turns: usize) {
    let sid = file.file_stem().unwrap().to_str().unwrap().to_owned();
    let mut f = std::fs::OpenOptions::new().append(true).open(file).unwrap();
    for t in 0..turns {
        let id = format!("toolu_{t}");
        let lines = [
            json!({"type": "user", "sessionId": sid, "message": {"role": "user", "content": format!("read {t}")}}),
            json!({"type": "assistant", "sessionId": sid, "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": id, "name": "Read", "input": {"file_path": format!("/src/f{t}.rs")}}]}}),
            json!({"type": "user", "sessionId": sid, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": id, "content": "x".repeat(6000)}]}}),
            json!({"type": "assistant", "sessionId": sid, "message": {"role": "assistant", "content": [
                {"type": "text", "text": format!("read {t}")}]}}),
        ];
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
    }
}

#[tokio::test]
async fn surgery_masks_old_tool_output_and_resumes_the_chat_on_the_copy() {
    let root = std::env::temp_dir().join(format!("acpmux-surgery-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("claude")).unwrap();
    let settings = root.join("cmux-next.json");
    // This integration test exercises surgery itself, so opt into the feature
    // explicitly instead of relying on the fleet-only default.
    std::fs::write(&settings, r#"{"agents": {"harnessMagic": {"surgery": {"enabled": true}}}}"#)
        .unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    std::fs::write(root.join("fleet-registry.json"), r#"{"machines": {}}"#).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["python3", FAKE_CLAUDE],
            "env": {"CLAUDE_CONFIG_DIR": root.join("claude")}}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = Client::new(&hub).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let prompt =
        |id: &str, text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    let surgery = |id: &str| json!({"sessionId": id});

    let id = c.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&id, "hello")).await;
    let dir = root.join("claude/projects/p");
    let original = transcript(&dir, None);

    // Too few turns: nothing to mask, and the chat keeps its conversation.
    let none = c.ok("_acpmux/surgery", surgery(&id)).await;
    assert_eq!(none["applied"], false, "{none}");
    assert_eq!(none["reason"], "nothing to mask", "{none}");

    // Five more turns with a 6 KB Read each: the three last prompts keep theirs whole.
    add_turns(&original, 5);
    let before = std::fs::read(&original).unwrap();
    let dry = c.ok("_acpmux/surgery", json!({"sessionId": id, "dryRun": true})).await;
    assert_eq!((dry["dryRun"].clone(), dry["maskedResults"].clone()), (json!(true), json!(2)));
    assert_eq!(transcript(&dir, None), original, "a dry run writes nothing");

    let done = c.ok("_acpmux/surgery", surgery(&id)).await;
    assert_eq!(done["applied"], true, "{done}");
    assert_eq!(done["maskedResults"], 2, "{done}");
    assert_eq!(std::fs::read(&original).unwrap(), before, "the original is never changed");
    let copy = transcript(&dir, Some(&original));
    assert_eq!(done["masked"], copy.display().to_string());
    let text = std::fs::read_to_string(&copy).unwrap();
    assert_eq!(text.matches("[masked by harness: Read /src/f").count(), 2, "{text}");
    assert_eq!(text.lines().count(), String::from_utf8(before).unwrap().lines().count());

    // The same chat answers on the copy: the conversation it resumed is the masked one, whole.
    c.ok("session/prompt", prompt(&id, "history-probe")).await;
    let events = hub.events(&id, 0, 10_000).unwrap();
    // The last reply's chunks: the history-probe's JSON.
    let start = events.iter().rposition(|e| e.kind == "user_message").unwrap();
    let reply: String = events[start..]
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    let probe: Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply}"));
    let copy_id = copy.file_stem().unwrap().to_str().unwrap();
    assert_eq!(probe["sessions"], json!([copy_id]), "{probe}");
    assert_eq!(probe["unresolved"], json!([]), "{probe}");
    assert_eq!(done["agentSessionId"], copy_id);

    // Its next turn carries the counters.
    let result = events.iter().rev().find(|e| e.kind == "turn_result").unwrap();
    assert_eq!(result.msg["harnessMagic.surgery.runs"], 1, "{:?}", result.msg);
    assert_eq!(result.msg["harnessMagic.surgery.maskedResults"], 2, "{:?}", result.msg);
    assert_eq!(result.msg["harnessMagic.surgery.refetched"], 0, "{:?}", result.msg);

    // Off in the settings: refused, nothing written.
    std::fs::write(&settings, r#"{"agents": {"harnessMagic": {"surgery": {"enabled": false}}}}"#)
        .unwrap();
    let off = c.ok("_acpmux/surgery", surgery(&id)).await;
    assert_eq!((off["applied"].clone(), off["reason"].clone()), (json!(false), json!("off")));

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
