//! `acpmux run --ephemeral` (and `acpmux exec`, `cmux acp run --ephemeral`)
//! never leaves a session behind, through the real binaries (2026-10-20).
//!
//! Only the CLI deleted an ephemeral session, with a `_acpmux/kill {purge}`
//! after the reply. Any exit before that line kept the session for good: the
//! CLI killed by a signal or by its caller's timeout while the turn ran (an
//! agent's Bash tool), a bad flag value checked after `session/new`, or a
//! connection that dropped. Agents running a smoke test by hand left
//! persistent "Reply with only: OK" chats in Leo's list.
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

/// One daemon on its own socket and home, with the fake agent as its only harness.
struct Daemon {
    root: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        // Short: the socket path must stay under the macOS limit.
        let root = std::env::temp_dir().join(format!("eph-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["home", "amx", "work"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let root = std::fs::canonicalize(&root).unwrap();
        std::fs::write(
            root.join("amx").join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        let mut daemon = Self { root, child: None };
        // `--memory`: no store on disk, so no agent host outlives the test.
        let mut child = daemon
            .cmd()
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut out = BufReader::new(child.stdout.take().unwrap());
        let mut seen = String::new();
        loop {
            let mut line = String::new();
            let n = out.read_line(&mut line).unwrap();
            assert!(n > 0, "daemon exited before it was ready: {seen}");
            if line.contains("\"ready\":true") {
                break;
            }
            seen.push_str(&line);
        }
        daemon.child = Some(child);
        daemon
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
            // Not inside a session: no spawnedBy tag.
            .env_remove("ACPMUX_SESSION_ID")
            .stdin(Stdio::null());
        cmd
    }

    fn run(&self, args: &[&str]) -> Output {
        self.cmd().args(args).output().expect("run acpmux")
    }

    /// Every session the daemon lists.
    fn sessions(&self) -> Vec<Value> {
        let out = self.run(&["--json", "ls"]);
        assert!(out.status.success(), "ls failed: {}", text(&out));
        let v: Value = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|e| panic!("ls printed no JSON ({e}): {}", text(&out)));
        v["sessions"].as_array().cloned().unwrap_or_default()
    }

    /// Waits until the daemon lists no session; panics with what it still lists.
    fn assert_no_session_within(&self, limit: Duration, why: &str) {
        let start = Instant::now();
        loop {
            let left = self.sessions();
            if left.is_empty() {
                return;
            }
            assert!(
                start.elapsed() < limit,
                "{why}: the ephemeral session is still there after {limit:?}: {left:?}"
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

#[test]
fn ephemeral_run_leaves_no_session_after_its_reply() {
    let daemon = Daemon::start("ok");
    let out = daemon.run(&["run", "--ephemeral", "--timeout", "60", "Reply with only: OK"]);
    assert!(out.status.success(), "run failed: {}", text(&out));
    assert!(String::from_utf8_lossy(&out.stdout).contains("Reply with only: OK"), "{}", text(&out));
    daemon.assert_no_session_within(Duration::from_secs(10), "after the reply");
}

#[test]
fn ephemeral_run_killed_during_its_turn_leaves_no_session() {
    let daemon = Daemon::start("kill");
    // The turn runs until it is cancelled; the CLI is killed meanwhile, as
    // a caller's timeout or Ctrl-C ends it.
    let mut cli = daemon
        .cmd()
        .args(["run", "--ephemeral", "--stall", "0", "until-cancel"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start acpmux run");
    let start = Instant::now();
    loop {
        let running = daemon.sessions().iter().any(|s| s["status"] == "running");
        if running {
            break;
        }
        assert!(cli.try_wait().unwrap().is_none(), "acpmux run ended before its turn started");
        assert!(start.elapsed() < Duration::from_secs(30), "the turn never started");
        std::thread::sleep(Duration::from_millis(100));
    }
    cli.kill().unwrap();
    cli.wait().unwrap();
    daemon.assert_no_session_within(Duration::from_secs(15), "after the CLI was killed");
}

#[test]
fn ephemeral_run_with_a_bad_flag_value_leaves_no_session() {
    let daemon = Daemon::start("flag");
    let out =
        daemon.run(&["run", "--ephemeral", "--on-permission", "bogus", "Reply with only: OK"]);
    assert!(!out.status.success(), "a bad --on-permission passed: {}", text(&out));
    daemon.assert_no_session_within(Duration::from_secs(10), "after a usage error");
}

/// The variables an agent's shell has that prove its session to the daemon (`hub/person.rs`
/// (a)): the daemon records lineage only from a proven caller (`hub/lineage.rs`), never from
/// `ACPMUX_SESSION_ID` alone.
const CALLER_ENV: [&str; 3] =
    ["ACPMUX_SESSION_ID", "ACPMUX_SESSION_TOKEN", "ACPMUX_SESSION_TOKEN_SOCKET"];

/// A session an agent's shell starts folds under that agent's chat, unless it is a throwaway
/// check: a probe runs ephemeral and leaves no chat at all.
#[test]
fn a_probe_from_an_agents_shell_is_not_its_subagent() {
    let daemon = Daemon::start("parent");
    let run = |prompt: &str, shell: &[(String, String)]| -> Value {
        let mut cmd = daemon.cmd();
        cmd.envs(shell.iter().map(|(k, v)| (k, v)));
        let out = cmd.args(["--json", "run", "--timeout", "60", prompt]).output().expect("run");
        assert!(out.status.success(), "run {prompt:?} failed: {}", text(&out));
        serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|e| panic!("run printed no JSON ({e}): {}", text(&out)))
    };
    let id = |v: &Value| v["sessionId"].as_str().expect("sessionId").to_owned();
    // The parent's agent reports its own environment: the shell it runs commands in.
    let reply = run(&format!("envs: {}", CALLER_ENV.join(",")), &[]);
    let parent = id(&reply);
    let env: Value = serde_json::from_str(reply["reply"].as_str().expect("reply"))
        .unwrap_or_else(|e| panic!("the agent printed no environment ({e}): {reply}"));
    let shell: Vec<(String, String)> = CALLER_ENV
        .iter()
        .map(|k| {
            let v = env[k].as_str().filter(|v| !v.is_empty());
            (
                k.to_string(),
                v.unwrap_or_else(|| panic!("the agent's shell lacks {k}: {env}")).into(),
            )
        })
        .collect();
    assert_eq!(shell[0].1, parent, "the agent's shell names its own session");
    let probe = id(&run("Reply with only: OK", &shell));
    let child = id(&run("Review the release diff", &shell));
    let listed = daemon.sessions();
    let find = |id: &str| listed.iter().find(|s| s["sessionId"] == id);
    let child = find(&child).unwrap_or_else(|| panic!("{child} is not listed: {listed:?}"));
    assert_eq!(child["spawnedBy"], json!(parent), "a real task from the agent is its subagent");
    assert!(find(&probe).is_none(), "the probe left its chat: {listed:?}");
}
