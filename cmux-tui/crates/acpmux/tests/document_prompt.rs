//! Document prompts at the daemon boundary. A PDF must remain a binary resource
//! for strict ACP harnesses and become an Anthropic document block for Claude Code.

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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const PDF_DATA: &str = "JVBERi0xLjQ=";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, method: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(chunk) =
                value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(chunk);
            }
        }
    }

    async fn new_session(&mut self, harness: &str) -> String {
        let (reply, _) = self
            .call_text(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
            )
            .await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }
}

#[tokio::test]
async fn pdf_reaches_codex_and_claude_as_a_document() {
    let hub = hub();
    let prompt = json!({
        "prompt": [
            {"type": "text", "text": "document-probe"},
            {"type": "document", "mimeType": "application/pdf", "data": PDF_DATA, "name": "report.pdf"}
        ]
    });

    let mut codex = client(&hub);
    let codex_session = codex.new_session("fake").await;
    let mut codex_prompt = prompt.clone();
    codex_prompt["sessionId"] = json!(codex_session);
    let (reply, echoed) = codex.call_text("session/prompt", codex_prompt).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(echoed.contains("resource:report.pdf:application/pdf:JVBERi0xLjQ="), "{echoed}");

    let mut claude = client(&hub);
    let claude_session = claude.new_session("fakeclaude").await;
    let mut claude_prompt = prompt;
    claude_prompt["sessionId"] = json!(claude_session);
    let (reply, echoed) = claude.call_text("session/prompt", claude_prompt).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let document: Value = serde_json::from_str(&echoed).expect("Claude document echo");
    assert_eq!(document["documents"][0]["type"], "document");
    assert_eq!(document["documents"][0]["title"], "report.pdf");
    assert_eq!(document["documents"][0]["media_type"], "application/pdf");
    assert_eq!(document["documents"][0]["data"], PDF_DATA);
}
