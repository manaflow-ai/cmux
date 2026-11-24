//! What one streamed text delta costs, in a small chat and in the god chat (hq
//! `docs/design/agent-service-v2.md`: "a text delta costs its own length"). Leo, 2026-11-19: "a lot of
//! this is just applying things properly and having those measurements in so that we're aware of
//! things".
//!
//! For each home (`god_fixture::Shape`, `ACPMUX_GOD_SHAPES`, default `small,god`;
//! `ACPMUX_GOD_SCALE` shrinks the god one) the real daemon starts over it, and one client does
//! what the pane does: it watches the list, attaches the big chat and follows its rows
//! (`_acpmux/rows` `follow`). A stand-in agent then streams turns of `ACPMUX_DELTA_N` reply chunks
//! of a fixed length (`delta-chunks: N L`, `tests/fake_agent.py`), at two lengths, so the bytes a
//! delta costs split into its length (the slope) and its framing (the rest). Per delta it reports:
//!
//! - `v1`: the `session/update` lines the attached client reads (what the pane reads today), their
//!   bytes per delta, per byte of delta text and above it (framing);
//! - `rows`: the `_acpmux/rows_patch` lines, their bytes, patches and rows touched per delta, and
//!   the patches that carry a whole row (`Insert` or `Text`) instead of the delta (`Append`);
//! - `list`: the `_acpmux/session_changed` lines the watcher reads per delta, and their bytes;
//! - `other`: every other line of the turn, per delta (the prompt's own lines, amortized);
//! - `daemonCpuUsPerDelta`: the daemon's user and system CPU over the turn, per delta;
//! - `wallUsPerDelta`: the prompt's request to its response, per delta;
//! - `fold`: the row fold alone (`rows::RowTable::apply`) in this process, over the chat's own log
//!   up to the last turn, then that turn's records timed: ns and patches per delta.
//!
//! Each home prints a `DELTA-COST` JSON line; the run ends with `DELTA-COST-RATIO`, one row per
//! measure with the god value, the small one, their ratio and the bar (god at most 1.2x small,
//! bytes per delta at most the delta's length plus a constant). The byte and row bars fail the
//! test; the time bars are printed, since one CI sample is noisy. Manual, on Linux CI:
//! `cargo test -p acpmux --release --test acpmux_all delta_cost -- --ignored --nocapture`.

// The per-home `json!` has more keys than the default limit expands, as in `god_daemon.rs`.
#![recursion_limit = "256"]
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The prompt goes to tests/fake_agent.py; the sizes hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_GOD_SHAPES",
    "ACPMUX_GOD_SCALE",
    "ACPMUX_DELTA_N",
    "ACPMUX_DELTA_ROUNDS",
]);

