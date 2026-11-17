//! What a phone's bytes attach costs the daemon, on one real daemon over its
//! socket: a 120 x 40 PTY surface with N rows of history (N = 100 and
//! N = 100,000 coloured compiler lines), and per case, median of 5 runs:
//!
//! - `attach-surface` (bytes mode) with `replay_history_rows: 0` (the screen
//!   alone), `10000`, a window (`replay_history_rows: 4000,
//!   replay_history_start: 40000`) and no field (the whole history): wall ms
//!   from writing the request to the whole `vt-state` line and to the reply,
//!   and the `vt-state` line's bytes. Each attach is a fresh connection that
//!   first declares `attach-replay-history-window-v1`, as the phone does;
//! - `set-client-info` + `identify` on a fresh connection (no replay): the
//!   round trip every attach also pays;
//! - in process, the ms the daemon's own terminal lock is held building each
//!   replay (`Surface::with_terminal` around the same `ghostty_vt` calls
//!   `window_replay_locked` makes, on the same terminal).
//!
//! Prints `ATTACH-LOAD-RUST` lines; with `FAST_CHECKS_OUT` set it also writes
//! `attach-load-bench.json` there. Run on the fleet (ignored in the normal
//! test run):
//! `cargo test -p cmux-tui-core --test attach_load_bench --release -- --ignored --nocapture`.

use std::io::{Read, Write};
use std::time::{Duration, Instant};

mod support;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};
use serde_json::{Value, json};
use support::{DaemonMuxOps, wait_for};

const COLS: u16 = 120;
const ROWS: u16 = 40;
const RUNS: usize = 5;
/// The daemon's replay budget (`VT_REPLAY_MAX_BYTES`, crate-private).
const REPLAY_MAX_BYTES: usize = ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES + 2 * 1024 * 1024;

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    values[values.len() / 2]
}

/// One fresh socket connection, reading whole lines.
struct Conn {
    stream: Box<dyn transport::Stream>,
    pending: Vec<u8>,
}

impl Conn {
    fn open(sock: &std::path::Path) -> Self {
        let stream = transport::connect(sock).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        Self { stream, pending: Vec::new() }
    }

    fn send(&mut self, value: Value) {
        let mut line = serde_json::to_vec(&value).unwrap();
        line.push(b'\n');
        self.stream.write_all(&line).unwrap();
    }

    /// The next line, or panic after 60 s.
    fn line(&mut self) -> (Instant, Vec<u8>) {
        let deadline = Instant::now() + Duration::from_secs(60);
        let mut buf = vec![0u8; 1 << 20];
        loop {
            if let Some(at) = self.pending.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=at).collect();
                return (Instant::now(), line[..line.len() - 1].to_vec());
            }
            assert!(Instant::now() < deadline, "no line from the daemon in 60 s");
            match self.stream.read(&mut buf) {
                Ok(0) => panic!("daemon closed the connection"),
                Ok(n) => self.pending.extend_from_slice(&buf[..n]),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(error) => panic!("read failed: {error}"),
            }
        }
    }

    /// Lines until the reply with `id`; returns (reply time, reply).
    fn reply(&mut self, id: u64) -> (Instant, Value) {
        loop {
            let (at, line) = self.line();
            let value: Value = serde_json::from_slice(&line).unwrap_or(Value::Null);
            if value.get("id").and_then(Value::as_u64) == Some(id) && value.get("event").is_none() {
                assert_eq!(
                    value.get("ok"),
                    Some(&Value::Bool(true)),
                    "request {id} failed: {value}"
                );
                return (at, value);
            }
        }
    }
}

struct AttachCase {
    name: &'static str,
    fields: Value,
}

fn attach_cases() -> Vec<AttachCase> {
    vec![
        AttachCase { name: "screen-only", fields: json!({"replay_history_rows": 0}) },
        AttachCase { name: "tail-10k", fields: json!({"replay_history_rows": 10_000}) },
        AttachCase {
            name: "window-4k@40k",
            fields: json!({"replay_history_rows": 4_000, "replay_history_start": 40_000}),
        },
        AttachCase { name: "whole-history", fields: json!({}) },
    ]
}

