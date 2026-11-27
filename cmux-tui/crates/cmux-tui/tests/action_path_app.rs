//! `cmux browser open-diff-viewer --path <dir>` against a fake app socket
//! (cx-ae75 follow-up): a relative `--path` names a folder of the caller's
//! working directory, so the app (whose own working directory is elsewhere)
//! must get it absolute. An agent runs `--path .` from its project folder.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Runs `cmux <args>` in `cwd` against a fake app that answers every
/// request `ok` and records it; returns the recorded `action.run` params.
fn action_run_params(args: &[&str], cwd: &Path) -> Value {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-actpath-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let done = Arc::new(AtomicBool::new(false));
    let received = Arc::new(Mutex::new(Vec::<Value>::new()));
    let app = {
        let (done, received) = (done.clone(), received.clone());
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
                            let response = json!({"id": request["id"], "ok": true, "result": {"ran": true, "created": []}});
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
        })
    };
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(&socket)
        .args(args)
        .current_dir(cwd)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let received = received.lock().unwrap();
    let run = received
        .iter()
        .find(|request| request["method"] == "action.run")
        .unwrap_or_else(|| panic!("no action.run sent: {received:?}"));
    run["params"].clone()
}

fn project() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-actpath-project-{stamp}"));
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    dir.canonicalize().unwrap()
}

#[test]
fn a_relative_diff_path_reaches_the_app_as_the_callers_folder() {
    let project = project();
    let params = action_run_params(&["browser", "open-diff-viewer", "--path", "."], &project);
    assert_eq!(params["args"]["path"], json!(project.to_string_lossy()), "{params}");
    let params = action_run_params(&["browser", "open-diff-viewer", "--path=sub"], &project);
    assert_eq!(params["args"]["path"], json!(project.join("sub").to_string_lossy()), "{params}");
    let _ = std::fs::remove_dir_all(&project);
}

#[test]
fn an_absolute_diff_path_is_sent_unchanged() {
    let project = project();
    let params = action_run_params(&["browser", "open-diff-viewer", "--path", "/tmp"], &project);
    assert_eq!(params["args"]["path"], json!("/tmp"), "{params}");
    let _ = std::fs::remove_dir_all(&project);
}
