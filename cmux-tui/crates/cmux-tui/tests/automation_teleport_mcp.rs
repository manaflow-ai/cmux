//! The MCP `automation_*` tools through the real `cmux-tui mcp serve`
//! (docs/automations-teleport-teams.md, section 5): they run the same code as
//! `cmux automation …`, so a create, list, pause, resume, get, runs, teleport
//! refusal and delete land in the same local store the CLI reads.
#![cfg(unix)]

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

#[test]
fn teleport_mcp_automation_tools_run_the_cli_code_on_the_local_store() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let dir = PathBuf::from(format!("/tmp/cmux-tpm-{}-{stamp}", std::process::id()));
    let runtime = dir.join("rt");
    std::fs::create_dir_all(&runtime).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let store = dir.join("store");

    let calls = [
        ("automation_create", json!({"name": "Nightly", "command": "echo hi", "daily": "23:00"})),
        ("automation_list", json!({})),
        ("automation_pause", json!({"automation": "Nightly"})),
        ("automation_get", json!({"automation": "nightly", "target": "local"})),
        (
            "automation_resume",
            json!({"automation": "Nightly", "idempotency_key": "mcp-test-resume"}),
        ),
        ("automation_runs", json!({"automation": "Nightly"})),
        ("automation_teleport", json!({"automation": "Nightly", "to": "cloud"})),
        ("automation_list", json!({"target": "mars"})),
        ("automation_delete", json!({"automation": "Nightly"})),
        ("automation_audit", json!({"target": "cloud"})),
    ];
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(dir.join("app.sock"))
        .args(["mcp", "serve"])
        .env("HOME", &dir)
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("CMUX_AUTOMATIONS_DIR", &store)
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("CMUX_TUI_SOCKET", dir.join("own.sock"))
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "automation-tools", "version": "1"}}})
    )
    .unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        .unwrap();
    for (index, (name, arguments)) in calls.iter().enumerate() {
        writeln!(
            stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": index + 1, "method": "tools/call",
                   "params": {"name": name, "arguments": arguments}})
        )
        .unwrap();
    }
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let answers: Vec<Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect();
    let result = |id: usize| -> Value {
        answers
            .iter()
            .find(|m| m["id"] == id)
            .unwrap_or_else(|| panic!("no answer to call {id}; stderr: {stderr}"))["result"]
            .clone()
    };
    let ok = |id: usize| -> Value {
        let r = result(id);
        assert_eq!(r["isError"], false, "call {id}: {r}");
        r["structuredContent"].clone()
    };

    let made = ok(1);
    let id = made["id"].as_str().unwrap_or_else(|| panic!("{made}")).to_string();
    assert!(id.starts_with("auto_"));
    assert_eq!(made["epoch"], 1);
    let listed = ok(2);
    assert_eq!(listed["automations"][0]["id"], id.as_str(), "{listed}");
    assert_eq!(ok(3)["enabled"], false);
    assert_eq!(ok(4)["id"], id.as_str());
    assert_eq!(ok(5)["enabled"], true);
    assert!(ok(6)["runs"].is_array());
    let teleport = result(7);
    assert_eq!(teleport["isError"], true, "{teleport}");
    assert!(
        teleport.to_string().contains("a shell command needs a machine"),
        "the CLI's refusal: {teleport}"
    );
    assert_eq!(result(8)["isError"], true, "a bad target is refused");
    assert_eq!(ok(9)["deleted"], id.as_str());
    // No cmux app here: the Cloud audit read reaches the CLI and fails there.
    let audit = result(10);
    assert_eq!(audit["isError"], true, "{audit}");
    assert!(!audit.to_string().contains("unknown tool"), "{audit}");

    // The CLI sees what the tools did.
    let list = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "automation", "list"])
        .env("HOME", &dir)
        .env("CMUX_AUTOMATIONS_DIR", &store)
        .output()
        .unwrap();
    let list: Value = serde_json::from_slice(&list.stdout).unwrap();
    assert_eq!(list["automations"], json!([]));
    let _ = std::fs::remove_dir_all(&dir);
}
