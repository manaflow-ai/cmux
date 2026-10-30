//! SCRATCH BENCH (acpmux-durable-ab, never merged; listed in stopped.txt): the acpmux request
//! latency, send to reply, with and without the "answer only after the write" commits, on a
//! loaded Mac. Run by `scripts/measure/acpmux-overhead.sh --arg=bench=daemon --arg=before=A`:
//! - the before side (arm A, this file in the A tree) only writes the path of its release
//!   daemon to `<overhead>/arm-a-bin` and ends;
//! - the after side (arm B) starts the load once (a memory hog into swap, F_FULLFSYNC writers,
//!   CPU spinners), then runs arm A's and arm B's daemons in turn, A B A B A B, under the same
//!   load. Each run: 80 chats stream at once (the background agents), then N = 1, 16 and 80
//!   clients, each on its own connection and chat, send the request mix for a fixed time.
//! Output: `ACPMUX-PERF ab ...` rows (p50/p95/p99/max per arm, round, N and request kind),
//! `ACPMUX-PERF load ...` rows (load average and swap during each run) and pooled rows per arm.
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts the stand-in agent only.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::oneshot;

const AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_stream_agent.py");
/// Chats streaming in the background during each run (the field case: about 80 agents).
const BG_CHATS: usize = 80;
/// Request clients per phase.
const PHASES: [usize; 3] = [1, 16, 80];
/// How long each phase sends requests.
const PHASE: Duration = Duration::from_secs(20);
/// Rounds; each runs arm A, then arm B.
const ROUNDS: usize = 3;
/// A request with no reply in this time counts as an error (the app restarts acpmux at 2 s;
/// this bound only keeps the bench moving).
const REPLY_BOUND: Duration = Duration::from_secs(30);
/// The memory hog stops growing at the first of these.
const SWAP_TARGET_BYTES: u64 = 6 << 30;
const HOG_OVER_RAM_BYTES: u64 = 8 << 30;
const MIN_FREE_DISK_BYTES: u64 = 40 << 30;
const HOG_CHUNK_U64S: usize = 32 << 20; // 256 MB
/// Background fsync writers and their file bound.
const FSYNC_WRITERS: usize = 4;
const FSYNC_FILE_BYTES: u64 = 512 << 20;

