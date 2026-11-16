//! The login spare (`hub/pool/spare.rs`, `pool.loginSpare`, staging only): on a Cloud machine,
//! the moment a login install names a cmux account in `~/.config/cmux/agent-auth/claude.login`
//! (the warm's copy, ahead of the chat), the daemon starts a hidden Claude Code agent in the home
//! folder, so the chat that claims the machine takes a started agent instead of a cold start.
//!
//! It behaves exactly like a fresh one: a chat of another model, folder, settings or account
//! never takes it (the pool key, `policy.rs` and `auth.rs`); the chat's mode is set on the started
//! agent at the take, never put in its command line; and nothing reaches the model before the
//! person's first prompt: the agent gets its `initialize` and no user line (the stand-in logs
//! every line it reads, `FAKE_CLAUDE_STDIN_LOG`).
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (fake_claude.py).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

struct Daemon {
    child: Option<Child>,
    scratch: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    /// A daemon whose `claude` harness is the stand-in, with `pool.loginSpare` as `on`.
    fn start(tag: &str, on: bool) -> Self {
        // Short: socket paths must stay under the limit.
        let scratch = std::env::temp_dir().join(format!("als-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(daemon_env::home(&scratch)).unwrap();
        let daemon = Self { child: None, socket: scratch.join("s.sock"), scratch };
        let claude = json!({
            "kind": "claude-stdio",
            "family": "claude",
            "argv": ["python3", FAKE_CLAUDE],
            "env": {"FAKE_CLAUDE_STDIN_LOG": daemon.stdin_log()},
        });
        std::fs::write(
            daemon.scratch.join("config.json"),
            json!({
                "harnesses": {"claude": claude},
                "defaultHarness": "claude",
                "permissionPolicy": "approve-all",
                "pool": {"debounceMs": 0, "loginSpare": on},
            })
            .to_string(),
        )
        .unwrap();
        daemon.run()
    }

    fn run(mut self) -> Self {
        let mut child = daemon_env::command(&self.scratch, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.scratch)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("CMUX_NEXT_CONFIG_FILE", self.scratch.join("cmux-next.json"))
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_SPARE_HARNESS", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        daemon_env::ready_line(child.stdout.take().unwrap());
        self.child = Some(child);
        self
    }

    /// Writes `pool.loginSpare` into config.json (a reload reads it).
    fn set_login_spare(&self, on: bool) {
        let path = self.scratch.join("config.json");
        let mut config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        config["pool"]["loginSpare"] = json!(on);
        std::fs::write(path, config.to_string()).unwrap();
    }

    /// The daemon's and the agents' HOME: the Cloud machine's home folder.
    fn home(&self) -> PathBuf {
        daemon_env::home(&self.scratch)
    }

    fn stdin_log(&self) -> PathBuf {
        self.scratch.join("claude-stdin.log")
    }

    /// The kinds of every line the stand-in Claude Code agents read, in order.
    fn stdin_kinds(&self) -> Vec<String> {
        std::fs::read_to_string(self.stdin_log())
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// A login install, as the warm's copy writes it (`CloudCredentialInstaller`): the launcher's
    /// choice, then the mark naming the cmux account and the login's digest.
    fn install_login(&self, account: &str, digest: &str) {
        let marks = self.home().join(".config/cmux/agent-auth");
        std::fs::create_dir_all(&marks).unwrap();
        std::fs::write(marks.join("claude"), "own\n").unwrap();
        let mark = json!({"account": account, "digest": digest}).to_string();
        let tmp = marks.join(".claude.login.tmp");
        std::fs::write(&tmp, mark).unwrap();
        std::fs::rename(tmp, marks.join("claude.login")).unwrap();
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }

    fn pool_records(&self) -> Vec<Value> {
        records(&self.scratch.join("hosts").join("pool"))
    }

    fn host_records(&self) -> Vec<Value> {
        records(&self.scratch.join("hosts"))
    }

    fn events(&self, session: &str) -> Vec<Value> {
        let dir = self.scratch.join("sessions").join(session).join("events");
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        files.sort();
        files
            .iter()
            .flat_map(|f| {
                std::fs::read_to_string(f)
                    .unwrap_or_default()
                    .lines()
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .filter_map(|l| serde_json::from_str(&l).ok())
            .collect()
    }

    fn taken(&self, session: &str) -> bool {
        self.events(session).iter().any(|e| e["kind"] == "pool_taken")
    }

    /// The harness pid `session` runs on.
    fn harness_pid(&self, session: &str) -> Value {
        self.host_records()
            .into_iter()
            .find(|r| r["session_id"] == session)
            .map(|r| r["harness_pid"].clone())
            .unwrap_or(Value::Null)
    }
}

fn records(dir: &Path) -> Vec<Value> {
    std::fs::read_dir(dir)
        .map(|d| {
            d.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
                .filter_map(|p| serde_json::from_slice(&std::fs::read(p).ok()?).ok())
                .collect()
        })
        .unwrap_or_default()
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        for r in self.host_records().into_iter().chain(self.pool_records()) {
            for pid in [r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten() {
                // SAFETY: process groups this test's daemon created.
                unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
            }
        }
        let _ = std::fs::remove_dir_all(&self.scratch);
    }
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// The ready Claude spare's pool record. Test polling, bounded.
async fn wait_claude_spare(daemon: &Daemon, rpc: &mut Rpc) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = rpc.call("_acpmux/status", json!({})).await;
        let ready = status["pool"]["entries"].as_array().unwrap().iter().any(|e| {
            e["harness"] == "claude"
                && e["state"] == "ready"
                && e["roles"].as_array().is_some_and(|r| r.iter().any(|r| r == "spare"))
        });
        if ready && let Some(record) = daemon.pool_records().into_iter().next() {
            return record;
        }
        assert!(Instant::now() < deadline, "no ready claude spare after a login install: {status}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// `session/new` as a Cloud chat's start sends it (`agent_session_start.rs`): the harness, the
/// policy, the person's mode and model, in `cwd`.
async fn chat(rpc: &mut Rpc, cwd: &Path, extra: Value) -> String {
    let mut meta = json!({"harness": "claude", "policy": "ask"});
    for (k, v) in extra.as_object().unwrap() {
        meta[k] = v.clone();
    }
    let created = rpc
        .call("session/new", json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}))
        .await;
    created["sessionId"].as_str().expect("session id").to_owned()
}

/// A login install starts a Claude spare in the home folder; a chat of its shape takes it, in
/// the chat's own mode (set at the take, not in the agent's command line), and no line that
/// calls the model reaches the agent before the person's prompt.
#[tokio::test(flavor = "multi_thread")]
async fn a_login_install_starts_a_claude_spare_that_a_chat_takes_with_no_model_call_before_its_prompt()
 {
    let daemon = Daemon::start("take", true);
    let mut rpc = daemon.rpc().await;
    assert!(daemon.pool_records().is_empty(), "no login yet: no spare");
    daemon.install_login("user_a", "d1");
    let pooled = wait_claude_spare(&daemon, &mut rpc).await;
    let kinds = daemon.stdin_kinds();
    assert!(
        kinds.iter().any(|k| k == "control_request:initialize"),
        "the spare is a started agent: {kinds:?}"
    );
    assert!(!kinds.iter().any(|k| k == "user"), "no model call before a prompt: {kinds:?}");

    let session = chat(&mut rpc, &daemon.home(), json!({"mode": "acceptEdits"})).await;
    assert!(daemon.taken(&session), "the chat took the login spare");
    assert_eq!(daemon.harness_pid(&session), pooled["harness_pid"], "on the spare's agent");
    let info = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(info["modes"]["currentModeId"], "acceptEdits", "the chat's mode: {info}");
    let kinds = daemon.stdin_kinds();
    assert!(!kinds.iter().any(|k| k == "user"), "no model call at the take: {kinds:?}");
    // The mode went to the started agent, not into its command line.
    let pid = pooled["harness_pid"].as_u64().expect("harness pid");
    let argv: Vec<String> = std::fs::read(format!("/proc/{pid}/cmdline"))
        .unwrap()
        .split(|b| *b == 0)
        .map(|w| String::from_utf8_lossy(w).into_owned())
        .collect();
    assert!(!argv.iter().any(|w| w == "acceptEdits"), "the mode reached the argv: {argv:?}");

    // The person's first prompt is the first model call.
    let answer = rpc
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    assert_eq!(daemon.stdin_kinds().iter().filter(|k| *k == "user").count(), 1);
}

/// Off (the default), a login install starts nothing.
#[tokio::test(flavor = "multi_thread")]
async fn with_the_login_spare_off_a_login_install_starts_no_agent() {
    let daemon = Daemon::start("off", false);
    let mut rpc = daemon.rpc().await;
    daemon.install_login("user_a", "d1");
    tokio::time::sleep(Duration::from_secs(2)).await;
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["pool"]["entries"], json!([]), "{status}");
    assert!(daemon.stdin_kinds().is_empty(), "no agent started");
}

/// The switch is read again by `_acpmux/reload_config` (`acpmux daemon reload`): turned on with a
/// login already installed, the spare starts with no daemon restart.
#[tokio::test(flavor = "multi_thread")]
async fn turning_the_login_spare_on_by_a_reload_starts_it_for_the_installed_login() {
    let daemon = Daemon::start("on-reload", false);
    let mut rpc = daemon.rpc().await;
    daemon.install_login("user_a", "d1");
    daemon.set_login_spare(true);
    let reloaded = rpc.call("_acpmux/reload_config", json!({})).await;
    assert_eq!(reloaded["reloaded"], true, "{reloaded}");
    wait_claude_spare(&daemon, &mut rpc).await;
}

/// A reload drops every pooled agent started under the old catalog; the login spare starts again
/// under the new one, so it is not lost until the next login install.
#[tokio::test(flavor = "multi_thread")]
async fn a_reload_starts_the_login_spare_again() {
    let (daemon, mut rpc, first) = with_spare("reload").await;
    let reloaded = rpc.call("_acpmux/reload_config", json!({})).await;
    assert_eq!(reloaded["reloaded"], true, "{reloaded}");
    let deadline = Instant::now() + Duration::from_secs(30);
    let again = loop {
        let record = wait_claude_spare(&daemon, &mut rpc).await;
        if record["harness_pid"] != first["harness_pid"] {
            break record;
        }
        assert!(Instant::now() < deadline, "no new login spare after a reload");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let session = chat(&mut rpc, &daemon.home(), json!({})).await;
    assert!(daemon.taken(&session), "the chat took the spare started after the reload");
    assert_eq!(daemon.harness_pid(&session), again["harness_pid"]);
}

/// A daemon with a ready login spare, its pool record, and a connection.
async fn with_spare(tag: &str) -> (Daemon, Rpc, Value) {
    let daemon = Daemon::start(tag, true);
    let mut rpc = daemon.rpc().await;
    daemon.install_login("user_a", "d1");
    let pooled = wait_claude_spare(&daemon, &mut rpc).await;
    (daemon, rpc, pooled)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_chat_of_another_model_never_takes_the_login_spare() {
    let (daemon, mut rpc, pooled) = with_spare("model").await;
    let session = chat(&mut rpc, &daemon.home(), json!({"model": "opus"})).await;
    assert!(!daemon.taken(&session), "another model is a cold start");
    assert_ne!(daemon.harness_pid(&session), pooled["harness_pid"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_chat_in_another_folder_never_takes_the_login_spare() {
    let (daemon, mut rpc, pooled) = with_spare("cwd").await;
    let project = daemon.home().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let session = chat(&mut rpc, &project, json!({})).await;
    assert!(!daemon.taken(&session), "another folder is a cold start");
    assert_ne!(daemon.harness_pid(&session), pooled["harness_pid"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_chat_after_a_settings_change_never_takes_the_login_spare() {
    let (daemon, mut rpc, pooled) = with_spare("settings").await;
    let settings = daemon.home().join(".claude/settings.json");
    std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
    std::fs::write(&settings, json!({"model": "sonnet"}).to_string()).unwrap();
    let session = chat(&mut rpc, &daemon.home(), json!({})).await;
    // The agent started under the old settings never serves it (a spare started again under the
    // new ones may).
    assert_ne!(
        daemon.harness_pid(&session),
        pooled["harness_pid"],
        "a spare started under the old settings served the chat"
    );
}

/// A settings change after the install (the model stub's endpoint, a person's edit) starts the
/// spare again under the new settings, and the next chat takes that one.
#[tokio::test(flavor = "multi_thread")]
async fn a_settings_change_starts_the_login_spare_again_under_the_new_settings() {
    let (daemon, mut rpc, pooled) = with_spare("resettle").await;
    let settings = daemon.home().join(".claude/settings.json");
    std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
    std::fs::write(&settings, json!({"model": "sonnet"}).to_string()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let again = loop {
        let record = wait_claude_spare(&daemon, &mut rpc).await;
        if record["harness_pid"] != pooled["harness_pid"] {
            break record;
        }
        assert!(Instant::now() < deadline, "the spare was not started again");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let session = chat(&mut rpc, &daemon.home(), json!({})).await;
    assert!(daemon.taken(&session), "the chat took the spare started under the new settings");
    assert_eq!(daemon.harness_pid(&session), again["harness_pid"]);
}

/// Another person's login installed on the machine: the agent started under the first one never
/// serves a chat (a new spare may, started under the new login).
#[tokio::test(flavor = "multi_thread")]
async fn a_chat_after_another_account_s_login_never_runs_on_the_old_spare() {
    let (daemon, mut rpc, pooled) = with_spare("account").await;
    daemon.install_login("user_b", "d2");
    let session = chat(&mut rpc, &daemon.home(), json!({})).await;
    assert_ne!(
        daemon.harness_pid(&session),
        pooled["harness_pid"],
        "a spare started under user_a's login served user_b's chat"
    );
}
