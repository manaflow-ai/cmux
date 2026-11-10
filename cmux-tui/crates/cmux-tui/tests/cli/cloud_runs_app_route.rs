//! A sandboxed Run's steps reach the app that started the daemon (#39022 review, 2026-11-09).
//!
//! The daemon ran each Run's `cmux cloud …` children with `--socket <daemon socket>`. An app
//! command reads `--socket` as an app socket, pings it, and refuses a daemon's as
//! `socket.wrong_kind`, so every Run failed at its first list and its cleanup never ran. Here a
//! real headless daemon starts with `CMUX_SOCKET_PATH` naming a recording socket, the way the app
//! starts its daemon, and one `cloud.runs.create` must make the daemon's own child ask that socket
//! which account the Run is (a Run is the app's signed-in account, never the caller's claim). The
//! stand-in answers nothing, so the create is refused as not signed in: no Run starts on a guess.
//!
//! With Cloud turned off by an organization (#39022 review at 116d2aa1, F1) the app refuses its
//! Cloud verbs but still answers `auth.status`: a Run that exists is waited on and cancelled, never
//! refused as signed out.

use super::*;

use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

/// A socket standing in for the app: it records each connection's first line, then closes it.
struct App {
    path: PathBuf,
    lines: Arc<Mutex<Vec<String>>>,
}

impl App {
    fn bind(path: PathBuf) -> Self {
        let listener = UnixListener::bind(&path).unwrap();
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink = lines.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut line = String::new();
                let _ = BufReader::new(stream).read_line(&mut line);
                sink.lock().unwrap().push(line);
            }
        });
        Self { path, lines }
    }

    fn lines(&self) -> Vec<String> {
        self.lines.lock().unwrap().clone()
    }
}

#[test]
fn a_runs_steps_reach_the_app_that_started_the_daemon() {
    let base = unique_temp_dir("runs-app");
    let runtime = cmux_tui_core::platform::runtime_dir_for_base(&base);
    fs::create_dir_all(&runtime).unwrap();
    fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
    let state_dir = base.join("daemon");
    fs::create_dir_all(&state_dir).unwrap();
    let home = base.join("home");
    fs::create_dir_all(&home).unwrap();
    let app = App::bind(base.join("app.sock"));
    let socket = runtime.join("main.sock");
    let state = state_dir.join("state");
    let child = Command::new(bin())
        .args(["--headless", "--session", "main", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(&state)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", &base)
        .env("CMUX_TUI_CONFIG", state_dir.join("config.json"))
        .env("CMUX_SOCKET_PATH", &app.path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let daemon = HeadlessServer::adopt(child, socket.clone(), state, state_dir);
    daemon.wait_for_socket();

    let request = serde_json::json!({
        "call": "runs.create", "api": "https://cloud.invalid", "auth": "owner",
        "credential": "test-credential", "team": "team_1",
        "args": { "task": "say hi", "agent": "codex", "timeoutMs": 30_000, "idempotencyKey": "k-1" },
    });
    let mut cli = Command::new(bin())
        .arg("--socket")
        .arg(&socket)
        .args(["cloud", "api"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", &base)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    cli.stdin.take().unwrap().write_all(request.to_string().as_bytes()).unwrap();
    let output = cli.wait_with_output().unwrap();
    let answer: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "no answer: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    });
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error"]["code"], "run_not_signed_in", "{answer}");

    // The create's account read (`cloud list-machines`) reached the app's socket.
    let lines = app.lines();
    assert!(
        lines.iter().any(|line| !line.contains("system.ping") && !line.trim().is_empty()),
        "the app saw no Cloud request: {lines:?}\n{}",
        daemon.stderr_tail()
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&base);
}

/// A stand-in app with Cloud turned off by its organization: `auth.status` says who is signed in,
/// and every other request (the Cloud verbs a Run's start and cleanup run) is refused as
/// `feature.disabled`. Each method asked is kept.
struct PolicyOffApp {
    path: PathBuf,
    methods: Arc<Mutex<Vec<String>>>,
}

impl PolicyOffApp {
    fn bind(path: PathBuf) -> Self {
        let listener = UnixListener::bind(&path).unwrap();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let sink = methods.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let sink = sink.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        let Ok(request) = serde_json::from_str::<Value>(&line) else { return };
                        line.clear();
                        let method = request["method"].as_str().unwrap_or_default().to_owned();
                        let response = match method.as_str() {
                            "system.ping" => {
                                json!({"id": request["id"], "ok": true, "result": {"pong": true}})
                            }
                            "auth.status" => json!({"id": request["id"], "ok": true, "result": {
                                "signed_in": true, "restoring": false, "user_id": "u1", "team_id": "team_1",
                            }}),
                            _ => json!({"id": request["id"], "ok": false, "error": {
                                "code": "feature.disabled", "message": "Cloud is turned off by your organization",
                            }}),
                        };
                        sink.lock().unwrap().push(method);
                        if writeln!(writer, "{response}").is_err() {
                            return;
                        }
                    }
                });
            }
        });
        Self { path, methods }
    }
}