fn now_ns() -> u64 {
    unsafe extern "C" {
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    const CLOCK_UPTIME_RAW: u32 = 8;
    // SAFETY: no preconditions.
    unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// ------------------------------------------------------------------ host readings

fn sysctl(name: &str) -> String {
    Command::new("/usr/sbin/sysctl")
        .args(["-n", name])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// The 1-minute load average.
fn load1() -> f64 {
    // "{ 12.34 10.00 9.00 }"
    sysctl("vm.loadavg")
        .trim_matches(|c| c == '{' || c == '}' || c == ' ')
        .split_whitespace()
        .next()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.0)
}

/// Swap used, in bytes ("total = 2048.00M  used = 1024.50M  free = ...").
fn swap_used() -> u64 {
    let s = sysctl("vm.swapusage");
    let Some(after) = s.split("used = ").nth(1) else { return 0 };
    let v = after.split_whitespace().next().unwrap_or("0");
    let (num, unit) = v.split_at(v.len().saturating_sub(1));
    let n: f64 = num.parse().unwrap_or(0.0);
    let mul = match unit {
        "K" => 1u64 << 10,
        "M" => 1 << 20,
        "G" => 1 << 30,
        _ => 1,
    };
    (n * mul as f64) as u64
}

/// macOS memory pressure: 1 normal, 2 warn, 4 critical.
fn pressure() -> u64 {
    sysctl("kern.memorystatus_vm_pressure_level").parse().unwrap_or(0)
}

fn free_disk(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: valid C string and out pointer.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return 0;
    }
    st.f_bavail as u64 * st.f_frsize as u64
}

// ------------------------------------------------------------------ the load

struct Load {
    stop: Arc<AtomicBool>,
    fsyncs: Arc<AtomicU64>,
    hog_bytes: Arc<AtomicU64>,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl Load {
    /// Starts the memory hog, the fsync writers and the CPU spinners; returns once the hog
    /// stopped growing (or after 240 s).
    fn start(dir: &Path) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let fsyncs = Arc::new(AtomicU64::new(0));
        let hog_bytes = Arc::new(AtomicU64::new(0));
        let grown = Arc::new(AtomicBool::new(false));
        let mut threads = Vec::new();
        let ram: u64 = sysctl("hw.memsize").parse().unwrap_or(16 << 30);
        let ncpu: usize = sysctl("hw.ncpu").parse().unwrap_or(8);
        eprintln!(
            "ACPMUX-PERF loadcfg ram_gb={} ncpu={ncpu} swap_target_gb={} spinners={} fsync_writers={FSYNC_WRITERS}",
            ram >> 30,
            SWAP_TARGET_BYTES >> 30,
            (3 * ncpu).min(64)
        );
        // Memory hog: incompressible chunks (xorshift) so the compressor cannot absorb them and
        // the host swaps; then a slow re-touch of every page keeps swap traffic on the disk.
        {
            let (stop, hog_bytes, grown, dir) =
                (stop.clone(), hog_bytes.clone(), grown.clone(), dir.to_owned());
            threads.push(std::thread::spawn(move || {
                let mut chunks: Vec<Vec<u64>> = Vec::new();
                let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
                let why = loop {
                    if stop.load(Ordering::Relaxed) {
                        break "stopped";
                    }
                    let held = chunks.len() as u64 * (HOG_CHUNK_U64S as u64 * 8);
                    if swap_used() >= SWAP_TARGET_BYTES {
                        break "swap target";
                    }
                    if pressure() >= 4 {
                        break "pressure critical";
                    }
                    if free_disk(&dir) < MIN_FREE_DISK_BYTES {
                        break "disk floor";
                    }
                    if held >= ram + HOG_OVER_RAM_BYTES {
                        break "hog cap";
                    }
                    let mut c = vec![0u64; HOG_CHUNK_U64S];
                    for v in c.iter_mut() {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                        *v = x;
                    }
                    chunks.push(c);
                    hog_bytes.store(held + (HOG_CHUNK_U64S as u64 * 8), Ordering::Relaxed);
                };
                eprintln!(
                    "ACPMUX-PERF hog grown={}MB why=\"{why}\" swap_used_mb={} pressure={}",
                    hog_bytes.load(Ordering::Relaxed) >> 20,
                    swap_used() >> 20,
                    pressure()
                );
                grown.store(true, Ordering::SeqCst);
                // Re-touch one word per 16 KB page, chunk by chunk.
                let mut i = 0usize;
                while !stop.load(Ordering::Relaxed) && !chunks.is_empty() {
                    let c = &mut chunks[i % chunks.len()];
                    let mut j = 0;
                    while j < c.len() {
                        c[j] = c[j].wrapping_add(1);
                        j += 2048;
                    }
                    i += 1;
                    std::thread::sleep(Duration::from_millis(20));
                }
            }));
        }
        // fsync writers: 256 KB writes, each followed by F_FULLFSYNC, files bounded.
        for w in 0..FSYNC_WRITERS {
            let (stop, fsyncs) = (stop.clone(), fsyncs.clone());
            let path = dir.join(format!("fsync-{w}.bin"));
            threads.push(std::thread::spawn(move || {
                use std::os::fd::AsRawFd;
                let Ok(mut f) = std::fs::File::create(&path) else { return };
                let buf: Vec<u8> = (0..256 * 1024).map(|i| (i * 31 + w) as u8).collect();
                let mut written = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    if f.write_all(&buf).is_err() {
                        break;
                    }
                    written += buf.len() as u64;
                    // SAFETY: an open descriptor; F_FULLFSYNC takes no argument.
                    unsafe { libc::fcntl(f.as_raw_fd(), libc::F_FULLFSYNC) };
                    fsyncs.fetch_add(1, Ordering::Relaxed);
                    if written >= FSYNC_FILE_BYTES {
                        let _ = f.set_len(0);
                        let _ = std::io::Seek::seek(&mut f, std::io::SeekFrom::Start(0));
                        written = 0;
                    }
                }
                let _ = std::fs::remove_file(&path);
            }));
        }
        // CPU spinners.
        for _ in 0..(3 * ncpu).min(64) {
            let stop = stop.clone();
            threads.push(std::thread::spawn(move || {
                let mut x = 1u64;
                while !stop.load(Ordering::Relaxed) {
                    for _ in 0..100_000 {
                        x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                    }
                    std::hint::black_box(x);
                }
            }));
        }
        let start = Instant::now();
        while !grown.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(240) {
            std::thread::sleep(Duration::from_millis(500));
        }
        Self { stop, fsyncs, hog_bytes, threads }
    }

    fn stop(self) {
        self.stop.store(true, Ordering::SeqCst);
        for t in self.threads {
            let _ = t.join();
        }
    }
}

