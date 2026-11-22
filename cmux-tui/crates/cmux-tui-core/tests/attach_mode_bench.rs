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
//! - per message: messages per second and the p50 and p95 line size in bytes.
//!
//! A third connection attaches in bytes mode after declaring
//! `attach-output-coalesce-v1` (mode `bytes-coalesced`): `output` at most
//! once per 60 Hz frame, the first bytes after idle at once. Two more attach
//! as a snapshot viewer (`snapshot:"ghostsnp"`, the Mac app's attach): mode
//! `snapshot` stays shown, mode `snapshot-hidden` sends
//! `set-attach-visibility {visible:false}` right after it attaches, the only
//! visibility the protocol has (bytes and render attaches have none). The
//! `keypress-echo` workload also reports key-to-echo latency for both bytes
//! attaches.
//!
//! Workloads (`CMUX_ATTACH_BENCH_WORKLOADS=a,b` picks some): an idle shell
//! for 60 s, `yes`, `yes | head -c 5000000` started once the attaches are up,
//! a build log at 200 lines a second, a full-screen TUI that repaints every
//! row 30 times a second (at 200 x 50 and at 80 x 24), the same TUI drawing
//! only its changed rows, a line every 2 s, and a shell prompt with one key a
//! second. `CMUX_ATTACH_BENCH_SECONDS` sets the length of every workload
//! without its own (default 20).
//!
//! Run on the fleet (ignored in the normal test run):
//! `cargo test -p cmux-tui-core --test attach_mode_bench -- --ignored --nocapture`.
//! It writes `attach-mode-bench.json` and `.md` to `CMUX_ATTACH_BENCH_OUT`,
//! else `FAST_CHECKS_OUT`, else the test target's temp dir, and prints the
//! JSON as one `attach-mode-bench-json:` line after the tables.

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
/// A phone-sized terminal.
const SMALL: (u16, u16) = (80, 24);
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
    /// A hidden snapshot viewer's `set-attach-visibility` was accepted.
    hidden: bool,
}

struct Reader {
    received: Arc<Mutex<Received>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    writer: Box<dyn transport::Stream>,
    surface: u64,
}

/// How one bench connection attaches.
#[derive(Clone, Copy, PartialEq)]
enum Attach {
    Bytes,
    BytesCoalesced,
    Render,
    Snapshot,
    SnapshotHidden,
}

impl Attach {
    const ALL: [Attach; 5] =
        [Self::Bytes, Self::BytesCoalesced, Self::Render, Self::Snapshot, Self::SnapshotHidden];

    fn name(self) -> &'static str {
        match self {
            Self::Bytes => "bytes",
            Self::BytesCoalesced => "bytes-coalesced",
            Self::Render => "render",
            Self::Snapshot => "snapshot",
            Self::SnapshotHidden => "snapshot-hidden",
        }
    }
}

