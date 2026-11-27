//! `acpmux session queue list|remove|clear SESSION`: a session's waiting prompts, read and taken
//! out from the CLI. A coordinator held 319 queued agent messages (2026-10-29) and the only way
//! to drop them was a hand-written `_acpmux/queue_remove` over the socket.
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
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "session-queue-cli"}});
        rpc.call("initialize", hello).await;
        rpc
    }

    /// Sends a request without waiting for its answer (a prompt answers when its turn ends).
    async fn send(&mut self, method: &str, params: Value) {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("send");
    }

    async fn next_line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .expect("read")
            .expect("daemon closed the socket");
        serde_json::from_str(&line).expect("json line")
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.send(method, params).await;
        let id = self.next;
        loop {
            let v = self.next_line().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Waits for a notification `method` whose params match.
    async fn wait_for(&mut self, method: &str, matches: impl Fn(&Value) -> bool) {
        loop {
            let v = self.next_line().await;
            if v["method"] == method && matches(&v["params"]) {
                return;
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
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all", "agentInbox": false});
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

    /// Runs `acpmux --json session queue ARGS...` on the person's socket; (exit ok, stdout JSON,
    /// stdout and stderr).
    async fn queue(&self, args: &[&str]) -> (bool, Value, String) {
        let out = daemon_env::tokio_command(&self.home, daemon_env::Agents::Deny)
            .args(["--json", "session", "queue"])
            .args(args)
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .output()
            .await
            .expect("run acpmux session queue");
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        let v = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
        (out.status.success(), v, format!("{stdout}{stderr}"))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

/// A session busy with a turn that runs until cancelled, so every prompt after it queues; then
/// `prompts` (prompt id, sending agent or `None` for the person's, text), each queued.
async fn busy_with_queue(daemon: &Daemon, prompts: &[(&str, Option<&str>, &str)]) -> (Rpc, String) {
    let mut rpc = Rpc::connect(&daemon.socket).await;
    let made = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().expect("session id").to_owned();
    let turn = json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}], "_meta": {"acpmux": {"promptId": "p-turn"}}});
    rpc.send("session/prompt", turn).await;
    rpc.wait_for("session/update", |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, from, text) in prompts {
        let mut meta = json!({"promptId": prompt_id});
        if let Some(from) = from {
            meta["fromAgent"] = json!(from);
        }
        let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}});
        rpc.send("session/prompt", params).await;
        rpc.wait_for("_acpmux/prompt_accepted", |p| {
            p["promptId"] == *prompt_id && p["queued"] == true
        })
        .await;
    }
    (rpc, id)
}

/// The queued prompt ids, in run order.
async fn queued_ids(rpc: &mut Rpc, id: &str) -> Vec<String> {
    let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
    info["queue"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|q| q["promptId"].as_str().map(str::to_owned))
        .collect()
}

/// `list --json` gives each queued prompt's whole text, not the 200-character preview the
/// session summary carries; the plain list is one line per prompt with its sender.
#[tokio::test]
async fn list_json_gives_each_queued_prompts_full_text() {
    let daemon = Daemon::start("qls").await;
    let long = format!("rebase first {}", "word ".repeat(200));
    let (_rpc, id) =
        busy_with_queue(&daemon, &[("p-me", None, "mine"), ("p-a", Some("lane-a"), &long)]).await;
    let (ok, v, out) = daemon.queue(&["list", &id]).await;
    assert!(ok, "{out}");
    let queue = v["queue"].as_array().expect("queue");
    assert_eq!(queue.len(), 2, "{out}");
    let agent = queue.iter().find(|q| q["promptId"] == "p-a").expect("p-a listed");
    assert_eq!(agent["fromAgent"], "lane-a", "{out}");
    assert_eq!(agent["text"], long.as_str(), "the whole text, not a preview: {out}");
    let mine = queue.iter().find(|q| q["promptId"] == "p-me").expect("p-me listed");
    assert_eq!(mine["fromAgent"], Value::Null, "{out}");
    assert_eq!(mine["text"], "mine", "{out}");
}