/// One attach: (ms to the whole vt-state line, ms to the reply, line bytes,
/// history_rows_omitted, history_rows_skipped).
fn attach_once(
    sock: &std::path::Path,
    surface: u64,
    fields: &Value,
) -> (f64, f64, usize, Value, Value) {
    let mut conn = Conn::open(sock);
    conn.send(json!({"id": 1, "cmd": "set-client-info", "name": "attach load bench",
        "capabilities": ["attach-replay-history-window-v1"]}));
    conn.reply(1);
    let mut request =
        json!({"id": 2, "cmd": "attach-surface", "surface": surface, "mode": "bytes"});
    for (key, value) in fields.as_object().unwrap() {
        request[key] = value.clone();
    }
    let started = Instant::now();
    conn.send(request);
    let (mut state_at, mut reply_at, mut state) = (None, None, None);
    while state_at.is_none() || reply_at.is_none() {
        let (at, line) = conn.line();
        let head = &line[..line.len().min(256)];
        let head = String::from_utf8_lossy(head);
        if state_at.is_none() && head.contains("\"event\":\"vt-state\"") {
            state_at = Some(at);
            let value: Value = serde_json::from_slice(&line).unwrap();
            state = Some((
                line.len() + 1,
                value.get("history_rows_omitted").cloned().unwrap_or(Value::Null),
                value.get("history_rows_skipped").cloned().unwrap_or(Value::Null),
            ));
        } else if reply_at.is_none() && !head.contains("\"event\"") {
            let value: Value = serde_json::from_slice(&line).unwrap_or(Value::Null);
            if value.get("id").and_then(Value::as_u64) == Some(2) {
                assert_eq!(value.get("ok"), Some(&Value::Bool(true)), "attach failed: {value}");
                reply_at = Some(at);
            }
        }
    }
    drop(conn);
    let ms = |at: Instant| at.duration_since(started).as_secs_f64() * 1000.0;
    let (bytes, omitted, skipped) = state.unwrap();
    (ms(state_at.unwrap()), ms(reply_at.unwrap()), bytes, omitted, skipped)
}

/// `set-client-info` + `identify` on a fresh connection, both replies.
fn baseline_once(sock: &std::path::Path) -> f64 {
    let mut conn = Conn::open(sock);
    let started = Instant::now();
    conn.send(json!({"id": 1, "cmd": "set-client-info", "name": "attach load bench",
        "capabilities": ["attach-replay-history-window-v1"]}));
    conn.send(json!({"id": 2, "cmd": "identify"}));
    conn.reply(1);
    let (at, _) = conn.reply(2);
    at.duration_since(started).as_secs_f64() * 1000.0
}

fn build_line(line: usize) -> String {
    format!(
        "\x1b[32m{line:06}\x1b[0m compiling crate-{} v0.{}.{} (/home/dev/src/project/crates/c{}) in {}ms\r\n",
        line % 977,
        line % 13,
        line % 101,
        line % 31,
        line % 4099
    )
}

