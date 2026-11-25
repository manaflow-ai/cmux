//! Bytes attach against render attach, on one real daemon surface: what each
//! mode puts on the wire and costs the client for the same terminal work.
//!
//! The iPhone app attaches every open terminal in bytes mode (`attach-surface`,
//! the `vt-state` replay, then `output` events of base64 PTY bytes) and runs a
//! Ghostty parser of its own on them. Render mode (protocol 7, spec/render.md)
//! sends one `render-state`, then `render-delta` frames of the dirty viewport
//! rows, at most one per server render frame. This bench runs a real PTY
//! surface of 200 x 50 cells, attaches it in both modes at once on two socket
//! connections, drives one workload, and reports per mode:
//!
//! - wire bytes per second: the JSON lines as the daemon sent them. The
//!   phone's `daemon` link channel carries these lines uncompressed;
//! - the same lines through one deflate stream (fast level, a sync flush per
//!   message, the window kept between messages: what permessage-deflate on
//!   the link would make of them);
//! - events per second, a proxy for the phone's wakeups;
//! - the client's apply cost in CPU ms per second of workload. Bytes mode: the
//!   JSON line parsed, base64 decoded and fed to ghostty-vt, with a render
//!   state update at most 60 times a second, as the phone's renderer reads it.
//!   Render mode: the JSON line parsed and its rows put into a row array.
//!   Neither includes drawing, which both modes do;
//! - the attach's first message (`vt-state` or `render-state`) in KB.
//!
//! A third connection attaches in bytes mode after declaring
//! `attach-output-coalesce-v1` (mode `bytes-coalesced`): `output` at most
//! once per 60 Hz frame, the first bytes after idle at once. The
//! `keypress-echo` workload also reports key-to-echo latency for both bytes
//! attaches.
//!
//! Workloads (`CMUX_ATTACH_BENCH_WORKLOADS=a,b` picks some): an idle shell
//! for 60 s, `yes`, a build log at 200 lines a second, a full-screen TUI that
//! repaints every row 30 times a second, the same TUI drawing only its changed
//! rows, and a line every 2 s. `CMUX_ATTACH_BENCH_SECONDS` sets the length of
//! every workload but the idle one (default 20).
//!
//! Run on the fleet (ignored in the normal test run):
//! `cargo test -p cmux-tui-core --test attach_mode_bench -- --ignored --nocapture`.
//! With `FAST_CHECKS_OUT` set it also writes `attach-mode-bench.json` there.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

mod support;
use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, Surface, SurfaceOptions};
use flate2::Compression;
use flate2::write::DeflateEncoder;
use ghostty_vt::{Callbacks, RenderState, Terminal};
use serde_json::{Value, json};
use support::{DaemonMuxOps, wait_for};

const COLS: u16 = 200;
const ROWS: u16 = 50;
/// Lines kept per mode for the apply and deflate measurements; the rest of a
/// flood is only counted, and its cost scaled from the kept part.
const SAMPLE_CAP: usize = 64 << 20;
/// The phone's renderer reads the terminal at most once per display frame.
const RENDER_UPDATE_EVERY: Duration = Duration::from_micros(16_667);

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// What one attach connection received.
#[derive(Default)]
struct Received {
    /// The first event (`vt-state` or `render-state`), whole.
    initial: Option<String>,
    /// Every later line: arrival time and length (with its newline).
    lines: Vec<(Instant, usize)>,
    /// Event names of `lines`, in the same order (`""` for a response).
    names: Vec<String>,
    /// The lines themselves, up to `SAMPLE_CAP` bytes.
    sample: Vec<(Instant, String)>,
    sample_bytes: usize,
    attached: bool,
}

struct Reader {
    received: Arc<Mutex<Received>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    _writer: Box<dyn transport::Stream>,
}

