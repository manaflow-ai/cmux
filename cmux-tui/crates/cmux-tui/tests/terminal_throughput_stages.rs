//! Terminal throughput by stage: where a large `cat` in a cmux NEXT terminal
//! spends its time between the PTY and the app, measured with no app.
//!
//! The Mac bench (scripts/cmux-next/terminal-throughput-bench.py, goal
//! terminal-throughput, CMUX-571) times one burst of terminal text written to
//! a terminal in 64 KiB writes until `tcdrain` returns: the terminal read every
//! byte off its PTY. Leo, 2026-11-12: "Infinite everything feels like nothing."
//! This test runs the same writer (the same 64 KiB writes and `tcdrain`) and
//! payload mix against a real headless daemon, so each stage of the byte path
//! gets its own MB/s:
//!
//! - `pty-only`: the kernel PTY alone, its master read and dropped by one
//!   thread: no terminal reads faster on this machine. The host alone, at
//!   macOS read sizes, has its own bench: cmux-tui-core
//!   `host_stage_throughput_bench`;
//! - `parse-NNNN`: ghostty-vt alone, the payload fed in NNNN-byte writes on
//!   one thread (the ceiling of any one parser of the stream);
//! - `daemon-hosted`: the daemon as the app runs it (`--state`): a terminal
//!   host process reads the PTY and parses, the daemon mirrors its stream and
//!   parses again; no viewer;
//! - `daemon-hosted+viewer`: the same with one byte attach reading every
//!   `output` event (JSON, base64 decoded);
//! - `daemon-hosted+viewer-snapshot`: the viewer attaches as the Mac app's
//!   terminal does (`set-client-info`, then a snapshot attach: READY, then
//!   `output` lines with offsets, base64 decoded);
//! - `daemon-hosted+viewer-frames`: the same snapshot attach from a connection
//!   that declared `attach-frames-v1`: `output` arrives as binary OUTPUT frames
//!   (16-byte header, raw bytes), no JSON scan and no base64;
//! - `daemon-ephemeral`: the daemon running the PTY in-process (`--ephemeral`,
//!   no host process): one parser, no host hop.
//!
//! For the daemon stages it also prints the busiest threads (CPU % of the
//! burst) of the daemon and the terminal host, and the viewer's events, so the
//! stage that caps the rate shows as a thread near 100 %. The viewer runs in
//! this test's process, which that sample does not read, so it reports its own
//! thread's CPU and the share of the burst it spent scanning lines and
//! decoding base64: a viewer near 100 % caps itself, not the daemon. Linux cuts thread
//! names to 15 bytes, so each carries its id: in a host, `terminal-host-p` with
//! the lower id is the parser (`terminal-host-parser`, started first), the
//! higher one the PTY reader (`terminal-host-pty`).
//!
//! Run (ignored in the normal test run):
//! `cargo test --release -p cmux-tui --test terminal_throughput_stages -- --ignored --nocapture`.
//! `CMUX_THROUGHPUT_MB` sets the payload (default 200), `CMUX_THROUGHPUT_STAGES`
//! picks stages (comma list of the names above, without the parse chunk),
//! `CMUX_THROUGHPUT_RUNS` the measured bursts of each daemon stage (default 1).
//! Each thread row carries its wakes (voluntary context switches in the
//! burst) and the viewer its socket reads, so a hand-off cap shows as many
//! wakes per MB with no thread near a core.
//! With `FAST_CHECKS_OUT` set it also writes `terminal-throughput-stages.json`.
#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const MB: f64 = 1_000_000.0;

/// The bench's writer, plus a go file: it reads the payload, waits for the go
/// file (the viewer attaches first), writes in 64 KiB writes, `tcdrain`s and
/// writes its result. argv: payload, result, go.
const WRITER: &str = r#"
import json, os, sys, termios, time
src, result, go = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "rb") as f:
    data = f.read()
while not os.path.exists(go):
    time.sleep(0.005)
view, n, off, chunk = memoryview(data), len(data), 0, 65536
t0 = time.perf_counter()
while off < n:
    off += os.write(1, view[off:off + chunk])
termios.tcdrain(1)
t1 = time.perf_counter()
os.write(1, b"\x1b[0m\r\nterminal-throughput: done\r\n")
tmp = result + ".tmp"
with open(tmp, "w") as f:
    json.dump({"bytes": n, "seconds": t1 - t0}, f)
