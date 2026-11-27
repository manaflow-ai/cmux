//! The daemon checks a new session against its host's room (deputy-2, 2026-10-22).
//!
//! About 25 Codex reviewers were started on huge-blue with a raw `acpmux new` over
//! reach from other hosts. That went around lane-place's cap of 12, filled the disk
//! to 98-100% and pushed the load to 50-80. Every path to a new session goes through
//! the daemon's `session/new`, so the daemon checks there, reading two files when the
//! session is created:
//! - `~/.cache/worktree-reclaim/under-floor` (worktree-reclaim writes it when the disk
//!   is under its free-space floor) warns on every new session;
//! - `lanes.max_lanes` of this machine in the fleet registry (`FLEET_REGISTRY`, else
//!   `~/.ssh/config.d/fleet-registry.json`, the copy `reach --install` renders, else a
//!   leo-workspace checkout's `machines/fleet-registry.json`) is this host's cap of live
//!   sessions (running, ready, waiting). A create at the cap starts with a warning
//!   (`admission` in the reply, `acpmux: warning:` on stderr), never a refusal: no launch
//!   is refused for load or a cap (huge-blue at its 12 refused the stall reconciler's
//!   PONG to claude-sr2, 2026-10-26).
//!
//! Disk floors and lane caps are advisory; `--force-admit` remains compatible. A send to an existing session and a restart
//! of one are never refused, and a host with no registry or no entry admits.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The machine these tests' registry names; the daemon is told it runs there.
const MACHINE: &str = "test-box";

struct Daemon {
    root: PathBuf,
    child: Option<Child>,
    /// `FLEET_REGISTRY`, relative to the root, when the test sets it.
    registry: Option<&'static str>,
}

impl Daemon {
    /// A daemon whose registry (when `max_lanes` is Some) gives `MACHINE` that cap.
    fn start(tag: &str, max_lanes: Option<u64>, under_floor: bool) -> Self {
        Self::start_with(tag, max_lanes, under_floor, None)
    }

