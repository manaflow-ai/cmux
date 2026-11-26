//! The command placer in shadow, measuring half (RFD 0144, piece 1b): every shell tool call an
//! agent makes (an ACP `tool_call` of kind `execute` with a `rawInput.command`), whatever its
//! harness, gets one row in `$ACPMUX_HOME/command-placer.jsonl`: its class, what was predicted, the
//! verdict of [`command_shadow::decide`] and, once it ends, what it really used: peak memory,
//! CPU-seconds, wall time and the ports it listened on.
//!
//! Off by default: only with the hidden AutoCloud key (`cloud.autoCloud: true` in the settings
//! file, read at each command's start) is anything kept. Nothing leaves the machine and no
//! command is moved, forked, resized, slowed or refused: the hook is a map insert on the hub's
//! inbound path, and everything else runs on one sampler thread.
//!
//! How a command's processes are found (Linux, `/proc`): the harness runs it as a descendant of
//! the session's agent process, which acpmux holds. Once a second, while any shell call is in
//! flight, the sampler walks down from that one process (its threads' `children` files, never a
//! listing of `/proc`) and reads each descendant's parent, start time, CPU times and RSS. Walking down from the agent
//! process, the first process on each branch that started after one of the session's calls began
//! is that call's, and so is everything under it: the call it belongs to is the latest one that
//! began before it started. A process a call owns stays its own after it leaves the tree (`nohup
//! cmd &`), checked by its start time. CPU-seconds are the largest sum seen of its live processes'
//! own and reaped children's times (`utime + stime + cutime + cstime`): a reaped child's time moves
//! into its parent's, so nothing is counted twice; at most the last second before the call's own
//! shell exits is missed. Peak memory is the largest sum of their RSS seen. A port is a listening
//! TCP socket (`/proc/net/tcp`, `tcp6`) one of its processes holds. A call whose processes still
//! run when it returns (a background shell, a server) is watched for up to [`LINGER`] more for
//! the ports it opens; its row says `outlived`. Elsewhere than Linux the row carries the verdict
//! and wall time, with usage unknown.

use super::command_shadow::{self as shadow, Decision, Predicted, Situation, Table, Verdict};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

/// The settings key that turns the shadow placer on (AutoCloud's hidden key).
pub const AUTO_CLOUD_KEY: &str = "cloud.autoCloud";
/// How often the processes of calls in flight are read.
const TICK: Duration = Duration::from_secs(1);
/// How long a call whose processes outlive it is watched after it returns.
const LINGER: Duration = Duration::from_secs(30);
/// A call with no end seen this long after it began is written as unended and dropped.
const MAX_FLIGHT: Duration = Duration::from_secs(6 * 3600);
/// The most calls watched at once; past it a new call is written at once with usage unknown.
const MAX_FLIGHTS: usize = 512;
/// The most processes one call follows.
const MAX_PROCS: usize = 1_024;
/// The rows file rotates once past this (one previous file kept).
const FILE_CAP: u64 = 16 << 20;
/// How much of the rows file a start reads back into the prediction table.
const RELOAD_BYTES: u64 = 8 << 20;

/// The rows file: `$ACPMUX_HOME/command-placer.jsonl`.
pub fn file_path() -> PathBuf {
    crate::config::home().join("command-placer.jsonl")
}

/// Whether the AutoCloud key is on in the settings file now.
pub fn enabled() -> bool {
    use crate::user_settings::{self, Settings};
    matches!(user_settings::read(), Settings::Parsed(doc)
        if user_settings::value(&doc, AUTO_CLOUD_KEY) == Some(Value::Bool(true)))
}

/// A shell call's start, as the hub saw it.
#[derive(Debug, Clone)]
pub struct Start {
    pub session: String,
    pub tool_call_id: String,
    pub repo: String,
    pub script: String,
    pub background: bool,
    /// The session's agent process, the root its commands run under.
    pub agent_pid: Option<u32>,
}