/// Samples load and swap every 2 s until dropped; the max of each.
struct Sampler {
    stop: Arc<AtomicBool>,
    max: Arc<Mutex<(f64, u64)>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Sampler {
    fn start() -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let max = Arc::new(Mutex::new((0.0f64, 0u64)));
        let (s, m) = (stop.clone(), max.clone());
        let thread = std::thread::spawn(move || {
            while !s.load(Ordering::Relaxed) {
                let (l, w) = (load1(), swap_used());
                let mut g = m.lock().unwrap();
                g.0 = g.0.max(l);
                g.1 = g.1.max(w);
                drop(g);
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        Self { stop, max, thread: Some(thread) }
    }

    fn finish(mut self) -> (f64, u64) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        *self.max.lock().unwrap()
    }
}

// ------------------------------------------------------------------ daemon

struct Daemon {
    child: Child,
    socket: PathBuf,
    work: PathBuf,
}

impl Daemon {
    fn start(exe: &Path, scratch: &Path) -> Self {
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
        let mut cmd = Command::new(exe);
        daemon_env::apply(&mut cmd, scratch, daemon_env::Agents::StandIn, &[]);
        let mut child = cmd
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
}

impl Drop for Daemon {
    /// Ends the daemon and every agent it hosts (`_acpmux/shutdown {endAgents}`); SIGTERM if
    /// the call fails.
    fn drop(&mut self) {
        let asked = std::os::unix::net::UnixStream::connect(&self.socket).and_then(|mut s| {
            s.set_read_timeout(Some(Duration::from_secs(60)))?;
            let lines = [
                json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}}),
                json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/shutdown", "params": {"endAgents": true}}),
            ];
            for line in lines {
                s.write_all(format!("{line}\n").as_bytes())?;
            }
            let mut reader = BufReader::new(s);
            let mut line = String::new();
            while reader.read_line(&mut line)? > 0 && !line.contains("\"id\":2") {
                line.clear();
            }
            Ok(())
        });
        if asked.is_err() {
            // SAFETY: signalling this test's own child.
            unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        }
        let _ = self.child.wait();
    }
}

// ------------------------------------------------------------------ client

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;
type Accepts = Arc<Mutex<HashMap<String, oneshot::Sender<u64>>>>;

struct Client {
    writer: tokio::io::WriteHalf<UnixStream>,
    pending: Pending,
    accepts: Accepts,
    next: u64,
}

