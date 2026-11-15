//! `server ensure` waits on a restoring owner while the owner works, however
//! long its restore takes, and gives up only once the owner does no work for
//! the restore bound (2026-11-08: a 59 GB registry took 26-30 min to
//! restore, and a fixed 120 s bound killed every owner partway).
//!
//! The owner's debug seams stand in for a long restore:
//! `CMUX_TUI_DEBUG_SLOW_RESTORE_MS` keeps a core busy, as an owner scanning a
//! large registry does; `CMUX_TUI_DEBUG_IDLE_RESTORE_MS` sleeps, as a
//! deadlocked owner does. `CMUX_TUI_DEBUG_RESTORE_STALL_MS` shortens the
//! bound. The work counters are read from the kernel on macOS only; other
//! platforms keep the fixed bound.

#![cfg(target_os = "macos")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

const STALL_MS: &str = "3000";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-rsb-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(dir.join("home")).unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir }
    }

    fn command(&self, extra: &[&str], env: &[(&str, &str)]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .envs(env.iter().copied())
            .env("CMUX_TUI_DEBUG_RESTORE_STALL_MS", STALL_MS)
            .args(["server", "ensure", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .args(extra)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// Runs `server ensure`: whether it succeeded, its JSON result or error,
    /// and how long it took.
    fn ensure(&self, extra: &[&str], env: &[(&str, &str)]) -> (bool, Value, Duration) {
        let started = Instant::now();
        let output = self.command(extra, env).output().unwrap();
        let took = started.elapsed();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stream = if output.status.success() { &stdout } else { &stderr };
        let last = stream.lines().rfind(|line| line.starts_with('{')).unwrap_or_default();
        let value: Value = serde_json::from_str(last).unwrap_or_else(|_| {
            panic!("server ensure printed no JSON: stdout {stdout:?} stderr {stderr:?}")
        });
        (output.status.success(), value, took)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[test]
fn restore_stall_ensure_awaits_an_owner_that_works_past_the_restore_bound() {
    let fixture = Fixture::new("restore-works");
    // Well past the 10 s contact floor the bound keeps, and many times the
    // 3 s stall bound: only the owner's work can keep the wait this long.
    let (ok, value, took) = fixture.ensure(&[], &[("CMUX_TUI_DEBUG_SLOW_RESTORE_MS", "25000")]);
    assert!(ok, "a working owner was given up on after {took:?}: {value}");
    assert_eq!(value["status"], "started", "{value}");
    assert!(took >= Duration::from_secs(25), "the restore did not run: {took:?}");
    eprintln!("restore_stall_bound: working owner, 25 s restore, 3 s bound: ready after {took:?}");
}

#[test]
fn restore_stall_ensure_gives_up_on_an_owner_that_does_no_work_for_the_bound() {
    let fixture = Fixture::new("restore-idle");
    let (ok, value, took) = fixture.ensure(&[], &[("CMUX_TUI_DEBUG_IDLE_RESTORE_MS", "30000")]);
    assert!(!ok, "an idle owner was awaited: {value}");
    assert_eq!(value["code"], "server.restore_timeout", "{value}");
    assert!(took < Duration::from_secs(20), "the idle owner was awaited for {took:?}");
    eprintln!("restore_stall_bound: idle owner, 3 s bound: gave up after {took:?}");
}

#[test]
fn restore_stall_replace_keeps_an_owner_that_works_through_its_probe() {
    let fixture = Fixture::new("restore-replace");
    // The first ensure spawns an owner that restores (works) for 20 s.
    let mut first = fixture
        .command(&[], &[("CMUX_TUI_DEBUG_SLOW_RESTORE_MS", "20000")])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_secs(1));
    // "Restart cmux-tui" while it restores: its identify goes unanswered, but
    // it works through the probe, so it is kept and awaited.
    let (ok, value, took) = fixture.ensure(&["--replace-unresponsive"], &[]);
    assert!(ok, "replace failed after {took:?}: {value}");
    assert_ne!(value["status"], "replaced", "a working owner was replaced: {value}");
    let pid = i32::try_from(value["pid"].as_u64().unwrap()).unwrap();
    assert!(alive(pid));
    let status = first.wait().unwrap();
    let mut out = String::new();
    std::io::Read::read_to_string(first.stdout.as_mut().unwrap(), &mut out).unwrap();
    assert!(status.success(), "the first ensure failed: {out}");
    let started: Value =
        serde_json::from_str(out.lines().rfind(|line| line.starts_with('{')).unwrap()).unwrap();
    assert_eq!(started["pid"], value["pid"], "the owner changed: {started} vs {value}");
}