impl Reader {
    /// Connect to the daemon and attach `surface` as `kind`; a thread reads
    /// every line from then on. `BytesCoalesced` declares
    /// `attach-output-coalesce-v1` first (the phone's opt-in).
    fn attach(sock: &std::path::Path, surface: u64, kind: Attach) -> Self {
        let capabilities: &[&str] =
            if kind == Attach::BytesCoalesced { &["attach-output-coalesce-v1"] } else { &[] };
        match kind {
            Attach::Render => Self::attach_with(sock, surface, "render", capabilities, json!({})),
            Attach::Snapshot | Attach::SnapshotHidden => Self::attach_with(
                sock,
                surface,
                "bytes",
                capabilities,
                json!({"snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version()}),
            ),
            Attach::Bytes | Attach::BytesCoalesced => {
                Self::attach_with(sock, surface, "bytes", capabilities, json!({}))
            }
        }
    }

    /// Connect, declare `capabilities` first (when any) and attach `surface`
    /// in `mode`, adding the `extra` fields to `attach-surface`.
    fn attach_with(
        sock: &std::path::Path,
        surface: u64,
        mode: &str,
        capabilities: &[&str],
        extra: Value,
    ) -> Self {
        let stream = transport::connect(sock).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        if !capabilities.is_empty() {
            writeln!(
                writer,
                "{}",
                json!({"id": 0, "cmd": "set-client-info", "name": "attach bench",
                       "capabilities": capabilities})
            )
            .unwrap();
        }
        let mut request =
            json!({"id": 1, "cmd": "attach-surface", "surface": surface, "mode": mode});
        for (key, value) in extra.as_object().into_iter().flatten() {
            request[key] = value.clone();
        }
        writeln!(writer, "{request}").unwrap();
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
        Self { received, stop, handle: Some(handle), writer, surface }
    }

    fn attached(&self) -> bool {
        let got = self.received.lock().unwrap();
        got.attached && got.initial.is_some()
    }

    /// Hide this snapshot viewer (`set-attach-visibility`, after it attached).
    fn hide(&mut self) {
        let request = json!({
            "id": 2, "cmd": "set-attach-visibility", "surface": self.surface, "visible": false,
        });
        writeln!(self.writer, "{request}").unwrap();
    }

    fn hidden(&self) -> bool {
        self.received.lock().unwrap().hidden
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
    if got.initial.is_none()
        && (event == "vt-state" || event == "render-state" || event == "snapshot")
    {
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
            Some(1) => {
                assert_eq!(
                    value.get("ok"),
                    Some(&Value::Bool(true)),
                    "attach-surface failed: {line}"
                );
                got.attached = true;
                return;
            }
            _ => {}
        }
    }
    // The `set-attach-visibility` reply of a hidden snapshot viewer.
    if event.is_empty() && line.starts_with('{') {
        let value: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        if value.get("id").and_then(Value::as_u64) == Some(2) {
            assert_eq!(
                value.get("ok"),
                Some(&Value::Bool(true)),
                "set-attach-visibility failed: {line}"
            );
            assert_eq!(value["data"]["viewers"], json!(1), "set-attach-visibility: {line}");
            got.hidden = true;
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
    Writer(fn(&Surface, Instant, Duration, (u16, u16))),
}

struct Workload {
    name: &'static str,
    what: &'static str,
    script: &'static str,
    ready: Option<&'static str>,
    seconds: Option<u64>,
    /// Columns and rows of the surface.
    size: (u16, u16),
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
            size: (COLS, ROWS),
            drive: Drive::Program,
        },
        Workload {
            name: "yes-flood",
            what: "`yes` with a 60-character line, as fast as the PTY drains",
            script: "exec yes 'y: the quick brown fox jumps over the lazy dog 0123456789'",
            ready: None,
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Program,
        },
        Workload {
            name: "build-log",
            what: "coloured compiler lines, 200 a second",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_build_log),
        },
        Workload {
            name: "tui-repaint",
            what: "a 200 x 50 TUI writing every row 30 times a second, 3 rows changing",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_tui_repaint),
        },
        Workload {
            name: "tui-diff",
            what: "the same TUI writing only its 3 changed rows, 30 times a second",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_tui_diff),
        },
        Workload {
            name: "slow-shell",
            what: "one line every 2 s",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_slow_shell),
        },
        Workload {
            name: "keypress-echo",
            what: "an interactive sh at its prompt, one key typed every 250 ms (echo latency)",
            script: "PS1='$ '; export PS1; exec /bin/sh -i",
            ready: Some("$"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_keypresses),
        },
        Workload {
            name: "yes-head-5m",
            what: "`yes | head -c 5000000` once, then quiet (10 s window: the bytes that show 5 MB of output)",
            script: "printf ready; read go; yes | head -c 5000000; exec sleep 3600",
            ready: Some("ready"),
            seconds: Some(10),
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_go),
        },
        Workload {
            name: "tui-repaint-80x24",
            what: "an 80 x 24 TUI writing every row 30 times a second, 3 rows changing",
            script: RAW_CAT,
            ready: Some("ready"),
            seconds: None,
            size: SMALL,
            drive: Drive::Writer(drive_tui_repaint),
        },
        Workload {
            name: "keypress-1hz",
            what: "an interactive sh at its prompt, one key typed a second",
            script: "PS1='$ '; export PS1; exec /bin/sh -i",
            ready: Some("$"),
            seconds: None,
            size: (COLS, ROWS),
            drive: Drive::Writer(drive_keypress_1hz),
        },
    ]
}

/// Start `yes-head-5m`'s flood: the line its `read` waits for.
fn drive_go(surface: &Surface, _start: Instant, _length: Duration, _size: (u16, u16)) {
    surface.write_bytes(b"\n").unwrap();
}

