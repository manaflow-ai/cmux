//! Binding the Unix socket must not wait for the journal's writer or replay.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io::{BufRead, BufReader};
use std::process::{Child, Stdio};
use std::time::Duration;

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        // Reap only the process this test started, including on an assertion failure.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn socket_ready_does_not_wait_for_store_open() {
    let dir = tempfile::Builder::new().prefix("amx-bind-").tempdir().unwrap();
    std::fs::write(dir.path().join("config.json"), "{}").unwrap();
    let socket = dir.path().join("s.sock");

    // Use the real journal writer lock, not a delay injected into the daemon. Keeping this
    // descriptor locked prevents store::open from completing on both old and new binaries.
    std::fs::create_dir(dir.path().join("journal")).unwrap();
    let lock = std::fs::File::create(dir.path().join("journal/LOCK")).unwrap();
    lock.lock().unwrap();
    let mut child = Daemon(
        daemon_env::command(dir.path(), daemon_env::Agents::Deny, &[])
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", dir.path())
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    let stdout = child.0.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().find_map(|line| {
            let value: serde_json::Value = serde_json::from_str(&line.ok()?).ok()?;
            (value["ready"] == true).then_some(value)
        })
    });
    // Less than the journal's five-second lock deadline: the old ordering cannot bind here.
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Ok(stream) = tokio::net::UnixStream::connect(&socket).await {
                break stream;
            }
            assert!(child.0.try_wait().unwrap().is_none(), "daemon exited before binding");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("socket must bind while the journal is locked");
    assert!(!ready.is_finished(), "the ready line must wait for the journal");

    drop(lock);
    let ready = tokio::time::timeout(Duration::from_secs(10), ready)
        .await
        .expect("daemon startup resumed when the journal was released")
        .unwrap()
        .expect("daemon reported readiness");
    assert_eq!(ready["pid"], child.0.id());
    unsafe { libc::kill(child.0.id() as i32, libc::SIGTERM) };
    let status = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("daemon stopped after SIGTERM");
    assert!(status.success(), "{status:?}");
    assert!(!socket.exists(), "shutdown removed the bound socket");
}

#[tokio::test]
async fn failed_startup_removes_bound_socket() {
    let dir = tempfile::Builder::new().prefix("amx-bind-err-").tempdir().unwrap();
    std::fs::write(dir.path().join("config.json"), "{}").unwrap();
    let socket = dir.path().join("s.sock");
    let mut command = daemon_env::command(dir.path(), daemon_env::Agents::Deny, &[]);
    // A network listener without explicit opt-in is refused after the Unix socket binds.
    command
        .args(["daemon", "run", "--listen", "0.0.0.0:0", "--log", "warn"])
        .env("ACPMUX_HOME", dir.path())
        .env("ACPMUX_SOCKET", &socket)
        .stdin(Stdio::null());
    let output = tokio::time::timeout(
        Duration::from_secs(10),
        tokio::process::Command::from(command).kill_on_drop(true).output(),
    )
    .await
    .expect("invalid listener configuration failed promptly")
    .unwrap();
    assert!(!output.status.success());
    assert!(!socket.exists(), "failed startup left its bound socket behind");
}
