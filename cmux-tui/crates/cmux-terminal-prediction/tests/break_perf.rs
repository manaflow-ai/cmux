//! Every read from a remote surface is copied into the inbox on the IO
//! thread and scanned byte by byte on the main thread, whether or not a key
//! is pending. `scan` returns a vector with one enum per byte.
//!
//! Measured on an idle M-series mini in the Swift suite, `swift test -c
//! release`: scan 54 ms per MiB, `observedOutput` 62 ms per MiB (16 MiB/s),
//! against 0.14 ms to map the same MiB into an enum array. A remote `cat` of
//! a log, or a build streaming over a LAN link, outruns the main thread
//! several times over, and the inbox has no bound while it catches up.

use cmux_terminal_prediction::{PredictionConfiguration, TerminalOutputScanner, TerminalOutputSignal, TerminalPredictionEngine};
use std::hint::black_box;
use std::time::{Duration, Instant};

fn chunk() -> Vec<u8> {
    let line = b"\x1B[32mCompiling\x1B[0m cmux-terminal-prediction v0.1.0 (/src/Packages/Shared/CmuxTerminalPrediction) target=arm64\r\n";
    let mut chunk = Vec::new();
    while chunk.len() < 65_536 {
        chunk.extend_from_slice(line);
    }
    chunk
}

fn engine() -> TerminalPredictionEngine {
    TerminalPredictionEngine::new(PredictionConfiguration::DEFAULT, true, true)
}

fn seconds(body: impl FnOnce()) -> f64 {
    let start = Instant::now();
    body();
    start.elapsed().as_secs_f64()
}

/// Output with nothing in flight must not be classified byte by byte.
/// Measured against touching every byte once in the same build, so the bound
/// holds on a loaded machine and in a debug build alike. Each byte goes
/// through `black_box`, so the reference loop is not vectorized away.
#[test]
fn scanning_a_remote_build_log_on_the_main_thread() {
    let chunk = chunk();
    let chunks = 16; // 1 MiB
    let mut total = 0_usize;
    let touch_every_byte = seconds(|| {
        for _ in 0..chunks {
            for &byte in &chunk {
                total = total.wrapping_add(usize::from(black_box(byte)));
            }
        }
    });
    assert!(total != 1);
    let mut idle = engine();
    let idle_seconds = seconds(|| {
        for index in 0..chunks {
            black_box(idle.observed_output(&chunk, Duration::from_millis(index)));
        }
    });
    // One key typed first: its echo never comes, the first chunk withdraws
    // it, and the rest is idle output again.
    let mut typed = engine();
    typed.typed_printable_ascii(Some(0x61), Duration::ZERO);
    let typed_seconds = seconds(|| {
        for index in 0..chunks {
            black_box(typed.observed_output(&chunk, Duration::from_millis(index + 1)));
        }
    });
    println!("PERF 1 MiB: touch every byte {touch_every_byte} s, idle surface {idle_seconds} s, after a key {typed_seconds} s");
    assert!(
        idle_seconds < touch_every_byte,
        "idle output took {idle_seconds} s against {touch_every_byte} s to touch every byte"
    );
    assert!(
        typed_seconds < touch_every_byte,
        "output after a key took {typed_seconds} s against {touch_every_byte} s to touch every byte"
    );
}

#[test]
fn breakdown() {
    let chunk = chunk();
    let time = |label: &str, body: &mut dyn FnMut()| {
        let start = Instant::now();
        body();
        println!("PERF {label}: {:?}", start.elapsed());
    };
    time("calibration: sum 1 MiB x16", &mut || {
        let mut total = 0_usize;
        for _ in 0..16 {
            for &byte in &chunk {
                total = total.wrapping_add(usize::from(byte));
            }
        }
        assert!(black_box(total) != 1);
    });
    time("calibration: map 1 MiB into [enum] x1", &mut || {
        let out: Vec<TerminalOutputSignal> = chunk.iter().map(|&b| TerminalOutputSignal::Printable(b)).collect();
        assert!(!black_box(out).is_empty());
    });
    time("scan 1 MiB", &mut || {
        let mut scanner = TerminalOutputScanner::new();
        let mut n = 0;
        for _ in 0..16 {
            n += scanner.scan(&chunk).len();
        }
        assert!(n > 0);
    });
    time("engine 1 MiB, never typed", &mut || {
        let mut engine = engine();
        for index in 0..16 {
            engine.observed_output(&chunk, Duration::from_millis(index));
        }
    });
    time("engine 1 MiB, one key typed first", &mut || {
        let mut engine = engine();
        engine.typed_printable_ascii(Some(0x61), Duration::ZERO);
        for index in 0..16 {
            engine.observed_output(&chunk, Duration::from_millis(index + 1));
        }
    });
}
