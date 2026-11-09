//! `wait_for_element` through `acpmux cua-mcp` as a real process: the bridge
//! lists it beside the helper's `get_window_state`, and a call checks the
//! tree again (with no screenshot) until the element appears or the
//! deadline passes. A stand-in helper (a Unix listener in this test process)
//! answers `get_window_state` with no matching element for the first reads.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Stdio};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SECRET: &str = "00112233445566778899aabbccddeeff";

struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str) -> Dir {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos();
        let path = PathBuf::from("/tmp").join(format!("acpw-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Dir(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A stand-in helper whose window shows a Save button from its read
/// number `appears_at` on (never, with `None`). Sends each
/// `get_window_state` request's arguments.
fn helper(dir: &Path, appears_at: Option<usize>) -> Receiver<Value> {
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let endpoint = dir.join("endpoint.json");
    std::fs::write(
        &endpoint,
        json!({"protocol": 1, "socket": socket, "secret": SECRET}).to_string(),
    )
    .unwrap();
    std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut reads = 0;
        // A reconnect gets a new connection; the read count goes on.
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut writer = stream.try_clone().unwrap();
            let mut lines = BufReader::new(stream).lines();
            let Some(Ok(_secret)) = lines.next() else { continue };
            writeln!(writer, "{}", json!({"ok": true, "protocol": 1})).unwrap();
            while let Some(Ok(line)) = lines.next() {
                let request: Value = serde_json::from_str(&line).unwrap();
                let result = match request["method"].as_str().unwrap() {
                    "machine/consent" => {
                        json!({"consentRequired": false, "consent": {"screen": "none", "control": "none"}})
                    }
                    "tools/list" => json!([
                        {"name": "get_window_state", "annotations": {"readOnlyHint": true}},
                        {"name": "click", "annotations": {"readOnlyHint": false}}
                    ]),
                    _ => {
                        assert_eq!(request["name"], "get_window_state", "{request}");
                        reads += 1;
                        let _ = tx.send(request["arguments"].clone());
                        let elements = if appears_at.is_some_and(|at| reads >= at) {
                            json!([
                                {"element_index": 0, "role": "AXWindow", "label": "Doc", "depth": 0},
                                {"element_index": 5, "element_token": "s00000009:5", "role": "AXButton", "label": "Save", "depth": 1}
                            ])
                        } else {
                            json!([])
                        };
                        json!({"content": [{"type": "text", "text": "window_id=4 pid=123"}],
                            "structuredContent": {"pid": 123, "window_id": 4, "elements": elements}})
                    }
                };
                writeln!(writer, "{}", json!({"id": request["id"], "ok": true, "result": result}))
                    .unwrap();
            }
        }
    });
    rx
}

struct Bridge {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    id: u64,
}

impl Bridge {
    fn start(dir: &Path) -> Bridge {
        let mut child = daemon_env::acpmux(dir)
            .arg("cua-mcp")
            .env("CMUX_NEXT_CUA_V2_DIR", dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Bridge { child, input, output, id: 0 }
    }

    fn send(&mut self, method: &str, params: Value) -> Value {
        self.id += 1;
        writeln!(
            self.input,
            "{}",
            json!({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params})
        )
        .unwrap();
        self.input.flush().unwrap();
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn wait_for_element_is_listed_and_returns_the_element_once_it_appears() {
    let dir = Dir::new("found");
    let reads = helper(&dir.0, Some(3));
    let mut bridge = Bridge::start(&dir.0);
    let listed = bridge.send("tools/list", json!({}));
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["get_window_state", "click", "wait_for_element"], "{listed}");

    let reply = bridge.send(
        "tools/call",
        json!({"name": "wait_for_element",
            "arguments": {"pid": 123, "window_id": 4, "query": "save", "role": "button", "interval_ms": 100}}),
    );
    let result = &reply["result"];
    assert_eq!(result.get("isError"), None, "{reply}");
    assert_eq!(result["structuredContent"]["timed_out"], false, "{reply}");
    assert_eq!(result["structuredContent"]["count"], 1, "{reply}");
    assert_eq!(result["structuredContent"]["checks"], 3, "{reply}");
    assert_eq!(result["structuredContent"]["elements"][0]["element_token"], "s00000009:5");
    let asked: Vec<Value> = reads.try_iter().collect();
    assert_eq!(asked.len(), 3);
    for arguments in asked {
        assert_eq!(
            arguments,
            json!({"pid": 123, "window_id": 4, "query": "save", "include_screenshot": false})
        );
    }
}

#[test]
fn wait_for_element_that_runs_out_says_timed_out_and_ends_at_its_deadline() {
    let dir = Dir::new("timeout");
    let _reads = helper(&dir.0, None);
    let mut bridge = Bridge::start(&dir.0);
    let started = Instant::now();
    let reply = bridge.send(
        "tools/call",
        json!({"name": "wait_for_element",
            "arguments": {"pid": 123, "window_id": 4, "query": "Save", "timeout_ms": 600}}),
    );
    let elapsed = started.elapsed();
    let result = &reply["result"];
    assert_eq!(result["isError"], true, "{reply}");
    assert_eq!(result["structuredContent"]["timed_out"], true, "{reply}");
    assert_eq!(result["structuredContent"]["count"], 0, "{reply}");
    assert!(result["content"][0]["text"].as_str().unwrap().starts_with("timed_out:"), "{reply}");
    assert!(elapsed >= Duration::from_millis(600), "{elapsed:?}");
    assert!(elapsed < Duration::from_secs(5), "{elapsed:?}");

    // A bad call names what it needs and reaches no helper read.
    let reply = bridge.send(
        "tools/call",
        json!({"name": "wait_for_element", "arguments": {"pid": 123, "window_id": 4}}),
    );
    assert_eq!(reply["result"]["isError"], true, "{reply}");
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("needs query, role or both")
    );
}
