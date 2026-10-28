//! A panic in `cmux mcp serve` must never be lost.
//! The MCP client drops the server's stderr, so the server appends each
//! panic to `mcp-panics.jsonl` at the state root and keeps serving; the
//! cmux-next app sends new lines to Sentry.

#![cfg(all(unix, debug_assertions))]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[test]
fn mcp_serve_panic_log_gets_one_line_and_the_server_keeps_answering() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-mcpp-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["mcp", "serve"])
        .env("HOME", &dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_SOCKET", dir.join("none.sock"))
        .env("CMUX_TUI_TEST_MCP_PANIC", "thread")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_MUX_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let log = dir.join("state").join("mcp-panics.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    let text = loop {
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        if text.ends_with('\n') {
            break text;
        }
        assert!(child.try_wait().unwrap().is_none(), "the server exited after a worker panic");
        assert!(Instant::now() < deadline, "no MCP panic line at {}", log.display());
        std::thread::sleep(Duration::from_millis(20));
    };

    // The panic ended only its own thread: the server still answers.
    let mut stdin = child.stdin.take().unwrap();
    let initialize = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "p09-099", "version": "1"}}});
    writeln!(stdin, "{initialize}").unwrap();
    let mut reply = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut reply).unwrap();
    drop(stdin);
    let status = child.wait().unwrap();
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&log).unwrap().permissions().mode() & 0o777
    };
    let _ = std::fs::remove_dir_all(&dir);

    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    let record: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(record["process"], "cmux-mcp", "{record}");
    assert_eq!(record["message"], "cmux mcp serve test panic", "{record}");
    assert_eq!(record["thread"], "mcp-panic-test", "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    assert_eq!(mode, 0o600);
    let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["id"], 1, "{reply}");
    assert!(reply.get("result").is_some(), "{reply}");
    assert!(status.success(), "the server ends cleanly when stdin closes: {status}");
}