fn run_case(history: usize, out: &mut Vec<String>, rows: &mut Vec<Value>) {
    let profile = if cfg!(debug_assertions) { "debug" } else { "release" };
    let file = std::env::temp_dir()
        .join(format!("attach-load-bench-{}-{history}.txt", std::process::id()));
    let mut text = String::with_capacity((history + 64) * 96);
    for line in 0..history + usize::from(ROWS) {
        text.push_str(&build_line(line));
    }
    text.push_str("fill-done");
    std::fs::write(&file, &text).unwrap();
    let script = format!("stty raw -echo; cat '{}'; exec cat", file.display());
    let opts = SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script]),
        scrollback: 400_000_000,
        ..Default::default()
    };
    let mux = Mux::new(format!("attach-load-bench-{}-{history}", std::process::id()), opts);
    let surface = mux.new_workspace(None, Some((COLS, ROWS))).unwrap();
    let fill_started = Instant::now();
    let filled = wait_for(
        || {
            surface
                .with_terminal(|term| {
                    let rows = term.history_rows() as usize;
                    let done = term.viewport_text().ok().is_some_and(|t| t.contains("fill-done"));
                    (done && rows >= history).then_some(rows)
                })
                .flatten()
        },
        Duration::from_secs(300),
    )
    .unwrap_or_else(|| panic!("history did not reach {history} rows"));
    let _ = std::fs::remove_file(&file);
    out.push(format!(
        "ATTACH-LOAD-RUST {profile} N={history}: history_rows {filled}, filled in {:.0} ms",
        fill_started.elapsed().as_secs_f64() * 1000.0
    ));
    let sock = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    // Warm the socket path once.
    let _ = baseline_once(&sock);
    let baseline = median((0..RUNS).map(|_| baseline_once(&sock)).collect());
    out.push(format!(
        "ATTACH-LOAD-RUST {profile} N={history} baseline set-client-info+identify: {baseline:.2} ms"
    ));
    rows.push(json!({"history": history, "case": "baseline", "reply_ms": baseline}));

    for case in attach_cases() {
        let mut state_ms = Vec::new();
        let mut reply_ms = Vec::new();
        let mut bytes = 0;
        let (mut omitted, mut skipped) = (Value::Null, Value::Null);
        for _ in 0..RUNS {
            let (s, r, b, o, k) = attach_once(&sock, surface.id, &case.fields);
            state_ms.push(s);
            reply_ms.push(r);
            bytes = b;
            omitted = o;
            skipped = k;
            // The daemon detaches the closed connection.
            std::thread::sleep(Duration::from_millis(50));
        }
        let (s, r) = (median(state_ms), median(reply_ms));
        out.push(format!(
            "ATTACH-LOAD-RUST {profile} N={history} attach {}: vt-state {bytes} bytes, {s:.2} ms to vt-state, {r:.2} ms to reply, omitted {omitted}, skipped {skipped}",
            case.name
        ));
        rows.push(json!({"history": history, "case": case.name, "vt_state_bytes": bytes,
            "vt_state_ms": s, "reply_ms": r, "history_rows_omitted": omitted,
            "history_rows_skipped": skipped}));
    }

    // The daemon's terminal lock held building each replay, in process.
    type Build = fn(&mut ghostty_vt::Terminal) -> usize;
    let builds: [(&str, Build); 4] = [
        ("screen-only", |t| {
            t.vt_replay_tail_theme_portable_with_aliases(REPLAY_MAX_BYTES, 0)
                .unwrap()
                .replay
                .bytes
                .len()
        }),
        ("tail-10k", |t| {
            t.vt_replay_tail_theme_portable_with_aliases(REPLAY_MAX_BYTES, 10_000)
                .unwrap()
                .replay
                .bytes
                .len()
        }),
        ("window-4k@40k", |t| {
            match t
                .vt_replay_window_theme_portable_with_aliases(REPLAY_MAX_BYTES, 40_000, 4_000)
                .unwrap()
            {
                Some(window) => window.replay.bytes.len(),
                // The daemon falls back to a tail from the window's start.
                None => {
                    let rows = u64::from(t.history_rows()).saturating_sub(40_000);
                    t.vt_replay_tail_theme_portable_with_aliases(REPLAY_MAX_BYTES, rows)
                        .unwrap()
                        .replay
                        .bytes
                        .len()
                }
            }
        }),
        ("whole-history", |t| {
            t.vt_replay_bounded_theme_portable_with_aliases(REPLAY_MAX_BYTES).unwrap().bytes.len()
        }),
    ];
    for (name, build) in builds {
        let mut ms = Vec::new();
        let mut raw = 0;
        for _ in 0..RUNS {
            let (elapsed, len) = surface
                .with_terminal(|t| {
                    let started = Instant::now();
                    let len = build(t);
                    (started.elapsed().as_secs_f64() * 1000.0, len)
                })
                .unwrap();
            ms.push(elapsed);
            raw = len;
        }
        let ms = median(ms);
        out.push(format!(
            "ATTACH-LOAD-RUST {profile} N={history} lock-held replay build {name}: {ms:.2} ms, {raw} raw replay bytes"
        ));
        rows.push(json!({"history": history, "case": format!("lock-build {name}"),
            "lock_ms": ms, "raw_replay_bytes": raw}));
    }

    let _ = mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock);
}

#[test]
#[ignore = "a bench; run with --ignored --nocapture"]
fn attach_load_cost() {
    let mut out = Vec::new();
    let mut rows = Vec::new();
    for history in [100usize, 100_000] {
        run_case(history, &mut out, &mut rows);
    }
    for line in &out {
        println!("{line}");
    }
    if let Some(dir) = std::env::var_os("FAST_CHECKS_OUT") {
        std::fs::create_dir_all(&dir).unwrap();
        let doc = json!({"cols": COLS, "rows": ROWS, "runs_per_case": RUNS, "results": rows});
        std::fs::write(
            std::path::Path::new(&dir).join("attach-load-bench.json"),
            serde_json::to_vec_pretty(&doc).unwrap(),
        )
        .unwrap();
    }
}
