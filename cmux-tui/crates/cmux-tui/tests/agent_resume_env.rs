//! An agent that `cmux agent start` or `cmux agent resume` runs gets the
//! person's environment, never the session environment of the agent that
//! called cmux (bench round 4, A6).
//!
//! An orchestrating agent (Claude Code, an acpmux session) runs the cmux CLI
//! with its own session variables: `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
//! Claude's cross-session messaging socket and token, acpmux's session token.
//! When that CLI starts the session owner (`server ensure`, `daemon restart`,
//! the first command of a session), the owner must not keep them: every
//! terminal it hosts inherits the owner's environment. A resumed Claude that
//! inherits them says "Transcript saving is off", and the caller's tokens
//! reach a process that is not the caller.
//!
//! The `claude` here is a stand-in that runs the cmux plugin's SessionStart
//! hook (so the daemon learns its session id, which resume needs) and records
//! its arguments and the NAMES of its environment, never the values.

#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[path = "support/private_state.rs"]
mod private_state;

/// The value every caller session variable of this test has.
const SENTINEL: &str = "w5r-caller-session-value";
/// The session id the stand-in's first run reports.
const SESSION: &str = "00000000-0000-4000-8000-0000000000a1";

/// What an orchestrating Claude Code or acpmux agent has in its environment
/// when it runs cmux.
const CALLER_SESSION_ENV: &[(&str, &str)] = &[
    ("CLAUDECODE", "1"),
    ("CLAUDE_CODE_ENTRYPOINT", "cli"),
    ("CLAUDE_CODE_SESSION_ID", SENTINEL),
    ("CLAUDE_CODE_CHILD_SESSION", SENTINEL),
    ("CLAUDE_CODE_MESSAGING_SOCKET", SENTINEL),
    ("CLAUDE_CODE_MESSAGING_TOKEN", SENTINEL),
    ("ANTHROPIC_BASE_URL", SENTINEL),
    ("AI_AGENT", SENTINEL),
    ("ACPMUX_ENV", "1"),
    ("ACPMUX_SESSION_ID", SENTINEL),
    ("ACPMUX_SESSION_NAME", SENTINEL),
    ("ACPMUX_SESSION_TOKEN", SENTINEL),
    ("ACPMUX_HOST_NONCE", SENTINEL),
    ("CMUX_AGENT_SESSION", SENTINEL),
    // A Chief turn's own messaging credential (acpmux CHIEF_CREDENTIAL_ENV)
    // and a background task's subagent mark (review 6731023492, item 5).
    ("MUX_AGENT_TOKEN_FILE", SENTINEL),
    ("OPTCHAT_CHIEF_PARTICIPANT", SENTINEL),
    ("ACPMUX_CALLER_SUBAGENT", SENTINEL),
    // The calling agent's app socket password and path (cmux sets no value
    // of its own in a terminal `agent start` opens), Codex's sandbox mark
    // and its session ids (review of #39027).
    ("CMUX_SOCKET_PASSWORD", SENTINEL),
    ("CMUX_SOCKET_PATH", "/nonexistent/w5r-caller-session-value.sock"),
    ("CODEX_SANDBOX", SENTINEL),
    ("CODEX_SANDBOX_NETWORK_DISABLED", SENTINEL),
    ("CODEX_THREAD_ID", SENTINEL),
    ("CODEX_SESSION_ID", SENTINEL),
];

/// A setting of the person's own that the agents keep.
const PERSON_SETTING: (&str, &str) = ("W5R_PERSON_SETTING", "kept");

/// Claude Code reduced to what this test needs: SessionStart through the
/// plugin folders cmux names in `CLAUDE_CODE_PLUGIN_DIRS`, then a record of
/// its arguments and environment names, then it runs until a line is typed.
const FAKE_CLAUDE: &str = r#"#!/usr/bin/env python3
import json, os, subprocess, sys

records = "@RECORDS@"
sentinel = "@SENTINEL@"
args = sys.argv[1:]
session = "@SESSION@"
if "--resume" in args and args.index("--resume") + 1 < len(args):
    session = args[args.index("--resume") + 1]
os.makedirs(records, exist_ok=True)
n = len([name for name in os.listdir(records) if name.startswith("run-")]) + 1

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

payload = {"session_id": session, "transcript_path": "/dev/null", "cwd": os.getcwd(),
           "hook_event_name": "SessionStart",
           "source": "resume" if "--resume" in args else "startup"}
for folder in os.environ.get("CLAUDE_CODE_PLUGIN_DIRS", "").split(":"):
    folder = folder.strip()
    if not folder or not os.path.isabs(folder):
        continue
    hooks = (load(os.path.join(folder, "hooks", "hooks.json")).get("hooks") or {})
    for group in hooks.get("SessionStart") or []:
        for hook in group.get("hooks") or []:
            if hook.get("command"):
                env = dict(os.environ)
                env["CLAUDE_PLUGIN_ROOT"] = folder
                subprocess.run(["/bin/sh", "-c", hook["command"]],
                               input=json.dumps(payload).encode(), env=env,
                               capture_output=True, timeout=60)