use acpmux::god_fixture::{self, Shape};
use acpmux::rows::{Patch, RowTable};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// The longest any one step may take before the run fails.
const STEP: Duration = Duration::from_secs(600);
/// The two delta lengths, in bytes: the slope between them is what a byte of text costs.
const SHORT: u64 = 16;
const LONG: u64 = 256;
/// The bar: god at most this many times small.
const BAR: f64 = 1.2;
/// How long to wait for every chat log to be read before measuring.
const ALL_LOGS: Duration = Duration::from_secs(300);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn median(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(f64::total_cmp);
    samples.get(samples.len() / 2).copied().unwrap_or(f64::NAN)
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// The real daemon over one home.
struct Daemon {
    child: Child,
    socket: PathBuf,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path) -> Self {
        let socket = scratch.join("s.sock");
        let mut command = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let spawned = Instant::now();
        let mut child = command.spawn().expect("spawn the daemon");
        while UnixStream::connect(&socket).is_err() {
            let exited = child.try_wait().ok().flatten().is_some();
            if spawned.elapsed() >= STEP || exited {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        Self { child, socket }
    }

    /// The daemon's CPU time so far, user and system, in microseconds (`/proc/PID/stat`).
    fn cpu_us(&self) -> f64 {
        let stat =
            std::fs::read_to_string(format!("/proc/{}/stat", self.child.id())).unwrap_or_default();
        let rest = stat.rsplit_once(')').map_or("", |(_, r)| r);
        let fields: Vec<&str> = rest.split_whitespace().collect();
        // utime and stime are fields 14 and 15; `rest` starts at field 3.
        let field = |n: usize| fields.get(n - 3).and_then(|f| f.parse::<u64>().ok()).unwrap_or(0);
        // SAFETY: sysconf reads a constant.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1);
        (field(14) + field(15)) as f64 * 1e6 / hz as f64
    }

    fn stop(&mut self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One line the client read: its bytes on the wire (newline included) and its JSON.
struct Line {
    bytes: u64,
    v: Value,
}

/// A newline-delimited JSON-RPC client on the daemon's socket.
struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon's socket");
        s.set_read_timeout(Some(STEP)).expect("set a read timeout");
        let reader = BufReader::new(s.try_clone().expect("clone the socket"));
        Self { reader, writer: s, next: 0 }
    }

    fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).expect("write a request");
        self.next
    }

    fn read(&mut self) -> Line {
        let mut text = String::new();
        let n = self.reader.read_line(&mut text).expect("read a line");
        assert!(n > 0, "the daemon closed the socket");
        let v = serde_json::from_str(&text).expect("a JSON line");
        Line { bytes: n as u64, v }
    }

    /// Reads until the response to `id`, handing every other line to `seen`.
    fn until_response(&mut self, id: u64, mut seen: impl FnMut(&Line)) -> Result<Value, Value> {
        loop {
            let line = self.read();
            if line.v.get("method").is_none() && line.v.get("id") == Some(&json!(id)) {
                return match line.v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(line.v.get("result").cloned().unwrap_or(Value::Null)),
                };
            }
            seen(&line);
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.request(method, params);
        self.until_response(id, |_| {})
    }
}

/// What one turn of deltas sent the client.
#[derive(Default)]
struct Tally {
    v1_lines: u64,
    v1_bytes: u64,
    patch_lines: u64,
    patch_bytes: u64,
    patches: u64,
    whole_row_patches: u64,
    rows_touched: u64,
    list_lines: u64,
    list_bytes: u64,
    /// The largest list notice: its bytes, whether it names this chat, and each of its summary's
    /// top-level keys by bytes (what a list notice carries).
    list_max: u64,
    list_max_of_chat: bool,
    list_max_keys: BTreeMap<String, u64>,
    /// List notices that name another chat than the one streaming.
    list_other_chats: u64,
    other_lines: u64,
    other_bytes: u64,
    other_methods: BTreeMap<String, u64>,
}

/// The bytes of each top-level key of the summary a list notice carries.
fn key_bytes(params: &Value) -> BTreeMap<String, u64> {
    let summary = ["session", "summary", "row"]
        .iter()
        .find_map(|k| params.get(*k).filter(|v| v.is_object()))
        .unwrap_or(params);
    let mut out = BTreeMap::new();
    if let Some(o) = summary.as_object() {
        for (k, v) in o {
            out.insert(k.clone(), serde_json::to_vec(v).map_or(0, |b| b.len() as u64));
        }
    }
    out
}

