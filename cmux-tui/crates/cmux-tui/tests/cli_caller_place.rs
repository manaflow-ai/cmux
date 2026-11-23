//! Where an agent's or a person's CLI command acts when it names the
//! caller's place implicitly (https://github.com/manaflow-ai/cmux/issues/25590):
//! `current` is the caller's own object (resolve.rs `caller_scopes`),
//! `focused` the one the person looks at, a terminal tab created from a
//! person's terminal with no place opens in that terminal's pane, and a
//! Chief turn is placed only by the app that owns its daemon.
//!
//! The CLI runs against a fake daemon and a fake app that record what they
//! were asked.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The caller's own place.
const OWN_WS: &str = "ws_11111111111111111111111111111111";
const OWN_SCREEN: &str = "screen_22222222222222222222222222222222";
const OWN_PANE: &str = "pane_33333333333333333333333333333333";
const OWN_TAB: &str = "tab_44444444444444444444444444444444";
const OWN_TERMINAL: &str = "term_55555555555555555555555555555555";
/// The workspace the person looks at.
const FRONT_WS: &str = "ws_77777777777777777777777777777777";
const FRONT_PANE: &str = "pane_88888888888888888888888888888888";
/// A terminal the daemon does not show.
const STALE_TERMINAL: &str = "term_00000000000000000000000000000000";
/// Another machine.
const MACHINE: &str = "machine_99999999999999999999999999999999";
/// Stands for the fake daemon's socket path in a test's arguments.
const SOCKET: &str = "{daemon socket}";
static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

