//! The app starts `daemon run --ready-fd` directly. A losing launch must return
//! the winner's endpoint and close its readiness pipe, including during startup.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("amx-race-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("config.json"), "{}").unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(dir: &Path) -> tokio::process::Command {
    daemon_with_log(dir, "warn")
}

fn daemon_with_log(dir: &Path, log: &str) -> tokio::process::Command {
    let mut cmd = daemon_env::acpmux(dir);
    cmd.args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", log])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut cmd = tokio::process::Command::from(cmd);
    cmd.kill_on_drop(true);
    cmd
}

async fn ready(child: &mut tokio::process::Child) -> Value {
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            if let Ok(value) = serde_json::from_str::<Value>(&line)
                && value["ready"] == true
            {
                return value;
            }
        }
        panic!("daemon exited before ready");
    })
    .await
    .expect("ready line in time")
}

async fn status(socket: &Path) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut stream = tokio::net::UnixStream::connect(socket).await.unwrap();
        let request = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status"});
        stream.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        let mut lines = BufReader::new(stream).lines();
        while let Some(line) = lines.next_line().await.unwrap() {
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == 1 {
                return value["result"].clone();
            }
        }
        panic!("daemon closed status connection");
    })
    .await
    .expect("status in time")
}

#[tokio::test]
async fn losing_direct_starts_report_the_starting_winner_and_leave_no_process_or_pipe() {
    let dir = Scratch::new();
    let socket = dir.0.join("s.sock");
    let mut winner = daemon(&dir.0)
        .args(["--ready-fd", "1"])
        // The listeners serve, but store/adoption/startup have not finished.
        .env("ACPMUX_TEST_HOLD_AFTER_READY_MS", "5000")
        .spawn()
        .unwrap();
    let winner_pid = winner.id().unwrap();
    let first = ready(&mut winner).await;
    assert_eq!(status(&socket).await["ready"], false, "fixture already finished startup");

    // As in the app/CLI race, seven further launchers all lose to the first.
    let mut losers = Vec::new();
    for _ in 0..7 {
        let child = daemon(&dir.0).args(["--ready-fd", "1"]).spawn().unwrap();
        losers.push((child.id().unwrap(), child));
    }
    for (pid, child) in losers {
        // wait_with_output also waits for EOF on stdout/stderr: a leaked ready
        // descriptor in a descendant would keep this open after the loser exited.
        let output = tokio::time::timeout(Duration::from_secs(3), child.wait_with_output())
            .await
            .expect("losing launch exited and closed every pipe")
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let reused = String::from_utf8_lossy(&output.stdout)
            .lines()
            .find_map(|line| serde_json::from_str::<Value>(line).ok())
            .expect("losing launch wrote readiness");
        assert_eq!(reused["ready"], true, "{reused}");
        assert_eq!(reused["lockHeld"], true, "keyed starts must still reject another key");
        for field in ["pid", "socket", "listen", "webUrl"] {
            assert_eq!(reused[field], first[field], "wrong winner {field}");
        }
        #[cfg(target_os = "linux")]
        assert!(!Path::new(&format!("/proc/{pid}/fd")).exists(), "loser still owns descriptors");
        #[cfg(not(target_os = "linux"))]
        let _ = pid;
    }
    assert_eq!(status(&socket).await["pid"], winner_pid, "a loser stopped the winner");

    // An explicit foreground daemon without a launch/readiness contract still
    // refuses an occupied home immediately, as before.
    let refused = tokio::time::timeout(Duration::from_secs(3), daemon(&dir.0).output())
        .await
        .unwrap()
        .unwrap();
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("another acpmux daemon holds"));

    // Only this test's recorded child is stopped; its agents were disabled.
    unsafe { libc::kill(winner_pid as _, libc::SIGTERM) };
    assert!(
        tokio::time::timeout(Duration::from_secs(8), winner.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
}

#[tokio::test]
async fn a_waiting_start_takes_over_when_the_old_daemon_releases_its_lock() {
    use std::os::fd::AsRawFd;
    let dir = Scratch::new();
    let lock = std::fs::File::create(dir.0.join("daemon.lock")).unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    // Use info only for this rendezvous; the daemon has reached the held lock,
    // so releasing it cannot race ahead of the behavior this test exercises.
    let mut child = daemon_with_log(&dir.0, "info").args(["--ready-fd", "1"]).spawn().unwrap();
    let pid = child.id().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let answer = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            if line.contains("waiting for its socket or exit") {
                assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
            }
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                return value;
            }
        }
        panic!("waiting start exited instead of taking over");
    })
    .await
    .unwrap();
    assert_eq!(answer["ready"], true, "{answer}");
    assert_eq!(answer["pid"], pid, "the waiting process is the successor");
    assert_eq!(status(&dir.0.join("s.sock")).await["pid"], pid);
    unsafe { libc::kill(pid as _, libc::SIGTERM) };
    assert!(
        tokio::time::timeout(Duration::from_secs(8), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
}

// The detached launch's readiness wait must cover handover, not just the usual
// eight-second bind budget. Drive the CLI, which owns that readiness timeout.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn cli_start_waits_for_a_lock_held_beyond_the_normal_bind_budget() {
    use std::os::fd::AsRawFd;
    let dir = Scratch::new();
    let socket = dir.0.join("s.sock");
    let lock = std::fs::File::create(dir.0.join("daemon.lock")).unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let cli = |args: &[&str]| {
        let mut cmd = daemon_env::acpmux(&dir.0);
        cmd.args(args)
            .env("ACPMUX_HOME", &dir.0)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null());
        let mut cmd = tokio::process::Command::from(cmd);
        cmd.kill_on_drop(true);
        cmd
    };
    let started = cli(&["--json", "daemon", "start"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let release = async {
        tokio::time::sleep(Duration::from_secs(9)).await;
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    };
    let (_, output) = tokio::join!(
        release,
        tokio::time::timeout(Duration::from_secs(35), started.wait_with_output())
    );
    // Clean up even on the regressed eight-second timeout: its detached child
    // may still be acquiring the released lock. A second start waits for it.
    let cleanup_start =
        tokio::time::timeout(Duration::from_secs(35), cli(&["daemon", "start"]).output()).await;
    let shutdown =
        tokio::time::timeout(Duration::from_secs(10), cli(&["daemon", "shutdown"]).output()).await;
    assert!(cleanup_start.unwrap().unwrap().status.success());
    assert!(shutdown.unwrap().unwrap().status.success());
    let output = output.unwrap().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let answer: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(answer["pid"].is_number(), "{answer}");
}
