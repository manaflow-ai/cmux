//! A daemon's stop under load, over a god home and a small one in one harness (W3, 2026-11-19).
//! Leo: "it's unacceptable to be having so many of these connectivity issues"; a stop that takes
//! long is a gap every client sees, and the app waited 38 s on one (hq
//! `docs/design/agent-service-v2.md`).
//!
//! Each run starts the daemon over the home, puts a turn that never ends on the god chat (the
//! stand-in agent's "hang", under an agent host that the next run's daemon adopts) with its
//! `session/prompt` in flight, opens [`CONNS`] more connections with [`WAITS`] `_acpmux/wait`
//! requests in flight on each (200 in all), then sends SIGTERM and times the process's exit, with
//! as many busy threads in this process as the machine has CPUs. `STOP-UNDER-LOAD` prints, for
//! each home: the stops' p50, p95 and max in ms, how many of the requests in flight read an answer
//! and not the close (a stop is not a client's cancel: the design gives them none, and never
//! -32800, counted apart), and whether each home's first agent streamed before its stop. Each
//! daemon runs with `ACPMUX_STOP_TIMELINE=1` and its stderr in a file of the scratch folder: its
//! `STOP-TIMELINE` line (`daemon/stop_timeline.rs`) gives each phase's end in ms since the stop
//! began, and `marksMs` their p50 and p95 for each home (`noTimeline`: runs without the line).
//!
//! Every stop must take under a second, and the god home's p95 at most 1.2 times the small one's
//! plus [`FLOOR_MS`] (hq `docs/handbook/perf-regresses-on-degenerate-sessions.md`).
//!
//! The sizes are a fleet run's: `ACPMUX_STOP_RUNS` (default 5 for each home) and
//! `ACPMUX_STOP_GOD_SCALE` (default 0.02 of `Shape::god`). The measured run, on Linux CI:
//! `ACPMUX_STOP_RUNS=50 ACPMUX_STOP_GOD_SCALE=1 cargo test -p acpmux --release --test
//! stop_under_load -- --nocapture`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The prompt goes to tests/fake_agent.py; the sizes hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_STOP_RUNS",
    "ACPMUX_STOP_GOD_SCALE",
    "ACPMUX_STOP_BUSY",
]);

use acpmux::god_fixture::{self, Shape};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Connections with waits in flight, and the waits on each.
const CONNS: usize = 4;
const WAITS: usize = 50;

/// The bound on every stop.
const STOP_MS: f64 = 1000.0;

/// What the god home's p95 may exceed 1.2 times the small one's by: under it a ratio of two
/// stops of a few milliseconds is the scheduler's noise.
const FLOOR_MS: f64 = 25.0;

/// How long one step of a run (a start, a reply, the exit) may take before the test fails.
const STEP: Duration = Duration::from_secs(120);

/// How long a home's first run waits for its agent's first chunk before it stops all the same.
const FIRST_CHUNK: Duration = Duration::from_secs(30);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// `Shape::god` at `scale` with no peers (a stop does not wait on them), or the small shape.
fn shapes() -> [Shape; 2] {
    let scale = env_or("ACPMUX_STOP_GOD_SCALE", 0.02f64).clamp(0.001, 1.0);
    let god = Shape::god();
    let by = |n: usize| ((n as f64 * scale).ceil() as usize).max(1);
    let god = Shape {
        chats: by(god.chats),
        god_messages: by(god.god_messages),
        god_bytes: (god.god_bytes as f64 * scale) as u64,
        peers: 0,
        ..god
    };
    [Shape { peers: 0, ..Shape::small() }, god]
}

