//! Cost per paint, small vs god scrollback (`cargo test --release -p
//! cmux-terminal-projection --test bench -- --ignored --nocapture`): an
//! echo, a streamed line and a rotation (a viewport change: its first frame,
//! re-wrapped at the new width) cost the same at 100, 10,000 and 100,000
//! history rows. A rotation paints a window (the screen and
//! `TAIL_SCREENS` above it); older rows come as the reader scrolls up.

use std::time::Instant;

use cmux_terminal_projection::{Projection, Segment};

/// A grid size, `(cols, rows)`.
type Grid = (usize, usize);

fn session(history: usize) -> Projection {
    let mut projection = Projection::new(120, 40, history + 100);
    let _ = projection.set_viewport(54, 38);
    let mut bytes = Vec::new();
    for i in 0..history {
        bytes.extend_from_slice(format!("\x1b[32m{i:06}\x1b[0m build step compiling a crate with a long enough line to wrap on the phone {i}\r\n").as_bytes());
    }
    bytes.extend_from_slice(b"$ ");
    let _ = projection.feed(&bytes, true);
    projection
}

fn per_op(label: &str, mut op: impl FnMut(usize), n: usize) -> f64 {
    let start = Instant::now();
    for i in 0..n {
        op(i);
    }
    let us = start.elapsed().as_secs_f64() * 1e6 / n as f64;
    println!("bench: {label}: {us:.1} us");
    us
}

fn bytes(segments: &[Segment]) -> usize {
    segments
        .iter()
        .map(|s| match s {
            Segment::Paint(b) | Segment::Reset(b) | Segment::Raw(b) => b.len(),
            Segment::Alternate(_) => 0,
        })
        .sum()
}

#[test]
#[ignore = "bench"]
fn paint_cost_is_flat_in_history() {
    let mut rotations = Vec::new();
    for history in [100, 10_000, 100_000] {
        let mut projection = session(history);
        per_op(
            &format!("{history} rows, echo"),
            |i| drop(projection.feed(&[b'a' + (i % 26) as u8], true)),
            2000,
        );
        per_op(
            &format!("{history} rows, streamed line"),
            |i| {
                drop(
                    projection.feed(
                        format!("output line {i} with some words in it\r\n").as_bytes(),
                        true,
                    ),
                );
            },
            2000,
        );
        let mut flip = false;
        let mut out = 0;
        let us = per_op(
            &format!("{history} rows, rotation (first frame)"),
            |_| {
                flip = !flip;
                out = bytes(
                    &projection
                        .set_viewport(if flip { 116 } else { 54 }, if flip { 16 } else { 38 }),
                );
            },
            40,
        );
        println!("bench: {history} rows, rotation bytes: {out}");
        rotations.push(us);
    }
    let (small, god) = (rotations[0], rotations[2]);
    println!("bench: rotation 100k / 100 rows, each alone: {:.2}x", god / small);
    assert!(
        god < 16_700.0,
        "a rotation's first frame at 100k rows is under one frame ({god:.0} us)"
    );
    // The work is the same at any length; a 100k-row heap alone slows every
    // paint of the process (a 100-row session measured beside it slows the
    // same), so the like-for-like gate measures both sessions side by side.
    let mut small = session(100);
    let mut god = session(100_000);
    let rotate = |projection: &mut Projection, label: &str| {
        let mut flip = false;
        per_op(
            label,
            |_| {
                flip = !flip;
                drop(
                    projection
                        .set_viewport(if flip { 116 } else { 54 }, if flip { 16 } else { 38 }),
                );
            },
            200,
        )
    };
    let mut ratios = Vec::new();
    for _ in 0..3 {
        let a = rotate(&mut small, "100 rows beside 100k, rotation (first frame)");
        let b = rotate(&mut god, "100000 rows, rotation (first frame)");
        ratios.push(b / a);
    }
    ratios.sort_by(f64::total_cmp);
    println!("bench: rotation 100k / 100 rows, side by side (median of 3): {:.2}x", ratios[1]);
    assert!(ratios[1] <= 1.2, "a rotation costs the same at 100 and 100k rows ({:.2}x)", ratios[1]);
}

/// Scrolling up after a rotation: each step re-wraps 2,000 more host rows
/// and repaints the phone's terminal from them (a terminal cannot take rows
/// above its scrollback); lines written before come from the view's cache.
/// The first, last and worst step at 100k rows.
#[test]
#[ignore = "bench"]
fn scrolling_up_after_a_rotation() {
    let mut projection = session(100_000);
    drop(projection.set_viewport(116, 16));
    let mut steps = Vec::new();
    loop {
        let start = Instant::now();
        let segments = projection.load_older(2_000);
        let us = start.elapsed().as_secs_f64() * 1e6;
        if segments.is_empty() {
            break;
        }
        steps.push((us, bytes(&segments)));
    }
    let worst = steps.iter().map(|s| s.0).fold(0.0, f64::max);
    println!(
        "bench: 100000 rows, scroll-up steps: {}, first {:.0} us ({} bytes), last {:.0} us ({} bytes), worst {:.0} us",
        steps.len(),
        steps[0].0,
        steps[0].1,
        steps[steps.len() - 1].0,
        steps[steps.len() - 1].1,
        worst
    );
    // Each step reuses the lines written before at this width: it re-wraps
    // 2,000 rows and copies the rest, under a frame even at the oldest.
    assert!(worst < 16_700.0, "a scroll-up step at 100k rows is under one frame ({worst:.0} us)");
}

