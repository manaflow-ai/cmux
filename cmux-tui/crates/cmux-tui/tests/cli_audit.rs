//! The `cmux` CLI against a real headless daemon and against sockets that
//! are missing, stale, hung or speak another protocol: the paths a user
//! types, the selectors they use, and the errors that must name the fix.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::symlink;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

fn scaled(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

fn temp_dir(label: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    // Short: Unix socket paths are limited to about 100 bytes.
    let dir = PathBuf::from("/tmp").join(format!("cxa-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("cmux")).unwrap();
    dir
}

/// Runs the binary under the name `cmux` with an isolated environment.
fn cmux(dir: &Path, args: &[&str]) -> Output {
    Command::new(dir.join("cmux"))
        .args(args)
        .env("HOME", dir)
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(label: &str) -> Self {
        let dir = temp_dir(label);
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("HOME", &dir)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + scaled(Duration::from_secs(15));
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    /// `cmux --socket <this daemon> <args>`.
    fn run(&self, args: &[&str]) -> Output {
        let socket = self.socket.to_str().unwrap();
        let mut full = vec!["--socket", socket];
        full.extend_from_slice(args);
        cmux(&self.dir, &full)
    }

    fn ok(&self, args: &[&str]) -> String {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "cmux {args:?} failed ({:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            text(&output.stdout),
            text(&output.stderr)
        );
        text(&output.stdout)
    }

    fn json(&self, args: &[&str]) -> Value {
        let mut full = vec!["--json"];
        full.extend_from_slice(args);
        let stdout = self.ok(&full);
        serde_json::from_str(&stdout).unwrap_or_else(|error| panic!("{error}: {stdout}"))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let tree = legacy_request(&self.socket, &json!({"cmd": "list-workspaces"}));
        for workspace in
            tree.iter().flat_map(|tree| tree["data"]["workspaces"].as_array()).flatten()
        {
            let _ = legacy_request(
                &self.socket,
                &json!({"cmd": "close-workspace", "key": workspace["key"], "end_terminals": true}),
            );
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn legacy_request(path: &Path, value: &Value) -> Option<Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

#[test]
fn tab_zoom_and_update_resolve_current_through_the_current_pane() {
    let daemon = Daemon::start("zoom");
    daemon.ok(&["workspace", "create", "--name", "zoom"]);
    daemon.ok(&["tab", "current", "zoom", "1.5"]);
    daemon.ok(&["tab", "current", "update", "--zoom", "2"]);
    daemon.ok(&["tab", "current", "zoom", "reset"]);
    daemon.ok(&["tab", "current", "update", "--clear-zoom"]);
}

#[test]
fn tab_new_terminal_is_tab_create_terminal() {
    let daemon = Daemon::start("tabnew");
    daemon.ok(&["workspace", "create", "--name", "tabs"]);
    let created = daemon.json(&["tab", "new", "terminal"]);
    assert!(created["value"]["tab_id"].as_str().is_some_and(|id| id.starts_with("tab_")));
    // A tab that is really named `new` still takes the explicit path.
    daemon.ok(&["tab", "current", "rename", "--name", "new"]);
    let shown = daemon.json(&["tab", "new", "terminal", "show"]);
    assert!(shown["id"].as_str().is_some_and(|id| id.starts_with("term_")), "{shown}");
}

#[test]
fn cmux_ls_lists_workspaces() {
    let daemon = Daemon::start("ls");
    daemon.ok(&["workspace", "create", "--name", "listed"]);
    assert_eq!(daemon.json(&["ls"]), daemon.json(&["workspace", "list"]));
    assert!(daemon.ok(&["ls"]).contains("listed"));
}

#[test]
fn a_definitive_daemon_error_does_not_claim_the_change_may_still_apply() {
    let daemon = Daemon::start("definitive");
    let output = daemon.run(&["workspace", "missing", "close"]);
    assert_eq!(output.status.code(), Some(1));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("no workspace matches"), "{stderr}");
    assert!(!stderr.contains("may still apply"), "{stderr}");
}

#[test]
fn a_missing_socket_names_the_command_that_starts_a_session() {
    let dir = temp_dir("missing");
    let socket = dir.join("none.sock");
    let output = cmux(&dir, &["--socket", socket.to_str().unwrap(), "workspace", "list"]);
    assert_eq!(output.status.code(), Some(3));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("no cmux session is running"), "{stderr}");
    assert!(stderr.contains("cmux server ensure"), "{stderr}");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn a_stale_socket_is_reported_as_stale_with_the_fix() {
    let dir = temp_dir("stale");
    let socket = dir.join("stale.sock");
    drop(UnixListener::bind(&socket).unwrap());
    let output = cmux(&dir, &["--socket", socket.to_str().unwrap(), "workspace", "list"]);
    assert_eq!(output.status.code(), Some(3));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("stale"), "{stderr}");
    assert!(stderr.contains("cmux server ensure"), "{stderr}");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn a_server_that_speaks_another_protocol_is_named_as_such() {
    let dir = temp_dir("legacy");
    let socket = dir.join("legacy.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut writer = stream;
        writeln!(writer, "{}", json!({"id": 1, "ok": false, "error": "unknown command"})).unwrap();
    });
    let output = cmux(&dir, &["--socket", socket.to_str().unwrap(), "workspace", "list"]);
    server.join().unwrap();
    assert_eq!(output.status.code(), Some(3));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("cmux.protocol/2"), "{stderr}");
    assert!(stderr.contains("--socket"), "{stderr}");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn incomplete_commands_name_the_help_that_lists_their_actions() {
    let dir = temp_dir("usage");
    let output = cmux(&dir, &["workspace"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(text(&output.stderr).contains("cmux workspace --help"), "{}", text(&output.stderr));
    let output = cmux(&dir, &["tab", "create"]);
    assert_eq!(output.status.code(), Some(2));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("terminal") && stderr.contains("browser"), "{stderr}");
    let output = cmux(&dir, &["workspace", "list", "--bogus"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(text(&output.stderr).contains("not an option"), "{}", text(&output.stderr));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn scope_help_shows_required_flags_and_selector_forms() {
    let dir = temp_dir("help");
    let workspace = text(&cmux(&dir, &["workspace", "--help"]).stdout);
    assert!(workspace.contains("rename <name>|--name <name>"), "{workspace}");
    assert!(workspace.contains("move --index"), "{workspace}");
    assert!(workspace.contains("name:"), "{workspace}");
    let tab = text(&cmux(&dir, &["tab", "--help"]).stdout);
    assert!(tab.contains("move --workspace"), "{tab}");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn rename_takes_the_new_name_as_a_word_or_a_flag() {
    let daemon = Daemon::start("rename");
    let created = daemon.json(&["workspace", "create", "--name", "before"]);
    let id = created["value"]["workspace_id"].as_str().unwrap().to_owned();
    daemon.ok(&["workspace", &id, "rename", "after"]);
    assert_eq!(daemon.json(&["workspace", &id, "show"])["name"], "after");
    daemon.ok(&["workspace", "rename", "current-name"]);
    assert_eq!(daemon.json(&["workspace", &id, "show"])["name"], "current-name");
    daemon.ok(&["pane", "current", "rename", "left"]);
    assert_eq!(daemon.json(&["pane", "current", "show"])["name"], "left");
    daemon.ok(&["tab", "current", "rename", "shell"]);
    assert_eq!(daemon.json(&["tab", "current", "show"])["name"], "shell");
    let both = daemon.run(&["workspace", &id, "rename", "x", "--name", "y"]);
    assert_eq!(both.status.code(), Some(2), "{}", text(&both.stderr));
}

#[test]
fn rename_has_its_own_help() {
    let dir = temp_dir("renamehelp");
    for args in [
        vec!["workspace", "rename", "--help"],
        vec!["workspace", "ws_00000000000000000000000000000000", "rename", "--help"],
        vec!["pane", "current", "rename", "--help"],
    ] {
        let output = cmux(&dir, &args);
        assert!(output.status.success(), "{args:?}: {}", text(&output.stderr));
        let help = text(&output.stdout);
        assert!(help.contains("rename <name>"), "{args:?}: {help}");
        assert!(help.contains("--name <name>"), "{args:?}: {help}");
        assert!(!help.contains("layout apply"), "{args:?} printed the whole scope help: {help}");
    }
    let _ = fs::remove_dir_all(dir);
}

/// Runs the binary under `name` (`cmux` or `cmux-tui`) in `dir`.
fn run_as(dir: &Path, name: &str, args: &[&str]) -> Output {
    let program = dir.join(name);
    if !program.exists() {
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), &program).unwrap();
    }
    Command::new(program)
        .args(args)
        .env("HOME", dir)
        .env("XDG_RUNTIME_DIR", dir)
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[test]
fn attach_errors_name_the_program_that_was_run() {
    let dir = temp_dir("attachname");
    for name in ["cmux", "cmux-tui"] {
        let output = run_as(&dir, name, &["attach", "--session", "cxa-absent"]);
        assert!(!output.status.success(), "{name}: attach to a missing session succeeded");
        let stderr = text(&output.stderr);
        assert!(stderr.starts_with(&format!("{name}: ")), "{name}: {stderr}");
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn attach_help_shows_only_attach_usage() {
    let dir = temp_dir("attachhelp");
    let output = run_as(&dir, "cmux", &["attach", "--help"]);
    assert!(output.status.success(), "{}", text(&output.stderr));
    let help = text(&output.stdout);
    assert!(help.contains("cmux attach"), "{help}");
    assert!(help.contains("--terminal <id>"), "{help}");
    assert!(!help.contains("--ws-insecure-bind"), "attach help lists start options: {help}");
    assert!(!help.contains("--relay"), "attach help lists start options: {help}");
    let _ = fs::remove_dir_all(dir);
}
