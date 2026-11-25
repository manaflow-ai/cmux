//! `cmux agents doctor` through the CLI entry with a fake HOME, PATH and app
//! socket: the readiness rows an agent reads in `--json`, the human table,
//! and that the report never writes the configs it reads.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const ACCESSIBILITY_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

struct World {
    dir: PathBuf,
    home: PathBuf,
    bin: PathBuf,
    work: PathBuf,
    /// The working directory of each run; `work` when `None`.
    cwd: Option<PathBuf>,
    /// Environment set after the defaults (HOME, CODEX_HOME, ...).
    env: Vec<(&'static str, PathBuf)>,
}

impl World {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = Path::new("/tmp")
            .join(format!("cmux-agents-doctor-{name}-{}-{stamp}-{n}", std::process::id()));
        let world = Self {
            home: dir.join("home"),
            bin: dir.join("bin"),
            work: dir.join("work"),
            cwd: None,
            env: Vec::new(),
            dir,
        };
        for path in [&world.home, &world.bin, &world.work] {
            std::fs::create_dir_all(path).unwrap();
        }
        world
    }

    /// An executable named `name` on the fake PATH that leaves `marker(name)`
    /// behind if anything runs it. A short-lived `sh` writes it so no sibling
    /// test's fork inherits a write descriptor (ETXTBSY).
    fn harness(&self, name: &str) -> PathBuf {
        let path = self.bin.join(name);
        let mut child = Command::new("/bin/sh")
            .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
            .arg(&path)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"#!/bin/sh\ntouch \"$0.ran\"\necho 1.0.0\n")
            .unwrap();
        assert!(child.wait().unwrap().success());
        path
    }

    /// The file the fake harness `name` touches when it runs.
    fn marker(&self, name: &str) -> PathBuf {
        self.bin.join(format!("{name}.ran"))
    }

    fn run(&self, app_socket: &Path, args: &[&str]) -> Output {
        self.run_in(app_socket, "C", args)
    }

    fn run_in(&self, app_socket: &Path, locale: &str, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--app-socket")
            .arg(app_socket)
            .args(args)
            .current_dir(self.cwd.as_ref().unwrap_or(&self.work))
            .env("HOME", &self.home)
            .env("PATH", &self.bin)
            .env("LC_ALL", locale)
            .env_remove("LANG")
            .env_remove("LC_MESSAGES")
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("CODEX_HOME")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .envs(self.env.iter().map(|(key, value)| (*key, value)))
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }
}

