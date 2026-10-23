//! The acpmux daemon's speed budgets (plans/cmux-next/perf-lead.md, "Daemon and acpmux
//! targets"): every request answers in under 2 ms p95 from send to reply, a streamed token
//! reaches an attached client in under 2 ms p95, and an idle daemon with live agents does not
//! wake. Measured on the real daemon binary, its real file store, its agent hosts and a
//! stand-in agent (`fake_stream_agent.py`, no model), in a light session (one chat) and in
//! STRESS (16 chats streaming at once to two attached clients while a third connection sends
//! requests). Every number goes to stderr as `ACPMUX-PERF` lines and to
//! `.build/acpmux-perf/perf_ops.json` at the repository root (a fleet step returns it with
//! `--artifact .build/acpmux-perf/perf_ops.json`).
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts the stand-in agent only.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::oneshot;

const AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_stream_agent.py");
/// The plan's budget for every daemon op and for a token's trip to a client.
const OP_P95: Duration = Duration::from_millis(2);
/// Requests timed per op in the light session (after a warm-up).
const ROUNDS: usize = 100;
/// Chats streaming at once in STRESS.
const STRESS_CHATS: usize = 16;
/// Chats streaming at once in the many-chats phase: more than the file store keeps open
/// (`store.rs` OPEN_LOGS, 64), as a STRESS app with an agent chat in each of 60 workspaces has.
const MANY_CHATS: usize = 72;
/// Idle windows; the daemon is judged by its median window.
const IDLE_WINDOW: Duration = Duration::from_secs(5);
const IDLE_WINDOWS: usize = 3;
/// Context switches allowed in a median idle window: a 1 Hz wake gives 5.
const IDLE_SWITCHES: u64 = 3;

fn now_ns() -> u64 {
    unsafe extern "C" {
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    /// Darwin's `CLOCK_UPTIME_RAW` (`<time.h>`): the clock the stand-in agent stamps its
    /// tokens on (Python's `time.CLOCK_UPTIME_RAW`).
    const CLOCK_UPTIME_RAW: u32 = 8;
    // SAFETY: no preconditions.
    unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// ------------------------------------------------------------------ daemon

struct Daemon {
    child: Child,
    socket: PathBuf,
    work: PathBuf,
}

impl Daemon {
    fn start(scratch: &Path) -> Self {
        let home = scratch.join("h");
        let work = scratch.join("work");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&work).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", AGENT]}}, "defaultHarness": "fake",
                   "permissionPolicy": "approve-all"})
            .to_string(),
        )
        .unwrap();
        let mut child = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", scratch.join("s.sock"))
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
            ready.clear();
        }
        assert!(ready.contains("\"ready\":true"), "daemon not ready");
        let socket = serde_json::from_str::<Value>(&ready)
            .ok()
            .and_then(|v| v["socket"].as_str().map(PathBuf::from))
            .unwrap_or_else(|| scratch.join("s.sock"));
        Self { child, socket, work }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: signalling this test's own child.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

// ------------------------------------------------------------------ client

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

/// One daemon connection. Its reader stamps every line as it arrives: replies go to their
/// caller, each streamed token's age (agent write to arrival) goes to `tokens`.
struct Client {
    writer: tokio::io::WriteHalf<UnixStream>,
    pending: Pending,
    tokens: Arc<Mutex<Vec<u64>>>,
    accepted: Arc<Mutex<HashMap<String, u64>>>,
    next: u64,
}

impl Client {
    async fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).await.expect("connect");
        let (rd, writer) = tokio::io::split(stream);
        let pending: Pending = Arc::default();
        let tokens: Arc<Mutex<Vec<u64>>> = Arc::default();
        let accepted: Arc<Mutex<HashMap<String, u64>>> = Arc::default();
        let (p, t, a) = (pending.clone(), tokens.clone(), accepted.clone());
        tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(rd).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let at = now_ns();
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                match v.get("method").and_then(Value::as_str) {
                    None => {
                        if let Some(id) = v.get("id").and_then(Value::as_u64)
                            && let Some(tx) = p.lock().unwrap().remove(&id)
                        {
                            let _ = tx.send(v);
                        }
                    }
                    Some("session/update") => {
                        let text = v.pointer("/params/update/content/text").and_then(Value::as_str);
                        if let Some(sent) = text.and_then(|t| {
                            t.strip_prefix('t')?.strip_suffix(';')?.parse::<u64>().ok()
                        }) {
                            t.lock().unwrap().push(at.saturating_sub(sent));
                        }
                    }
                    Some("_acpmux/prompt_accepted") => {
                        if let Some(id) = v.pointer("/params/promptId").and_then(Value::as_str) {
                            a.lock().unwrap().insert(id.to_owned(), at);
                        }
                    }
                    Some(_) => {}
                }
            }
        });
        let mut c = Self { writer, pending, tokens, accepted, next: 0 };
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "perf"}})).await;
        c
    }

    async fn send(&mut self, method: &str, params: Value) -> oneshot::Receiver<Value> {
        self.next += 1;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(self.next, tx);
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        rx
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let rx = self.send(method, params).await;
        let v = tokio::time::timeout(Duration::from_secs(60), rx).await.expect("reply").unwrap();
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }

    /// Send to reply, in ns.
    async fn timed(&mut self, method: &str, params: Value) -> u64 {
        let start = now_ns();
        self.call(method, params).await;
        now_ns() - start
    }

    async fn new_chat(&mut self, work: &Path) -> String {
        let v = self.call("session/new", json!({"cwd": work, "mcpServers": []})).await;
        v["sessionId"].as_str().expect("session id").to_owned()
    }

    fn take_tokens(&self) -> Vec<u64> {
        std::mem::take(&mut *self.tokens.lock().unwrap())
    }
}

