//! A Claude Code started in a terminal of a build on its own settings file
//! (a tagged DEV build, `CMUX_NEXT_CONFIG_FILE` in the terminal) gets cmux's
//! MCP server from the `claude` shim, with that settings file, and no global
//! entry anywhere: the shim's `--mcp-config` names the file, and the server it
//! runs serves cmux's tools (not the off server, not Computer Use only)
//! although the shared settings file says no.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

const CMUX: &str = env!("CARGO_BIN_EXE_cmux-tui");

#[test]
fn claude_in_a_dev_build_terminal_gets_cmux_with_its_settings_file_and_no_global_entry() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let bin = root.path().join("bin");
    let project = root.path().join("project");
    for dir in [&home, &bin, &project] {
        fs::create_dir_all(dir).unwrap();
    }
    // The shared file says no; the DEV build's own file says yes.
    fs::create_dir_all(home.join(".config/cmux")).unwrap();
    fs::write(home.join(".config/cmux/cmux-next.json"), r#"{"agents": {"cmuxMcp": "off"}}"#)
        .unwrap();
    let own = home.join(".config/cmux/cmux-next-cu-fresh.json");
    fs::write(&own, r#"{"agents": {"cmuxMcp": "on"}}"#).unwrap();
    let received = root.path().join("claude-args");
    let claude = bin.join("claude");
    fs::write(&claude, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", received.display()))
        .unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let socket = root.path().join("mux.sock");
    let _listener = UnixListener::bind(&socket).unwrap();

    // The terminal's environment, as the app now gives it (LaunchIdentity.terminalEnvironment).
    let status = Command::new(CMUX)
        .args(["agent", "claude-wrapper", "hi"])
        .current_dir(&project)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", &bin)
        .env("CMUX_TUI_SOCKET", &socket)
        .env("CMUX_TUI_TERMINAL_ID", "term_1")
        .env("CMUX_TAG", "cu-fresh")
        .env("CMUX_NEXT_CONFIG_FILE", &own)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(!home.join(".claude.json").exists(), "the launch wrote a global entry");

    let args = fs::read_to_string(&received).unwrap();
    let lines: Vec<&str> = args.lines().collect();
    let at = lines
        .iter()
        .position(|arg| *arg == "--mcp-config")
        .unwrap_or_else(|| panic!("no --mcp-config: {args}"));
    let config: Value = serde_json::from_str(lines[at + 1]).unwrap();
    let server = &config["mcpServers"]["cmux"];
    assert_eq!(server["env"]["CMUX_NEXT_CONFIG_FILE"], own.to_str().unwrap(), "{config}");
    assert_eq!(server["args"], json!(["mcp", "serve"]), "{config}");

    // The server Claude starts from that config, with only the config's env:
    // the full cmux server (it announces list changes), not the off server or
    // Computer Use only (neither does).
    let mut command = Command::new(server["command"].as_str().unwrap());
    command
        .args(server["args"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()))
        .env_clear()
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (key, value) in server["env"].as_object().unwrap() {
        command.env(key, value.as_str().unwrap());
    }
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2025-06-18", "capabilities": {}}});
    writeln!(stdin, "{init}").unwrap();
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    let answer: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(answer["result"]["capabilities"]["tools"]["listChanged"], true, "{answer}");
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();

    // The same launch without the terminal's settings file (the shared file,
    // `off`) passes no cmux server at all.
    fs::remove_file(&received).unwrap();
    let status = Command::new(CMUX)
        .args(["agent", "claude-wrapper", "hi"])
        .current_dir(&project)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", &bin)
        .env("CMUX_TUI_SOCKET", &socket)
        .env("CMUX_TUI_TERMINAL_ID", "term_1")
        .status()
        .unwrap();
    assert!(status.success());
    let args = fs::read_to_string(&received).unwrap();
    assert!(!args.lines().any(|arg| arg == "--mcp-config"), "{args}");
}