/// The shell call a `tool_call` or `tool_call_update` starts: kind `execute` (or none named) with
/// a `rawInput.command`. Claude Code's Bash carries `run_in_background`.
pub fn start_of(update: &Value) -> Option<(String, String, bool)> {
    if !matches!(
        update.get("sessionUpdate").and_then(Value::as_str),
        Some("tool_call" | "tool_call_update")
    ) {
        return None;
    }
    if update.get("kind").and_then(Value::as_str).is_some_and(|k| k != "execute") {
        return None;
    }
    if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
        return None;
    }
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let raw = update.get("rawInput")?;
    let script = match raw.get("command")? {
        Value::String(s) => s.clone(),
        Value::Array(argv) => argv.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "),
        _ => return None,
    };
    if script.trim().is_empty() {
        return None;
    }
    let background = raw.get("run_in_background").and_then(Value::as_bool).unwrap_or(false);
    Some((id.to_owned(), script, background))
}

/// The end a `tool_call_update` reports: its status, when completed or failed.
pub fn end_of(update: &Value) -> Option<(&str, &str)> {
    let status = update.get("status").and_then(Value::as_str)?;
    if !matches!(status, "completed" | "failed") {
        return None;
    }
    Some((update.get("toolCallId").and_then(Value::as_str)?, status))
}

/// One shell call being watched.
#[derive(Debug)]
struct Flight {
    start: Start,
    class: String,
    predicted: Predicted,
    situation: Situation,
    verdict: Verdict,
    began_ms: u64,
    began: Instant,
    /// When it began, in the kernel's clock ticks since boot (a process's `starttime`).
    began_ticks: Option<u64>,
    ended: Option<(Instant, String)>,
    /// Its processes: pid to start time.
    procs: HashMap<u32, u64>,
    cpu_ticks: u64,
    peak_rss_bytes: u64,
    ports: BTreeSet<u16>,
    samples: u32,
    alive_at_end: Option<bool>,
}

/// The shadow placer's state. One per daemon ([`global`]); tests make their own.
pub struct Shadow {
    inner: Mutex<Inner>,
    wake: Condvar,
    path: PathBuf,
}

#[derive(Default)]
struct Inner {
    table: Table,
    loaded: bool,
    flights: HashMap<(String, String), Flight>,
    file: Option<(std::fs::File, u64)>,
    thread: bool,
}

static GLOBAL: std::sync::OnceLock<Shadow> = std::sync::OnceLock::new();

/// This daemon's shadow placer.
pub fn global() -> &'static Shadow {
    GLOBAL.get_or_init(|| Shadow::new(file_path()))
}

/// The hub's hook (`stalled_turn.rs`): one `session/update` of a session's agent. Only a shell
/// call's start reads the settings key; anything else is a map lookup, or nothing.
pub fn note_update(
    session: &str,
    repo: impl FnOnce() -> String,
    agent_pid: impl FnOnce() -> Option<u32>,
    update: &Value,
) {
    let Some(shadow) = GLOBAL.get() else {
        if start_of(update).is_some() && enabled() {
            let shadow = global();
            shadow.note(session, repo, agent_pid, update, true);
        }
        return;
    };
    shadow.note(session, repo, agent_pid, update, false);
}

