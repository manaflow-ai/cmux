//! Claude Code in a cmux-tui pane reports to the pane's session however it
//! was started: through the `claude` shim on PATH, by its full path, or by a
//! launcher (`sr2 claude`, a version-manager shim, an alias) that runs it by
//! full path with its own `CLAUDE_CONFIG_DIR` and its own `--settings`.
//!
//! The `claude` here is a stand-in for Claude Code that loads hooks the way
//! Claude Code 2.1 does: the user settings of its config directory (unless
//! `--setting-sources` leaves `user` out), the last `--settings` file, and
//! every plugin folder named in `CLAUDE_CODE_PLUGIN_DIRS`
//! (`hooks/hooks.json`, run with `CLAUDE_PLUGIN_ROOT`). Identical commands
//! from settings files run once; plugin hooks are never merged with them. It
//! then runs `SessionStart`, `UserPromptSubmit` and `Stop` and records the
//! hook output. Like Claude Code it gives the commands it starts
//! `CLAUDE_PID` (its process id) and its `SessionStart` hooks a
//! `CLAUDE_ENV_FILE`, and on request it starts another Claude the way a Bash
//! tool call would (after sourcing that file). The hook helper is the real one, so the
//! daemon's agent roster and message inbox show whether the events arrived.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "support/private_state.rs"]
mod private_state;

/// Claude Code's hook loading, reduced to what the test needs.
const FAKE_CLAUDE: &str = r#"#!/usr/bin/env python3
import json, os, subprocess, sys, time

args = sys.argv[1:]
settings_file = None
setting_sources = None
i = 0
while i < len(args):
    if args[i] in ("--settings", "--setting-sources") and i + 1 < len(args):
        if args[i] == "--settings":
            settings_file = args[i + 1]
        else:
            setting_sources = args[i + 1]
        i += 2
        continue
    if args[i].startswith("--settings="):
        settings_file = args[i][len("--settings="):]
    if args[i].startswith("--setting-sources="):
        setting_sources = args[i][len("--setting-sources="):]
    i += 1
reads_user = setting_sources is None or "user" in [s.strip() for s in setting_sources.split(",")]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")
settings_sources = [load(os.path.join(config, "settings.json"))] if reads_user else []
if settings_file:
    settings_sources.append(load(settings_file))
plugins = []
for folder in os.environ.get("CLAUDE_CODE_PLUGIN_DIRS", "").split(":"):
    folder = folder.strip()
    if folder and os.path.isabs(folder):
        plugins.append((folder, load(os.path.join(folder, "hooks", "hooks.json"))))

def commands(event):
    seen, out = set(), []
    for source in settings_sources:
        for group in (source.get("hooks") or {}).get(event) or []:
            for hook in group.get("hooks") or []:
                command = hook.get("command")
                if command and command not in seen:
                    seen.add(command)
                    out.append((command, None))
    for root, source in plugins:
        for group in (source.get("hooks") or {}).get(event) or []:
            for hook in group.get("hooks") or []:
                if hook.get("command"):
                    out.append((hook["command"], root))
    return out

session = os.environ["FAKE_SESSION_ID"]
record = {"session_id": session, "outputs": {}}
# The session's env file: SessionStart hooks may append `export` lines, and
# Claude Code sources it before each Bash tool command when it exists. Like
# Claude Code 2.1.319, the stand-in does not create it.
env_file = os.path.join(os.environ["FAKE_RECORD_DIR"], "env-" + os.environ["OB_TAG"] + ".sh")

def run_round(session, payloads):
    outputs_by_event = {}
    for event, extra in payloads:
        payload = {"session_id": session, "transcript_path": "/dev/null", "cwd": os.getcwd(),
                   "hook_event_name": event}
        payload.update(extra)
        outputs = []
        for command, root in commands(event):
            # What Claude Code sets for the commands it starts, hooks and tools.
            env = dict(os.environ, CLAUDECODE="1", CLAUDE_PID=str(os.getpid()),
                       CLAUDE_CODE_SESSION_ID=session)
            if event == "SessionStart":
                env["CLAUDE_ENV_FILE"] = env_file
            if root:
                env["CLAUDE_PLUGIN_ROOT"] = root
            if os.environ.get("FAKE_HOOKS_SOURCE_ENV_FILE"):
                # As if Claude Code sourced the env file for its hooks too
                # (2.1.319 does so only for Bash tool commands).
                env["FAKE_SOURCE"] = env_file
                command = '[ -f "$FAKE_SOURCE" ] && . "$FAKE_SOURCE"; ' + command
            done = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(payload).encode(),
                                  env=env, capture_output=True, timeout=60)
            outputs.append(done.stdout.decode(errors="replace"))
        outputs_by_event[event] = outputs
    return outputs_by_event

