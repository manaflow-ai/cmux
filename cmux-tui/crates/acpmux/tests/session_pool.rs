//! The session pool (hidden pre-created sessions, `hub/pool/`) through a real
//! daemon with agent hosts and a fake adapter whose start is slow: a hinted
//! harness switch takes a ready session, hidden sessions are never listed or
//! counted and leave nothing behind, and they end with the daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The fake adapter's boot and session start: a cold start pays both.
const INIT_MS: u64 = 300;
const NEW_MS: u64 = 700;
/// Text whose host entry fails its acknowledgement, once per daemon (`ACPMUX_TEST_ACK_FAILS_ONCE`):
/// a fake that reports it as its mode after its `session/new` answer stops its link's reader then.
const ACK_FAILS: &str = "ackstop-mode";

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
        Self::with_fakeb(tag, debounce_ms, &profile("b"))
    }

    /// `new` with another `fakeb` profile, written before the first start.
    fn with_fakeb(tag: &str, debounce_ms: u64, fakeb: &Value) -> Self {
        Self::with_settings(tag, debounce_ms, fakeb, None)
    }

    /// `with_fakeb` with the cmux settings file `settings`, written before the first start.
    fn with_settings(tag: &str, debounce_ms: u64, fakeb: &Value, settings: Option<Value>) -> Self {
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
        daemon.write_config(fakeb);
        if let Some(settings) = settings {
            std::fs::write(daemon.home.join("cmux-next.json"), settings.to_string()).unwrap();
        }
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
        let mut child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            // The cmux settings file: absent (every key at its default) unless a test writes it.
            .env("CMUX_NEXT_CONFIG_FILE", self.home.join("cmux-next.json"))
            // No catalog fetch: a test never reaches the network, and the fetch's
            // warning (a catalog server 404) came on stdout before the ready line.
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            // Each marker file here stalls one agent host's hello (debug
            // builds' seam): `stall_hellos`.
            .env("ACPMUX_TEST_HOST_HELLO_STALL_DIR", self.stall_dir())
            // A mode in this file is reported by the next pooled agent a chat takes, after the
            // take's check (debug builds' seam): `adopt_report`.
            .env("ACPMUX_TEST_POOL_ADOPT_REPORT_FILE", self.home.join("adopt-report"))
            // The same while a chat claims it, and then MDM's off is unset: `claim-report`.
            .env("ACPMUX_TEST_POOL_CLAIM_REPORT_FILE", self.home.join("claim-report"))
            // MDM's off comes and goes once, right after a pooled start read it: `off-blip`.
            .env("ACPMUX_TEST_OFF_BLIP_FILE", self.home.join("off-blip"))
            // While this file exists, MDM's off begins and is unset while a chat claims a pooled
            // agent: `claim_off_seam`.
            .env("ACPMUX_TEST_POOL_CLAIM_OFF_FILE", self.home.join("claim-off"))
            // While this file exists, MDM's off is pushed and unset as a chat takes the pooled
            // agent it claimed: `take_off_seam`.
            .env("ACPMUX_TEST_POOL_TAKE_OFF_FILE", self.home.join("take-off"))
            // The first host entry holding this text fails its acknowledgement (debug builds'
            // seam): only a fake that reports it as a mode sends one.
            .env("ACPMUX_TEST_ACK_FAILS_ONCE", ACK_FAILS)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        self.ready = daemon_env::ready_line(child.stdout.take().unwrap());
        self.child = Some(child);
    }

    fn stall_dir(&self) -> PathBuf {
        self.home.join("stall")
    }

    /// The next `n` agent hosts never answer hello, as a wedged host.
    fn stall_hellos(&self, n: usize) {
        std::fs::create_dir_all(self.stall_dir()).unwrap();
        for i in 0..n {
            std::fs::write(self.stall_dir().join(format!("stall-{i}")), "").unwrap();
        }
    }

    /// Stall markers no host took yet.
    fn stalls_left(&self) -> usize {
        std::fs::read_dir(self.stall_dir()).map(|d| d.count()).unwrap_or(0)
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

/// `session` runs on the pooled host `pooled` (its pool record): the same
/// host and agent processes, started once. A switch that started a fresh
/// host instead would wait the fake's initialize and session/new delays; its
/// wall time is no proof on a loaded machine, the processes are.
fn assert_runs_on_pooled_host(daemon: &Daemon, session: &str, pooled: &Value) {
    let record = daemon
        .host_records()
        .into_iter()
        .find(|r| r["session_id"] == session)
        .unwrap_or_else(|| panic!("{session} has no host record"));
    assert_eq!(record["host_pid"], pooled["host_pid"], "not the pooled host: {record}");
    assert_eq!(record["harness_pid"], pooled["harness_pid"], "not the pooled agent: {record}");
    let kinds: Vec<Value> = daemon.events(session).iter().map(|e| e["kind"].clone()).collect();
    for once in ["host_started", "initialize"] {
        let n = kinds.iter().filter(|kind| *kind == once).count();
        assert_eq!(n, 1, "{once} {n} times: {kinds:?}");
    }
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
    let pooled = daemon.pool_records()[0].clone();
    let pooled_id = pooled["session_id"].as_str().unwrap().to_owned();

    let (second, warm) = new_session(&mut rpc, &home, "fakeb").await;
    eprintln!("session/new: cold {cold:?}, pooled {warm:?}");
    assert_eq!(second, pooled_id, "the session takes the pooled id");
    assert!(taken(&daemon, &second));
    assert!(cold >= Duration::from_millis(INIT_MS + NEW_MS), "cold {cold:?}");
    assert_runs_on_pooled_host(&daemon, &second, &pooled);
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
    let pooled_fake = daemon.pool_records()[0].clone();
    let (third, back) = new_session(&mut rpc, &home, "fake").await;
    eprintln!("session/new back to the last-used harness: {back:?}");
    assert!(taken(&daemon, &third));
    assert_runs_on_pooled_host(&daemon, &third, &pooled_fake);
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

    // A crash: no daemon can use a pooled host nobody took, so the host ends its harness
    // and itself as its daemon's link closes (`agent_host/host.rs` `on_frame`), with no
    // next daemon. Whether it is still alive right after the SIGKILL is a race with that
    // end, so the test never asks it.
    daemon.start();
    {
        let mut rpc = daemon.rpc().await;
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
        wait_pool_ready(&mut rpc, "fakeb").await;
    }
    let r = daemon.pool_records().pop().expect("a pooled host");
    let (host, harness) = (r["host_pid"].as_i64().unwrap(), r["harness_pid"].as_i64().unwrap());
    daemon.sigkill();
    assert!(gone_within(harness, Duration::from_secs(15)), "pooled harness outlived a crash");
    assert!(gone_within(host, Duration::from_secs(15)), "pooled host outlived a crash");
    assert!(daemon.pool_records().is_empty(), "the ended host left its record");
    // The next daemon starts clean: nothing listed, nothing stored.
    daemon.start();
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
    let record = daemon.pool_records()[0].clone();
    let pooled = record["session_id"].as_str().unwrap().to_owned();
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
    let (second, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert_eq!(second, pooled, "the next switch takes the same entry");
    assert!(taken(&daemon, &second));
    assert_runs_on_pooled_host(&daemon, &second, &record);
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
/// does) is claimed in that mode, and a Web prompt is refused (D13 refuses
/// any Claude session the Mac started).
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_claude_session_claimed_in_bypass_refuses_a_web_prompt() {
    use futures::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let fakeb = json!({
        "kind": "claude-stdio",
        "family": "claude",
        "argv": ["python3", fake_claude, "--permission-mode", "bypassPermissions"],
    });
    let daemon = Daemon::with_fakeb("claudepool", 0, &fakeb);
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
    // A Claude session the Mac started is never Web-controlled (D13); its
    // mode does not ask either (above).
    assert_eq!(reply["error"]["data"]["reason"], "remote.local_claude_session", "{reply}");
}

/// `sessions.allowFullAccess` off: a pooled chat whose harness started in full access on its own
/// settings (not its argv, which acpmux leaves alone) is moved to a mode that asks when it is
/// taken, the same as a cold start, before anything runs in it.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_chat_that_started_in_full_access_leaves_it_when_off() {
    let mut fakeb = profile("b");
    fakeb["env"]["FAKE_FULL_ACCESS"] = json!("1");
    fakeb["env"]["FAKE_NEW_MODE"] = json!("full-access");
    let off = json!({"sessions": {"allowFullAccess": false}});
    let daemon = Daemon::with_settings("fapool", 0, &fakeb, Some(off));
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fakeb").await;
    let (claimed, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(taken(&daemon, &claimed), "the session came from the pool");
    let info = rpc.call("_acpmux/info", json!({"sessionId": claimed})).await;
    assert_eq!(info["modes"]["currentModeId"], "normal", "{info}");
}

/// `sessions.allowFullAccess` off does not touch a profile that pins its mode in its argv
/// (`--yolo`): acpmux sets no mode over such profiles, pooled or cold.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_chat_pinned_to_full_access_by_its_argv_keeps_it_when_off() {
    let mut fakeb = profile("b");
    fakeb["argv"].as_array_mut().unwrap().push(json!("--yolo"));
    fakeb["env"]["FAKE_FULL_ACCESS"] = json!("1");
    fakeb["env"]["FAKE_NEW_MODE"] = json!("full-access");
    let off = json!({"sessions": {"allowFullAccess": false}});
    let daemon = Daemon::with_settings("fapinned", 0, &fakeb, Some(off));
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fakeb").await;
    let (claimed, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(taken(&daemon, &claimed), "the session came from the pool");
    let info = rpc.call("_acpmux/info", json!({"sessionId": claimed})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
}

/// Whether `status` shows a ready fakeb entry.
fn fakeb_ready(status: &Value) -> bool {
    status["pool"]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|e| e["harness"] == "fakeb" && e["state"] == "ready")
}

/// A daemon whose fakeb harness runs with `env`, once MDM forced full access off and fakeb was
/// prewarmed, and whether the pool kept a ready fakeb entry.
async fn prewarmed_under_an_off(tag: &str, env: &[(&str, &str)]) -> (Daemon, Rpc, bool) {
    let mut fakeb = profile("b");
    for (key, value) in env {
        fakeb["env"][*key] = json!(value);
    }
    let daemon = Daemon::with_fakeb(tag, 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let off = json!({"enabled": true, "discovery": false, "roots": [], "managedRoots": [],
                     "allowFullAccess": false, "allowFullAccessManaged": true});
    let pushed = rpc.call("_acpmux/chat_settings", off).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    let kept = fakeb_ready(&warmed);
    (daemon, rpc, kept)
}

/// MDM forces `sessions.allowFullAccess` off (#23322, reviews 73, 75 and 77): an off that comes
/// and goes right after a pooled start first reads it holds for that start, so a profile that
/// pins full access is not prewarmed.
#[tokio::test(flavor = "multi_thread")]
async fn a_pinned_prewarm_holds_an_off_that_came_and_went_as_it_began() {
    let mut fakeb = profile("b");
    fakeb["argv"].as_array_mut().unwrap().push(json!("--yolo"));
    let daemon = Daemon::with_fakeb("faonce", 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    std::fs::write(home.join("off-blip"), "").unwrap();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert!(
        !fakeb_ready(&warmed),
        "a profile pinning full access was prewarmed though MDM's off came and went: {warmed}"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, reviews 121, 122 and 124): a chat whose
/// claim began, saw MDM's off come and go, and then waited on a pooled agent that started only
/// after the unset (so its start saw no off) and came up in full access does not take it: the
/// claim's own read holds.
#[tokio::test(flavor = "multi_thread")]
async fn a_full_access_pooled_start_claimed_as_an_mdm_off_came_and_went_is_not_taken() {
    let mut fakeb = profile("b");
    fakeb["env"]["FAKE_FULL_ACCESS"] = json!("1");
    fakeb["env"]["FAKE_NEW_MODE"] = json!("full-access");
    let daemon = Daemon::with_fakeb("fawarmb", 0, &fakeb);
    let home = daemon.home.clone();
    let blip = home.join("off-blip");
    std::fs::write(&blip, "then-start").unwrap();
    let mut claiming = daemon.rpc().await;
    let at = home.clone();
    let created = tokio::spawn(async move { new_session(&mut claiming, &at, "fakeb").await });
    let deadline = Instant::now() + Duration::from_secs(30);
    while blip.exists() {
        assert!(Instant::now() < deadline, "the claim never reached its seam");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home})).await;
    let (session, _) = created.await.expect("the chat is created");
    assert!(
        !taken(&daemon, &session),
        "a chat took a pooled agent in full access its claim waited on through MDM's off"
    );
}

/// A daemon whose fakeb harness comes up in full access, prewarmed with MDM unset (so kept).
/// `blip_at_claim` then has MDM's off come and go once while the next chat claims it.
async fn full_access_entry_claimed_through_an_off(tag: &str) -> (Daemon, Rpc, Value) {
    let mut fakeb = profile("b");
    fakeb["env"]["FAKE_FULL_ACCESS"] = json!("1");
    fakeb["env"]["FAKE_NEW_MODE"] = json!("full-access");
    let daemon = Daemon::with_fakeb(tag, 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let record = daemon.pool_records()[0].clone();
    (daemon, rpc, record)
}

fn blip_at_claim(daemon: &Daemon) {
    std::fs::write(daemon.home.join("off-blip"), "").unwrap();
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 120): a pooled agent in full access
/// that a chat was claiming while MDM's off came and went is not handed to the chat after the
/// unset. It ran in full access while the off held, out of reach of the push's drain.
#[tokio::test(flavor = "multi_thread")]
async fn a_full_access_pooled_agent_claimed_through_an_mdm_off_is_not_taken() {
    let (daemon, mut rpc, _) = full_access_entry_claimed_through_an_off("fablip").await;
    let home = daemon.home.clone();
    blip_at_claim(&daemon);
    let (session, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(!taken(&daemon, &session), "a chat took a pooled agent that ran through MDM's off");
}

/// The same entry, when the chat that claimed it fails to start, does not go back to the pool.
#[tokio::test(flavor = "multi_thread")]
async fn a_full_access_pooled_agent_claimed_through_an_mdm_off_does_not_go_back() {
    let (daemon, mut rpc, _) = full_access_entry_claimed_through_an_off("faback").await;
    let home = daemon.home.clone();
    let (_first, _) = new_session(&mut rpc, &home, "fake").await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    blip_at_claim(&daemon);
    // The name is taken: the create fails after it claimed the pooled entry.
    let err = rpc
        .call_err(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb", "name": "fake"}}}),
        )
        .await;
    assert!(err.contains("taken"), "{err}");
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert!(!fakeb_ready(&status), "a pooled agent that ran through MDM's off went back: {status}");
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 122): a pooled agent whose start
/// saw MDM's off come and go, and that reports full access only as a chat takes it, is kept from
/// the chat after the unset: the take judges it under the entry's read (`Pooled::lived_off`).
/// One claimed through an off never gets that far (review 69).
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_agent_started_through_an_mdm_off_that_reports_at_the_take_is_kept_from_the_chat()
{
    let mut fakeb = profile("b");
    fakeb["env"]["FAKE_NO_MODES"] = json!("1");
    let daemon = Daemon::with_fakeb("fablipadopt", 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    std::fs::write(home.join("off-blip"), "").unwrap();
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    std::fs::write(home.join("adopt-report"), "bypassPermissions").unwrap();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let refused = created["error"]["message"].as_str().is_some_and(|m| m.contains("full-access"));
    assert!(refused, "a chat took a pooled agent started through MDM's off: {created}");
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 25): a harness whose own settings
/// start it in full access is never kept warm in the pool, where nothing runs `cap_full_access`
/// until a chat takes it. The pooled agent ends instead, and a chat starts cold.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_pooled_agent_that_came_up_in_full_access_is_not_kept() {
    let env = [("FAKE_FULL_ACCESS", "1"), ("FAKE_NEW_MODE", "full-access")];
    let (daemon, mut rpc, kept) = prewarmed_under_an_off("famdm", &env).await;
    assert!(!kept, "a pooled agent in full access was kept under the MDM off");
    let (claimed, _) = new_session(&mut rpc, &daemon.home, "fakeb").await;
    assert!(!taken(&daemon, &claimed), "a chat took the pooled agent in full access");
}

/// MDM forces `sessions.allowFullAccess` off (#23322, reviews 32, 46 and 70): a harness that reports
/// full access while its pooled session starts is not kept either, whatever it reported in its
/// other updates or its `session/new` answer, before or after. The reports are held with the
/// entry's other traffic until a chat takes it, so the check reads them there.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_pooled_agent_that_reported_full_access_at_start_is_not_kept() {
    for (tag, env, why) in [
        (
            "faheld",
            &[("FAKE_NO_MODES", "1"), ("FAKE_STARTUP_MODE", "bypassPermissions")][..],
            "reported bypassPermissions, declaring no modes",
        ),
        (
            "famask",
            &[
                ("FAKE_FULL_ACCESS", "1"),
                ("FAKE_NEW_MODE", "full-access"),
                ("FAKE_STARTUP_MODE", "normal"),
            ],
            "answered in full access after reporting an asking mode",
        ),
        (
            "fablank",
            &[
                ("FAKE_NO_MODES", "1"),
                ("FAKE_STARTUP_MODE", "bypassPermissions"),
                ("FAKE_STARTUP_SID", ""),
            ],
            "reported bypassPermissions under an empty session id (review 70)",
        ),
        (
            "fablanknew",
            &[
                ("FAKE_NO_MODES", "1"),
                ("FAKE_STARTUP_MODE", "bypassPermissions"),
                ("FAKE_NEW_RESULT_SID", ""),
            ],
            "reported bypassPermissions and answered with an empty session id (review 74)",
        ),
    ] {
        let (_daemon, _rpc, kept) = prewarmed_under_an_off(tag, env).await;
        assert!(!kept, "a pooled agent that {why} was kept under the MDM off");
    }
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 73): a pooled agent that reports full
/// access while it starts and then holds its `session/new` answer ends then, not at the answer.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_starting_pooled_agent_that_reports_full_access_ends_then() {
    let hold = std::env::temp_dir().join(format!("asp-hold-{}", std::process::id()));
    std::fs::write(&hold, "").unwrap();
    let path = hold.to_string_lossy().into_owned();
    let env = [
        ("FAKE_NO_MODES", "1"),
        ("FAKE_STARTUP_MODE", "bypassPermissions"),
        ("FAKE_NEW_HOLD", path.as_str()),
    ];
    let started = Instant::now();
    let (_daemon, _rpc, kept) = prewarmed_under_an_off("fastart", &env).await;
    let waited = started.elapsed();
    let _ = std::fs::remove_file(&hold);
    let _ = std::fs::remove_file(format!("{path}.reported"));
    assert!(!kept, "a pooled agent that reported full access while it started was kept");
    assert!(
        waited < Duration::from_secs(12),
        "a starting pooled agent in full access ran on under the off until it answered: {waited:?}"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 71): a report of full access that
/// comes after the take's check, before the entry's lines go to the chat, still keeps the agent
/// from the chat, though the chat may not have read it yet when the start is capped.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_report_held_past_the_take_keeps_the_agent_from_the_chat() {
    let env = [("FAKE_NO_MODES", "1")];
    let (daemon, mut rpc, kept) = prewarmed_under_an_off("faadopt", &env).await;
    assert!(kept, "fakeb reports nothing before it is taken, so it is kept");
    std::fs::write(daemon.home.join("adopt-report"), "bypassPermissions").unwrap();
    let home = daemon.home.clone();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let refused = created["error"]["message"].as_str().is_some_and(|m| m.contains("full-access"));
    assert!(
        refused,
        "a chat took a pooled agent that reported full access under the off: {created}"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 77): a report of full access held as
/// a chat takes a pooled agent keeps the agent from the chat, though MDM's off is unset before
/// the handoff.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_report_at_the_handoff_keeps_the_agent_from_the_chat_after_an_unset() {
    let env = [("FAKE_NO_MODES", "1")];
    let (daemon, mut rpc, kept) = prewarmed_under_an_off("fahand", &env).await;
    assert!(kept, "fakeb reports nothing before it is taken, so it is kept");
    std::fs::write(daemon.home.join("adopt-report"), "bypassPermissions unset").unwrap();
    let home = daemon.home.clone();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let refused = created["error"]["message"].as_str().is_some_and(|m| m.contains("full-access"));
    assert!(
        refused,
        "a chat took a pooled agent that reported full access under the off: {created}"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 69): a pooled agent a chat claims while
/// an off begins escapes the drain that off's push runs (only ready entries drain). Though the off
/// is unset before the chat takes it, the chat starts cold instead, as for every entry started
/// under the old bound.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_agent_claimed_as_an_off_began_is_not_taken_after_an_unset() {
    let daemon = Daemon::with_fakeb("faclaimoff", 0, &profile("b"));
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert!(fakeb_ready(&warmed), "{warmed}");
    std::fs::write(home.join("claim-off"), "").unwrap();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let id = created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}"));
    assert!(!taken(&daemon, id), "a chat took a pooled agent claimed as an off began");
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 69): an off pushed as a chat takes the
/// pooled agent it claimed, past the take's checks, and unset right after, still ends that agent
/// when its profile pins full access (`--yolo`): the chat's start is refused under the off, or the
/// push ends what runs in full access once the chat has it, and the unset waits for that.
#[tokio::test(flavor = "multi_thread")]
async fn a_pinned_pooled_agent_taken_as_an_off_comes_and_goes_ends() {
    let mut fakeb = profile("b");
    fakeb["argv"].as_array_mut().unwrap().push(json!("--yolo"));
    let daemon = Daemon::with_fakeb("fatakeoff", 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert!(fakeb_ready(&warmed), "{warmed}");
    let pooled = daemon.pool_records().into_iter().next().expect("a pooled agent");
    let harness_pid = pooled["harness_pid"].as_i64().expect("its harness pid");
    std::fs::write(home.join("take-off"), "").unwrap();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let refused = created["error"]["data"]["reason"] == "full_access_off";
    let id = created["result"]["sessionId"].as_str();
    assert!(refused || id.is_some_and(|id| taken(&daemon, id)), "not the take: {created}");
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "a pinned pooled agent ran on after an off came and went as a chat took it"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, review 76): a pooled agent that reports full
/// access while a chat claims it, out of both the ready and the claimed entries, is not handed to
/// the chat, though MDM's off is unset before the chat takes it.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_report_while_claimed_keeps_the_agent_from_the_chat_after_an_unset() {
    let env = [("FAKE_NO_MODES", "1")];
    let (daemon, mut rpc, kept) = prewarmed_under_an_off("faclaim", &env).await;
    assert!(kept, "fakeb reports nothing before it is claimed, so it is kept");
    std::fs::write(daemon.home.join("claim-report"), "bypassPermissions").unwrap();
    let home = daemon.home.clone();
    let created = rpc
        .raw(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}}),
        )
        .await;
    let id = created["result"]["sessionId"].as_str().unwrap_or_default().to_owned();
    assert!(
        id.is_empty() || !taken(&daemon, &id),
        "a chat took a pooled agent that reported full access under the off: {created}"
    );
}