impl Shadow {
    pub fn new(path: PathBuf) -> Self {
        Shadow { inner: Mutex::new(Inner::default()), wake: Condvar::new(), path }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn note(
        &'static self,
        session: &str,
        repo: impl FnOnce() -> String,
        agent_pid: impl FnOnce() -> Option<u32>,
        update: &Value,
        checked: bool,
    ) {
        if let Some((id, status)) = end_of(update) {
            self.end(session, id, status);
            return;
        }
        let Some((id, script, background)) = start_of(update) else { return };
        if self.lock().flights.contains_key(&(session.to_owned(), id.clone())) {
            return;
        }
        if !checked && !enabled() {
            return;
        }
        let start = Start {
            session: session.to_owned(),
            tool_call_id: id,
            repo: repo(),
            script,
            background,
            agent_pid: agent_pid(),
        };
        self.begin(start, boot_ticks_now());
        self.ensure_thread();
    }

    fn ensure_thread(&'static self) {
        let mut inner = self.lock();
        if inner.thread {
            self.wake.notify_all();
            return;
        }
        inner.thread = true;
        drop(inner);
        let spawned = std::thread::Builder::new().name("command-placer".into()).spawn(move || {
            loop {
                let mut inner = self.lock();
                while inner.flights.is_empty() {
                    inner = self.wake.wait(inner).unwrap_or_else(|e| e.into_inner());
                }
                drop(inner);
                self.tick_live();
                std::thread::sleep(TICK);
            }
        });
        if spawned.is_err() {
            self.lock().thread = false;
        }
    }

    /// Notes a shell call's start: its class, prediction and verdict, decided now.
    pub fn begin(&self, start: Start, began_ticks: Option<u64>) {
        let mut inner = self.lock();
        if !inner.loaded {
            inner.loaded = true;
            reload(&self.path, &mut inner.table);
        }
        let class = shadow::class_of(&start.script);
        let predicted = inner.table.predict(&start.repo, &class, &start.script, start.background);
        let heavy_running = inner
            .flights
            .values()
            .filter(|f| f.start.session == start.session && f.ended.is_none())
            .filter(|f| matches!(f.verdict.decision, Decision::Grow | Decision::RunVm))
            .count() as u32;
        let situation =
            Situation { agent_vm: shadow::AGENT_VM_START, heavy_running, fork_p95_ms: None };
        let verdict = shadow::decide(&predicted, &situation);
        let flight = Flight {
            class,
            predicted,
            situation,
            verdict,
            began_ms: crate::store::now_ms(),
            began: Instant::now(),
            began_ticks,
            ended: None,
            procs: HashMap::new(),
            cpu_ticks: 0,
            peak_rss_bytes: 0,
            ports: BTreeSet::new(),
            samples: 0,
            alive_at_end: None,
            start,
        };
        if inner.flights.len() >= MAX_FLIGHTS {
            let row = row_of(&flight, Some("not watched: too many calls in flight"));
            self.write(&mut inner, &row);
            return;
        }
        let key = (flight.start.session.clone(), flight.start.tool_call_id.clone());
        inner.flights.insert(key, flight);
    }

    /// Notes a shell call's end. Its row is written at the next tick, after a last reading.
    pub fn end(&self, session: &str, id: &str, status: &str) {
        let mut inner = self.lock();
        if let Some(f) = inner.flights.get_mut(&(session.to_owned(), id.to_owned()))
            && f.ended.is_none()
        {
            f.ended = Some((Instant::now(), status.to_owned()));
        }
    }

    /// One reading of every call in flight, and the rows of those that are done.
    pub fn tick(&self, read: &dyn Fn() -> Option<Procs>) {
        let procs = read();
        let mut inner = self.lock();
        let mut done = Vec::new();
        let now = Instant::now();
        if let Some(procs) = &procs {
            attribute(&mut inner.flights, procs);
        }
        for (key, f) in inner.flights.iter_mut() {
            if let Some(procs) = &procs {
                measure(f, procs);
            }
            let Some((ended_at, _)) = &f.ended else {
                if now.duration_since(f.began) > MAX_FLIGHT {
                    done.push(key.clone());
                }
                continue;
            };
            let alive =
                procs.as_ref().is_some_and(|p| f.procs.keys().any(|pid| p.rows.contains_key(pid)));
            f.alive_at_end.get_or_insert(alive);
            if !alive || now.duration_since(*ended_at) >= LINGER || procs.is_none() {
                done.push(key.clone());
            }
        }
        for key in done {
            if let Some(f) = inner.flights.remove(&key) {
                let why = if f.ended.is_none() { Some("no end seen") } else { None };
                let row = row_of(&f, why);
                if let Some(run) = run_of(&f) {
                    inner.table.record(&f.start.repo, &f.class, run);
                }
                self.write(&mut inner, &row);
            }
        }
    }

    fn write(&self, inner: &mut Inner, row: &Value) {
        let line = format!("{row}\n");
        if inner.file.is_none() {
            let size = std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0);
            inner.file = open_append(&self.path).ok().map(|f| (f, size));
        }
        let Some((file, written)) = inner.file.as_mut() else { return };
        if *written + line.len() as u64 > FILE_CAP {
            let _ = std::fs::rename(&self.path, self.path.with_extension("jsonl.1"));
            match open_append(&self.path) {
                Ok(fresh) => {
                    *file = fresh;
                    *written = 0;
                }
                Err(_) => return,
            }
        }
        if file.write_all(line.as_bytes()).is_ok() {
            *written += line.len() as u64;
        }
    }
}

fn open_append(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    crate::home_fs::OpenOptions::new().create(true).append(true).mode(0o600).open(path)
}

