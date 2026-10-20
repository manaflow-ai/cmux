//! `cmux server ensure`: the detached local session owner.
//!
//! These tests drive the same ensure path the interactive client uses, so
//! they cover the contract behind "several `cmux` runs share one session":
//! ensure starts an owner when none runs, reports the running owner
//! afterwards, and concurrent ensures converge on a single owner process.

#![cfg(unix)]

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct EnsureFixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl EnsureFixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-eo-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("eo-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            // The spawned owner inherits this environment, so its durable
            // state and configuration stay inside the fixture directory.
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    fn run(&self, action: &str) -> serde_json::Value {
        let output = self.command(action).output().unwrap();
        parse_success(action, &output)
    }
}

impl Drop for EnsureFixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn parse_success(action: &str, output: &Output) -> serde_json::Value {
    assert!(
        output.status.success(),
        "server {action} failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn ensure_starts_a_detached_owner_once() {
    let fixture = EnsureFixture::new("start");

    let first = fixture.run("ensure");
    assert_eq!(first["status"], "started", "{first}");
    assert_eq!(first["session"], fixture.session.as_str(), "{first}");
    let pid = first["pid"].as_u64().expect("owner pid");

    // The ensure process exited, so a running owner proves detachment.
    let again = fixture.run("ensure");
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(again["pid"].as_u64(), Some(pid), "{again}");

    let status = fixture.run("status");
    assert_eq!(status["status"], "running", "{status}");
    assert_eq!(status["pid"].as_u64(), Some(pid), "{status}");

    let stopped = fixture.run("stop");
    assert_eq!(stopped["status"], "stopped", "{stopped}");

    let output = fixture.command("status").output().unwrap();
    assert!(!output.status.success(), "status after stop must fail");
}

#[test]
fn concurrent_ensures_converge_on_one_owner() {
    let fixture = EnsureFixture::new("race");

    let children = (0..4)
        .map(|_| {
            let mut command = fixture.command("ensure");
            command.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
            command.spawn().unwrap()
        })
        .collect::<Vec<_>>();
    let mut pids = Vec::new();
    for child in children {
        let output = child.wait_with_output().unwrap();
        let value = parse_success("ensure", &output);
        pids.push(value["pid"].as_u64().expect("owner pid"));
    }
    pids.sort_unstable();
    pids.dedup();
    assert_eq!(pids.len(), 1, "every ensure must report the same owner: {pids:?}");
}