impl World {
    /// A real `cmux mcp serve` in the same environment as `run_in` (the
    /// server switched on by a settings file outside HOME): initializes,
    /// sends each `tools/call` and returns their results in order.
    fn mcp(&self, app_socket: &Path, calls: &[Value]) -> Vec<Value> {
        let config = self.dir.join("cmux-next.json");
        std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--app-socket")
            .arg(app_socket)
            .args(["mcp", "serve"])
            .current_dir(self.cwd.as_ref().unwrap_or(&self.work))
            .env("HOME", &self.home)
            .env("PATH", &self.bin)
            .env("LC_ALL", "C")
            .env("CMUX_NEXT_CONFIG_FILE", &config)
            .env_remove("LANG")
            .env_remove("LC_MESSAGES")
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("CODEX_HOME")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .envs(self.env.iter().map(|(key, value)| (*key, value)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let mut messages = vec![
            json!({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "agents-doctor-test", "version": "1"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        ];
        for (index, arguments) in calls.iter().enumerate() {
            messages.push(json!({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                "params": {"name": "agents_doctor", "arguments": arguments}}));
        }
        for message in messages {
            writeln!(stdin, "{message}").unwrap();
        }
        drop(stdin);
        let output = child.wait_with_output().unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let answers: Vec<Value> = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect();
        (0..calls.len())
            .map(|index| {
                let answer = answers
                    .iter()
                    .find(|answer| answer["id"] == index)
                    .unwrap_or_else(|| panic!("no answer to call {index}; stderr: {stderr}"));
                assert!(answer.get("error").is_none(), "{answer}");
                answer["result"].clone()
            })
            .collect()
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A fake cmux app that answers `computer_use.status` with `status` and
/// refuses every other method; records the methods it was asked.
struct FakeApp {
    socket: PathBuf,
    done: Arc<AtomicBool>,
    methods: Arc<Mutex<Vec<String>>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn serve_app(stream: std::os::unix::net::UnixStream, status: &Value, methods: &Mutex<Vec<String>>) {
    stream.set_nonblocking(false).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap_or(0) > 0 {
        let Ok(request) = serde_json::from_str::<Value>(&line) else { break };
        line.clear();
        let method = request["method"].as_str().unwrap_or("").to_owned();
        let response = if method == "computer_use.status" {
            json!({"id": request["id"], "ok": true, "result": status})
        } else {
            json!({"id": request["id"], "ok": false, "error": {"code": "method_not_found", "message": "unknown method"}})
        };
        // The MCP server's catalog reads and event stream are not the doctor's.
        if !matches!(method.as_str(), "action.list" | "events.stream") {
            methods.lock().unwrap().push(method);
        }
        if writeln!(writer, "{response}").is_err() {
            break;
        }
    }
}

impl FakeApp {
    fn start(dir: &Path, status: Value) -> Self {
        let socket = dir.join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let done = Arc::new(AtomicBool::new(false));
        let methods = Arc::new(Mutex::new(Vec::new()));
        let thread = {
            let (done, methods) = (done.clone(), methods.clone());
            std::thread::spawn(move || {
                loop {
                    match listener.accept() {
                        // One thread per connection: `cmux mcp serve` keeps one
                        // open for the app's events while it answers calls.
                        Ok((stream, _)) => {
                            let (status, methods) = (status.clone(), methods.clone());
                            std::thread::spawn(move || serve_app(stream, &status, &methods));
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            if done.load(Ordering::Relaxed) {
                                break;
                            }
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        Err(error) => panic!("app accept: {error}"),
                    }
                }
            })
        };
        Self { socket, done, methods, thread: Some(thread) }
    }

    fn stop(mut self) -> Vec<String> {
        self.done.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
        self.methods.lock().unwrap().clone()
    }
}

fn report(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "agents doctor exited {:?}: {}{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "agents doctor --json is not JSON ({error}): {}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

/// Every row has exactly the documented keys, so agents can rely on them.
#[track_caller]
fn assert_row_schema(report: &Value) {
    let rows = report["checks"].as_array().unwrap_or_else(|| panic!("no checks array: {report}"));
    assert_eq!(rows.len(), 8, "{report}");
    for row in rows {
        let mut keys: Vec<&str> = row.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["detail", "fix", "fix_url", "id", "reason", "status"], "{row}");
    }
}

/// Every command a `fix` names in backticks works as written: a `cmux`
/// command runs and exits 0 here (a CLI-exempt or unknown action would be
/// refused), and an `open` opens exactly the row's `fix_url`. A row with a
/// `fix_url` names that `open` command.
#[track_caller]
fn assert_fixes_runnable(world: &World, app_socket: &Path, report: &Value) {
    for row in report["checks"].as_array().unwrap() {
        let Some(fix) = row["fix"].as_str() else {
            assert_eq!(row["fix_url"], Value::Null, "fix_url without a fix: {row}");
            continue;
        };
        if let Some(url) = row["fix_url"].as_str() {
            assert!(
                fix.contains(&format!("`open '{url}'`")),
                "fix does not open its fix_url: {row}"
            );
        }
        for command in fix.split('`').skip(1).step_by(2) {
            if let Some(target) = command.strip_prefix("open ") {
                assert_eq!(
                    Some(target),
                    row["fix_url"].as_str().map(|url| format!("'{url}'")).as_deref(),
                    "{row}"
                );
                continue;
            }
            let args: Vec<&str> = command
                .strip_prefix("cmux ")
                .unwrap_or_else(|| panic!("fix command is neither cmux nor open: {row}"))
                .split_whitespace()
                .collect();
            let output = world.run(app_socket, &args);
            assert!(
                output.status.success(),
                "fix command `{command}` exited {:?}: {}{} in {row}",
                output.status.code(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}

#[track_caller]
fn row<'a>(report: &'a Value, id: &str) -> &'a Value {
    report["checks"]
        .as_array()
        .unwrap_or_else(|| panic!("no checks array: {report}"))
        .iter()
        .find(|row| row["id"] == id)
        .unwrap_or_else(|| panic!("no {id} row: {report}"))
}

#[test]
fn agents_doctor_reports_missing_wiring_without_changing_anything() {
    let world = World::new("missing");
    let claude = world.harness("claude");
    let claude_json = r#"{"mcpServers":{"other":{"command":"node","args":["server.js"]}}}"#;
    std::fs::write(world.home.join(".claude.json"), claude_json).unwrap();
    let missing_app = world.dir.join("no-app.sock");

    let report = report(&world.run(&missing_app, &["--json", "agents", "doctor"]));

    assert_eq!(report["schema_version"], 1, "{report}");
    assert_row_schema(&report);
    let harness = row(&report, "harness.claude");
    assert_eq!(harness["status"], "ok", "{report}");
    assert_eq!(harness["detail"], claude.to_str().unwrap(), "{report}");
    let codex = row(&report, "harness.codex");
    assert_eq!(codex["status"], "missing", "{report}");
    assert_eq!(codex["reason"], "not_on_path", "{report}");
    assert!(codex["fix"].as_str().is_some_and(|fix| !fix.is_empty()), "{report}");

    // Without a user-level cmux-cua server, Claude Code has computer use only
    // in chats cmux launches (cmux injects it there); not an error.
    let claude_mcp = row(&report, "mcp.claude");
    assert_eq!(claude_mcp["status"], "cmux_only", "{report}");
    assert_eq!(claude_mcp["reason"], "injected_in_cmux_chats", "{report}");
    let codex_mcp = row(&report, "mcp.codex");
    assert_eq!(codex_mcp["status"], "not_applicable", "{report}");
    assert_eq!(codex_mcp["reason"], "harness_missing", "{report}");

    for id in ["grant.accessibility", "grant.screen_recording", "grant.capture_consent"] {
        let grant = row(&report, id);
        if cfg!(target_os = "macos") {
            assert_eq!(grant["status"], "unknown", "{id}: {report}");
            assert_eq!(grant["reason"], "app_not_running", "{id}: {report}");
        } else {
            assert_eq!(grant["status"], "not_applicable", "{id}: {report}");
            assert_eq!(grant["reason"], "not_macos", "{id}: {report}");
        }
    }

    // Read-only: the config it read is byte for byte the same, nothing new in HOME.
    assert_eq!(std::fs::read_to_string(world.home.join(".claude.json")).unwrap(), claude_json);
    let entries: Vec<_> = std::fs::read_dir(&world.home).unwrap().collect();
    assert_eq!(entries.len(), 1, "doctor wrote into HOME: {entries:?}");

    // The human table names each check with its status and a fix.
    let human = world.run(&missing_app, &["agents", "doctor"]);
    assert!(human.status.success(), "{}", String::from_utf8_lossy(&human.stderr));
    let text = String::from_utf8_lossy(&human.stdout);
    assert!(text.contains("Codex on PATH"), "{text}");
    assert!(text.contains("missing"), "{text}");
    assert!(text.contains("only inside cmux chats"), "{text}");

    // Read-only also means the harness itself never ran.
    assert!(!world.marker("claude").exists(), "doctor ran the claude it found");
}

/// A `cmux` that a login shell can find before the app's CLI (a PyPI
/// `cmux` in ~/.local/bin) and that is older than this CLI is named, with
/// its version and a fix; a newer or same-version one is not. The doctor
/// runs only its `--version`.
#[test]
fn agents_doctor_warns_about_an_older_cmux_on_path() {
    let world = World::new("cli-shadow");
    let missing_app = world.dir.join("no-app.sock");
    // Written by a short-lived `sh`, as `World::harness` does, so no sibling
    // test's fork inherits a write descriptor (ETXTBSY).
    let fake_cmux = |version: &str| {
        let path = world.bin.join("cmux");
        let script = format!(
            "#!/bin/sh\n[ \"$1\" = --version ] || touch \"$0.ran\"\necho \"cmux {version}\"\n"
        );
        let status = Command::new("/bin/sh")
            .args(["-c", "printf '%s' \"$2\" >\"$1\" && chmod 755 \"$1\"", "sh"])
            .arg(&path)
            .arg(script)
            .status()
            .unwrap();
        assert!(status.success());
        path
    };

    let old = fake_cmux("0.13.4");
    let first = report(&world.run(&missing_app, &["--json", "agents", "doctor"]));
    assert_row_schema(&first);
    let shadow = row(&first, "cli.shadow");
    assert_eq!(shadow["status"], "outdated", "{first}");
    assert_eq!(shadow["reason"], "older_cli_on_path", "{first}");
    let detail = shadow["detail"].as_str().unwrap();
    assert!(detail.contains("0.13.4") && detail.contains("cmux"), "{first}");
    assert!(shadow["fix"].as_str().is_some_and(|fix| !fix.is_empty()), "{first}");
    assert!(!world.marker("cmux").exists(), "doctor ran {} beyond --version", old.display());

    fake_cmux("99.0.0");
    let second = report(&world.run(&missing_app, &["--json", "agents", "doctor"]));
    let shadow = row(&second, "cli.shadow");
    assert_eq!(shadow["status"], "ok", "{second}");
    assert_eq!(shadow["fix"], Value::Null, "{second}");
}

#[test]
fn agents_doctor_reports_configured_wiring_and_app_grants() {
    let world = World::new("configured");
    world.harness("claude");
    world.harness("codex");
    std::fs::write(
        world.home.join(".claude.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"/opt/cmux/bin/cmux-cua","args":["mcp"]}}}"#,
    )
    .unwrap();
    std::fs::create_dir_all(world.home.join(".codex")).unwrap();
    let codex_config = world.home.join(".codex").join("config.toml");
    std::fs::write(
        &codex_config,
        "model = \"x\"\n\n[mcp_servers.computer]\ncommand = \"/opt/cmux/bin/cmux-cua\"\nargs = [\"mcp\"]\n",
    )
    .unwrap();
    let app = FakeApp::start(
        &world.dir,
        json!({"phase": "ready", "accessibility": false, "screen_recording": true, "helper": "cmux Computer Use"}),
    );

    let configured = world.run(&app.socket, &["--json", "agents", "doctor"]);

    // A project .mcp.json that names cmux-cua is pending until Claude Code approves it,
    // and a config that does not parse is reported, not guessed.
    std::fs::write(world.home.join(".claude.json"), r#"{"mcpServers":{}}"#).unwrap();
    std::fs::write(
        world.work.join(".mcp.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"cmux-cua","args":["mcp"]}}}"#,
    )
    .unwrap();
    std::fs::write(&codex_config, "[mcp_servers.computer\ncommand = ").unwrap();
    let pending = world.run(&app.socket, &["--json", "agents", "doctor"]);

    let cwd = std::fs::canonicalize(&world.work).unwrap();
    let approved = json!({"mcpServers": {}, "projects": {cwd.to_str().unwrap(): {"enabledMcpjsonServers": ["cmux-cua"]}}});
    std::fs::write(world.home.join(".claude.json"), approved.to_string()).unwrap();
    let approved = world.run(&app.socket, &["--json", "agents", "doctor"]);
    let methods = app.stop();

    let report = report(&configured);
    assert_row_schema(&report);
    let claude_mcp = row(&report, "mcp.claude");
    assert_eq!(claude_mcp["status"], "ok", "{report}");
    assert_eq!(claude_mcp["reason"], "configured", "{report}");
    let codex_mcp = row(&report, "mcp.codex");
    assert_eq!(codex_mcp["status"], "ok", "{report}");
    assert!(codex_mcp["detail"].as_str().unwrap().contains("~/.codex/config.toml"), "{report}");

    let pending = self::report(&pending);
    assert_row_schema(&pending);
    let claude_mcp = row(&pending, "mcp.claude");
    assert_eq!(claude_mcp["status"], "cmux_only", "{pending}");
    assert_eq!(claude_mcp["reason"], "pending_approval", "{pending}");
    assert!(
        claude_mcp["detail"].as_str().unwrap().contains("pending approval in Claude Code"),
        "{pending}"
    );
    let codex_mcp = row(&pending, "mcp.codex");
    assert_eq!(codex_mcp["status"], "unknown", "{pending}");
    assert_eq!(codex_mcp["reason"], "config_unreadable", "{pending}");

    let approved = self::report(&approved);
    let claude_mcp = row(&approved, "mcp.claude");
    assert_eq!(claude_mcp["status"], "ok", "{approved}");
    assert!(claude_mcp["detail"].as_str().unwrap().contains(".mcp.json"), "{approved}");

    for harness in ["claude", "codex"] {
        assert!(!world.marker(harness).exists(), "doctor ran the {harness} it found");
    }

    let accessibility = row(&report, "grant.accessibility");
    let screen_recording = row(&report, "grant.screen_recording");
    if cfg!(target_os = "macos") {
        assert_eq!(methods, vec!["computer_use.status".to_owned(); 3], "{report}");
        assert_eq!(accessibility["status"], "missing", "{report}");
        assert_eq!(accessibility["fix_url"], ACCESSIBILITY_URL, "{report}");
        assert_eq!(screen_recording["status"], "ok", "{report}");
        assert_eq!(screen_recording["fix_url"], Value::Null, "{report}");
        assert_eq!(row(&report, "grant.capture_consent")["status"], "unknown", "{report}");
    } else {
        assert!(methods.is_empty(), "{methods:?}");
        assert_eq!(accessibility["status"], "not_applicable", "{report}");
        assert_eq!(screen_recording["status"], "not_applicable", "{report}");
    }
}

/// Every fix the doctor can print, for every app answer and both languages,
/// is a command an agent can run as written.
#[test]
fn agents_doctor_fix_commands_are_runnable() {
    let world = World::new("fixes");
    world.harness("claude");
    std::fs::write(
        world.work.join(".mcp.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"cmux-cua"}}}"#,
    )
    .unwrap();
    std::fs::create_dir_all(world.home.join(".codex")).unwrap();
    std::fs::write(world.home.join(".codex/config.toml"), "[mcp_servers\n").unwrap();

    let statuses = [
        json!({"phase": "ready", "accessibility": false, "screen_recording": false}),
        json!({"phase": "ready"}),
        json!({"phase": "off"}),
        json!({"phase": "disabled_by_policy"}),
        json!({"phase": "unavailable"}),
        json!({"phase": "starting"}),
        json!({"phase": "version_mismatch"}),
        json!({"phase": "from_a_newer_app"}),
    ];
    for locale in ["C", "ja_JP.UTF-8"] {
        let no_app = world.dir.join("no-app.sock");
        let doctor = report(&world.run_in(&no_app, locale, &["--json", "agents", "doctor"]));
        assert_row_schema(&doctor);
        assert_fixes_runnable(&world, &no_app, &doctor);
        for status in &statuses {
            let app = FakeApp::start(&world.dir, status.clone());
            let doctor =
                report(&world.run_in(&app.socket, locale, &["--json", "agents", "doctor"]));
            assert_row_schema(&doctor);
            assert_fixes_runnable(&world, &app.socket, &doctor);
            app.stop();
            std::fs::remove_file(world.dir.join("app.sock")).unwrap();
        }
    }
    assert!(!world.marker("claude").exists(), "doctor ran the claude it found");
}

/// The status an MCP finding has for a CLI row: a missing harness fails
/// only when no harness is installed.
fn mcp_status(row: &Value, report: &Value) -> &'static str {
    let any_harness =
        report["checks"].as_array().unwrap().iter().any(|row| {
            row["id"].as_str().unwrap().starts_with("harness.") && row["status"] == "ok"
        });
    match row["status"].as_str().unwrap() {
        "ok" | "not_applicable" => "ok",
        "cmux_only" | "unknown" | "outdated" => "warn",
        "missing" if row["id"].as_str().unwrap().starts_with("harness.") && any_harness => "warn",
        "missing" => "fail",
        other => panic!("unknown CLI status {other}"),
    }
}

/// `agents_doctor` over a real `cmux mcp serve` reports the CLI's rows:
/// the same ids in order, each status mapped to ok/warn/fail, the detail
/// as its summary and the CLI's fix as `fix.text`, with the System
/// Settings pane both as the `open` command and the url. It is read-only.
#[test]
fn agents_doctor_mcp_tool_reports_the_cli_findings() {
    let world = World::new("mcp");
    world.harness("claude");
    std::fs::write(
        world.work.join(".mcp.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"cmux-cua"}}}"#,
    )
    .unwrap();
    let claude_json = r#"{"mcpServers":{}}"#;
    std::fs::write(world.home.join(".claude.json"), claude_json).unwrap();
    let app = FakeApp::start(
        &world.dir,
        json!({"phase": "ready", "accessibility": false, "screen_recording": true}),
    );

    let cli = report(&world.run(&app.socket, &["--json", "agents", "doctor"]));
    let results = world.mcp(
        &app.socket,
        &[
            json!({}),
            json!({"checks": ["mcp.codex", "harness.claude"]}),
            json!({"checks": ["harness.nope"]}),
            json!({"checks": "harness.claude"}),
            json!({"checks": ["harness.claude", "harness.claude"]}),
            json!({"fix": true}),
        ],
    );
    let methods = app.stop();

    let tool = &results[0];
    assert_eq!(tool["isError"], false, "{tool}");
    let findings = tool["structuredContent"]["findings"]
        .as_array()
        .unwrap_or_else(|| panic!("no findings: {tool}"));
    let rows = cli["checks"].as_array().unwrap();
    assert_eq!(findings.len(), rows.len(), "{tool}\n{cli}");
    for (finding, row) in findings.iter().zip(rows) {
        let mut keys: Vec<&str> = finding.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["fix", "id", "reason", "status", "summary"], "{finding}");
        assert_eq!(finding["id"], row["id"], "{finding} vs {row}");
        assert_eq!(finding["reason"], row["reason"], "{finding} vs {row}");
        assert_eq!(finding["status"], mcp_status(row, &cli), "{finding}");
        let summary = finding["summary"].as_str().unwrap();
        assert!(summary.ends_with(row["detail"].as_str().unwrap()), "{finding} vs {row}");
        match row["fix"].as_str() {
            None => assert_eq!(finding["fix"], Value::Null, "{finding} vs {row}"),
            Some(text) => {
                let fix = &finding["fix"];
                let mut keys: Vec<&str> =
                    fix.as_object().unwrap().keys().map(String::as_str).collect();
                keys.sort_unstable();
                assert_eq!(keys, ["command", "palette", "text", "url"], "{finding}");
                assert_eq!(fix["text"], text, "{finding} vs {row}");
                assert_eq!(fix["url"], row["fix_url"], "{finding} vs {row}");
                if let Some(url) = row["fix_url"].as_str() {
                    assert_eq!(fix["command"], format!("open '{url}'"), "{finding}");
                }
                if let Some(command) = fix["command"].as_str() {
                    assert!(text.contains(&format!("`{command}`")), "{finding}");
                }
                if let Some(palette) = fix["palette"].as_str() {
                    assert!(text.contains(palette), "{finding}");
                }
            }
        }
    }
    if cfg!(target_os = "macos") {
        let accessibility = findings.iter().find(|f| f["id"] == "grant.accessibility").unwrap();
        assert_eq!(accessibility["status"], "fail", "{tool}");
        assert_eq!(accessibility["fix"]["url"], ACCESSIBILITY_URL, "{tool}");
        // The CLI and the full MCP report each asked once; the subset never did.
        assert_eq!(methods, vec!["computer_use.status".to_owned(); 2], "{tool}");
    } else {
        assert!(methods.is_empty(), "{methods:?}");
    }

    // `checks` keeps the report's order and asks the app nothing it does not need.
    let subset = &results[1];
    assert_eq!(subset["isError"], false, "{subset}");
    let ids: Vec<&str> = subset["structuredContent"]["findings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| finding["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["harness.claude", "mcp.codex"], "{subset}");

    // Unknown ids, a non-array and arguments it does not take are refused, not run.
    for refused in &results[2..] {
        assert_eq!(refused["isError"], true, "{refused}");
        assert_eq!(refused["structuredContent"]["state"], "not_run", "{refused}");
    }
    assert!(
        results[2]["structuredContent"]["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("harness.nope")),
        "{}",
        results[2]
    );

    // Read-only: no config changed, nothing new in HOME, the harness never ran.
    assert_eq!(std::fs::read_to_string(world.home.join(".claude.json")).unwrap(), claude_json);
    assert_eq!(std::fs::read_dir(&world.home).unwrap().count(), 1);
    assert!(!world.marker("claude").exists(), "doctor ran the claude it found");

    // Codex missing beside an installed Claude Code is a warning; with no
    // harness at all, each missing one fails.
    let codex = findings.iter().find(|finding| finding["id"] == "harness.codex").unwrap();
    assert_eq!(codex["status"], "warn", "{tool}");
    std::fs::remove_file(world.bin.join("claude")).unwrap();
    let no_app = world.dir.join("no-app.sock");
    let none = world.mcp(&no_app, &[json!({"checks": ["harness.codex"]})]).remove(0);
    let none = &none["structuredContent"]["findings"];
    assert_eq!(none[0]["id"], "harness.codex", "{none}");
    assert_eq!(none[0]["status"], "fail", "{none}");
}

/// Neither the CLI (JSON and table) nor the MCP tool prints the home
/// directory or the text of a config it could not parse, which may hold a
/// secret: paths under HOME read `~/...` and a parse error names its line.
#[test]
fn agents_doctor_mcp_and_cli_redact_home_and_config_text() {
    const SECRET: &str = "sk-cmux-doctor-secret-4242";
    let world = World::new("redact");
    world.harness("codex");
    std::fs::create_dir_all(world.home.join(".codex")).unwrap();
    std::fs::write(
        world.home.join(".codex/config.toml"),
        format!("model = \"x\"\napi_key = \"{SECRET}\" trailing\n"),
    )
    .unwrap();
    let no_app = world.dir.join("no-app.sock");

    let json_report = world.run(&no_app, &["--json", "agents", "doctor"]);
    let table = world.run(&no_app, &["agents", "doctor"]);
    let tool = world.mcp(&no_app, &[json!({})]).remove(0);

    let home = world.home.to_str().unwrap();
    for (surface, text) in [
        ("cli --json", String::from_utf8_lossy(&json_report.stdout).into_owned()),
        ("cli table", String::from_utf8_lossy(&table.stdout).into_owned()),
        ("mcp", tool.to_string()),
    ] {
        assert!(!text.contains(SECRET), "{surface} printed the config's secret: {text}");
        assert!(!text.contains(home), "{surface} printed HOME: {text}");
        assert!(text.contains("~/.codex/config.toml"), "{surface}: {text}");
    }
    let report = report(&json_report);
    let codex = row(&report, "mcp.codex");
    assert_eq!(codex["reason"], "config_unreadable", "{report}");
    assert!(codex["detail"].as_str().unwrap().contains("line 2"), "{report}");
}

/// A HOME reached through a symlink (`/home -> /var/home`) still prints as
/// `~`: the working directory is the resolved path, so a project under HOME
/// must not print it. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` print by name.
#[test]
fn agents_doctor_mcp_and_cli_redact_symlinked_home_and_config_dirs() {
    let mut world = World::new("symlink");
    world.harness("claude");
    world.harness("codex");
    let real_home = world.dir.join("real-home");
    let link_home = world.dir.join("link-home");
    let project = real_home.join("proj");
    std::fs::create_dir_all(&project).unwrap();
    std::os::unix::fs::symlink(&real_home, &link_home).unwrap();
    std::fs::write(real_home.join(".claude.json"), r#"{"mcpServers":{}}"#).unwrap();
    std::fs::write(
        project.join(".mcp.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"cmux-cua"}}}"#,
    )
    .unwrap();
    let codex_home = world.dir.join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(codex_home.join("config.toml"), "[mcp_servers\n").unwrap();
    let claude_config = world.dir.join("claude-config");
    std::fs::create_dir_all(&claude_config).unwrap();
    std::fs::write(
        claude_config.join(".claude.json"),
        r#"{"mcpServers":{"cmux-cua":{"command":"cmux-cua"}}}"#,
    )
    .unwrap();
    world.cwd = Some(link_home.join("proj"));
    world.env = vec![("HOME", link_home.clone()), ("CODEX_HOME", codex_home.clone())];
    let no_app = world.dir.join("no-app.sock");

    let mut forbidden: Vec<String> = [&real_home, &link_home, &codex_home, &claude_config]
        .into_iter()
        .flat_map(|path| [path.clone(), std::fs::canonicalize(path).unwrap()])
        .map(|path| path.to_str().unwrap().to_owned())
        .collect();
    forbidden.sort();
    forbidden.dedup();
    let check = |surface: &str, text: &str, expected: &[&str]| {
        for path in &forbidden {
            assert!(!text.contains(path.as_str()), "{surface} printed {path}: {text}");
        }
        for want in expected {
            assert!(text.contains(want), "{surface} does not name {want}: {text}");
        }
    };

    // Project config under the symlinked HOME and a broken $CODEX_HOME config.
    let expected = ["~/proj/.mcp.json", "$CODEX_HOME/config.toml"];
    let cli = world.run(&no_app, &["--json", "agents", "doctor"]);
    report(&cli);
    check("cli --json", &String::from_utf8_lossy(&cli.stdout), &expected);
    let table = world.run(&no_app, &["agents", "doctor"]);
    check("cli table", &String::from_utf8_lossy(&table.stdout), &expected);
    let tool = world.mcp(&no_app, &[json!({})]).remove(0);
    assert_eq!(tool["isError"], false, "{tool}");
    check("mcp", &tool.to_string(), &expected);

    // Claude Code configured in $CLAUDE_CONFIG_DIR.
    world.env.push(("CLAUDE_CONFIG_DIR", claude_config));
    let expected = ["$CLAUDE_CONFIG_DIR/.claude.json"];
    let cli = world.run(&no_app, &["--json", "agents", "doctor"]);
    report(&cli);
    check("cli --json", &String::from_utf8_lossy(&cli.stdout), &expected);
    let tool = world.mcp(&no_app, &[json!({})]).remove(0);
    check("mcp", &tool.to_string(), &expected);
}
