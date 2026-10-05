//! The session pool (hidden pre-created sessions, `hub/pool/`) through a real
//! daemon with agent hosts and a fake adapter whose start is slow: a hinted
//! harness switch takes a ready session, hidden sessions are never listed or
//! counted and leave nothing behind, and they end with the daemon.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The fake adapter's boot and session start: a cold start pays both.
const INIT_MS: u64 = 300;
const NEW_MS: u64 = 700;

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
    debounce_ms: u64,
    /// The readiness line of the current run (it has the `webUrl`).
    ready: String,
}

fn profile(tag: &str) -> Value {
    json!({"argv": ["python3", FAKE], "env": {
        "FAKE_INIT_DELAY_MS": INIT_MS.to_string(),
        "FAKE_NEW_DELAY_MS": NEW_MS.to_string(),
        "FAKE_TAG": tag,
    }})
}

impl Daemon {
    fn new(tag: &str, debounce_ms: u64) -> Self {
        // Short: socket paths must stay under the macOS limit.
        let home = std::env::temp_dir().join(format!("asp-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let mut daemon = Self {
            child: None,
            socket: home.join("s.sock"),
            home,
            debounce_ms,
            ready: String::new(),
        };
        daemon.write_config(&profile("b"));
        daemon.start();
        daemon
    }

    fn write_config(&self, fakeb: &Value) {
        std::fs::write(
            self.home.join("config.json"),
            json!({
                "harnesses": {"fake": profile("a"), "fakeb": fakeb},
                "defaultHarness": "fake",
                "permissionPolicy": "approve-all",
                "pool": {"debounceMs": self.debounce_ms},
            })
            .to_string(),
        )
        .unwrap();
    }

    fn start(&mut self) {
        assert!(self.child.is_none());
        let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env_remove("ACPMUX_AGENT_HOSTS")
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("XPC_SERVICE_NAME")
            .env_remove("ACPMUX_IDLE_CHILD_SECS")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut ready = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut ready).unwrap();
        assert!(ready.contains("\"ready\":true"), "daemon not ready: {ready}");
        self.ready = ready;
        self.child = Some(child);
    }

