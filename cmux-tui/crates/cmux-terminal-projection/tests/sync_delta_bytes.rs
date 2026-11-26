//! RFD 0140 §4's byte target for the viewport sync's diffs (`sync::diff`, the
//! diff from the phone's last acked screen), on a real VT model: after a
//! one-line change the diff is under 1% of the keyframe for the same screen at
//! 200x60. An 80x24 keyframe is about 1.2 KB, so 1% is 12 bytes, about the
//! fixed cost of any diff (version, flags, 4-byte digest, a span's row, column
//! and length): there the bound is 2%, and an echoed key is at most 12 bytes.

use cmux_terminal_projection::Terminal;
use cmux_terminal_projection::sync::{ScreenState, apply, diff};

fn feed(term: &mut Terminal, bytes: &[u8]) {
    for &b in bytes {
        term.advance(b);
    }
}

/// A screen full of colored listing output and a prompt, like a busy shell.
fn busy(cols: usize, rows: usize) -> Terminal {
    let mut term = Terminal::new(cols, rows, 1000);
    for i in 0..rows * 2 {
        let name = format!("src/module_{i:04}/file_with_a_longer_name_{i}.rs");
        let line = format!(
            "\x1b[1;34m{:>6}\x1b[0m  \x1b[32m-rw-r--r--\x1b[0m  {} \x1b[33m{:>8}\x1b[0m {}\r\n",
            i,
            "Nov 25 05:58",
            i * 7919 % 100_000,
            name
        );
        feed(&mut term, line.as_bytes());
    }
    feed(&mut term, b"$ ");
    term
}

/// (case, base screen, latest screen) for one-line changes on a busy screen.
fn cases(cols: usize, rows: usize) -> Vec<(&'static str, ScreenState, ScreenState)> {
    let step = |setup: &[u8], change: &[u8]| {
        let mut term = busy(cols, rows);
        feed(&mut term, setup);
        let a = ScreenState::capture(&term);
        feed(&mut term, change);
        (a, ScreenState::capture(&term))
    };
    let mut out = Vec::new();
    let (a, b) = step(b"", b"l");
    out.push(("keystroke echo", a, b));
    let clock =
        |s: u8| format!("\x1b7\x1b[1;1H\x1b[7m 05:58:0{} \x1b[0m\x1b8", s as char).into_bytes();
    let (a, b) = step(&clock(b'1'), &clock(b'2'));
    out.push(("status clock tick", a, b));
    let (a, b) = step(b"\r\x1b[Kdownloading  41%", b"\r\x1b[Kdownloading  42%");
    out.push(("progress line redraw", a, b));
    let (a, b) = step(b"", b"ok\r\n$ ");
    out.push(("one output line (scroll)", a, b));
    out
}

#[test]
fn one_line_change_diff_is_a_sliver_of_a_keyframe() {
    let mut failures = Vec::new();
    for (cols, rows) in [(80, 24), (200, 60)] {
        for (name, a, b) in cases(cols, rows) {
            let keyframe = diff(None, &b).len();
            let delta = diff(Some(&a), &b);
            // The diff reproduces the screen.
            assert_eq!(apply(Some(&a), &delta).as_ref(), Ok(&b), "{cols}x{rows} {name}");
            let ratio = delta.len() as f64 / keyframe as f64;
            println!(
                "{cols}x{rows} {name:<26} keyframe {keyframe:>6} B  diff {:>4} B  {:.3}%",
                delta.len(),
                ratio * 100.0
            );
            let bound = if cols >= 200 { 0.01 } else { 0.02 };
            if ratio >= bound {
                failures.push(format!("{cols}x{rows} {name}: {} of {keyframe} B", delta.len()));
            }
            if name == "keystroke echo" && delta.len() > 12 {
                failures.push(format!("{cols}x{rows} {name}: {} B > 12 B", delta.len()));
            }
        }
    }
    assert!(failures.is_empty(), "over the bound: {failures:?}");
}