impl Tally {
    fn take(&mut self, chat: &str, line: &Line) {
        let v = &line.v;
        let method = v.get("method").and_then(Value::as_str).unwrap_or("");
        let params = v.get("params").unwrap_or(&Value::Null);
        let of_chat = params.get("sessionId").and_then(Value::as_str) == Some(chat);
        let update_kind = params.pointer("/update/sessionUpdate").and_then(Value::as_str);
        if method == "session/update" && of_chat && update_kind == Some("agent_message_chunk") {
            self.v1_lines += 1;
            self.v1_bytes += line.bytes;
        } else if method == "_acpmux/rows_patch" && of_chat {
            self.patch_lines += 1;
            self.patch_bytes += line.bytes;
            let patches = params.get("patches").and_then(Value::as_array);
            let mut touched = BTreeSet::new();
            for p in patches.into_iter().flatten() {
                self.patches += 1;
                let op = p.get("op").and_then(Value::as_str).unwrap_or("");
                if op == "insert" || op == "text" {
                    self.whole_row_patches += 1;
                }
                let index = p
                    .get("index")
                    .or_else(|| p.pointer("/row/index"))
                    .or_else(|| p.pointer("/head/index"))
                    .and_then(Value::as_u64);
                touched.insert(index);
            }
            self.rows_touched += touched.len() as u64;
        } else if method == "_acpmux/session_changed" {
            self.list_lines += 1;
            self.list_bytes += line.bytes;
            let names = |id: &str| v.to_string().contains(id);
            if !names(chat) {
                self.list_other_chats += 1;
            }
            if line.bytes > self.list_max {
                self.list_max = line.bytes;
                self.list_max_of_chat = names(chat);
                self.list_max_keys = key_bytes(params);
            }
        } else {
            self.other_lines += 1;
            self.other_bytes += line.bytes;
            let key = if method == "session/update" {
                format!("session/update:{}", update_kind.unwrap_or("?"))
            } else {
                method.to_owned()
            };
            *self.other_methods.entry(key).or_default() += 1;
        }
    }
}

/// One turn's measures, per delta.
struct Turn {
    tally: Tally,
    deltas: u64,
    cpu_us: f64,
    wall_us: f64,
}

impl Turn {
    fn per(&self, v: u64) -> f64 {
        v as f64 / self.deltas.max(1) as f64
    }
}

/// One turn of `deltas` chunks of `len` bytes to `chat`.
fn turn(client: &mut Client, daemon: &Daemon, chat: &str, deltas: u64, len: u64) -> Turn {
    let text = format!("delta-chunks: {deltas} {len}");
    let prompt = json!({"sessionId": chat, "prompt": [{"type": "text", "text": text}]});
    let mut tally = Tally::default();
    let cpu = daemon.cpu_us();
    let sent = Instant::now();
    let id = client.request("session/prompt", prompt);
    let reply = client.until_response(id, |line| tally.take(chat, line));
    let wall_us = sent.elapsed().as_secs_f64() * 1e6;
    let cpu_us = daemon.cpu_us() - cpu;
    if let Err(e) = reply {
        panic!("the delta turn failed: {e}");
    }
    Turn { tally, deltas, cpu_us, wall_us }
}

