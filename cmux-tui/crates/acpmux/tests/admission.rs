//! The daemon admits a new session only when its host has room (deputy-2, 2026-10-22).
//!
//! About 25 Codex reviewers were started on huge-blue with a raw `acpmux new` over
//! reach from other hosts. That went around lane-place's cap of 12, filled the disk
//! to 98-100% and pushed the load to 50-80. Every path to a new session goes through
//! the daemon's `session/new`, so the daemon checks there, reading two files when the
//! session is created:
//! - `~/.cache/worktree-reclaim/under-floor` (worktree-reclaim writes it when the disk
//!   is under its free-space floor) refuses every new session;
//! - `lanes.max_lanes` of this machine in the fleet registry (`FLEET_REGISTRY`, else
//!   `~/.ssh/config.d/fleet-registry.json`, the copy `reach --install` renders, else a
//!   leo-workspace checkout's `machines/fleet-registry.json`) caps this host's live
//!   sessions (running, ready, waiting).
//!
//! A refusal exits 5 (lane-place's "no host qualifies"). `--force-admit` creates the
//! session anyway, and the daemon logs it. A send to an existing session and a restart
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

/// The JSON error envelope a refused command printed on stderr.
fn envelope(out: &Output) -> Value {
    let err = String::from_utf8_lossy(&out.stderr);
    err.lines()
        .rev()
        .find_map(|l| serde_json::from_str::<Value>(l).ok())
        .unwrap_or_else(|| panic!("no JSON error envelope: {}", text(out)))
}

