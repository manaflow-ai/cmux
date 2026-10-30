//! Every parent-session and team-send RPC spends the original caller budget.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

async fn assert_deadline(stalled: &'static str, team: bool, delayed_setup: bool) {
    let root = tempfile::Builder::new().prefix("amx-deadline-").tempdir().unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let socket = root.path().join("a.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
    let requests = seen.clone();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let requests = requests.clone();
            connections.spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let message: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(message.clone());
                    let Some(id) = message.get("id") else { continue };
                    let method = message["method"].as_str().unwrap();
                    if method == stalled {
                        // A finite delay makes the pre-fix failure finish on its own.
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    } else if delayed_setup && method == "_acpmux/subsession/start" {
                        tokio::time::sleep(Duration::from_millis(350)).await;
                    }
                    let result = match method {
                        "initialize" | "_acpmux/tag" => json!({}),
                        "_acpmux/subsession/start" => {
                            json!({"sessionId":"child", "name":"child", "harness":"fake"})
                        }
                        "_acpmux/wait" => json!({"sessions":[{
                            "sessionId":"child", "lastTurn":{"status":"completed", "turnId":"turn"}
                        }]}),
                        "_acpmux/attach" if stalled == "_acpmux/events" => {
                            json!({"events":[{"seq":10}], "hasMore":true})
                        }
                        "_acpmux/attach" | "_acpmux/events" => {
                            json!({"events":[], "hasMore":false})
                        }
                        "_acpmux/team/send" => json!({"messageId":"message"}),
                        other => panic!("unexpected request: {other}"),
                    };
                    let answer = json!({"jsonrpc":"2.0", "id":id, "result":result});
                    if write.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    let mut command = daemon_env::tokio_command(root.path(), daemon_env::Agents::Deny);
    command
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_HOME", root.path())
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(root.path())
        .kill_on_drop(true);
    if team {
        command.args(["--json", "send", "--timeout", "1", "@team", "hello"]);
    } else {
        // `run` detaches by policy. Foreground parent waits/replies are reached
        // through `new -q`; keep setup coverage on the detached `run` alias.
        let foreground = matches!(stalled, "_acpmux/wait" | "_acpmux/attach" | "_acpmux/events");
        command.args([
            "--json",
            if foreground { "new" } else { "run" },
            "-q",
            "--parent",
            "parent",
            "--tag",
            "test=deadline",
            "--timeout",
            "1",
            "hello",
        ]);
    }
    let started = Instant::now();
    let output = tokio::time::timeout(Duration::from_secs(4), command.output()).await;
    let elapsed = started.elapsed();
    server.abort();
    let _ = server.await;
    let output = output.expect("caller exceeded outer safety limit").unwrap();
    let observed = seen.lock().unwrap();
    assert!(
        observed.iter().any(|r| r["method"] == stalled),
        "never reached {stalled}: {observed:?}"
    );
    assert_eq!(
        output.status.code(),
        Some(3),
        "{stalled}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(elapsed < Duration::from_secs(2), "{stalled} reset or ignored budget: {elapsed:?}");
    assert!(
        !observed.iter().any(|r| r["method"] == "session/cancel"),
        "parent timeout changed cancellation policy"
    );
    if delayed_setup {
        let wait = observed.iter().find(|r| r["method"] == "_acpmux/wait").unwrap();
        assert!(
            wait["params"]["timeoutMs"].as_u64().unwrap() < 800,
            "wait reset budget after setup: {wait}"
        );
    }
}

#[tokio::test]
async fn parent_initialize_shares_caller_deadline() {
    assert_deadline("initialize", false, false).await;
}

#[tokio::test]
async fn parent_create_shares_caller_deadline() {
    assert_deadline("_acpmux/subsession/start", false, false).await;
}

#[tokio::test]
async fn parent_tag_shares_caller_deadline() {
    assert_deadline("_acpmux/tag", false, false).await;
}

#[tokio::test]
async fn parent_wait_uses_budget_left_after_creation() {
    assert_deadline("_acpmux/wait", false, true).await;
}

#[tokio::test]
async fn parent_reply_attach_shares_caller_deadline() {
    assert_deadline("_acpmux/attach", false, false).await;
}

#[tokio::test]
async fn parent_reply_paging_shares_caller_deadline() {
    assert_deadline("_acpmux/events", false, false).await;
}

#[tokio::test]
async fn team_initialize_shares_caller_deadline() {
    assert_deadline("initialize", true, false).await;
}

#[tokio::test]
async fn team_delivery_shares_caller_deadline() {
    assert_deadline("_acpmux/team/send", true, false).await;
}