impl Client {
    async fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).await.expect("connect");
        let (rd, writer) = tokio::io::split(stream);
        let pending: Pending = Arc::default();
        let accepts: Accepts = Arc::default();
        let (p, a) = (pending.clone(), accepts.clone());
        tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(rd).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let at = now_ns();
                // Only replies and accepted notes matter; skip the token stream cheaply.
                if line.contains("\"session/update\"") {
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                match v.get("method").and_then(Value::as_str) {
                    None => {
                        if let Some(id) = v.get("id").and_then(Value::as_u64)
                            && let Some(tx) = p.lock().unwrap().remove(&id)
                        {
                            let _ = tx.send(v);
                        }
                    }
                    Some("_acpmux/prompt_accepted") => {
                        if let Some(id) = v.pointer("/params/promptId").and_then(Value::as_str)
                            && let Some(tx) = a.lock().unwrap().remove(id)
                        {
                            let _ = tx.send(at);
                        }
                    }
                    Some(_) => {}
                }
            }
        });
        let mut c = Self { writer, pending, accepts, next: 0 };
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "perf-ab"}}))
            .await
            .expect("initialize");
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

    async fn notify(&mut self, method: &str, params: Value) {
        let line = json!({"jsonrpc": "2.0", "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }

    /// The result, or None on an error reply or no reply within REPLY_BOUND.
    async fn call(&mut self, method: &str, params: Value) -> Option<Value> {
        let rx = self.send(method, params).await;
        match tokio::time::timeout(REPLY_BOUND, rx).await {
            Ok(Ok(v)) if v.get("error").is_none() => Some(v["result"].clone()),
            Ok(Ok(v)) => {
                eprintln!("ACPMUX-PERF-ERR {method} {}", v["error"]);
                None
            }
            _ => None,
        }
    }

    /// Send to reply in ns; None on an error or no reply.
    async fn timed(&mut self, method: &str, params: Value) -> Option<u64> {
        let start = now_ns();
        self.call(method, params).await.map(|_| now_ns() - start)
    }

    /// Sends a prompt; send to its `_acpmux/prompt_accepted` in ns (it queues behind the
    /// running turn). Its own reply comes at its turn's end, or `cancelled` once removed.
    async fn queue_prompt(&mut self, s: &str, id: &str) -> Option<u64> {
        let (tx, rx) = oneshot::channel();
        self.accepts.lock().unwrap().insert(id.to_owned(), tx);
        let start = now_ns();
        let _reply = self
            .send(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}],
                       "_meta": {"acpmux": {"promptId": id}}}),
            )
            .await;
        match tokio::time::timeout(REPLY_BOUND, rx).await {
            Ok(Ok(at)) => Some(at.saturating_sub(start)),
            _ => {
                self.accepts.lock().unwrap().remove(id);
                None
            }
        }
    }

    async fn new_chat(&mut self, work: &Path) -> String {
        let v = self.call("session/new", json!({"cwd": work, "mcpServers": []})).await;
        v.and_then(|v| v["sessionId"].as_str().map(str::to_owned)).expect("session id")
    }
}

// ------------------------------------------------------------------ numbers

type Samples = BTreeMap<&'static str, (Vec<u64>, u64)>;

fn record(s: &mut Samples, kind: &'static str, v: Option<u64>) {
    let e = s.entry(kind).or_default();
    match v {
        Some(ns) => e.0.push(ns),
        None => e.1 += 1,
    }
}

