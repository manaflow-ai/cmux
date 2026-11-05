//! A session's harness starts at normal CPU class and runs below the GUI's once its start is over
//! (macOS, `cpu_class.rs`): background (`PRIO_DARWIN_BG`) unless its profile, the daemon's env or
//! config asks for `normal`. A start has a deadline, and at background class a busy disk held a
//! harness past it (2026-10-30), so the daemon lowers the running harness only after its
//! `session/new` answered; the tools its turns start inherit the class. A start that still misses
//! its deadline at background class runs once more, and a start that misses it names what its
//! harness was doing.
//!
//! The class is read with `ps -o pri=`: the scheduler's base priority, 4 for a background
//! (darwinbg) process, 20 under an agent host's utility clamp (`qos.rs`) and 31 for a default one.
//! The stand-in agent (`fake_agent.py`) logs its own priority as it answers `session/new`
//! (`FAKE_CLASS_LOG`), and a "class-probe" prompt starts a tool and reports its pid.

#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). The reference test's
// variable is set as the process starts, never while tests run. `ACPMUX_QOS=background` puts the
// agent hosts this process starts in background class (`qos.rs`), so a hosted harness would
// inherit it: the hosted test checks that its harness clears it at its exec. The in-process hubs
// start their harnesses directly and read no `ACPMUX_QOS`.
// The hermetic environment keeps stand-ins at normal class (`daemon_env::vars`); these tests
// check the product's background class, so this process and its daemons ask for it.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().with_env(&[
    ("ACPMUX_TEST_CPU_CLASS_REF", "normal"),
    ("ACPMUX_QOS", "background"),
    ("ACPMUX_SESSION_CPU_CLASS", "background"),
]);

use acpmux::agent::{Attached, ChildAgent};
use acpmux::agent_host::link::{self, HostLauncher};
use acpmux::agent_host::{self, SpawnSpec};
use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::cpu_class::CpuClass;
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The scheduler's base priority of a darwinbg process (`MAXPRI_THROTTLE`).
const BACKGROUND_PRI: u32 = 4;
/// The in-process daemon's person key (`hub/person.rs`), as a daemon the app started holds one.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("acp-cpu-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// `ps -o pri=` of `pid`.
fn base_priority(pid: i32) -> u32 {
    let out = std::process::Command::new("/bin/ps")
        .args(["-o", "pri=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap_or_else(|_| {
        panic!("ps -o pri= -p {pid}: {:?}", String::from_utf8_lossy(&out.stdout))
    })
}

/// The class part of `pid`'s priority: the lowest of a few reads. The kernel raises a thread's
/// priority for a moment while it holds what a higher thread waits for (a host read 46 once,
/// under a background class, on a loaded fleet Mac), never lowers it below its class.
fn class_priority(pid: i32) -> u32 {
    (0..5).map(|_| base_priority(pid)).min().unwrap_or(u32::MAX)
}

/// These checks compare a harness's class with its starter's: a runner at background class
/// (set on it by another process, which a child cannot clear) makes them meaningless.
fn runs_above_background() {
    let own = base_priority(std::process::id() as i32);
    assert!(own > BACKGROUND_PRI, "the test process itself runs at background class (pri {own})");
}

/// `ps -o ppid=` of `pid`.
fn parent(pid: i32) -> i32 {
    let out = std::process::Command::new("/bin/ps")
        .args(["-o", "ppid=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
}

fn kill(pid: i32) {
    // SAFETY: signals one process this test started.
    unsafe { libc::kill(pid, libc::SIGKILL) };
}

/// The JSON a stand-in wrote to `path` (written whole: a rename).
fn read_json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// The ACP client of an in-process daemon, as the app is.
struct Client {
    tx: tokio::sync::mpsc::Sender<String>,
    rx: tokio::sync::mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }

    async fn new_session(&mut self, dir: &Path, name: &str) -> Result<String, String> {
        let params = json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": name}}});
        let created = self.request(method::SESSION_NEW, params).await?;
        Ok(created["sessionId"].as_str().unwrap().to_owned())
    }

    /// A "class-probe" turn: the pid of the tool it started.
    async fn probe_tool(&mut self, id: &str, dir: &Path) -> i32 {
        let out = dir.join("tool.json");
        let text = format!("class-probe: {}", out.display());
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        self.request(method::SESSION_PROMPT, prompt).await.unwrap();
        read_json(&out)["sleeper"].as_i64().unwrap() as i32
    }
}

/// An in-process daemon whose one harness is the stand-in agent with `env` (its direct child: no
/// agent hosts), and its person client.
async fn daemon(env: BTreeMap<String, String>) -> (Arc<Hub>, Client) {
    runs_above_background();
    let profile: HarnessProfile =
        serde_json::from_value(json!({"argv": ["python3", FAKE], "env": env})).unwrap();
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, out_rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = Client { tx: in_tx, rx: out_rx, next: 0 };
    let init = client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    client.request("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
    (hub, client)
}

/// A connection that is not the person (no `_acpmux/person_prove`): an agent's or a lane's
/// `acpmux` client.
fn agent_client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, out_rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection(hub.clone(), in_rx, out_tx));
    Client { tx: in_tx, rx: out_rx, next: 0 }
}