impl Reader {
    /// Connect to the daemon and attach `surface` in `mode`; a thread reads
    /// every line from then on. `coalesce` declares
    /// `attach-output-coalesce-v1` first (the phone's opt-in).
    fn attach(sock: &std::path::Path, surface: u64, mode: &str, coalesce: bool) -> Self {
        let stream = transport::connect(sock).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        if coalesce {
            writeln!(
                writer,
                "{}",
                json!({"id": 0, "cmd": "set-client-info", "name": "attach bench",
                       "capabilities": ["attach-output-coalesce-v1"]})
            )
            .unwrap();
        }
        writeln!(
            writer,
            "{}",
            json!({"id": 1, "cmd": "attach-surface", "surface": surface, "mode": mode})
        )
        .unwrap();
        let received = Arc::new(Mutex::new(Received::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let handle = {
            let received = received.clone();
            let stop = stop.clone();
            let mut stream = stream;
            std::thread::spawn(move || {
                let mut pending: Vec<u8> = Vec::new();
                let mut buf = vec![0u8; 1 << 16];
                while !stop.load(Ordering::Relaxed) {
                    let n = match stream.read(&mut buf) {
                        Ok(0) => return,
                        Ok(n) => n,
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) =>
                        {
                            continue;
                        }
                        Err(error) => panic!("attach read failed: {error}"),
                    };
                    let now = Instant::now();
                    pending.extend_from_slice(&buf[..n]);
                    let mut start = 0;
                    let mut got = received.lock().unwrap();
                    while let Some(offset) = memchr_newline(&pending[start..]) {
                        let end = start + offset;
                        let line = String::from_utf8_lossy(&pending[start..end]).into_owned();
                        start = end + 1;
                        record(&mut got, now, line);
                    }
                    drop(got);
                    pending.drain(..start);
                }
            })
        };
        Self { received, stop, handle: Some(handle), _writer: writer }
    }

    fn attached(&self) -> bool {
        let got = self.received.lock().unwrap();
        got.attached && got.initial.is_some()
    }

    fn finish(mut self) -> Received {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            handle.join().unwrap();
        }
        std::mem::take(&mut *self.received.lock().unwrap())
    }
}

fn memchr_newline(bytes: &[u8]) -> Option<usize> {
    bytes.iter().position(|byte| *byte == b'\n')
}

/// The `event` name of a JSON line without parsing it: the reader keeps up
/// with a flood, and the full parse is the apply measurement's job.
fn event_name(line: &str) -> &str {
    const KEY: &str = "\"event\":\"";
    line.find(KEY)
        .map(|at| &line[at + KEY.len()..])
        .and_then(|rest| rest.find('"').map(|end| &rest[..end]))
        .unwrap_or_default()
}

fn record(got: &mut Received, now: Instant, line: String) {
    let event = event_name(&line).to_string();
    if got.initial.is_none() && (event == "vt-state" || event == "render-state") {
        got.initial = Some(line);
        return;
    }
    if !got.attached && event.is_empty() {
        let value: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        match value.get("id").and_then(Value::as_u64) {
            // The `set-client-info` reply of a coalescing attach.
            Some(0) => {
                assert_eq!(
                    value.get("ok"),
                    Some(&Value::Bool(true)),
                    "set-client-info failed: {line}"
                );
                return;
            }
            Some(_) => {
                assert_eq!(
                    value.get("ok"),
                    Some(&Value::Bool(true)),
                    "attach-surface failed: {line}"
                );
                got.attached = true;
                return;
            }
            None => {}
        }
    }
    got.lines.push((now, line.len() + 1));
    got.names.push(event);
    if got.sample_bytes < SAMPLE_CAP {
        got.sample_bytes += line.len() + 1;
        got.sample.push((now, line));
    }
}

/// What a workload drives once both attaches are up.
enum Drive {
    /// The surface's own program does the work (a shell, `yes`).
    Program,
    /// The surface runs `cat` in raw mode; the bench writes the output into
    /// it on a clock.
    Writer(fn(&Surface, Instant, Duration)),
}

struct Workload {
    name: &'static str,
    what: &'static str,
    script: &'static str,
    ready: Option<&'static str>,
    seconds: Option<u64>,
    drive: Drive,
}

const RAW_CAT: &str = "stty raw -echo; printf ready; exec cat";