#[test]
fn pane_current_split_from_a_terminal_splits_the_callers_own_pane() {
    let run = Run::new().terminal().cli(&["--json", "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(split["screen"], OWN_SCREEN);
    assert_eq!(split["pane"], OWN_PANE);
}

#[test]
fn tab_create_terminal_with_no_place_opens_in_the_callers_pane() {
    let run = Run::new().terminal().cli(&["--json", "tab", "create", "terminal"]);
    let created = run.mutation("tab.create_terminal");
    assert_eq!(created["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(created["pane"], OWN_PANE);
}

#[test]
fn a_current_parent_flag_is_the_callers_too() {
    let run =
        Run::new().terminal().cli(&["--json", "tab", "create", "terminal", "--pane", "current"]);
    let created = run.mutation("tab.create_terminal");
    assert_eq!(created["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(created["pane"], OWN_PANE);
}

#[test]
fn workspace_current_is_the_callers_workspace() {
    let run =
        Run::new().terminal().cli(&["--json", "workspace", "current", "rename", "--name", "dev"]);
    let renamed = run.mutation("workspace.rename");
    assert_eq!(renamed["workspace"], OWN_WS, "{}", run.stderr());
}

#[test]
fn an_agent_chats_current_is_where_the_app_places_its_chat() {
    let run = Run::new().app(App::Placed).agent().cli(&["--json", "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(split["pane"], OWN_PANE);
    assert!(run.app_methods().contains(&"system.identify".to_owned()));
}

#[test]
fn focused_is_the_pane_the_person_looks_at() {
    let run = Run::new().app(App::Placed).terminal().cli(&["--json", "pane", "focused", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], FRONT_WS, "{}", run.stderr());
    // The app names no focused screen: the daemon's active one of that workspace.
    assert_eq!(split["screen"], "current");
    assert_eq!(split["pane"], FRONT_PANE);
    assert!(!run.daemon_operations().contains(&"terminal.get".to_owned()));
}

#[test]
fn focused_below_the_callers_current_workspace_is_that_workspaces_active_pane() {
    // The caller's workspace is not the one the person looks at, so the
    // focused pane is not in it: the pane is the workspace's active one.
    let run = Run::new().app(App::Placed).terminal().cli(&[
        "--json",
        "tab",
        "create",
        "terminal",
        "--workspace",
        "current",
        "--pane",
        "focused",
    ]);
    let created = run.mutation("tab.create_terminal");
    assert_eq!(created["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(created["pane"], "current");
}

#[test]
fn another_machine_keeps_its_own_current() {
    let run =
        Run::new().terminal().cli(&["--json", "--machine", MACHINE, "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["machine"], MACHINE, "{}", run.stderr());
    assert_eq!(split["workspace"], "current");
    assert_eq!(split["pane"], "current");
    assert!(!run.daemon_operations().contains(&"terminal.get".to_owned()));
}

#[test]
fn current_under_another_workspace_id_is_its_active_pane_even_for_an_unplaced_chat() {
    // The app is unreachable, so the chat cannot be placed; the command
    // names the workspace by id, so it does not need the chat's place.
    let run = Run::new().agent().cli(&[
        "--json",
        "tab",
        "create",
        "terminal",
        "--workspace",
        FRONT_WS,
        "--pane",
        "current",
    ]);
    let split = run.mutation("tab.create_terminal");
    assert_eq!(split["workspace"], FRONT_WS, "{}", run.stderr());
    assert_eq!(split["pane"], "current");
}

#[test]
fn current_under_the_callers_own_workspace_id_is_the_callers_pane() {
    let run = Run::new().terminal().cli(&[
        "--json",
        "tab",
        "create",
        "terminal",
        "--workspace",
        OWN_WS,
        "--pane",
        "current",
    ]);
    let split = run.mutation("tab.create_terminal");
    assert_eq!(split["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(split["pane"], OWN_PANE);
}

#[test]
fn focused_without_an_app_is_the_daemons_active_pane() {
    let run = Run::new().terminal().cli(&["--json", "pane", "focused", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], "current", "{}", run.stderr());
    assert_eq!(split["pane"], "current");
}

#[test]
fn a_shell_outside_cmux_keeps_the_daemons_current() {
    let run = Run::new().cli(&["--json", "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], "current", "{}", run.stderr());
    assert_eq!(split["pane"], "current");
    assert!(!run.daemon_operations().contains(&"terminal.get".to_owned()));
}

#[test]
fn a_cloud_chief_turn_keeps_its_vms_current_and_never_sends_the_macs_ids() {
    // The relayed app places the Home chat in the Mac's topology; the VM's
    // daemon has none of those ids.
    let run =
        Run::new().app(App::Placed).cloud_chief_turn().cli(&["--json", "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], "current", "{}", run.stderr());
    assert_eq!(split["pane"], "current");
    let run = Run::new()
        .app(App::Placed)
        .cloud_chief_turn()
        .cli(&["--json", "tab", "create", "terminal"]);
    let created = run.mutation("tab.create_terminal");
    assert!(created.get("pane").is_none_or(Value::is_null), "{created} {}", run.stderr());
}

#[test]
fn a_chief_turn_in_the_mac_app_acts_at_the_home_chat() {
    let run = Run::new().app(App::Placed).chief_turn().cli(&["--json", "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], OWN_WS, "{}", run.stderr());
    assert_eq!(split["pane"], OWN_PANE);
}

#[test]
fn focused_on_another_session_is_its_active_pane() {
    let run = Run::new()
        .app(App::Placed)
        .terminal()
        .cli(&["--json", "--socket", SOCKET, "pane", "focused", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["workspace"], "current", "{}", run.stderr());
    assert_eq!(split["pane"], "current");
    assert!(run.app.is_empty(), "no app was asked: {:?}", run.app_methods());
}

#[test]
fn a_terminal_the_daemon_no_longer_shows_keeps_the_default_pane_for_a_new_tab() {
    let run = Run::new().stale_terminal().cli(&["--json", "tab", "create", "terminal"]);
    let created = run.mutation("tab.create_terminal");
    for scope in ["workspace", "screen", "pane"] {
        assert!(created.get(scope).is_none_or(Value::is_null), "{scope}: {}", run.stderr());
    }
}

#[test]
fn a_tab_with_no_place_in_a_named_session_names_no_place() {
    // The daemon's default can create a workspace in an empty session;
    // `current` there would fail.
    let run =
        Run::new().terminal().cli(&["--json", "--socket", SOCKET, "tab", "create", "terminal"]);
    let created = run.mutation("tab.create_terminal");
    for scope in ["workspace", "screen", "pane"] {
        assert!(created.get(scope).is_none_or(Value::is_null), "{scope}: {}", run.stderr());
    }
    assert!(!run.daemon_operations().contains(&"terminal.get".to_owned()));
}

#[test]
fn a_named_socket_keeps_its_own_current() {
    let run =
        Run::new().terminal().cli(&["--json", "--socket", SOCKET, "pane", "current", "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["pane"], "current", "{}", run.stderr());
    assert!(!run.daemon_operations().contains(&"terminal.get".to_owned()));
}

#[test]
fn an_id_is_sent_as_given() {
    let run = Run::new().terminal().cli(&["--json", "pane", FRONT_PANE, "split"]);
    let split = run.mutation("pane.split");
    assert_eq!(split["pane"], FRONT_PANE, "{}", run.stderr());
    assert!(split.get("workspace").is_none_or(Value::is_null));
}

struct Run {
    dir: PathBuf,
    app: Option<App>,
    terminal: bool,
    agent: bool,
    /// A Chief turn (`CMUX_CALLER_HOME_CHAT`).
    home_chat: bool,
    /// The app is reached through `CMUX_SOCKET_PATH` (a relay) and does not
    /// own the request's daemon.
    relay: bool,
    /// The caller's terminal id is one the daemon does not show.
    stale: bool,
}

/// What the fake app's `system.identify` says about the caller.
#[derive(Clone, Copy)]
enum App {
    /// The caller's chat is in the caller's place.
    Placed,
}

struct Finished {
    output: Output,
    daemon: Vec<Value>,
    app: Vec<Value>,
}

impl Finished {
    fn stderr(&self) -> String {
        String::from_utf8_lossy(&self.output.stderr).into_owned()
    }

    fn daemon_operations(&self) -> Vec<String> {
        self.daemon.iter().filter_map(|r| r["operation"].as_str().map(str::to_owned)).collect()
    }

    fn app_methods(&self) -> Vec<String> {
        self.app.iter().filter_map(|r| r["method"].as_str().map(str::to_owned)).collect()
    }

    /// The params of the one `operation` request the CLI sent.
    fn mutation(&self, operation: &str) -> Value {
        self.daemon
            .iter()
            .find(|request| request["operation"] == operation)
            .map(|request| request["params"].clone())
            .unwrap_or_else(|| {
                panic!("no {operation}: {:?}\nstderr: {}", self.daemon_operations(), self.stderr())
            })
    }
}

impl Run {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let dir = Path::new("/tmp")
            .join(format!("cmux-cplace-{}-{stamp}-{sequence}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self {
            dir,
            app: None,
            terminal: false,
            agent: false,
            home_chat: false,
            relay: false,
            stale: false,
        }
    }

    fn app(mut self, app: App) -> Self {
        self.app = Some(app);
        self
    }

    /// The CLI runs in the caller's terminal (`CMUX_TUI_TERMINAL_ID`).
    fn terminal(mut self) -> Self {
        self.terminal = true;
        self
    }

    /// A Chief turn in the Mac app: `CMUX_CALLER_HOME_CHAT`, the app that
    /// owns the daemon.
    fn chief_turn(mut self) -> Self {
        self.home_chat = true;
        self
    }

    /// A Cloud Chief turn: `CMUX_CALLER_HOME_CHAT`, the Mac app over a
    /// relay, and the VM's own daemon.
    fn cloud_chief_turn(mut self) -> Self {
        self.home_chat = true;
        self.relay = true;
        self
    }

    /// The caller's terminal is gone from the daemon (a script that
    /// outlived its tab).
    fn stale_terminal(mut self) -> Self {
        self.terminal = true;
        self.stale = true;
        self
    }

    /// The CLI runs for an agent chat (`CMUX_AGENT_SESSION`).
    fn agent(mut self) -> Self {
        self.agent = true;
        self
    }

    fn cli(self, args: &[&str]) -> Finished {
        let daemon_socket = self.dir.join("mux.sock");
        let app_socket = self.dir.join("app.sock");
        let daemon = fake_daemon(&daemon_socket);
        let done = Arc::new(AtomicBool::new(false));
        let app = self.app.map(|mode| fake_app(&app_socket, mode, done.clone()));
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        if self.relay {
            // The app socket comes from the environment, and nothing ties
            // it to the daemon.
            command.env("CMUX_SOCKET_PATH", &app_socket);
        } else {
            // A missing socket: the app is unreachable.
            command.arg("--app-socket").arg(&app_socket);
        }
        let socket = daemon_socket.display().to_string();
        command
            .args(args.iter().map(|arg| if *arg == SOCKET { socket.as_str() } else { arg }))
            .env("CMUX_TUI_SOCKET", &daemon_socket)
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_CALLER_HOME_CHAT")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env("CMUX_CLI_NO_RETRY", "1");
        if self.terminal {
            let terminal = if self.stale { STALE_TERMINAL } else { OWN_TERMINAL };
            command.env("CMUX_TUI_TERMINAL_ID", terminal);
        }
        if self.home_chat {
            command.env("CMUX_CALLER_HOME_CHAT", "1");
        }
        if self.agent {
            command.env("CMUX_AGENT_SESSION", "01a17599");
        }
        let output = command.output().unwrap();
        done.store(true, Ordering::Relaxed);
        let daemon = daemon.join().unwrap();
        let app = app.map(|handle| handle.join().unwrap()).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&self.dir);
        Finished { output, daemon, app }
    }
}

/// A daemon that answers the caller lookups and the creations, and records
/// every request of the one connection.
fn fake_daemon(socket: &Path) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut requests = Vec::new();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(&line).expect("CLI sent invalid JSON");
            line.clear();
            let response = match daemon_result(&request) {
                Ok(result) => json!({"protocol": "cmux.protocol/2", "type": "response",
                    "id": request["id"], "ok": true, "result": result}),
                Err(message) => json!({"protocol": "cmux.protocol/2", "type": "response",
                    "id": request["id"], "ok": false, "error": {"code": "resource.not_found",
                    "message": message, "details": {}, "retryable": false}}),
            };
            requests.push(request);
            if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err() {
                break;
            }
        }
        requests
    })
}

fn daemon_result(request: &Value) -> Result<Value, String> {
    let params = &request["params"];
    let mutation = |value: Value| json!({"value": value, "generation": "g", "revision": "2", "replayed": false});
    match request["operation"].as_str().unwrap_or_default() {
        "terminal.get" if params["terminal"] == OWN_TERMINAL => {
            Ok(json!({"id": OWN_TERMINAL, "tab_id": OWN_TAB}))
        }
        "tab.get" if params["tab"] == OWN_TAB => Ok(json!({"id": OWN_TAB, "pane_id": OWN_PANE})),
        "pane.get" if params["pane"] == OWN_PANE => {
            Ok(json!({"id": OWN_PANE, "screen_id": OWN_SCREEN}))
        }
        "screen.get" if params["screen"] == OWN_SCREEN => {
            Ok(json!({"id": OWN_SCREEN, "workspace_id": OWN_WS}))
        }
        "pane.split" => Ok(mutation(json!({"workspace_id": OWN_WS, "pane_id": OWN_PANE,
            "tab_id": "tab_99999999999999999999999999999999"}))),
        "tab.create_terminal" | "tab.create_browser" => Ok(mutation(json!({
            "workspace_id": OWN_WS, "pane_id": OWN_PANE,
            "tab_id": "tab_99999999999999999999999999999999"}))),
        "workspace.rename" => Ok(mutation(json!({"id": OWN_WS, "name": "dev"}))),
        other => Err(format!("unexpected {other} {params}")),
    }
}

/// An app control socket that answers `system.identify` and `snapshot.get`.
/// It stops waiting for a connection once `done` is set.
fn fake_app(socket: &Path, mode: App, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::new()));
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
                        let response = app_response(mode, &request);
                        received.lock().unwrap().push(request);
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
        std::mem::take(&mut *received.lock().unwrap())
    })
}

fn app_response(mode: App, request: &Value) -> Value {
    let result = match request["method"].as_str().unwrap_or_default() {
        "system.identify" => match mode {
            App::Placed => json!({"caller": {"agent_session": "01a17599", "workspace": OWN_WS,
                "screen": OWN_SCREEN, "pane": OWN_PANE, "tab": OWN_TAB}, "beside": null}),
        },
        // The app's focus names no screen (ControlTopology+JSON.swift).
        "snapshot.get" => json!({"topology": {"focus": {"window": "win_a",
            "workspace": FRONT_WS, "pane": FRONT_PANE}}}),
        other => {
            return json!({"id": request["id"], "ok": false, "error": {"code": "unknown_method",
                "message": format!("unexpected {other}"), "data": {}}});
        }
    };
    json!({"id": request["id"], "ok": true, "result": result})
}
