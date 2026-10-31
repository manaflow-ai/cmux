//! Restart Chat / Update Everything (cx-1mbnu): over the daemon's unix
//! socket, `_acpmux/sessions/restart_harness {sessions?, harnesses?}` restarts
//! each named live chat's harness process and resumes the same agent session.
//! A restart that cannot spawn the harness again is counted as failed and
//! named in `errors` (never reported as success), a Home Chief chat restarts
//! when the caller names it, and a chat nobody named is left alone. A profile
//! reload that changes a live chat's launch restarts it the same way once its
//! turn ends (`hub/profile_respawn.rs`).

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(test: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-restart-{test}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// The harness launcher at `path`: the fake agent, with its own pid in `RUN_PID`.
fn launcher(path: &Path) {
    std::fs::write(path, format!("#!/bin/sh\nexport RUN_PID=$$\nexec python3 '{FAKE}' \"$@\"\n"))
        .unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.1.recv())
                .await
                .expect("no reply in 60 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    async fn new_chat(&mut self, harness: &str) -> String {
        let new = self
            .ok(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                       "_meta": {"acpmux": {"harness": harness}}}),
            )
            .await;
        new["sessionId"].as_str().unwrap().to_owned()
    }

    /// The pid of the harness process that answers a turn in `session`.
    async fn harness_pid(&mut self, session: &str) -> String {
        let prompt =
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "env: RUN_PID"}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        // The reply can overtake the turn's last streamed update.
        while !text.contains("RUN_PID=") {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no pid text: reply {reply}, text {text:?}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        let at = text.rfind("RUN_PID=").unwrap_or(0);
        text[at + "RUN_PID=".len()..].trim().to_owned()
    }

    async fn agent_session(&mut self, session: &str) -> Value {
        self.ok("_acpmux/info", json!({"sessionId": session})).await["agentSessionId"].clone()
    }
}

fn hub(root: &Path, good: &Path, bad: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "good": {"argv": ["/bin/sh", good], "family": "claude"},
            "bad": {"argv": ["/bin/sh", bad], "family": "claude"},
        },
        "defaultHarness": "good",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restart_harness_restarts_named_chats_and_reports_one_that_cannot_spawn() {
    let root = scratch("named");
    let (good, bad) = (root.join("good.sh"), root.join("bad.sh"));
    launcher(&good);
    launcher(&bad);
    let hub = hub(&root, &good, &bad);
    let mut local = Client::open(&hub);

    // A: a Home Chief chat, named by the caller. B: its harness can no longer
    // start. C: a live chat nobody names.
    let a = local.new_chat("good").await;
    let b = local.new_chat("bad").await;
    let c = local.new_chat("good").await;
    local.ok(method::MUX_TAG, json!({"sessionId": a, "set": {"cmux.chief": "1"}})).await;
    let (a_pid, b_pid, c_pid) =
        (local.harness_pid(&a).await, local.harness_pid(&b).await, local.harness_pid(&c).await);
    assert!(!a_pid.is_empty() && !b_pid.is_empty() && !c_pid.is_empty());
    let a_agent = local.agent_session(&a).await;
    assert!(a_agent.is_string(), "{a_agent}");
    std::fs::write(&bad, "#!/bin/sh\nexit 1\n").unwrap();

    let reply = local.ok(method::MUX_SESSIONS_RESTART_HARNESS, json!({"sessions": [&a, &b]})).await;
    assert_eq!(
        (&reply["restarted"], &reply["after_turn"], &reply["failed"]),
        (&json!(1), &json!(0), &json!(1)),
        "A restarts now, B fails: {reply}"
    );
    let errors = reply["errors"].as_array().unwrap_or_else(|| panic!("no errors list: {reply}"));
    assert_eq!(errors.len(), 1, "{reply}");
    assert_eq!(errors[0]["session"], json!(&b), "{reply}");
    assert!(errors[0]["error"].as_str().is_some_and(|e| !e.is_empty()), "{reply}");

    // A runs a new process on the same agent session; C still runs its first.
    let a_new = local.harness_pid(&a).await;
    assert_ne!(a_new, a_pid, "the named chat's harness restarted");
    assert_eq!(local.agent_session(&a).await, a_agent, "the same agent session resumed");
    assert_eq!(local.harness_pid(&c).await, c_pid, "an unnamed chat is untouched");

    // Unnamed (Update Everything): every live chat of the harness but the Chief's.
    let all = local.ok(method::MUX_SESSIONS_RESTART_HARNESS, json!({"harnesses": ["good"]})).await;
    assert_eq!(
        all,
        json!({"restarted": 1, "after_turn": 0, "failed": 0, "errors": []}),
        "only C restarts"
    );
    assert_ne!(local.harness_pid(&c).await, c_pid, "C restarted");
    assert_eq!(local.harness_pid(&a).await, a_new, "the Chief's chat is never swept");

    let _ = std::fs::remove_dir_all(&root);
}

