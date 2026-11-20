//! The daemon on the supervisor contract (`cmux-supervise-core`), against real daemons in temp
//! homes, one fault each (hq `docs/design/remote-cloud-durability.md` section 5), in the style
//! the `cmux-fault` harness adopts:
//!
//! - `slow-disk` (F8): every journal fsync takes 10 s. The daemon serves on with zero self-stops,
//!   and its health says so: `supervisor.faultsToday` 0, state `running`.
//! - `kill` (F7, H5): a SIGKILLed daemon wrote no end; the next one counts its death once, with
//!   the death event, and reads it on `_acpmux/status`.
//! - `kill` during a dial (F10): a client that dials while the next daemon holds the home but has
//!   not bound connects within 2 s of that daemon's ready, instead of "no acpmux daemon".
//! - `update-swap` (F9): an update moves the daemon's executable under `backup/` and puts a new
//!   build at the installed path; within 2 s `_acpmux/status` answers from the installed path. A
//!   new build that does not run is dropped and the old daemon serves on.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-sv-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn with_home(mut cmd: Command, dir: &Path) -> Command {
    cmd.env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = with_home(daemon_env::command(dir, daemon_env::Agents::StandIn, &[]), dir);
    cmd.args(args).output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn status(dir: &Path) -> Option<Value> {
    let out = cli(dir, &["--json", "daemon", "status"]);
    out.status.success().then(|| serde_json::from_slice(&out.stdout).ok()).flatten()
}

struct Daemon {
    child: Child,
    lines: std::sync::mpsc::Receiver<String>,
}

impl Daemon {
    /// Wait for a stdout line `want` says is the one, up to `within`.
    fn line(&self, within: Duration, want: impl Fn(&str) -> bool) -> Option<String> {
        let deadline = Instant::now() + within;
        loop {
            let left = deadline.checked_duration_since(Instant::now())?;
            match self.lines.recv_timeout(left) {
                Ok(line) if want(&line) => return Some(line),
                Ok(_) => {}
                Err(_) => return None,
            }
        }
    }

    fn ready(&self, within: Duration) -> Value {
        let line = self
            .line(within, |l| serde_json::from_str::<Value>(l).is_ok_and(|v| v["ready"] == true))
            .expect("the daemon became ready");
        serde_json::from_str(&line).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_daemon(binary: &Path, dir: &Path, env: &[(&str, &str)]) -> Daemon {
    let mut cmd =
        with_home(daemon_env::command_at(binary, dir, daemon_env::Agents::StandIn, &[]), dir);
    cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn"]);
    for (k, v) in env {
        cmd.env(k, v);
    }
    // Its stdout carries the ready line and its log (`log_sink.rs`): both come through `lines`.
    let mut child =
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, lines) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                return;
            }
        }
    });
    Daemon { child, lines }
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

fn sigkill(pid: u64) {
    // Only a daemon this test started.
    // SAFETY: integer args only; no memory is passed.
    assert_eq!(unsafe { libc::kill(pid as i32, libc::SIGKILL) }, 0);
}

/// fault: slow-disk. Every log fsync takes 10 s; sessions are made and read through it.
#[test]
fn slow_disk_10s_fsync_makes_zero_self_stops_and_the_health_says_so() {
    let _ = HERMETIC;
    let dir = scratch("slow");
    let _shutdown = Shutdown(&dir);
    let daemon = spawn_daemon(daemon_env::bin(), &dir, &[("ACPMUX_TEST_SYNC_DELAY_MS", "10000")]);
    let pid = daemon.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let started = Instant::now();
    let mut made = 0;
    while started.elapsed() < Duration::from_secs(25) {
        let out = cli(&dir, &["new", "-d", "-n", &format!("s{made}"), "-m", "fake"]);
        assert!(out.status.success() || made > 0, "{}", text(&out));
        made += 1;
        let now = status(&dir).expect("the daemon answers on a slow disk");
        assert_eq!(now["pid"].as_u64(), Some(pid), "the daemon stopped itself: {now}");
    }
    let now = status(&dir).unwrap();
    assert_eq!(now["pid"].as_u64(), Some(pid));
    let supervisor = &now["supervisor"];
    assert_eq!(supervisor["state"], "running", "{now}");
    assert_eq!(supervisor["faultsToday"], 0, "zero self-stops: {supervisor}");
    assert_eq!(supervisor["owner"]["pid"].as_u64(), Some(pid), "{supervisor}");
}