/// Leo's keyboard toggle and rotation, before and after, in one harness
/// (`--ignored layout_change`): the same session, the same phone sizes.
///
/// - Before (Fit to Phone, a real resize): the Mac's terminal resizes and
///   the shell redraws its prompt; the daemon builds its replay; the phone's
///   mirror takes `ESC c` and the replay at the new size. This counts the
///   CPU on both ends and the bytes sent; a round trip between the phone
///   and the Mac comes on top of it, at least twice (the resize up, the
///   replay down).
/// - After (projection): the projection re-wraps at the new size and the
///   phone's terminal takes what it writes. Nothing is sent.
#[test]
#[ignore = "bench"]
fn layout_change_before_and_after() {
    use ghostty_vt::{Callbacks, Terminal as Vt};
    let vt =
        |c: usize, r: usize| Vt::new(c as u16, r as u16, 256 << 20, Callbacks::default()).unwrap();
    let history_bytes = |rows: usize| {
        let mut bytes = Vec::new();
        for i in 0..rows {
            bytes.extend_from_slice(format!("\x1b[32m{i:06}\x1b[0m build step compiling a crate with a long enough line to wrap on the phone {i}\r\n").as_bytes());
        }
        bytes.extend_from_slice(b"$ ");
        bytes
    };
    let changes: [(&str, Grid, Grid); 2] =
        [("keyboard toggle", (52, 38), (52, 20)), ("rotation", (52, 38), (112, 17))];
    let mut table = String::from(
        "| change | load | history rows | before: CPU per change | before: bytes sent | after: CPU per change | after: bytes sent |\n|---|---|---:|---:|---:|---:|---:|\n",
    );
    // Duress: a burst of Claude Code like output (colors, wide chars, a
    // spinner rewrite, ~16 KB) lands between every layout change, so the
    // change is measured on a terminal that is streaming and growing.
    let burst = {
        let mut b = Vec::new();
        for i in 0..160 {
            b.extend_from_slice(format!("\x1b[38;5;174m⏺\x1b[0m Update(src/lib.rs) 中文 ✅ \x1b[2mline {i} of a long tool result that wraps on the phone\x1b[0m\r\n").as_bytes());
            b.extend_from_slice(
                "\r\x1b[K\x1b[38;5;174m✻\x1b[0m Thinking… (esc to interrupt)".as_bytes(),
            );
        }
        b.extend_from_slice(b"\r\x1b[K$ ");
        b
    };
    let mut worst_after: f64 = 0.0;
    for (label, a, b) in changes {
        for (load, history, streaming) in [
            ("idle fixture", 0usize, false),
            ("idle fixture", 2_000, false),
            ("long session", 10_000, false),
            ("long session + streaming", 10_000, true),
        ] {
            let bytes = history_bytes(history);
            // Before: the Mac's terminal at the phone's size, the phone's
            // mirror beside it.
            let mut mac = vt(a.0, a.1);
            mac.vt_write(&bytes);
            let mut sent = 0usize;
            let n = 20;
            let mut before_d = std::time::Duration::ZERO;
            for i in 0..n {
                let (c, r) = if i % 2 == 0 { b } else { a };
                if streaming {
                    mac.vt_write(&burst);
                }
                let start = Instant::now();
                let _ = mac.resize(c as u16, r as u16, 0, 0);
                mac.vt_write(b"\r\x1b[J$ ");
                let replay = mac.vt_replay_bytes().unwrap();
                sent += replay.len() + 2;
                let mut mirror = vt(c, r);
                mirror.vt_write(b"\x1bc");
                mirror.vt_write(&replay);
                before_d += start.elapsed();
            }
            let before_us = before_d.as_secs_f64() * 1e6 / n as f64;
            let before_bytes = sent / n;
            // After: the projection and the phone's terminal.
            let mut projection = Projection::new(120, 40, history + 100);
            let mut phone = vt(a.0, a.1);
            for seg in
                projection.set_viewport(a.0, a.1).into_iter().chain(projection.feed(&bytes, true))
            {
                if let Segment::Paint(x) | Segment::Reset(x) | Segment::Raw(x) = seg {
                    phone.vt_write(&x);
                }
            }
            let mut after_d = std::time::Duration::ZERO;
            let mut cur = a;
            for i in 0..n {
                let (c, r) = if i % 2 == 0 { b } else { a };
                if streaming {
                    for seg in projection.feed(&burst, true) {
                        match seg {
                            Segment::Reset(x) => {
                                phone = vt(cur.0, cur.1);
                                phone.vt_write(&x);
                            }
                            Segment::Paint(x) | Segment::Raw(x) => phone.vt_write(&x),
                            Segment::Alternate(_) => {}
                        }
                    }
                }
                let start = Instant::now();
                cur = (c, r);
                let _ = phone.resize(c as u16, r as u16, 0, 0);
                for seg in projection.set_viewport(c, r) {
                    match seg {
                        Segment::Reset(x) => {
                            phone = vt(c, r);
                            phone.vt_write(&x);
                        }
                        Segment::Paint(x) | Segment::Raw(x) => phone.vt_write(&x),
                        Segment::Alternate(_) => {}
                    }
                }
                after_d += start.elapsed();
            }
            let after_us = after_d.as_secs_f64() * 1e6 / n as f64;
            worst_after = worst_after.max(after_us);
            let _ = std::fmt::Write::write_fmt(
                &mut table,
                format_args!(
                    "| {label} | {load} | {history} | {:.2} ms + 2 round trips | {before_bytes} | {:.2} ms | 0 |\n",
                    before_us / 1000.0,
                    after_us / 1000.0
                ),
            );
        }
    }
    println!("Layout change, before (real resize) and after (projection):\n{table}");
    if let Ok(dir) = std::env::var("PARITY_OUT") {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(std::path::Path::new(&dir).join("layout.md"), &table).unwrap();
    }
    assert!(
        worst_after < 16_700.0,
        "a layout change under projection fits one frame ({worst_after:.0} us)"
    );
}
