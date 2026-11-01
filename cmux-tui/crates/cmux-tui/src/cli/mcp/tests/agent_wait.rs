//! `agents_wait` at the MCP boundary: an agent waits for another agent to
//! finish, for a dialog or for text on a screen instead of polling
//! `agents_snapshot`, and gets a receipt with a fresh state either way.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Change, Fake, SharedBuffer, WORKSPACE, call, sent_of};
use crate::cli::mcp::{Server, watch};

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const AGENT: &str = "agent_0123456789abcdef0123456789abcdef";

/// One workspace with one terminal tab whose agent reports `state`.
fn daemon(state: &str) -> Value {
    json!({
        "workspaces": [{"id": WORKSPACE}],
        "tabs": [{"id": TAB}],
        "terminals": [{"id": TERMINAL, "tab_id": TAB, "tab_ids": [TAB], "running": true}],
        "agents": [{"id": AGENT, "terminal_id": TERMINAL, "state": state, "source": "hook"}],
    })
}

fn waited(receipt: &Value) -> f64 {
    receipt["waited_seconds"].as_f64().unwrap_or_else(|| panic!("waited_seconds: {receipt}"))
}

#[test]
fn agents_wait_is_listed_as_a_bounded_read() {
    let mut server = Server::new(Fake::default(), None);
    let tools = server.list();
    let tool = tools.iter().find(|tool| tool["name"] == "agents_wait").expect("agents_wait");
    assert_eq!(tool["annotations"]["readOnlyHint"], true, "{tool}");
    assert_eq!(tool["annotations"]["idempotentHint"], true);
    assert_eq!(tool["annotations"]["destructiveHint"], false);
    let schema = &tool["inputSchema"];
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(schema["required"], json!(["until"]));
    assert_eq!(schema["properties"]["until"]["enum"], json!(["idle", "dialog", "text"]));
    assert_eq!(schema["properties"]["timeout_seconds"]["maximum"], 120);
    assert_eq!(schema["properties"]["timeout_seconds"]["default"], 30);
    assert!(schema["properties"].get("idempotency_key").is_none(), "a read takes no key");
    let description = tool["description"].as_str().unwrap();
    assert!(description.contains("other agents"), "{description}");
}

#[test]
fn agents_wait_idle_matches_when_the_agent_finishes_mid_wait() {
    let fake = Fake::live(Some(daemon("working")), None)
        .then(Duration::from_millis(600), Change::Daemon(daemon("idle")));
    let mut server = Server::new(fake, None);
    let started = Instant::now();
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": 10}),
    );
    let elapsed = started.elapsed();
    assert_eq!(result["isError"], false, "{result}");
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["until"], "idle");
    assert_eq!(receipt["matched"], true, "{receipt}");
    assert_eq!(receipt["match"]["target"], TERMINAL);
    assert_eq!(receipt["match"]["state"], "idle");
    assert!(waited(receipt) >= 0.5, "it waited for the change: {receipt}");
    assert!(elapsed < Duration::from_secs(5), "it answered on the change, not the timeout");
    assert_eq!(receipt["state"]["sources"]["daemon"]["available"], true, "{receipt}");
    assert_eq!(receipt["state"]["terminals"][0]["id"], TERMINAL);
}

#[test]
fn agents_wait_idle_targets_the_tab_and_the_agent_id_too() {
    for target in [TAB, AGENT] {
        let mut server = Server::new(Fake::live(Some(daemon("idle")), None), None);
        let result = call(&mut server, "agents_wait", json!({"until": "idle", "target": target}));
        let receipt = &result["structuredContent"];
        assert_eq!(receipt["matched"], true, "{target}: {result}");
        assert_eq!(receipt["match"]["terminal"], TERMINAL, "{target}");
    }
}

/// A GUI chat that starts while the app is unavailable still runs in acpmux, with
/// a session UUID but no terminal, agent_ record or visible tab. Waiting on the
/// UUID must read the scoped acpmux state instead of calling it missing.
#[test]
fn agents_wait_uses_chat_state_for_a_tabless_session() {
    const CHAT: &str = "01234567-89ab-4cde-8f01-23456789abcd";
    let daemon = |running: bool| {
        json!({
            "workspaces": [{"id": WORKSPACE}],
            "chats": [{
                "chat": CHAT, "running": running,
                "status": if running { "running" } else { "ready" },
                "queued": 0, "pending_permissions": 0
            }],
        })
    };
    let mut working = Server::new(Fake::live(Some(daemon(true)), None), None);
    let result = call(
        &mut working,
        "agents_wait",
        json!({
            "until": "idle", "target": CHAT, "timeout_seconds": 0.1
        }),
    );
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["matched"], false, "{result}");

    let mut ready = Server::new(Fake::live(Some(daemon(false)), None), None);
    let result = call(
        &mut ready,
        "agents_wait",
        json!({
            "until": "idle", "target": CHAT, "timeout_seconds": 1, "session": "another"
        }),
    );
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["matched"], true, "{result}");
    assert_eq!(result["structuredContent"]["match"]["state"], "idle", "{result}");
    assert_eq!(result["structuredContent"]["match"]["chat"], CHAT, "{result}");
    let requests = sent_of(&ready, "chat");
    assert!(requests.iter().any(|row| row["session"] == "another"), "{requests:?}");
}