/// One connection to the daemon's socket, a line of JSON each way.
struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).expect("connect to the daemon's socket");
        stream.set_read_timeout(Some(STEP)).unwrap();
        let mut rpc =
            Self { reader: BufReader::new(stream.try_clone().unwrap()), writer: stream, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "stop-under-load"}});
        let id = rpc.request("initialize", hello);
        rpc.until(STEP, |v| is_response(v, id)).expect("initialize answered");
        rpc
    }

    /// Writes a request without waiting for its response: its id.
    fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    /// The next line; none once the daemon closed the socket (or a read failed).
    fn read(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(n) if n > 0 => serde_json::from_str(&line).ok(),
            _ => None,
        }
    }

    /// The first line `pred` takes; none once the socket closed or a read took over `each`.
    fn until(&mut self, each: Duration, pred: impl Fn(&Value) -> bool) -> Option<Value> {
        self.writer.set_read_timeout(Some(each)).unwrap();
        loop {
            let v = self.read()?;
            if pred(&v) {
                return Some(v);
            }
        }
    }

    /// Reads to the socket's close: how many responses came, and how many of them carried a
    /// client cancel's code.
    fn answers(mut self) -> (usize, usize) {
        self.writer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (mut answers, mut cancels) = (0, 0);
        while let Some(v) = self.read() {
            if v.get("method").is_some() || v.get("id").is_none() {
                continue;
            }
            answers += 1;
            cancels += usize::from(v["error"]["code"] == -32800);
        }
        (answers, cancels)
    }
}

/// `v` answers request `id` (a response has no method; a request from the daemon may share ids).
fn is_response(v: &Value, id: u64) -> bool {
    v.get("method").is_none() && v.get("id") == Some(&json!(id))
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    /// The file the daemon's stderr goes to.
    stderr: PathBuf,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path, env: &[(&str, &str)], stderr: PathBuf) -> Self {
        let socket = scratch.join("s.sock");
        let log = std::fs::File::create(&stderr).expect("create the daemon's stderr file");
        let mut command = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_STOP_TIMELINE", "1")
            .envs(env.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        let spawned = Instant::now();
        let mut child = command.spawn().unwrap();
        while UnixStream::connect(&socket).is_err() {
            if spawned.elapsed() >= STEP || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                let _ = child.wait();
                let text = std::fs::read(&stderr).unwrap_or_default();
                eprint!("{}", String::from_utf8_lossy(&text));
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        Self { child, socket, stderr }
    }

    /// SIGTERM, then the exit: how long it took in ms, and whether it exited with success.
    fn stop(&mut self) -> (f64, bool) {
        let sent = Instant::now();
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let status = self.child.wait().unwrap();
        (sent.elapsed().as_secs_f64() * 1000.0, status.success())
    }
}

/// A run that panics does not leave its daemon writing into a scratch folder being removed.
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Ends the agent hosts and agents this home's daemons started, by the pids its host records
/// name (`<home>/hosts/<session>.json`): a SIGTERM stop keeps them for a next daemon, and this
/// test's last one has none.
struct Hosts(PathBuf);

impl Drop for Hosts {
    fn drop(&mut self) {
        let records = std::fs::read_dir(self.0.join("hosts")).into_iter().flatten().flatten();
        for record in records {
            let text = std::fs::read_to_string(record.path()).unwrap_or_default();
            let record: Value = serde_json::from_str(&text).unwrap_or_default();
            for pid in ["harness_pid", "host_pid"] {
                let pid = record[pid].as_i64().and_then(|pid| i32::try_from(pid).ok());
                if let Some(pid) = pid.filter(|pid| *pid > 1) {
                    // SAFETY: kill takes a pid and a signal; the pid is a process this test's
                    // own daemon started and recorded.
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                }
            }
        }
    }
}

/// Threads that only spin until dropped: the load the daemon's stop shares its CPUs with.
struct Busy(Arc<AtomicBool>, Vec<std::thread::JoinHandle<()>>);

impl Busy {
    fn start(threads: usize) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let spinning = |stop: Arc<AtomicBool>| {
            move || {
                while !stop.load(Ordering::Relaxed) {
                    std::hint::spin_loop();
                }
            }
        };
        let handles = (0..threads).map(|_| std::thread::spawn(spinning(stop.clone()))).collect();
        Self(stop, handles)
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
        for handle in self.1.drain(..) {
            let _ = handle.join();
        }
    }
}

