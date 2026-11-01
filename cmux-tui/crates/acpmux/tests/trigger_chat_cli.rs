//! The Cloud bridge distinguishes an unavailable daemon from an old daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::path::Path;
use std::process::{Output, Stdio};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

async fn trigger(scratch: &Path, home: &Path, socket: &Path) -> Output {
    let mut child = daemon_env::tokio_command(scratch, daemon_env::Agents::Deny)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .args(["--json", "trigger-chat", "--protocol", "trigger-chat-v1", "--principal-fd", "0"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(br#"{"operation":"ensure","token":"synthetic-principal"}"#).await.unwrap();
    drop(stdin);
    tokio::time::timeout(Duration::from_secs(10), child.wait_with_output()).await.unwrap().unwrap()
}

#[tokio::test]
async fn trigger_chat_unavailable_daemon_is_retryable_and_not_unsupported() {
    let dir = tempfile::tempdir().unwrap();
    // An explicitly configured missing home refuses autostart without starting a process.
    let home = dir.path().join("missing");
    let out = trigger(dir.path(), &home, &home.join("daemon.sock")).await;
    assert_eq!(out.status.code(), Some(75), "{}", String::from_utf8_lossy(&out.stderr));
    let error: Value = serde_json::from_slice(&out.stderr).unwrap();
    assert_eq!(error["error"]["detail"], "trigger_daemon_unavailable");
    assert_eq!(error["error"]["retryable"], true);
    assert!(out.stdout.is_empty());
    assert!(!home.exists());
}

#[tokio::test]
async fn trigger_chat_connected_old_daemon_remains_unsupported() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let serve = async {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut reader = BufReader::new(rd);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let hello: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(hello["method"], "initialize");
        let response = json!({"jsonrpc":"2.0", "id":hello["id"], "result":{}});
        wr.write_all(format!("{response}\n").as_bytes()).await.unwrap();
        line.clear();
        assert_eq!(reader.read_line(&mut line).await.unwrap(), 0, "no trigger request to old daemon");
    };
    let (out, ()) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(trigger(dir.path(), dir.path(), &socket), serve)
    })
    .await
    .unwrap();
    assert_eq!(out.status.code(), Some(82), "{}", String::from_utf8_lossy(&out.stderr));
    let error: Value = serde_json::from_slice(&out.stderr).unwrap();
    assert_eq!(error["error"]["detail"], "trigger_unsupported");
    assert_eq!(error["error"]["retryable"], false);
    assert!(out.stdout.is_empty());
}
