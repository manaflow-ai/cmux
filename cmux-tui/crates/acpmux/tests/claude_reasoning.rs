//! Claude Code's reasoning options, as the composer shows them.
//!
//! The Reasoning select lists only Claude Code's effort levels. Ultracode is
//! a Claude Code setting (workflow orchestration at Extra High), not a level,
//! so it is its own On/Off switch. No choice rewrites the person's prompt.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// One local client of the hub (the app pane's connection).
struct TestClient {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl TestClient {
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

/// The person key this test's hub holds, as a daemon the app started does.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn cwd() -> String {
    std::env::temp_dir().to_string_lossy().into_owned()
}

/// A hub whose only harness runs `fake_claude.py` as Claude Code.
async fn claude_setup() -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fakeclaude".to_owned(),
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("fakeclaude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    // The client is the person at the app (`hub/person.rs`): Fast mode and the
    // `ultracode` option are theirs to switch (the app's pane rides `effort`).
    hub.person.install_spawn_key(PERSON_KEY).unwrap();
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    let r = c.request("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
    assert_eq!(r["person"], json!(true), "{r}");
    (hub, c)
}

fn option<'a>(options: &'a Value, id: &str) -> &'a Value {
    options
        .as_array()
        .and_then(|a| a.iter().find(|o| o["id"] == id))
        .unwrap_or_else(|| panic!("no {id} option: {options}"))
}

fn values(option: &Value) -> Vec<String> {
    option["options"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["value"].as_str().unwrap().to_owned())
        .collect()
}

async fn set(c: &mut TestClient, id: &str, config: &str, value: &str) -> Value {
    let r = c
        .request(
            method::SESSION_SET_CONFIG_OPTION,
            json!({"sessionId": id, "configId": config, "value": value}),
        )
        .await
        .unwrap();
    r["configOptions"].clone()
}

/// What Claude Code read: the prompt text, every flag-settings change and its argv.
async fn probe(hub: &Arc<Hub>, c: &mut TestClient, id: &str) -> Value {
    let before = hub.events(id, 0, 10_000).unwrap().len();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "settings-probe"}]}),
    )
    .await
    .unwrap();
    let text: String = hub
        .events(id, 0, 10_000)
        .unwrap()
        .iter()
        .skip(before)
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{e}: {text}"))
}

#[tokio::test]
async fn claude_reasoning_lists_effort_levels_and_ultracode_is_its_own_switch() {
    let (hub, mut c) = claude_setup().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude", "name": "think"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();

    let options = set(&mut c, &id, "effort", "high").await;
    let effort = option(&options, "effort");
    assert_eq!(values(effort), ["default", "low", "medium", "high", "xhigh", "max"], "{effort}");
    assert_eq!(effort["currentValue"], "high");
    let ultracode = option(&options, "ultracode");
    assert_eq!(values(ultracode), ["off", "on"], "{ultracode}");
    assert_eq!(ultracode["currentValue"], "off");

    // Ultracode on: Claude Code runs at Extra High with its ultracode setting.
    let options = set(&mut c, &id, "ultracode", "on").await;
    assert_eq!(option(&options, "ultracode")["currentValue"], "on");
    assert_eq!(option(&options, "effort")["currentValue"], "xhigh");
    let got = probe(&hub, &mut c, &id).await;
    assert_eq!(got["said"], "settings-probe", "the prompt reaches Claude as typed: {got}");
    assert_eq!(
        got["settings"].as_array().unwrap().last().unwrap(),
        &json!({"effortLevel": "xhigh", "ultracode": true}),
        "{got}"
    );

    // Picking a level turns Ultracode off.
    let options = set(&mut c, &id, "effort", "medium").await;
    assert_eq!(option(&options, "ultracode")["currentValue"], "off");
    assert_eq!(option(&options, "effort")["currentValue"], "medium");
    let got = probe(&hub, &mut c, &id).await;
    assert_eq!(
        got["settings"].as_array().unwrap().last().unwrap(),
        &json!({"effortLevel": "medium", "ultracode": false}),
        "{got}"
    );

    // Ultracode survives a respawn: Extra High on the command line, the
    // setting on the live channel before the first turn.
    set(&mut c, &id, "ultracode", "on").await;
    let session = hub.resolve("think").unwrap();
    hub.detach_child(&session).await;
    let got = probe(&hub, &mut c, &id).await;
    let argv: Vec<String> = serde_json::from_value(got["argv"].clone()).unwrap();
    let at = argv.iter().position(|a| a == "--effort").unwrap_or_else(|| panic!("{argv:?}"));
    assert_eq!(argv[at + 1], "xhigh", "{argv:?}");
    assert_eq!(got["settings"], json!([{"effortLevel": "xhigh", "ultracode": true}]), "{got}");
    assert_eq!(got["said"], "settings-probe", "{got}");
}

#[tokio::test]
async fn claude_reasoning_a_saved_ultrathink_pick_runs_the_default_level_unrewritten() {
    let (hub, mut c) = claude_setup().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude", "name": "legacy"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // An older pane (or a remembered pick) still sends the retired value.
    let options = set(&mut c, &id, "effort", "ultrathink").await;
    assert_eq!(option(&options, "effort")["currentValue"], "default", "{options}");
    let got = probe(&hub, &mut c, &id).await;
    assert_eq!(got["said"], "settings-probe", "{got}");
    assert_eq!(
        got["settings"].as_array().unwrap().last().unwrap(),
        &json!({"effortLevel": "auto", "ultracode": false}),
        "{got}"
    );
}

#[tokio::test]
async fn claude_reasoning_a_new_chat_attaches_with_its_effort_and_fast_options() {
    // The composer draws Reasoning and Fast mode from the attached chat's
    // options (Lawrence 2026-10-14: "we lost effort").
    let (_hub, mut c) = claude_setup().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude", "name": "fresh"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for moment in ["before its first prompt", "after its first prompt"] {
        let a = c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
        let options = &a["session"]["configOptions"];
        assert!(options.is_array(), "{moment}: no options: {a}");
        assert!(values(option(options, "effort")).len() > 1, "{moment}: {options}");
        assert_eq!(values(option(options, "fast-mode")), ["off", "on"], "{moment}: {options}");
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await
        .unwrap();
    }
}
