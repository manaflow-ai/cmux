//! Frame build cost per frame: `cargo test --release -p ghostty-vt --test
//! frame_build_bench -- --ignored --nocapture`. Prints one line per workload
//! with the mean and p99 of `update` + `build_frame` in microseconds.

use std::time::{Duration, Instant};

use ghostty_vt::{Callbacks, RenderState, Terminal};

const COLS: u16 = 200;
const ROWS: u16 = 50;
const FRAMES: usize = 3000;

/// A full screen of styled text, as an editor or a busy log leaves it.
fn filled_terminal() -> Terminal {
    let mut term = Terminal::new(COLS, ROWS, 1000, Callbacks::default()).unwrap();
    for row in 0..ROWS {
        let mut line = format!("\x1b[{};1H", row + 1);
        for col in 0..COLS / 10 {
            line.push_str(&format!("\x1b[3{}m{:>9} ", (row + col) % 8, row * 1000 + col));
        }
        line.push_str("\x1b[0m");
        term.vt_write(line.as_bytes());
    }
    term
}

fn measure(name: &str, mut step: impl FnMut(usize, &mut Terminal)) {
    let mut term = filled_terminal();
    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    let _ = state.build_frame().unwrap();
    let mut samples = Vec::with_capacity(FRAMES);
    for index in 0..FRAMES {
        step(index, &mut term);
        let started = Instant::now();
        state.update(&mut term).unwrap();
        let frame = state.build_frame().unwrap();
        samples.push(started.elapsed());
        std::hint::black_box(frame);
    }
    samples.sort();
    let mean = samples.iter().sum::<Duration>() / FRAMES as u32;
    let p99 = samples[FRAMES * 99 / 100];
    println!(
        "FRAME-BUILD {name} cols={COLS} rows={ROWS} frames={FRAMES} mean_us={:.1} p99_us={:.1}",
        mean.as_secs_f64() * 1e6,
        p99.as_secs_f64() * 1e6
    );
}

#[test]
#[ignore = "benchmark: run with --release -- --ignored --nocapture"]
fn frame_build_cost() {
    // A keystroke and its echo: one cell on the prompt row changes.
    measure("typing", |index, term| {
        let ch = b'a' + (index % 26) as u8;
        term.vt_write(&[b'\x1b', b'[', b'5', b'0', b';', b'1', b'0', b'H', ch]);
    });
    // Nothing changed since the last frame (a cursor blink, a resize to the same size).
    measure("idle", |_, _| {});
    // A status line repaint: three rows change.
    measure("three-rows", |index, term| {
        let text =
            format!("\x1b[1;1Hstatus {index}\x1b[25;1Hmiddle {index}\x1b[50;1Hbottom {index}");
        term.vt_write(text.as_bytes());
    });
    // Output that scrolls the whole screen: every row is new.
    measure("scroll", |index, term| {
        let text = format!("\x1b[50;1H\r\n\x1b[32mline {index} of a log that scrolls\x1b[0m");
        term.vt_write(text.as_bytes());
    });
}