fn assert_refused(out: &Output, why: &str, words: &str) {
    assert_eq!(out.status.code(), Some(5), "a refused create exits 5: {}", text(out));
    let e = envelope(out);
    assert_eq!(e["error"]["detail"], "admission_refused", "{e}");
    assert_eq!(e["error"]["data"]["why"], why, "{e}");
    let message = e["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains(words), "the refusal says {words:?}: {message}");
    assert!(message.contains("--force-admit"), "the refusal names the override: {message}");
}

#[test]
fn under_floor_flag_refuses_a_new_session_and_a_run() {
    let daemon = Daemon::start("flag", None, true);
    let out = daemon.create("a", &[]);
    assert_refused(&out, "under_floor", "under-floor");
    let out =
        daemon.run(&["--json", "run", "--ephemeral", "--timeout", "30", "Reply with only: OK"]);
    assert_refused(&out, "under_floor", "under-floor");
    // Read at create time: once worktree-reclaim clears it, a create goes through.
    daemon.set_under_floor(false);
    let out = daemon.create("b", &[]);
    assert!(out.status.success(), "the flag is gone: {}", text(&out));
}

#[test]
fn max_lanes_refuses_at_the_cap_and_admits_under_it() {
    let daemon = Daemon::start("cap", Some(2), false);
    for name in ["one", "two"] {
        let out = daemon.create(name, &[]);
        assert!(out.status.success(), "under the cap: {}", text(&out));
        daemon.wait_live(name);
    }
    let out = daemon.create("three", &[]);
    assert_refused(
        &out,
        "max_lanes",
        "2 live sessions, at its cap of 2 (lanes.max_lanes of test-box in ",
    );
    assert!(
        text(&out).contains(".ssh/config.d/fleet-registry.json"),
        "names the registry: {}",
        text(&out)
    );
    // A session that stopped is not live: there is room again.
    let out = daemon.run(&["kill", "one"]);
    assert!(out.status.success(), "kill: {}", text(&out));
    let out = daemon.create("three", &[]);
    assert!(out.status.success(), "a stopped session frees its place: {}", text(&out));
}

#[test]
fn force_admit_creates_past_a_refusal_and_is_logged() {
    let daemon = Daemon::start("force", Some(0), true);
    let out = daemon.create("forced", &["--force-admit"]);
    assert!(out.status.success(), "--force-admit admits: {}", text(&out));
    daemon.wait_log(
        |l| l.contains("force-admit") && l.contains("under_floor"),
        "the daemon logs the override and what it overrode",
    );
}

#[test]
fn sends_and_restarts_of_existing_sessions_are_never_refused() {
    let daemon = Daemon::start("send", Some(1), false);
    let out = daemon.create("kept", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("kept");
    // At the cap and under the floor at once.
    daemon.set_under_floor(true);
    assert_refused(&daemon.create("other", &[]), "under_floor", "under-floor");
    let out = daemon.run(&["send", "kept", "--timeout", "30", "Reply with only: OK"]);
    assert!(out.status.success(), "a send to an existing session: {}", text(&out));
    let out = daemon.run(&["session", "restart", "kept"]);
    assert!(out.status.success(), "a restart of an existing session: {}", text(&out));
    let out = daemon.run(&["send", "kept", "--timeout", "30", "Reply with only: again"]);
    assert!(out.status.success(), "a send after the restart: {}", text(&out));
    // A fork is a new session: refused, unless forced.
    let out = daemon.run(&["--json", "fork", "kept", "-n", "kept-fork"]);
    assert_refused(&out, "under_floor", "under-floor");
    let out = daemon.run(&["--json", "fork", "kept", "-n", "kept-fork", "--force-admit"]);
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
    assert_eq!(out.status.code(), Some(5), "the daemon's own machine decides: {}", text(&out));
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
fn a_set_fleet_registry_that_is_missing_refuses() {
    // FLEET_REGISTRY names the file on purpose: a rename, a failed mount or a
    // typo must not lift the cap, as the usual copies being absent does.
    let daemon = Daemon::start_with("setreg", None, false, Some("reg/fleet-registry.json"));
    assert_refused(
        &daemon.create("a", &[]),
        "registry_unreadable",
        "fleet registry cannot be read",
    );
    // Once it is there, its cap applies.
    let dir = daemon.root.join("reg");
    std::fs::create_dir_all(&dir).unwrap();
    let registry = json!({"machines": {MACHINE: {"lanes": {"max_lanes": 1}}}});
    std::fs::write(dir.join("fleet-registry.json"), registry.to_string()).unwrap();
    let out = daemon.create("a", &[]);
    assert!(out.status.success(), "{}", text(&out));
    daemon.wait_live("a");
    assert_refused(&daemon.create("b", &[]), "max_lanes", "at its cap of 1");
    // Gone again: the last good copy keeps the cap.
    std::fs::remove_file(dir.join("fleet-registry.json")).unwrap();
    assert_refused(&daemon.create("b", &[]), "max_lanes", "at its cap of 1");
}

#[test]
fn a_registry_folder_that_cannot_be_searched_never_lifts_the_cap() {
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
    // so the last good copy keeps the cap.
    mode(&dir, 0o000);
    let out = daemon.create("b", &[]);
    mode(&dir, 0o700);
    assert_refused(&out, "max_lanes", "at its cap of 1");
    drop(daemon);
    // With no good copy read before, the create is refused as unreadable.
    let daemon = Daemon::start("noaccess2", Some(1), false);
    let dir = daemon_env::home(&daemon.root).join(".ssh/config.d");
    mode(&dir, 0o000);
    let out = daemon.create("a", &[]);
    mode(&dir, 0o700);
    assert_refused(&out, "registry_unreadable", "fleet registry cannot be read");
}

#[test]
fn a_leo_workspace_checkouts_registry_caps_a_host_with_no_rendered_copy() {
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
    assert_refused(&out, "max_lanes", "1 live sessions, at its cap of 1");
    assert!(
        text(&out).contains("Projects/leo-workspace/machines/fleet-registry.json"),
        "names the checkout's registry: {}",
        text(&out)
    );
}

#[test]
fn concurrent_creates_at_the_cap_do_not_all_pass() {
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
    let refused = outs.iter().filter(|o| o.status.code() == Some(5)).count();
    let all: Vec<String> = outs.iter().map(text).collect();
    assert_eq!((made, refused), (2, 4), "two made, four refused: {all:#?}");
}

#[test]
fn reuse_launches_of_one_name_at_the_cap_all_get_the_one_session() {
    // Room for one: the create that wins the name takes it, and every other
    // `new --reuse` of that name reuses the winner instead of being refused.
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
