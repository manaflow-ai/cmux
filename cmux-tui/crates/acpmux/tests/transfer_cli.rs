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
        Self::with_peer(tag, None).await
    }

    async fn with_peer(tag: &str, target: Option<&Daemon>) -> Self {
        Self::with_env(tag, target, json!({}), &[], "approve-all").await
    }

    /// The same, with the test agent under the harness name `harness`.
    async fn with_harness(tag: &str, target: Option<&Daemon>, harness: &str) -> Self {
        let peer = target.map(|target| (target.home.clone(), target.socket.clone()));
        Self::spawn_as(tag, peer, json!({}), harness).await
    }

    /// `with_peer`, with `harness_env` in the fake harness's env, `vars` in the daemon's, and
    /// `policy` its permission policy.
    async fn with_env(
        tag: &str,
        target: Option<&Daemon>,
        harness_env: Value,
        vars: &[(&str, &str)],
        policy: &str,
    ) -> Self {
        let peer = target.map(|target| (target.home.clone(), target.socket.clone()));
        Self::spawn_full(tag, peer, harness_env, "fake", false, None, vars, policy).await
    }

    /// Where the daemon tagged `tag` lives, known before it starts (two daemons that are each
    /// other's peer name each other's socket first).
    fn place(tag: &str) -> (PathBuf, PathBuf) {
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-{tag}-{}", std::process::id()));
        let socket = home.join("s.sock");
        (home, socket)
    }

    /// A daemon whose peer `target` is the daemon at `peer` (home, socket), its agent started
    /// with `agent_env`.
    async fn spawn(tag: &str, peer: Option<(PathBuf, PathBuf)>, agent_env: Value) -> Self {
        Self::spawn_inner(tag, peer, agent_env, "fake", false, None).await
    }

    /// [`Self::spawn`], with the test agent under the harness name `harness`.
    async fn spawn_as(
        tag: &str,
        peer: Option<(PathBuf, PathBuf)>,
        agent_env: Value,
        harness: &str,
    ) -> Self {
        Self::spawn_inner(tag, peer, agent_env, harness, false, None).await
    }

    /// [`Self::spawn`]; `linked`: it serves its WebSocket port too, so the daemon whose peer
    /// it is holds a live link to it (`session_move::fake_ssh` carries the link).
    async fn spawn_with(
        tag: &str,
        peer: Option<(PathBuf, PathBuf)>,
        agent_env: Value,
        linked: bool,
    ) -> Self {
        Self::spawn_inner(tag, peer, agent_env, "fake", linked, None).await
    }

    async fn spawn_inner(
        tag: &str,
        peer: Option<(PathBuf, PathBuf)>,
        agent_env: Value,
        harness: &str,
        linked: bool,
        link: Option<(u16, u16, u64)>,
    ) -> Self {
        Self::spawn_full(tag, peer, agent_env, harness, linked, link, &[], "approve-all").await
    }

    /// [`Self::spawn_inner`], with `vars` in the daemon's env and `policy` its permission policy.
    #[allow(clippy::too_many_arguments)]
    async fn spawn_full(
        tag: &str,
        peer: Option<(PathBuf, PathBuf)>,
        agent_env: Value,
        harness: &str,
        linked: bool,
        link: Option<(u16, u16, u64)>,
        vars: &[(&str, &str)],
        policy: &str,
    ) -> Self {
        let (home, socket) = Self::place(tag);
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("home");
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        // `FAMILY` in `agent_env` is not the agent's environment: it is the profile's `family`
        // (`claude`, `codex`), which names the native store the chat's files travel from.
        let mut agent_env = agent_env;
        let family = agent_env.as_object_mut().and_then(|env| env.remove("FAMILY"));
        let mut profile = json!({"argv": ["python3", fake], "env": agent_env});
        if let Some(family) = family {
            profile["family"] = family;
        }
        let mut config = json!({"harnesses": {harness: profile}, "defaultHarness": harness, "permissionPolicy": policy});
        if linked {
            let free = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
            let listen = free.local_addr().expect("its address").to_string();
            config["websocket"] = json!({"listen": listen, "token": format!("token-{tag}")});
        }
        let path = peer.map(|(peer_home, peer_socket)| {
            config["peers"] = json!({"target": {"url": "ssh://target"}});
            let link = link.map(|(_, port, delay)| (port, delay));
            session_move::fake_ssh(&home, &peer_home, &peer_socket, link)
        });
        if let Some((port, ..)) = link {
            config["websocket"] =
                json!({"listen": format!("127.0.0.1:{port}"), "token": "5a".repeat(32)});
        }
        std::fs::write(home.join("config.json"), config.to_string()).expect("config");
        let mut command = daemon_env::command(&home, daemon_env::Agents::StandIn, &[]);
        if let Some(path) = path {
            command.env("PATH", path);
        }
        let child = command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            // No agent hosts: a host outlives its daemon, and this test kills only the daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .envs(vars.iter().copied())
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

#[path = "transfer_cli/composer_attachments.rs"]
mod composer_attachments;
#[path = "transfer_cli/first_turn_fence.rs"]
mod first_turn_fence;
#[path = "transfer_cli/move_matrix.rs"]
mod move_matrix;
#[path = "transfer_cli/session_move.rs"]
mod session_move;
#[path = "transfer_cli/session_move_as.rs"]
mod session_move_as;

#[path = "transfer_cli/session_move_ask.rs"]
mod session_move_ask;
#[path = "transfer_cli/session_move_follow.rs"]
mod session_move_follow;
#[path = "transfer_cli/session_move_history.rs"]
mod session_move_history;
#[path = "transfer_cli/session_move_live.rs"]
mod session_move_live;
#[path = "transfer_cli/session_move_reachable.rs"]
mod session_move_reachable;
#[path = "transfer_cli/session_move_target_ask.rs"]
mod session_move_target_ask;
#[path = "transfer_cli/view_latency.rs"]
mod view_latency;