/// The stand-in's env: its class log in `dir`, plus `more`.
fn logged(dir: &Path, more: &[(&str, &str)]) -> BTreeMap<String, String> {
    let mut env = BTreeMap::from([(
        "FAKE_CLASS_LOG".to_owned(),
        dir.join("class.log").to_string_lossy().into_owned(),
    )]);
    env.extend(more.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
    env
}

/// Each harness's (pid, priority as it answered `session/new`), oldest first.
fn class_log(dir: &Path) -> Vec<(i32, u32)> {
    std::fs::read_to_string(dir.join("class.log"))
        .unwrap_or_default()
        .lines()
        .map(|l| {
            let v: Value = serde_json::from_str(l).unwrap();
            (v["pid"].as_i64().unwrap() as i32, v["pri"].as_u64().unwrap() as u32)
        })
        .collect()
}

#[tokio::test]
async fn cpu_class_a_session_starts_at_normal_class_and_runs_at_background_once_started() {
    let dir = scratch("s");
    let (_hub, mut c) = daemon(logged(&dir, &[])).await;
    let id = c.new_session(&dir, "bg").await.unwrap();
    let [(harness, at_start)] = class_log(&dir)[..] else { panic!("{:?}", class_log(&dir)) };
    let running = class_priority(harness);
    let tool = c.probe_tool(&id, &dir).await;
    let tool_pri = class_priority(tool);
    kill(tool);
    assert!(at_start > BACKGROUND_PRI, "the harness answered session/new at background class");
    assert_eq!(running, BACKGROUND_PRI, "the started session's harness runs at the GUI's class");
    assert_eq!(tool_pri, BACKGROUND_PRI, "a tool its turn started runs at the GUI's class");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn cpu_class_a_profile_can_keep_its_harness_at_normal_class() {
    let dir = scratch("n");
    let (_hub, mut c) = daemon(logged(&dir, &[("ACPMUX_SESSION_CPU_CLASS", "normal")])).await;
    let id = c.new_session(&dir, "normal").await.unwrap();
    let [(harness, _)] = class_log(&dir)[..] else { panic!("{:?}", class_log(&dir)) };
    let tool = c.probe_tool(&id, &dir).await;
    let (h, t) = (base_priority(harness), base_priority(tool));
    kill(tool);
    assert!(h > BACKGROUND_PRI, "the opted-out harness was lowered: pri {h}");
    assert!(t > BACKGROUND_PRI, "the opted-out harness's tool was lowered: pri {t}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn cpu_class_a_profile_reference_that_resolves_to_normal_keeps_normal_class() {
    let dir = scratch("r");
    // ACPMUX_TEST_CPU_CLASS_REF=normal: set for this process by HERMETIC.
    let class = ("ACPMUX_SESSION_CPU_CLASS", "${env:ACPMUX_TEST_CPU_CLASS_REF}");
    let (_hub, mut c) = daemon(logged(&dir, &[class])).await;
    c.new_session(&dir, "ref").await.unwrap();
    let [(harness, _)] = class_log(&dir)[..] else { panic!("{:?}", class_log(&dir)) };
    let h = base_priority(harness);
    assert!(h > BACKGROUND_PRI, "a reference that resolves to normal was lowered: pri {h}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A harness that cannot finish its start (`FAKE_START_GATE`, a busy disk's stand-in): the
/// `agent_start` deadline error names its process, class, run time and threads, and a start at
/// normal class is not run again.
#[tokio::test]
async fn cpu_class_a_start_that_misses_its_deadline_says_what_its_harness_was_doing() {
    let dir = scratch("t");
    let gate = dir.join("gate");
    std::fs::write(&gate, b"").unwrap();
    let gate_env = ("FAKE_START_GATE", gate.to_str().unwrap());
    let (hub, _person) = daemon(logged(&dir, &[gate_env])).await;
    // An agent's connection: the person's start has no deadline (#28963, `hub/lifecycle.rs`
    // `person_start`), an agent's or a lane's keeps it.
    let mut c = agent_client(&hub);
    let id = c.new_session(&dir, "late").await.unwrap();
    // Stop the agent; the next prompt starts a fresh one that never reads.
    c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    std::fs::remove_file(&gate).unwrap();
    hub.config.write().await.agent_start_timeout_ms = Some(3_000);
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]});
    let refused = c.request(method::SESSION_PROMPT, prompt).await.expect_err("it started");
    assert!(refused.contains("agent_start did not finish within"), "{refused}");
    assert!(refused.contains("its agent process (pid "), "{refused}");
    assert!(refused.contains("is alive at normal CPU class (priority "), "{refused}");
    assert!(refused.contains(" s of CPU, ") && refused.contains(" threads running"), "{refused}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(
        !events.iter().any(|e| e.kind == "agent_start_retried_at_normal"),
        "a start at normal class was run again"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A start whose harness is put in background class by another process during its start
/// (`FAKE_BG_ONCE`: the first harness then fails its `initialize` and stays alive) runs once
/// more; the retry is logged with that harness's state, and the session starts.
#[tokio::test]
async fn cpu_class_a_start_that_fails_at_background_class_runs_once_more() {
    let dir = scratch("b");
    let once = dir.join("bg-once");
    let (hub, mut c) = daemon(logged(&dir, &[("FAKE_BG_ONCE", once.to_str().unwrap())])).await;
    let id = c.new_session(&dir, "retried").await.expect("the retried start failed");
    assert!(once.exists(), "the first harness never started");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let retried =
        events.iter().find(|e| e.kind == "agent_start_retried_at_normal").unwrap_or_else(|| {
            panic!("no retry logged: {:?}", events.iter().map(|e| &e.kind).collect::<Vec<_>>())
        });
    let harness = &retried.msg["harness"];
    assert_eq!(harness["background"], json!(true), "{harness}");
    assert_eq!(retried.msg["timedOut"], json!(false), "{}", retried.msg);
    // The second harness answered session/new at normal class.
    let [(_, at_start)] = class_log(&dir)[..] else { panic!("{:?}", class_log(&dir)) };
    assert!(at_start > BACKGROUND_PRI, "the retried harness started at background class");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The agent host this process starts runs in background class (`ACPMUX_QOS=background`, set by
/// HERMETIC). Its harness clears that class at its exec, so the harness and a tool it starts as it
/// starts run above it; once its start is over the daemon lowers the harness, and a tool its turn
/// starts inherits that.
#[tokio::test]
async fn cpu_class_a_hosted_harness_starts_at_normal_under_a_background_host_then_runs_below() {
    let dir = scratch("h");
    let fifo = dir.join("pids");
    let c = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let script = format!(
        "sleep 120 & echo \"$$ $!\" > {}; exec python3 {}",
        daemon_env::sh_quote(fifo.display()),
        daemon_env::sh_quote(FAKE)
    );
    let hosts = dir.join("hosts");
    // As the daemon sends it (`hub/hosts.rs`).
    let spec: SpawnSpec = serde_json::from_value(json!({
        "session_id": "s-cpu-h",
        "program": "/bin/sh",
        "args": ["-c", script],
        // The stand-in's environment: never the host's (its PATH has real agents).
        "env": daemon_env::vars(&dir, daemon_env::Agents::StandIn, &[]),
        "cwd": dir,
        "translator": null,
        "socket": agent_host::socket_path(&hosts, "s-cpu-h"),
        "hosts_dir": hosts,
        "buffer_cap": agent_host::DEFAULT_BUFFER_CAP,
    }))
    .unwrap();
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let record = link::spawn(&launcher, &spec).await.expect("spawn the host");
    let host_pri = class_priority(record.host_pid as i32);
    let line = tokio::time::timeout(
        Duration::from_secs(20),
        tokio::task::spawn_blocking(move || std::fs::read_to_string(fifo).unwrap()),
    )
    .await
    .expect("the harness did not write its pids")
    .unwrap();
    let mut pids = line.split_whitespace().map(|p| p.parse::<i32>().unwrap());
    let (harness, starter_tool) = (pids.next().unwrap(), pids.next().unwrap());
    assert_eq!(record.harness_pid, Some(harness as u32));
    let (at_start, starter_tool_pri) = (base_priority(harness), base_priority(starter_tool));
    kill(starter_tool);

    let (inbound, _rx) = tokio::sync::mpsc::channel(64);
    let tap: acpmux::agent::Tap = Arc::new(|_, _, _| true);
    let Attached::Ready(agent, ..) =
        ChildAgent::attach_hosted("fake", record.clone(), 0, Vec::new(), inbound, tap)
            .await
            .unwrap()
    else {
        panic!("the host refused its controller")
    };
    agent.request(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let new = agent.request(method::SESSION_NEW, json!({"cwd": dir, "mcpServers": []})).await;
    let sid = new.unwrap()["sessionId"].as_str().unwrap().to_owned();
    // The start is over (as `ensure_child` ends it).
    agent.set_run_class(CpuClass::Background);
    assert!(agent.enter_run_class().await, "the running harness was not lowered");
    let running = class_priority(harness);
    let out = dir.join("tool.json");
    let text = format!("class-probe: {}", out.display());
    let prompt = json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]});
    agent.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let tool = read_json(&out)["sleeper"].as_i64().unwrap() as i32;
    let tool_pri = class_priority(tool);
    kill(tool);
    // SAFETY: signals the process group the harness leads.
    unsafe { libc::killpg(harness, libc::SIGKILL) };
    drop(agent);
    kill(record.host_pid as i32);
    assert_eq!(host_pri, BACKGROUND_PRI, "the host did not run at background class");
    assert!(at_start > BACKGROUND_PRI, "the hosted harness started at background class");
    assert!(starter_tool_pri > BACKGROUND_PRI, "a tool its start ran is at background class");
    assert_eq!(running, BACKGROUND_PRI, "the started harness runs at the GUI's class");
    assert_eq!(tool_pri, BACKGROUND_PRI, "a tool its turn started runs at the GUI's class");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A real daemon (`acpmux daemon run`, agent hosts on, a store on disk) whose one harness is the
/// stand-in agent with `env`.
struct RealDaemon {
    root: PathBuf,
    child: Option<std::process::Child>,
}

impl RealDaemon {
    fn start(tag: &str, env: &BTreeMap<String, String>) -> Self {
        runs_above_background();
        let root = scratch(tag);
        for sub in ["home", "amx", "work"] {
            std::fs::create_dir_all(root.join(sub)).unwrap();
        }
        let config = json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE], "env": env}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        });
        std::fs::write(root.join("amx").join("config.json"), config.to_string()).unwrap();
        let mut daemon = Self { root, child: None };
        let mut child = daemon
            .cmd()
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut out = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut seen = String::new();
        loop {
            let mut line = String::new();
            let n = std::io::BufRead::read_line(&mut out, &mut line).unwrap();
            assert!(n > 0, "daemon exited before it was ready: {seen}");
            if line.contains("\"ready\":true") {
                break;
            }
            seen.push_str(&line);
        }
        daemon.child = Some(child);
        daemon
    }

    fn cmd(&self) -> std::process::Command {
        let mut cmd = daemon_env::command(&self.root, daemon_env::Agents::StandIn, &[]);
        cmd.current_dir(self.root.join("work"))
            .env("ACPMUX_HOME", self.root.join("amx"))
            .env("ACPMUX_SOCKET", self.root.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .env(acpmux::cpu_class::ENV, "background")
            .env_remove("ACPMUX_SESSION_ID")
            .stdin(std::process::Stdio::null());
        cmd
    }
}

impl Drop for RealDaemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = self.cmd().args(["daemon", "shutdown", "--end-agents"]).output();
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Through the real daemon, whose harnesses run under agent hosts as in the app: a chat's harness
/// answers `session/new` above background class, runs at it once its start is over, and a tool
/// its turn starts inherits that.
#[test]
fn cpu_class_a_daemon_runs_a_hosted_harness_at_background_once_its_start_is_over() {
    let dir = scratch("dh");
    let daemon = RealDaemon::start("dd", &logged(&dir, &[]));
    let out = dir.join("tool.json");
    let probe = format!("class-probe: {}", out.display());
    let ran = daemon.cmd().args(["run", "--timeout", "60", &probe]).output().expect("run acpmux");
    assert!(ran.status.success(), "acpmux run failed: {}", String::from_utf8_lossy(&ran.stderr));
    let tool = read_json(&out)["sleeper"].as_i64().unwrap() as i32;
    let tool_pri = class_priority(tool);
    // The chat's harness is the tool's parent; a pooled harness may have logged too.
    let harness = parent(tool);
    let log = class_log(&dir);
    let at_start = log.iter().find(|(pid, _)| *pid == harness).map(|(_, pri)| *pri);
    let at_start = at_start.unwrap_or_else(|| panic!("harness {harness} is not in {log:?}"));
    let running = class_priority(harness);
    kill(tool);
    drop(daemon);
    assert!(
        at_start > BACKGROUND_PRI,
        "the hosted harness answered session/new at background class"
    );
    assert_eq!(running, BACKGROUND_PRI, "the started hosted harness runs at the GUI's class");
    assert_eq!(tool_pri, BACKGROUND_PRI, "a tool its turn started runs at the GUI's class");
    let _ = std::fs::remove_dir_all(&dir);
}