/// One `cmux cloud api` request to the daemon at `socket`: its answer line.
fn cloud_api(
    socket: &std::path::Path,
    home: &std::path::Path,
    base: &std::path::Path,
    request: &Value,
) -> Value {
    let mut cli = Command::new(bin())
        .arg("--socket")
        .arg(socket)
        .args(["cloud", "api"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("XDG_RUNTIME_DIR", base)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    cli.stdin.take().unwrap().write_all(request.to_string().as_bytes()).unwrap();
    let output = cli.wait_with_output().unwrap();
    serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "no answer: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn with_cloud_turned_off_a_run_that_exists_is_still_waited_on_and_cancelled() {
    let base = unique_temp_dir("runs-policy");
    let runtime = cmux_tui_core::platform::runtime_dir_for_base(&base);
    fs::create_dir_all(&runtime).unwrap();
    fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
    let state_dir = base.join("daemon");
    fs::create_dir_all(&state_dir).unwrap();
    let home = base.join("home");
    fs::create_dir_all(&home).unwrap();
    let app = PolicyOffApp::bind(base.join("app.sock"));
    let socket = runtime.join("main.sock");
    let state = state_dir.join("state");
    let child = Command::new(bin())
        .args(["--headless", "--session", "main", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(&state)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", &base)
        .env("CMUX_TUI_CONFIG", state_dir.join("config.json"))
        .env("CMUX_SOCKET_PATH", &app.path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let daemon = HeadlessServer::adopt(child, socket.clone(), state, state_dir);
    daemon.wait_for_socket();
    let call = |call: &str, args: Value| {
        let request = json!({
            "call": call, "api": "https://cloud.invalid", "auth": "owner",
            "credential": "test-credential", "team": "team_1", "args": args,
        });
        cloud_api(&socket, &home, &base, &request)
    };

    // The Run's account is the app's sign-in, read with Cloud off: the create is the person's.
    let created = call(
        "runs.create",
        json!({
            "task": "say hi", "agent": "codex", "timeoutMs": 30_000, "idempotencyKey": "k-policy",
            "expectedAccount": {"user_id": "u1", "team_id": "team_1"},
        }),
    );
    assert_eq!(created["ok"], true, "{created}\n{}", daemon.stderr_tail());
    let id = created["body"]["id"].as_str().expect("a Run id").to_owned();

    let waited = call("runs.wait", json!({"id": id, "timeoutMs": 2_000}));
    assert_eq!(waited["ok"], true, "a wait with Cloud off: {waited}");
    assert_eq!(waited["body"]["run"]["id"], id.as_str(), "{waited}");
    let cancelled = call("runs.cancel", json!({"id": id}));
    assert_eq!(cancelled["ok"], true, "a cancel with Cloud off: {cancelled}");

    let methods = app.methods.lock().unwrap().clone();
    assert!(methods.iter().any(|m| m == "auth.status"), "{methods:?}");
    drop(daemon);
    let _ = fs::remove_dir_all(&base);
}
