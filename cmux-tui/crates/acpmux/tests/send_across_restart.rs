//! A send made while one daemon hands over to the next waits for the next one and is delivered.
//!
//! On 2026-10-21/22 cosmic-gray's daemon logged "shutting down" four times (22:52, 00:55, 03:00,
//! 04:10 UTC): the cmux app stopping it (`_acpmux/shutdown`) so its bundled build takes over. The
//! old daemon removes its socket at once but keeps `daemon.lock` until its agents settle, 4-13 s
//! there. A send in that window started a daemon that found the lock taken ("another acpmux
//! daemon holds daemon.lock", 00:55:21) and exited, and the send failed. A coordinator's message
//! is lost that way unless someone notices and sends it again.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-sar-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(
        dir.join("config.json"),
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )
    .unwrap();
    dir
}

fn cli_command(dir: &Path, args: &[&str]) -> std::process::Command {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    cli_command(dir, args).output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn a_send_during_a_daemon_handover_waits_for_the_next_daemon_and_is_delivered() {
    let dir = scratch("h");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(
        made.status.success(),
        "the session: {}\ndaemon.log: {}",
        text(&made),
        fs::read_to_string(dir.join("daemon.log")).unwrap_or_default()
    );
    let stopped = cli(&dir, &["daemon", "shutdown"]);
    assert!(stopped.status.success(), "the first daemon stops: {}", text(&stopped));

    // The old daemon is still settling its agents: its socket is gone, its lock is held.
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join("daemon.lock"))
        .unwrap();
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);

    let started = Instant::now();
    let mut send = cli_command(&dir, &["send", "--no-wait", "lane", "across the handover"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // Until the daemon the send started has found the lock taken, or the send has given up.
    let tried = Instant::now();
    while !fs::read_to_string(dir.join("daemon.log"))
        .unwrap_or_default()
        .contains("another acpmux daemon holds")
        && send.try_wait().unwrap().is_none()
    {
        assert!(tried.elapsed() < Duration::from_secs(10), "the send started no daemon");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(500));
    // The old daemon exits.
    // SAFETY: as above.
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
    drop(lock);

    let sent = send.wait_with_output().unwrap();
    assert!(sent.status.success(), "the send failed instead of waiting: {}", text(&sent));
    assert!(started.elapsed() < Duration::from_secs(20), "the send took {:?}", started.elapsed());

    let waited = cli(&dir, &["wait", "lane", "--timeout", "20"]);
    assert!(waited.status.success(), "the session's turn: {}", text(&waited));
    let last = cli(&dir, &["last", "lane"]);
    assert!(
        String::from_utf8_lossy(&last.stdout).contains("echo: across the handover"),
        "the next daemon did not deliver the send: {}",
        text(&last)
    );
}

#[test]
fn a_lock_the_daemon_cannot_open_fails_at_once_instead_of_waiting_for_a_handover() {
    let dir = scratch("l");
    let _shutdown = Shutdown(&dir);
    // Not another daemon: a lock file the daemon refuses to open.
    std::os::unix::fs::symlink(dir.join("elsewhere"), dir.join("daemon.lock")).unwrap();
    let started = Instant::now();
    let out = cli(&dir, &["send", "--no-wait", "lane", "hello"]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(started.elapsed() < Duration::from_secs(5), "failed after {:?}", started.elapsed());
    assert!(!text(&out).contains("still holds"), "{}", text(&out));
}