/// Asks `_acpmux/status` until its "all chat logs" startup phase has ended.
fn wait_all_logs(client: &mut Client) {
    let deadline = Instant::now() + ALL_LOGS;
    while Instant::now() < deadline {
        if let Ok(status) = client.call("_acpmux/status", json!({})) {
            let phases = status.pointer("/gauges/startup").and_then(Value::as_array);
            let done = phases
                .into_iter()
                .flatten()
                .any(|p| p.get("name") == Some(&json!("all chat logs")) && p.get("ms").is_some());
            if done {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("every chat log was not read within {ALL_LOGS:?}");
}

/// The row fold alone over chat `id`'s own log: every record up to `cut` folded off the clock,
/// then the records after it (the last delta turn) timed.
fn fold_cost(home: &Path, id: &str, cut: u64) -> Value {
    let mut cfg = acpmux::config::Config::default();
    cfg.store.mode = acpmux::config::StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, home).expect("open the store");
    let mut table = RowTable::new();
    let mut sink = Vec::new();
    let mut tail = Vec::new();
    let folded = Instant::now();
    store
        .scan(id, 0, &mut |rec| {
            if rec.seq <= cut {
                table.apply(&rec, &mut sink);
                sink.clear();
            } else {
                tail.push(rec);
            }
            true
        })
        .expect("scan the chat's log");
    let fold_ms = folded.elapsed().as_secs_f64() * 1e3;
    let rows = table.rows().len();
    let deltas = tail.iter().filter(|r| r.dir == "in" && r.kind == "agent_message_chunk").count();
    let mut patches: Vec<Patch> = Vec::with_capacity(tail.len());
    let timed = Instant::now();
    for rec in &tail {
        table.apply(rec, &mut patches);
    }
    let ns = timed.elapsed().as_secs_f64() * 1e9;
    let whole =
        patches.iter().filter(|p| matches!(p, Patch::Insert { .. } | Patch::Text { .. })).count();
    let patch_bytes: usize =
        patches.iter().map(|p| serde_json::to_vec(p).map_or(0, |b| b.len())).sum();
    let per = |v: f64| round2(v / deltas.max(1) as f64);
    json!({
        "rowsBefore": rows,
        "foldToCutMs": round2(fold_ms),
        "tailRecords": tail.len(),
        "deltas": deltas,
        "nsPerDelta": per(ns),
        "patchesPerDelta": per(patches.len() as f64),
        "wholeRowPatches": whole,
        "patchBytesPerDelta": per(patch_bytes as f64),
    })
}

fn write_config(home: &Path) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    });
    std::fs::write(home.join("config.json"), config.to_string()).expect("write config.json");
}

/// The medians of `turns` at one delta length.
fn summarize(turns: &[Turn], len: u64) -> Value {
    let m = |f: &dyn Fn(&Turn) -> f64| round2(median(turns.iter().map(f).collect()));
    let v1 = m(&|t: &Turn| t.per(t.tally.v1_bytes));
    let others: BTreeMap<String, u64> =
        turns.last().map(|t| t.tally.other_methods.clone()).unwrap_or_default();
    json!({
        "deltaBytes": len,
        "v1": {
            "linesPerDelta": m(&|t: &Turn| t.per(t.tally.v1_lines)),
            "bytesPerDelta": v1,
            "bytesPerDeltaByte": round2(v1 / len as f64),
            "framingBytes": round2(v1 - len as f64),
        },
        "rows": {
            "linesPerDelta": m(&|t: &Turn| t.per(t.tally.patch_lines)),
            "bytesPerDelta": m(&|t: &Turn| t.per(t.tally.patch_bytes)),
            "patchesPerDelta": m(&|t: &Turn| t.per(t.tally.patches)),
            "rowsTouchedPerDelta": m(&|t: &Turn| t.per(t.tally.rows_touched)),
            "wholeRowPatchesPerTurn": m(&|t: &Turn| t.tally.whole_row_patches as f64),
        },
        "list": {
            "linesPerDelta": m(&|t: &Turn| t.per(t.tally.list_lines)),
            "bytesPerDelta": m(&|t: &Turn| t.per(t.tally.list_bytes)),
            "linesPerTurn": m(&|t: &Turn| t.tally.list_lines as f64),
            "bytesPerLine": m(&|t: &Turn| t.tally.list_bytes as f64 / t.tally.list_lines.max(1) as f64),
            "linesPerSecond": m(&|t: &Turn| t.tally.list_lines as f64 * 1e6 / t.wall_us.max(1.0)),
            "otherChatLinesPerTurn": m(&|t: &Turn| t.tally.list_other_chats as f64),
            "largestLine": turns.last().map(|t| json!({"bytes": t.tally.list_max,
                "ofChat": t.tally.list_max_of_chat, "keyBytes": t.tally.list_max_keys})),
        },
        "other": {
            "bytesPerDelta": m(&|t: &Turn| t.per(t.tally.other_bytes)),
            "linesPerTurn": m(&|t: &Turn| t.tally.other_lines as f64),
            "methods": others,
        },
        "wireBytesPerDelta": m(&|t: &Turn| {
            t.per(t.tally.v1_bytes + t.tally.patch_bytes + t.tally.list_bytes + t.tally.other_bytes)
        }),
        "daemonCpuUsPerDelta": m(&|t: &Turn| t.cpu_us / t.deltas.max(1) as f64),
        "wallUsPerDelta": m(&|t: &Turn| t.wall_us / t.deltas.max(1) as f64),
    })
}

