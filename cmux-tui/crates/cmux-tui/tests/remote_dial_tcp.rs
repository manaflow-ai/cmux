//! `remote dial-tcp` as an ssh ProxyCommand: stdin and stdout carry one
//! loopback TCP stream through a real daemon session.
#![cfg(unix)]

use std::path::Path;
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
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio::task::LocalSet;

const STEP_TIMEOUT: Duration = Duration::from_secs(15);

/// A trusted-carrier daemon on loopback WebSocket, serving one client.
struct Daemon {
    endpoint: String,
    websocket: cmux_remote::daemon::DirectWebSocketServer,
}

async fn start_daemon(state: &Path) -> Daemon {
    let auth = AuthDatabase::load_or_create(state.join("daemon"), "dial-tcp", true).unwrap();
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
    tokio::task::spawn_local(async move {
        let connection = accepted.recv().await.expect("daemon stopped accepting");
        services.serve_client(connection).await
    });
    Daemon { endpoint, websocket }
}

/// A daemon that accepts the session and then never answers it, so the
/// client's workspace and route setup waits forever.
async fn start_silent_daemon(state: &Path) -> Daemon {
    let auth = AuthDatabase::load_or_create(state.join("daemon"), "dial-tcp", true).unwrap();
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
    tokio::task::spawn_local(async move {
        let _connection = accepted.recv().await;
        std::future::pending::<()>().await;
    });
    Daemon { endpoint, websocket }
}

