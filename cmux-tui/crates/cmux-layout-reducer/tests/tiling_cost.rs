//! The cost of the F2 check at a layout commit, against the cost of the layout itself, for screens
//! of 1 to 256 panes. A timed test, ignored by default; run it in the release profile:
//!
//! ```sh
//! cargo test -p cmux-layout-reducer --release --test tiling_cost -- --ignored --nocapture
//! ```
//!
//! It prints one row per pane count: ns per layout alone (`layout`), per layout with the check
//! (`solve`, what a commit costs now) and per check alone, and the check's ns per rect, which stays
//! flat as the pane count grows (the check is linear in the rects, plus a sort of their corners).

use cmux_layout_reducer::optimistic::{Dir, Node};
use cmux_layout_reducer::split_layout::{SplitSolver, SplitStyle};
use cmux_layout_reducer::tiling::{Checker, Frame, RectPt};
use std::hint::black_box;
use std::time::Instant;

/// A balanced tree of `n` panes, splits alternating across and down.
fn tree(first: u64, n: u64, depth: u32) -> Node {
    if n == 1 {
        return Node::Leaf { pane: first };
    }
    let half = n / 2;
    Node::Split {
        split: Some(first * 1000 + u64::from(depth)),
        split_id: None,
        dir: if depth.is_multiple_of(2) { Dir::Right } else { Dir::Down },
        ratio: half as f64 / n as f64,
        a: Box::new(tree(first, half, depth + 1)),
        b: Box::new(tree(first + half, n - half, depth + 1)),
    }
}

fn per_call(mut f: impl FnMut()) -> f64 {
    // Warm up, then the best of 5 runs of enough calls to take about 20 ms.
    for _ in 0..1000 {
        f();
    }
    let start = Instant::now();
    let mut calls = 0u64;
    while start.elapsed().as_millis() < 20 {
        f();
        calls += 1;
    }
    let mut best = f64::MAX;
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..calls {
            f();
        }
        best = best.min(start.elapsed().as_nanos() as f64 / calls as f64);
    }
    best
}

#[test]
#[ignore = "a timed measurement: run it in release with --ignored"]
fn the_check_costs_a_constant_per_rect_at_each_commit() {
    // Small enough panes that 256 fit: no minimum clamps the timing.
    let style = SplitStyle { divider: 1.0, min_width: 2.0, min_height: 2.0 };
    let (w, h, scale) = (3840.0 / 2.0, 2160.0 / 2.0, 2.0);
    println!("panes  rects  layout_ns  solve_ns  check_ns  check_ns_per_rect");
    for n in [1u64, 4, 16, 64, 256] {
        let node = tree(1, n, 0);
        let mut solver = SplitSolver::new();
        let layout = per_call(|| {
            black_box(solver.layout(black_box(&node), w, h, &style, scale));
        });
        let solve = per_call(|| {
            black_box(solver.solve(black_box(&node), w, h, &style, scale));
        });
        let shown = solver.layout(&node, w, h, &style, scale).clone();
        let tiled: Vec<RectPt> =
            shown.panes.iter().map(|p| p.1).chain(shown.dividers.iter().copied()).collect();
        let mut checker = Checker::new();
        let frame = Frame { width: w, height: h, scale, tiled: &tiled, floating: &[] };
        assert_eq!(checker.check(&frame), Ok(()));
        let check = per_call(|| {
            black_box(checker.check(black_box(&frame)).is_ok());
        });
        println!(
            "{n:5}  {:5}  {layout:9.0}  {solve:8.0}  {check:8.0}  {:17.1}",
            tiled.len(),
            check / tiled.len() as f64
        );
    }
}