def write_record(tag, record):
    out = os.path.join(os.environ["FAKE_RECORD_DIR"], "claude-" + tag + ".json")
    with open(out + ".tmp", "w") as f:
        json.dump(record, f)
    os.rename(out + ".tmp", out)

reply = os.environ.get("FAKE_REPLY", "done here")
turn = [
    ("UserPromptSubmit", {"prompt": "hello"}),
    ("Stop", {"stop_hook_active": False, "last_assistant_message": reply}),
]
record["outputs"] = run_round(session, [("SessionStart", {"source": "startup"})] + turn)
write_record(os.environ["OB_TAG"], record)
def wait_for(path):
    deadline = time.time() + 120
    while not os.path.exists(path) and time.time() < deadline:
        time.sleep(0.05)

# The rounds below wait for the test's go when it names one.
round_go = os.environ.get("FAKE_ROUND_GO")
# `/clear`: the same Claude process ends the session and starts another.
cleared = os.environ.get("FAKE_CLEAR_SESSION_ID")
if cleared:
    if round_go:
        wait_for(round_go)
    run_round(session, [("SessionEnd", {"reason": "clear"})])
    outputs = run_round(cleared, [("SessionStart", {"source": "clear"})] + turn)
    write_record(os.environ["OB_TAG"] + "-clear", {"session_id": cleared, "outputs": outputs})
# An in-process `/resume`: the same Claude process ends its session and takes
# another (Claude Code 2.1.319 sends SessionEnd with reason "resume" first).
resumed = os.environ.get("FAKE_RESUME_SESSION_ID")
if resumed:
    if round_go:
        wait_for(round_go)
    run_round(session, [("SessionEnd", {"reason": "resume"})])
    outputs = run_round(resumed, [("SessionStart", {"source": "resume"})] + turn)
    write_record(os.environ["OB_TAG"] + "-resume", {"session_id": resumed, "outputs": outputs})
# A tool call that starts another Claude (`claude -p`) once the test says go:
# it inherits the plugin folder and this Claude's tool environment.
go = os.environ.get("FAKE_NESTED_GO")
if go:
    wait_for(go)
    nested = dict(os.environ, OB_TAG=os.environ["OB_TAG"] + "-nested",
                  FAKE_SESSION_ID=os.environ["FAKE_NESTED_SESSION_ID"], FAKE_REPLY="nested reply",
                  FAKE_EXIT="1", CLAUDECODE="1", CLAUDE_PID=str(os.getpid()),
                  CLAUDE_CODE_SESSION_ID=session)
    del nested["FAKE_NESTED_GO"]
    # A Bash tool command sources the env file first; a Claude that a hook,
    # an MCP server or a teammate starts does not.
    script = '[ -f "$1" ] && . "$1"; exec "$2" -p hi'
    if nested.pop("FAKE_NESTED_NO_ENV_FILE", None):
        script = 'exec "$2" -p hi'
    subprocess.run(["/bin/sh", "-c", script, "sh", env_file,
                    os.path.realpath(sys.argv[0])], env=nested, timeout=120)
if os.environ.get("FAKE_EXIT"):
    sys.exit(0)
time.sleep(600)
"#;

fn unique_root() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmux-al-{}-{stamp}-{n}", std::process::id()));
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

struct Daemon {
    child: Child,
    socket: PathBuf,
    terminals: Vec<(String, String)>,
    surfaces: Vec<(String, u64)>,
}