fn pct(sorted: &[u64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let ns = sorted[((sorted.len() as f64 - 1.0) * p).round() as usize];
    (ns as f64 / 1e3).round() / 1e3
}

fn row(prefix: &str, kind: &str, ns: &mut Vec<u64>, errors: u64) -> Value {
    ns.sort_unstable();
    let (p50, p95, p99) = (pct(ns, 0.5), pct(ns, 0.95), pct(ns, 0.99));
    let max = pct(ns, 1.0);
    eprintln!(
        "ACPMUX-PERF {prefix} kind={kind} p50_ms={p50} p95_ms={p95} p99_ms={p99} max_ms={max} n={} errors={errors}",
        ns.len()
    );
    json!({"p50_ms": p50, "p95_ms": p95, "p99_ms": p99, "max_ms": max, "n": ns.len(), "errors": errors})
}

/// The kinds that change state (they wait for their record in arm B).
const WRITE_KINDS: &[&str] = &[
    "queue_edit_update",
    "queue_edit_move",
    "queue_remove",
    "prompt_withdraw",
    "rename",
    "draft_set",
];

/// One client's request mix on chat `s` until `until`.
async fn client_loop(mut c: Client, s: String, tag: String, until: Instant) -> Samples {
    let mut out = Samples::new();
    let mut cycle = 0u64;
    while Instant::now() < until {
        let (p1, p2) = (format!("{tag}-{cycle}-a"), format!("{tag}-{cycle}-b"));
        let v = c.queue_prompt(&s, &p1).await;
        record(&mut out, "prompt_queue", v);
        let v = c.queue_prompt(&s, &p2).await;
        record(&mut out, "prompt_queue", v);
        let v = c
            .timed(
                "_acpmux/queue_edit",
                json!({"sessionId": s, "promptId": p1, "op": "update", "text": format!("edited {cycle}")}),
            )
            .await;
        record(&mut out, "queue_edit_update", v);
        let v = c
            .timed(
                "_acpmux/queue_edit",
                json!({"sessionId": s, "promptId": p1, "op": "move", "index": 1}),
            )
            .await;
        record(&mut out, "queue_edit_move", v);
        let v = c.timed("_acpmux/queue_remove", json!({"sessionId": s, "promptId": p1})).await;
        record(&mut out, "queue_remove", v);
        let v = c.timed("_acpmux/prompt_withdraw", json!({"sessionId": s, "promptId": p2})).await;
        record(&mut out, "prompt_withdraw", v);
        let v = c
            .timed("_acpmux/rename", json!({"sessionId": s, "newName": format!("{tag}-{cycle}")}))
            .await;
        record(&mut out, "rename", v);
        let v = c
            .timed("_acpmux/draft_set", json!({"sessionId": s, "text": format!("draft {cycle}")}))
            .await;
        record(&mut out, "draft_set", v);
        let v = c.timed("_acpmux/status", json!({})).await;
        record(&mut out, "status", v);
        let v = c.timed("_acpmux/events", json!({"sessionId": s, "limit": 50})).await;
        record(&mut out, "events", v);
        cycle += 1;
    }
    out
}

/// One run of one arm's daemon under the load; returns samples per N.
async fn run_arm(
    exe: &Path,
    arm: &str,
    round: usize,
    base: &Path,
    load: &Load,
) -> BTreeMap<usize, Samples> {
    let scratch = base.join(format!("{arm}{round}"));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).unwrap();
    let (l0, w0) = (load1(), swap_used());
    let sampler = Sampler::start();
    let f0 = load.fsyncs.load(Ordering::Relaxed);
    let t0 = Instant::now();
    let daemon = Daemon::start(exe, &scratch);
    let mut app = Client::connect(&daemon.socket).await;
    let mut chats = Vec::new();
    for _ in 0..BG_CHATS {
        let s = app.new_chat(&daemon.work).await;
        app.call("_acpmux/attach", json!({"sessionId": s, "limit": 1})).await;
        chats.push(s);
    }
    // Start every agent, then wait for all of them.
    let mut warm = Vec::new();
    for (i, s) in chats.iter().enumerate() {
        warm.push(
            app.send(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "hello"}],
                       "_meta": {"acpmux": {"promptId": format!("warm-{i}")}}}),
            )
            .await,
        );
    }
    for w in warm {
        let _ = tokio::time::timeout(Duration::from_secs(120), w).await;
    }
    // The background turns: each chat streams for longer than the run (cancelled at its end).
    for (i, s) in chats.iter().enumerate() {
        let _ = app
            .send(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "stream 100000 10"}],
                       "_meta": {"acpmux": {"promptId": format!("bg-{i}")}}}),
            )
            .await;
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    let mut by_n = BTreeMap::new();
    for n in PHASES {
        let mut clients = Vec::new();
        for _ in 0..n {
            clients.push(Client::connect(&daemon.socket).await);
        }
        let until = Instant::now() + PHASE;
        let mut tasks = Vec::new();
        for (i, c) in clients.into_iter().enumerate() {
            let tag = format!("{arm}{round}-n{n}-c{i}");
            tasks.push(tokio::spawn(client_loop(c, chats[i].clone(), tag, until)));
        }
        let mut merged = Samples::new();
        for t in tasks {
            for (k, (ns, err)) in t.await.unwrap() {
                let e = merged.entry(k).or_default();
                e.0.extend(ns);
                e.1 += err;
            }
        }
        by_n.insert(n, merged);
    }
    for s in &chats {
        app.notify("session/cancel", json!({"sessionId": s})).await;
    }
    let secs = t0.elapsed().as_secs_f64();
    let fsyncs = load.fsyncs.load(Ordering::Relaxed) - f0;
    let (lmax, wmax) = sampler.finish();
    eprintln!(
        "ACPMUX-PERF load round={round} arm={arm} load1_start={l0:.1} load1_max={lmax:.1} load1_end={:.1} swap_start_mb={} swap_max_mb={} swap_end_mb={} hog_mb={} bg_fsyncs_per_s={:.1} pressure={}",
        load1(),
        w0 >> 20,
        wmax >> 20,
        swap_used() >> 20,
        load.hog_bytes.load(Ordering::Relaxed) >> 20,
        fsyncs as f64 / secs,
        pressure()
    );
    drop(app);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&scratch);
    by_n
}

