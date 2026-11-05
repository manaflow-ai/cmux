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

/// The daemon's exit status when its store asked it to stop for a restart (`daemon::EXIT_REPAIR`):
/// EX_IOERR. A supervisor starts it again (launchd `KeepAlive`, systemd `Restart=always`; 75 is
/// the only status the units prevent).
const EXIT_REPAIR: i32 = 74;

/// R-DURABILITY S2c, lead rule 2026-11-04 (3). With `store.journal` on, a log sync that fails (a
/// debug build's `ACPMUX_TEST_FAIL_LOG_SYNC`) freezes the event journal's checkpoint, and the store
/// asks the daemon to stop for a restart, whose replay writes the logs again. The daemon exits with
/// [`EXIT_REPAIR`]; a WebSocket client gets the restart close (1012), and the acpmux client's
/// request in flight ends with the CLI's typed, retryable `daemon_closed`, never a hang.
#[tokio::test]
async fn a_failed_log_sync_stops_the_daemon_for_a_restart() {
    use std::os::unix::fs::PermissionsExt;
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-repair");
    let home = dir.path();
    let private = |path: &std::path::Path, mode: u32| {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    };
    private(home, 0o700);
    let socket = home.join("s.sock");
    std::fs::write(home.join("config.json"), r#"{"store":{"journal":true}}"#).unwrap();
    private(&home.join("config.json"), 0o600);
    // A chat on disk: a rename of it appends an acknowledged record without starting an agent.
    let id = "01a15903-0000-7000-8000-000000000a01";
    let chat = home.join("sessions").join(id);
    std::fs::create_dir_all(&chat).unwrap();
    private(&home.join("sessions"), 0o700);
    private(&chat, 0o700);
    let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": "repair", "harness": "claude",
                      "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1});
    std::fs::write(chat.join("session.json"), meta.to_string()).unwrap();
    private(&chat.join("session.json"), 0o600);

    let mut child = daemon_env::tokio_command(home, daemon_env::Agents::Deny)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_TEST_FAIL_LOG_SYNC", "1")
        .env("ACPMUX_TEST_JOURNAL_CHECKPOINT_MS", "200")
        .args([
            "daemon",
            "run",
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

    // The acpmux client library, as the CLI and the app's helpers use it.
    let client = acpmux::client::Client::connect(&socket).await.unwrap();
    // The session index loads after the ready line: `_acpmux/info` waits for it.
    let info = client.request("_acpmux/info", json!({"sessionId": id})).await;
    assert!(info.is_ok(), "info: {info:?}");
    // The rename's `renamed` line makes the chat's log dirty; the next checkpoint (200 ms) syncs
    // it, the sync fails, the checkpoint freezes, and the store asks for a restart. A rename that
    // loses the race to the stop ends like the wait below.
    let renamed =
        client.request("_acpmux/rename", json!({"sessionId": id, "newName": "renamed"})).await;
    // Waits until the chat closes: no result comes from a daemon that stops.
    let waited = match renamed {
        Ok(_) => {
            let wait =
                client.request("_acpmux/wait", json!({"sessions": [id], "until": ["closed"]}));
            tokio::time::timeout(Duration::from_secs(60), wait)
                .await
                .unwrap_or_else(|_| panic!("the wait got no answer within 60 s: the client hangs"))
        }
        Err(error) => Err(error),
    };
    let error = waited.expect_err("a result from a daemon that must stop");
    // What the CLI makes of it: a typed, retryable error, never a hang.
    let typed = acpmux::cli::errors::classify(&error);
    assert_eq!(typed.detail, "daemon_closed", "{error:#}");
    assert!(typed.retryable, "{error:#}");

    let frame = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Close(close))) => return close.map(|frame| u16::from(frame.code)),
                Some(Ok(_)) => {}
                Some(Err(error)) => panic!("websocket: {error}"),
                None => panic!("the websocket ended without a close frame"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no close frame within 30 s: the client hangs"));
    assert_eq!(frame, Some(1012), "a restart close");
    let status = tokio::time::timeout(Duration::from_secs(30), child.wait())
        .await
        .unwrap_or_else(|_| panic!("the daemon did not exit within 30 s"))
        .unwrap();
    assert_eq!(status.code(), Some(EXIT_REPAIR), "the daemon's exit status: {status:?}");
}