// ------------------------------------------------------------------ numbers

#[derive(Default)]
struct Report {
    rows: serde_json::Map<String, Value>,
    over: Vec<String>,
}

fn pct(sorted: &[u64], p: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    sorted[((sorted.len() as f64 - 1.0) * p).round() as usize]
}

impl Report {
    /// One latency row in ms (p50, p95, max, n); over budget when p95 > `budget`.
    fn latency(&mut self, name: &str, mut ns: Vec<u64>, budget: Option<Duration>) {
        ns.sort_unstable();
        let ms = |v: u64| (v as f64 / 1e6 * 1000.0).round() / 1000.0;
        let (p50, p95, max) = (pct(&ns, 0.5), pct(&ns, 0.95), *ns.last().unwrap_or(&0));
        eprintln!(
            "ACPMUX-PERF {name} p50_ms={} p95_ms={} max_ms={} n={}",
            ms(p50),
            ms(p95),
            ms(max),
            ns.len()
        );
        if let Some(b) = budget
            && (ns.is_empty() || p95 > b.as_nanos() as u64)
        {
            self.over.push(format!("{name} p95 {} ms > {} ms", ms(p95), b.as_millis()));
        }
        self.rows.insert(
            name.to_owned(),
            json!({"p50_ms": ms(p50), "p95_ms": ms(p95), "max_ms": ms(max), "n": ns.len()}),
        );
    }

    fn value(&mut self, name: &str, v: Value) {
        eprintln!("ACPMUX-PERF {name} {v}");
        self.rows.insert(name.to_owned(), v);
    }

    fn write(&self) {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let dir = root.join(".build/acpmux-perf");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(
            dir.join("perf_ops.json"),
            serde_json::to_string_pretty(&Value::Object(self.rows.clone())).unwrap(),
        );
    }
}

/// CPU ns, context switches, threads and resident bytes of one process (proc_pidinfo).
#[derive(Clone, Copy, Debug, Default)]
struct Usage {
    cpu_ns: u64,
    switches: u64,
    threads: u64,
    rss: u64,
}

fn usage(pid: u32) -> Usage {
    use std::os::raw::{c_int, c_void};
    // The C layout of PROC_PIDTASKINFO: most fields are only there for their offsets.
    #[allow(dead_code)]
    #[repr(C)]
    #[derive(Default)]
    struct TaskInfo {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buf: *mut c_void,
            size: c_int,
        ) -> c_int;
        fn mach_timebase_info(info: *mut Timebase) -> c_int;
    }
    let mut task = TaskInfo::default();
    let mut tb = Timebase::default();
    let size = size_of::<TaskInfo>() as c_int;
    // SAFETY: the buffer matches PROC_PIDTASKINFO's layout and size.
    let n = unsafe { proc_pidinfo(pid as c_int, 4, 0, (&raw mut task).cast(), size) };
    if n != size {
        return Usage::default();
    }
    // SAFETY: writes the two fields.
    unsafe { mach_timebase_info(&raw mut tb) };
    let ticks = (task.total_user + task.total_system) as u128;
    Usage {
        cpu_ns: (ticks * tb.numer as u128 / tb.denom.max(1) as u128) as u64,
        switches: task.csw.max(0) as u64,
        threads: task.threadnum.max(0) as u64,
        rss: task.resident_size,
    }
}

/// Every process under `pid` (agent hosts and their agents), by `ps`.
fn descendants(pid: u32) -> Vec<u32> {
    let out = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid="]).output().unwrap();
    let pairs: Vec<(u32, u32)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            Some((f.next()?.parse().ok()?, f.next()?.parse().ok()?))
        })
        .collect();
    let mut found = vec![pid];
    let mut i = 0;
    while i < found.len() {
        let parent = found[i];
        found.extend(pairs.iter().filter(|(_, pp)| *pp == parent).map(|(p, _)| *p));
        i += 1;
    }
    found.remove(0);
    found
}

