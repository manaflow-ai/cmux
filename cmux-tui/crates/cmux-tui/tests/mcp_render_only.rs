//! `cmux mcp serve --render-only` over stdio, as an agent's MCP client runs
//! it: on with no `mcp.enabled` setting, offering `render` and nothing else.
#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// A `cmux` on a fresh home with no settings file.
struct Home {
    dir: PathBuf,
}

impl Home {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            std::env::temp_dir().join(format!("cmux-mcp-render-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        Self { dir }
    }

    /// Runs `cmux mcp serve <args>` with `requests` on stdin (one JSON-RPC
    /// message per line) and returns the messages it wrote on stdout.
    fn serve(&self, args: &[&str], requests: &[Value]) -> (bool, Vec<Value>, String) {
        let mut child = Command::new(self.dir.join("bin/cmux"))
            .args(["mcp", "serve"])
            .args(args)
            .env("HOME", &self.dir)
            .env("XDG_CONFIG_HOME", self.dir.join(".config"))
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        for request in requests {
            writeln!(stdin, "{request}").unwrap();
        }
        drop(stdin);
        let output = child.wait_with_output().unwrap();
        let messages = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        (output.status.success(), messages, String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn session() -> Vec<Value> {
    vec![
        serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                           "params": {"protocolVersion": "2025-03-26"}}),
        serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
    ]
}

#[test]
fn render_only_serves_render_alone_without_the_mcp_setting() {
    let home = Home::new();
    let (ok, messages, stderr) = home.serve(&["--render-only"], &session());
    assert!(ok, "{stderr}");
    let listed = messages.iter().find(|message| message["id"] == 2).expect("a tools/list answer");
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .expect("a tool list")
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["render"]);
}