#[test]
fn agents_wait_unknown_chat_still_reports_selector_not_found() {
    const CHAT: &str = "12345678-1234-4234-8234-123456789abc";
    let mut server = Server::new(Fake::live(Some(json!({"workspaces": []})), None), None);
    let result = call(&mut server, "agents_wait", json!({"until": "idle", "target": CHAT}));
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("selector.not_found"), "{result}");
}

#[test]
fn agents_wait_returns_at_once_when_the_condition_already_holds() {
    let mut server = Server::new(Fake::live(Some(daemon("idle")), None), None);
    let started = Instant::now();
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": 30}),
    );
    assert_eq!(result["structuredContent"]["matched"], true, "{result}");
    assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
    assert!(waited(&result["structuredContent"]) < 1.0);
}

#[test]
fn agents_wait_timeout_is_an_unmatched_receipt_not_an_error() {
    let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
    let started = Instant::now();
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": 1}),
    );
    let elapsed = started.elapsed();
    assert_eq!(result["isError"], false, "a timeout is an answer: {result}");
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["matched"], false, "{receipt}");
    assert_eq!(receipt["match"], Value::Null);
    assert!(waited(receipt) >= 0.9, "{receipt}");
    assert!(elapsed < Duration::from_millis(2500), "within the timeout and slack: {elapsed:?}");
    assert_eq!(receipt["state"]["terminals"][0]["id"], TERMINAL, "{receipt}");
}

#[test]
fn agents_wait_dialog_matches_when_a_dialog_appears() {
    let dialog = json!({
        "id": "feed_1", "request_id": "request_a", "workstream_id": "chat_build",
        "source": "claude", "kind": "permissionRequest", "status": "pending",
    });
    let fake = Fake::live(Some(daemon("working")), Some(json!({"items": []})))
        .then(Duration::from_millis(600), Change::Feed(json!({"items": [dialog]})));
    let mut server = Server::new(fake, None);
    let started = Instant::now();
    let result =
        call(&mut server, "agents_wait", json!({"until": "dialog", "timeout_seconds": 10}));
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["matched"], true, "{result}");
    assert_eq!(receipt["match"]["dialogs"][0]["request_id"], "request_a", "{receipt}");
    assert!(waited(receipt) >= 0.5, "{receipt}");
    assert!(started.elapsed() < Duration::from_secs(5));
    let lists = sent_of(&server, "app")
        .into_iter()
        .filter(|sent| sent["method"] == "feed.list")
        .collect::<Vec<_>>();
    assert!(lists.iter().all(|sent| sent["params"]["pending_only"] == true), "{lists:?}");

    // A filter that names another agent's session does not match.
    let fake = Fake::live(Some(daemon("working")), Some(json!({"items": [dialog]})));
    let mut server = Server::new(fake, None);
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "dialog", "target": "chat_other", "timeout_seconds": 1}),
    );
    assert_eq!(result["structuredContent"]["matched"], false, "{result}");
    let mut server = Server::new(Fake::live(None, Some(json!({"items": [dialog]}))), None);
    let result =
        call(&mut server, "agents_wait", json!({"until": "dialog", "target": "chat_build"}));
    assert_eq!(result["structuredContent"]["matched"], true, "{result}");
}

#[test]
fn agents_wait_text_waits_on_the_daemon_for_the_tab_terminal() {
    let fake = Fake {
        resource_result: Some(json!({"matched": true, "text": "$ make\nbuild a.b ok\n$ "})),
        ..Fake::live(Some(daemon("working")), None)
    };
    let mut server = Server::new(fake, None);
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "text", "target": TAB, "text": "a.b ok", "timeout_seconds": 20}),
    );
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["matched"], true, "{result}");
    assert_eq!(receipt["match"]["terminal"], TERMINAL);
    assert!(receipt["match"]["screen"].as_str().unwrap().contains("build a.b ok"), "{receipt}");
    let wait = sent_of(&server, "resource")
        .into_iter()
        .find(|sent| sent["request"]["operation"] == "terminal.wait")
        .expect("one daemon wait, no polling");
    let params = &wait["request"]["params"];
    assert_eq!(params["terminal"], TERMINAL);
    assert_eq!(params["pattern"], "a\\.b ok", "text is literal");
    let timeout_ms = params["timeout_ms"].as_str().unwrap().parse::<u64>().unwrap();
    assert!((19_000..=20_000).contains(&timeout_ms), "{timeout_ms}");

    let mut server = Server::new(
        Fake {
            resource_result: Some(json!({"matched": false, "text": "$ "})),
            ..Fake::live(Some(daemon("working")), None)
        },
        None,
    );
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "text", "target": TERMINAL, "text": "^done [0-9]+$", "regex": true}),
    );
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["matched"], false);
    let wait = sent_of(&server, "resource")
        .into_iter()
        .find(|sent| sent["request"]["operation"] == "terminal.wait")
        .unwrap();
    assert_eq!(wait["request"]["params"]["pattern"], "^done [0-9]+$");
}