fn workloads() -> Vec<Workload> {
    vec![
        Workload {
            name: "idle-shell",
            what: "an interactive sh at its prompt, 60 s",
            script: "PS1='$ '; export PS1; exec /bin/sh -i",
            ready: Some("$"),
            seconds: Some(60),
            drive: Drive::Program,
        },
        Workload {
            name: "yes-flood",
            what: "`yes` with a 60-character line, as fast as the PTY drains",
            script: "exec yes 'y: the quick brown fox jumps over the lazy dog 0123456789'",
            ready: None,
            seconds: None,
            drive: Drive::Program,
        },
        Workload {
            name: "build-log",
            what: "coloured compiler lines, 200 a second",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            drive: Drive::Writer(drive_build_log),
        },
        Workload {
            name: "tui-repaint",
            what: "a 200 x 50 TUI writing every row 30 times a second, 3 rows changing",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            drive: Drive::Writer(drive_tui_repaint),
        },
        Workload {
            name: "tui-diff",
            what: "the same TUI writing only its 3 changed rows, 30 times a second",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            drive: Drive::Writer(drive_tui_diff),
        },
        Workload {
            name: "slow-shell",
            what: "one line every 2 s",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            drive: Drive::Writer(drive_slow_shell),
        },
        Workload {
            name: "keypress-echo",
            what: "an interactive sh at its prompt, one key typed every 250 ms (echo latency)",
            script: "PS1='$ '; export PS1; exec /bin/sh -i",
            ready: Some("$"),
            seconds: None,
            drive: Drive::Writer(drive_keypresses),
        },
    ]
}

/// When each key of `keypress-echo` was written.
static KEYPRESSES: Mutex<Vec<Instant>> = Mutex::new(Vec::new());

fn drive_keypresses(surface: &Surface, start: Instant, length: Duration) {
    let period = Duration::from_millis(250);
    let mut n: u64 = 0;
    KEYPRESSES.lock().unwrap().clear();
    while start.elapsed() < length {
        KEYPRESSES.lock().unwrap().push(Instant::now());
        surface.write_bytes(b"x").unwrap();
        n += 1;
        tick(start, n, period);
    }
}

/// Key to the first `output` after it, per key: (p50, p95, max) ms and the
/// keys whose echo did not arrive before the next key.
fn echo_latency(got: &Received, keys: &[Instant]) -> (f64, f64, f64, usize) {
    let mut latencies: Vec<f64> = Vec::new();
    let mut missed = 0;
    for (index, key) in keys.iter().enumerate() {
        let next = keys.get(index + 1).copied();
        let echo = got
            .lines
            .iter()
            .zip(&got.names)
            .find(|((at, _), name)| *at >= *key && name.as_str() == "output")
            .map(|((at, _), _)| *at)
            .filter(|at| next.is_none_or(|next| *at < next));
        match echo {
            Some(at) => latencies.push(at.duration_since(*key).as_secs_f64() * 1000.0),
            None => missed += 1,
        }
    }
    latencies.sort_by(f64::total_cmp);
    let at = |q: f64| {
        if latencies.is_empty() {
            return 0.0;
        }
        let index = ((latencies.len() - 1) as f64 * q).round() as usize;
        latencies[index.min(latencies.len() - 1)]
    };
    (at(0.5), at(0.95), latencies.last().copied().unwrap_or(0.0), missed)
}

/// Sleep until `start + n * period`.
fn tick(start: Instant, n: u64, period: Duration) {
    let at = start + period.saturating_mul(u32::try_from(n).unwrap_or(u32::MAX));
    let now = Instant::now();
    if at > now {
        std::thread::sleep(at - now);
    }
}

fn drive_build_log(surface: &Surface, start: Instant, length: Duration) {
    let period = Duration::from_millis(10);
    let mut n: u64 = 0;
    while start.elapsed() < length {
        let mut out = String::new();
        for k in 0..2 {
            let i = n * 2 + k;
            if i % 9 == 4 {
                out.push_str(&format!(
                    "\x1b[1;33mwarning\x1b[0m: unused variable `value_{i}` in crates/crate-{}/src/lib.rs:{}:{}\r\n",
                    i % 37,
                    i % 400,
                    i % 80
                ));
            } else {
                out.push_str(&format!(
                    "\x1b[1;32m   Compiling\x1b[0m crate-{} v0.{}.{} (/home/user/src/project/crates/crate-{})\r\n",
                    i % 37,
                    i % 40,
                    i % 7,
                    i % 37
                ));
            }
        }
        surface.write_bytes(out.as_bytes()).unwrap();
        n += 1;
        tick(start, n, period);
    }
}

