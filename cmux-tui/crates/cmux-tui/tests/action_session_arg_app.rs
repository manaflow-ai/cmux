//! An app action whose argument is named `session` (`agent.openSessionWorkspace`)
//! run from `cmux` against a fake app socket: after `action run <id>` the
//! action's `--session` is its argument, not the global option that names a
//! daemon session (which swallowed it, so the app answered "requires
//! --session"), and `cmux agent open SESSION` opens an existing acpmux session
//! (one `cmux acp ensure` made) in a new workspace, the way scripts and
//! coordinators make a CLI-created session appear in the app.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Runs `cmux <args>` against a fake app that answers every request `ok` and
/// records it; returns the recorded `action.run` params.
fn action_run_params(args: &[&str]) -> Value {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-actsess-{}-{stamp}", std::process::id()));
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
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.status.success(),
        "cmux {args:?}: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let received = received.lock().unwrap();
    let run = received
        .iter()
        .find(|request| request["method"] == "action.run")
        .unwrap_or_else(|| panic!("cmux {args:?} sent no action.run: {received:?}"));
    run["params"].clone()
}

mod session_arg {
    use super::*;

    #[test]
    fn an_actions_session_argument_reaches_the_app() {
        const ID: &str = "agent.openSessionWorkspace";
        for args in [
            vec!["action", "run", ID, "--session", "sess-1", "--name", "x"],
            vec!["action", "run", ID, "--session=sess-1", "--name", "x"],
            vec!["action", "run", ID, "--", "--session", "sess-1", "--name", "x"],
        ] {
            let params = action_run_params(&args);
            assert_eq!(params["action"], ID, "{args:?}: {params}");
            assert_eq!(params["args"]["session"], "sess-1", "{args:?}: {params}");
            assert_eq!(params["args"]["name"], "x", "{args:?}: {params}");
        }
    }

    #[test]
    fn agent_open_opens_an_existing_session_in_a_workspace() {
        let params =
            action_run_params(&["agent", "open", "sess-1", "--name", "x", "--cwd", "/tmp"]);
        assert_eq!(params["action"], "agent open", "{params}");
        assert_eq!(params["cli"], true, "{params}");
        assert_eq!(
            params["args"],
            json!({"session": "sess-1", "name": "x", "cwd": "/tmp"}),
            "{params}"
        );
    }

    #[test]
    fn agent_open_tab_opens_an_existing_session_as_a_tab_of_a_pane() {
        let params = action_run_params(&["agent", "open-tab", "sess-1", "--target", "pane:pane_7"]);
        assert_eq!(params["action"], "agent open-tab", "{params}");
        assert_eq!(params["cli"], true, "{params}");
        assert_eq!(params["target"], "pane:pane_7", "{params}");
        assert_eq!(params["args"], json!({"session": "sess-1"}), "{params}");
    }
}