/// The config file `hub_from_file` reads and a reload reads again: harness `good` runs the
/// launcher with `flag` as its one argument.
fn write_config(root: &Path, good: &Path, flag: &str) -> PathBuf {
    let path = root.join("home").join("config.json");
    let cfg = json!({
        "harnesses": {"good": {"argv": ["/bin/sh", good, flag], "family": "claude"}},
        "defaultHarness": "good",
        "permissionPolicy": "approve-all",
    });
    std::fs::write(&path, serde_json::to_vec(&cfg).unwrap()).unwrap();
    path
}

fn hub_from_file(root: &Path, path: &Path) -> Arc<Hub> {
    let mut cfg: Config =
        serde_json::from_slice(&std::fs::read(path).unwrap()).expect("config.json parses");
    cfg.path = Some(path.to_path_buf());
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

impl Client {
    /// The arguments the harness process that answers a turn in `session` was started with.
    async fn harness_args(&mut self, session: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "argv"}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        while !text.ends_with(']') {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no argv text: reply {reply}, text {text:?}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        text
    }

    async fn respawn_pending(&mut self, session: &str) -> Value {
        self.ok("_acpmux/info", json!({"sessionId": session})).await["respawnPending"].clone()
    }

    /// `respawnPending` of `session`'s row in the session list (`acpmux ls`, a shared snapshot).
    async fn listed_respawn(&mut self, session: &str) -> Value {
        let list = self.ok(method::MUX_SESSIONS, json!({})).await;
        let rows = list["sessions"].as_array().cloned().unwrap_or_default();
        let row = rows.into_iter().find(|r| r["sessionId"] == session);
        row.unwrap_or_else(|| panic!("{session} not listed: {list}"))["respawnPending"].clone()
    }
}

/// Leo, 2026-10-31, on a session at 650k of a 1M context: "why were you on high and on 1m
/// context??? i thought we fixed that???". Its harness profile gained `--autocompact` after the
/// agent started, and a session that never goes idle never started again. Now a profile reload
/// that changes a live agent's launch restarts it on the new argv once its turn ends (never in
/// the turn), on the same agent session, and `respawnPending` says so meanwhile.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn profile_change_respawns_a_busy_agent_with_the_new_args_after_its_turn() {
    let root = scratch("profile");
    let good = root.join("good.sh");
    launcher(&good);
    let path = write_config(&root, &good, "--old-arg");
    let hub = hub_from_file(&root, &path);
    let mut local = Client::open(&hub);

    let chat = local.new_chat("good").await;
    let first = local.harness_args(&chat).await;
    assert!(first.contains("--old-arg"), "started with the profile's argv: {first}");
    let pid = local.harness_pid(&chat).await;
    let agent = local.agent_session(&chat).await;
    assert!(agent.is_string(), "{agent}");
    assert_eq!(local.respawn_pending(&chat).await, Value::Null, "nothing pending yet");
    // The list is read once now, so a snapshot it keeps would show the row without the mark.
    assert_eq!(local.listed_respawn(&chat).await, Value::Null);

    // A turn in progress, held on a FIFO, while the profile file changes and the catalog reloads.
    let gate = root.join("gate");
    let c = std::ffi::CString::new(gate.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    local.2 += 1;
    let turn_id = local.2;
    let text = format!("gate: {}", gate.display());
    let prompt = json!({"sessionId": &chat, "prompt": [{"type": "text", "text": text}]});
    local.0.send(Message::request(turn_id, "session/prompt", prompt).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), local.1.recv())
            .await
            .expect("the gated turn never started")
            .unwrap();
        if line.contains("before-gate") {
            break;
        }
    }
    write_config(&root, &good, "--new-arg");
    let reload = local.ok(method::MUX_RELOAD_CONFIG, json!({})).await;
    assert_eq!(reload["reloaded"], true, "{reload}");
    // The respawn is decided on a task of its own after the reload answers.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while local.respawn_pending(&chat).await != json!("profile changed") {
        assert!(tokio::time::Instant::now() < deadline, "respawnPending never said so");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    assert_eq!(
        local.listed_respawn(&chat).await,
        json!("profile changed"),
        "the list shows it too"
    );

    // The turn runs to its end on the agent it started on: never cancelled.
    std::fs::write(&gate, "go").unwrap();
    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(60), local.1.recv())
            .await
            .expect("the gated turn never ended")
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(turn_id)) {
            break v;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "the turn was not cut: {reply}");

    // The next turn runs on a new agent with the new argv, resuming the same agent session.
    let next = local.harness_args(&chat).await;
    assert!(
        next.contains("--new-arg") && !next.contains("--old-arg"),
        "respawned on the new argv: {next}"
    );
    assert_ne!(local.harness_pid(&chat).await, pid, "a new harness process");
    assert_eq!(local.agent_session(&chat).await, agent, "the same agent session resumed");
    assert_eq!(local.respawn_pending(&chat).await, Value::Null, "the respawn settled");
    assert_eq!(local.listed_respawn(&chat).await, Value::Null, "and the list says so");

    // A reload that leaves the launch as it is restarts nothing.
    let settled = local.harness_pid(&chat).await;
    local.ok(method::MUX_RELOAD_CONFIG, json!({})).await;
    assert_eq!(local.harness_pid(&chat).await, settled, "an unchanged profile keeps its agent");
    assert_eq!(local.respawn_pending(&chat).await, Value::Null);

    let _ = std::fs::remove_dir_all(&root);
}