os.rename(tmp, result)
"#;

/// About 1 MiB of the bench's mix (plain lines, lines longer than the grid,
/// 256-color SGR runs, UTF-8), the same every run.
fn payload_block() -> Vec<u8> {
    let words = [
        "cargo",
        "build",
        "warning:",
        "error[E0308]:",
        "src/main.rs:42:7",
        "Compiling",
        "Finished",
        "test",
        "ok",
        "PASS",
        "FAIL",
        "0x7ffee4b2c8a0",
        "GET",
        "/api/v1/sessions",
        "200",
        "1.24ms",
        "INFO",
        "DEBUG",
        "--release",
    ];
    let utf8 = ["é", "ü", "→", "✓", "✗", "日本語", "│", "─", "λ", "🙂"];
    let mut state: u64 = 571;
    let mut next = move |n: usize| {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((state >> 33) as usize) % n
    };
    let mut out = Vec::with_capacity(1 << 20);
    while out.len() < 1 << 20 {
        let kind = next(100);
        let mut line = String::new();
        if kind < 5 {
        } else if kind < 30 {
            for i in 0..4 + next(10) {
                if i > 0 {
                    line.push(' ');
                }
                line.push_str(&format!(
                    "\x1b[38;5;{}m{}\x1b[0m",
                    next(256),
                    words[next(words.len())]
                ));
            }
        } else if kind < 40 {
            for i in 0..6 + next(14) {
                if i > 0 {
                    line.push(' ');
                }
                let pick = next(words.len() + utf8.len());
                line.push_str(if pick < words.len() {
                    words[pick]
                } else {
                    utf8[pick - words.len()]
                });
            }
        } else {
            for i in 0..6 + next(24) {
                if i > 0 {
                    line.push(' ');
                }
                line.push_str(words[next(words.len())]);
            }
        }
        line.push('\n');
        out.extend_from_slice(line.as_bytes());
    }
    out
}

fn payload(bytes: usize) -> Vec<u8> {
    let block = payload_block();
    let mut out = Vec::with_capacity(bytes);
    while out.len() < bytes {
        let take = (bytes - out.len()).min(block.len());
        out.extend_from_slice(&block[..take]);
    }
    out
}

fn mb_s(bytes: usize, seconds: f64) -> f64 {
    if seconds > 0.0 { bytes as f64 / MB / seconds } else { 0.0 }
}

/// ghostty-vt alone: the payload in `chunk`-byte writes, translated `\n` to
/// `\r\n` first as the PTY's line discipline does.
fn parse_stage(data: &[u8], chunk: usize) -> Value {
    let mut term =
        ghostty_vt::Terminal::new(120, 40, 10_000_000, ghostty_vt::Callbacks::default()).unwrap();
    let started = Instant::now();
    for piece in data.chunks(chunk) {
        term.vt_write(piece);
    }
    let seconds = started.elapsed().as_secs_f64();
    json!({"stage": format!("parse-{chunk}"), "bytes": data.len(), "seconds": seconds,
           "mb_s": mb_s(data.len(), seconds)})
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: Option<PathBuf>,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // The daemon this test started, by its own handle.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Daemon {
    fn start(name: &str, hosted: bool) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-throughput-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let settings = dir.join("cmux-next.json");
        fs::write(&settings, "{}\n").unwrap();
        let home = dir.join("home");
        fs::create_dir_all(&home).unwrap();
        let state = hosted.then(|| dir.join("state"));
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command.args(["--headless", "--session", "main", "--socket"]).arg(&socket);
        match &state {
            Some(state) => command.arg("--state").arg(state),
            None => command.arg("--ephemeral"),
        };
        let child = command
            .env("HOME", &home)
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .env("ACPMUX_SOCKET", dir.join("acpmux.sock"))
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, state, dir }
    }

    fn request(&self, value: Value) -> Value {
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(writer, "{value}").unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "{value} failed: {response}");
        response["data"].clone()
    }

    fn host_pids(&self) -> Vec<u32> {
        let Some(state) = &self.state else { return Vec::new() };
        let root = cmux_tui_core::terminal_host_runtime::terminal_host_root(state, "main");
        fs::read_dir(root)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .filter_map(|record| record["host_pid"].as_u64())
            .filter_map(|pid| u32::try_from(pid).ok())
            .collect()
    }
}

