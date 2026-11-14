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
    /// every line from then on.
    fn attach(sock: &std::path::Path, surface: u64, mode: &str) -> Self {
        let stream = transport::connect(sock).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
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
        if value.get("id").is_some() {
            assert_eq!(value["ok"], true, "attach-surface failed: {line}");
            got.attached = true;
            return;
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
    ]
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

fn in_window<'a>(
    got: &'a Received,
    from: Instant,
    to: Instant,
) -> impl Iterator<Item = &'a (Instant, String)> {
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
    let (sample_ms, sample_payload) =
        if mode == "bytes" { apply_bytes(got, from, to) } else { apply_render(got, from, to) };
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

fn run_workload(workload: &Workload, default_seconds: u64) -> Vec<Row> {
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
    let bytes = Reader::attach(&sock, surface.id, "bytes");
    let render = Reader::attach(&sock, surface.id, "render");
    wait_for(|| (bytes.attached() && render.attached()).then_some(()), Duration::from_secs(10))
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
    let render = render.finish();
    let _ = mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock);
    vec![
        measure(workload.name, "bytes", &bytes, from, to),
        measure(workload.name, "render", &render, from, to),
    ]
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
    for workload in &chosen {
        eprintln!("attach-mode-bench: {} ...", workload.name);
        rows.extend(run_workload(workload, default_seconds));
    }
    let text = table(&rows, &chosen);
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
