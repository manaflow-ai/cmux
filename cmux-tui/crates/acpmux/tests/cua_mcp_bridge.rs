//! `acpmux cua-mcp` (the Computer Use helper v2 bridge, `cua_v2.rs`) as a
//! real process: it reads `endpoint.json` from `CMUX_NEXT_CUA_V2_DIR`,
//! connects to the helper socket named there, and sends the per-launch
//! secret first. A stand-in helper (a Unix listener in this test process)
//! records what reaches it.
//!
//! The bridge must not trust an `endpoint.json` that another user could have
//! written or read (fleet Macs run several slot users on one Mac): with a
//! group- or world-accessible file it refuses before it connects, so no
//! secret reaches any socket. A private file of this user connects, the
//! peer uid (this test's own) passes, and the secret is sent.
//! The other-user socket case needs a second account (bead cx-8coo).
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SECRET: &str = "00112233445566778899aabbccddeeff";

struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str) -> Dir {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos();
        let path = PathBuf::from("/tmp").join(format!("acpx-{tag}-{}-{nanos}", std::process::id()));
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

/// Writes endpoint.json with `mode` and starts a stand-in helper on `h.sock`
/// that records the first line it gets and answers the MCP bridge.
fn stand_in(dir: &Path, mode: u32) -> std::sync::mpsc::Receiver<String> {
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let endpoint = dir.join("endpoint.json");
    std::fs::write(
        &endpoint,
        json!({"protocol": 1, "socket": socket, "secret": SECRET}).to_string(),
    )
    .unwrap();
    std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(mode)).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
        let mut writer = stream.try_clone().unwrap();
        let mut lines = BufReader::new(stream).lines();
        let Some(Ok(first)) = lines.next() else { return };
        let _ = tx.send(first);
        writeln!(writer, "{}", json!({"ok": true, "protocol": 1})).unwrap();
        while let Some(Ok(line)) = lines.next() {
            let request: Value = serde_json::from_str(&line).unwrap();
            let reply = json!({"id": request["id"], "ok": true,
                "result": [{"name": "stand_in_tool", "inputSchema": {"type": "object"}}]});
            writeln!(writer, "{reply}").unwrap();
        }
    });
    rx
}

/// Runs `acpmux cua-mcp` for one `tools/list` and returns its reply.
fn tools_list(dir: &Path) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .arg("cua-mcp")
        .env("CMUX_NEXT_CUA_V2_DIR", dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).unwrap();
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    serde_json::from_str(text.lines().next().expect("a reply line")).unwrap()
}

#[test]
fn an_endpoint_file_other_users_can_read_is_refused_before_any_secret_is_sent() {
    let dir = Dir::new("open");
    let received = stand_in(&dir.0, 0o644);
    let reply = tools_list(&dir.0);
    let message = reply["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("not private to this user"), "reply: {reply}");
    assert!(
        received.recv_timeout(Duration::from_millis(500)).is_err(),
        "the bridge connected and sent a line to the socket"
    );
}

#[test]
fn a_private_endpoint_file_of_this_user_reaches_the_helper_with_the_secret() {
    let dir = Dir::new("private");
    let received = stand_in(&dir.0, 0o600);
    let reply = tools_list(&dir.0);
    assert_eq!(reply["result"]["tools"][0]["name"], "stand_in_tool", "reply: {reply}");
    let first: Value =
        serde_json::from_str(&received.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    assert_eq!(first, json!({"secret": SECRET}));
}