    /// `start`, with `FLEET_REGISTRY` set to `registry` under the root.
    fn start_with(
        tag: &str,
        max_lanes: Option<u64>,
        under_floor: bool,
        registry: Option<&'static str>,
    ) -> Self {
        // Short: the socket path must stay under the macOS limit.
        let root = std::env::temp_dir().join(format!("adm-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["home", "amx", "work"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let root = std::fs::canonicalize(&root).unwrap();
        // Owner-only, whatever the umask: the daemon refuses a state directory
        // under a folder others may write.
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(
            root.join("amx").join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        let daemon = Self { root, child: None, registry };
        if let Some(max) = max_lanes {
            daemon.write_registry(
                ".ssh/config.d",
                json!({MACHINE: {"lanes": {"max_lanes": max}}, "elsewhere": {"lanes": {"max_lanes": 99}}}),
            );
        }
        if under_floor {
            daemon.set_under_floor(true);
        }
        daemon.launch()
    }

    fn launch(mut self) -> Self {
        let log = std::fs::File::create(self.root.join("daemon.err")).unwrap();
        // `--memory`: no store on disk, so no agent host outlives the test.
        let mut child = self
            .cmd()
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "info"])
            .stdout(Stdio::piped())
            .stderr(log)
            .spawn()
            .expect("start daemon");
        let mut out = BufReader::new(child.stdout.take().unwrap());
        loop {
            let mut line = String::new();
            let n = out.read_line(&mut line).unwrap();
            assert!(n > 0, "daemon exited before it was ready: {}", self.log());
            if line.contains("\"ready\":true") {
                break;
            }
        }
        // The daemon logs to stdout too: keep reading it, into the log file.
        let mut log =
            std::fs::OpenOptions::new().append(true).open(self.root.join("daemon.err")).unwrap();
        std::thread::spawn(move || std::io::copy(&mut out, &mut log));
        self.child = Some(child);
        self
    }

    /// A fleet registry with these machines, in `dir` under the daemon's HOME.
    fn write_registry(&self, dir: &str, machines: Value) {
        let dir = daemon_env::home(&self.root).join(dir);
        std::fs::create_dir_all(&dir).unwrap();
        let registry = json!({"machines": machines});
        std::fs::write(dir.join("fleet-registry.json"), registry.to_string()).unwrap();
    }

    fn set_under_floor(&self, on: bool) {
        let dir = daemon_env::home(&self.root).join(".cache").join("worktree-reclaim");
        std::fs::create_dir_all(&dir).unwrap();
        let flag = dir.join("under-floor");
        if on {
            std::fs::write(flag, "free 12 GiB < floor 20 GiB\n").unwrap();
        } else {
            let _ = std::fs::remove_file(flag);
        }
    }

    fn cmd(&self) -> Command {
        let mut cmd = daemon_env::command(&self.root, daemon_env::Agents::StandIn, &[]);
        cmd.current_dir(self.root.join("work"))
            .env("ACPMUX_HOME", self.root.join("amx"))
            .env("ACPMUX_SOCKET", self.root.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .env("FLEET_ORIGIN", MACHINE)
            .env_remove("ACPMUX_SESSION_ID")
            .stdin(Stdio::null());
        if let Some(rel) = self.registry {
            cmd.env("FLEET_REGISTRY", self.root.join(rel));
        }
        cmd
    }

    fn run(&self, args: &[&str]) -> Output {
        self.cmd().args(args).output().expect("run acpmux")
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.root.join("daemon.err")).unwrap_or_default()
    }

    /// Waits for a log line that passes `want` (the log is copied in a thread).
    fn wait_log(&self, want: impl Fn(&str) -> bool, why: &str) {
        let start = Instant::now();
        while !self.log().lines().any(&want) {
            assert!(start.elapsed() < Duration::from_secs(10), "{why}: {}", self.log());
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// `acpmux new -d -n NAME` plus `extra`.
    fn create(&self, name: &str, extra: &[&str]) -> Output {
        let mut args = vec!["--json", "new", "-d", "-n", name];
        args.extend_from_slice(extra);
        self.run(&args)
    }

    /// Waits until `name` is live (its harness runs); a session made with
    /// `new -d` starts its harness at once.
    fn wait_live(&self, name: &str) {
        let start = Instant::now();
        loop {
            let out = self.run(&["--json", "ls"]);
            let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
            let status = v["sessions"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|s| s["name"] == name)
                .and_then(|s| s["status"].as_str())
                .map(str::to_owned);
            if matches!(status.as_deref(), Some("ready" | "running" | "waiting")) {
                return;
            }
            assert!(
                start.elapsed() < Duration::from_secs(20),
                "{name} is not live after 20 s: {status:?} {}",
                text(&out)
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = self.run(&["daemon", "shutdown", "--end-agents"]);
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn text(out: &Output) -> String {
    format!("{} {}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
}

/// Started past the cap: the reply's `admission` warning and the CLI's stderr say `words`.
fn assert_warned(out: &Output, words: &str) {
    assert!(out.status.success(), "a cap never refuses: {}", text(out));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    let admission = v.get("admission").or_else(|| v.pointer("/_meta/acpmux/admission"));
    let warning =
        admission.and_then(|a| a.get("warning")).and_then(Value::as_str).unwrap_or_default();
    assert!(warning.contains(words), "the warning says {words:?}: {}", text(out));
    assert!(warning.contains("started anyway"), "{warning}");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("acpmux: warning: "), "the CLI prints it: {err}");
}

fn assert_not_warned(out: &Output) {
    assert!(out.status.success(), "{}", text(out));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    assert!(v.get("admission").is_none(), "under the cap, no warning: {}", text(out));
}

#[test]
fn under_floor_flag_warns_for_a_new_session_and_a_run() {
    let daemon = Daemon::start("flag", None, true);
    let out = daemon.create("a", &[]);
    assert_warned(&out, "free-space floor");
    let out =
        daemon.run(&["--json", "run", "--ephemeral", "--timeout", "30", "Reply with only: OK"]);
    assert_warned(&out, "free-space floor");
    // Read at create time: once worktree-reclaim clears it, a create goes through.
    daemon.set_under_floor(false);
    let out = daemon.create("b", &[]);
    assert!(out.status.success(), "the flag is gone: {}", text(&out));
}

#[test]
fn max_lanes_warns_at_the_cap_and_never_refuses() {
    let daemon = Daemon::start("cap", Some(2), false);
    for name in ["one", "two"] {
        let out = daemon.create(name, &[]);
        assert_not_warned(&out);
        daemon.wait_live(name);
    }
    let out = daemon.create("three", &[]);
    assert_warned(&out, "2 live sessions, at its cap of 2 (lanes.max_lanes of test-box in ");
    assert!(
        text(&out).contains(".ssh/config.d/fleet-registry.json"),
        "names the registry: {}",
        text(&out)
    );
    daemon.wait_live("three");
    daemon.wait_log(|l| l.contains("admitted past the lane cap"), "the daemon logs it");
    // Past the cap too: a one-shot `exec` (the stall reconciler's PONG) runs and answers.
    let out = daemon.run(&[
        "exec",
        "--ephemeral",
        "--timeout",
        "30",
        "-n",
        "pong",
        "Reply with only: PONG",
    ]);
    assert!(out.status.success(), "an exec past the cap: {}", text(&out));
    assert!(text(&out).contains("acpmux: warning: "), "{}", text(&out));
    // A session that stopped is not live: under the cap again, no warning.
    for name in ["one", "two", "three"] {
        let out = daemon.run(&["kill", name]);
        assert!(out.status.success(), "kill: {}", text(&out));
    }
    assert_not_warned(&daemon.create("four", &[]));
}

#[test]
fn force_admit_stays_compatible_with_advisory_floor_and_cap() {
    let daemon = Daemon::start("force", Some(0), true);
    let out = daemon.create("forced", &["--force-admit"]);
    assert!(out.status.success(), "--force-admit admits: {}", text(&out));
    assert_warned(&out, "free-space floor");
    assert_warned(&out, "cap of 0");
}

#[test]
fn sends_and_restarts_of_existing_sessions_are_never_refused() {
    let daemon = Daemon::start("send", Some(1), false);
    let out = daemon.create("kept", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("kept");
    // At the cap: a send to the live session neither fails nor warns.
    let out = daemon.run(&["send", "kept", "--timeout", "30", "Reply with only: PONG"]);
    assert!(out.status.success(), "a send at the cap: {}", text(&out));
    assert!(!text(&out).contains("warning"), "a send is not a create: {}", text(&out));
    // At the cap and under the floor at once.
    daemon.set_under_floor(true);
    assert_warned(&daemon.create("other", &[]), "free-space floor");
    let out = daemon.run(&["send", "kept", "--timeout", "30", "Reply with only: OK"]);
    assert!(out.status.success(), "a send to an existing session: {}", text(&out));
    let out = daemon.run(&["session", "restart", "kept"]);
    assert!(out.status.success(), "a restart of an existing session: {}", text(&out));
    let out = daemon.run(&["send", "kept", "--timeout", "30", "Reply with only: again"]);
    assert!(out.status.success(), "a send after the restart: {}", text(&out));
    // A fork is a new session: both floor and cap warn, with no override needed.
    let out = daemon.run(&["--json", "fork", "kept", "-n", "kept-fork"]);
    assert_warned(&out, "free-space floor");
    let out = daemon.run(&["--json", "fork", "kept", "-n", "forced-fork", "--force-admit"]);
    assert!(out.status.success(), "a forced fork: {}", text(&out));
}

#[test]
fn no_registry_or_no_entry_admits() {
    // No registry file at all.
    let daemon = Daemon::start("none", None, false);
    for name in ["a", "b", "c"] {
        let out = daemon.create(name, &[]);
        assert!(out.status.success(), "no registry: {}", text(&out));
    }
    drop(daemon);
    // A registry with no entry for this machine.
    let daemon = Daemon::start("other", Some(0), false);
    let out = daemon
        .cmd()
        .env("FLEET_ORIGIN", "not-in-the-registry")
        .args(["--json", "new", "-d", "-n", "x"])
        .output()
        .unwrap();
    // FLEET_ORIGIN is the daemon's, not the CLI's: the daemon still runs as MACHINE.
    assert_warned(&out, "at its cap of 0");
    drop(daemon);
    // A registry that lists other machines only, written after the daemon
    // started: it is read when the session is created.
    let daemon = Daemon::start("noentry", None, false);
    daemon.write_registry(".ssh/config.d", json!({"elsewhere": {"lanes": {"max_lanes": 0}}}));
    let out = daemon.create("free", &[]);
    assert!(out.status.success(), "no entry for this machine: {}", text(&out));
    // FLEET_ORIGIN names a machine the registry does not list.
    daemon.wait_log(|l| l.contains("no lane cap"), "it says why it admits");
}

#[test]
fn a_set_fleet_registry_that_is_missing_admits_and_logs_it() {
    // FLEET_REGISTRY names the file on purpose: a rename, a failed mount or a
    // typo is logged as a warning, and the create starts (the cap is unknown).
    let daemon = Daemon::start_with("setreg", None, false, Some("reg/fleet-registry.json"));
    assert_not_warned(&daemon.create("a", &[]));
    daemon.wait_log(
        |l| l.contains("cannot be read, so the lane cap is unknown"),
        "the unreadable registry is logged",
    );
    daemon.wait_live("a");
    // Once it is there, its cap warns.
    let dir = daemon.root.join("reg");
    std::fs::create_dir_all(&dir).unwrap();
    let registry = json!({"machines": {MACHINE: {"lanes": {"max_lanes": 1}}}});
    std::fs::write(dir.join("fleet-registry.json"), registry.to_string()).unwrap();
    assert_warned(&daemon.create("b", &[]), "at its cap of 1");
    // Gone again: the last good copy keeps the warning.
    std::fs::remove_file(dir.join("fleet-registry.json")).unwrap();
    assert_warned(&daemon.create("c", &[]), "at its cap of 1");
}

#[test]
fn a_registry_folder_that_cannot_be_searched_keeps_the_caps_warning() {
    use std::os::unix::fs::PermissionsExt;
    let mode = |dir: &std::path::Path, m: u32| {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(m)).unwrap()
    };
    // The rendered copy caps this host at one; the checkout fallback is absent.
    let daemon = Daemon::start("noaccess", Some(1), false);
    let dir = daemon_env::home(&daemon.root).join(".ssh/config.d");
    let out = daemon.create("a", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("a");
    // Its folder can no longer be searched: whether the file is there is unknown,
    // so the last good copy keeps the cap's warning.
    mode(&dir, 0o000);
    let out = daemon.create("b", &[]);
    mode(&dir, 0o700);
    assert_warned(&out, "at its cap of 1");
    drop(daemon);
    // With no good copy read before, the create starts and the daemon logs why.
    let daemon = Daemon::start("noaccess2", Some(1), false);
    let dir = daemon_env::home(&daemon.root).join(".ssh/config.d");
    mode(&dir, 0o000);
    let out = daemon.create("a", &[]);
    mode(&dir, 0o700);
    assert_not_warned(&out);
    daemon.wait_log(|l| l.contains("lane cap is unknown"), "the daemon says why");
}

#[test]
fn a_registry_read_once_keeps_the_caps_warning_while_every_copy_is_gone() {
    // A refresh (a rename, a delete and rewrite) can leave no copy for a moment:
    // the last good copy keeps the cap's warning, whichever path it came from.
    let daemon = Daemon::start("gone", Some(1), false);
    let out = daemon.create("a", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("a");
    let copy = daemon_env::home(&daemon.root).join(".ssh/config.d/fleet-registry.json");
    std::fs::remove_file(copy).unwrap();
    assert_warned(&daemon.create("b", &[]), "at its cap of 1");
}

#[test]
fn a_leo_workspace_checkouts_registry_caps_a_host_with_no_rendered_copy() {
    // The cap warns (`max_lanes_warns_at_the_cap_and_never_refuses`).
    // cmux16 has ~/Projects/leo-workspace and no ~/.ssh/config.d copy.
    let daemon = Daemon::start("lws", None, false);
    daemon.write_registry(
        "Projects/leo-workspace/machines",
        json!({MACHINE: {"lanes": {"max_lanes": 1}}}),
    );
    let out = daemon.create("first", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("first");
    let out = daemon.create("second", &[]);
    assert_warned(&out, "1 live sessions, at its cap of 1");
    assert!(
        text(&out).contains("Projects/leo-workspace/machines/fleet-registry.json"),
        "names the checkout's registry: {}",
        text(&out)
    );
}

#[test]
fn concurrent_creates_past_the_cap_all_start_and_each_one_past_it_is_warned() {
    let daemon = Daemon::start("race", Some(2), false);
    let children: Vec<_> = (0..6)
        .map(|i| {
            daemon
                .cmd()
                .args(["--json", "new", "-d", "-n", &format!("r{i}")])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let outs: Vec<Output> = children.into_iter().map(|c| c.wait_with_output().unwrap()).collect();
    let made = outs.iter().filter(|o| o.status.success()).count();
    let warned = outs
        .iter()
        .filter(|o| {
            let v: Value = serde_json::from_slice(&o.stdout).unwrap_or(Value::Null);
            v["admission"]["warning"].is_string()
        })
        .count();
    let all: Vec<String> = outs.iter().map(text).collect();
    // Admitted creates count as live until they end: two fit, the other four are past it.
    assert_eq!((made, warned), (6, 4), "six made, four warned: {all:#?}");
}

#[test]
fn at_the_cap_a_live_sessions_name_is_taken_not_refused() {
    // Base checks names under the insert lock: a create of a live session's name
    // says the name is taken, and `new --reuse` takes that session, at the cap too.
    let daemon = Daemon::start("taken", Some(1), false);
    let out = daemon.create("worker", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("worker");
    let first: Value = serde_json::from_slice(&out.stdout).unwrap();
    let out = daemon.create("worker", &[]);
    assert_ne!(out.status.code(), Some(5), "not an admission refusal: {}", text(&out));
    assert!(text(&out).contains("is taken"), "the name is taken: {}", text(&out));
    let out = daemon.create("worker", &["--reuse"]);
    assert!(out.status.success(), "--reuse takes the live session: {}", text(&out));
    let reused: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reused["sessionId"], first["sessionId"], "{}", text(&out));
}

#[test]
fn reuse_launches_of_one_name_at_the_cap_all_get_the_one_session() {
    // Room for one: the create that wins the name takes it, and every other
    // `new --reuse` of that name reuses the winner.
    let daemon = Daemon::start("reuse", Some(1), false);
    let children: Vec<_> = (0..4)
        .map(|_| {
            daemon
                .cmd()
                .args(["--json", "new", "-d", "--reuse", "-n", "worker"])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let outs: Vec<Output> = children.into_iter().map(|c| c.wait_with_output().unwrap()).collect();
    let all: Vec<String> = outs.iter().map(text).collect();
    assert!(outs.iter().all(|o| o.status.success()), "every --reuse gets worker: {all:#?}");
    let ids: std::collections::HashSet<String> = outs
        .iter()
        .map(|o| {
            let v: Value = serde_json::from_slice(&o.stdout).unwrap_or(Value::Null);
            v["sessionId"].as_str().unwrap_or_default().to_owned()
        })
        .collect();
    assert_eq!(ids.len(), 1, "one session: {all:#?}");
}
