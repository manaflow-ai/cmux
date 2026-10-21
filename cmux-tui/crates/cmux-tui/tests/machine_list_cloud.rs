//! `cmux machine list` lists the cmux Cloud machines the app knows: the
//! daemon's catalog only takes `machine_<hex>` ids, so the CLI adds the app's
//! `cloud.machines` rows (`kind: "cloud"`) after the daemon's, which stay as
//! the daemon sent them. Without an app the daemon's list prints alone, with
//! a note on stderr. A fake daemon and a fake app socket stand in for both.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const LOCAL: &str = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn local_row() -> Value {
    json!({"id": LOCAL, "name": "local", "origin": "local", "status": "running",
           "connectable": true, "deleted": false, "recoverable": false})
}

fn temp_dir(label: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{label}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A fake daemon that answers every request with `[local_row()]`.
fn fake_daemon(socket: &Path, done: Arc<AtomicBool>) -> std::thread::JoinHandle<Vec<Value>> {
    serve(socket, done, |request| {
        json!({"protocol": "cmux.protocol/2", "type": "response", "id": request["id"],
               "ok": true, "result": [local_row()]})
    })
}

/// A fake app whose `cloud.machines` lists one running Cloud machine.
fn fake_app(socket: &Path, done: Arc<AtomicBool>) -> std::thread::JoinHandle<Vec<Value>> {
    serve(socket, done, |request| {
        let result = if request["method"] == "cloud.machines" {
            json!({"machines": [{"id": "vm-brave-otter", "title": "brave-otter", "status": "running",
                                 "daemon": "connected"}], "creations": []})
        } else {
            json!({"pong": true})
        };
        json!({"id": request["id"], "ok": true, "result": result})
    })
}

/// Answers each JSON line on `socket` with `answer`, on every connection,
/// until `done`; returns the requests.
fn serve(
    socket: &Path,
    done: Arc<AtomicBool>,
    answer: fn(&Value) -> Value,
) -> std::thread::JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::<Value>::new()));
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
                        let response = answer(&request);
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
                Err(error) => panic!("accept: {error}"),
            }
        }
        received.lock().unwrap().clone()
    })
}

/// `cmux-tui --json --socket <daemon> --app-socket <app> machine list`, with
/// a fake app when `with_app`; returns the output and the app's requests.
fn machine_list(with_app: bool) -> (Output, Vec<Value>) {
    let dir = temp_dir("mlcloud");
    let done = Arc::new(AtomicBool::new(false));
    let daemon_socket = dir.join("mux.sock");
    let app_socket = dir.join("app.sock");
    let daemon = fake_daemon(&daemon_socket, done.clone());
    let app = with_app.then(|| fake_app(&app_socket, done.clone()));
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--json")
        .arg("--socket")
        .arg(&daemon_socket)
        .arg("--app-socket")
        .arg(&app_socket)
        .args(["machine", "list"])
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    daemon.join().unwrap();
    let app_requests = app.map(|app| app.join().unwrap()).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.status.success(),
        "machine list: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    (output, app_requests)
}

#[test]
fn machine_list_adds_the_apps_cloud_machines() {
    let (output, app) = machine_list(true);
    assert!(app.iter().any(|request| request["method"] == "cloud.machines"), "{app:?}");
    let rows: Value = serde_json::from_slice(&output.stdout).expect("one JSON reply");
    let rows = rows.as_array().expect("machine list prints an array");
    assert_eq!(rows.len(), 2, "{rows:?}");
    assert_eq!(rows[0], local_row(), "the daemon's row changed");
    assert_eq!(rows[1]["id"], "vm-brave-otter");
    assert_eq!(rows[1]["name"], "brave-otter");
    assert_eq!(rows[1]["kind"], "cloud");
    assert_eq!(rows[1]["origin"], "cloud");
    assert_eq!(rows[1]["status"], "running");
    assert_eq!(rows[1]["connectable"], true);
    assert_eq!(rows[1]["target"], "machine:vm-brave-otter");
}

#[test]
fn machine_list_without_the_app_prints_the_daemons_rows_and_a_note() {
    let (output, _) = machine_list(false);
    let rows: Value = serde_json::from_slice(&output.stdout).expect("one JSON reply");
    assert_eq!(rows, json!([local_row()]));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Cloud"), "no note about the Cloud machines: {stderr}");
}