fn tree(pid: u32) -> Value {
    let kids = descendants(pid);
    let own = usage(pid);
    let rss: u64 = kids.iter().map(|p| usage(*p).rss).sum();
    let threads: u64 = kids.iter().map(|p| usage(*p).threads).sum();
    json!({"daemon_threads": own.threads, "daemon_rss_mb": own.rss >> 20,
           "processes": kids.len(), "processes_threads": threads, "processes_rss_mb": rss >> 20})
}

fn scratch() -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-perf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

// ------------------------------------------------------------------ the bench

/// The ops a client sends most, each timed `ROUNDS` times on chat `s`.
async fn time_ops(c: &mut Client, s: &str, rounds: usize, label: &str, report: &mut Report) {
    let mut rows: Vec<(&str, Vec<u64>)> = Vec::new();
    for op in ["status", "sessions", "draft_set", "rename", "attach", "events"] {
        let mut ns = Vec::with_capacity(rounds);
        for i in 0..rounds + 5 {
            let (m, p) = match op {
                "status" => ("_acpmux/status", json!({})),
                "sessions" => ("_acpmux/sessions", json!({})),
                "draft_set" => {
                    ("_acpmux/draft_set", json!({"sessionId": s, "text": format!("draft {i}")}))
                }
                "rename" => (
                    "_acpmux/rename",
                    json!({"sessionId": s, "newName": format!("perf-{label}-{i}")}),
                ),
                "attach" => ("_acpmux/attach", json!({"sessionId": s, "limit": 50})),
                _ => ("_acpmux/events", json!({"sessionId": s, "limit": 50})),
            };
            let t = c.timed(m, p).await;
            if i >= 5 {
                ns.push(t);
            }
        }
        rows.push((op, ns));
    }
    for (op, ns) in rows {
        report.latency(&format!("{label}.op.{op}"), ns, Some(OP_P95));
    }
}

/// One prompt: send to `_acpmux/prompt_accepted` on the same connection, in ns.
async fn prompt(c: &mut Client, s: &str, text: &str, id: &str) -> oneshot::Receiver<Value> {
    c.send(
        "session/prompt",
        json!({"sessionId": s, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id}}}),
    )
    .await
}

