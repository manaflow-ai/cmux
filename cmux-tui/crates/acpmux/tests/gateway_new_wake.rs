//! A chat that starts a helper with its `new` tool, served by the daemon's MCP gateway, then gives
//! that idle helper work with `send` (class action): the tool text says it wakes the helper, as
//! it does a chat the sender started from its shell.
//!
//! On the base the gateway ran the `new` tool's `acpmux new` without the chat's env, which the
//! gateway keeps only in the request's scope: the CLI found no caller token, declared itself the
//! person's terminal, and the helper had no parent. The starter's action then waited for the
//! result deadline (15 min) like anyone's, measured at 15 min on a live chat. This test times the
//! delay from the send to the helper's turn.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
#[allow(dead_code)]
#[path = "durable_watch_lifecycle/daemon.rs"]
mod daemon;
use acpmux::client::Client;
use acpmux::rpc::method;
use daemon::Daemon;
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

async fn call(client: &Client, method: &str, params: Value) -> Value {
    tokio::time::timeout(Duration::from_secs(30), client.request(method, params))
        .await
        .expect(method)
        .unwrap()
}

/// One MCP request to the gateway `server` (its `url` and `headers`, as the harness got them);
/// the JSON-RPC answer.
fn post(server: &Value, body: Value) -> Value {
    let mut curl = std::process::Command::new("curl");
    curl.args(["-sS", "--max-time", "60", "-X", "POST", server["url"].as_str().unwrap()]).args([
        "-H",
        "content-type: application/json",
        "-H",
        "accept: application/json",
    ]);
    for header in server["headers"].as_array().into_iter().flatten() {
        curl.args([
            "-H",
            &format!("{}: {}", header["name"].as_str().unwrap(), header["value"].as_str().unwrap()),
        ]);
    }
    let out = curl.args(["--data-binary", &body.to_string()]).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().rev().find_map(|l| l.strip_prefix("data: ")).unwrap_or(&text);
    serde_json::from_str(line.trim()).unwrap_or_else(|e| panic!("{e}: {text}"))
}

fn tool(server: &Value, name: &str, arguments: Value) -> Value {
    let answer = post(
        server,
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}}),
    );
    let result = answer["result"].clone();
    assert_eq!(result["isError"], false, "{name}: {answer}");
    result
}

/// `session`'s row in `_acpmux/list`.
async fn row(client: &Client, session: &str) -> Value {
    let list = call(client, method::MUX_SESSIONS, json!({})).await;
    let rows = list["sessions"].as_array().cloned().unwrap_or_default();
    rows.into_iter().find(|r| r["sessionId"] == session).unwrap_or(Value::Null)
}

/// Until `session` has run `turns` turns and is idle, at most `bound`; how long it took.
async fn turns(client: &Client, session: &str, turns: u64, bound: Duration) -> Option<Duration> {
    let start = Instant::now();
    while start.elapsed() < bound {
        let r = row(client, session).await;
        if r["turnCount"].as_u64().unwrap_or(0) >= turns && r["turn"].is_null() {
            return Some(start.elapsed());
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    None
}

#[tokio::test]
async fn a_starters_action_wakes_the_idle_helper_its_new_tool_started() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("gn");
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let given = dir.path().join("given-mcp");
    std::fs::write(
        dir.path().join("config.json"),
        json!({
            "harnesses": {"fake": {"argv": ["python3", fake],
                "env": {"FAKE_MCP_HTTP": "1", "FAKE_MCP_OUT": given}}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all",
            "permissionGroups": {"enabled": false}, "webRoots": [dir.path()]
        })
        .to_string(),
    )
    .unwrap();
    std::fs::set_permissions(
        dir.path().join("config.json"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let (mut child, client, _listen, _socket) = Daemon::start(dir.path()).await;

    let starter = call(
        &client,
        method::SESSION_NEW,
        json!({"cwd": dir.path(), "mcpServers": [], "_meta": {"acpmux": {"name": "starter"}}}),
    )
    .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    // The servers the starter's harness was given: its acpmux tools at the gateway.
    let servers: Vec<Value> = std::fs::read_dir(&given)
        .unwrap()
        .flat_map(|f| {
            serde_json::from_slice::<Vec<Value>>(&std::fs::read(f.unwrap().path()).unwrap())
                .unwrap()
        })
        .collect();
    let acpmux = servers
        .iter()
        .find(|s| s["name"] == "acpmux" && s["url"].as_str().is_some_and(|u| u.contains(&starter)))
        .unwrap_or_else(|| panic!("no acpmux gateway server: {servers:?}"))
        .clone();
    post(
        &acpmux,
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
            "capabilities": {}, "clientInfo": {"name": "gateway-new-test", "version": "0"}}}),
    );

    let started = tool(&acpmux, "new", json!({"prompt": "first task", "name": "helper"}));
    let helper = started["structuredContent"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("{started}"))
        .to_owned();
    assert!(turns(&client, &helper, 1, Duration::from_secs(30)).await.is_some(), "its first turn");

    // The starter gives its idle helper more work.
    let sent = Instant::now();
    tool(&acpmux, "send", json!({"to": helper, "text": "second task", "class": "action"}));
    let woke = turns(&client, &helper, 2, Duration::from_secs(30)).await;
    eprintln!(
        "gateway-new-wake: action to idle helper started a turn after {:?}",
        woke.map(|_| sent.elapsed())
    );
    assert!(
        woke.is_some(),
        "the starter's action did not wake its own idle helper within 30 s: {}",
        row(&client, &helper).await
    );
    let _ = client.request(method::MUX_SHUTDOWN, json!({"endAgents": true})).await;
    let _ = tokio::time::timeout(Duration::from_secs(20), child.wait()).await;
}