/// Row `r` of the TUI's frame `frame`: a fixed body, with a counter on row 0,
/// a spinner on row 25 and a progress bar on row 49.
fn tui_row(r: u16, frame: u64) -> String {
    let width = usize::from(COLS);
    let text = match r {
        0 => format!(" cmux bench  frame {frame:>8}  {:>6.2}s", frame as f64 / 30.0),
        25 => format!(
            " {} working on task {}",
            ['|', '/', '-', '\\'][(frame % 4) as usize],
            frame / 30
        ),
        49 => {
            let done = (frame % 190) as usize;
            format!(" [{}{}]", "#".repeat(done), ".".repeat(190 - done))
        }
        _ => format!(
            " {r:>2} | src/module_{r}.rs  fn handler_{r}(request: &Request) -> Response {{ ... }}  // body line"
        ),
    };
    let mut text: String = text.chars().take(width).collect();
    let pad = width.saturating_sub(text.chars().count());
    text.push_str(&" ".repeat(pad));
    let colour = 31 + u32::from(r % 6);
    format!("\x1b[{};1H\x1b[{colour}m{}\x1b[0m{}", r + 1, &text[..4], &text[4..])
}

fn drive_tui(surface: &Surface, start: Instant, length: Duration, every_row: bool) {
    let period = Duration::from_micros(33_333);
    let mut frame: u64 = 0;
    surface.write_bytes(b"\x1b[?1049h\x1b[?25l\x1b[2J").unwrap();
    while start.elapsed() < length {
        let mut out = String::from("\x1b[?2026h");
        for r in 0..ROWS {
            if every_row || frame == 0 || matches!(r, 0 | 25 | 49) {
                out.push_str(&tui_row(r, frame));
            }
        }
        out.push_str("\x1b[?2026l");
        surface.write_bytes(out.as_bytes()).unwrap();
        frame += 1;
        tick(start, frame, period);
    }
}

fn drive_tui_repaint(surface: &Surface, start: Instant, length: Duration) {
    drive_tui(surface, start, length, true);
}

fn drive_tui_diff(surface: &Surface, start: Instant, length: Duration) {
    drive_tui(surface, start, length, false);
}

fn drive_slow_shell(surface: &Surface, start: Instant, length: Duration) {
    let period = Duration::from_secs(2);
    let mut n: u64 = 0;
    while start.elapsed() < length {
        surface
            .write_bytes(format!("$ make status\r\nbuild {n}: 3 targets up to date\r\n").as_bytes())
            .unwrap();
        n += 1;
        tick(start, n, period);
    }
}

/// One mode's numbers over the measured window.
struct Row {
    workload: &'static str,
    mode: &'static str,
    seconds: f64,
    wire_bytes: usize,
    deflate_ratio: f64,
    events: usize,
    by_event: Vec<(String, usize)>,
    apply_ms: f64,
    initial_bytes: usize,
    payload_bytes: usize,
}

impl Row {
    fn per_s(&self, n: f64) -> f64 {
        if self.seconds > 0.0 { n / self.seconds } else { 0.0 }
    }

    fn json(&self) -> Value {
        json!({
            "workload": self.workload,
            "mode": self.mode,
            "seconds": self.seconds,
            "wire_bytes": self.wire_bytes,
            "wire_kb_per_s": self.per_s(self.wire_bytes as f64) / 1000.0,
            "deflate_kb_per_s": self.per_s(self.wire_bytes as f64 * self.deflate_ratio) / 1000.0,
            "events_per_s": self.per_s(self.events as f64),
            "events": self.by_event.iter().map(|(name, n)| json!({"event": name, "count": n})).collect::<Vec<_>>(),
            "apply_ms_per_s": self.per_s(self.apply_ms),
            "initial_kb": self.initial_bytes as f64 / 1000.0,
            "terminal_payload_kb_per_s": self.per_s(self.payload_bytes as f64) / 1000.0,
        })
    }
}