/// Where the daemon spends a session list's time: macOS `sample` of the daemon for 2 s while
/// one connection asks for `_acpmux/sessions` back to back. Prints the heaviest frames of the
/// samples (top of stack) as `ACPMUX-PROFILE` lines; a diagnostic, not a budget.
async fn profile_sessions_list(daemon: &Daemon, c: &mut Client) {
    let out = std::env::temp_dir().join(format!("amx-sample-{}.txt", std::process::id()));
    let Ok(mut sample) = std::process::Command::new("/usr/bin/sample")
        .args([&daemon.pid().to_string(), "2", "-mayDie", "-file"])
        .arg(&out)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        eprintln!("ACPMUX-PROFILE sample did not start");
        return;
    };
    let mut lists = 0;
    while sample.try_wait().ok().flatten().is_none() {
        c.call("_acpmux/sessions", json!({})).await;
        lists += 1;
    }
    let text = std::fs::read_to_string(&out).unwrap_or_default();
    let _ = std::fs::remove_file(&out);
    eprintln!("ACPMUX-PROFILE sessions lists during the sample: {lists}");
    let top = text.split("Sort by top of stack").nth(1).unwrap_or("");
    for line in top.lines().filter(|l| !l.trim().is_empty()).take(40) {
        eprintln!("ACPMUX-PROFILE {}", line.trim());
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn acpmux_ops_and_streaming_meet_the_daemon_budgets_light_and_stress() {
    let dir = scratch();
    let daemon = Daemon::start(&dir);
    let mut report = Report::default();
    report.value("idle0.tree", tree(daemon.pid()));

    // -------- light: one chat, one client
    let mut app = Client::connect(&daemon.socket).await;
    let chat = app.new_chat(&daemon.work).await;
    app.call("_acpmux/attach", json!({"sessionId": chat, "limit": 1})).await;
    // The first prompt starts the agent (its host and harness).
    let first = now_ns();
    let rx = prompt(&mut app, &chat, "hello", "warm-0").await;
    rx.await.unwrap();
    report.value("light.first_prompt_ms", json!((now_ns() - first) as f64 / 1e6));
    time_ops(&mut app, &chat, ROUNDS, "light", &mut report).await;
    let mut accepted = Vec::new();
    for i in 0..30 {
        let id = format!("light-{i}");
        let start = now_ns();
        let rx = prompt(&mut app, &chat, "hi", &id).await;
        rx.await.unwrap();
        if let Some(at) = app.accepted.lock().unwrap().get(&id) {
            accepted.push(at - start);
        }
    }
    report.latency("light.op.prompt_accepted", accepted, Some(OP_P95));
    let mut created = Vec::new();
    for _ in 0..10 {
        let start = now_ns();
        app.new_chat(&daemon.work).await;
        created.push(now_ns() - start);
    }
    report.latency("light.op.session_new", created, Some(OP_P95));
    app.take_tokens();
    let rx = prompt(&mut app, &chat, "stream 400 2", "light-stream").await;
    rx.await.unwrap();
    report.latency("light.token_to_client", app.take_tokens(), Some(OP_P95));

    // -------- STRESS: 16 chats streaming to two attached clients; a third sends requests
    let mut viewer = Client::connect(&daemon.socket).await;
    let mut chats = Vec::new();
    for _ in 0..STRESS_CHATS {
        let s = app.new_chat(&daemon.work).await;
        for c in [&mut app, &mut viewer] {
            c.call("_acpmux/attach", json!({"sessionId": s, "limit": 1})).await;
        }
        let rx = prompt(&mut app, &s, "hello", &format!("warm-{s}")).await;
        rx.await.unwrap();
        chats.push(s);
    }
    report.value("stress.tree", tree(daemon.pid()));
    app.take_tokens();
    viewer.take_tokens();
    let mut turns = Vec::new();
    for (i, s) in chats.iter().enumerate() {
        turns.push(prompt(&mut app, s, "stream 300 5", &format!("stress-{i}")).await);
    }
    let mut ops = Client::connect(&daemon.socket).await;
    time_ops(&mut ops, &chats[0], 40, "stress", &mut report).await;
    for t in turns {
        t.await.unwrap();
    }
    report.latency("stress.token_to_client.app", app.take_tokens(), Some(OP_P95));
    report.latency("stress.token_to_client.viewer", viewer.take_tokens(), Some(OP_P95));

    // -------- idle: every agent alive, both clients attached, nothing streaming
    tokio::time::sleep(Duration::from_secs(3)).await;
    let mut windows = Vec::new();
    let mut kid_windows = Vec::new();
    for _ in 0..IDLE_WINDOWS {
        let kids = descendants(daemon.pid());
        let (before, kb): (Usage, Vec<Usage>) =
            (usage(daemon.pid()), kids.iter().map(|p| usage(*p)).collect());
        tokio::time::sleep(IDLE_WINDOW).await;
        let after = usage(daemon.pid());
        windows.push((after.switches - before.switches, after.cpu_ns - before.cpu_ns));
        let ka: Vec<Usage> = kids.iter().map(|p| usage(*p)).collect();
        let (sw, cpu) = kb.iter().zip(&ka).fold((0, 0), |(s, c), (b, a)| {
            (s + a.switches.saturating_sub(b.switches), c + a.cpu_ns.saturating_sub(b.cpu_ns))
        });
        kid_windows.push((sw, cpu));
    }
    windows.sort_unstable();
    kid_windows.sort_unstable();
    let (sw, cpu) = windows[IDLE_WINDOWS / 2];
    let (ksw, kcpu) = kid_windows[IDLE_WINDOWS / 2];
    report.value(
        "idle.stress",
        json!({"window_s": IDLE_WINDOW.as_secs(), "daemon_switches": sw, "daemon_cpu_ms": cpu / 1_000_000,
               "agent_processes_switches": ksw, "agent_processes_cpu_ms": kcpu / 1_000_000}),
    );
    if sw > IDLE_SWITCHES {
        report.over.push(format!(
            "idle daemon: {sw} context switches in {} s (at most {IDLE_SWITCHES})",
            IDLE_WINDOW.as_secs()
        ));
    }

    // -------- many chats: more chats writing at once than the store keeps logs open
    let mut many = chats.clone();
    while many.len() < MANY_CHATS {
        let s = app.new_chat(&daemon.work).await;
        app.call("_acpmux/attach", json!({"sessionId": s, "limit": 1})).await;
        let rx = prompt(&mut app, &s, "hello", &format!("warm-{s}")).await;
        rx.await.unwrap();
        many.push(s);
    }
    report.value("many.tree", tree(daemon.pid()));
    app.take_tokens();
    let mut turns = Vec::new();
    for (i, s) in many.iter().enumerate() {
        turns.push(prompt(&mut app, s, "stream 40 25", &format!("many-{i}")).await);
    }
    time_ops(&mut ops, &many[0], 20, "many", &mut report).await;
    for t in turns {
        t.await.unwrap();
    }
    report.latency("many.token_to_client", app.take_tokens(), Some(OP_P95));
    profile_sessions_list(&daemon, &mut ops).await;

    report.write();
    assert!(report.over.is_empty(), "over the daemon budgets: {:#?}", report.over);
}