/// `clear` takes only other agents' messages, and only with `--from-agents`: without it, it
/// refuses; `--dry-run` lists and takes nothing; then the person's prompt is all that is left.
#[tokio::test]
async fn clear_from_agents_leaves_the_persons_prompts() {
    let daemon = Daemon::start("qcl").await;
    let prompts =
        [("p-me", None, "mine"), ("p-a1", Some("lane-a"), "one"), ("p-a2", Some("lane-b"), "two")];
    let (mut rpc, id) = busy_with_queue(&daemon, &prompts).await;
    let all = queued_ids(&mut rpc, &id).await;
    assert_eq!(all.len(), 3, "{all:?}");

    let (ok, _, out) = daemon.queue(&["clear", &id]).await;
    assert!(!ok && out.contains("--from-agents"), "refuses without --from-agents: {out}");
    assert_eq!(queued_ids(&mut rpc, &id).await, all, "nothing removed");

    let (ok, v, out) = daemon.queue(&["clear", &id, "--from-agents", "--dry-run"]).await;
    assert!(ok, "{out}");
    let would: Vec<&str> = v["wouldRemove"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|q| q["promptId"].as_str())
        .collect();
    assert_eq!(would, ["p-a1", "p-a2"], "{out}");
    assert_eq!(queued_ids(&mut rpc, &id).await, all, "a dry run removes nothing");

    let (ok, v, out) = daemon.queue(&["clear", &id, "--from-agents"]).await;
    assert!(ok, "{out}");
    assert_eq!(v["removed"], 2, "{out}");
    assert_eq!(queued_ids(&mut rpc, &id).await, ["p-me"], "the person's prompt stays");

    // Through the same path as the app: the log records each removal.
    let events =
        rpc.call("_acpmux/events", json!({"sessionId": id, "kinds": ["queue_removed"]})).await;
    let removed: Vec<&str> = events["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| e.pointer("/msg/promptId").and_then(Value::as_str))
        .collect();
    assert_eq!(removed, ["p-a1", "p-a2"], "{events}");
}

/// `remove` takes the named prompts out and reports each one removed or not found; an unknown
/// id fails the command after the others are removed.
#[tokio::test]
async fn remove_reports_unknown_ids() {
    let daemon = Daemon::start("qrm").await;
    let (mut rpc, id) =
        busy_with_queue(&daemon, &[("p-me", None, "mine"), ("p-a", Some("lane-a"), "hi")]).await;
    let (ok, v, out) = daemon.queue(&["remove", &id, "p-a", "nope"]).await;
    assert!(!ok, "an unknown id fails the command: {out}");
    assert!(out.contains("queue.not_removed"), "{out}");
    let results = v["results"].as_array().expect("results");
    assert_eq!(results[0], json!({"promptId": "p-a", "status": "removed"}), "{out}");
    assert_eq!(results[1], json!({"promptId": "nope", "status": "not_found"}), "{out}");
    assert_eq!(queued_ids(&mut rpc, &id).await, ["p-me"]);

    let (ok, v, out) = daemon.queue(&["remove", &id, "p-me"]).await;
    assert!(ok, "{out}");
    assert_eq!(v["removed"], 1, "{out}");
    assert!(queued_ids(&mut rpc, &id).await.is_empty());
}

/// `clear --from-agents` checks that a prompt is still another agent's message as it leaves,
/// under the queue's lock (`_acpmux/queue_remove` `fromAgentsOnly`), not only by the list it
/// read first: an agent message the person edits becomes theirs, and a removal asked for
/// agents' messages only keeps it.
#[tokio::test]
async fn an_agents_only_removal_keeps_a_prompt_the_person_edited() {
    let daemon = Daemon::start("qed").await;
    let (mut rpc, id) =
        busy_with_queue(&daemon, &[("p-me", None, "mine"), ("p-a", Some("lane-a"), "hi")]).await;
    let agents_only =
        |prompt_id: &str| json!({"sessionId": id, "promptId": prompt_id, "fromAgentsOnly": true});
    // The person's own prompt is kept, and the daemon says why.
    let v = rpc.call("_acpmux/queue_remove", agents_only("p-me")).await;
    assert_eq!(v["removed"], false, "{v}");
    assert_eq!(v["notFromAgent"], true, "{v}");
    assert_eq!(v["fromAgentsOnly"], true, "{v}");
    // The person edits the agent's message: it is theirs now, and kept too.
    let edit = json!({"sessionId": id, "promptId": "p-a", "op": "update", "text": "my words"});
    rpc.call("_acpmux/queue_edit", edit).await;
    let v = rpc.call("_acpmux/queue_remove", agents_only("p-a")).await;
    assert_eq!(v["removed"], false, "{v}");
    assert_eq!(v["notFromAgent"], true, "{v}");
    assert_eq!(queued_ids(&mut rpc, &id).await, ["p-me", "p-a"]);
    // And clear has nothing of an agent's left to take.
    let (ok, v, out) = daemon.queue(&["clear", &id, "--from-agents"]).await;
    assert!(ok, "{out}");
    assert_eq!(v["removed"], 0, "{out}");
    assert_eq!(queued_ids(&mut rpc, &id).await, ["p-me", "p-a"]);
}
