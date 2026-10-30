//! JSON output for `acpmux hand pair`, including the stable exit-1 error
//! envelope. The pair endpoint is a loopback-only fake; no cloud is contacted.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::Value;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Output;
use std::thread::{self, JoinHandle};

struct Scratch {
    root: PathBuf,
    hand_home: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!("acpmux-hand-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let hand_home = root.join("hand");
        Self { root, hand_home }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// One local HTTP response for the pairing request. The request bytes are
/// returned so callers can inspect what would have gone to the cloud.
fn pair_server(
    status: u16,
    reason: &'static str,
    body: &'static str,
) -> (String, JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    let thread = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(std::time::Duration::from_secs(3))).unwrap();
        let mut request = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            let n = stream.read(&mut chunk).unwrap_or(0);
            if n == 0 {
                break;
            }
            request.extend_from_slice(&chunk[..n]);
            if request.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
        let response = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        request
    });
    (api, thread)
}

fn pair(scratch: &Scratch, api: &str, code: &str) -> Output {
    let root = scratch.root.to_string_lossy().into_owned();
    let mut cmd = daemon_env::command(&scratch.root, daemon_env::Agents::Deny, &[]);
    cmd.env("CMUX_HAND_HOME", &scratch.hand_home)
        .env("ACPMUX_HOME", scratch.root.join("acpmux"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(&scratch.root);
    cmd.args([
        "--json",
        "hand",
        "pair",
        code,
        "--api",
        api,
        "--profile",
        "sandbox",
        "--root",
        &root,
        "--name",
        "json-test-hand",
    ])
    .output()
    .expect("run acpmux hand pair")
}

fn json_stdout(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|e| {
        panic!(
            "stdout was not JSON ({e}):\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn hand_pair_json_prints_a_safe_success_summary() {
    let scratch = Scratch::new("ok");
    let (api, server) = pair_server(200, "OK", r#"{"ok":true,"value":{"hand":"hand_test"}}"#);
    let output = pair(&scratch, &api, "pair-code");
    let request = server.join().expect("pair server");

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let summary = json_stdout(&output);
    assert_eq!(summary["paired"], true);
    assert_eq!(summary["hand"], "hand_test");
    assert_eq!(summary["api"], api);
    assert_eq!(summary["profile"], "sandbox");
    assert_eq!(summary["agentPolicy"], "approve-edits");
    assert!(summary["config"].as_str().unwrap().ends_with("hand.json"));
    assert!(!request.is_empty());

    let config_path = scratch.hand_home.join("hand.json");
    let config: Value = serde_json::from_slice(&fs::read(config_path).unwrap()).unwrap();
    let key = config["key"].as_str().unwrap();
    assert!(!String::from_utf8_lossy(&output.stdout).contains(key));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(key));
}

#[test]
fn hand_pair_json_errors_use_exit_one_envelope() {
    let scratch = Scratch::new("error");
    let (api, server) = pair_server(
        400,
        "Bad Request",
        r#"{"ok":false,"error":{"message":"invalid pairing code"}}"#,
    );
    let output = pair(&scratch, &api, "bad-code");
    let _request = server.join().expect("pair server");

    assert_eq!(
        output.status.code(),
        Some(1),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(output.stdout.is_empty());
    let envelope: Value = serde_json::from_slice(&output.stderr).unwrap_or_else(|e| {
        panic!("stderr was not JSON ({e}): {}", String::from_utf8_lossy(&output.stderr))
    });
    assert_eq!(envelope["error"]["exit"], 1);
    assert_eq!(envelope["error"]["code"], "runtime");
    assert!(envelope["error"]["message"].as_str().unwrap().contains("pairing refused"));
}
