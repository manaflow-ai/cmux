//! A prompt's hidden context at the daemon boundary (cx-ihyx2): `_meta.acpmux.context` on
//! `session/prompt` reaches the agent after the person's text, and the recorded
//! `user_message`, the session's title and its last prompt show only the person's text.
//! A block a client marks as context by itself stays visible.

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
const CONTEXT: &str = "<cmux-workspace-context>CTX-MARK</cmux-workspace-context>";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE, "--fake", "FAKE_ECHO_GUIDANCE", "1"], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        Self::open_as(hub, Origin::Local)
    }

    fn open_as(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self(in_tx, out_rx, 0)
    }

    /// The raw reply to one request (an error is returned, not asserted).
    async fn reply(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    /// The reply to one request and the agent message text streamed before it.
    async fn call(&mut self, method: &str, params: Value) -> (Value, String) {
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
                assert!(value.get("error").is_none(), "{method}: {value}");
                return (value["result"].clone(), text);
            }
            if value.pointer("/params/update/sessionUpdate").and_then(Value::as_str)
                == Some("agent_message_chunk")
                && let Some(chunk) =
                    value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(chunk);
            }
        }
    }

    async fn user_messages(&mut self, session: &str) -> Vec<String> {
        let (page, _) = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["msg"]["text"].as_str().unwrap_or_default().to_owned())
            .collect()
    }
}

#[tokio::test]
async fn the_agent_gets_the_context_and_the_transcript_shows_only_the_persons_text() {
    let hub = hub();
    let mut client = Client::open(&hub);
    let (created, _) = client
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
        .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();

    let (_, echoed) = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "what runs in my terminal?"}],
                   "_meta": {"acpmux": {"context": CONTEXT}}}),
        )
        .await;
    assert!(echoed.contains("what runs in my terminal?"), "{echoed}");
    assert!(echoed.contains("CTX-MARK"), "the agent did not get the context: {echoed}");
    assert!(echoed.contains(acpmux::agent_tools::CONCURRENT_WORK_RULE), "{echoed}");

    // A block the client marks as context itself is the person's text like any other.
    let (_, echoed) = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [
                {"type": "text", "text": "second", "_meta": {"acpmux": {"context": true}}}]}),
        )
        .await;
    assert!(echoed.contains("second"), "{echoed}");
    assert!(!echoed.contains(acpmux::agent_tools::CONCURRENT_WORK_RULE), "{echoed}");

    assert_eq!(client.user_messages(&session).await, ["what runs in my terminal?", "second"]);
    let (info, _) = client.call("_acpmux/info", json!({"sessionId": session})).await;
    let shown = info.to_string();
    assert!(
        !shown.contains("CTX-MARK"),
        "the session's title or preview shows the context: {shown}"
    );
    assert!(shown.contains("what runs in my terminal?"), "{shown}");
}

#[tokio::test]
async fn a_context_that_is_not_text_or_comes_from_a_web_client_is_refused() {
    let hub = hub();
    let mut client = Client::open(&hub);
    let (created, _) = client
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
        .await;
    let session = created["sessionId"].as_str().unwrap();
    for context in [json!(7), json!("  "), json!("x".repeat(acpmux::prompt_context::MAX_BYTES + 1))]
    {
        let params = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}],
                            "_meta": {"acpmux": {"context": context}}});
        let value = client.reply("session/prompt", params).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("context.value_refused")),
            "{value}"
        );
    }
    // A peer daemon relaying its remote web client's prompt (`via: web`) may not hide text.
    let mut relay = Client::open_as(&hub, Origin::Peer);
    let value = relay
        .reply(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}],
                   "_meta": {"acpmux": {"context": CONTEXT, "via": "web"}}}),
        )
        .await;
    assert!(value.get("error").is_some(), "a web client's context was taken: {value}");
    assert!(client.user_messages(session).await.is_empty(), "a refused prompt was recorded");
}

/// A Claude Code chat gets cmux's rules in its system prompt (`--append-system-prompt`), at
/// every start of its harness, and never as a hidden block after the person's first prompt.
#[tokio::test]
async fn a_claude_chat_gets_the_rules_in_its_system_prompt() {
    const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut client = Client::open(&hub);
    let (created, _) = client
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude"}}}))
        .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    for _ in 0..2 {
        let (_, reply) = client
            .call(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": "settings-probe"}]}),
            )
            .await;
        let probe: Value = serde_json::from_str(&reply).unwrap();
        let argv: Vec<String> = serde_json::from_value(probe["argv"].clone()).unwrap();
        let at = argv.iter().position(|a| a == "--append-system-prompt").expect("no system prompt");
        assert!(argv[at + 1].starts_with(acpmux::agent_tools::CONCURRENT_WORK_RULE), "{argv:?}");
        assert_eq!(argv.iter().filter(|a| *a == "--append-system-prompt").count(), 1, "{argv:?}");
        assert_eq!(probe["said"], "settings-probe", "{probe}");
        // In the system prompt, so never in a message too.
        assert_eq!(probe["guidance"], 0, "{probe}");
    }
    // The Context viewer still lists the rule, editable and switchable, on its new channel.
    let (inventory, _) = client.call("_acpmux/context", json!({"sessionId": session})).await;
    let rule = inventory["parts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["source"] == "cmux-default")
        .unwrap_or_else(|| panic!("no rule part: {inventory}"));
    assert_eq!(rule["channel"], "append-system-prompt", "{rule}");
    assert_eq!(rule["label"], "cmux guidance (system prompt)", "{rule}");
    assert_eq!(rule["editable"], true, "{rule}");
    assert_eq!(rule["included"], true, "{rule}");
}

/// A Claude profile with its own `--append-system-prompt` keeps it: cmux's rules go in the
/// first message, once.
#[tokio::test]
async fn a_claude_chat_with_its_own_appended_prompt_gets_the_rules_in_its_first_message_once() {
    const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {
            "argv": ["python3", FAKE_CLAUDE, "--append-system-prompt", "mine"],
            "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut client = Client::open(&hub);
    let (created, _) = client
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude"}}}))
        .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let mut guidance = Vec::new();
    for _ in 0..2 {
        let (_, reply) = client
            .call(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": "settings-probe"}]}),
            )
            .await;
        let probe: Value = serde_json::from_str(&reply).unwrap();
        let argv: Vec<String> = serde_json::from_value(probe["argv"].clone()).unwrap();
        assert_eq!(argv.iter().filter(|a| *a == "--append-system-prompt").count(), 1, "{argv:?}");
        assert!(argv.iter().any(|a| a == "mine"), "{argv:?}");
        guidance.push(probe["guidance"].as_u64().unwrap());
    }
    assert!(guidance[0] >= 1, "{guidance:?}");
    assert_eq!(guidance[1], 0, "{guidance:?}");
}