/// Refills the prediction table from the rows file's newest [`RELOAD_BYTES`].
fn reload(path: &std::path::Path, table: &mut Table) {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = std::fs::File::open(path) else { return };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let from = len.saturating_sub(RELOAD_BYTES);
    if file.seek(SeekFrom::Start(from)).is_err() {
        return;
    }
    let mut text = String::new();
    if file.take(RELOAD_BYTES).read_to_string(&mut text).is_err() {
        return;
    }
    // A cut first line is not a row.
    let lines = text.lines().skip(usize::from(from > 0));
    for line in lines {
        let Ok(row) = serde_json::from_str::<Value>(line) else { continue };
        let (Some(repo), Some(class), Some(wall)) = (
            row.get("repo").and_then(Value::as_str),
            row.get("class").and_then(Value::as_str),
            row.get("wallS").and_then(Value::as_f64),
        ) else {
            continue;
        };
        let Some(usage) = row.get("usage").filter(|u| !u.is_null()) else { continue };
        table.record(
            repo,
            class,
            shadow::Run {
                wall_s: wall,
                cpu_s: usage.get("cpuS").and_then(Value::as_f64),
                peak_mem_gib: usage.get("peakMemGiB").and_then(Value::as_f64),
                listened: usage
                    .get("ports")
                    .and_then(Value::as_array)
                    .is_some_and(|p| !p.is_empty()),
                outlived: usage.get("outlived").and_then(Value::as_bool).unwrap_or(false),
            },
        );
    }
}

/// What a finished call adds to the prediction table: only a measured one.
fn run_of(f: &Flight) -> Option<shadow::Run> {
    let (ended_at, _) = f.ended.as_ref()?;
    if f.samples == 0 {
        return None;
    }
    Some(shadow::Run {
        wall_s: ended_at.duration_since(f.began).as_secs_f64(),
        // No process of its seen: it ended between two readings, its usage unmeasured, not zero.
        cpu_s: (!f.procs.is_empty()).then(|| f.cpu_ticks as f64 / clock_ticks()),
        peak_mem_gib: (!f.procs.is_empty()).then(|| f.peak_rss_bytes as f64 / GIB),
        listened: !f.ports.is_empty(),
        outlived: f.alive_at_end == Some(true),
    })
}

const GIB: f64 = (1u64 << 30) as f64;

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

/// A call's row.
fn row_of(f: &Flight, why: Option<&str>) -> Value {
    let wall = f.ended.as_ref().map(|(at, _)| round3(at.duration_since(f.began).as_secs_f64()));
    let usage = (f.samples > 0).then(|| {
        json!({
            "peakMemGiB": (!f.procs.is_empty()).then(|| round3(f.peak_rss_bytes as f64 / GIB)),
            "cpuS": (!f.procs.is_empty()).then(|| round3(f.cpu_ticks as f64 / clock_ticks())),
            "ports": f.ports,
            "outlived": f.alive_at_end == Some(true),
            "procs": f.procs.len(),
            "samples": f.samples,
        })
    });
    let host = host_shape();
    json!({
        "v": 1,
        "ts": f.began_ms,
        "session": f.start.session,
        "toolCallId": f.start.tool_call_id,
        "repo": f.start.repo,
        "class": f.class,
        "background": f.start.background,
        "decision": f.verdict.decision,
        "row": f.verdict.row,
        "rowNumber": f.verdict.row.number(),
        "shape": f.verdict.shape,
        "predicted": f.predicted,
        "situation": f.situation,
        "host": host,
        "status": f.ended.as_ref().map(|(_, s)| s.as_str()),
        "wallS": wall,
        "usage": usage,
        "why": why.or(match (&usage, f.start.agent_pid) {
            (None, None) => Some("usage unknown: no agent process"),
            (None, _) if cfg!(not(target_os = "linux")) => Some("usage unknown: not Linux"),
            (None, _) => Some("usage unknown: no process seen"),
            _ if f.procs.is_empty() => Some("usage unmeasured: it ended between two readings"),
            _ => None,
        }),
    })
}

/// This machine's shape, read once.
fn host_shape() -> Value {
    static SHAPE: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    SHAPE
        .get_or_init(|| {
            let vcpu = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
            let mem = std::fs::read_to_string("/proc/meminfo").ok().and_then(|t| {
                let kib: f64 = t
                    .lines()
                    .find(|l| l.starts_with("MemTotal:"))?
                    .split_whitespace()
                    .nth(1)?
                    .parse()
                    .ok()?;
                Some(round3(kib / (1u64 << 20) as f64))
            });
            json!({"vcpu": vcpu, "memGiB": mem})
        })
        .clone()
}