/// MDM forces `sessions.allowFullAccess` off (#23322, reviews 46 and 74): a ready pooled agent that
/// reports full access while it waits ends then, though no chat takes it, and though its
/// `session/new` answer named a blank session id.
#[tokio::test(flavor = "multi_thread")]
async fn under_an_mdm_off_a_ready_pooled_agent_that_reports_full_access_ends() {
    let late = [("FAKE_NO_MODES", "1"), ("FAKE_LATE_MODE", "bypassPermissions")];
    let blank = [late[0], late[1], ("FAKE_NEW_RESULT_SID", "")];
    for (tag, env) in [("falate", &late[..]), ("falateblank", &blank[..])] {
        let (_daemon, mut rpc, kept) = prewarmed_under_an_off(tag, env).await;
        assert!(kept, "{tag}: fakeb reports nothing until it is ready, so it is kept then");
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let status = rpc.call("_acpmux/status", json!({})).await;
            if !fakeb_ready(&status) {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "{tag}: a ready pooled agent that reported full access stayed under the MDM off: {status}"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

/// `sessions.allowFullAccess` off and a pooled chat in full access whose harness never answers
/// the switch to a mode that asks: taking it is bounded by the start budget like a cold start,
/// so `session/new` fails with a deadline and ends the host instead of hanging on `spawn_lock`.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_chat_whose_harness_never_leaves_full_access_fails_with_a_deadline() {
    let mut fakeb = profile("b");
    fakeb["env"]["FAKE_FULL_ACCESS"] = json!("1");
    fakeb["env"]["FAKE_NEW_MODE"] = json!("full-access");
    fakeb["env"]["FAKE_SET_MODE_SILENT"] = json!("1");
    let off = json!({"sessions": {"allowFullAccess": false}});
    let daemon = Daemon::with_settings("fahang", 0, &fakeb, Some(off));
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let config = home.join("config.json");
    let mut cfg: Value = serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
    cfg["agentStartTimeoutMs"] = json!(2_000);
    std::fs::write(&config, cfg.to_string()).unwrap();
    rpc.call("_acpmux/reload_config", json!({})).await;
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fakeb").await;
    let params = json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeb"}}});
    let refused =
        tokio::time::timeout(Duration::from_secs(30), rpc.call_err("session/new", params))
            .await
            .expect("session/new hung on a harness that never left full access");
    assert!(refused.contains("agent_start did not finish within"), "{refused}");
    // The host still in full access was ended, so nothing re-adopts it.
    let deadline = Instant::now() + Duration::from_secs(10);
    while !daemon.host_records().is_empty() {
        assert!(
            Instant::now() < deadline,
            "the full-access host runs: {:#?}",
            daemon.host_records()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// LAUNCH-NO-TCC-PROMPTS: an agent nobody asked for (a prewarm, a warm) never
/// starts without a folder or in `/`, and a session without a folder is
/// refused instead of running in the home folder.
#[tokio::test(flavor = "multi_thread")]
async fn no_agent_starts_unasked_in_root_or_without_a_folder() {
    let daemon = Daemon::new("guard", 0);
    let mut rpc = daemon.rpc().await;
    let none = rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "wait": true})).await;
    assert_eq!(none["accepted"], false, "{none}");
    let root =
        rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": "/", "wait": true})).await;
    assert_eq!(root["accepted"], false, "{root}");
    assert!(daemon.pool_records().is_empty(), "nothing was pooled");

    let refused = rpc.call_err("session/new", json!({"mcpServers": []})).await;
    assert!(refused.contains("no folder"), "{refused}");

    // A person may name `/`; a later warm still leaves it alone.
    let made = rpc.call("session/new", json!({"cwd": "/", "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let warmed = rpc.call("_acpmux/warm", json!({"sessionIds": [id], "limit": 3})).await;
    assert_eq!(warmed["warmed"], json!([]), "{warmed}");
}

/// `acpmux daemon shutdown` (the CLI, as rollback scripts run it) stops the
/// daemon and every agent host it owns: the user session's host and the
/// pooled one. It returns only after they all exited and reports the counts.
#[tokio::test(flavor = "multi_thread")]
async fn the_shutdown_command_ends_every_agent_host_and_reports_the_counts() {
    let mut daemon = Daemon::new("cli", 0);
    let home = daemon.home.clone();
    let mut rpc = daemon.rpc().await;
    let (session, _) = new_session(&mut rpc, &home, "fake").await;
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    drop(rpc);
    let deadline = Instant::now() + Duration::from_secs(30);
    while !daemon.host_records().iter().any(|r| r["session_id"] == session.as_str()) {
        assert!(Instant::now() < deadline, "the session never got an agent host");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let records: Vec<Value> =
        daemon.host_records().into_iter().chain(daemon.pool_records()).collect();
    assert!(records.len() >= 2, "a session host and a pooled host: {records:#?}");
    let pids: Vec<i64> = records
        .iter()
        .flat_map(|r| [r["host_pid"].as_i64(), r["harness_pid"].as_i64()])
        .flatten()
        .collect();

    let out = daemon_env::acpmux(&home)
        .args(["--json", "daemon", "shutdown", "--end-agents"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .output()
        .expect("run acpmux daemon shutdown");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "shutdown failed: {stdout} {}",
        String::from_utf8_lossy(&out.stderr)
    );
    daemon.wait_exit();
    for pid in pids {
        // The command returned after every host exited; only a zombie's
        // reaping may still be in flight.
        assert!(
            gone_within(pid, Duration::from_secs(2)),
            "pid {pid} outlived `daemon shutdown`: {stdout}"
        );
    }
    let report: Value = serde_json::from_str(stdout.trim()).expect("JSON report");
    assert_eq!(report["stopped"], true, "{report}");
    assert_eq!(report["endAgents"], true, "{report}");
    assert!(report["agentHosts"]["before"].as_u64().unwrap() >= 2, "{report}");
    assert_eq!(report["agentHosts"]["left"], json!([]), "{report}");
}

/// The pid of the setsid helper that harness `harness` started
/// (`FAKE_SETSID_CHILD`).
fn helper_of(file: &Path, harness: i64) -> i64 {
    let path = format!("{}.{harness}", file.display());
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    text.trim().parse().unwrap()
}

fn kinds<'a>(events: &'a [Value], kind: &str) -> Vec<&'a Value> {
    events.iter().filter(|e| e["dir"] == "mux" && e["kind"] == kind).collect()
}

/// End a harness group a test left behind (its host was killed, so nothing
/// else ends it), only while that group still exists under its leader.
fn end_group(pid: i64) {
    // SAFETY: getpgid only reads; the group is the one this test's daemon
    // started while its leader still leads it.
    unsafe {
        if libc::getpgid(pid as i32) == pid as i32 {
            libc::killpg(pid as i32, libc::SIGKILL);
        }
    }
}

/// The Chief's subagent died on "agent host did not answer hello within 5s"
/// (2026-10-14). A host that misses its hello is ended and one fresh host
/// takes its place: the session/new succeeds and the session works.
#[tokio::test(flavor = "multi_thread")]
async fn a_new_session_whose_host_misses_hello_starts_on_a_fresh_host() {
    let daemon = Daemon::new("hello1", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    daemon.stall_hellos(1);
    let (id, took) = new_session(&mut rpc, &home, "fake").await;
    eprintln!("session/new with one wedged host: {took:?}");
    assert_eq!(daemon.stalls_left(), 0, "the first host took the stall");
    let events = daemon.events(&id);
    let started = kinds(&events, "host_started");
    let unanswered = kinds(&events, "host_unanswered");
    assert_eq!(started.len(), 2, "one fresh host after the wedged one: {events:#?}");
    assert_eq!(unanswered.len(), 1, "{events:#?}");
    let wedged = unanswered[0]["msg"]["hostPid"].as_i64().unwrap();
    assert_eq!(started[0]["msg"]["hostPid"].as_i64(), Some(wedged));
    assert_eq!(unanswered[0]["msg"]["ended"], true, "{events:#?}");
    assert!(gone_within(wedged, Duration::from_secs(10)), "the wedged host still runs");
    let fresh = started[1]["msg"]["hostPid"].as_i64().unwrap();
    let records = daemon.host_records();
    assert_eq!(records.len(), 1, "{records:#?}");
    assert_eq!(records[0]["host_pid"].as_i64(), Some(fresh));
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
}

/// No retry loop: when the fresh host also misses its hello, session/new
/// fails with both causes, and both hosts are ended.
#[tokio::test(flavor = "multi_thread")]
async fn a_new_session_fails_clearly_when_the_fresh_host_also_misses_hello() {
    let daemon = Daemon::new("hello2", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    daemon.stall_hellos(3);
    let err = rpc
        .call_err(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        )
        .await;
    assert!(err.contains("did not answer hello"), "{err}");
    assert!(err.contains("a fresh agent host also failed"), "{err}");
    assert_eq!(daemon.stalls_left(), 1, "exactly two hosts started");
    assert!(daemon.host_records().is_empty(), "both hosts were ended");
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["liveAgents"], 0, "{status}");
    assert_eq!(status["sessions"], 0, "the failed session is not left behind: {status}");
}

/// A pooled host that stopped answering (wedged: its link stays open) is
/// not served: it is ended and the session starts on a fresh host.
#[tokio::test(flavor = "multi_thread")]
async fn a_wedged_pooled_host_is_ended_and_the_session_starts_on_a_fresh_host() {
    let daemon = Daemon::new("wedge", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    // The pooled harness starts a helper that leaves its process group, as
    // a harness's background shell does.
    let helper_file = home.join("helper.pid");
    let mut with_helper = profile("b");
    with_helper["env"]["FAKE_SETSID_CHILD"] = json!(helper_file);
    daemon.write_config(&with_helper);
    rpc.call("_acpmux/reload_config", json!({})).await;
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let r = daemon.pool_records().pop().expect("a pooled host");
    let (host, harness) = (r["host_pid"].as_i64().unwrap(), r["harness_pid"].as_i64().unwrap());
    // The helper of this host's harness: the model probe's harness starts
    // one too, in its own file.
    let helper = helper_of(&helper_file, harness);
    // SAFETY: the exact pooled host this test's daemon started (its record).
    unsafe { libc::kill(host as i32, libc::SIGSTOP) };
    let (id, took) = new_session(&mut rpc, &home, "fakeb").await;
    eprintln!("session/new past a wedged pooled host: {took:?}");
    assert!(!taken(&daemon, &id), "the wedged entry was served");
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert!(gone_within(host, Duration::from_secs(15)), "the wedged pooled host still runs");
    // It could not end what runs under it: the daemon ended that with it.
    let ended = gone_within(helper, Duration::from_secs(10));
    end_group(harness);
    if !ended {
        // SAFETY: the exact helper pid the fake harness reported.
        unsafe { libc::kill(helper as i32, libc::SIGKILL) };
    }
    assert!(ended, "a process under the wedged host runs on without an owner");
}

/// A pooled host whose link stopped reading (an acknowledgement failed while its socket still
/// looks open) still answers the claim's query, but nothing it sends from then on is heard: it
/// is not served, it is ended, and the session starts on a fresh host.
#[tokio::test(flavor = "multi_thread")]
async fn a_pooled_host_whose_link_stopped_is_not_served() {
    let mut fakeb = profile("b");
    // Half a second after its `session/new` answer, once the entry is ready.
    fakeb["env"]["FAKE_LATE_MODE"] = json!(ACK_FAILS);
    let daemon = Daemon::with_fakeb("ackstop", 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let r = daemon.pool_records().pop().expect("a pooled host");
    let (host, harness) = (r["host_pid"].as_i64().unwrap(), r["harness_pid"].as_i64().unwrap());
    // Past the late report: the entry's reader stopped at it.
    tokio::time::sleep(Duration::from_millis(2000)).await;
    let (id, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(!taken(&daemon, &id), "the pooled host whose link stopped was served");
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    let reply = tokio::time::timeout(Duration::from_secs(30), rpc.call("session/prompt", prompt))
        .await
        .expect("the prompt was answered");
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert!(gone_within(host, Duration::from_secs(15)), "the pooled host whose link stopped runs");
    end_group(harness);
}

/// A pooled host that died is not served either.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_pooled_host_is_not_served_and_the_session_starts_on_a_fresh_host() {
    let daemon = Daemon::new("deadp", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let r = daemon.pool_records().pop().expect("a pooled host");
    let (host, harness) = (r["host_pid"].as_i64().unwrap(), r["harness_pid"].as_i64().unwrap());
    // SAFETY: the exact pooled host this test's daemon started (its record).
    unsafe { libc::kill(host as i32, libc::SIGKILL) };
    assert!(gone_within(host, Duration::from_secs(10)));
    let (id, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(!taken(&daemon, &id), "the dead entry was served");
    let reply = rpc
        .call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    end_group(harness);
}

impl Rpc {
    /// The agent text streamed while `session` answers `text`.
    async fn prompt_text(&mut self, session: &str, text: &str) -> String {
        self.next += 1;
        let id = self.next;
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let line =
            json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": prompt});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        let mut streamed = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{v}");
                return streamed;
            }
            let chunk = v.pointer("/params/update/content/text").and_then(Value::as_str);
            if v.pointer("/params/sessionId") == Some(&json!(session))
                && let Some(t) = chunk
            {
                streamed.push_str(t);
            }
        }
    }
}

/// An OpenCode chat whose permission policy is narrower than approve-all never takes a pooled
/// agent started without OpenCode asked to ask (the pool key holds the spawn env,
/// `hub/policy_mode.rs`): it starts cold, on an agent host, with `OPENCODE_CONFIG_CONTENT`
/// asking before every tool. An approve-all chat takes the pooled agent, which runs with none.
#[tokio::test(flavor = "multi_thread")]
async fn opencode_policy_a_pooled_agent_is_never_taken_by_a_chat_it_would_not_ask_for() {
    let fakeb = json!({"argv": ["python3", FAKE], "family": "opencode"});
    let daemon = Daemon::with_fakeb("ocask", 0, &fakeb);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    let config = |text: String| match text.strip_prefix("OPENCODE_CONFIG_CONTENT=") {
        Some("") => Value::Null,
        Some(v) => serde_json::from_str(v).unwrap_or_else(|e| panic!("{v:?}: {e}")),
        None => panic!("the agent names the variable: {text:?}"),
    };
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let meta = json!({"harness": "fakeb", "policy": "approve-reads"});
    let created = rpc
        .call("session/new", json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": meta}}))
        .await;
    let narrow = created["sessionId"].as_str().expect("session id").to_owned();
    assert!(!taken(&daemon, &narrow), "the pooled agent does not ask: never taken");
    assert!(
        daemon.host_records().iter().any(|r| r["session_id"] == narrow.as_str()),
        "the chat's agent runs on an agent host"
    );
    let seen = rpc.prompt_text(&narrow, "env: OPENCODE_CONFIG_CONTENT").await;
    assert_eq!(config(seen), json!({"permission": {"*": "ask"}}));

    // An approve-all chat takes a pooled agent, which OpenCode's own settings drive.
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fakeb").await;
    let (wide, _) = new_session(&mut rpc, &home, "fakeb").await;
    assert!(taken(&daemon, &wide), "an approve-all chat takes the pooled agent");
    let seen = rpc.prompt_text(&wide, "env: OPENCODE_CONFIG_CONTENT").await;
    assert_eq!(config(seen), Value::Null);
}

/// Test polling: wait until the pool holds exactly `n` entries.
async fn wait_pool_len(rpc: &mut Rpc, n: usize) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = rpc.call("_acpmux/status", json!({})).await;
        if status["pool"]["entries"].as_array().map(Vec::len) == Some(n) {
            return status;
        }
        assert!(Instant::now() < deadline, "the pool never held {n} entries: {status}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The agent pid of the pool's only record.
fn only_pooled_pid(daemon: &Daemon) -> i64 {
    let records = daemon.pool_records();
    assert_eq!(records.len(), 1, "{records:?}");
    records[0]["harness_pid"].as_i64().expect("harness pid")
}

/// Typing in a new chat hints its harness in that chat's folder. A person who types in a new
/// chat in another folder keeps one warm agent of that harness, not one per folder: the older
/// folder's entry ends (`pool.hintedPerHarness`, default 1).
#[tokio::test(flavor = "multi_thread")]
async fn a_typing_hint_in_another_folder_keeps_one_pooled_session_per_harness() {
    let daemon = Daemon::new("cap", 0);
    let mut rpc = daemon.rpc().await;
    let (a, b) = (daemon.home.join("a"), daemon.home.join("b"));
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();
    let warmed =
        rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": a, "wait": true})).await;
    assert_eq!(warmed["accepted"], true, "{warmed}");
    wait_pool_ready(&mut rpc, "fake").await;
    let first = only_pooled_pid(&daemon);

    rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": b, "wait": true})).await;
    let status = wait_pool_len(&mut rpc, 1).await;
    let entry = &status["pool"]["entries"][0];
    assert_eq!(entry["cwd"], json!(b), "{status}");
    assert_eq!(entry["state"], "ready", "{status}");
    assert!(
        gone_within(first, Duration::from_secs(10)),
        "the first folder's warm agent still runs"
    );

    // Another harness keeps its own warm agent beside it.
    rpc.call("_acpmux/prewarm", json!({"harness": "fakeb", "cwd": a, "wait": true})).await;
    wait_pool_len(&mut rpc, 2).await;
}

/// The person cleared a new chat's prompt or closed its tab: the pane releases its hint and the
/// warm agent ends at once instead of idling until `pool.idleMinutes`.
#[tokio::test(flavor = "multi_thread")]
async fn a_released_hint_ends_its_pooled_session() {
    let daemon = Daemon::new("rel", 0);
    let mut rpc = daemon.rpc().await;
    let home = daemon.home.clone();
    rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": home, "wait": true})).await;
    wait_pool_ready(&mut rpc, "fake").await;
    let pid = only_pooled_pid(&daemon);

    let released =
        rpc.call("_acpmux/prewarm", json!({"harness": "fake", "cwd": home, "release": true})).await;
    assert_eq!(released["released"], 1, "{released}");
    wait_pool_len(&mut rpc, 0).await;
    assert!(gone_within(pid, Duration::from_secs(10)), "the released warm agent still runs");
    // The next chat there starts cold: nothing was left to take.
    let (id, _) = new_session(&mut rpc, &home, "fake").await;
    assert!(!taken(&daemon, &id));
}
