//! `cmux mcp serve` names the caller of an app run only where the caller
//! is (cx-91xd, beside_caller phase 3, hq-6d right-column design).
//!
//! The caller's terminal (`CMUX_TUI_TERMINAL_ID`) belongs to the session
//! its environment names. A tool call that names another session must not
//! send that terminal: not as a `terminal.get` to the other session's
//! daemon, and not as the `caller` of the app's `openBrowser` run. An
//! agent's caller is its acpmux session (`CMUX_AGENT_SESSION`), which the
//! app finds by its own topology, so it goes with the run in either case.
//!
//! The test runs the real `cmux-tui mcp serve` over stdio against a fake
//! daemon per session (the caller's own at `CMUX_TUI_SOCKET`, the named
//! one at its derived socket) and a fake app control socket.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const OTHER_SESSION: &str = "other";
const PERSON_TERMINAL: &str = "term_55555555555555555555555555555555";
const AGENT_SESSION: &str = "acp_agent_session_a";
const WORKSPACE: &str = "ws_11111111111111111111111111111111";
const SCREEN: &str = "screen_22222222222222222222222222222222";
const PANE: &str = "pane_33333333333333333333333333333333";
const NEW_TAB: &str = "tab_77777777777777777777777777777777";
const NEW_BROWSER: &str = "browser_88888888888888888888888888888888";
const URL: &str = "http://127.0.0.1:8765/opener-a.html";
static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

#[test]
fn a_person_naming_another_session_sends_no_terminal_of_their_own_session() {
    let run = serve(None);
    assert_eq!(run.result["isError"], false, "{}", run.result);
    assert!(run.own_daemon.is_empty(), "the caller's own daemon was asked: {:?}", run.own_daemon);
    assert!(
        !run.other_daemon.iter().any(|request| request["operation"] == "terminal.get"),
        "the other session was asked for the caller's terminal: {:?}",
        run.other_daemon
    );
    let open = run.open_browser();
    assert!(
        open["params"].get("caller").is_none(),
        "the app run names the person's terminal of another session as its caller: {open}"
    );
}

#[test]
fn an_agent_naming_another_session_sends_its_agent_session_as_caller() {
    let run = serve(Some(AGENT_SESSION));
    assert_eq!(run.result["isError"], false, "{}", run.result);
    assert!(run.own_daemon.is_empty(), "the caller's own daemon was asked: {:?}", run.own_daemon);
    assert!(
        !run.other_daemon.iter().any(|request| request["operation"] == "terminal.get"),
        "{:?}",
        run.other_daemon
    );
    let open = run.open_browser();
    assert_eq!(open["params"]["caller"], json!({"agent_session": AGENT_SESSION}), "{open}");
}

struct Finished {
    result: Value,
    own_daemon: Vec<Value>,
    other_daemon: Vec<Value>,
    app: Vec<Value>,
}

impl Finished {
    fn open_browser(&self) -> &Value {
        let runs: Vec<&Value> = self
            .app
            .iter()
            .filter(|call| {
                call["method"] == "action.run" && call["params"]["action"] == "openBrowser"
            })
            .collect();
        let [open] = runs.as_slice() else {
            panic!("one openBrowser run expected: {:?}", self.app)
        };
        open
    }
}