#[test]
fn agents_wait_text_reports_a_terminal_that_closes_mid_wait() {
    let gone =
        json!({"workspaces": [{"id": WORKSPACE}], "tabs": [], "terminals": [], "agents": []});
    let fake = Fake {
        fail_after: Some(("terminal.wait", Duration::from_millis(400))),
        ..Fake::live(Some(daemon("working")), None)
            .then(Duration::from_millis(200), Change::Daemon(gone))
    };
    let mut server = Server::new(fake, None);
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "text", "target": TERMINAL, "text": "done", "timeout_seconds": 10}),
    );
    assert_eq!(result["isError"], false, "as idle reports it: {result}");
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["matched"], true, "{receipt}");
    assert_eq!(receipt["match"]["state"], "closed", "{receipt}");
    assert_eq!(receipt["match"]["terminal"], TERMINAL);
}

#[test]
fn agents_wait_refuses_an_invalid_regex_and_an_unknown_dialog_agent_before_waiting() {
    for text in ["(", "[a-", "a{2,1}"] {
        let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
        let result = call(
            &mut server,
            "agents_wait",
            json!({"until": "text", "target": TERMINAL, "text": text, "regex": true}),
        );
        assert_eq!(result["isError"], true, "{text}: {result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{text}");
        assert!(server.backend.sent.borrow().is_empty(), "{text} reached an owner");
    }
    // A dialog wait for an agent no owner knows fails as idle and text do;
    // it does not wait out its timeout.
    let started = Instant::now();
    let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
    let result = call(
        &mut server,
        "agents_wait",
        json!({"until": "dialog", "target": "term_fedcba9876543210fedcba9876543210",
               "timeout_seconds": 5}),
    );
    assert_eq!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["state"], "not_run");
    assert_eq!(result["structuredContent"]["error"]["code"], "selector.not_found", "{result}");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

#[test]
fn agents_wait_refuses_bad_arguments_before_reaching_an_owner() {
    for arguments in [
        json!({}),
        json!({"until": "soon"}),
        json!({"until": "idle"}),
        json!({"until": "idle", "target": "--all"}),
        json!({"until": "text", "target": TERMINAL}),
        json!({"until": "text", "text": "ok"}),
        json!({"until": "dialog", "text": "ok"}),
        json!({"until": "idle", "target": TERMINAL, "regex": true}),
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": 121}),
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": -1}),
        json!({"until": "idle", "target": TERMINAL, "timeout_seconds": "5"}),
        json!({"until": "idle", "target": TERMINAL, "idempotency_key": "k"}),
        json!({"until": "idle", "target": TERMINAL, "bogus": 1}),
    ] {
        let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
        let result = call(&mut server, "agents_wait", arguments.clone());
        assert_eq!(result["isError"], true, "{arguments}: {result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{arguments}");
        assert!(server.backend.sent.borrow().is_empty(), "{arguments} reached an owner");
    }
    // A target no owner knows is refused too, after one read.
    let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
    let missing = "term_fedcba9876543210fedcba9876543210";
    let result = call(&mut server, "agents_wait", json!({"until": "idle", "target": missing}));
    assert_eq!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["state"], "not_run");
    assert_eq!(result["structuredContent"]["error"]["code"], "selector.not_found", "{result}");
}

#[test]
fn agents_wait_reports_progress_when_the_client_asks_for_it() {
    let mut server = Server::new(Fake::live(Some(daemon("working")), None), None);
    let request = json!({
        "jsonrpc": "2.0", "id": "w", "method": "tools/call",
        "params": {
            "name": "agents_wait",
            "arguments": {"until": "idle", "target": TERMINAL, "timeout_seconds": 1},
            "_meta": {"progressToken": "wait-1"},
        },
    });
    let buffer = SharedBuffer::default();
    let input = format!("{request}\n");
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let lines = buffer
        .text()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    let progress =
        lines.iter().filter(|line| line["method"] == "notifications/progress").collect::<Vec<_>>();
    assert!(!progress.is_empty(), "{lines:?}");
    for note in &progress {
        assert_eq!(note["params"]["progressToken"], "wait-1");
        assert_eq!(note["params"]["total"], 1.0);
        assert!(note["params"]["progress"].as_f64().unwrap() <= 1.0, "{note}");
    }
    let answer = lines.last().unwrap();
    assert_eq!(answer["id"], "w", "the answer comes after the notes: {lines:?}");
    assert_eq!(answer["result"]["structuredContent"]["matched"], false);
}
