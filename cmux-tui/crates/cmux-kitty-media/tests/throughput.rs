//! Throughput on output with no Kitty file commands, against the copy the
//! PTY reader makes anyway (`to_vec` of each 64 KiB read).
//!
//! `cargo test --release -p cmux-kitty-media --test throughput -- --ignored --nocapture`

use std::hint::black_box;
use std::time::{Duration, Instant};

use cmux_kitty_media::KittyMediaRewriter;

const READ: usize = 64 * 1024;
const TOTAL: usize = 1 << 30;

fn workloads() -> Vec<(&'static str, Vec<u8>)> {
    let yes: Vec<u8> = b"y\n".iter().copied().cycle().take(READ).collect();
    let colored: Vec<u8> = b"\x1b[01;34mdirectory\x1b[0m  \x1b[01;32mexec\x1b[0m  plain.txt\r\n"
        .iter()
        .copied()
        .cycle()
        .take(READ)
        .collect();
    let escapes: Vec<u8> =
        b"\x1b[H\x1b[2J\x1b[38;5;196mx\x1b_Xapc\x1b\\".iter().copied().cycle().take(READ).collect();
    vec![("yes", yes), ("ls --color", colored), ("escape-dense", escapes)]
}

fn time(mut run: impl FnMut()) -> Duration {
    let mut best = Duration::MAX;
    for _ in 0..5 {
        let start = Instant::now();
        run();
        best = best.min(start.elapsed());
    }
    best
}

#[test]
#[ignore = "benchmark; run in release with --ignored"]
fn non_graphics_throughput_overhead() {
    for (name, read) in workloads() {
        let reads = TOTAL / read.len();
        let baseline = time(|| {
            for _ in 0..reads {
                black_box(black_box(&read[..]).to_vec());
            }
        });
        let mut rewriter = KittyMediaRewriter::new();
        let rewritten = time(|| {
            for _ in 0..reads {
                let mut out = Vec::with_capacity(read.len());
                rewriter.rewrite(black_box(&read[..]), &mut out);
                black_box(out);
            }
        });
        // The local reader parses the read in place: its baseline is no copy.
        let mut scratch = Vec::new();
        let borrowed = time(|| {
            for _ in 0..reads {
                black_box(rewriter.rewrite_borrowed(black_box(&read[..]), &mut scratch).len());
            }
        });
        let gib = TOTAL as f64 / f64::from(1u32 << 30);
        println!(
            "{name:>13}: copy {:.2} GiB/s, rewrite {:.2} GiB/s (+{:.3} ns/byte), borrowed scan {:.2} GiB/s ({:.3} ns/byte)",
            gib / baseline.as_secs_f64(),
            gib / rewritten.as_secs_f64(),
            (rewritten.as_secs_f64() - baseline.as_secs_f64()) * 1e9 / TOTAL as f64,
            gib / borrowed.as_secs_f64(),
            borrowed.as_secs_f64() * 1e9 / TOTAL as f64,
        );
    }
}