/// The lines of `got` inside `[from, to)`: their wire bytes, events by name.
fn window(got: &Received, from: Instant, to: Instant) -> (usize, usize, Vec<(String, usize)>) {
    let mut bytes = 0;
    let mut events = 0;
    let mut names: Vec<(String, usize)> = Vec::new();
    for ((at, len), name) in got.lines.iter().zip(&got.names) {
        if *at < from || *at >= to {
            continue;
        }
        bytes += len;
        events += 1;
        match names.iter_mut().find(|(seen, _)| seen == name) {
            Some((_, n)) => *n += 1,
            None => names.push((name.clone(), 1)),
        }
    }
    (bytes, events, names)
}

fn in_window(
    got: &Received,
    from: Instant,
    to: Instant,
) -> impl Iterator<Item = &(Instant, String)> {
    got.sample.iter().filter(move |(at, _)| *at >= from && *at < to)
}

/// The deflate stream's size over the sampled window lines, as a fraction of
/// their size.
fn deflate_ratio(got: &Received, from: Instant, to: Instant) -> f64 {
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::fast());
    let mut raw = 0usize;
    for (_, line) in in_window(got, from, to) {
        encoder.write_all(line.as_bytes()).unwrap();
        encoder.write_all(b"\n").unwrap();
        encoder.flush().unwrap();
        raw += line.len() + 1;
    }
    let packed = encoder.finish().unwrap().len();
    if raw == 0 { 1.0 } else { packed as f64 / raw as f64 }
}

fn decode(value: &Value) -> Vec<u8> {
    let data = value.get("data").and_then(Value::as_str).unwrap_or_default();
    base64::engine::general_purpose::STANDARD.decode(data).unwrap()
}

/// Bytes mode on the phone: the replay, then every `output` parsed, decoded
/// and fed to Ghostty, the render state read at most once a display frame.
/// Returns the CPU ms of the window's lines and the PTY bytes they carried.
fn apply_bytes(got: &Received, from: Instant, to: Instant) -> (f64, usize) {
    let mut term = Terminal::new(COLS, ROWS, 10_000, Callbacks::default()).unwrap();
    let mut state = RenderState::new().unwrap();
    if let Some(initial) = &got.initial {
        let value: Value = serde_json::from_str(initial).unwrap();
        term.vt_write(&decode(&value));
        state.update(&mut term).unwrap();
    }
    let mut payload = 0usize;
    let mut last_update: Option<Instant> = None;
    let started = Instant::now();
    for (at, line) in in_window(got, from, to) {
        let value: Value = serde_json::from_str(line).unwrap();
        if value.get("event").and_then(Value::as_str) == Some("output") {
            let bytes = decode(&value);
            payload += bytes.len();
            term.vt_write(&bytes);
        }
        if last_update.is_none_or(|last| at.duration_since(last) >= RENDER_UPDATE_EVERY) {
            state.update(&mut term).unwrap();
            last_update = Some(*at);
        }
    }
    state.update(&mut term).unwrap();
    (started.elapsed().as_secs_f64() * 1000.0, payload)
}

/// One run of styled text, as a render client keeps it.
#[allow(dead_code)]
struct Run {
    text: String,
    fg: Option<String>,
    bg: Option<String>,
    attrs: u64,
}

fn apply_rows(grid: &mut Vec<Vec<Run>>, value: &Value) -> usize {
    if let Some(size) = value.get("size") {
        let rows = size.get("rows").and_then(Value::as_u64).unwrap_or(0) as usize;
        grid.resize_with(rows, Vec::new);
    }
    let mut text_bytes = 0;
    for row in value.get("rows").and_then(Value::as_array).into_iter().flatten() {
        let index = row.get("row").and_then(Value::as_u64).unwrap_or(0) as usize;
        let runs: Vec<Run> = row
            .get("runs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|run| Run {
                text: run.get("text").and_then(Value::as_str).unwrap_or_default().to_string(),
                fg: run.get("fg").and_then(Value::as_str).map(str::to_string),
                bg: run.get("bg").and_then(Value::as_str).map(str::to_string),
                attrs: run.get("attrs").and_then(Value::as_u64).unwrap_or(0),
            })
            .collect();
        text_bytes += runs.iter().map(|run| run.text.len()).sum::<usize>();
        if let Some(slot) = grid.get_mut(index) {
            *slot = runs;
        }
    }
    text_bytes
}

