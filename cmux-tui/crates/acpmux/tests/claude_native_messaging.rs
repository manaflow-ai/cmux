//! Claude Code's own cross-session messaging inside acpmux (bench round 6, A5 3 -> 1).
//!
//! An acpmux Claude Code agent asked to message another agent used Claude Code's own `ListAgents`
//! and `SendMessage`, not acpmux: the receiver held the message silently (a different permission
//! mode), `acpmux pending` showed nothing, and `ListAgents` listed a session of another acpmux
//! daemon. The stand-in (`fake_claude_auto.py`) models Claude Code 2.1.322's messaging as measured
//! on a fleet Mac: a machine-wide peer registry, `ListAgents`, `SendMessage` into a peer's inbox,
//! `CLAUDE_CODE_HARBOR_KITE=0` turning all of it off, and the `system/peer_message_hold` line a
//! receiver writes for a message it holds.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

const FAKE_AUTO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude_auto.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// One private daemon home whose `claude` harness is the stand-in Claude Code, sharing the peer
/// registry `registry` with every other daemon of the test (as every Claude Code of one user
/// shares `~/.claude/sessions`).
struct Daemon(PathBuf);

impl Daemon {
    fn new(tag: &str, registry: &Path) -> Self {
        Self::with_claude_env(tag, registry, json!({}))
    }

