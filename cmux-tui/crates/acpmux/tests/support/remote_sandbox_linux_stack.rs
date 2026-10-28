//! Full Linux production spawn; every RPC/readiness wait has a 45-second deadline.
//! The daemon is killed on scope exit, closing its direct agents' input streams.
//! Fixture/assertion loops consume finite lists; final reaping has a five-second deadline.
use super::*;
use futures_util::{SinkExt, StreamExt};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message as WsMessage};

type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Stops when the matching reply arrives, the connection closes, or the deadline expires.
async fn call(ws: &mut Ws, id: i64, method: &str, params: Value) -> Value {
    tokio::time::timeout(Duration::from_secs(45), async {
        ws.send(WsMessage::Text(Message::request(id, method, params).to_line().into()))
            .await
            .unwrap();
        while let Some(frame) = ws.next().await {
            if let WsMessage::Text(text) = frame.unwrap() {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == id {
                    return value;
                }
            }
        }
        panic!("connection ended before {method} replied");
    })
    .await
    .expect("RPC deadline")
}

#[tokio::test]
async fn linux_remote_chain_uses_the_production_sandbox_without_a_switch() {
    production_spawn("linux-production", false).await;
}

/// config.json's `vmHost: true` is guest state (the agent can write the file):
/// the remote chain still runs in bwrap after the canary, as with `false`.
#[tokio::test]
async fn linux_remote_chain_with_vm_host_true_still_runs_in_the_production_sandbox() {
    production_spawn("linux-vm-host", true).await;
}

