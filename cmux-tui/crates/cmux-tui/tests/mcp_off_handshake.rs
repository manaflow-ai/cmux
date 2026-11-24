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

/// The first answer of `cmux mcp serve` started with `env` and the settings in `settings`: the
/// `initialize` result's instructions, and how many tools `tools/list` offers.
fn serve_with(settings: &str, env: &[(&str, &str)]) -> (String, usize) {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux-next.json");
    std::fs::write(&config, settings).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["--app-socket", dir.path().join("no-app.sock").to_str().unwrap(), "mcp", "serve"])
        .env_clear()
        .env("HOME", dir.path())
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (key, value) in env {
        command.env(key, value);
    }
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut ask = |id: u64, method: &str, params: Value| -> Value {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
        let mut answer = String::new();
        stdout.read_line(&mut answer).unwrap();
        serde_json::from_str(&answer).unwrap()
    };
    let init = ask(1, "initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}}));
    let list = ask(2, "tools/list", json!({}));
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    (
        init["result"]["instructions"].as_str().unwrap_or_default().to_owned(),
        list["result"]["tools"].as_array().map(Vec::len).unwrap_or_default(),
    )
}

/// An agent chat follows the setting: a `cmux` entry an older cmux wrote into the person's own
/// Claude Code or Codex config starts `cmux mcp serve` in every chat, with the chat's
/// `CMUX_AGENT_SESSION`, and while `agents.cmuxMcp` is off it is the off server. A Chief turn
/// (its preset's `CMUX_MCP_TOOLS`) is served either way, and with the setting on (the default) a
/// chat is served.
#[test]
fn an_agent_chat_gets_cmux_tools_unless_turned_off_and_the_chief_always() {
    let chat = [("CMUX_AGENT_SESSION", "chat-1")];
    let chief = [("CMUX_AGENT_SESSION", "chief-1"), ("CMUX_MCP_TOOLS", "agents_snapshot")];
    for settings in [r#"{"agents": {"cmuxMcp": "off"}}"#, r#"{"agents.cmuxMcp": "off"}"#] {
        let (instructions, tools) = serve_with(settings, &chat);
        assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{settings}: {instructions}");
        assert_eq!(tools, 1, "{settings}: the off server's one tool");
        let (instructions, _) = serve_with(settings, &chief);
        assert!(
            !instructions.contains("agents.cmuxMcp on --confirm"),
            "{settings}: {instructions}"
        );
    }
    for settings in [r#"{"agents": {"cmuxMcp": "on"}}"#, r#"{"agents": {"cmuxMcp": "ask"}}"#, "{}"]
    {
        let (instructions, _) = serve_with(settings, &chat);
        assert!(
            !instructions.contains("agents.cmuxMcp on --confirm"),
            "{settings}: {instructions}"
        );
    }
    // `"mcp": {"enabled": true}` does not override the setting off in a chat.
    let (instructions, _) =
        serve_with(r#"{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}"#, &chat);
    assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
}

/// A chat cmux-next started on another machine (a peer link, a Cloud VM, a headless daemon)
/// follows the answer of the Mac that started it: that Mac's daemon sends its `agents.cmuxMcp`
/// answer with the session, the peer runs the chat's harness with it as
/// `CMUX_AGENT_TOOLS_ANSWER`, and a `cmux mcp serve` the chat starts uses it over the peer's own
/// settings file. Without it (a chat started there) the peer's own answer applies.
#[test]
fn a_chat_started_from_another_mac_follows_that_macs_answer() {
    let off_here = r#"{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}"#;
    let on_here = r#"{"agents": {"cmuxMcp": "on"}}"#;
    let chat = |answer: &'static str| {
        [("CMUX_AGENT_SESSION", "chat-1"), ("CMUX_AGENT_TOOLS_ANSWER", answer)]
    };
    let (instructions, _) = serve_with(off_here, &chat("on"));
    assert!(!instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
    let (instructions, tools) = serve_with(on_here, &chat("off"));
    assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
    assert_eq!(tools, 1, "the off server's one tool");
    // A chat started on this machine: its own file.
    let (instructions, _) = serve_with(off_here, &[("CMUX_AGENT_SESSION", "chat-1")]);
    assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
    // `"mcp": {"enabled": false}` still turns it off for everyone.
    let (instructions, _) = serve_with(r#"{"mcp": {"enabled": false}}"#, &chat("on"));
    assert!(!instructions.is_empty() && instructions.contains("false"), "{instructions}");
}

/// A Codex started in a cmux terminal with the answer not on: the shim tells the person's own
/// stdio `cmux` entry `CMUX_AGENT_TOOLS_ANSWER=off`, and its `cmux mcp serve` follows that, as an
/// agent cmux started, over `"mcp": {"enabled": true}` (which serves a caller outside cmux).
#[test]
fn a_terminal_codex_s_own_entry_follows_the_answer_the_shim_gives_it() {
    let file = r#"{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}"#;
    let (instructions, tools) = serve_with(file, &[("CMUX_AGENT_TOOLS_ANSWER", "off")]);
    assert!(instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
    assert_eq!(tools, 1, "the off server's one tool");
    // Without it, a caller outside cmux follows `mcp.enabled`.
    let (instructions, _) = serve_with(file, &[]);
    assert!(!instructions.contains("agents.cmuxMcp on --confirm"), "{instructions}");
}