    fn sigkill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
    }

    fn wait_exit(&mut self) {
        let mut child = self.child.take().unwrap();
        let status = child.wait().unwrap();
        assert!(status.success(), "daemon exited badly after _acpmux/shutdown: {status}");
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }

    fn records(&self, dir: &Path) -> Vec<Value> {
        std::fs::read_dir(dir)
            .map(|d| {
                d.filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
                    .filter_map(|p| serde_json::from_slice(&std::fs::read(p).ok()?).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn host_records(&self) -> Vec<Value> {
        self.records(&self.home.join("hosts"))
    }

    fn pool_records(&self) -> Vec<Value> {
        self.records(&self.home.join("hosts").join("pool"))
    }

    fn stored_sessions(&self) -> usize {
        std::fs::read_dir(self.home.join("sessions")).map(|d| d.count()).unwrap_or(0)
    }

    fn events(&self, session: &str) -> Vec<Value> {
        let dir = self.home.join("sessions").join(session).join("events");
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
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // End every host this test started, pooled or not.
        for r in self.host_records().into_iter().chain(self.pool_records()) {
            for pid in [r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten() {
                // SAFETY: process groups this test's daemon created.
                unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
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
        let v = self.raw(method, params).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }

    /// The error a request answers with.
    async fn call_err(&mut self, method: &str, params: Value) -> String {
        let v = self.raw(method, params).await;
        v["error"]["message"]
            .as_str()
            .unwrap_or_else(|| panic!("{method} did not fail: {v}"))
            .to_owned()
    }

    async fn raw(&mut self, method: &str, params: Value) -> Value {
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
                return v;
            }
        }
    }
}

fn alive(pid: i64) -> bool {
    // SAFETY: signal 0 only checks existence.
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn gone_within(pid: i64, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

/// Test polling: wait until the pool shows `harness` ready.
async fn wait_pool_ready(rpc: &mut Rpc, harness: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = rpc.call("_acpmux/status", json!({})).await;
        let ready = status["pool"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["harness"] == harness && e["state"] == "ready");
        if ready {
            return status;
        }
        assert!(Instant::now() < deadline, "{harness} never pooled: {status}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn new_session(rpc: &mut Rpc, home: &Path, harness: &str) -> (String, Duration) {
    let t = Instant::now();
    let created = rpc
        .call(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
        )
        .await;
    (created["sessionId"].as_str().expect("session id").to_owned(), t.elapsed())
}

fn taken(daemon: &Daemon, session: &str) -> bool {
    daemon.events(session).iter().any(|e| e["kind"] == "pool_taken")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hinted_switch_takes_a_hidden_session_that_was_never_listed() {
    let daemon = Daemon::new("hit", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let (first, cold) = new_session(&mut rpc, &home, "fake").await;
    assert!(!taken(&daemon, &first), "nothing was pooled yet");

    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    let status = wait_pool_ready(&mut rpc, "fakeb").await;
    // Hidden: not listed, not counted, nothing in the store, and its host
    // record is not where adoption and the quit census read.
    let listed = rpc.call("_acpmux/sessions", json!({})).await;
    assert_eq!(listed["sessions"].as_array().unwrap().len(), 1, "{listed}");
    assert_eq!(status["sessions"], 1, "{status}");
    assert_eq!(status["liveAgents"], 1, "{status}");
    assert_eq!(daemon.stored_sessions(), 1);
    assert_eq!(daemon.host_records().len(), 1, "only the user's session has a host record");
    assert_eq!(daemon.pool_records().len(), 1);
    let pooled_id = daemon.pool_records()[0]["session_id"].as_str().unwrap().to_owned();

    let (second, warm) = new_session(&mut rpc, &home, "fakeb").await;
    eprintln!("session/new: cold {cold:?}, pooled {warm:?}");
    assert_eq!(second, pooled_id, "the session takes the pooled id");
    assert!(taken(&daemon, &second));
    assert!(cold >= Duration::from_millis(INIT_MS + NEW_MS), "cold {cold:?}");
    assert!(warm < Duration::from_millis(300), "pooled switch took {warm:?}");
    // The taken session is durable like any other: its record moved.
    assert!(daemon.pool_records().is_empty());
    assert!(daemon.host_records().iter().any(|r| r["session_id"] == second.as_str()));
    // Its log holds the pooled start, in order, then it works.
    let kinds: Vec<String> =
        daemon.events(&second).iter().map(|e| e["kind"].as_str().unwrap().to_owned()).collect();
    let pos =
        |k: &str| kinds.iter().position(|x| x == k).unwrap_or_else(|| panic!("{k}: {kinds:?}"));
    assert!(pos("created") < pos("host_started"));
    assert!(pos("host_started") < pos("initialize"));
    assert!(pos("initialize") < pos("session/new"));
    assert!(pos("session/new") < pos("pool_taken"));
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": second, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");

    // Back and forth: the harness used before (fake) is now pooled.
    wait_pool_ready(&mut rpc, "fake").await;
    let (third, back) = new_session(&mut rpc, &home, "fake").await;
    eprintln!("session/new back to the last-used harness: {back:?}");
    assert!(taken(&daemon, &third));
    assert!(back < Duration::from_millis(300), "{back:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn hints_are_debounced_and_a_config_change_is_never_served() {
    let daemon = Daemon::new("deb", 300);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    // Two hints inside the debounce: only the newest one starts.
    let first = rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": home})).await;
    assert_eq!(first["accepted"], true);
    let second =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(second["superseded"], false, "{second}");
    let entries = second["pool"]["entries"].as_array().unwrap().clone();
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0]["harness"], "fakeb");
    assert_eq!(entries[0]["roles"], json!(["hinted"]));

    // The profile's env changes (a new credential) and the config reloads:
    // the entry started under the old one is ended, never served.
    let mut changed = profile("b");
    changed["env"]["FAKE_TOKEN"] = json!("rotated");
    daemon.write_config(&changed);
    rpc.call("_acpmux/reload_config", json!({})).await;
    let (id, cold) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(!taken(&daemon, &id), "a session under the changed key started cold");
    assert!(cold >= Duration::from_millis(INIT_MS + NEW_MS), "{cold:?}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !daemon.pool_records().is_empty() {
        assert!(Instant::now() < deadline, "the stale entry's host still runs");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn pooled_sessions_end_with_the_daemon_and_after_a_crash() {
    let mut daemon = Daemon::new("end", 0);
    let home = daemon.home.clone();
    {
        let mut rpc = daemon.rpc().await;
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
        wait_pool_ready(&mut rpc, "fakeb").await;
    }
    let r = daemon.pool_records().pop().expect("a pooled host");
    let (host, harness) = (r["host_pid"].as_i64().unwrap(), r["harness_pid"].as_i64().unwrap());
    {
        // A plain shutdown keeps user agents for the next daemon, but never
        // a hidden session.
        let mut rpc = daemon.rpc().await;
        rpc.call("_acpmux/shutdown", json!({})).await;
    }
    daemon.wait_exit();
    assert!(gone_within(harness, Duration::from_secs(10)), "pooled harness outlived shutdown");
    assert!(gone_within(host, Duration::from_secs(10)), "pooled host outlived shutdown");
    assert!(daemon.pool_records().is_empty());
    assert_eq!(daemon.stored_sessions(), 0, "an untaken pooled session leaves no trace");

    // A crash leaves the pooled host running; the next daemon ends it.
    daemon.start();
    {
        let mut rpc = daemon.rpc().await;
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
        wait_pool_ready(&mut rpc, "fakeb").await;
    }
    let r = daemon.pool_records().pop().expect("a pooled host");
    let harness = r["harness_pid"].as_i64().unwrap();
    daemon.sigkill();
    assert!(alive(harness), "a crashed daemon cannot end it");
    daemon.start();
    assert!(gone_within(harness, Duration::from_secs(15)), "the next daemon ended it");
    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("_acpmux/sessions", json!({})).await;
    assert!(listed["sessions"].as_array().unwrap().is_empty(), "{listed}");
    assert_eq!(daemon.stored_sessions(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_start_still_running_ends_with_the_daemon() {
    let mut daemon = Daemon::new("fly", 0);
    let home = daemon.home.clone();
    // The pooled harness hangs in its session start.
    let mut slow = profile("b");
    slow["env"]["FAKE_NEW_DELAY_MS"] = json!("60000");
    daemon.write_config(&slow);
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/reload_config", json!({})).await;
    let hint = rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home})).await;
    assert_eq!(hint["accepted"], true, "{hint}");
    let deadline = Instant::now() + Duration::from_secs(30);
    let record = loop {
        if let Some(r) = daemon.pool_records().pop()
            && r["harness_pid"].as_i64().is_some()
        {
            break r;
        }
        assert!(Instant::now() < deadline, "the pooled host never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let harness = record["harness_pid"].as_i64().unwrap();
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["pool"]["entries"][0]["state"], "warming", "{status}");
    rpc.call("_acpmux/shutdown", json!({})).await;
    daemon.wait_exit();
    assert!(gone_within(harness, Duration::from_secs(10)), "a start in flight outlived shutdown");
    assert!(daemon.pool_records().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_new_that_fails_after_its_claim_puts_the_entry_back() {
    let daemon = Daemon::new("ret", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let (_first, _) = new_session(&mut rpc, &home, "fake").await;
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let pooled = daemon.pool_records()[0]["session_id"].as_str().unwrap().to_owned();
    // The name is taken: the create fails after it claimed the pooled entry
    // (a cancelled session/new drops its claim the same way).
    let err = rpc
        .call_err(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb", "name": "fake"}}}),
        )
        .await;
    assert!(err.contains("taken"), "{err}");
    let status = rpc.call("_acpmux/status", json!({})).await;
    let entry = &status["pool"]["entries"][0];
    assert_eq!(entry["harness"], "fakeb", "{status}");
    assert_eq!(entry["state"], "ready", "the entry is back in the pool: {status}");
    assert_eq!(daemon.pool_records().len(), 1, "its host still runs");
    let (second, warm) = new_session(&mut rpc, &home, "fakeb").await;
    assert_eq!(second, pooled, "the next switch takes the same entry");
    assert!(taken(&daemon, &second));
    assert!(warm < Duration::from_millis(300), "{warm:?}");
}

/// ACP-REMOTE-GUARD B1: a pool claim writes the pooled session's mode
/// through the one setter; a session claimed in a mode that does not ask
/// (the fake's `normal`; its family has no asking modes) refuses a Web prompt.
#[tokio::test(flavor = "multi_thread")]
async fn a_pool_claim_in_a_mode_that_does_not_ask_refuses_a_web_prompt() {
    use futures::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    let daemon = Daemon::new("webpool", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fakeb").await;
    let (claimed, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(taken(&daemon, &claimed), "the session came from the pool");
    // A Web connection (the dashboard token only).
    let ready: Value = serde_json::from_str(&daemon.ready).unwrap();
    let ws_url = ready["webUrl"].as_str().unwrap().replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(ws_url).await.unwrap();
    let prompt = json!({"jsonrpc": "2.0", "id": 1, "method": "session/prompt",
        "params": {"sessionId": claimed, "prompt": [{"type": "text", "text": "from the web"}]}});
    ws.send(Frame::Text(prompt.to_string().into())).await.unwrap();
    let reply = loop {
        let frame = tokio::time::timeout(Duration::from_secs(20), ws.next())
            .await
            .expect("a reply")
            .expect("open")
            .unwrap();
        let Frame::Text(t) = frame else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if v.get("id") == Some(&json!(1)) {
            break v;
        }
    };
    assert_eq!(reply["error"]["data"]["reason"], "remote.mode_not_asking", "{reply}");
    assert_eq!(reply["error"]["data"]["mode"], "normal", "{reply}");
    // The unix socket keeps control of it.
    let local = rpc
        .call(
            "session/prompt",
            json!({"sessionId": claimed, "prompt": [{"type": "text", "text": "local"}]}),
        )
        .await;
    assert_eq!(local["stopReason"], "end_turn", "{local}");
}

/// ACP-REMOTE-GUARD B1, the Claude backend's claim path (`claude_state`):
/// a pooled Claude session whose profile pins `--permission-mode
/// bypassPermissions` (the fake reports the pinned mode, as Claude Code
/// does) is claimed in that mode, and a Web prompt is refused.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_claude_session_claimed_in_bypass_refuses_a_web_prompt() {
    use futures::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut daemon = Daemon::new("claudepool", 0);
    daemon.write_config(&json!({
        "kind": "claude-stdio",
        "family": "claude",
        "argv": ["python3", fake_claude, "--permission-mode", "bypassPermissions"],
    }));
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/shutdown", json!({})).await;
    daemon.wait_exit();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fakeb").await;
    let (claimed, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(taken(&daemon, &claimed), "the session came from the pool");
    let info = rpc.call("_acpmux/info", json!({"sessionId": claimed})).await;
    assert_eq!(info["modes"]["currentModeId"], "bypassPermissions", "{info}");
    let ready: Value = serde_json::from_str(&daemon.ready).unwrap();
    let ws_url = ready["webUrl"].as_str().unwrap().replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(ws_url).await.unwrap();
    let prompt = json!({"jsonrpc": "2.0", "id": 1, "method": "session/prompt",
        "params": {"sessionId": claimed, "prompt": [{"type": "text", "text": "from the web"}]}});
    ws.send(Frame::Text(prompt.to_string().into())).await.unwrap();
    let reply = loop {
        let frame = tokio::time::timeout(Duration::from_secs(20), ws.next())
            .await
            .expect("a reply")
            .expect("open")
            .unwrap();
        let Frame::Text(t) = frame else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if v.get("id") == Some(&json!(1)) {
            break v;
        }
    };
    assert_eq!(reply["error"]["data"]["reason"], "remote.mode_not_asking", "{reply}");
    assert_eq!(reply["error"]["data"]["mode"], "bypassPermissions", "{reply}");
}
