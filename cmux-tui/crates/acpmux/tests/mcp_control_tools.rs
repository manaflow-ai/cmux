//! The `acpmux` MCP server's control tools against a real daemon (RFD 0167 row 8 (c)): a
//! coordinator chat waits on a session it did not start and reads its reply, stops that session's
//! running turn, and is refused its own chat and a name that is no session.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
#[allow(dead_code)]
#[path = "durable_watch_lifecycle/daemon.rs"]
mod daemon;
use acpmux::rpc::method;
use daemon::Daemon;
use serde_json::{Value, json};
use std::{process::Stdio, time::Duration};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// One `tools/call` to a fresh `acpmux acpmux-mcp` process for chat `session`; its result.
async fn mcp(a: &Daemon, session: &str, name: &str, arguments: Value) -> Value {
    let _ = HERMETIC;
    let mut child = daemon_env::tokio_command(a.dir.path(), daemon_env::Agents::StandIn)
        .env("ACPMUX_SOCKET", &a.socket)
        .env("ACPMUX_SESSION_ID", session)
        .arg("acpmux-mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for line in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
            "capabilities": {}, "clientInfo": {"name": "control-test", "version": "0"}}}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}}),
    ] {
        stdin.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let result = tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            let line = lines.next_line().await.unwrap().expect("an MCP reply");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == 2 {
                break v["result"].clone();
            }
        }
    })
    .await
    .expect("the MCP server answers");
    drop(stdin);
    let _ = child.kill().await;
    result
}

fn text(v: &Value) -> &str {
    v["content"][0]["text"].as_str().unwrap_or_default()
}

/// Until `session` runs a turn (`_acpmux/info`'s `turn`).
async fn running(a: &Daemon, session: &str) {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let info = a.call(method::MUX_INFO, json!({"sessionId": session})).await;
            if info.get("turn").is_some_and(|t| !t.is_null()) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the worker's turn starts");
}

#[tokio::test]
async fn a_chat_waits_on_and_stops_a_session_it_did_not_start() {
    let mut a = Daemon::new().await;
    let coord = a.chat("coordinator").await;
    let worker = a.chat("worker").await;

    // Wait on a peer lane by name: its turn's reply comes back in the answer.
    a.send(&worker, "reply-for-the-coordinator").await;
    let waited = mcp(&a, &coord, "wait", json!({"sessions": ["worker"]})).await;
    assert_eq!(waited["isError"], false, "{waited}");
    assert_eq!(waited["structuredContent"]["timedOut"], false, "{waited}");
    let row = &waited["structuredContent"]["sessions"][0];
    assert_eq!(row["sessionId"], json!(&worker), "{waited}");
    assert!(row["reply"].as_str().unwrap().contains("reply-for-the-coordinator"), "{waited}");
    assert!(text(&waited).starts_with("worker: "), "{waited}");

    // Stop its running turn: the turn ends as cancelled, and wait sees it end.
    a.send(&worker, "until-cancel").await;
    running(&a, &worker).await;
    let stopped = mcp(&a, &coord, "cancel", json!({"name": "worker"})).await;
    assert_eq!(stopped["isError"], false, "{stopped}");
    assert_eq!(stopped["structuredContent"], json!({"sessionId": worker, "cancelSent": true}));
    let after = mcp(&a, &coord, "wait", json!({"sessions": "worker", "timeoutSeconds": 30})).await;
    assert_eq!(after["structuredContent"]["timedOut"], false, "{after}");
    let info = a.call(method::MUX_INFO, json!({"sessionId": worker})).await;
    assert!(info.get("turn").is_none_or(Value::is_null), "{info}");

    // Refusals the agent reads, never a silent no-op.
    for (name, arguments, expected) in [
        ("cancel", json!({"name": "coordinator"}), "that is this chat"),
        ("cancel", json!({}), "name is required"),
        ("wait", json!({"sessions": []}), "sessions is required"),
        ("wait", json!({"sessions": ["no-such-session-here"]}), "no-such-session-here"),
    ] {
        let refused = mcp(&a, &coord, name, arguments).await;
        assert_eq!(refused["isError"], true, "{name}: {refused}");
        assert!(text(&refused).contains(expected), "{name}: {refused}");
    }
    a.stop().await;
}
