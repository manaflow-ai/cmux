//! The host binary's command line. One MCP entry point (decision
//! BROWSER-MCP-ENTRY, 2026-10-04): `cmux mcp serve`, which cmux.json turns
//! on; the host binary has no MCP server of its own.

use std::process::{Command, Stdio};

#[test]
fn the_host_binary_refuses_mcp_and_names_cmux_mcp_serve() {
    let dir = std::env::temp_dir().join(format!("cmux-host-cli-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .arg("mcp")
        .env("CMUX_BROWSER_HOST_SOCKET", dir.join("host.sock"))
        .stdin(Stdio::null())
        .output()
        .expect("run cmux-browser-host mcp");
    let _ = std::fs::remove_dir_all(&dir);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "stderr: {stderr}");
    assert!(stderr.contains("cmux mcp serve"), "stderr: {stderr}");
    assert!(out.stdout.is_empty(), "no MCP traffic: {}", String::from_utf8_lossy(&out.stdout));
}
