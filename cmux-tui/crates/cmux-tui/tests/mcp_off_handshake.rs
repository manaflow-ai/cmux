//! `cmux mcp serve` started by a coding agent while cmux's tools are off for
//! it (the settings file it reads has `agents.cmuxMcp` off): the server
//! completes the MCP handshake and says why, instead of exiting before
//! `initialize`, which Claude Code showed only as CONNECTION_CLOSED (tag
//! cu-fresh, 2026-11-13). No tool runs.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use serde_json::{Value, json};

#[test]
fn cmux_mcp_serve_while_off_completes_the_handshake_and_names_the_setting() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux-next.json");
    std::fs::write(&config, r#"{"agents": {"cmuxMcp": "off"}}"#).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--app-socket", dir.path().join("no-app.sock").to_str().unwrap(), "mcp", "serve"])
        .env_clear()
        .env("HOME", dir.path())
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut ask = |id: u64, method: &str, params: Value| -> Value {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
        let mut answer = String::new();
        stdout.read_line(&mut answer).unwrap();
        assert!(!answer.is_empty(), "the server closed the connection on {method}");
        serde_json::from_str(&answer).unwrap()
    };
    let init = ask(1, "initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}}));
    let instructions = init["result"]["instructions"].as_str().unwrap_or_default().to_owned();
    assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{init}");
    let list = ask(2, "tools/list", json!({}));
    assert_eq!(list["result"]["tools"].as_array().map(Vec::len), Some(1), "{list}");
    let call = ask(3, "tools/call", json!({"name": "workspace_list", "arguments": {}}));
    assert_eq!(call["result"]["isError"], true, "{call}");
    assert_eq!(call["result"]["structuredContent"]["error"]["code"], "mcp.disabled", "{call}");
    drop(stdin);
    let status = child.wait().unwrap();
    assert!(status.success(), "{status}");
}