record = {
    "args": args,
    "names": sorted(os.environ.keys()),
    "names_with_caller_value": sorted(k for k, v in os.environ.items() if sentinel in v),
    "person_setting": os.environ.get("W5R_PERSON_SETTING"),
}
out = os.path.join(records, "run-%d.json" % n)
with open(out + ".tmp", "w") as f:
    json.dump(record, f)
os.rename(out + ".tmp", out)
print("stand-in claude run %d ready" % n, flush=True)
# Runs until a line arrives on its terminal (the test types one).
sys.stdin.readline()
"#;

fn unique_root() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmux-w5r-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    // macOS /tmp is a symlink; the daemon resolves its own path.
    root.canonicalize().unwrap()
}

/// Writes `contents` as an executable file through a short-lived `sh`, so no
/// fork of this test process holds a write descriptor to it (ETXTBSY).
fn write_executable(path: &Path, contents: &str) {
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat > \"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents.as_bytes()).unwrap();
    assert!(child.wait().unwrap().success(), "write {}", path.display());
}

/// One session owner started the way an agent's CLI starts it, and the CLI
/// that agent runs.
struct Session {
    root: PathBuf,
    exe: PathBuf,
    socket: PathBuf,
}

impl Session {
    /// A `cmux-tui` command with the person's isolated home and the calling
    /// agent's session environment.
    fn cli(&self) -> Command {
        let mut command = Command::new(&self.exe);
        command
            .env("HOME", self.root.join("home"))
            .env("XDG_DATA_HOME", self.root.join("data"))
            .env("PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/sh")
            .env("LC_ALL", "C")
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("CMUX_TUI_CONFIG", self.root.join("config.json"))
            .env("CMUX_TUI_HOST_EXE_DIR", self.root.join("host-exe"))
            .env(PERSON_SETTING.0, PERSON_SETTING.1);
        for key in [
            "CMUX_TUI_HOOK",
            "CMUX_TUI_SOCKET",
            "CMUX_MUX_SOCKET",
            "CMUX_TUI_TERMINAL_ID",
            "CMUX_TUI_AGENT_SHIMS",
            "CMUX_TUI_CLAUDE_WRAPPER_ACTIVE",
            "CMUX_TUI_CLAUDE_HOOKS_DISABLED",
            "CMUX_AGENT_COMMAND",
            "CLAUDE_CODE_PLUGIN_DIRS",
            "CLAUDE_CONFIG_DIR",
            "SR2_CLAUDE2_HOOK_SOCKET",
            "TMUX",
            "CMUX_BUNDLE_ID",
            "CMUX_TAG",
            "CMUX_BUNDLED_CLI_PATH",
        ] {
            command.env_remove(key);
        }
        for (key, value) in CALLER_SESSION_ENV {
            command.env(key, value);
        }
        private_state::use_private_state(&mut command, &self.root);
        command
    }

    /// `cmux-tui --json --socket S ARGS...` as the calling agent runs it.
    fn run(&self, args: &[&str]) -> Output {
        let mut command = self.cli();
        command.args(["--json", "--socket"]).arg(&self.socket).args(args);
        command.output().unwrap()
    }

    fn json(&self, args: &[&str]) -> serde_json::Value {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "cmux {args:?} failed: {:?}\nstdout: {}\nstderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null)
    }