fn run(shape: &Shape, deltas: u64, rounds: usize) -> Value {
    let scratch_dir = daemon_env::Scratch::new(&format!("delta-{}", shape.name));
    let scratch = scratch_dir.path().to_path_buf();
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), shape)
        .expect("write the fixture home");
    write_config(&home);
    let chat = made.god.clone();

    let mut daemon = Daemon::start(&scratch, &home);
    let mut client = Client::connect(&daemon.socket);
    client
        .call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "delta-cost"}}))
        .expect("initialize");
    client.call("_acpmux/watch", json!({"enabled": true})).expect("watch the list");
    wait_all_logs(&mut client);
    client
        .call(
            "_acpmux/attach",
            json!({"sessionId": chat, "waitLogs": false, "limit": 400, "maxBytes": 131072}),
        )
        .expect("attach the chat");
    let page = client
        .call("_acpmux/rows", json!({"sessionId": chat, "follow": true, "maxBytes": 65536}))
        .expect("follow the chat's rows");
    let rows_held = page.get("count").and_then(Value::as_u64).unwrap_or(0);
    // The first turn starts the agent; it is not measured.
    turn(&mut client, &daemon, &chat, 8, SHORT);

    let mut short = Vec::with_capacity(rounds);
    let mut long = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        short.push(turn(&mut client, &daemon, &chat, deltas, SHORT));
        long.push(turn(&mut client, &daemon, &chat, deltas, LONG));
    }
    // Where the last turn starts, for the fold alone: every record of the log up to here.
    let cut = client
        .call("_acpmux/rows", json!({"sessionId": chat, "maxBytes": 4096}))
        .ok()
        .and_then(|p| p.get("lastSeq").and_then(Value::as_u64))
        .unwrap_or(0);
    long.push(turn(&mut client, &daemon, &chat, deltas, LONG));
    drop(client);
    daemon.stop();
    let fold = fold_cost(&home, &chat, cut);

    let short = summarize(&short, SHORT);
    let long = summarize(&long, LONG);
    let slope = |path: &str| {
        let at = |s: &Value| s.pointer(path).and_then(Value::as_f64).unwrap_or(f64::NAN);
        round2((at(&long) - at(&short)) / (LONG - SHORT) as f64)
    };
    json!({
        "shape": shape.name,
        "chatMessages": shape.god_messages,
        "chatLogBytes": made.god_log_bytes,
        "rowsHeld": rows_held,
        "deltasPerTurn": deltas,
        "rounds": rounds,
        "bytesPerDeltaByte": {"v1": slope("/v1/bytesPerDelta"), "rows": slope("/rows/bytesPerDelta"),
                              "wire": slope("/wireBytesPerDelta")},
        "short": short,
        "long": long,
        "fold": fold,
    })
}

/// One row of the ratio table: a measure at `path` in both homes, and its bar.
fn ratio_row(small: &Value, god: &Value, name: &str, path: &str, unit: &str) -> Value {
    let at = |v: &Value| v.pointer(path).and_then(Value::as_f64).unwrap_or(f64::NAN);
    let (s, g) = (at(small), at(god));
    // Two zeros are equal; a zero small with a nonzero god is over any bar.
    let ratio = if s == 0.0 && g == 0.0 { 1.0 } else { g / s };
    json!({"name": name, "unit": unit, "small": s, "god": g, "ratio": round2(ratio),
           "bar": BAR, "pass": ratio <= BAR})
}