impl Daemon {
    fn start(root: &Path, exe: &Path, session: &str, home: &Path, data: &Path, path: &str) -> Self {
        let dir = root.join(format!("daemon-{session}"));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("s.sock");
        let mut command = Command::new(exe);
        command
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("HOME", home)
            .env("XDG_DATA_HOME", data)
            .env("PATH", path)
            .env("SHELL", "/bin/sh")
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .env_remove("CMUX_TUI_HOOK")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_TUI_AGENT_SHIMS")
            .env_remove("CMUX_TUI_CLAUDE_WRAPPER_ACTIVE")
            .env_remove("CMUX_TUI_CLAUDE_HOOKS_DISABLED")
            .env_remove("CLAUDE_CODE_PLUGIN_DIRS")
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("SR2_CLAUDE2_HOOK_SOCKET")
            .env_remove("TMUX")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_BUNDLED_CLI_PATH")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        private_state::use_private_state(&mut command, &dir);
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "{session} never served {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, terminals: Vec::new(), surfaces: Vec::new() }
    }

    fn request(&self, value: serde_json::Value) -> serde_json::Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone().unwrap();
        writeln!(writer, "{value}").unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "request failed: {response}");
        response["data"].clone()
    }

    /// Runs `script` (sh) in a new terminal named `tag`; returns its public
    /// terminal id (`term_<id>`, the form the CLI takes).
    fn run(&mut self, tag: &str, script: &str) -> String {
        let created = self.request(serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", script],
            "new_workspace": true, "name": tag, "cols": 100, "rows": 20,
        }));
        let terminal = created["terminal_id"].as_str().unwrap().to_owned();
        let incarnation = created["terminal_incarnation"].as_str().unwrap().to_owned();
        self.terminals.push((terminal, incarnation));
        let surface = created["surface"].as_u64().unwrap();
        self.surfaces.push((tag.to_owned(), surface));
        // `run` answers with the host's terminal id; the CLI and the agent
        // roster use the public one, which the workspace tree gives.
        let tree = self.request(serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
        public_terminal(&tree, surface)
            .unwrap_or_else(|| panic!("surface {surface} has no public terminal id: {tree}"))
    }

    /// The screen of the terminal named `tag`, for a failure message.
    fn screen(&self, tag: &str) -> String {
        let Some(&(_, surface)) = self.surfaces.iter().find(|(name, _)| name == tag) else {
            return String::from("(no surface)");
        };
        let Ok(stream) = UnixStream::connect(&self.socket) else { return String::new() };
        let mut writer = stream.try_clone().unwrap();
        let read = serde_json::json!({"id": 2, "cmd": "read-screen", "surface": surface});
        let _ = writeln!(writer, "{read}");
        let mut line = String::new();
        let _ = BufReader::new(stream).read_line(&mut line);
        serde_json::from_str::<serde_json::Value>(&line)
            .ok()
            .and_then(|response| response["data"]["text"].as_str().map(str::to_owned))
            .unwrap_or(line)
    }

    /// The `agent list` row of `terminal`, if the session has one.
    fn agent_row(&self, exe: &Path, env: &[(&str, &Path)], terminal: &str) -> serde_json::Value {
        let mut command = Command::new(exe);
        command
            .args(["--json", "--socket"])
            .arg(&self.socket)
            .args(["agent", "list"])
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID");
        for (key, value) in env {
            command.env(key, value);
        }
        let output = command.output().unwrap();
        if !output.status.success() {
            return serde_json::Value::String(format!(
                "agent list failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        let listed: serde_json::Value =
            serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);
        find_row(&listed, terminal).cloned().unwrap_or_else(|| {
            serde_json::Value::String(format!(
                "no row for {terminal} in the session's agent list: {listed}"
            ))
        })
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        for (terminal, incarnation) in std::mem::take(&mut self.terminals) {
            let _ = UnixStream::connect(&self.socket).map(|mut stream| {
                let close = serde_json::json!({"id": 9, "cmd": "close-terminal",
                    "terminal_id": terminal, "terminal_incarnation": incarnation});
                let _ = writeln!(stream, "{close}");
                let _ = BufReader::new(stream).read_line(&mut String::new());
            });
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The public terminal id (`terminal_resource_id`) of the tab of `surface`
/// in a workspace tree.
fn public_terminal(value: &serde_json::Value, surface: u64) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            if map.get("surface").and_then(serde_json::Value::as_u64) == Some(surface)
                && let Some(id) =
                    map.get("terminal_resource_id").and_then(serde_json::Value::as_str)
            {
                return Some(id.to_owned());
            }
            map.values().find_map(|child| public_terminal(child, surface))
        }
        serde_json::Value::Array(items) => {
            items.iter().find_map(|child| public_terminal(child, surface))
        }
        _ => None,
    }
}

/// The first object below `value` whose `terminal_id` is `terminal`.
fn find_row<'a>(value: &'a serde_json::Value, terminal: &str) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            if map.get("terminal_id").and_then(serde_json::Value::as_str) == Some(terminal) {
                return Some(value);
            }
            map.values().find_map(|child| find_row(child, terminal))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find_row(child, terminal)),
        _ => None,
    }
}