/// One process, as `/proc/<pid>/stat` says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Proc {
    pub ppid: u32,
    /// Start time, clock ticks since boot.
    pub start: u64,
    /// `utime + stime + cutime + cstime`, clock ticks.
    pub cpu: u64,
    pub rss_bytes: u64,
}

/// One reading of the process table, and the listening sockets by inode.
#[derive(Debug, Default)]
pub struct Procs {
    pub rows: HashMap<u32, Proc>,
    pub listening: HashMap<u64, u16>,
    /// A process's socket inodes, read only for the processes a call owns.
    pub sockets: HashMap<u32, Vec<u64>>,
}

/// Gives each call in flight its processes: walking down from each session's agent process, the
/// first process of a branch that started after one of the session's calls began is the latest
/// such call's, with everything under it.
fn attribute(flights: &mut HashMap<(String, String), Flight>, procs: &Procs) {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (pid, p) in &procs.rows {
        children.entry(p.ppid).or_default().push(*pid);
    }
    let mut roots: HashMap<u32, Vec<(&(String, String), u64)>> = HashMap::new();
    for (key, f) in flights.iter() {
        if let (Some(pid), Some(began)) = (f.start.agent_pid, f.began_ticks) {
            roots.entry(pid).or_default().push((key, began));
        }
    }
    let mut owned: Vec<(&(String, String), u32, u64)> = Vec::new();
    for (root, calls) in &roots {
        let mut stack: Vec<(u32, Option<usize>)> =
            children.get(root).into_iter().flatten().map(|c| (*c, None)).collect();
        let mut seen = 0usize;
        while let Some((pid, owner)) = stack.pop() {
            seen += 1;
            if seen > 1 << 16 {
                break;
            }
            let Some(p) = procs.rows.get(&pid) else { continue };
            let owner = owner.or_else(|| {
                calls
                    .iter()
                    .enumerate()
                    .filter(|(_, (_, began))| p.start >= *began)
                    .max_by_key(|(_, (_, began))| *began)
                    .map(|(i, _)| i)
            });
            if let Some((call, _)) = owner.and_then(|i| calls.get(i)) {
                owned.push((*call, pid, p.start));
            }
            for c in children.get(&pid).into_iter().flatten() {
                stack.push((*c, owner));
            }
        }
    }
    let owned: Vec<((String, String), u32, u64)> =
        owned.into_iter().map(|(k, pid, start)| (k.clone(), pid, start)).collect();
    for (key, pid, start) in owned {
        if let Some(f) = flights.get_mut(&key)
            && f.procs.len() < MAX_PROCS
        {
            f.procs.entry(pid).or_insert(start);
        }
    }
}

/// Adds one reading to a call: its live processes' CPU, memory and ports.
fn measure(f: &mut Flight, procs: &Procs) {
    if f.start.agent_pid.is_none() || f.began_ticks.is_none() {
        return;
    }
    f.samples += 1;
    let mut cpu = 0u64;
    let mut rss = 0u64;
    for (pid, start) in &f.procs {
        let Some(p) = procs.rows.get(pid).filter(|p| p.start == *start) else { continue };
        cpu += p.cpu;
        rss += p.rss_bytes;
        for inode in procs.sockets.get(pid).into_iter().flatten() {
            if let Some(port) = procs.listening.get(inode) {
                f.ports.insert(*port);
            }
        }
    }
    f.cpu_ticks = f.cpu_ticks.max(cpu);
    f.peak_rss_bytes = f.peak_rss_bytes.max(rss);
}

fn clock_ticks() -> f64 {
    #[cfg(unix)]
    {
        // SAFETY: sysconf takes a constant and has no other effect.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if hz > 0 {
            return hz as f64;
        }
    }
    100.0
}

/// Now, in the kernel's clock ticks since boot (`/proc/uptime`), the clock a process's
/// `starttime` is in. A small step back covers a call whose process started in the same tick.
fn boot_ticks_now() -> Option<u64> {
    let text = std::fs::read_to_string("/proc/uptime").ok()?;
    let secs: f64 = text.split_whitespace().next()?.parse().ok()?;
    Some(((secs * clock_ticks()) as u64).saturating_sub(2))
}