#[test]
#[ignore = "manual: the god home is 2 GB on disk; run on Linux CI"]
fn a_text_delta_costs_its_own_length_in_a_god_chat() {
    let shapes = std::env::var("ACPMUX_GOD_SHAPES").unwrap_or_else(|_| "small,god".to_owned());
    let deltas = env_or("ACPMUX_DELTA_N", 1000u64).max(1);
    let rounds = env_or("ACPMUX_DELTA_ROUNDS", 3usize).max(1);
    let mut results = BTreeMap::new();
    for name in shapes.split(',') {
        let shape = match name.trim() {
            "small" => Shape::small(),
            "god" => Shape::god_from_env(),
            other => panic!("ACPMUX_GOD_SHAPES: no shape {other}"),
        };
        let result = run(&shape, deltas, rounds);
        // One short line per part: a CI log cuts a long line.
        if let Some(parts) = result.as_object() {
            for (key, part) in parts {
                println!("DELTA-COST {} {key} {part}", shape.name);
            }
        }
        results.insert(shape.name, result);
    }
    let mut failures = Vec::new();
    for (name, r) in &results {
        // A delta's bytes grow by its own length: one byte of text is one byte on each path.
        for path in ["/bytesPerDeltaByte/v1", "/bytesPerDeltaByte/rows"] {
            let slope = r.pointer(path).and_then(Value::as_f64).unwrap_or(f64::NAN);
            if !(0.9..=1.2).contains(&slope) {
                failures.push(format!("{name}: {path} is {slope}, not about 1"));
            }
        }
        for len in ["short", "long"] {
            let touched = r
                .pointer(&format!("/{len}/rows/rowsTouchedPerDelta"))
                .and_then(Value::as_f64)
                .unwrap_or(f64::NAN);
            if touched > 1.05 {
                failures.push(format!("{name}: a {len} delta touches {touched} rows"));
            }
        }
    }
    if let (Some(small), Some(god)) = (results.get("small"), results.get("god")) {
        let rows = vec![
            ratio_row(small, god, "v1 bytes per delta (16 B)", "/short/v1/bytesPerDelta", "B"),
            ratio_row(small, god, "v1 bytes per delta (256 B)", "/long/v1/bytesPerDelta", "B"),
            ratio_row(
                small,
                god,
                "row patch bytes per delta (16 B)",
                "/short/rows/bytesPerDelta",
                "B",
            ),
            ratio_row(
                small,
                god,
                "row patch bytes per delta (256 B)",
                "/long/rows/bytesPerDelta",
                "B",
            ),
            ratio_row(
                small,
                god,
                "rows touched per delta",
                "/long/rows/rowsTouchedPerDelta",
                "rows",
            ),
            ratio_row(small, god, "list bytes per delta", "/long/list/bytesPerDelta", "B"),
            ratio_row(small, god, "wire bytes per delta (256 B)", "/long/wireBytesPerDelta", "B"),
            ratio_row(
                small,
                god,
                "daemon CPU per delta (256 B)",
                "/long/daemonCpuUsPerDelta",
                "us",
            ),
            ratio_row(small, god, "wall per delta (256 B)", "/long/wallUsPerDelta", "us"),
            ratio_row(small, god, "fold ns per delta", "/fold/nsPerDelta", "ns"),
        ];
        // Bytes and rows are counted, not timed: their bar fails the run. Times are printed.
        for row in &rows {
            let unit = row.get("unit").and_then(Value::as_str).unwrap_or("");
            if (unit == "B" || unit == "rows") && row.get("pass") != Some(&json!(true)) {
                failures.push(format!("god over {BAR}x small: {row}"));
            }
        }
        for row in &rows {
            println!("DELTA-COST-RATIO {row}");
        }
    }
    for failure in &failures {
        println!("DELTA-COST-FAIL {failure}");
    }
    assert!(failures.is_empty(), "a text delta does not cost its own length: {failures:#?}");
}