    fn screen(&self, terminal: &str) -> String {
        let output = self.run(&["terminal", terminal, "screen", "read"]);
        String::from_utf8_lossy(&output.stdout).into_owned()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.run(&["daemon", "stop", "--end-terminals"]);
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Waits for `pattern` on `terminal`'s screen: the daemon's own screen
/// wait, which answers when the output arrives.
fn wait_screen(session: &Session, terminal: &str, pattern: &str, what: &str) {
    let output = session.run(&[
        "terminal",
        terminal,
        "screen",
        "wait",
        "--pattern",
        pattern,
        "--timeout-ms",
        "90000",
    ]);
    assert!(
        output.status.success(),
        "{what}: {}\nstderr: {}\nscreen: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
        session.screen(terminal)
    );
}

/// What the stand-in recorded on run `n`: it writes the record, then says
/// that the run is ready.
fn launch_record(session: &Session, n: u32, terminal: &str) -> serde_json::Value {
    wait_screen(
        session,
        terminal,
        &format!("stand-in claude run {n} ready"),
        &format!("the agent never ran (run {n})"),
    );
    let path = session.root.join("records").join(format!("run-{n}.json"));
    serde_json::from_slice(&fs::read(&path).unwrap()).unwrap()
}

/// The caller's session variable names in a launch record.
fn caller_names(record: &serde_json::Value) -> Vec<String> {
    let names: Vec<&str> = record["names"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .collect();
    CALLER_SESSION_ENV
        .iter()
        .map(|(key, _)| *key)
        .filter(|key| names.contains(key))
        .map(str::to_owned)
        .collect()
}

fn assert_person_env(record: &serde_json::Value, what: &str) {
    assert_eq!(
        caller_names(record),
        Vec::<String>::new(),
        "{what}: the agent inherited the calling agent's session variables (names only)"
    );
    assert_eq!(
        record["names_with_caller_value"],
        serde_json::json!([]),
        "{what}: a variable carries a calling agent's session value (names only)"
    );
    assert_eq!(
        record["person_setting"], PERSON_SETTING.1,
        "{what}: the person's own settings stay in the agent's environment"
    );
}

#[test]
fn w5r_agents_started_and_resumed_from_an_agent_caller_get_none_of_its_session_env() {
    let root = unique_root();
    for dir in ["home", "data", "realbin", "records", "proj", "build"] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    let claude = root.join("realbin").join("claude");
    write_executable(
        &claude,
        &FAKE_CLAUDE
            .replace("@RECORDS@", &root.join("records").display().to_string())
            .replace("@SENTINEL@", SENTINEL)
            .replace("@SESSION@", SESSION),
    );
    // The daemon's build: this binary alone in a folder, so its hooks run the
    // build's own hook launcher (as tests/claude_any_launcher.rs).
    let exe = root.join("build").join("cmux-tui");
    if fs::hard_link(env!("CARGO_BIN_EXE_cmux-tui"), &exe).is_err() {
        fs::copy(env!("CARGO_BIN_EXE_cmux-tui"), &exe).unwrap();
    }
    let session = Session { socket: root.join("s.sock"), exe, root: root.clone() };

    // The calling agent's CLI starts the session owner.
    let ensure = session
        .cli()
        .args(["server", "ensure", "--json", "--session", "w5r", "--socket"])
        .arg(&session.socket)
        .output()
        .unwrap();
    assert!(
        ensure.status.success(),
        "server ensure failed: {}",
        String::from_utf8_lossy(&ensure.stderr)
    );

    let launcher = claude.display().to_string();
    let proj = root.join("proj").display().to_string();
    // `agent start` waits until the agent itself reports idle: its
    // SessionStart hook, which also names the session id resume needs.
    let started = session.json(&[
        "agent",
        "start",
        "w5rbot",
        "--cmd",
        &launcher,
        "--cwd",
        &proj,
        "--no-focus",
        "--timeout",
        "90s",
    ]);
    assert_eq!(started["state"], "ready", "agent start: {started}");
    let terminal = started["terminal_id"].as_str().unwrap_or_default().to_owned();
    assert!(terminal.starts_with("term_"), "agent start reported no terminal: {started}");
    let first = launch_record(&session, 1, &terminal);
    assert_person_env(&first, "agent start");
    let agents = session.json(&["agent", "list", "--terminal", &terminal]);
    let known = agents.as_array().into_iter().flatten().any(|row| {
        row.pointer("/extra/agent_session_id").and_then(serde_json::Value::as_str) == Some(SESSION)
    });
    assert!(known, "the hook did not report the session: {agents}");
    session.json(&["terminal", &terminal, "write", "--text", "quit\n"]);
    // The stand-in shows no prompt; the wait for one ends when its terminal
    // exits (the daemon's event stream, terminal.exited).
    let exited =
        session.run(&["terminal", &terminal, "wait", "--until", "prompt", "--timeout", "60s"]);
    // A `--json` error is one JSON document on stderr.
    let exited_json: serde_json::Value =
        serde_json::from_slice(&exited.stderr).unwrap_or(serde_json::Value::Null);
    assert_eq!(
        exited_json.get("code").and_then(serde_json::Value::as_str),
        Some("terminal.exited"),
        "the agent never exited: {exited_json} {}",
        String::from_utf8_lossy(&exited.stdout)
    );

    let resumed = session.json(&["agent", "resume", "w5rbot", "--no-focus", "--no-wait"]);
    let new_terminal = resumed["terminal_id"].as_str().unwrap_or_default().to_owned();
    assert_eq!(resumed["resumed"]["agent_session_id"], SESSION, "{resumed}");
    let second = launch_record(&session, 2, &new_terminal);
    let args: Vec<&str> = second["args"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .collect();
    assert_eq!(args, ["--resume", SESSION], "resume runs the launcher with the session");
    assert_person_env(&second, "agent resume");
    drop(session);
}