fn dial_tcp(fixture: &Path, endpoint: &str, host: &str, port: u16) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["remote", "dial-tcp", endpoint, "--carrier", "--lanes", "single", "--state-dir"])
        .arg(fixture.join("client"))
        .arg("--local-socket")
        .arg(fixture.join("client.sock"))
        .args(["--host", host, "--port", &port.to_string()])
        .env("HOME", fixture)
        .env("XDG_STATE_HOME", fixture.join("xdg"))
        .env("CMUX_TUI_CONFIG", fixture.join("config.json"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command
}

/// The sshd stand-in echoes until the client half-closes, then answers once
/// more and closes, so the test sees bytes cross after stdin EOF.
#[tokio::test(flavor = "current_thread")]
async fn dial_tcp_pipes_stdio_to_a_loopback_port_and_honors_half_close() {
    LocalSet::new()
        .run_until(async {
            tokio::time::timeout(Duration::from_secs(60), async {
                let fixture = tempdir().unwrap();
                let daemon = start_daemon(fixture.path()).await;
                let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let port = target.local_addr().unwrap().port();
                let echo = tokio::task::spawn_local(async move {
                    let (mut socket, _) = target.accept().await.unwrap();
                    let (mut reader, mut writer) = socket.split();
                    let echoed = tokio::io::copy(&mut reader, &mut writer).await.unwrap();
                    writer.write_all(b"|after-eof").await.unwrap();
                    writer.shutdown().await.unwrap();
                    echoed
                });

                let mut child =
                    dial_tcp(fixture.path(), &daemon.endpoint, "127.0.0.1", port).spawn().unwrap();
                let mut stdin = child.stdin.take().unwrap();
                let mut stdout = child.stdout.take().unwrap();
                let mut stderr = child.stderr.take().unwrap();

                // No trailing newline: a line-buffered stdout would hold it.
                stdin.write_all(b"SSH-2.0-dial-tcp").await.unwrap();
                stdin.flush().await.unwrap();
                let mut banner = [0_u8; 16];
                tokio::time::timeout(STEP_TIMEOUT, stdout.read_exact(&mut banner))
                    .await
                    .expect("no echo before stdin EOF")
                    .unwrap();
                assert_eq!(&banner, b"SSH-2.0-dial-tcp");

                let bulk = (0..256 * 1024).map(|index| (index % 251) as u8).collect::<Vec<_>>();
                let mut echoed = Vec::new();
                tokio::time::timeout(STEP_TIMEOUT, async {
                    tokio::try_join!(
                        async {
                            stdin.write_all(&bulk).await?;
                            // Half-close: the tunnel must keep reading after this.
                            drop(stdin);
                            Ok::<_, std::io::Error>(())
                        },
                        stdout.read_to_end(&mut echoed),
                    )
                })
                .await
                .expect("dial-tcp did not end after the remote closed")
                .unwrap();
                let mut expected = bulk.clone();
                expected.extend_from_slice(b"|after-eof");
                assert_eq!(echoed.len(), expected.len());
                assert!(echoed == expected, "stdout carried bytes other than the stream");

                let status = tokio::time::timeout(STEP_TIMEOUT, child.wait())
                    .await
                    .expect("dial-tcp did not exit after a clean close")
                    .unwrap();
                let mut diagnostics = String::new();
                stderr.read_to_string(&mut diagnostics).await.unwrap();
                assert!(status.success(), "dial-tcp failed: {status:?}: {diagnostics}");
                let echoed_by_target =
                    tokio::time::timeout(STEP_TIMEOUT, echo).await.unwrap().unwrap();
                assert_eq!(echoed_by_target, 16 + bulk.len() as u64);
                daemon.websocket.shutdown().await.unwrap();
            })
            .await
            .expect("dial-tcp round trip timed out");
        })
        .await;
}

/// The route stays LoopbackOnly: the daemon refuses any other address, and
/// the command fails with one stderr line and nothing on stdout.
#[tokio::test(flavor = "current_thread")]
async fn dial_tcp_refuses_a_non_loopback_host() {
    LocalSet::new()
        .run_until(async {
            tokio::time::timeout(Duration::from_secs(60), async {
                let fixture = tempdir().unwrap();
                let daemon = start_daemon(fixture.path()).await;
                // TEST-NET-1: never loopback, and no DNS lookup.
                let child = dial_tcp(fixture.path(), &daemon.endpoint, "192.0.2.1", 22)
                    .stdin(Stdio::null())
                    .spawn()
                    .unwrap();
                let output = tokio::time::timeout(STEP_TIMEOUT, child.wait_with_output())
                    .await
                    .expect("dial-tcp did not exit after the refusal")
                    .unwrap();
                let stderr = String::from_utf8_lossy(&output.stderr);
                assert!(!output.status.success(), "non-loopback dial succeeded");
                assert!(output.stdout.is_empty(), "stdout: {:?}", output.stdout);
                assert!(stderr.contains("route-policy-denied"), "stderr: {stderr}");
                assert_eq!(stderr.trim_end().lines().count(), 1, "stderr: {stderr}");
                daemon.websocket.shutdown().await.unwrap();
            })
            .await
            .expect("dial-tcp refusal timed out");
        })
        .await;
}

/// SIGTERM ends a dial whose setup never gets a reply, as it ends one that
/// is streaming: a stalled ProxyCommand must not outlive its ssh.
#[tokio::test(flavor = "current_thread")]
async fn dial_tcp_exits_on_sigterm_during_setup() {
    LocalSet::new()
        .run_until(async {
            tokio::time::timeout(Duration::from_secs(60), async {
                let fixture = tempdir().unwrap();
                let daemon = start_silent_daemon(fixture.path()).await;
                let child =
                    dial_tcp(fixture.path(), &daemon.endpoint, "127.0.0.1", 22).spawn().unwrap();
                // Long enough to be past connect and waiting on setup.
                tokio::time::sleep(Duration::from_secs(2)).await;
                let pid = child.id().expect("dial-tcp exited before setup").to_string();
                let killed = Command::new("kill").args(["-TERM", &pid]).status().await.unwrap();
                assert!(killed.success());
                let output = tokio::time::timeout(STEP_TIMEOUT, child.wait_with_output())
                    .await
                    .expect("dial-tcp ignored SIGTERM during setup")
                    .unwrap();
                let stderr = String::from_utf8_lossy(&output.stderr);
                assert!(!output.status.success(), "stderr: {stderr}");
                assert!(output.stdout.is_empty(), "stdout: {:?}", output.stdout);
                daemon.websocket.shutdown().await.unwrap();
            })
            .await
            .expect("dial-tcp setup cancellation timed out");
        })
        .await;
}