/// Render mode on a phone: every line parsed, its rows put into the row array.
fn apply_render(got: &Received, from: Instant, to: Instant) -> (f64, usize) {
    let mut grid: Vec<Vec<Run>> = Vec::new();
    grid.resize_with(usize::from(ROWS), Vec::new);
    if let Some(initial) = &got.initial {
        apply_rows(&mut grid, &serde_json::from_str(initial).unwrap());
    }
    let mut payload = 0usize;
    let started = Instant::now();
    for (_, line) in in_window(got, from, to) {
        let value: Value = serde_json::from_str(line).unwrap();
        if value.get("event").and_then(Value::as_str) == Some("render-delta") {
            payload += apply_rows(&mut grid, &value);
        }
    }
    (started.elapsed().as_secs_f64() * 1000.0, payload)
}

fn measure(
    workload: &'static str,
    mode: &'static str,
    got: &Received,
    from: Instant,
    to: Instant,
) -> Row {
    let (wire_bytes, events, by_event) = window(got, from, to);
    let (sample_ms, sample_payload) = if mode.starts_with("bytes") {
        apply_bytes(got, from, to)
    } else {
        apply_render(got, from, to)
    };
    let sampled: usize = in_window(got, from, to).map(|(_, line)| line.len() + 1).sum();
    // A flood past SAMPLE_CAP: scale the kept part's cost to every line.
    let scale = if sampled == 0 { 1.0 } else { wire_bytes as f64 / sampled as f64 };
    Row {
        workload,
        mode,
        seconds: to.duration_since(from).as_secs_f64(),
        wire_bytes,
        deflate_ratio: deflate_ratio(got, from, to),
        events,
        by_event,
        apply_ms: sample_ms * scale,
        initial_bytes: got.initial.as_ref().map_or(0, String::len),
        payload_bytes: (sample_payload as f64 * scale) as usize,
    }
}

/// Echo latency of one bytes attach on `keypress-echo`.
struct Echo {
    mode: &'static str,
    keys: usize,
    p50_ms: f64,
    p95_ms: f64,
    max_ms: f64,
    missed: usize,
}

fn run_workload(workload: &Workload, default_seconds: u64) -> (Vec<Row>, Vec<Echo>) {
    let seconds = workload.seconds.unwrap_or(default_seconds);
    let opts = SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), workload.script.to_string()]),
        ..Default::default()
    };
    let mux = Mux::new(unique_session("attach-bench"), opts);
    let surface = mux.new_workspace(None, Some((COLS, ROWS))).unwrap();
    if let Some(ready) = workload.ready {
        wait_for(
            || {
                surface
                    .with_terminal(|term| {
                        term.viewport_text().ok().filter(|text| text.contains(ready))
                    })
                    .flatten()
            },
            Duration::from_secs(10),
        )
        .unwrap_or_else(|| panic!("{}: no {ready:?} on the screen", workload.name));
    }
    let sock = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let bytes = Reader::attach(&sock, surface.id, "bytes", false);
    // The same bytes attach with `attach-output-coalesce-v1` (default interval).
    let coalesced = Reader::attach(&sock, surface.id, "bytes", true);
    let render = Reader::attach(&sock, surface.id, "render", false);
    wait_for(
        || (bytes.attached() && coalesced.attached() && render.attached()).then_some(()),
        Duration::from_secs(10),
    )
    .unwrap_or_else(|| panic!("{}: an attach got no state and response", workload.name));
    // Let the attach settle, then measure exactly `seconds`.
    std::thread::sleep(Duration::from_millis(500));
    let from = Instant::now();
    let length = Duration::from_secs(seconds);
    match workload.drive {
        Drive::Program => std::thread::sleep(length),
        Drive::Writer(drive) => drive(&surface, from, length),
    }
    let left = length.saturating_sub(from.elapsed());
    std::thread::sleep(left);
    let to = Instant::now();
    // Lines of the window still in flight.
    std::thread::sleep(Duration::from_millis(300));
    let bytes = bytes.finish();
    let coalesced = coalesced.finish();
    let render = render.finish();
    let _ = mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock);
    let mut echoes = Vec::new();
    if workload.name == "keypress-echo" {
        let keys = KEYPRESSES.lock().unwrap().clone();
        for (mode, got) in [("bytes", &bytes), ("bytes-coalesced", &coalesced)] {
            let (p50_ms, p95_ms, max_ms, missed) = echo_latency(got, &keys);
            echoes.push(Echo { mode, keys: keys.len(), p50_ms, p95_ms, max_ms, missed });
        }
    }
    let rows = vec![
        measure(workload.name, "bytes", &bytes, from, to),
        measure(workload.name, "bytes-coalesced", &coalesced, from, to),
        measure(workload.name, "render", &render, from, to),
    ];
    (rows, echoes)
}

