//! `cmux workspace new-on-machine --machine <id>` run against a fake app
//! socket: the action's own `--machine` reaches the app as its `machine`
//! argument (the global option swallowed it, so the app answered "requires
//! --machine"), a `--machine` before the action's words stays the global
//! option, and the reply carries the workspace the app made (its id, name and
//! machine), which the CLI prints as the app answered it.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const WORKSPACE: &str = "ws_0123456789abcdef0123456789abcdef";

/// The reply of an app whose `workspace.newOnMachine` made a workspace.
fn created_reply(args: &Value) -> Value {
    // The app resolves the `machine:` target to the machine's id.
    let machine = args["machine"].as_str().map_or("local", |m| m.trim_start_matches("machine:"));
    json!({
        "action": "workspace.newOnMachine",
        "ran": true,
        "waited": true,
        "args": args,
        "created": [WORKSPACE],
        "result": { "workspace_id": WORKSPACE, "name": "Workspace 2", "machine_id": machine },
    })
}

/// Runs `cmux --app-socket <fake> <args>` against a fake app that answers
/// every `action.run` with [`created_reply`]; returns the CLI's output and
/// the recorded `action.run` params.
fn run(args: &[&str]) -> (Output, Value) {
    // Parallel tests in this process can read the same clock tick (seen on Linux CI:
    // bind "Address already in use"), so a per-process counter keeps each socket distinct.
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let serial = NEXT.fetch_add(1, Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-actmach-{}-{serial}-{stamp}", std::process::id()));
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
                            let result = if request["method"] == "action.run" {
                                created_reply(&request["params"]["args"])
                            } else {
                                json!({ "pong": true })
                            };
                            let response =
                                json!({"id": request["id"], "ok": true, "result": result});
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
    let params = received
        .iter()
        .find(|request| request["method"] == "action.run")
        .unwrap_or_else(|| panic!("cmux {args:?} sent no action.run: {received:?}"))["params"]
        .clone();
    (output, params)
}

/// One filter (`own_machine_flag`) runs these and the parser's unit test.
mod own_machine_flag {
    use super::*;

    #[test]
    fn new_on_machine_gets_its_own_machine_flag() {
        for args in [
            vec!["--json", "workspace", "new-on-machine", "--machine", "machine:vm-1"],
            vec!["--json", "workspace", "new-on-machine", "--machine=machine:vm-1"],
            vec!["workspace", "new-on-machine", "--machine", "machine:vm-1", "--json"],
        ] {
            let (_, params) = run(&args);
            assert_eq!(params["action"], "workspace new-on-machine", "{args:?}: {params}");
            assert_eq!(params["cli"], true, "{args:?}: {params}");
            assert_eq!(params["args"], json!({ "machine": "machine:vm-1" }), "{args:?}: {params}");
        }
    }

    #[test]
    fn a_machine_flag_before_the_action_stays_global() {
        let (_, params) = run(&["--json", "--machine", "vm-1", "workspace", "new-on-machine"]);
        assert_eq!(params["action"], "workspace new-on-machine", "{params}");
        assert!(params.get("args").is_none(), "the global --machine became an argument: {params}");
    }

    #[test]
    fn new_on_machine_prints_the_workspace_it_created() {
        let (output, _) =
            run(&["--json", "workspace", "new-on-machine", "--machine", "machine:vm-1"]);
        let reply: Value = serde_json::from_slice(&output.stdout).expect("one JSON reply");
        assert_eq!(reply["created"], json!([WORKSPACE]), "{reply}");
        assert_eq!(reply["result"]["workspace_id"], WORKSPACE, "{reply}");
        assert_eq!(reply["result"]["name"], "Workspace 2", "{reply}");
        assert_eq!(reply["result"]["machine_id"], "vm-1", "{reply}");
    }
}