/// fault: kill. The next daemon counts the death once and serves it on its health.
#[test]
fn a_killed_daemon_is_counted_once_as_a_death_by_the_next_one() {
    let dir = scratch("kill");
    let _shutdown = Shutdown(&dir);
    let first = spawn_daemon(daemon_env::bin(), &dir, &[]);
    let pid = first.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    sigkill(pid);
    drop(first);
    let second = spawn_daemon(daemon_env::bin(), &dir, &[]);
    second.ready(Duration::from_secs(60));
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(supervisor["faultsToday"], 1, "{supervisor}");
    assert_eq!(supervisor["owner"]["epoch"], 2, "{supervisor}");
    assert_eq!(supervisor["recent"][0]["cause"]["kind"], "died", "{supervisor}");
    let deaths = fs::read_to_string(dir.join("daemon.deaths.jsonl")).unwrap();
    assert_eq!(deaths.lines().count(), 1, "{deaths}");
    assert!(deaths.contains(&format!("\"pid\":{pid}")), "{deaths}");
    // A meant stop is counted, never as a fault, and the start after it counts nothing.
    let stop = cli(&dir, &["daemon", "shutdown"]);
    assert!(stop.status.success(), "{}", text(&stop));
    drop(second);
    let third = spawn_daemon(daemon_env::bin(), &dir, &[]);
    third.ready(Duration::from_secs(60));
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(
        (supervisor["faultsToday"].as_u64(), supervisor["stopsToday"].as_u64()),
        (Some(1), Some(2)),
        "{supervisor}"
    );
}

/// fault: kill during a dial. The client dials while the next daemon holds the home and has not
/// bound its socket yet (`ACPMUX_TEST_HOLD_AFTER_LOCK`: 500 ms there).
#[test]
fn a_dial_during_a_restart_connects_within_2s_of_the_next_daemons_ready() {
    let dir = scratch("dial");
    let _shutdown = Shutdown(&dir);
    let first = spawn_daemon(daemon_env::bin(), &dir, &[]);
    let pid = first.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    sigkill(pid);
    drop(first);
    let next = spawn_daemon(daemon_env::bin(), &dir, &[("ACPMUX_TEST_HOLD_AFTER_LOCK", "1")]);
    next.line(Duration::from_secs(30), |l| l == "acpmux-test-lock-held")
        .expect("the next start holds the lock");
    // `process list` never starts a daemon (`connect(false)`): it dials the one there is.
    let mut dial = with_home(daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]), &dir);
    let dial = dial
        .args(["--json", "process", "list"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    next.ready(Duration::from_secs(30));
    let ready_at = Instant::now();
    let out = dial.wait_with_output().unwrap();
    let after_ready = ready_at.elapsed();
    assert!(out.status.success(), "the dial during the restart failed: {}", text(&out));
    assert!(after_ready <= Duration::from_secs(2), "connected {after_ready:?} after ready");
}

/// The daemon binary copied to `<dir>/app/acpmux`, as an app bundle holds it.
fn install(dir: &Path) -> PathBuf {
    let app = dir.join("app");
    fs::create_dir_all(&app).unwrap();
    let exe = app.join("acpmux");
    fs::copy(daemon_env::bin(), &exe).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    exe
}

/// The update: the old bundle goes under `backup/`, and `new` is put at the installed path.
fn update(dir: &Path, new: impl FnOnce(&Path)) {
    fs::create_dir_all(dir.join("backup")).unwrap();
    fs::rename(dir.join("app"), dir.join("backup/app")).unwrap();
    fs::create_dir_all(dir.join("app")).unwrap();
    new(&dir.join("app/acpmux"));
}

/// fault: update-swap.
#[test]
fn an_update_that_moves_the_executable_answers_from_the_installed_path_within_2s() {
    let dir = scratch("swap");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    assert_eq!(status(&dir).unwrap()["exe"], installed.display().to_string());

    let tmp = dir.join("acpmux.new");
    fs::copy(daemon_env::bin(), &tmp).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    update(&dir, |at| fs::rename(&tmp, at).unwrap());
    let moved = Instant::now();
    let deadline = moved + Duration::from_secs(20);
    let swapped = loop {
        if let Some(now) = status(&dir)
            && now["exe"] == installed.display().to_string()
            && now["pid"].as_u64() != Some(old_pid)
        {
            break moved.elapsed();
        }
        assert!(Instant::now() < deadline, "still {:?}", status(&dir).map(|s| s["exe"].clone()));
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        swapped <= Duration::from_secs(2),
        "answered from the installed path after {swapped:?}"
    );
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(supervisor["faultsToday"], 0, "an update is no fault: {supervisor}");
}

/// fault: update-swap with a new build that does not run: the old daemon keeps serving.
#[test]
fn an_update_whose_new_build_does_not_run_keeps_the_old_daemon_serving() {
    let dir = scratch("swapbad");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    update(&dir, |at| {
        fs::write(at, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
    });
    old.line(Duration::from_secs(20), |l| l.contains("the new build did not take over"))
        .expect("the old daemon logs that it kept serving");
    let now = status(&dir).expect("the old daemon still answers");
    assert_eq!(now["pid"].as_u64(), Some(old_pid), "{now}");
}