    /// `new`, with `extra` added to the stand-in Claude Code's environment.
    fn with_claude_env(tag: &str, registry: &Path, extra: Value) -> Self {
        // Short: the socket path must stay under the macOS limit.
        let dir = std::env::temp_dir().join(format!("w7a-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let dir = fs::canonicalize(&dir).unwrap();
        fs::create_dir(dir.join("work")).unwrap();
        let log = dir.join("calls.jsonl");
        let mut env = json!({"FAKE_AUTO_LOG": log, "FAKE_CLAUDE_PEER_REGISTRY": registry});
        for (key, value) in extra.as_object().into_iter().flatten() {
            env[key] = value.clone();
        }
        let config = json!({
            "harnesses": {
                "claude": {"argv": ["python3", FAKE_AUTO], "kind": "claude-stdio", "env": env},
                "fake": {"argv": ["python3", FAKE_AGENT]},
            },
            "defaultHarness": "claude",
            // The bench's agents ran with nothing held (bypassPermissions).
            "permissionPolicy": "approve-all",
        });
        fs::write(dir.join("config.json"), config.to_string()).unwrap();
        fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
        Self(dir)
    }

    fn run(&self, args: &[&str]) -> Output {
        daemon_env::command(&self.0, daemon_env::Agents::StandIn, &[])
            .args(args)
            .env("ACPMUX_HOME", &self.0)
            .env("ACPMUX_SOCKET", self.0.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(self.0.join("work"))
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> Output {
        let out = self.run(args);
        assert!(out.status.success(), "{args:?}: {}", diagnostic(&out));
        out
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = self.ok(args);
        serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|e| panic!("{args:?} is not JSON: {e}\n{}", diagnostic(&out)))
    }

    /// Starts session `name` on `harness` with `prompt`, and waits for its turn to end.
    fn start(&self, name: &str, harness: &str, prompt: &str) {
        self.ok(&["new", "-d", "-n", name, "-m", harness, prompt]);
        self.ok(&["wait", name, "--timeout", "60"]);
    }

    /// The tool calls the stand-in Claude Code made in this daemon, as it logged them.
    fn calls(&self) -> Vec<Value> {
        let text = fs::read_to_string(self.0.join("calls.jsonl")).unwrap_or_default();
        text.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.run(&["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn diagnostic(out: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// The prompt that makes the stand-in run `calls`, each `[tool, input]`.
fn auto(calls: &Value) -> String {
    format!("auto-tools: {calls}")
}

fn registry(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("w7a-reg-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir(&dir).unwrap();
    dir
}

/// The one logged call of `tool` whose input `to` is `to` (any, for `None`).
fn call<'a>(calls: &'a [Value], tool: &str, to: Option<&str>) -> &'a Value {
    calls
        .iter()
        .find(|c| c["tool"] == tool && to.is_none_or(|to| c["input"]["to"] == to))
        .unwrap_or_else(|| panic!("no {tool} call to {to:?}: {calls:?}"))
}

/// The bench's A5 try 1: ALPHA sent to the acpmux session BETA with Claude Code's SendMessage,
/// BETA held it and nothing showed it. A native send to a session of this daemon is now refused
/// before it runs, and the refusal names the acpmux command that delivers it (and waits for the
/// reply). A SendMessage to an agent of the session itself still runs.
#[test]
fn w7a_a_native_send_to_an_acpmux_session_is_refused_with_the_acpmux_command() {
    let registry = registry("send");
    let daemon = Daemon::new("send", &registry);
    daemon.start("beta", "fake", "hello");
    let calls = json!([
        ["SendMessage", {"to": "beta", "message": "What is the capital of France?"}],
        ["SendMessage", {"to": "beta [3fa9c1]", "message": "you, specifically"}],
        ["SendMessage", {"to": "main", "message": "done"}],
    ]);
    daemon.start("alpha", "claude", &auto(&calls));
    let calls = daemon.calls();
    for to in ["beta", "beta [3fa9c1]"] {
        let send = call(&calls, "SendMessage", Some(to));
        assert_eq!(send["ran"], false, "the native send to {to:?} ran: {send}");
        let reason = send["reason"].as_str().unwrap_or_default();
        assert!(reason.contains("\"$ACPMUX_BIN\" send beta --wait"), "{reason}");
        assert!(reason.contains("Nothing was sent"), "{reason}");
    }
    let own = call(&calls, "SendMessage", Some("main"));
    assert_eq!(own["ran"], true, "a send to the session's own agent was refused: {own}");
    let _ = fs::remove_dir_all(&registry);
}

/// `CLAUDE_CODE_HARBOR_KITE` is not a documented Claude Code setting. If a later Claude Code
/// renames or drops it, its own messaging is on again in acpmux agents: `ListAgents` lists the
/// other acpmux agents of the machine, and a `SendMessage` to one would be held or dropped out of
/// sight. The gate does not depend on the switch: it still refuses a native send to a session of
/// this daemon, or to a `NAME [ref]` row of `ListAgents`, with the acpmux command.
#[test]
fn w7a_the_gate_refuses_a_native_send_when_the_switch_has_no_effect() {
    let registry = registry("noswitch");
    let daemon =
        Daemon::with_claude_env("noswitch", &registry, json!({"FAKE_CLAUDE_IGNORE_SWITCH": "1"}));
    daemon.start("beta", "claude", &auto(&json!([])));
    let calls = json!([
        ["ListAgents", {}],
        ["SendMessage", {"to": "beta", "message": "What is the capital of France?"}],
        ["SendMessage", {"to": "beta [3fa9c1]", "message": "you, specifically"}],
    ]);
    daemon.start("alpha", "claude", &auto(&calls));
    let calls = daemon.calls();
    // The switch had no effect: Claude Code's own messaging is on and reaches beta.
    let listed = call(&calls, "ListAgents", None);
    assert_eq!(listed["ran"], true, "{listed}");
    assert!(listed["output"].as_str().unwrap_or_default().contains("beta"), "{listed}");
    for to in ["beta", "beta [3fa9c1]"] {
        let send = call(&calls, "SendMessage", Some(to));
        assert_eq!(send["ran"], false, "the native send to {to:?} ran: {send}");
        let reason = send["reason"].as_str().unwrap_or_default();
        assert!(reason.contains("\"$ACPMUX_BIN\" send beta --wait"), "{reason}");
    }
    let _ = fs::remove_dir_all(&registry);
}

/// The bench's isolation finding: ALPHA's `ListAgents` on a private daemon listed the eval
/// agent's session on another daemon. A Claude Code agent acpmux starts now takes no part in
/// Claude Code's machine-wide peer list: it lists no session of another daemon, and no session of
/// another daemon lists it. Its peers are the sessions `acpmux ls` lists.
#[test]
fn w7a_the_peer_list_of_one_daemon_has_no_session_of_another() {
    let registry = registry("peers");
    let other = Daemon::new("peers-b", &registry);
    other.start("bravo", "claude", &auto(&json!([])));
    let daemon = Daemon::new("peers-a", &registry);
    daemon.start("alpha", "claude", &auto(&json!([["ListAgents", {}]])));
    let calls = daemon.calls();
    let listed = call(&calls, "ListAgents", None);
    let output = listed["output"].as_str().unwrap_or_default();
    assert!(!output.contains("bravo"), "daemon A's agent lists daemon B's session: {listed}");
    // Nor can any Claude Code on the machine list or message an acpmux agent natively.
    let registered: Vec<String> = fs::read_dir(&registry)
        .unwrap()
        .filter_map(|e| fs::read_to_string(e.ok()?.path()).ok())
        .collect();
    assert!(registered.is_empty(), "acpmux agents in Claude Code's peer registry: {registered:?}");
    // acpmux's own list is the peer list: this daemon's sessions only.
    let ls = daemon.json(&["--json", "ls"]);
    let names: Vec<&str> = ls["sessions"]
        .as_array()
        .unwrap_or_else(|| panic!("{ls}"))
        .iter()
        .filter_map(|s| s["name"].as_str())
        .collect();
    assert!(names.contains(&"alpha") && !names.contains(&"bravo"), "{names:?}");
    let _ = fs::remove_dir_all(&registry);
}

/// The bench's BETA held ALPHA's message and acpmux showed nothing (`pending` none). A message
/// Claude Code holds (`system/peer_message_hold`, state held) now shows in `acpmux pending`, text
/// and JSON, and in the session's info, until Claude Code says it was released or dropped.
#[test]
fn w7a_a_message_claude_code_holds_shows_in_pending() {
    let registry = registry("hold");
    let daemon = Daemon::new("hold", &registry);
    let held = json!({"state": "held", "message_uuid": "m-1", "from": "uds:/tmp/cc-socks/1.sock",
        "from_name": "alpha", "cause": "mode-mismatch"});
    daemon.start("beta", "claude", &format!("peer-hold: {held}"));
    let pending = daemon.json(&["--json", "pending"]);
    let rows = pending["heldMessages"].as_array().unwrap_or_else(|| panic!("{pending}"));
    assert_eq!(rows.len(), 1, "{pending}");
    assert_eq!(rows[0]["session"], "beta", "{pending}");
    assert_eq!(rows[0]["fromName"], "alpha", "{pending}");
    assert_eq!(rows[0]["cause"], "mode-mismatch", "{pending}");
    assert_eq!(rows[0]["messageUuid"], "m-1", "{pending}");
    let text = String::from_utf8_lossy(&daemon.ok(&["pending"]).stdout).into_owned();
    assert!(text.contains("beta") && text.contains("held") && text.contains("alpha"), "{text}");
    let info = daemon.json(&["--json", "session", "info", "beta"]);
    assert_eq!(info["heldMessages"][0]["fromName"], "alpha", "{info}");
    // Claude Code dropped it (no one approved it in time): it leaves pending.
    let dropped = json!({"state": "dropped", "message_uuid": "m-1", "outcome": "expired"});
    daemon.ok(&["send", "beta", &format!("peer-hold: {dropped}")]);
    let pending = daemon.json(&["--json", "pending"]);
    assert_eq!(pending["heldMessages"], json!([]), "{pending}");
    let _ = fs::remove_dir_all(&registry);
}
