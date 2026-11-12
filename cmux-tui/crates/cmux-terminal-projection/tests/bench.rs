//! Cost per paint, small vs god scrollback (`cargo test --release -p
//! cmux-terminal-projection --test bench -- --ignored --nocapture`): an
//! echo, a streamed line and a rotation (a viewport change: its first frame,
//! re-wrapped at the new width) cost the same at 100, 10,000 and 100,000
//! history rows. A rotation paints a window (the screen and
//! `TAIL_SCREENS` above it); older rows come as the reader scrolls up.

use std::time::Instant;

use cmux_terminal_projection::{Projection, Segment};

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
                )
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
