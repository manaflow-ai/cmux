//! Claude Code in a cmux-tui pane reports to the pane's session however it
//! was started: through the `claude` shim on PATH, by its full path, or by a
//! launcher (`sr2 claude`, a version-manager shim, an alias) that runs it by
//! full path with its own `CLAUDE_CONFIG_DIR` and its own `--settings`.
//!
//! The `claude` here is a stand-in for Claude Code that loads hooks the way
//! Claude Code 2.1 does: the user settings of its config directory, the last
//! `--settings` file, and every plugin folder named in
//! `CLAUDE_CODE_PLUGIN_DIRS` (`hooks/hooks.json`, run with
//! `CLAUDE_PLUGIN_ROOT`). Identical commands from settings files run once;
//! plugin hooks are never merged with them. It then runs `SessionStart`,
//! `UserPromptSubmit` and `Stop` and records the hook output. The hook
//! helper is the real one, so the daemon's agent roster and journal show
//! whether the events arrived, and how many times.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Claude Code's hook loading, reduced to what the test needs.
const FAKE_CLAUDE: &str = r#"#!/usr/bin/env python3
import json, os, subprocess, sys, time

args = sys.argv[1:]
settings_file = None
i = 0
while i < len(args):
    if args[i] == "--settings" and i + 1 < len(args):
        settings_file = args[i + 1]
        i += 2
        continue
    if args[i].startswith("--settings="):
        settings_file = args[i][len("--settings="):]
    i += 1

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")
settings_sources = [load(os.path.join(config, "settings.json"))]
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
payloads = [
    ("SessionStart", {"source": "startup"}),
    ("UserPromptSubmit", {"prompt": "hello"}),
    ("Stop", {"stop_hook_active": False, "last_assistant_message": "done here"}),
]
for event, extra in payloads:
    payload = {"session_id": session, "transcript_path": "/dev/null", "cwd": os.getcwd(),
               "hook_event_name": event}
    payload.update(extra)
    outputs = []
    for command, root in commands(event):
        env = dict(os.environ)
        if root:
            env["CLAUDE_PLUGIN_ROOT"] = root
        done = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(payload).encode(),
                              env=env, capture_output=True, timeout=60)
        outputs.append(done.stdout.decode(errors="replace"))
    record["outputs"][event] = outputs
out = os.path.join(os.environ["FAKE_RECORD_DIR"], "claude-" + os.environ["OB_TAG"] + ".json")
with open(out + ".tmp", "w") as f:
    json.dump(record, f)
os.rename(out + ".tmp", out)
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
            .env_remove("CMUX_TUI_HOOK")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_TUI_AGENT_SHIMS")
            .env_remove("CMUX_TUI_CLAUDE_WRAPPER_ACTIVE")
            .env_remove("CMUX_TUI_CLAUDE_HOOKS_DISABLED")
            .env_remove("CLAUDE_CODE_PLUGIN_DIRS")
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("TMUX")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_BUNDLED_CLI_PATH")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
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
    /// terminal id (`term_<id>`, the form the CLI takes) and the host's id.
    fn run(&mut self, tag: &str, script: &str) -> (String, String) {
        let created = self.request(serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", script],
            "new_workspace": true, "name": tag, "cols": 100, "rows": 20,
        }));
        let terminal = created["terminal_id"].as_str().unwrap().to_owned();
        let incarnation = created["terminal_incarnation"].as_str().unwrap().to_owned();
        self.terminals.push((terminal.clone(), incarnation));
        let surface = created["surface"].as_u64().unwrap();
        self.surfaces.push((tag.to_owned(), surface));
        // `run` answers with the host's terminal id; the CLI and the agent
        // roster use the public one, which the workspace tree gives.
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let tree = self.request(serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
            if let Some(public) = public_terminal(&tree, surface) {
                return (public, terminal);
            }
            assert!(
                Instant::now() < deadline,
                "surface {surface} has no public terminal id: {tree}"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The `native_event` of every Claude hook record in the session journal
    /// whose terminal subject is one of `ids`, oldest first.
    fn claude_hook_events(&self, ids: &[&str]) -> Vec<String> {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut writer = stream.try_clone().unwrap();
        let request = serde_json::json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": "any-launcher-journal-read",
            "operation": "session.journal.subscribe",
            "params": {
                "machine": "current",
                "session": "current",
                "stream_id": "stream_22222222222242228222222222222222",
                "start": "beginning",
                "follow": false,
                "filter": {"kinds": ["agent.*"], "max_sensitivity": "sensitive"},
            },
        });
        writeln!(writer, "{request}").unwrap();
        let mut reader = BufReader::new(stream);
        let mut events = Vec::new();
        let mut line = String::new();
        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                break;
            }
            let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
            match envelope["type"].as_str() {
                Some("response") => {
                    assert_eq!(envelope["ok"], true, "journal read failed: {envelope}");
                }
                Some("stream_item") => {
                    let record = &envelope["item"];
                    let mine = record["subjects"].as_array().into_iter().flatten().any(|subject| {
                        subject["kind"] == "terminal"
                            && subject["id"].as_str().is_some_and(|id| ids.contains(&id))
                    });
                    if mine && record["payload"]["adapter"]["id"] == "claude" {
                        let event = record["payload"]["native_event"].as_str().unwrap_or("");
                        events.push(event.to_owned());
                    }
                }
                _ => break,
            }
        }
        events
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
    // `--settings` with a hook of its own, and Claude by full path.
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
             CLAUDE_CONFIG_DIR='{config}'\nexport CLAUDE_CONFIG_DIR\n\
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
                "{}CLAUDE_CONFIG_DIR='{}' '{}'; sleep 600",
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
                "{}CLAUDE_CONFIG_DIR='{}' '{}'; sleep 600",
                common("installed", 3),
                installed_config.display(),
                claude.display()
            ),
        ),
        // Plain `claude` through the shim on PATH.
        (
            "shim",
            format!(
                "{}CLAUDE_CONFIG_DIR='{}' claude; sleep 600",
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
    for (tag, (terminal, host_terminal), n) in &terminals {
        let record = launch_record(&root, &daemon, tag);
        // The session's place in the model's context, exactly once.
        assert_eq!(
            session_start_outputs_with(&record, "you run in a cmux terminal"),
            1,
            "{tag}: SessionStart must add the cmux session context once: {record}"
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
        // One copy of the cmux hooks ran, not zero and not two: the journal
        // holds each event once. Stop is the last one Claude ran; the record
        // above was written after every hook command returned.
        let ids = [terminal.as_str(), host_terminal.as_str()];
        let deadline = Instant::now() + Duration::from_secs(30);
        while !daemon.claude_hook_events(&ids).iter().any(|event| event == "Stop") {
            assert!(
                Instant::now() < deadline,
                "{tag}: Stop never reached the journal: {:?}",
                daemon.claude_hook_events(&ids)
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        std::thread::sleep(Duration::from_millis(500));
        let events = daemon.claude_hook_events(&ids);
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            assert_eq!(
                events.iter().filter(|seen| *seen == event).count(),
                1,
                "{tag}: exactly one copy of the cmux hooks must run ({event}): {events:?}"
            );
        }
    }
    // The launcher's own hook still runs beside cmux's.
    assert_eq!(
        fs::read_to_string(&launcher_log).unwrap_or_default().lines().count(),
        1,
        "the launcher's own Stop hook must run once"
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}
