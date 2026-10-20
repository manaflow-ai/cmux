//! `acpmux --json transfer` as an app runs it: a refusal the app shows in its own words comes
//! with a stable `detail` and its data, not only acpmux's text.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        let mut rpc = Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "transfer-cli-test"}});
        rpc.call("initialize", hello).await;
        rpc
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("send");
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .expect("read")
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).expect("json line");
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// A daemon in its own home, with the test agent as harness `fake`; killed on drop.
struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: std::process::Child,
}

impl Daemon {
    async fn start(tag: &str) -> Self {
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("home");
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"});
        std::fs::write(home.join("config.json"), config.to_string()).expect("config");
        let socket = home.join("s.sock");
        let child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            // No agent hosts: a host outlives its daemon, and this test kills only the daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while tokio::net::UnixStream::connect(&socket).await.is_err() {
            assert!(tokio::time::Instant::now() < deadline, "daemon {tag} never listened");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        Self { home, socket, child }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

#[tokio::test]
async fn a_chat_whose_folder_is_missing_on_the_target_is_refused_with_a_reason_the_app_can_name() {
    let (a, b) = (Daemon::start("xfa").await, Daemon::start("xfb").await);
    let folder = PathBuf::from("/tmp").join(format!("amx-xff-{}", std::process::id()));
    std::fs::create_dir_all(&folder).expect("folder");
    let mut src = Rpc::connect(&a.socket).await;
    let made = src.call("session/new", json!({"cwd": folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().expect("session id").to_owned();
    // The chat's folder is not on the target (here: gone from this machine).
    std::fs::remove_dir_all(&folder).expect("remove folder");

    let out = daemon_env::tokio_command(&a.home, daemon_env::Agents::Deny)
        .args(["--json", "transfer", &id, "--to"])
        .arg(&b.socket)
        .env("ACPMUX_HOME", &a.home)
        .env("ACPMUX_SOCKET", &a.socket)
        .output()
        .await
        .expect("run acpmux transfer");
    assert!(!out.status.success(), "the move must be refused");
    let stderr = String::from_utf8_lossy(&out.stderr);
    let last = stderr.lines().last().unwrap_or_default();
    let envelope: Value = serde_json::from_str(last).unwrap_or_else(|_| panic!("{stderr}"));
    assert_eq!(envelope["error"]["detail"], "cwd_missing", "{envelope}");
    assert_eq!(envelope["error"]["data"]["cwd"], folder.to_string_lossy().as_ref(), "{envelope}");

    // The chat stays on the source, not frozen.
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
    assert_eq!(info["moving"], false, "{info}");
}