/// One `/proc/<pid>/stat` line read: the fields after the command name (which may hold spaces
/// and parentheses, so the last `)` ends it).
pub fn parse_stat(text: &str, page: u64) -> Option<Proc> {
    let rest = text.get(text.rfind(')')? + 1..)?;
    let f: Vec<&str> = rest.split_whitespace().collect();
    // f[0] is field 3 (state): field n is f[n - 3].
    let n = |i: usize| f.get(i - 3).and_then(|v| v.parse::<u64>().ok());
    let cpu = n(14)? + n(15)? + n(16)? + n(17)?;
    Some(Proc { ppid: n(4)? as u32, start: n(22)?, cpu, rss_bytes: n(24)? * page })
}

/// Listening TCP sockets in a `/proc/net/tcp` or `tcp6` table: inode to local port.
pub fn parse_listening(text: &str, into: &mut HashMap<u64, u16>) {
    for line in text.lines().skip(1) {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.get(3) != Some(&"0A") {
            continue;
        }
        let port = f
            .get(1)
            .and_then(|a| a.rsplit(':').next())
            .and_then(|p| u16::from_str_radix(p, 16).ok());
        let inode = f.get(9).and_then(|i| i.parse::<u64>().ok());
        if let (Some(port), Some(inode)) = (port, inode) {
            into.insert(inode, port);
        }
    }
}

/// The processes under `roots` (the sessions' agent processes, which acpmux holds, and the
/// processes calls already own), with listening sockets; None elsewhere than Linux. No process
/// table is listed: it walks down from each root through its threads' `children` files and reads
/// those processes' `stat` only.
fn read_procs(roots: &[u32]) -> Option<Procs> {
    #[cfg(target_os = "linux")]
    {
        // SAFETY: sysconf takes a constant and has no other effect.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) }.max(4096) as u64;
        let mut procs = Procs::default();
        let mut stack: Vec<u32> = roots.to_vec();
        while let Some(pid) = stack.pop() {
            if procs.rows.contains_key(&pid) || procs.rows.len() >= 1 << 14 {
                continue;
            }
            let Some(p) = std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|t| parse_stat(&t, page))
            else {
                continue;
            };
            procs.rows.insert(pid, p);
            let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) else { continue };
            for task in tasks.flatten() {
                let Ok(text) = std::fs::read_to_string(task.path().join("children")) else {
                    continue;
                };
                stack.extend(text.split_whitespace().filter_map(|c| c.parse::<u32>().ok()));
            }
        }
        for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
            if let Ok(text) = std::fs::read_to_string(table) {
                parse_listening(&text, &mut procs.listening);
            }
        }
        Some(procs)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = roots;
        None
    }
}

/// The socket inodes `pid` holds (`/proc/<pid>/fd`).
#[cfg(target_os = "linux")]
fn sockets_of(pid: u32) -> Vec<u64> {
    let Ok(dir) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { return Vec::new() };
    dir.flatten()
        .filter_map(|e| std::fs::read_link(e.path()).ok())
        .filter_map(|l| {
            let l = l.to_str()?.to_owned();
            l.strip_prefix("socket:[")?.strip_suffix(']')?.parse().ok()
        })
        .collect()
}

impl Shadow {
    /// [`Shadow::tick`] with the sockets of the processes calls own read in, between attribution
    /// and measurement (the daemon's sampler; a test passes its own reading to `tick`).
    pub fn tick_live(&self) {
        self.tick(&|| {
            let roots: Vec<u32> = {
                let inner = self.lock();
                let agents = inner.flights.values().filter_map(|f| f.start.agent_pid);
                let owned = inner.flights.values().flat_map(|f| f.procs.keys().copied());
                agents.chain(owned).collect::<BTreeSet<_>>().into_iter().collect()
            };
            let mut procs = read_procs(&roots)?;
            #[cfg(target_os = "linux")]
            if !procs.listening.is_empty() {
                let mut inner = self.lock();
                attribute(&mut inner.flights, &procs);
                let pids: Vec<u32> =
                    inner.flights.values().flat_map(|f| f.procs.keys().copied()).collect();
                drop(inner);
                for pid in pids {
                    if procs.rows.contains_key(&pid) {
                        procs.sockets.insert(pid, sockets_of(pid));
                    }
                }
            }
            Some(procs)
        });
    }
}

#[cfg(test)]
#[path = "command_sampler_tests.rs"]
mod tests;