/// CPU ticks (user + system) and wakes (voluntary context switches: each
/// time the thread blocked and was woken again) of every thread of `pid`, by
/// thread id: (name, ticks, wakes).
fn thread_ticks(pid: u32) -> HashMap<u32, (String, u64, u64)> {
    let mut out = HashMap::new();
    let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) else { return out };
    for task in tasks.filter_map(Result::ok) {
        let Some(tid) = task.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(stat) = fs::read_to_string(task.path().join("stat")) else { continue };
        let (Some(open), Some(close)) = (stat.find('('), stat.rfind(')')) else { continue };
        let name = stat[open + 1..close].to_string();
        let fields: Vec<&str> = stat[close + 2..].split_whitespace().collect();
        // Fields after the name start at field 3 (state); utime is field 14, stime 15.
        let ticks = fields.get(11).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0)
            + fields.get(12).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
        let wakes = fs::read_to_string(task.path().join("status"))
            .ok()
            .and_then(|status| {
                status.lines().find_map(|line| {
                    line.strip_prefix("voluntary_ctxt_switches:")
                        .and_then(|v| v.trim().parse::<u64>().ok())
                })
            })
            .unwrap_or(0);
        out.insert(tid, (name, ticks, wakes));
    }
    out
}

/// Snapshot files the output store replaced under `state` (each is a screen
/// replay under the terminal's parser lock, a gzip and two fsyncs): a thread
/// polls every 2 ms for a new inode of any `*.snap` file until it is stopped.
fn count_snapshots(state: Option<PathBuf>) -> (Arc<AtomicBool>, std::thread::JoinHandle<u64>) {
    use std::os::unix::fs::MetadataExt;
    fn snaps(dir: &Path, depth: u32, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|extension| extension == "snap") {
                out.push(path);
            } else if depth > 0 && path.is_dir() {
                snaps(&path, depth - 1, out);
            }
        }
    }
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    let handle = std::thread::spawn(move || {
        let Some(state) = state else { return 0 };
        let mut seen: HashMap<PathBuf, u64> = HashMap::new();
        let mut count = 0_u64;
        let mut files = Vec::new();
        let mut next_scan = Instant::now();
        while !flag.load(Ordering::Acquire) {
            if Instant::now() >= next_scan {
                files.clear();
                snaps(&state, 6, &mut files);
                next_scan = Instant::now() + Duration::from_millis(250);
            }
            for file in &files {
                if let Ok(metadata) = fs::metadata(file) {
                    let previous = seen.insert(file.clone(), metadata.ino());
                    if previous.is_some_and(|previous| previous != metadata.ino()) {
                        count += 1;
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        count
    });
    (stop, handle)
}

fn sample(pids: &[(String, u32)]) -> HashMap<(String, u32), (String, u64, u64)> {
    let mut out = HashMap::new();
    for (role, pid) in pids {
        for (tid, value) in thread_ticks(*pid) {
            out.insert((role.clone(), tid), value);
        }
    }
    out
}

/// The busiest threads between two samples, as CPU % of `seconds`, with
/// their wakes in the window.
fn busiest(
    before: &HashMap<(String, u32), (String, u64, u64)>,
    after: &HashMap<(String, u32), (String, u64, u64)>,
    seconds: f64,
) -> Vec<Value> {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
    let mut rows: Vec<(f64, u64, String, String)> = after
        .iter()
        .map(|((role, tid), (name, ticks, wakes))| {
            let (start, start_wakes) =
                before.get(&(role.clone(), *tid)).map_or((0, 0), |(_, t, w)| (*t, *w));
            let pct = (ticks.saturating_sub(start)) as f64 / hz / seconds * 100.0;
            (pct, wakes.saturating_sub(start_wakes), role.clone(), format!("{name}#{tid}"))
        })
        .filter(|(pct, wakes, _, _)| *pct >= 1.0 || *wakes >= 1000)
        .collect();
    rows.sort_by(|a, b| b.0.total_cmp(&a.0));
    rows.into_iter()
        .take(10)
        .map(|(pct, wakes, role, name)| {
            json!({"process": role, "thread": name, "cpu_pct": (pct * 10.0).round() / 10.0, "wakes": wakes})
        })
        .collect()
}

/// Each process's CPU % of `seconds`, summed over its threads (100 = one core).
fn process_cpu(
    before: &HashMap<(String, u32), (String, u64, u64)>,
    after: &HashMap<(String, u32), (String, u64, u64)>,
    seconds: f64,
) -> Value {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
    let mut totals: HashMap<String, f64> = HashMap::new();
    for ((role, tid), (_, ticks, _)) in after {
        let start = before.get(&(role.clone(), *tid)).map_or(0, |(_, t, _)| *t);
        *totals.entry(role.clone()).or_default() +=
            ticks.saturating_sub(start) as f64 / hz / seconds * 100.0;
    }
    totals.into_iter().map(|(role, pct)| (role, json!((pct * 10.0).round() / 10.0))).collect()
}

/// How the viewer attaches and reads its output.
#[derive(Clone, Copy, PartialEq)]
enum ViewerMode {
    /// A plain byte attach: `vt-state`, then `output` lines, base64 decoded.
    Bytes,
    /// The Mac app's attach: `set-client-info`, a snapshot attach (READY), `output` lines.
    Snapshot,
    /// The snapshot attach of a connection that declared `attach-frames-v1`: OUTPUT frames.
    Frames,
}

/// One attach, read as a terminal view reads it: every `output` event's
/// base64 decoded, or every OUTPUT frame's payload taken as is.
struct Viewer {
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<ViewerStats>>,
    handle: Option<std::thread::JoinHandle<()>>,
    _writer: Box<dyn transport::Stream>,
}

#[derive(Default, Clone)]
struct ViewerStats {
    attached: bool,
    outputs: u64,
    output_bytes: u64,
    replays: u64,
    /// OUTPUT frames whose offset was not the end of the one before.
    frame_gaps: u64,
    other: HashMap<String, u64>,
    last_output: Option<Instant>,
    first_output: Option<Instant>,
    /// The viewer thread's CPU seconds at its first and its last output.
    cpu_first_output: Option<f64>,
    cpu_last_output: f64,
    /// Seconds spent scanning lines and decoding `output` data.
    decode_seconds: f64,
    /// Socket reads that returned bytes (each one wake of the viewer).
    reads: u64,
    /// Each resync the viewer saw (a READY, a `vt-state`, a `resized`): when, what, and for a frames
    /// viewer the stream bytes it skipped (the READY's offset past the end of the last frame).
    marks: Vec<(Instant, &'static str, Option<u64>)>,
    /// A frames viewer's stream position after its last frame or READY.
    end_offset: Option<u64>,
}

impl Viewer {
    fn attach(socket: &Path, surface: u64, mode: ViewerMode) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        // The replies the viewer waits for before it counts as attached.
        let mut replies_needed = 1;
        if mode == ViewerMode::Bytes {
            writeln!(writer, "{}", json!({"id": 1, "cmd": "attach-surface", "surface": surface}))
                .unwrap();
        } else {
            let capabilities: &[&str] =
                if mode == ViewerMode::Frames { &["attach-frames-v1"] } else { &[] };
            writeln!(
                writer,
                "{}",
                json!({"id": 0, "cmd": "set-client-info", "name": "throughput viewer",
                       "kind": "frontend", "capabilities": capabilities})
            )
            .unwrap();
            writeln!(
                writer,
                "{}",
                json!({"id": 1, "cmd": "attach-surface", "surface": surface, "mode": "bytes",
                       "cols": 120, "rows": 40, "snapshot": "ghostsnp",
                       "snapshot_version": ghostty_vt::snapshot_version(),
                       "snapshot_local_history": true})
            )
            .unwrap();
            replies_needed = 2;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let stats = Arc::new(Mutex::new(ViewerStats::default()));
        let handle = {
            let (stop, stats) = (stop.clone(), stats.clone());
            let mut stream = stream;
            std::thread::spawn(move || {
                let mut pending: Vec<u8> = Vec::new();
                let mut buf = vec![0u8; 1 << 16];
                let engine = base64::engine::general_purpose::STANDARD;
                let mut decoded = Vec::new();
                let mut replies = 0;
                let mut next_offset: Option<u64> = None;
                while !stop.load(Ordering::Relaxed) {
                    let n = match stream.read(&mut buf) {
                        Ok(0) => return,
                        Ok(n) => {
                            stats.lock().unwrap().reads += 1;
                            n
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) =>
                        {
                            continue;
                        }
                        Err(_) => return,
                    };
                    pending.extend_from_slice(&buf[..n]);
                    let mut start = 0;
                    let decode_started = Instant::now();
                    let mut got = stats.lock().unwrap();
                    let outputs_before = got.outputs;
                    loop {
                        if pending.get(start) == Some(&0xFF) {
                            // An OUTPUT frame: u8 0xFF, u8 kind, u16 stream, u32 len, u64 offset.
                            let Some(header) = pending.get(start..start + 16) else { break };
                            let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
                            let offset = u64::from_le_bytes(header[8..16].try_into().unwrap());
                            if pending.len() < start + 16 + len {
                                break;
                            }
                            if next_offset.is_some_and(|expected| expected != offset) {
                                got.frame_gaps += 1;
                            }
                            next_offset = Some(offset + len as u64);
                            got.end_offset = next_offset;
                            start += 16 + len;
                            got.outputs += 1;
                            got.output_bytes += len as u64;
                            got.last_output = Some(Instant::now());
                            continue;
                        }
                        let Some(offset) = pending[start..].iter().position(|b| *b == b'\n') else {
                            break;
                        };
                        let line = &pending[start..start + offset];
                        start += offset + 1;
                        let text = std::str::from_utf8(line).unwrap_or("");
                        let event = field(text, "event").unwrap_or("");
                        match event {
                            "output" => {
                                decoded.clear();
                                if let Some(data) = field(text, "data") {
                                    let _ = engine.decode_vec(data, &mut decoded);
                                }
                                got.outputs += 1;
                                got.output_bytes += decoded.len() as u64;
                                got.last_output = Some(Instant::now());
                            }
                            "vt-state" => {
                                got.replays += 1;
                                got.marks.push((Instant::now(), "vt-state", None));
                            }
                            "snapshot" if text.contains("\"phase\":\"ready\"") => {
                                got.replays += 1;
                                let ready_at = number_field(text, "offset");
                                let skipped = next_offset
                                    .zip(ready_at)
                                    .map(|(end, ready)| ready.saturating_sub(end));
                                got.marks.push((Instant::now(), "ready", skipped));
                                if ready_at.is_some() {
                                    got.end_offset = ready_at;
                                }
                                // The next frame starts at the READY's offset.
                                next_offset = None;
                            }
                            "resized" => {
                                *got.other.entry("resized".to_string()).or_default() += 1;
                                got.marks.push((Instant::now(), "resized", None));
                            }
                            "" if text.contains("\"ok\":true") => {
                                replies += 1;
                                got.attached = replies >= replies_needed;
                            }
                            other => *got.other.entry(other.to_string()).or_default() += 1,
                        }
                    }
                    got.decode_seconds += decode_started.elapsed().as_secs_f64();
                    if got.outputs > outputs_before {
                        let cpu = thread_cpu_seconds();
                        got.cpu_first_output.get_or_insert(cpu);
                        got.first_output.get_or_insert_with(Instant::now);
                        got.cpu_last_output = cpu;
                    }
                    drop(got);
                    pending.drain(..start);
                }
            })
        };
        Self { stop, stats, handle: Some(handle), _writer: writer }
    }

    fn stats(&self) -> ViewerStats {
        self.stats.lock().unwrap().clone()
    }

    fn finish(mut self) -> ViewerStats {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        self.stats()
    }
}

/// CPU seconds the calling thread has used.
fn thread_cpu_seconds() -> f64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid timespec for clock_gettime to fill.
    let status = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut now) };
    assert_eq!(status, 0, "clock_gettime: {}", std::io::Error::last_os_error());
    now.tv_sec as f64 + now.tv_nsec as f64 / 1e9
}

/// The number value of `"key":N` in a JSON line (the first such key).
fn number_field(line: &str, key: &str) -> Option<u64> {
    let pattern = format!("\"{key}\":");
    let at = line.find(&pattern)? + pattern.len();
    let digits: String = line[at..].chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// The string value of `"key":"..."` in a JSON line with no escapes in it.
fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let pattern = format!("\"{key}\":\"");
    let at = line.find(&pattern)? + pattern.len();
    let end = line[at..].find('"')?;
    Some(&line[at..at + end])
}

fn wait_file(path: &Path, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Ok(bytes) = fs::read(path) {
            return serde_json::from_slice(&bytes).ok();
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    None
}

/// One burst of `payload_path` through a terminal of `daemon`: (writer MB/s,
/// busiest threads, viewer stats).
fn burst(
    daemon: &Daemon,
    scripts: &Path,
    payload_path: &Path,
    label: &str,
    viewer: Option<ViewerMode>,
) -> Value {
    let result = scripts.join(format!("{label}.json"));
    let go = scripts.join(format!("{label}.go"));
    let created = daemon.request(json!({
        "id": 2, "cmd": "run", "new_workspace": true, "name": label,
        "argv": ["python3", "-I", scripts.join("writer.py"), payload_path, &result, &go],
    }));
    let surface = created["surface"]
        .as_u64()
        .or_else(|| created["surface_id"].as_u64())
        .unwrap_or_else(|| panic!("run reply names no surface: {created}"));
    let attached = viewer.map(|mode| Viewer::attach(&daemon.socket, surface, mode));
    if let Some(attached) = &attached {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !attached.stats().attached {
            assert!(Instant::now() < deadline, "{label}: the viewer never attached");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    // The host process appears once the terminal exists.
    std::thread::sleep(Duration::from_millis(300));
    let mut pids = vec![("daemon".to_string(), daemon.child.id())];
    pids.extend(daemon.host_pids().into_iter().map(|pid| ("host".to_string(), pid)));
    let before = sample(&pids);
    let (snapshots_stop, snapshots) = count_snapshots(daemon.state.clone());
    let started = Instant::now();
    fs::write(&go, b"go").unwrap();
    let res = wait_file(&result, Duration::from_secs(600))
        .unwrap_or_else(|| panic!("{label}: the writer gave no result"));
    let wall = started.elapsed().as_secs_f64();
    snapshots_stop.store(true, Ordering::Release);
    let snapshots_written = snapshots.join().unwrap_or(0);
    let after = sample(&pids);
    let bytes = res["bytes"].as_u64().unwrap_or(0) as usize;
    let seconds = res["seconds"].as_f64().unwrap_or(0.0);
    let mut row = json!({
        "stage": label, "bytes": bytes, "seconds": seconds, "mb_s": mb_s(bytes, seconds),
        "threads": busiest(&before, &after, wall),
        "snapshots_written": snapshots_written,
        "snapshots_per_s": (snapshots_written as f64 / wall * 10.0).round() / 10.0,
        "cpus": std::thread::available_parallelism().map_or(0, |n| n.get()),
        "process_cpu_pct": process_cpu(&before, &after, wall),
    });
    if let Some(attached) = attached {
        // The viewer's tail: wait until it has every payload byte, or no output
        // for 5 s. A shorter quiet wait ended the row inside a daemon pause (a
        // resize's reflow), so bytes still on their way read as never sent.
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let stats = attached.stats();
            let whole = stats.output_bytes >= bytes as u64;
            let quiet = stats.last_output.is_none_or(|at| at.elapsed() > Duration::from_secs(5));
            if whole || quiet || Instant::now() > deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let viewed = started.elapsed().as_secs_f64();
        let stats = attached.finish();
        // Timed to the last output: the quiet wait above is not the viewer's.
        let to_last =
            stats.last_output.map_or(viewed, |at| at.duration_since(started).as_secs_f64());
        // The viewer's CPU and decode time over its own window, first output to last.
        let busy = (stats.cpu_last_output - stats.cpu_first_output.unwrap_or(0.0)).max(0.0);
        let window = match (stats.first_output, stats.last_output) {
            (Some(first), Some(last)) => last.duration_since(first).as_secs_f64().max(1e-6),
            _ => to_last,
        };
        row["viewer"] = json!({
            "outputs": stats.outputs, "output_bytes": stats.output_bytes,
            "bytes_per_output": stats.output_bytes.checked_div(stats.outputs).unwrap_or(0),
            "replays": stats.replays, "other_events": stats.other,
            "frame_gaps": stats.frame_gaps,
            "reads": stats.reads,
            "bytes_per_read": stats.output_bytes.checked_div(stats.reads).unwrap_or(0),
            "overflows": stats.other.get("overflow").copied().unwrap_or(0),
            "seconds_to_last_output": to_last, "mb_s_to_last_output": mb_s(stats.output_bytes as usize, to_last),
            "viewer_cpu_pct": (busy / window * 1000.0).round() / 10.0,
            "decode_pct": (stats.decode_seconds / window * 1000.0).round() / 10.0,
            // Resyncs in time order, ms after the writer's go (negative: while attaching).
            "marks": stats.marks.iter().map(|(at, kind, skipped)| {
                let ms = if *at >= started {
                    at.duration_since(started).as_secs_f64() * 1e3
                } else {
                    -(started.duration_since(*at).as_secs_f64() * 1e3)
                };
                json!({"ms": ms.round(), "kind": kind, "skipped_bytes": skipped})
            }).collect::<Vec<_>>(),
            "end_offset": stats.end_offset,
        });
    }
    // Best effort: the next burst runs in its own terminal either way.
    if let Ok(stream) = transport::connect(&daemon.socket) {
        let mut writer = stream.try_clone_box().unwrap();
        let _ =
            writeln!(writer, "{}", json!({"id": 3, "cmd": "close-surface", "surface": surface}));
        let mut line = String::new();
        let _ = BufReader::new(stream).read_line(&mut line);
    }
    row
}

/// The kernel PTY alone: the same writer on a PTY whose master one thread
/// reads into a 64 KiB buffer and drops. No terminal reads faster than this.
fn pty_only(scripts: &Path, payload_path: &Path, label: &str) -> Value {
    use std::os::fd::{FromRawFd, OwnedFd};
    let (mut master, mut slave) = (0, 0);
    // SAFETY: openpty writes two descriptors into the given ints; the other
    // arguments may be null.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    assert_eq!(opened, 0, "openpty: {}", std::io::Error::last_os_error());
    // SAFETY: openpty returned these descriptors and nothing else owns them.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    let result = scripts.join(format!("{label}.json"));
    let go = scripts.join(format!("{label}.go"));
    let mut writer = Command::new("python3")
        .args(["-I"])
        .arg(scripts.join("writer.py"))
        .arg(payload_path)
        .arg(&result)
        .arg(&go)
        .stdin(Stdio::null())
        .stdout(Stdio::from(slave.try_clone().unwrap()))
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    drop(slave);
    let mut master = fs::File::from(master);
    let reader = std::thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        // Ends with EIO once the writer exits and its side closes.
        while matches!(master.read(&mut buf), Ok(n) if n > 0) {}
    });
    fs::write(&go, b"go").unwrap();
    let res = wait_file(&result, Duration::from_secs(600))
        .unwrap_or_else(|| panic!("{label}: the writer gave no result"));
    let _ = writer.wait();
    let _ = reader.join();
    let bytes = res["bytes"].as_u64().unwrap_or(0) as usize;
    let seconds = res["seconds"].as_f64().unwrap_or(0.0);
    json!({"stage": label, "bytes": bytes, "seconds": seconds, "mb_s": mb_s(bytes, seconds)})
}

#[test]
#[ignore = "a throughput bench; run with --ignored --nocapture"]
fn terminal_throughput_by_stage() {
    let mb: usize = std::env::var("CMUX_THROUGHPUT_MB")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|v| *v > 0)
        .unwrap_or(200);
    // `CMUX_THROUGHPUT_RUNS`: measured bursts per daemon stage (default 1), one daemon.
    let runs: usize = std::env::var("CMUX_THROUGHPUT_RUNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|v| *v > 0)
        .unwrap_or(1);
    let pick: Option<Vec<String>> = std::env::var("CMUX_THROUGHPUT_STAGES")
        .ok()
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect());
    let wants = |name: &str| pick.as_ref().is_none_or(|p| p.iter().any(|s| s == name));
    let bytes = mb * 1_000_000;
    let data = payload(bytes);

    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let scripts =
        PathBuf::from("/tmp").join(format!("cmux-throughput-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&scripts).unwrap();
    fs::write(scripts.join("writer.py"), WRITER).unwrap();
    let payload_path = scripts.join("payload.txt");
    fs::write(&payload_path, &data).unwrap();
    // A warm-up of 16 MB per daemon, as the Mac bench does.
    let warm_path = scripts.join("warmup.txt");
    fs::write(&warm_path, &data[..data.len().min(16_000_000)]).unwrap();

    let mut rows = Vec::new();
    if wants("parse") {
        // The PTY's line discipline turns `\n` into `\r\n` before a terminal reads it.
        let mut cooked = Vec::with_capacity(data.len() + data.len() / 40);
        for &b in &data {
            if b == b'\n' {
                cooked.push(b'\r');
            }
            cooked.push(b);
        }
        for chunk in [1024, 4096, 65536] {
            let row = parse_stage(&cooked, chunk);
            eprintln!("TERMINAL-THROUGHPUT-STAGE {row}");
            rows.push(row);
        }
    }
    if wants("pty-only") {
        let _ = pty_only(&scripts, &warm_path, "pty-only-warmup");
        let row = pty_only(&scripts, &payload_path, "pty-only");
        eprintln!("TERMINAL-THROUGHPUT-STAGE {row}");
        rows.push(row);
    }
    for (stage, hosted, viewer) in [
        ("daemon-hosted", true, None),
        ("daemon-hosted+viewer", true, Some(ViewerMode::Bytes)),
        ("daemon-hosted+viewer-snapshot", true, Some(ViewerMode::Snapshot)),
        ("daemon-hosted+viewer-frames", true, Some(ViewerMode::Frames)),
        ("daemon-ephemeral", false, None),
        ("daemon-ephemeral+viewer", false, Some(ViewerMode::Bytes)),
    ] {
        if !wants(stage) {
            continue;
        }
        let daemon = Daemon::start(stage.replace('+', "-").as_str(), hosted);
        let _ = burst(
            &daemon,
            &scripts,
            &warm_path,
            &format!("{}-warmup", stage.replace('+', "-")),
            viewer,
        );
        for run in 0..runs {
            let label = format!("{}-{run}", stage.replace('+', "-"));
            let mut row = burst(&daemon, &scripts, &payload_path, &label, viewer);
            row["stage"] = json!(stage);
            row["run"] = json!(run);
            eprintln!("TERMINAL-THROUGHPUT-STAGE {row}");
            rows.push(row);
        }
    }
    let _ = fs::remove_dir_all(&scripts);

    let mut table = format!(
        "Terminal throughput by stage, {mb} MB (cmux-tui tests/terminal_throughput_stages.rs)\n\n\
         | Stage | MB/s | Busiest threads (CPU % of the burst) | Viewer |\n| --- | --- | --- | --- |\n"
    );
    for row in &rows {
        let threads: Vec<String> = row["threads"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| {
                format!(
                    "{}:{} {} ({} wakes)",
                    t["process"].as_str().unwrap_or(""),
                    t["thread"].as_str().unwrap_or(""),
                    t["cpu_pct"],
                    t["wakes"]
                )
            })
            .collect();
        let viewer = row.get("viewer").map_or(String::new(), |v| {
            format!(
                "{:.1} MB in {} outputs, {} B each, {} reads ({} B each), {} replays, {:.1} MB/s to last output, viewer {} % CPU ({} % decoding), {} overflows, {} frame gaps, events {}",
                v["output_bytes"].as_f64().unwrap_or(0.0) / 1e6,
                v["outputs"],
                v["bytes_per_output"],
                v["reads"],
                v["bytes_per_read"],
                v["replays"],
                v["mb_s_to_last_output"].as_f64().unwrap_or(0.0),
                v["viewer_cpu_pct"],
                v["decode_pct"],
                v["overflows"],
                v["frame_gaps"],
                v["other_events"]
            )
        });
        table.push_str(&format!(
            "| {} | {:.1} | {} | {} |\n",
            row["stage"].as_str().unwrap_or(""),
            row["mb_s"].as_f64().unwrap_or(0.0),
            threads.join(", "),
            viewer
        ));
    }
    println!("{table}");
    if let Some(dir) = std::env::var_os("FAST_CHECKS_OUT") {
        let path = Path::new(&dir).join("terminal-throughput-stages.json");
        fs::write(&path, serde_json::to_vec_pretty(&json!({"mb": mb, "rows": rows})).unwrap())
            .unwrap();
        fs::write(path.with_extension("md"), &table).unwrap();
    }
}