/// What the stand-in Claude recorded in the terminal named `tag`.
fn launch_record(root: &Path, daemon: &Daemon, tag: &str) -> serde_json::Value {
    let path = root.join(format!("claude-{tag}.json"));
    let deadline = Instant::now() + Duration::from_secs(60);
    while !path.exists() {
        assert!(Instant::now() < deadline, "claude never ran in {tag}: {}", daemon.screen(tag));
        std::thread::sleep(Duration::from_millis(50));
    }
    serde_json::from_slice(&fs::read(&path).unwrap()).unwrap()
}

/// How many `SessionStart` outputs carry `needle`.
fn session_start_outputs_with(record: &serde_json::Value, needle: &str) -> usize {
    record["outputs"]["SessionStart"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .filter(|output| output.contains(needle))
        .count()
}

#[test]
fn any_launcher_claude_reports_to_the_pane_session() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let realbin = root.join("realbin");
    for dir in [&home, &data, &realbin] {
        fs::create_dir_all(dir).unwrap();
    }
    let claude = realbin.join("claude");
    write_executable(&claude, FAKE_CLAUDE);

    // A launcher like `sr2 claude`: its own config directory, its own
    // `--settings` with a hook of its own, its supervisor socket variable,
    // and Claude by full path.
    let launcher_log = root.join("launcher-hook.log");
    let launcher_settings = root.join("launcher-settings.json");
    fs::write(
        &launcher_settings,
        serde_json::json!({"hooks": {"Stop": [{"hooks": [{"type": "command",
            "command": format!("echo launcher-stop >> '{}'; echo {{}}", launcher_log.display())}]}]}})
        .to_string(),
    )
    .unwrap();
    let launcher = root.join("fake-sr2");
    write_executable(
        &launcher,
        &format!(
            "#!/bin/sh\n[ \"$1\" = claude ] && shift\n\
             CLAUDE_CONFIG_DIR='{config}'\nSR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock\n\
             export CLAUDE_CONFIG_DIR SR2_CLAUDE2_HOOK_SOCKET\n\
             exec '{claude}' --settings '{settings}' \"$@\"\n",
            config = root.join("config-launcher").display(),
            claude = claude.display(),
            settings = launcher_settings.display(),
        ),
    );

    // `agent hook install claude` into its own config directory, for the
    // launch that also has the installed copy of the hooks.
    let installed_config = root.join("config-installed");
    fs::create_dir_all(&installed_config).unwrap();
    // The daemon's build: this binary alone in a folder, as an install
    // without the standalone helper beside it (its hooks run the build's
    // own hook launcher).
    let exe = env!("CARGO_BIN_EXE_cmux-tui");
    let build = root.join("build");
    fs::create_dir_all(&build).unwrap();
    let daemon_exe = build.join("cmux-tui");
    if fs::hard_link(exe, &daemon_exe).is_err() {
        fs::copy(exe, &daemon_exe).unwrap();
    }
    let install = Command::new(&daemon_exe)
        .args(["agent", "hook", "install", "claude"])
        .env("HOME", &home)
        .env("XDG_DATA_HOME", &data)
        .env("CLAUDE_CONFIG_DIR", &installed_config)
        .env("LC_ALL", "C")
        .output()
        .unwrap();
    assert!(install.status.success(), "{}", String::from_utf8_lossy(&install.stderr));
    assert!(
        fs::read_to_string(installed_config.join("settings.json"))
            .is_ok_and(|text| text.contains("cmux-tui-journal-hook")),
        "the install wrote no hooks"
    );

    let path = format!("{}:/usr/bin:/bin", realbin.display());
    let mut daemon = Daemon::start(&root, &daemon_exe, "al", &home, &data, &path);

    let common = |tag: &str, n: u32| {
        format!(
            "OB_TAG='{tag}' FAKE_RECORD_DIR='{}' FAKE_SESSION_ID=\
             '00000000-0000-4000-8000-00000000000{n}'; export OB_TAG FAKE_RECORD_DIR \
             FAKE_SESSION_ID; ",
            root.display()
        )
    };
    let launches = [
        // Claude by its full path, under its own config directory.
        (
            "full-path",
            format!(
                "{}CLAUDE_CONFIG_DIR='{}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock \
                 '{}'; sleep 600",
                common("full-path", 1),
                root.join("config-full").display(),
                claude.display()
            ),
        ),
        // A launcher that runs Claude by full path with its own settings.
        (
            "launcher",
            format!("{}'{}' claude; sleep 600", common("launcher", 2), launcher.display()),
        ),
        // Full path again, with the hooks also installed in its config.
        (
            "installed",
            format!(
                "{}CLAUDE_CONFIG_DIR='{}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock \
                 '{}'; sleep 600",
                common("installed", 3),
                installed_config.display(),
                claude.display()
            ),
        ),
        // Plain `claude` through the shim on PATH.
        (
            "shim",
            format!(
                "{}CLAUDE_CONFIG_DIR='{}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock \
                 claude; sleep 600",
                common("shim", 4),
                root.join("config-shim").display()
            ),
        ),
    ];
    let mut terminals = Vec::new();
    for (n, (tag, script)) in launches.iter().enumerate() {
        fs::create_dir_all(root.join(format!("config-{tag}"))).ok();
        let terminal = daemon.run(tag, script);
        terminals.push((*tag, terminal, n + 1));
    }

    let cli_env = [("HOME", home.as_path()), ("XDG_DATA_HOME", data.as_path())];
    for (tag, terminal, n) in &terminals {
        let record = launch_record(&root, &daemon, tag);
        // The session's place in the model's context, exactly once. Its guide line names the
        // pane's own cmux (`"$CMUX_TUI_CLI" skill show`, W5-Q #39040), so match its opening.
        assert_eq!(
            session_start_outputs_with(&record, "cmux: you run in a cmux terminal"),
            1,
            "{tag}: SessionStart must add the cmux session context once: {record}"
        );
        // The startup line comes from the hook helper's SessionStart: one
        // copy of the hooks ran, not zero and not two.
        assert_eq!(
            session_start_outputs_with(&record, "systemMessage"),
            1,
            "{tag}: exactly one copy of the cmux hooks must run: {record}"
        );
        let session = format!("00000000-0000-4000-8000-00000000000{n}");
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let row = daemon.agent_row(&daemon_exe, &cli_env, terminal);
            if row["source"] == "hook" && row["extra"]["agent_session_id"] == session.as_str() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "{tag}: the session never got the hook events (source hook, session {session}): \
                 {row}\n{}",
                daemon.screen(tag)
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    // The launcher's own hook still runs beside cmux's.
    assert_eq!(
        fs::read_to_string(&launcher_log).unwrap_or_default().lines().count(),
        1,
        "the launcher's own Stop hook must run once"
    );
    // A documented limit (docs/agent-hooks.md): with the hooks installed but
    // `--setting-sources` leaving the user settings out, the installed copy
    // does not load and the plugin copy stands down beside it. The terminal
    // then shows no hook state: never two copies, never another session's.
    let limited = daemon.run(
        "no-user-settings",
        &format!(
            "{}CLAUDE_CONFIG_DIR='{}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock \
             '{}' --setting-sources project,local; sleep 600",
            common("no-user-settings", 5),
            installed_config.display(),
            claude.display()
        ),
    );
    let record = launch_record(&root, &daemon, "no-user-settings");
    assert_eq!(
        session_start_outputs_with(&record, "systemMessage"),
        0,
        "no-user-settings: the plugin copy must stand down: {record}"
    );
    // The guard is not empty: a cmux copy of each hook ran (and stood down).
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        let ran = record["outputs"][event].as_array().map_or(0, Vec::len);
        assert!(ran >= 1, "no-user-settings: no copy of the {event} hook ran: {record}");
    }
    let row = daemon.agent_row(&daemon_exe, &cli_env, &limited);
    assert!(
        row["source"] != "hook"
            || row["extra"]["agent_session_id"] == "00000000-0000-4000-8000-000000000005",
        "no-user-settings: a wrong hook state: {row}"
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}

/// Runs the cmux-tui CLI against `daemon`; its exit status and output.
fn cli(daemon: &Daemon, exe: &Path, env: &[(&str, &Path)], args: &[&str]) -> (bool, String) {
    let mut command = Command::new(exe);
    command
        .args(["--json", "--socket"])
        .arg(&daemon.socket)
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID");
    for (key, value) in env {
        command.env(key, value);
    }
    let output = command.output().unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    (output.status.success(), text)
}

#[test]
fn any_launcher_nested_claude_leaves_the_pane_session_and_its_messages_to_the_outer_claude() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let realbin = root.join("realbin");
    let build = root.join("build");
    let empty_config = root.join("config-empty");
    let installed_config = root.join("config-installed");
    for dir in [&home, &data, &realbin, &build, &empty_config, &installed_config] {
        fs::create_dir_all(dir).unwrap();
    }
    let claude = realbin.join("claude");
    write_executable(&claude, FAKE_CLAUDE);
    let daemon_exe = build.join("cmux-tui");
    if fs::hard_link(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).is_err() {
        fs::copy(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).unwrap();
    }
    // `agent hook install claude` in one config directory: its copy of the
    // hooks, not the plugin's, then reports for the Claude and the nested one.
    let install = Command::new(&daemon_exe)
        .args(["agent", "hook", "install", "claude"])
        .env("HOME", &home)
        .env("XDG_DATA_HOME", &data)
        .env("CLAUDE_CONFIG_DIR", &installed_config)
        .env("LC_ALL", "C")
        .output()
        .unwrap();
    assert!(install.status.success(), "{}", String::from_utf8_lossy(&install.stderr));
    let path = format!("{}:/usr/bin:/bin", realbin.display());
    let mut daemon = Daemon::start(&root, &daemon_exe, "nest", &home, &data, &path);
    let cli_env = [("HOME", home.as_path()), ("XDG_DATA_HOME", data.as_path())];

    // Each terminal runs a Claude; once told, a tool call of it starts another
    // Claude (`claude -p`), which inherits the pane's environment and sources
    // the outer Claude's env file. The plugin reports for the first; the
    // installed hooks for the second; the shim's own hooks for the third. The
    // fourth starts its Claude the way a hook, an MCP server or a teammate
    // would: without the env file, so with no claim in its environment.
    let cases = [
        ("plain", format!("'{}'", claude.display()), &empty_config, 2),
        ("installed", format!("'{}'", claude.display()), &installed_config, 3),
        ("shim", "claude".to_owned(), &installed_config, 4),
        ("teammate", format!("FAKE_NESTED_NO_ENV_FILE=1 '{}'", claude.display()), &empty_config, 5),
    ];
    let mut terminals = Vec::new();
    for (tag, command, config, n) in &cases {
        let outer = format!("00000000-0000-4000-8000-0000000000{n}1");
        let script = format!(
            "OB_TAG={tag} FAKE_RECORD_DIR='{root}' FAKE_SESSION_ID={outer} \
             FAKE_NESTED_SESSION_ID=00000000-0000-4000-8000-0000000000{n}2 \
             FAKE_NESTED_GO='{root}/go-{tag}' FAKE_REPLY='outer reply' \
             CLAUDE_CONFIG_DIR='{config}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock; \
             export OB_TAG FAKE_RECORD_DIR FAKE_SESSION_ID FAKE_NESTED_SESSION_ID \
             FAKE_NESTED_GO FAKE_REPLY CLAUDE_CONFIG_DIR SR2_CLAUDE2_HOOK_SOCKET; \
             {command}; sleep 600",
            root = root.display(),
            config = config.display(),
        );
        terminals.push((*tag, daemon.run(tag, &script), outer));
    }
    for (tag, terminal, outer) in &terminals {
        launch_record(&root, &daemon, tag);
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let row = daemon.agent_row(&daemon_exe, &cli_env, terminal);
            if row["source"] == "hook" && row["extra"]["agent_session_id"] == outer.as_str() {
                break;
            }
            assert!(Instant::now() < deadline, "{tag}: the outer Claude never reported: {row}");
            std::thread::sleep(Duration::from_millis(100));
        }
        // A message for the pane's agent waits for the outer Claude's next prompt.
        let note = format!("note for the {tag} pane agent 7f3a");
        let (sent, text) =
            cli(&daemon, &daemon_exe, &cli_env, &["agent", "message", terminal, &note]);
        assert!(sent, "{tag}: agent message failed: {text}");
        fs::write(root.join(format!("go-{tag}")), b"go").unwrap();
    }
    for (tag, terminal, outer) in &terminals {
        let nested = launch_record(&root, &daemon, &format!("{tag}-nested"));
        let note = format!("note for the {tag} pane agent 7f3a");
        // The nested Claude neither takes the message nor reports as the pane's agent.
        assert!(
            !nested["outputs"].to_string().contains(&note),
            "{tag}: the nested Claude took the pane agent's message: {nested}"
        );
        assert_eq!(
            session_start_outputs_with(&nested, "systemMessage"),
            0,
            "{tag}: the nested Claude ran the pane's hooks: {nested}"
        );
        assert_eq!(
            session_start_outputs_with(&nested, "cmux: you run in a cmux terminal"),
            0,
            "{tag}: the nested Claude was told it runs in the pane's terminal: {nested}"
        );
        let (listed, inbox) =
            cli(&daemon, &daemon_exe, &cli_env, &["agent", "inbox", terminal, "--state", "queued"]);
        assert!(listed && inbox.contains(&note), "{tag}: the message is no longer queued: {inbox}");
        let row = daemon.agent_row(&daemon_exe, &cli_env, terminal);
        assert_eq!(row["extra"]["agent_session_id"], outer.as_str(), "{tag}: {row}");
        // Nor does its reply become the pane's last reply.
        assert_eq!(
            row["extra"]["last_reply"], "outer reply",
            "{tag}: the nested Claude's reply took the pane agent's place: {row}"
        );
    }
    // What the check adds to a Claude hook that hands over messages, a banner
    // or context: one `agent.list` read of its terminal.
    let (_, terminal, _) = &terminals[0];
    let mut took: Vec<Duration> =
        (0..40).map(|_| agent_list_round_trip(&daemon, terminal)).collect();
    took.sort();
    let at = |share: usize| took[(took.len() * share / 100).min(took.len() - 1)];
    let _ = writeln!(
        std::io::stderr(),
        "w5n3 hook roster read (agent.list, {} reads): p50 {:?} p95 {:?}",
        took.len(),
        at(50),
        at(95)
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}

