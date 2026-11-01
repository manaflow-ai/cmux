//! Exercise the real daemon's supervisor and detached-updater shutdown paths.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

#[tokio::test]
async fn daemon_update_and_sigterm_send_1012_but_explicit_stop_is_normal() {
    let _ = HERMETIC;
    // SIGTERM is the supervisor update path; --restart is the detached update path.
    for trigger in ["sigterm", "restart", "stop"] {
        let dir = cmux_unix_socket::short_test_dir(&format!("amx-close-{trigger}"));
        let socket = dir.path().join("s.sock");
        let mut child = daemon_env::tokio_command(dir.path(), daemon_env::Agents::Deny)
            .env("ACPMUX_HOME", dir.path())
            .env("ACPMUX_SOCKET", &socket)
            .args([
                "daemon",
                "run",
                "--memory",
                "--listen",
                "127.0.0.1:0",
                "--token",
                "test-token",
                "--ready-fd",
                "1",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = tokio::time::timeout(Duration::from_secs(30), async {
            let mut lines = BufReader::new(stdout).lines();
            while let Some(line) = lines.next_line().await.unwrap() {
                if let Ok(value) = serde_json::from_str::<Value>(&line)
                    && value["ready"] == true
                {
                    return value;
                }
            }
            panic!("daemon ended before ready");
        })
        .await
        .unwrap();
        let mut request =
            format!("ws://{}", ready["listen"].as_str().unwrap()).into_client_request().unwrap();
        request.headers_mut().insert("authorization", "Bearer test-token".parse().unwrap());
        let (mut ws, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        ws.send(Message::Text(
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(5), ws.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            Message::Text(_)
        ));
        let command = if trigger == "sigterm" {
            // Only the child this test created is signaled.
            assert_eq!(unsafe { libc::kill(child.id().unwrap() as i32, libc::SIGTERM) }, 0);
            None
        } else {
            let mut command = daemon_env::tokio_command(dir.path(), daemon_env::Agents::Deny);
            command.env("ACPMUX_HOME", dir.path()).env("ACPMUX_SOCKET", &socket).args([
                "daemon",
                "shutdown",
                "--keep-agents",
            ]);
            if trigger == "restart" {
                command.arg("--restart");
            }
            Some(command.kill_on_drop(true).spawn().unwrap())
        };
        let frame = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let Message::Close(close) = frame else {
            panic!("{trigger}: expected Close, got {frame:?}")
        };
        let code = close.map(|frame| u16::from(frame.code));
        if trigger == "stop" {
            assert_ne!(code, Some(1012));
        } else {
            assert_eq!(code, Some(1012), "{trigger}");
        }
        assert!(
            tokio::time::timeout(Duration::from_secs(10), child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
        if let Some(mut command) = command {
            assert!(
                tokio::time::timeout(Duration::from_secs(10), command.wait())
                    .await
                    .unwrap()
                    .unwrap()
                    .success()
            );
        }
    }
}
