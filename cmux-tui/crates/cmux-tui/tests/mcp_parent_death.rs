//! An agent's MCP servers end with the agent, also while another process
//! still holds their stdin open (ask-25170f5ee5, `acpmux::parent_watch`):
//! `cmux mcp serve`, the servers folded behind it, and acpmux's own servers
//! spawned straight under a harness.
//!
//! Each test starts the server under a shell that stands in for the
//! harness, keeps the server's stdin open itself, and kills the shell. The
//! server and its children share the shell's stderr; its EOF means all of
//! them exited.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const CMUX: &str = env!("CARGO_BIN_EXE_cmux-tui");

#[test]
fn cmux_mcp_serve_and_its_folded_server_end_with_the_agent() {
    let dir = scratch("serve");
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let upstreams = json!([{
        "name": "cmux-forum",
        "command": CMUX,
        "args": ["acp", "forum-mcp"],
        "env": {"ACPMUX_SESSION_ID": "acp_parent_death"},
    }]);
    let mut agent = Agent::start(
        &dir,
        &["--app-socket", dir.join("no-app.sock").to_str().unwrap(), "mcp", "serve", "--all-tools"],
        &[
            ("CMUX_NEXT_CONFIG_FILE", config.to_str().unwrap()),
            ("CMUX_MCP_UPSTREAMS", &upstreams.to_string()),
        ],
    );
    agent.ask("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}}));
    // With no stored list (a fresh HOME), listing starts the folded server.
    let tools = agent.ask("tools/list", json!({}));
    assert!(
        tools["result"]["tools"].as_array().unwrap().iter().any(|t| t["name"] == "forum_rules"),
        "the folded forum server did not start: {tools}"
    );
    agent.die_and_expect_servers_gone();
}

#[test]
fn acpmux_servers_end_with_the_agent() {
    for verb in ["forum-mcp", "subsession-mcp", "acpmux-mcp"] {
        let dir = scratch(verb);
        let mut agent =
            Agent::start(&dir, &["acp", verb], &[("ACPMUX_SESSION_ID", "acp_parent_death")]);
        agent.ask("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}}));
        agent.die_and_expect_servers_gone();
    }
}

/// A shell standing in for the harness, with the server as its child.
struct Agent {
    shell: Child,
    stdin: ChildStdin,
    stdout: mpsc::Receiver<String>,
    stderr_closed: mpsc::Receiver<()>,
    next_id: u64,
}

impl Agent {
    fn start(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> Self {
        let mut shell = Command::new("/bin/sh")
            .arg("-c")
            // A background job's stdin would be /dev/null; fd 3 keeps the pipe.
            .arg(r#"exec 3<&0; "$@" <&3 3<&- & wait"#)
            .arg("sh")
            .arg(CMUX)
            .args(args)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", dir)
            .env("ACPMUX_HOME", dir.join("acpmux"))
            .env("LC_ALL", "C")
            .envs(env.iter().copied())
            .current_dir(dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = shell.stdin.take().unwrap();
        let (tx, stdout) = mpsc::channel();
        let out = BufReader::new(shell.stdout.take().unwrap());
        std::thread::spawn(move || {
            for line in out.lines().map_while(Result::ok) {
                let _ = tx.send(line);
            }
        });
        let (closed, stderr_closed) = mpsc::channel();
        let mut err = BufReader::new(shell.stderr.take().unwrap());
        std::thread::spawn(move || {
            let _ = std::io::copy(&mut err, &mut std::io::stderr());
            let _ = closed.send(());
        });
        Self { shell, stdin, stdout, stderr_closed, next_id: 1 }
    }

    fn ask(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stdin, "{request}").unwrap();
        self.stdin.flush().unwrap();
        loop {
            let line = self.stdout.recv_timeout(Duration::from_secs(30)).unwrap();
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply["id"] == id {
                return reply;
            }
        }
    }

    /// Kills the shell while this test keeps the server's stdin open.
    fn die_and_expect_servers_gone(mut self) {
        self.shell.kill().unwrap();
        self.shell.wait().unwrap();
        let gone = self.stderr_closed.recv_timeout(Duration::from_secs(20)).is_ok();
        drop(self.stdin);
        assert!(gone, "a server outlived its agent with stdin still open");
    }
}

fn scratch(name: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        std::env::temp_dir().join(format!("cmux-mcp-pd-{name}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