/// `<work>` of acpmux-overhead.sh: the before tree is `<work>/before-src`, the after tree's
/// work is `<root>/.build/acpmux-overhead`.
fn overhead_dir() -> (PathBuf, bool) {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tree = manifest.join("../../..");
    let tree = tree.canonicalize().unwrap_or(tree);
    if tree.file_name().is_some_and(|n| n == "before-src") {
        (tree.parent().unwrap().to_owned(), true)
    } else {
        (tree.join(".build/acpmux-overhead"), false)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn acpmux_durable_ab_under_load() {
    let (work, before_side) = overhead_dir();
    let arm_a_file = work.join("arm-a-bin");
    if before_side {
        std::fs::write(&arm_a_file, daemon_env::bin().display().to_string()).unwrap();
        eprintln!("ACPMUX-PERF arm-a-bin {}", daemon_env::bin().display());
        return;
    }
    let a = PathBuf::from(
        std::fs::read_to_string(&arm_a_file)
            .expect("no arm-a-bin: run with --arg=before=<arm A sha>")
            .trim(),
    );
    assert!(a.exists(), "arm A's daemon is missing: {}", a.display());
    let b = daemon_env::bin().to_owned();
    // Short: socket paths must stay under the macOS limit.
    let base = std::env::temp_dir().join(format!("amx-ab-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();
    eprintln!(
        "ACPMUX-PERF start load1={:.1} swap_mb={} pressure={} a={} b={}",
        load1(),
        swap_used() >> 20,
        pressure(),
        a.display(),
        b.display()
    );
    let load = Load::start(&base);
    let mut pooled: BTreeMap<(String, usize), Samples> = BTreeMap::new();
    let mut report = serde_json::Map::new();
    for round in 0..ROUNDS {
        for (arm, exe) in [("A", &a), ("B", &b)] {
            let by_n = run_arm(exe, arm, round, &base, &load).await;
            for (n, samples) in by_n {
                let mut writes_all = Vec::new();
                let mut writes_err = 0;
                for (kind, (mut ns, err)) in samples {
                    if WRITE_KINDS.contains(&kind) {
                        writes_all.extend_from_slice(&ns);
                        writes_err += err;
                    }
                    let key = format!("ab.round{round}.{arm}.n{n}.{kind}");
                    report.insert(
                        key,
                        row(&format!("ab round={round} arm={arm} n={n}"), kind, &mut ns, err),
                    );
                    let p = pooled.entry((arm.to_owned(), n)).or_default().entry(kind).or_default();
                    p.0.extend(ns);
                    p.1 += err;
                }
                report.insert(
                    format!("ab.round{round}.{arm}.n{n}.ALL_WRITES"),
                    row(
                        &format!("ab round={round} arm={arm} n={n}"),
                        "ALL_WRITES",
                        &mut writes_all,
                        writes_err,
                    ),
                );
            }
        }
    }
    for ((arm, n), samples) in pooled {
        let mut writes_all = Vec::new();
        let mut writes_err = 0;
        for (kind, (mut ns, err)) in samples {
            if WRITE_KINDS.contains(&kind) {
                writes_all.extend_from_slice(&ns);
                writes_err += err;
            }
            report.insert(
                format!("pooled.{arm}.n{n}.{kind}"),
                row(&format!("pooled arm={arm} n={n}"), kind, &mut ns, err),
            );
        }
        report.insert(
            format!("pooled.{arm}.n{n}.ALL_WRITES"),
            row(&format!("pooled arm={arm} n={n}"), "ALL_WRITES", &mut writes_all, writes_err),
        );
    }
    eprintln!(
        "ACPMUX-PERF end load1={:.1} swap_mb={} pressure={}",
        load1(),
        swap_used() >> 20,
        pressure()
    );
    load.stop();
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/acpmux-perf");
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(
        dir.join("perf_ops.json"),
        serde_json::to_string_pretty(&Value::Object(report)).unwrap(),
    );
    let _ = std::fs::remove_dir_all(&base);
}