/// One `tab_create_browser` tool call naming [`OTHER_SESSION`], from a
/// `cmux mcp serve` started in a terminal of the person's own session
/// (`CMUX_TUI_TERMINAL_ID`), with `agent_session` as `CMUX_AGENT_SESSION`.
fn serve(agent_session: Option<&str>) -> Finished {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    let dir = PathBuf::from(format!("/tmp/cmux-mcs-{}-{stamp}-{sequence}", std::process::id()));
    let runtime = dir.join("rt");
    std::fs::create_dir_all(&runtime).unwrap();
    let uid = std::fs::metadata(&dir).unwrap().uid();
    let session_dir = runtime.join(format!("cmux-tui-{uid}"));
    std::fs::create_dir_all(&session_dir).unwrap();
    std::fs::set_permissions(&session_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();

    let done = Arc::new(AtomicBool::new(false));
    let own_daemon = fake_daemon(&dir.join("own.sock"), done.clone());
    let other_daemon =
        fake_daemon(&session_dir.join(format!("{OTHER_SESSION}.sock")), done.clone());
    let app = fake_app(&dir.join("app.sock"), done.clone());

    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .arg("--app-socket")
        .arg(dir.join("app.sock"))
        .args(["mcp", "serve"])
        .env("HOME", &dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("CMUX_TUI_SOCKET", dir.join("own.sock"))
        .env("CMUX_TUI_TERMINAL_ID", PERSON_TERMINAL)
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(session) = agent_session {
        command.env("CMUX_AGENT_SESSION", session);
    }
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "cx-91xd", "version": "1"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "tab_create_browser",
            "arguments": {"session": OTHER_SESSION, "url": URL}}}),
    ] {
        writeln!(stdin, "{message}").unwrap();
    }
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    done.store(true, Ordering::Relaxed);
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let result = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|message| message["id"] == 2)
        .unwrap_or_else(|| panic!("no tools/call answer; stderr: {stderr}"))["result"]
        .clone();
    let finished = Finished {
        result,
        own_daemon: own_daemon.join().unwrap(),
        other_daemon: other_daemon.join().unwrap(),
        app: app.join().unwrap(),
    };
    let _ = std::fs::remove_dir_all(&dir);
    finished
}

/// Accepts connections until `done`, one thread each, answering every
/// request line with `answer` and recording it.
fn listen(
    socket: &Path,
    done: Arc<AtomicBool>,
    answer: fn(&Value) -> Value,
) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::new()));
    std::thread::spawn(move || {
        let mut connections = Vec::new();
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    let received = received.clone();
                    connections.push(std::thread::spawn(move || {
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut writer = stream;
                        let mut line = String::new();
                        while reader.read_line(&mut line).unwrap_or(0) > 0 {
                            let request: Value = serde_json::from_str(&line).unwrap();
                            line.clear();
                            let response = if request["cmd"] == "set-client-info" {
                                json!({"id": request["id"], "ok": true, "data": {}})
                            } else {
                                answer(&request)
                            };
                            received.lock().unwrap().push(request);
                            if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err()
                            {
                                break;
                            }
                        }
                    }));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if done.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept: {error}"),
            }
        }
        // A connection the server keeps open (the action watcher) ends with
        // its process; the ones that answered a call are done.
        drop(connections);
        std::mem::take(&mut *received.lock().unwrap())
    })
}

/// A session daemon that answers the reads a browser creation makes; any
/// other operation (a `terminal.get` for a terminal it does not have) fails.
fn fake_daemon(socket: &Path, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
    listen(socket, done, |request| {
        let params = &request["params"];
        let result = match request["operation"].as_str().unwrap_or_default() {
            "tab.get" if params["tab"] == NEW_TAB => Some(json!({"id": NEW_TAB, "pane_id": PANE,
                "content_kind": "browser", "content_id": NEW_BROWSER})),
            "pane.get" => Some(json!({"id": params["pane"], "screen_id": SCREEN})),
            "screen.get" => Some(json!({"id": params["screen"], "workspace_id": WORKSPACE})),
            _ => None,
        };
        match result {
            Some(result) => json!({"protocol": "cmux.protocol/2", "type": "response",
                "id": request["id"], "ok": true, "result": result}),
            None => json!({"protocol": "cmux.protocol/2", "type": "response",
                "id": request["id"], "ok": false, "error": {"code": "resource.not_found",
                "message": format!("unexpected {request}"), "details": {}, "retryable": false}}),
        }
    })
}

/// An app control socket whose waited `openBrowser` creates `NEW_TAB`; it
/// refuses its event stream, so the server's action watcher backs off.
fn fake_app(socket: &Path, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
    listen(socket, done, |request| {
        let params = &request["params"];
        if request["method"] != "action.run" {
            return json!({"id": request["id"], "ok": false, "error": {"code": "unavailable",
                "message": "not in this fake app", "data": {}}});
        }
        let created = if params["action"] == "openBrowser" && params["wait"] == true {
            json!([NEW_TAB])
        } else {
            json!([])
        };
        json!({"id": request["id"], "ok": true, "result": {"action": params["action"],
            "ran": true, "waited": true, "created": created, "replayed": false}})
    })
}
