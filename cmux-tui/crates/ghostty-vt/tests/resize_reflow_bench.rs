//! Reflow cost per frame of a divider drag: `cargo test --release -p ghostty-vt
//! --test resize_reflow_bench -- --ignored --nocapture`. A terminal holding a
//! long wrapped transcript (a long Claude Code session) is resized one column
//! per frame, 120 to 60 columns and back, as a pane drag reports its grid. Prints
//! one line per scrollback size with the p50, p95 and longest `resize`.

use std::time::{Duration, Instant};

use ghostty_vt::{Callbacks, Terminal};

const ROWS: u16 = 50;
const WIDE: u16 = 120;
const NARROW: u16 = 60;

/// A transcript of `bytes` of prose, in paragraphs that wrap at any width.
fn transcript(term: &mut Terminal, bytes: usize) {
    let words =
        ["the", "pane", "resized", "while", "a", "long", "answer", "wrapped", "across", "rows"];
    let mut written = 0;
    let mut turn = 0usize;
    while written < bytes {
        let mut line = format!("\x1b[1mturn {turn}\x1b[0m ");
        for word in 0..90 {
            line.push_str(words[(turn + word) % words.len()]);
            line.push(' ');
        }
        line.push_str("\r\n\r\n");
        term.vt_write(line.as_bytes());
        written += line.len();
        turn += 1;
    }
}

fn measure(scrollback_bytes: usize) {
    let mut term = Terminal::new(WIDE, ROWS, 10_000_000, Callbacks::default()).unwrap();
    transcript(&mut term, scrollback_bytes);
    let widths: Vec<u16> = (NARROW..WIDE).rev().chain(NARROW + 1..=WIDE).collect();
    let mut samples = Vec::with_capacity(widths.len());
    for cols in widths {
        let started = Instant::now();
        term.resize(cols, ROWS, 8, 16).unwrap();
        samples.push(started.elapsed());
    }
    samples.sort();
    let at = |q: usize| samples[(samples.len() - 1) * q / 100].as_secs_f64() * 1e3;
    let total: Duration = samples.iter().sum();
    println!(
        "RESIZE-REFLOW transcript_bytes={scrollback_bytes} frames={} p50_ms={:.2} p95_ms={:.2} max_ms={:.2} total_ms={:.0}",
        samples.len(),
        at(50),
        at(95),
        at(100),
        total.as_secs_f64() * 1e3
    );
}

#[test]
#[ignore = "benchmark: run with --release -- --ignored --nocapture"]
fn resize_reflow_cost() {
    for bytes in [100_000, 1_000_000, 4_000_000, 10_000_000] {
        measure(bytes);
    }
}