/// One `agent.list` read of `terminal`, as the hook makes it: its time.
fn agent_list_round_trip(daemon: &Daemon, terminal: &str) -> Duration {
    let started = Instant::now();
    let stream = UnixStream::connect(&daemon.socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "w5n3-roster-read",
        "operation": "agent.list",
        "params": {"machine": "current", "session": "current", "terminal_id": terminal},
    });
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "agent.list failed: {response}");
    started.elapsed()
}

#[test]
fn any_launcher_w5n3_clear_keeps_reporting_when_hooks_see_the_env_file() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let realbin = root.join("realbin");
    let build = root.join("build");
    let config = root.join("config-empty");
    for dir in [&home, &data, &realbin, &build, &config] {
        fs::create_dir_all(dir).unwrap();
    }
    let claude = realbin.join("claude");
    write_executable(&claude, FAKE_CLAUDE);
    let daemon_exe = build.join("cmux-tui");
    if fs::hard_link(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).is_err() {
        fs::copy(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).unwrap();
    }
    let path = format!("{}:/usr/bin:/bin", realbin.display());
    let mut daemon = Daemon::start(&root, &daemon_exe, "clear", &home, &data, &path);
    let cli_env = [("HOME", home.as_path()), ("XDG_DATA_HOME", data.as_path())];
    // Claude Code 2.1.319 does not source the env file for its hooks. Were a
    // later version to do so, the hooks of the claiming Claude would read its
    // own claim; after `/clear` (a new session in the same process) they must
    // still report.
    let first = "00000000-0000-4000-8000-000000000061";
    let cleared = "00000000-0000-4000-8000-000000000062";
    let script = format!(
        "OB_TAG=clear FAKE_RECORD_DIR='{root}' FAKE_SESSION_ID={first} \
         FAKE_CLEAR_SESSION_ID={cleared} FAKE_HOOKS_SOURCE_ENV_FILE=1 \
         CLAUDE_CONFIG_DIR='{config}' SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock; \
         export OB_TAG FAKE_RECORD_DIR FAKE_SESSION_ID FAKE_CLEAR_SESSION_ID \
         FAKE_HOOKS_SOURCE_ENV_FILE CLAUDE_CONFIG_DIR SR2_CLAUDE2_HOOK_SOCKET; \
         '{claude}'; sleep 600",
        root = root.display(),
        config = config.display(),
        claude = claude.display(),
    );
    let terminal = daemon.run("clear", &script);
    launch_record(&root, &daemon, "clear-clear");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let row = daemon.agent_row(&daemon_exe, &cli_env, &terminal);
        if row["source"] == "hook" && row["extra"]["agent_session_id"] == cleared {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "after /clear the Claude's new session never reported: {row}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn any_launcher_w5n3_the_pane_agent_keeps_its_messages_after_clear_and_resume() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let realbin = root.join("realbin");
    let build = root.join("build");
    let config = root.join("config-empty");
    for dir in [&home, &data, &realbin, &build, &config] {
        fs::create_dir_all(dir).unwrap();
    }
    let claude = realbin.join("claude");
    write_executable(&claude, FAKE_CLAUDE);
    let daemon_exe = build.join("cmux-tui");
    if fs::hard_link(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).is_err() {
        fs::copy(env!("CARGO_BIN_EXE_cmux-tui"), &daemon_exe).unwrap();
    }
    let path = format!("{}:/usr/bin:/bin", realbin.display());
    let mut daemon = Daemon::start(&root, &daemon_exe, "again", &home, &data, &path);
    let cli_env = [("HOME", home.as_path()), ("XDG_DATA_HOME", data.as_path())];
    // The pane's agent goes on in a new session of the same process: after
    // `/clear` or an in-process `/resume` (each ends the old session first).
    // The messages for the pane are its, and the row follows it.
    let cases = [
        ("clear", "FAKE_CLEAR_SESSION_ID", "00000000-0000-4000-8000-000000000072", 7),
        ("resume", "FAKE_RESUME_SESSION_ID", "00000000-0000-4000-8000-000000000082", 8),
    ];
    let mut terminals = Vec::new();
    for (tag, variable, next, n) in &cases {
        let first = format!("00000000-0000-4000-8000-0000000000{n}1");
        let script = format!(
            "OB_TAG={tag} FAKE_RECORD_DIR='{root}' FAKE_SESSION_ID={first} {variable}={next} \
             FAKE_ROUND_GO='{root}/go-{tag}' CLAUDE_CONFIG_DIR='{config}' \
             SR2_CLAUDE2_HOOK_SOCKET=/nonexistent/sr2.sock; \
             export OB_TAG FAKE_RECORD_DIR FAKE_SESSION_ID {variable} FAKE_ROUND_GO \
             CLAUDE_CONFIG_DIR SR2_CLAUDE2_HOOK_SOCKET; '{claude}'; sleep 600",
            root = root.display(),
            config = config.display(),
            claude = claude.display(),
        );
        terminals.push((*tag, daemon.run(tag, &script), first));
    }
    for (tag, terminal, first) in &terminals {
        launch_record(&root, &daemon, tag);
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let row = daemon.agent_row(&daemon_exe, &cli_env, terminal);
            if row["source"] == "hook" && row["extra"]["agent_session_id"] == first.as_str() {
                break;
            }
            assert!(Instant::now() < deadline, "{tag}: the first session never reported: {row}");
            std::thread::sleep(Duration::from_millis(100));
        }
        let note = format!("note for the {tag} pane agent 41c9");
        let (sent, text) =
            cli(&daemon, &daemon_exe, &cli_env, &["agent", "message", terminal, &note]);
        assert!(sent, "{tag}: agent message failed: {text}");
        fs::write(root.join(format!("go-{tag}")), b"go").unwrap();
    }
    for ((tag, terminal, _), (_, _, session, _)) in terminals.iter().zip(&cases) {
        let next = launch_record(&root, &daemon, &format!("{tag}-{tag}"));
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let row = daemon.agent_row(&daemon_exe, &cli_env, terminal);
            if row["source"] == "hook" && row["extra"]["agent_session_id"] == *session {
                break;
            }
            assert!(Instant::now() < deadline, "{tag}: the row did not follow the agent: {row}");
            std::thread::sleep(Duration::from_millis(100));
        }
        let note = format!("note for the {tag} pane agent 41c9");
        let prompt = next["outputs"]["UserPromptSubmit"].to_string();
        assert!(
            prompt.contains(&note),
            "{tag}: the pane agent's next session did not get its message: {next}"
        );
    }
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}