fn echo_table(echoes: &[Echo]) -> String {
    let mut out = String::from(
        "\nKeypress to echo (`keypress-echo`: first `output` after each key, as read)\n\n",
    );
    out.push_str("| Mode | Keys | p50 ms | p95 ms | max ms | No echo before next key |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- |\n");
    for echo in echoes {
        out.push_str(&format!(
            "| {} | {} | {:.2} | {:.2} | {:.2} | {} |\n",
            echo.mode, echo.keys, echo.p50_ms, echo.p95_ms, echo.max_ms, echo.missed
        ));
    }
    out
}

fn table(rows: &[Row], workloads: &[Workload]) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "Attach modes on one {COLS} x {ROWS} PTY surface of a real daemon (cmux-tui-core tests/attach_mode_bench.rs)\n\n"
    ));
    out.push_str("| Workload | Mode | s | Wire KB/s | Deflate KB/s | Events/s | Apply CPU ms/s | Attach KB | Events |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for row in rows {
        let events: Vec<String> = row
            .by_event
            .iter()
            .map(|(name, n)| format!("{} {n}", if name.is_empty() { "?" } else { name }))
            .collect();
        out.push_str(&format!(
            "| {} | {} | {:.0} | {:.1} | {:.1} | {:.1} | {:.2} | {:.1} | {} |\n",
            row.workload,
            row.mode,
            row.seconds,
            row.per_s(row.wire_bytes as f64) / 1000.0,
            row.per_s(row.wire_bytes as f64 * row.deflate_ratio) / 1000.0,
            row.per_s(row.events as f64),
            row.per_s(row.apply_ms),
            row.initial_bytes as f64 / 1000.0,
            events.join(", "),
        ));
    }
    out.push('\n');
    for workload in workloads {
        out.push_str(&format!("- {}: {}\n", workload.name, workload.what));
    }
    out
}

#[test]
#[ignore = "a bench of a minute or more; run with --ignored --nocapture"]
fn attach_modes_bytes_against_render() {
    let default_seconds = std::env::var("CMUX_ATTACH_BENCH_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .unwrap_or(20);
    let pick: Option<Vec<String>> = std::env::var("CMUX_ATTACH_BENCH_WORKLOADS")
        .ok()
        .map(|value| value.split(',').map(str::trim).map(str::to_string).collect());
    let chosen: Vec<Workload> = workloads()
        .into_iter()
        .filter(|workload| {
            pick.as_ref().is_none_or(|pick| pick.iter().any(|name| name == workload.name))
        })
        .collect();
    assert!(!chosen.is_empty(), "CMUX_ATTACH_BENCH_WORKLOADS names no workload");
    let mut rows = Vec::new();
    let mut echoes = Vec::new();
    for workload in &chosen {
        eprintln!("attach-mode-bench: {} ...", workload.name);
        let (workload_rows, workload_echoes) = run_workload(workload, default_seconds);
        rows.extend(workload_rows);
        echoes.extend(workload_echoes);
    }
    let mut text = table(&rows, &chosen);
    if !echoes.is_empty() {
        text.push_str(&echo_table(&echoes));
    }
    println!("{text}");
    if let Some(dir) = std::env::var_os("FAST_CHECKS_OUT") {
        let path = std::path::Path::new(&dir).join("attach-mode-bench.json");
        let doc = json!({"cols": COLS, "rows": ROWS, "runs": rows.iter().map(Row::json).collect::<Vec<_>>()});
        std::fs::write(&path, serde_json::to_vec_pretty(&doc).unwrap()).unwrap();
        std::fs::write(path.with_extension("md"), &text).unwrap();
    }
    for row in &rows {
        assert!(
            row.events > 0 || row.workload == "idle-shell",
            "{} {}: no events in the window",
            row.workload,
            row.mode
        );
    }
}
