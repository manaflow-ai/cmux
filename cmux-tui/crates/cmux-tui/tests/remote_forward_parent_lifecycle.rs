//! Exercise app-owned forwards with a real daemon and a disposable parent.
#![cfg(unix)]

use std::process::Stdio;
use std::time::Duration;

use cmux_remote::daemon::{
    DirectWebSocketOptions, RemoteDaemon, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::Command;
use tokio::task::LocalSet;
use url::Url;

const STEP_TIMEOUT: Duration = Duration::from_secs(10);

/// Also clean up the deliberately orphaned forward if an assertion fails.
struct ForwardProcess(u32);

impl Drop for ForwardProcess {
    fn drop(&mut self) {
        if self.0 != 0 {
            // SAFETY: this PID belongs to the fixture's forward child.
            unsafe { libc::kill(self.0 as libc::pid_t, libc::SIGKILL) };
        }
    }
}

#[derive(Clone, Copy)]
enum ParentExit {
    Normal,
    Crash,
}

#[tokio::test(flavor = "current_thread")]
async fn remote_forward_exits_with_parent() {
    check_parent_lifecycle(true, ParentExit::Normal).await;
}

#[tokio::test(flavor = "current_thread")]
async fn remote_forward_exits_when_parent_is_killed() {
    check_parent_lifecycle(true, ParentExit::Crash).await;
}

#[tokio::test(flavor = "current_thread")]
async fn remote_forward_without_parent_flag_survives_parent_exit() {
    check_parent_lifecycle(false, ParentExit::Normal).await;
}

async fn check_parent_lifecycle(owned: bool, exit: ParentExit) {
    LocalSet::new()
        .run_until(async {
            tokio::time::timeout(Duration::from_secs(45), async {
                let fixture = tempdir().unwrap();
                let auth = AuthDatabase::load_or_create(
                    fixture.path().join("daemon"),
                    "forward-parent-lifecycle",
                    true,
                )
                .unwrap();
                let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
                let websocket = serve_direct_websocket_with_options(
                    daemon,
                    "127.0.0.1:0".parse().unwrap(),
                    65_535,
                    DirectWebSocketOptions { trusted_carrier: true, ..Default::default() },
                )
                .await
                .unwrap();
                let endpoint = format!("ws://{}/v1/link", websocket.local_addr());
                let services = DaemonServices::new(WorkspaceService::new(), None);
                let service_task = tokio::task::spawn_local(async move {
                    let connection = accepted.recv().await.expect("daemon stopped accepting");
                    services.serve_client(connection).await
                });

                let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let destination_port = destination.local_addr().unwrap().port();
                let echo_task = tokio::task::spawn_local(async move {
                    let (mut socket, _) = destination.accept().await.unwrap();
                    let (mut reader, mut writer) = socket.split();
                    tokio::io::copy(&mut reader, &mut writer).await.unwrap();
                });

                // The parent waits for our explicit release, so it stays alive
                // until we have exchanged data through the ready forward. The
                // forward has /dev/null stdin, just as in SSHTuiLinkManager.
                let mut command = Command::new("/bin/sh");
                command
                    .args([
                        "-c",
                        r#""$@" </dev/null &
printf '%s\n' "$!"
IFS= read -r release
exit 0"#,
                        "forward-parent",
                        env!("CARGO_BIN_EXE_cmux-tui"),
                        "remote",
                        "forward",
                        &endpoint,
                        "--carrier",
                        "--lanes",
                        "single",
                        "--state-dir",
                    ])
                    .arg(fixture.path().join("client"))
                    .arg("--local-socket")
                    .arg(fixture.path().join("client.sock"))
                    .arg("--workspace-root")
                    .arg(fixture.path())
                    .args(["--port", &destination_port.to_string()])
                    .env("HOME", fixture.path())
                    .env("XDG_STATE_HOME", fixture.path().join("xdg"))
                    .env("CMUX_TUI_CONFIG", fixture.path().join("config.json"))
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::inherit())
                    .kill_on_drop(true);
                if owned {
                    command.arg("--exit-with-parent");
                }
                let mut parent = command.spawn().unwrap();
                let mut output = BufReader::new(parent.stdout.take().unwrap());
                let mut line = String::new();
                output.read_line(&mut line).await.unwrap();
                let mut forward = ForwardProcess(line.trim().parse().expect("forward PID"));
                line.clear();
                tokio::time::timeout(STEP_TIMEOUT, output.read_line(&mut line))
                    .await
                    .expect("forward did not report readiness")
                    .unwrap();
                let url = Url::parse(line.trim()).expect("forward listener URL");
                let address = url.socket_addrs(|| None).unwrap()[0];
                assert!(address.ip().is_loopback());
                let mut tunnel = TcpStream::connect(address).await.unwrap();
                round_trip(&mut tunnel).await;
                assert!(parent.try_wait().unwrap().is_none(), "parent exited before release");

                match exit {
                    ParentExit::Normal => {
                        parent.stdin.take().unwrap().write_all(b"exit\n").await.unwrap();
                        assert!(parent.wait().await.unwrap().success());
                    }
                    ParentExit::Crash => {
                        parent.kill().await.unwrap();
                    }
                }

                if !owned {
                    // Omitting the flag must preserve ordinary CLI forwards.
                    round_trip(&mut tunnel).await;
                    // SAFETY: this PID is the fixture's running forward.
                    assert_eq!(unsafe { libc::kill(forward.0 as libc::pid_t, libc::SIGTERM) }, 0);
                }

                // EOF on stdout requires the forward to release its inherited
                // pipe. It works even when init delays reaping an orphan zombie.
                let mut remainder = Vec::new();
                tokio::time::timeout(STEP_TIMEOUT, output.read_to_end(&mut remainder))
                    .await
                    .expect("forward child did not exit after its owner")
                    .unwrap();
                forward.0 = 0;
                expect_tunnel_closed(&mut tunnel).await;
                assert!(TcpStream::connect(address).await.is_err(), "orphan listener remained");
                tokio::time::timeout(STEP_TIMEOUT, echo_task).await.unwrap().unwrap();
                let _ = tokio::time::timeout(STEP_TIMEOUT, service_task).await.unwrap().unwrap();
                websocket.shutdown().await.unwrap();
            })
            .await
            .expect("forward lifecycle test timed out");
        })
        .await;
}

async fn round_trip(tunnel: &mut TcpStream) {
    tokio::time::timeout(STEP_TIMEOUT, async {
        tunnel.write_all(b"forward-alive").await.unwrap();
        let mut reply = [0; 13];
        tunnel.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply, b"forward-alive");
    })
    .await
    .expect("forward did not relay traffic while its owner was alive");
}

async fn expect_tunnel_closed(tunnel: &mut TcpStream) {
    let mut byte = [0; 1];
    let result = tokio::time::timeout(STEP_TIMEOUT, tunnel.read(&mut byte))
        .await
        .expect("active forwarded connection remained open");
    assert!(
        matches!(result, Ok(0))
            || result.is_err_and(|error| error.kind() == std::io::ErrorKind::ConnectionReset)
    );
}
