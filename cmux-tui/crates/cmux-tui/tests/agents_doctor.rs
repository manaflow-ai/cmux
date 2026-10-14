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
}

impl World {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = Path::new("/tmp")
            .join(format!("cmux-agents-doctor-{name}-{}-{stamp}-{n}", std::process::id()));
        let world =
            Self { home: dir.join("home"), bin: dir.join("bin"), work: dir.join("work"), dir };
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
            .current_dir(&self.work)
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
            .stdin(Stdio::null())
            .output()
            .unwrap()
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
                        Ok((stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                            let mut reader = BufReader::new(stream.try_clone().unwrap());
                            let mut writer = stream;
                            let mut line = String::new();
                            while reader.read_line(&mut line).unwrap_or(0) > 0 {
                                let request: Value = serde_json::from_str(&line).unwrap();
                                line.clear();
                                let method = request["method"].as_str().unwrap_or("").to_owned();
                                let response = if method == "computer_use.status" {
                                    json!({"id": request["id"], "ok": true, "result": status})
                                } else {
                                    json!({"id": request["id"], "ok": false, "error": {"code": "method_not_found", "message": "unknown method"}})
                                };
                                methods.lock().unwrap().push(method);
                                if writeln!(writer, "{response}").is_err() {
                                    break;
                                }
                            }
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
    assert_eq!(rows.len(), 7, "{report}");
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
    assert!(
        codex_mcp["detail"].as_str().unwrap().contains(codex_config.to_str().unwrap()),
        "{report}"
    );

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
