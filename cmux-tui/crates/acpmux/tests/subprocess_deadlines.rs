//! The CLI deadline covers a group open and every relay pipe, including pipes
//! inherited by a descendant after the relay leader exits.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

struct OwnedProcesses {
    pids: PathBuf,
    sentinel: Child,
}

impl Drop for OwnedProcesses {
    fn drop(&mut self) {
        // Every PID was recorded by this fixture's executable, never discovered
        // by process name. Only still-running fixture processes need cleanup.
        for pid in recorded(&self.pids) {
            if running(pid) {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
        let _ = self.sentinel.kill();
        let _ = self.sentinel.wait();
    }
}

fn recorded(path: &Path) -> Vec<i32> {
    fs::read_to_string(path).unwrap_or_default().lines().map(|line| line.parse().unwrap()).collect()
}

fn running(pid: i32) -> bool {
    #[cfg(target_os = "linux")]
    {
        // An orphan can await init's reap after being killed. It has stopped
        // executing and cannot retain the pipes; do not mistake it for a leak.
        let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else { return false };
        return stat.rsplit_once(") ").is_some_and(|(_, state)| !state.starts_with('Z'));
    }
    #[cfg(not(target_os = "linux"))]
    unsafe {
        libc::kill(pid, 0) == 0
    }
}

async fn assert_deadline(mode: &'static str, setup_delay: bool) {
    let root = tempfile::tempdir().unwrap();
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let bin = root.path().join("bin");
    fs::create_dir(&bin).unwrap();
    let helper = bin.join("cmux");
    let pids = root.path().join("pids");
    let script = r#"#!/usr/bin/env python3
import os, time
path = os.environ['FIXTURE_PIDS']
def record(pid):
    with open(path, 'a') as out:
        out.write(str(pid) + '\n')
        out.flush()
mode = os.environ['FIXTURE_MODE']
if mode == 'group':
    record(os.getpid())
    time.sleep(30)
else:
    pid = os.fork()
    if pid:
        # Record the child before exiting so the test can always clean it up.
        record(pid)
        os._exit(0)
    if mode == 'relay-stdin':
        os.close(1)
        os.close(2)
    else:
        os.close(0)
        os.close(2)
    time.sleep(30)
"#;
    fs::write(&helper, script).unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        root.path().join("config.json"),
        json!({"harnesses":{}, "sendRelay":{"argv":[helper]}}).to_string(),
    )
    .unwrap();
    fs::set_permissions(root.path().join("config.json"), fs::Permissions::from_mode(0o600))
        .unwrap();
    let sentinel = std::process::Command::new("sleep")
        .arg("30")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut owned = OwnedProcesses { pids: pids.clone(), sentinel };
    let socket = root.path().join("a.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let message: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = message.get("id") else { continue };
            let method = message["method"].as_str().unwrap();
            if setup_delay && method == "initialize" {
                tokio::time::sleep(Duration::from_millis(700)).await;
            }
            let result = match method {
                "initialize" => json!({}),
                "session/new" => json!({"sessionId":"child", "name":"child"}),
                "_acpmux/info" => {
                    let response = json!({"jsonrpc":"2.0", "id":id,
                        "error":{"code":-32002,"message":"no session"}});
                    let _ = write.write_all(format!("{response}\n").as_bytes()).await;
                    continue;
                }
                "_acpmux/attach" | "_acpmux/events" => json!({"events":[],"hasMore":false}),
                "session/prompt" => json!({"stopReason":"end_turn"}),
                _ => json!({}),
            };
            let response = json!({"jsonrpc":"2.0", "id":id, "result":result});
            if write.write_all(format!("{response}\n").as_bytes()).await.is_err() {
                break;
            }
        }
    });
    let args = if mode == "group" {
        vec!["--json", "run", "--group", "g", "--timeout", "1", "go"]
    } else {
        vec!["--json", "send", "--timeout", "1", "missing", "-"]
    };
    let mut command = daemon_env::tokio_command(root.path(), daemon_env::Agents::Deny);
    command
        .args(args)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_HOME", root.path())
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(root.path())
        .env("PATH", format!("{}:{}", bin.display(), daemon_env::bare_path(&[])))
        .env("FIXTURE_PIDS", &pids)
        .env("FIXTURE_MODE", mode)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let started = Instant::now();
    let mut cli = command.spawn().unwrap();
    let mut input = cli.stdin.take().unwrap();
    let input_task = tokio::spawn(async move {
        let body = if mode == "relay-stdin" { "x".repeat(1 << 20) } else { "hello".into() };
        // A pre-fix command killed by the guard may close stdin early.
        let _ = input.write_all(body.as_bytes()).await;
    });
    let mut stdout = cli.stdout.take().unwrap();
    let out_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).await.unwrap();
        bytes
    });
    let mut stderr = cli.stderr.take().unwrap();
    let err_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        stderr.read_to_end(&mut bytes).await.unwrap();
        bytes
    });
    let status = tokio::time::timeout(Duration::from_secs(3), cli.wait()).await;
    let elapsed = started.elapsed();
    let helper_pids = recorded(&pids);
    let helpers_stopped = helper_pids.iter().all(|&pid| !running(pid));
    let sentinel_alive = owned.sentinel.try_wait().unwrap().is_none();
    // Clean up even when the pre-fix process exceeds the assertion's guard.
    drop(owned);
    if status.is_err() {
        let _ = cli.kill().await;
    }
    input_task.await.unwrap();
    let stdout = tokio::time::timeout(Duration::from_secs(2), out_task).await.unwrap().unwrap();
    let stderr = tokio::time::timeout(Duration::from_secs(2), err_task).await.unwrap().unwrap();
    server.abort();
    let _ = server.await;
    assert!(!helper_pids.is_empty(), "{mode}: subprocess was never reached");
    assert!(sentinel_alive, "{mode}: timeout killed an unrelated owned process");
    let status = status.expect("subprocess exceeded the CLI deadline").unwrap();
    assert_eq!(status.code(), Some(3), "{mode}: stdout={stdout:?}, stderr={stderr:?}");
    assert!(helpers_stopped, "{mode}: owned subprocess survived timeout");
    assert!(elapsed < Duration::from_millis(1500), "{mode}: budget reset: {elapsed:?}");
}

#[tokio::test]
async fn group_open_uses_remaining_budget_and_stops_only_its_child() {
    assert_deadline("group", true).await;
}

#[tokio::test]
async fn relay_inherited_stdout_is_bounded_after_its_leader_exits() {
    assert_deadline("relay-stdout", true).await;
}

#[tokio::test]
async fn relay_inherited_stdin_is_bounded_after_its_leader_exits() {
    assert_deadline("relay-stdin", false).await;
}
