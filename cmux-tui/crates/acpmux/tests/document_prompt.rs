//! Document prompts at the daemon boundary. A PDF becomes a workspace resource
//! link for strict ACP harnesses and an Anthropic document block for Claude Code;
//! a file link reaches Claude Code with the path it names.

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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const PDF_DATA: &str = "JVBERi0xLjQ=";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "family": "codex"},
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
        self.new_session_in(harness, &std::env::temp_dir()).await
    }

    async fn new_session_in(&mut self, harness: &str, cwd: &Path) -> String {
        let (reply, _) = self
            .call_text(
                "session/new",
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
            )
            .await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }
}

#[tokio::test]
async fn pdf_reaches_codex_as_a_workspace_resource_link_and_claude_as_a_document() {
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
    let marker = "resource_link:report.pdf:application/pdf:file://";
    let start = echoed.find(marker).expect("Codex resource link");
    let path = echoed[start + marker.len()..].split_whitespace().next().unwrap();
    assert!(std::path::Path::new(&path).is_file(), "{path}: {echoed}");
    assert_eq!(std::fs::read(path).unwrap(), b"%PDF-1.4");
    assert!(!echoed.contains(PDF_DATA), "Codex must not receive PDF base64: {echoed}");

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

fn percent_decode(text: &str) -> Vec<u8> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            out.push(u8::from_str_radix(&text[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

#[tokio::test]
async fn a_saved_pdf_link_is_a_valid_uri_in_a_folder_with_spaces_and_accents() {
    let hub = hub();
    let root = std::env::temp_dir().join(format!("acpmux-pdf-{}", uuid::Uuid::now_v7()));
    let cwd = root.join("my project ü");
    std::fs::create_dir_all(&cwd).unwrap();
    let mut codex = client(&hub);
    let session = codex.new_session_in("fake", &cwd).await;
    let (reply, echoed) = codex
        .call_text(
            "session/prompt",
            json!({
                "sessionId": session,
                "prompt": [
                    {"type": "text", "text": "document-probe"},
                    {"type": "document", "mimeType": "application/pdf", "data": PDF_DATA, "name": "report.pdf"}
                ]
            }),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    let marker = "resource_link:report.pdf:application/pdf:";
    let start = echoed.find(marker).expect("Codex resource link");
    let uri = echoed[start + marker.len()..].split_whitespace().next().unwrap();
    let encoded = uri.strip_prefix("file://").expect("file URI");
    assert!(
        encoded.bytes().all(|b| b.is_ascii_alphanumeric() || b"/-._~%".contains(&b)),
        "URI must be percent-encoded: {uri}"
    );
    let path = std::path::PathBuf::from(String::from_utf8(percent_decode(encoded)).unwrap());
    assert!(path.starts_with(&cwd), "{}", path.display());
    assert_eq!(std::fs::read(&path).unwrap(), b"%PDF-1.4");
    let ignore = path.parent().unwrap().join(".gitignore");
    assert_eq!(std::fs::read_to_string(ignore).unwrap(), "*\n", "saved PDFs stay out of commits");
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn a_file_link_reaches_claude_with_its_decoded_path() {
    let hub = hub();
    let mut claude = client(&hub);
    let session = claude.new_session("fakeclaude").await;
    let uri = "file:///Users/me/Library/Application%20Support/cmux/Chat%20Uploads/a%20b.zip";
    let (reply, echoed) = claude
        .call_text(
            "session/prompt",
            json!({
                "sessionId": session,
                "prompt": [
                    {"type": "text", "text": "resource-probe"},
                    {"type": "resource_link", "uri": uri, "name": "a b.zip"}
                ]
            }),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    let probe: Value = serde_json::from_str(&echoed).expect("Claude resource echo");
    let link = probe["texts"][1].as_str().unwrap_or_default();
    assert!(link.contains(&format!("uri=\"{uri}\"")), "{link}");
    assert!(
        link.contains("path=\"/Users/me/Library/Application Support/cmux/Chat Uploads/a b.zip\""),
        "{link}"
    );
}
