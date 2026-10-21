//! A chat started with `_meta.acpmux.disallowedTools` (Claude Code built-in
//! tool names) never gets those tools: every start of its Claude Code, the
//! first, a respawn and a resume, gets `--disallowedTools NAME` for each.
//! `acpmux new --worktree` or `--prompt-file` (a lane another agent starts,
//! with nobody at its chat) sends `["AskUserQuestion"]`: a multiple-choice
//! question there waits for an answer that never comes and locks the chat.

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

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
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

    /// The reply (Ok result or Err error object) and the text streamed before it.
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

    async fn new_session(&mut self, disallowed: Value) -> Result<Value, Value> {
        let meta = json!({"harness": "fakeclaude", "disallowedTools": disallowed});
        let params =
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        self.call("session/new", params).await.0
    }

    /// The `--disallowedTools` values of the fake Claude Code's argv, which
    /// it replies with to a plain prompt.
    async fn disallowed(&mut self, session: &str) -> Vec<String> {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
        let (reply, said) = self.call("session/prompt", prompt).await;
        reply.expect("session/prompt");
        let args: Vec<String> =
            serde_json::from_str(&said).unwrap_or_else(|e| panic!("{e}: {said}"));
        args.windows(2).filter(|w| w[0] == "--disallowedTools").map(|w| w[1].clone()).collect()
    }
}

#[tokio::test]
async fn a_chat_started_without_ask_user_question_never_gets_it() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);

    let created = c.new_session(json!(["AskUserQuestion"])).await.expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.disallowed(&id).await, ["AskUserQuestion"], "the first start");

    // Its process ends; the next prompt respawns it and resumes the conversation.
    c.call("session/close", json!({"sessionId": id})).await.0.expect("close");
    assert_eq!(c.disallowed(&id).await, ["AskUserQuestion"], "the respawn");
    c.call("_acpmux/sessions/restart_harness", json!({"sessions": [id]})).await.0.expect("restart");
    assert_eq!(c.disallowed(&id).await, ["AskUserQuestion"], "a restart");

    // A chat started without the list keeps every tool.
    let plain = c.new_session(Value::Null).await.expect("session/new");
    assert!(c.disallowed(plain["sessionId"].as_str().unwrap()).await.is_empty());

    // Only tool names: a permission rule or a flag would widen what is passed.
    for bad in [json!("AskUserQuestion"), json!([""]), json!(["Bash(rm *)"]), json!(["--x"])] {
        let e = c.new_session(bad.clone()).await.expect_err(&format!("{bad} is refused"));
        assert_eq!(e["code"], json!(-32602), "{bad}: {e}");
    }
}
