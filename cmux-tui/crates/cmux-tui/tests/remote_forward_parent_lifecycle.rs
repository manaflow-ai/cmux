#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use cmux_remote::daemon::{
    DirectWebSocketOptions, RemoteDaemon, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use tempfile::tempdir;
use tokio::task::LocalSet;
use url::Url;

const MAXIMUM_FRAME_BYTES: usize = 65_535;

/// A forward launched by the app must stop its listener when the app process
/// disappears, even when Swift cannot run its normal cancellation path.
#[tokio::test(flavor = "current_thread")]
async fn forward_closes_listener_after_short_lived_parent_exits() {
    LocalSet::new()
        .run_until(async {
            let fixture = tempdir().unwrap();
            let auth = AuthDatabase::load_or_create(
                fixture.path().join("daemon-state"),
                "forward-parent-lifecycle",
                true,
            )
            .unwrap();
            let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
            let websocket = serve_direct_websocket_with_options(
                daemon,
                "127.0.0.1:0".parse().unwrap(),
                MAXIMUM_FRAME_BYTES,
                DirectWebSocketOptions { trusted_carrier: true, ..Default::default() },
            )
            .await
            .unwrap();
            let endpoint = format!("ws://{}/v1/link", websocket.local_addr());

            let services = DaemonServices::new(WorkspaceService::new(), None);
            let service_task = tokio::task::spawn_local(async move {
                let connection = tokio::time::timeout(Duration::from_secs(10), accepted.recv())
                    .await
                    .expect("forward did not authenticate")
                    .expect("daemon stopped accepting clients");
                services.serve_client(connection).await
            });

            // CreateRoute validates that the destination resolves. Keeping a
            // listener here also lets the test prove the local forward became
            // usable before the parent disappeared.
            let destination = TcpListener::bind("127.0.0.1:0").unwrap();
            let destination_port = destination.local_addr().unwrap().port();
            let ready_fifo = fixture.path().join("forward-ready.fifo");
            make_fifo(&ready_fifo);
            let pid_file = fixture.path().join("forward.pid");
            let state_dir = fixture.path().join("client-state");
            let child_args = [
                "remote".to_string(),
                "forward".to_string(),
                endpoint,
                "--carrier".to_string(),
                "--exit-with-parent".to_string(),
                "--state-dir".to_string(),
                state_dir.to_str().unwrap().to_string(),
                "--workspace-root".to_string(),
                fixture.path().to_str().unwrap().to_string(),
                "--port".to_string(),
                destination_port.to_string(),
            ];

            // Keep the shell alive until cmux-tui has printed its listener.
            // This guarantees the forward captures the shell as its direct
            // parent before the shell exits and leaves it orphaned.
            let script = r#"
fifo=$1
pid_file=$2
shift 2
"$@" >"$fifo" 2>/dev/null &
child=$!
printf '%s\n' "$child" >"$pid_file"
IFS= read -r line <"$fifo" || exit 1
printf '%s\n' "$line"
"#;
            let mut launcher = Command::new("/bin/sh")
                .args(["-c", script, "forward-parent"])
                .arg(&ready_fifo)
                .arg(&pid_file)
                .args(&child_args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let stdout = launcher.stdout.take().unwrap();
            let ready_line = tokio::task::spawn_blocking(move || {
                let mut line = String::new();
                BufReader::new(stdout).read_line(&mut line).map(|_| line)
            });
            let launcher_status = tokio::task::spawn_blocking(move || launcher.wait());
            let ready_line = tokio::time::timeout(Duration::from_secs(20), ready_line)
                .await
                .expect("forward did not print a listener URL")
                .unwrap()
                .unwrap();
            let listener_url = Url::parse(ready_line.trim()).unwrap();
            let listener = SocketAddr::new(
                listener_url.host().unwrap().parse().unwrap(),
                listener_url.port().unwrap(),
            );
            assert!(TcpStream::connect_timeout(&listener, Duration::from_secs(5)).is_ok());
            assert!(
                tokio::time::timeout(Duration::from_secs(5), launcher_status)
                    .await
                    .expect("short-lived parent did not exit")
                    .unwrap()
                    .unwrap()
                    .success()
            );

            wait_for_process_exit(&pid_file).await;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
            loop {
                if TcpStream::connect_timeout(&listener, Duration::from_millis(100)).is_err() {
                    break;
                }
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "orphan forward listener remained open"
                );
                tokio::time::sleep(Duration::from_millis(50)).await;
            }

            let _ = service_task.await;
            websocket.shutdown().await.unwrap();
        })
        .await;
}

fn make_fifo(path: &Path) {
    let status = Command::new("mkfifo").arg(path).status().unwrap();
    assert!(status.success(), "mkfifo failed for {}", path.display());
}

async fn wait_for_process_exit(pid_file: &Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(pid) =
            fs::read_to_string(pid_file).ok().and_then(|pid| pid.trim().parse::<i32>().ok())
        {
            // The orphan is reaped by the system's init/subreaper after it
            // shuts down. `kill(pid, 0)` is portable across Unix test hosts.
            let running = unsafe { libc::kill(pid, 0) == 0 };
            if !running {
                return;
            }
        }
        assert!(tokio::time::Instant::now() < deadline, "forward child did not exit");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