fn drive_keypress_1hz(surface: &Surface, start: Instant, length: Duration, _size: (u16, u16)) {
    let period = Duration::from_secs(1);
    let mut n: u64 = 0;
    while start.elapsed() < length {
        surface.write_bytes(b"x").unwrap();
        n += 1;
        tick(start, n, period);
    }
}

/// When each key of `keypress-echo` was written.
static KEYPRESSES: Mutex<Vec<Instant>> = Mutex::new(Vec::new());

fn drive_keypresses(surface: &Surface, start: Instant, length: Duration, _size: (u16, u16)) {
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

fn drive_build_log(surface: &Surface, start: Instant, length: Duration, _size: (u16, u16)) {
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

/// The TUI's changing rows on a `rows`-row screen: a counter on the first,
/// a spinner in the middle and a progress bar on the last.
fn tui_changing(rows: u16) -> [u16; 3] {
    [0, rows / 2, rows - 1]
}

/// Row `r` of the TUI's frame `frame` on a `(cols, rows)` screen: a fixed
/// body and the changing rows of `tui_changing`.
fn tui_row(r: u16, frame: u64, (cols, rows): (u16, u16)) -> String {
    let width = usize::from(cols);
    let [first, middle, last] = tui_changing(rows);
    let bar = width.saturating_sub(10);
    let text = match r {
        _ if r == first => {
            format!(" cmux bench  frame {frame:>8}  {:>6.2}s", frame as f64 / 30.0)
        }
        _ if r == middle => format!(
            " {} working on task {}",
            ['|', '/', '-', '\\'][(frame % 4) as usize],
            frame / 30
        ),
        _ if r == last => {
            let done = (frame % bar as u64) as usize;
            format!(" [{}{}]", "#".repeat(done), ".".repeat(bar - done))
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

fn drive_tui(
    surface: &Surface,
    start: Instant,
    length: Duration,
    size: (u16, u16),
    every_row: bool,
) {
    let period = Duration::from_micros(33_333);
    let mut frame: u64 = 0;
    surface.write_bytes(b"\x1b[?1049h\x1b[?25l\x1b[2J").unwrap();
    while start.elapsed() < length {
        let mut out = String::from("\x1b[?2026h");
        let changing = tui_changing(size.1);
        for r in 0..size.1 {
            if every_row || frame == 0 || changing.contains(&r) {
                out.push_str(&tui_row(r, frame, size));
            }
        }
        out.push_str("\x1b[?2026l");
        surface.write_bytes(out.as_bytes()).unwrap();
        frame += 1;
        tick(start, frame, period);
    }
}

fn drive_tui_repaint(surface: &Surface, start: Instant, length: Duration, size: (u16, u16)) {
    drive_tui(surface, start, length, size, true);
}

fn drive_tui_diff(surface: &Surface, start: Instant, length: Duration, size: (u16, u16)) {
    drive_tui(surface, start, length, size, false);
}

fn drive_slow_shell(surface: &Surface, start: Instant, length: Duration, _size: (u16, u16)) {
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
    /// p50 and p95 line size in the window, newline included.
    msg_p50: usize,
    msg_p95: usize,
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
            "messages_per_s": self.per_s(self.events as f64),
            "message_bytes_p50": self.msg_p50,
            "message_bytes_p95": self.msg_p95,
        })
    }
}

/// The p50 and p95 line sizes of `got` inside `[from, to)`.
fn size_quantiles(got: &Received, from: Instant, to: Instant) -> (usize, usize) {
    let mut sizes: Vec<usize> =
        got.lines.iter().filter(|(at, _)| *at >= from && *at < to).map(|(_, len)| *len).collect();
    if sizes.is_empty() {
        return (0, 0);
    }
    sizes.sort_unstable();
    let at = |q: f64| sizes[(((sizes.len() - 1) as f64) * q).round() as usize];
    (at(0.5), at(0.95))
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
    // `vt-state` and `output` carry `data`; a `resized` replay is `replay`.
    let data = value
        .get("data")
        .or_else(|| value.get("replay"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    base64::engine::general_purpose::STANDARD.decode(data).unwrap()
}

/// Bytes mode on the phone: the replay, then every `output` parsed, decoded
/// and fed to Ghostty, the render state read at most once a display frame.
/// Returns the CPU ms of the window's lines and the PTY bytes they carried.
/// A snapshot viewer starts from a blank terminal here, not a restored READY:
/// the window's cost is its `output`, the same parse as bytes mode.
fn apply_bytes(
    got: &Received,
    from: Instant,
    to: Instant,
    (cols, rows): (u16, u16),
) -> (f64, usize) {
    let mut term = Terminal::new(cols, rows, 10_000, Callbacks::default()).unwrap();
    let mut state = RenderState::new().unwrap();
    if let Some(initial) = &got.initial {
        let value: Value = serde_json::from_str(initial).unwrap();
        if value.get("event").and_then(Value::as_str) == Some("vt-state") {
            term.vt_write(&decode(&value));
        }
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
fn apply_render(got: &Received, from: Instant, to: Instant, rows: u16) -> (f64, usize) {
    let mut grid: Vec<Vec<Run>> = Vec::new();
    grid.resize_with(usize::from(rows), Vec::new);
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
    size: (u16, u16),
) -> Row {
    let (wire_bytes, events, by_event) = window(got, from, to);
    let (msg_p50, msg_p95) = size_quantiles(got, from, to);
    let (sample_ms, sample_payload) = if mode == "render" {
        apply_render(got, from, to, size.1)
    } else {
        apply_bytes(got, from, to, size)
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
        msg_p50,
        msg_p95,
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
    let surface = mux.new_workspace(None, Some(workload.size)).unwrap();
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
    let mut readers: Vec<(Attach, Reader)> =
        Attach::ALL.iter().map(|kind| (*kind, Reader::attach(&sock, surface.id, *kind))).collect();
    wait_for(
        || readers.iter().all(|(_, reader)| reader.attached()).then_some(()),
        Duration::from_secs(10),
    )
    .unwrap_or_else(|| panic!("{}: an attach got no state and response", workload.name));
    for (kind, reader) in &mut readers {
        if *kind == Attach::SnapshotHidden {
            reader.hide();
        }
    }
    wait_for(
        || {
            readers
                .iter()
                .all(|(kind, reader)| *kind != Attach::SnapshotHidden || reader.hidden())
                .then_some(())
        },
        Duration::from_secs(10),
    )
    .unwrap_or_else(|| panic!("{}: set-attach-visibility got no reply", workload.name));
    // Let the attach settle, then measure exactly `seconds`.
    std::thread::sleep(Duration::from_millis(500));
    let from = Instant::now();
    let length = Duration::from_secs(seconds);
    match workload.drive {
        Drive::Program => std::thread::sleep(length),
        Drive::Writer(drive) => drive(&surface, from, length, workload.size),
    }
    let left = length.saturating_sub(from.elapsed());
    std::thread::sleep(left);
    let to = Instant::now();
    // Lines of the window still in flight.
    std::thread::sleep(Duration::from_millis(300));
    let received: Vec<(Attach, Received)> =
        readers.into_iter().map(|(kind, reader)| (kind, reader.finish())).collect();
    let got = |want: Attach| &received.iter().find(|(kind, _)| *kind == want).unwrap().1;
    let _ = mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock);
    let mut echoes = Vec::new();
    if workload.name == "keypress-echo" {
        let keys = KEYPRESSES.lock().unwrap().clone();
        for kind in [Attach::Bytes, Attach::BytesCoalesced] {
            let mode = kind.name();
            let (p50_ms, p95_ms, max_ms, missed) = echo_latency(got(kind), &keys);
            echoes.push(Echo { mode, keys: keys.len(), p50_ms, p95_ms, max_ms, missed });
        }
    }
    let rows = received
        .iter()
        .map(|(kind, got)| measure(workload.name, kind.name(), got, from, to, workload.size))
        .collect();
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
        "Attach modes on one PTY surface of a real daemon, {COLS} x {ROWS} unless named (cmux-tui-core tests/attach_mode_bench.rs)\n\n"
    ));
    out.push_str("| Workload | Mode | s | Wire KB/s | Deflate KB/s | Msgs/s | Msg p50 B | Msg p95 B | Apply CPU ms/s | Attach KB | Events |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for row in rows {
        let events: Vec<String> = row
            .by_event
            .iter()
            .map(|(name, n)| format!("{} {n}", if name.is_empty() { "?" } else { name }))
            .collect();
        out.push_str(&format!(
            "| {} | {} | {:.0} | {:.1} | {:.1} | {:.1} | {} | {} | {:.2} | {:.1} | {} |\n",
            row.workload,
            row.mode,
            row.seconds,
            row.per_s(row.wire_bytes as f64) / 1000.0,
            row.per_s(row.wire_bytes as f64 * row.deflate_ratio) / 1000.0,
            row.per_s(row.events as f64),
            row.msg_p50,
            row.msg_p95,
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
    let sizes: Vec<Value> = chosen
        .iter()
        .map(|workload| {
            json!({"workload": workload.name, "cols": workload.size.0, "rows": workload.size.1})
        })
        .collect();
    let doc = json!({"sizes": sizes, "runs": rows.iter().map(Row::json).collect::<Vec<_>>()});
    println!("attach-mode-bench-json: {doc}");
    let dir = std::env::var_os("CMUX_ATTACH_BENCH_OUT")
        .or_else(|| std::env::var_os("FAST_CHECKS_OUT"))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("attach-mode-bench.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&doc).unwrap()).unwrap();
    std::fs::write(path.with_extension("md"), &text).unwrap();
    eprintln!("attach-mode-bench: wrote {}", path.display());
    for row in &rows {
        assert!(
            row.events > 0 || row.workload == "idle-shell",
            "{} {}: no events in the window",
            row.workload,
            row.mode
        );
    }
}

/// The resizes of `attach_resize_bench`: to a phone's portrait grid, back,
/// to a narrower Mac pane, back.
const RESIZE_STEPS: [(u16, u16); 4] = [(54, 26), (COLS, ROWS), (120, 40), (COLS, ROWS)];
/// How long each resize's lines are counted before the next resize.
const RESIZE_SETTLE: Duration = Duration::from_millis(750);

/// One attach's view of one resize.
struct ResizeRow {
    history: usize,
    step: String,
    mode: &'static str,
    wire_bytes: usize,
    events: usize,
    by_event: Vec<(String, usize)>,
    /// Command sent to the attach's first line after it.
    first_ms: Option<f64>,
    /// Command sent to the attach's last line inside the settle window.
    last_ms: Option<f64>,
    /// The `resize-surface` round trip on the control connection.
    command_ms: f64,
    /// The client's CPU ms to rebuild its screen from the step's lines.
    apply_ms: f64,
}

impl ResizeRow {
    fn json(&self) -> Value {
        json!({
            "history_lines": self.history,
            "step": self.step,
            "mode": self.mode,
            "wire_bytes": self.wire_bytes,
            "events": self.by_event.iter().map(|(name, n)| json!({"event": name, "count": n})).collect::<Vec<_>>(),
            "first_line_ms": self.first_ms,
            "last_line_ms": self.last_ms,
            "command_ms": self.command_ms,
            "apply_ms": self.apply_ms,
        })
    }
}

/// Send `request` (with `id`) on `stream`; its reply and round trip.
fn control_request(
    stream: &mut Box<dyn transport::Stream>,
    id: u64,
    mut request: Value,
) -> (Value, Duration) {
    request["id"] = json!(id);
    let started = Instant::now();
    writeln!(stream, "{request}").unwrap();
    let mut pending: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 1 << 16];
    while started.elapsed() < Duration::from_secs(10) {
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => panic!("control read failed: {error}"),
        };
        pending.extend_from_slice(&buf[..n]);
        while let Some(offset) = memchr_newline(&pending) {
            let line: Vec<u8> = pending.drain(..=offset).collect();
            let value: Value = serde_json::from_slice(&line).unwrap_or(Value::Null);
            if value.get("id").and_then(Value::as_u64) == Some(id) {
                return (value, started.elapsed());
            }
        }
    }
    panic!("no reply to {request}");
}

/// The client's cost of one resize. Bytes: each `resized` replay into a new
/// mirror of the new size (the spec's "replace the emulator"), the `output`
/// after it, one render state read. Render: each `render-delta` into the row
/// array.
fn apply_resize(got: &Received, mode: &str, from: Instant, to: Instant) -> f64 {
    let started = Instant::now();
    if mode.starts_with("bytes") {
        let mut mirror: Option<Terminal> = None;
        for (_, line) in in_window(got, from, to) {
            let value: Value = serde_json::from_str(line).unwrap();
            match value.get("event").and_then(Value::as_str) {
                Some("resized") => {
                    let cols = value.get("cols").and_then(Value::as_u64).unwrap_or(1) as u16;
                    let rows = value.get("rows").and_then(Value::as_u64).unwrap_or(1) as u16;
                    let mut term =
                        Terminal::new(cols, rows, 64 << 20, Callbacks::default()).unwrap();
                    term.vt_write(&decode(&value));
                    mirror = Some(term);
                }
                Some("output") => {
                    if let Some(term) = mirror.as_mut() {
                        term.vt_write(&decode(&value));
                    }
                }
                _ => {}
            }
        }
        if let Some(term) = mirror.as_mut() {
            RenderState::new().unwrap().update(term).unwrap();
        }
    } else {
        let mut grid: Vec<Vec<Run>> = Vec::new();
        for (_, line) in in_window(got, from, to) {
            let value: Value = serde_json::from_str(line).unwrap();
            if value.get("event").and_then(Value::as_str) == Some("render-delta") {
                apply_rows(&mut grid, &value);
            }
        }
    }
    started.elapsed().as_secs_f64() * 1000.0
}

/// A 200 x 50 surface holding `history` build-log lines behind its screen.
fn surface_with_history(history: usize) -> (Arc<Mux>, Arc<Surface>) {
    let opts = SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), RAW_CAT.to_string()]),
        scrollback: 256 << 20,
        ..Default::default()
    };
    let mux = Mux::new(unique_session("resize-bench"), opts);
    let surface = mux.new_workspace(None, Some((COLS, ROWS))).unwrap();
    let on_screen = |needle: String| {
        wait_for(
            || {
                surface
                    .with_terminal(|term| {
                        term.viewport_text().ok().filter(|text| text.contains(&needle))
                    })
                    .flatten()
            },
            Duration::from_secs(30),
        )
        .unwrap_or_else(|| panic!("resize bench: no {needle:?} on the screen"));
    };
    on_screen("ready".to_string());
    // The history, then a screen of it, in chunks the PTY drains between.
    let lines = history + usize::from(ROWS);
    let mut chunk = String::new();
    for i in 0..lines {
        chunk.push_str(&format!(
            "\x1b[1;32m{i:06}\x1b[0m compiling crate-{} v0.{}.{} (/home/user/src/project/crates/crate-{}) in {}ms\r\n",
            i % 37,
            i % 40,
            i % 7,
            i % 37,
            i % 4099
        ));
        if chunk.len() > 32 << 10 || i + 1 == lines {
            surface.write_bytes(chunk.as_bytes()).unwrap();
            chunk.clear();
            on_screen(format!("{i:06} compiling"));
        }
    }
    (mux, surface)
}

/// Bench of one resize (ignored; `--ignored --nocapture`). A 200 x 50 surface
/// of a real daemon holds a build log with N lines of history
/// (`CMUX_RESIZE_BENCH_HISTORY=0,2000,20000`, the default). Three socket
/// attaches watch it while a control connection resizes it to a phone's
/// portrait grid (54 x 26), back, to 120 x 40 and back:
///
/// - `bytes`: no history window, as the Mac app and phones from before
///   `attach-replay-history-window-v1` attach. Each resize sends the whole
///   history again;
/// - `bytes-phone`: the iPhone app today, `replay_history_rows: 0` with the
///   window capability declared;
/// - `render`: protocol 7 render mode.
///
/// Per attach and resize: wire bytes of the lines in the 750 ms after the
/// command, time to the first and last of them, the command's round trip,
/// and the client's CPU ms to rebuild its screen from them. With
/// `FAST_CHECKS_OUT` set it also writes `attach-resize-bench.json` and `.md`.
#[test]
#[ignore = "a bench of half a minute or more; run with --ignored --nocapture"]
fn attach_resize_bench() {
    let histories: Vec<usize> = std::env::var("CMUX_RESIZE_BENCH_HISTORY")
        .ok()
        .map(|value| value.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .unwrap_or_else(|| vec![0, 2_000, 20_000]);
    assert!(!histories.is_empty(), "CMUX_RESIZE_BENCH_HISTORY names no history length");
    let mut rows: Vec<ResizeRow> = Vec::new();
    for &history in &histories {
        eprintln!("attach-resize-bench: {history} lines of history ...");
        let (mux, surface) = surface_with_history(history);
        let sock = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
        let attaches = [
            ("bytes", Reader::attach_with(&sock, surface.id, "bytes", &[], json!({}))),
            (
                "bytes-phone",
                Reader::attach_with(
                    &sock,
                    surface.id,
                    "bytes",
                    &["attach-replay-history-window-v1"],
                    json!({"replay_history_rows": 0}),
                ),
            ),
            ("render", Reader::attach_with(&sock, surface.id, "render", &[], json!({}))),
        ];
        wait_for(
            || attaches.iter().all(|(_, reader)| reader.attached()).then_some(()),
            Duration::from_secs(30),
        )
        .unwrap_or_else(|| panic!("resize bench: an attach got no state and response"));
        std::thread::sleep(Duration::from_millis(500));
        let mut control = transport::connect(&sock).unwrap();
        control.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut steps: Vec<(String, Instant, f64)> = Vec::new();
        let mut size = (COLS, ROWS);
        for (index, (cols, rows)) in RESIZE_STEPS.into_iter().enumerate() {
            let sent = Instant::now();
            let (reply, took) = control_request(
                &mut control,
                10 + index as u64,
                json!({"cmd": "resize-surface", "surface": surface.id, "cols": cols, "rows": rows}),
            );
            assert_eq!(reply.get("ok"), Some(&Value::Bool(true)), "resize failed: {reply}");
            steps.push((
                format!("{}x{} -> {cols}x{rows}", size.0, size.1),
                sent,
                took.as_secs_f64() * 1000.0,
            ));
            size = (cols, rows);
            std::thread::sleep(RESIZE_SETTLE.saturating_sub(sent.elapsed()));
        }
        let received: Vec<(&'static str, Received)> =
            attaches.into_iter().map(|(mode, reader)| (mode, reader.finish())).collect();
        drop(control);
        let _ = mux.close_surface(surface.id);
        cmux_tui_core::server::cleanup(&sock);
        for (step, sent, command_ms) in &steps {
            let to = *sent + RESIZE_SETTLE;
            for (mode, got) in &received {
                let (wire_bytes, events, by_event) = window(got, *sent, to);
                let times: Vec<f64> = got
                    .lines
                    .iter()
                    .filter(|(at, _)| *at >= *sent && *at < to)
                    .map(|(at, _)| at.duration_since(*sent).as_secs_f64() * 1000.0)
                    .collect();
                rows.push(ResizeRow {
                    history,
                    step: step.clone(),
                    mode,
                    wire_bytes,
                    events,
                    by_event,
                    first_ms: times.first().copied(),
                    last_ms: times.last().copied(),
                    command_ms: *command_ms,
                    apply_ms: apply_resize(got, mode, *sent, to),
                });
            }
        }
    }
    let ms = |value: Option<f64>| value.map_or("-".to_string(), |ms| format!("{ms:.1}"));
    let mut text = format!(
        "One resize, per attach, on a {COLS} x {ROWS} PTY surface of a real daemon (cmux-tui-core tests/attach_mode_bench.rs attach_resize_bench)\n\n"
    );
    text.push_str("| History lines | Resize | Mode | Wire KB | First line ms | Last line ms | Command ms | Client rebuild ms | Events |\n");
    text.push_str("| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for row in &rows {
        let events: Vec<String> = row
            .by_event
            .iter()
            .map(|(name, n)| format!("{} {n}", if name.is_empty() { "?" } else { name }))
            .collect();
        text.push_str(&format!(
            "| {} | {} | {} | {:.1} | {} | {} | {:.1} | {:.2} | {} |\n",
            row.history,
            row.step,
            row.mode,
            row.wire_bytes as f64 / 1000.0,
            ms(row.first_ms),
            ms(row.last_ms),
            row.command_ms,
            row.apply_ms,
            events.join(", "),
        ));
    }
    println!("{text}");
    if let Some(dir) = std::env::var_os("FAST_CHECKS_OUT") {
        let path = std::path::Path::new(&dir).join("attach-resize-bench.json");
        let doc = json!({"cols": COLS, "rows": ROWS, "runs": rows.iter().map(ResizeRow::json).collect::<Vec<_>>()});
        std::fs::write(&path, serde_json::to_vec_pretty(&doc).unwrap()).unwrap();
        std::fs::write(path.with_extension("md"), &text).unwrap();
    }
    for row in &rows {
        assert!(
            row.events > 0,
            "{} {} {}: no lines after the resize",
            row.history,
            row.step,
            row.mode
        );
    }
}
