//! The headless row of Mac output to iPhone paint (ask-0e9bbe35bb), on one clock: a terminal
//! with a 20,000-line history streams a coloured build log line every 10 ms while a phone-like
//! viewer, attached as the phone attaches (bytes, `attach-output-coalesce-v1`), parses what
//! arrives into its own ghostty-vt terminal and pans it, one scroll step and one viewport read
//! per 120 Hz frame. Each line is stamped when the terminal is written
//! ([`cmux_output_paint::SendStamps`]); each frame records the output it had parsed; the
//! window ([`cmux_output_paint::window`]) times every line to the first frame that showed it.
//! No link: `rtt` is 0, so both columns are the Mac's pipeline and the paint loop.
//!
//! `cargo test -p cmux-tui-core --lib output_to_paint -- --nocapture`;
//! `CMUX_OUTPUT_TO_PAINT_SECONDS` sets the stream's length (default 3).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_output_paint::{Paint, SendStamps};
use serde_json::{Value, json};

use super::{declaring, disconnect_client, terminal};

const HISTORY_ROWS: usize = 20_000;
const FRAME: Duration = Duration::from_micros(8_333);

fn line(n: usize) -> Vec<u8> {
    format!("\x1b[1;32m   Compiling\x1b[0m crate-{n} v0.1.{n} (/src/crate-{n})\r\n").into_bytes()
}

#[test]
fn output_to_paint_headless_under_duress() {
    let seconds: u64 = std::env::var("CMUX_OUTPUT_TO_PAINT_SECONDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(3);
    let (mux, surface) = terminal("output-to-paint", None);
    for n in 0..HISTORY_ROWS {
        surface.inject_output_for_test(&line(n));
    }
    let viewer = declaring(&mux, &["attach-output-coalesce-v1", "terminal-pending-sequence-v1"]);
    viewer.attach(&mux, &surface, json!({"cols": 100, "rows": 40}));
    // The attach's replay first: the stream's offsets start after it.
    let mut skipped = Vec::new();
    let first = viewer.next("vt-state", &mut skipped);
    let replay: Vec<Vec<u8>> = ["data", "pending"]
        .iter()
        .filter_map(|key| first[key].as_str())
        .map(|text| base64::engine::general_purpose::STANDARD.decode(text).unwrap())
        .collect();
    std::thread::sleep(Duration::from_millis(200));
    while viewer.outbound.try_pop().is_some() {}

    let clock = Instant::now();
    let now_us = move || clock.elapsed().as_micros() as u64;
    let stamps = Arc::new(Mutex::new(SendStamps::default()));
    let stop = Arc::new(AtomicBool::new(false));
    // The phone's side: what arrives is parsed at once; a frame every 8.3 ms pans and reads
    // the viewport, and records the output parsed by then.
    let (paints_tx, paints_rx) = mpsc::channel::<Vec<Paint>>();
    let outbound = viewer.outbound.clone();
    let painter_stop = stop.clone();
    let painter = std::thread::spawn(move || {
        let mut term =
            ghostty_vt::Terminal::new(100, 40, 64 << 20, ghostty_vt::Callbacks::default())
                .expect("a terminal");
        for bytes in &replay {
            term.vt_write(bytes);
        }
        let history = term.scrollback_rows();
        let mut paints = Vec::new();
        let mut through = 0u64;
        let mut next = Instant::now();
        let mut direction = -3isize;
        let mut frames = 0u64;
        let mut received = 0u64;
        while !painter_stop.load(Ordering::Relaxed) {
            while let Some(message) = outbound.try_pop() {
                let Ok(value) = serde_json::from_str::<Value>(&message) else { continue };
                if value["event"] == "output"
                    && let Some(data) = value["data"].as_str()
                {
                    let bytes = base64::engine::general_purpose::STANDARD.decode(data).unwrap();
                    term.vt_write(&bytes);
                    through += bytes.len() as u64;
                    received += 1;
                }
            }
            if Instant::now() >= next {
                frames += 1;
                if frames % 60 == 0 {
                    direction = -direction;
                }
                term.scroll_delta(direction);
                let _ = term.viewport_text();
                paints.push(Paint { through, at_us: now_us() });
                next += FRAME;
            } else {
                std::thread::sleep(Duration::from_micros(200));
            }
        }
        let _ = paints_tx.send(paints);
        (frames, received, history)
    });

    let start = Instant::now();
    let mut n = HISTORY_ROWS;
    while start.elapsed() < Duration::from_secs(seconds) {
        let bytes = line(n);
        n += 1;
        stamps.lock().unwrap().sent(bytes.len() as u64, now_us());
        surface.inject_output_for_test(&bytes);
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(300));
    stop.store(true, Ordering::Relaxed);
    let (frames, received, history) = painter.join().unwrap();
    let paints = paints_rx.recv().unwrap();
    let stamps = stamps.lock().unwrap();
    let window =
        cmux_output_paint::window(&stamps, &paints, Some(0.0)).expect("lines were painted");
    let less = window.less_half_rtt.expect("rtt given");
    println!(
        "OUTPUT_TO_PAINT_HEADLESS {}",
        json!({
            "duress": format!("{HISTORY_ROWS}-line session ({history} rows held) streaming a line every 10 ms while panning at 120 Hz"),
            "seconds": seconds,
            "lines_sent": n - HISTORY_ROWS,
            "output_events_received": received,
            "frames": frames,
            "output_to_paint_ms": {"events": window.raw.events, "p50_ms": window.raw.p50_ms, "p95_ms": window.raw.p95_ms, "max_ms": window.raw.max_ms},
            "output_to_paint_less_half_rtt_ms": {"events": less.events, "p50_ms": less.p50_ms, "p95_ms": less.p95_ms, "max_ms": less.max_ms},
            "rtt_ms": 0,
            "partial": window.partial,
            "ahead": window.ahead,
        })
    );
    assert_eq!(window.ahead, 0, "the viewer parsed exactly the bytes the terminal was written");
    assert!(!window.partial);
    assert!(window.raw.events as u64 >= (n - HISTORY_ROWS) as u64 * 9 / 10, "{window:?}");
    assert!(window.raw.p50_ms < 1_000.0, "{window:?}");
    disconnect_client(&mux, viewer.client, false);
}