/// A daemon with `vmHost` as given spawns a Web session's Claude Code: the
/// canary passed, the agent's probe is denied outside its folders, and it
/// inherits none of the daemon's own secrets.
async fn production_spawn(tag: &str, vm_host: bool) {
    if let Err(error) = Hub::linux_sandbox_probe_for_tests() {
        assert!(std::env::var_os("ACPMUX_REQUIRE_BWRAP").is_none(), "{error}");
        eprintln!("remote_sandbox: skipped ({error})");
        return;
    }
    let d = dir(tag);
    use std::os::unix::fs::DirBuilderExt;
    for path in [d.join("home"), d.join("runtime"), d.join("work/.git/hooks")] {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path).unwrap();
    }
    std::fs::write(
        d.join("config.json"),
        json!({
            "harnesses": {"fakeclaude": {
                "argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                "env": {"ANTHROPIC_AUTH_TOKEN": "synthetic-profile-token"}
            }},
            "defaultHarness": "fakeclaude", "permissionPolicy": "ask",
            "webRoots": [d.join("work")], "vmHost": vm_host,
            "pool": {"debounceMs": 0}
        })
        .to_string(),
    )
    .unwrap();
    // Match the daemon's HOME=d/home and ACPMUX_HOME=d, without bypassing its gate.
    let trust = acpmux::trust::Paths {
        claude_json: d.join("home/.claude.json"),
        codex_config: d.join("home/.codex/config.toml"),
        record: d.join("trust.json"),
        agent_home: None,
        cmux_worktrees: None,
    };
    acpmux::trust::set(&trust, &d.join("work").to_string_lossy(), "trusted").unwrap();
    let mut command = daemon_env::tokio_command(&d, daemon_env::Agents::StandIn);
    let mut daemon = command
        .args([
            "daemon",
            "run",
            "--memory",
            "--listen",
            "127.0.0.1:0",
            "--ready-fd",
            "1",
            "--log",
            "warn",
        ])
        .env("ACPMUX_HOME", &d)
        .env("ACPMUX_SOCKET", d.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("XDG_RUNTIME_DIR", d.join("runtime"))
        .env("CMUX_REMOTE_TEST_SECRET", "synthetic-cmux-secret")
        .env("UNRELATED_TOKEN", "synthetic-unrelated-token")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut ready = String::new();
    tokio::time::timeout(
        Duration::from_secs(45),
        BufReader::new(daemon.stdout.take().unwrap()).read_line(&mut ready),
    )
    .await
    .unwrap()
    .unwrap();
    let ready: Value = serde_json::from_str(&ready).unwrap();
    let url = ready["webUrl"].as_str().unwrap().replace("http://", "ws://");
    let (mut ws, _) =
        tokio::time::timeout(Duration::from_secs(45), tokio_tungstenite::connect_async(url))
            .await
            .unwrap()
            .unwrap();
    let reply =
        call(&mut ws, 1, "session/new", json!({"cwd": d.join("work"), "mcpServers": []})).await;
    assert!(reply.get("error").is_none(), "production Linux spawn refused: {reply}");
    let session = reply["result"]["sessionId"].as_str().unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let outside = d.join("outside");
    let prompt = format!(
        "linux-sandbox-probe {} {}",
        outside.display(),
        listener.local_addr().unwrap().port()
    );
    let reply = call(
        &mut ws,
        2,
        "session/prompt",
        json!({
            "sessionId": session, "prompt": [{"type": "text", "text": prompt}]
        }),
    )
    .await;
    assert!(reply.get("error").is_none(), "production Linux prompt refused: {reply}");
    let events =
        call(&mut ws, 3, "_acpmux/events", json!({"sessionId": session, "limit": 1000})).await;
    let text: String = events["result"]["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| {
            e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
        })
        .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
        .collect();
    let seen: Value = serde_json::from_str(&text).expect("agent answered sandbox probe");
    for key in ["outside", "git", "claude", "loopback"] {
        assert_eq!(seen[key], "denied", "{seen}");
    }
    assert_eq!(seen["cwd"], "allowed", "{seen}");
    assert!(
        seen["proxy"].as_str().unwrap().contains("403"),
        "proxy did not enforce policy: {seen}"
    );
    for path in [outside, d.join("work/.git/hooks/x"), d.join("work/CLAUDE.md")] {
        assert!(
            matches!(std::fs::symlink_metadata(&path), Err(e) if e.kind() == std::io::ErrorKind::NotFound),
            "forbidden file landed: {}",
            path.display()
        );
    }
    assert!(listener.accept().is_err(), "host loopback connection arrived");
    assert_eq!(std::fs::read_to_string(d.join("work/ok")).unwrap(), "x");
    let sandbox: Vec<&Value> = events["result"]["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "remote_sandbox")
        .map(|e| &e["msg"])
        .collect();
    assert!(sandbox.iter().any(|m| m["canary"] == "passed"), "no canary: {sandbox:?}");
    assert!(sandbox.iter().all(|m| m.get("vmHost").is_none()), "{sandbox:?}");

    let names = "ANTHROPIC_AUTH_TOKEN,CMUX_REMOTE_TEST_SECRET,UNRELATED_TOKEN,HOME,PATH";
    let prompt = json!({
        "sessionId": session, "prompt": [{"type": "text", "text": format!("envs: {names}")}]
    });
    let reply = call(&mut ws, 4, "session/prompt", prompt).await;
    assert!(reply.get("error").is_none(), "production Linux prompt refused: {reply}");
    let events =
        call(&mut ws, 5, "_acpmux/events", json!({"sessionId": session, "limit": 1000})).await;
    let env: Value = events["result"]["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| {
            e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
        })
        .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
        .filter_map(|text| serde_json::from_str::<Value>(text).ok())
        .find(|v| v.get("UNRELATED_TOKEN").is_some())
        .expect("agent answered envs");
    assert_eq!(env["ANTHROPIC_AUTH_TOKEN"], "synthetic-profile-token", "{env}");
    for dropped in ["CMUX_REMOTE_TEST_SECRET", "UNRELATED_TOKEN"] {
        assert_eq!(env[dropped], "", "remote child inherited {dropped}: {env}");
    }
    assert!(env["HOME"].as_str().is_some_and(|v| !v.is_empty()), "{env}");
    assert!(env["PATH"].as_str().is_some_and(|v| !v.is_empty()), "{env}");
    drop(ws);
    tokio::time::timeout(Duration::from_secs(5), daemon.kill()).await.unwrap().unwrap();
    let _ = std::fs::remove_dir_all(d);
}