fn write_config(home: &Path) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    });
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
}

/// p50, p95 and max of `samples`.
fn spread(samples: &[f64]) -> (f64, f64, f64) {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let at = |q: f64| sorted[((sorted.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), sorted[sorted.len() - 1])
}

/// The marks of the `STOP-TIMELINE {...}` line in a daemon's stderr `text`, in its order: each
/// phase's name and its end in ms since the stop began. None without the line.
fn timeline(text: &str) -> Option<Vec<(String, f64)>> {
    let line = text.lines().find_map(|line| line.strip_prefix("STOP-TIMELINE "))?;
    let v: Value = serde_json::from_str(line).ok()?;
    let marks = v["marks"].as_array()?;
    Some(marks.iter().filter_map(|m| Some((m[0].as_str()?.to_string(), m[1].as_f64()?))).collect())
}

/// What one home's runs gave.
struct Stops {
    ms: Vec<f64>,
    /// Each run's stop timeline (`timeline`), and how many runs printed none.
    marks: Vec<Vec<(String, f64)>>,
    no_timeline: usize,
    /// Requests in flight that read an answer before the close, of every run's, and those of
    /// them answered as a client's cancel.
    answered: usize,
    cancels: usize,
    in_flight: usize,
    /// First runs (one for each home) whose agent streamed before the stop.
    streamed: usize,
    /// Stops that did not exit with success.
    failed: usize,
}

/// One run: the daemon started, loaded as the module says, stopped; added to `stops`.
fn run(scratch: &Path, home: &Path, god: &str, stops: &mut Stops) {
    let stderr = scratch.join(format!("daemon-{}.stderr", stops.ms.len()));
    let mut daemon = Daemon::start(scratch, home, &[], stderr);
    let mut turn = Rpc::connect(&daemon.socket);
    // The pane's attach, so this connection reads the chat's updates. The session index loads
    // after the socket binds, and the attach waits for it.
    let page = json!({"sessionId": god, "waitLogs": false, "limit": 1, "maxBytes": 4096});
    let attach = turn.request("_acpmux/attach", page);
    let attached = turn.until(STEP, |v| is_response(v, attach)).expect("the attach answered");
    assert!(attached.get("error").is_none(), "the god chat did not attach: {attached}");
    let hang = json!({"sessionId": god, "prompt": [{"type": "text", "text": "hang"}]});
    let prompt = turn.request("session/prompt", hang);
    // A first run's agent starts and streams; a later run's daemon adopted the host with its
    // turn still open, and this prompt waits behind it.
    if stops.ms.is_empty() {
        let chunk = turn.until(FIRST_CHUNK, |v| {
            is_response(v, prompt)
                || (v["method"] == "session/update"
                    && v["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        });
        stops.streamed += usize::from(chunk.is_some_and(|v| !is_response(&v, prompt)));
    }
    let mut waiting = Vec::new();
    for _ in 0..CONNS {
        let mut rpc = Rpc::connect(&daemon.socket);
        for _ in 0..WAITS {
            rpc.request("_acpmux/wait", json!({"sessions": [god], "until": ["closed"]}));
        }
        // Requests are read in order: this answer says every wait before it is in flight.
        let read = rpc.request("_acpmux/info", json!({"sessionId": god}));
        rpc.until(STEP, |v| is_response(v, read)).expect("the daemon read the waits");
        waiting.push(rpc);
    }
    let (ms, success) = daemon.stop();
    let text = std::fs::read(&daemon.stderr).unwrap_or_default();
    let text = String::from_utf8_lossy(&text);
    if ms >= STOP_MS || !success {
        eprint!("{text}");
    }
    match timeline(&text) {
        Some(marks) => stops.marks.push(marks),
        None => stops.no_timeline += 1,
    }
    stops.ms.push(ms);
    stops.failed += usize::from(!success);
    stops.in_flight += 1 + CONNS * WAITS;
    for rpc in std::iter::once(turn).chain(waiting) {
        let (answers, cancels) = rpc.answers();
        stops.answered += answers;
        stops.cancels += cancels;
    }
}

/// For each mark name, in first-seen order, the p50 and p95 of its ms across the runs: the
/// object for `marksMs`, and the names by p50 for `markOrder`.
fn marks_ms(runs: &[Vec<(String, f64)>]) -> (Value, Vec<String>) {
    let mut names: Vec<String> = Vec::new();
    for marks in runs {
        for (name, _) in marks {
            if !names.contains(name) {
                names.push(name.clone());
            }
        }
    }
    let mut by_name = serde_json::Map::new();
    let mut p50s = Vec::new();
    for name in &names {
        let samples: Vec<f64> =
            runs.iter().flatten().filter(|(n, _)| n == name).map(|(_, ms)| *ms).collect();
        let (p50, p95, _) = spread(&samples);
        by_name.insert(name.clone(), json!({"p50": p50.round(), "p95": p95.round()}));
        p50s.push((name.clone(), p50));
    }
    p50s.sort_by(|a, b| a.1.total_cmp(&b.1));
    (Value::Object(by_name), p50s.into_iter().map(|(name, _)| name).collect())
}

/// `shape`'s home, stopped under load `runs` times.
fn stops(shape: &Shape, runs: usize) -> Stops {
    let scratch = daemon_env::Scratch::new(&format!("stop-{}", shape.name));
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), shape).unwrap();
    write_config(&home);
    // Dropped before the scratch folder: the hosts go before their files.
    let _hosts = Hosts(home.clone());
    let mut stops = Stops {
        ms: vec![],
        marks: vec![],
        no_timeline: 0,
        answered: 0,
        cancels: 0,
        in_flight: 0,
        streamed: 0,
        failed: 0,
    };
    for _ in 0..runs {
        run(&scratch, &home, &made.god, &mut stops);
    }
    stops
}

#[test]
fn a_stop_under_load_takes_under_a_second_whatever_the_home() {
    let _ = HERMETIC;
    let runs = env_or("ACPMUX_STOP_RUNS", 5usize).max(1);
    let cpus = std::thread::available_parallelism().map_or(4, usize::from);
    let _busy = Busy::start(env_or("ACPMUX_STOP_BUSY", cpus));
    let mut p95s = Vec::new();
    let mut slow = Vec::new();
    for shape in shapes() {
        let stops = stops(&shape, runs);
        let (p50, p95, max) = spread(&stops.ms);
        let (marks, order) = marks_ms(&stops.marks);
        let line = json!({
            "shape": shape.name, "chats": shape.chats, "godBytes": shape.god_bytes,
            "runs": runs, "stopMs": {"p50": p50.round(), "p95": p95.round(), "max": max.round()},
            "inFlight": stops.in_flight, "answered": stops.answered,
            "cancelAnswers": stops.cancels, "streamedRuns": stops.streamed,
            "failedExits": stops.failed,
            "marksMs": marks, "markOrder": order, "noTimeline": stops.no_timeline,
        });
        eprintln!("STOP-UNDER-LOAD {line}");
        p95s.push(p95);
        if max >= STOP_MS || stops.failed > 0 {
            slow.push(line);
        }
    }
    assert!(
        slow.is_empty(),
        "a stop took a second or more, or did not exit with success: {slow:?}"
    );
    let (small, god) = (p95s[0], p95s[1]);
    assert!(
        god <= small * 1.2 + FLOOR_MS,
        "the god home's stop p95 {god:.0} ms is over 1.2x the small one's {small:.0} ms + {FLOOR_MS} ms"
    );
}
