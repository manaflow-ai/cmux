//! What one publish costs, at the image sizes a window produces: run with
//! `cargo test -p cmux-launch-image --release --test publish_cost -- --ignored --nocapture`.
//! The store knows windows, never workspaces, so the cost depends on the image's bytes and the
//! window count (capped at 16), not on how many workspaces the session has.

use cmux_launch_image::{Caps, Store};
use std::path::PathBuf;
use std::time::Instant;

fn png(width: u32, height: u32, len: usize) -> Vec<u8> {
    let mut bytes = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    bytes.extend_from_slice(&13_u32.to_be_bytes());
    bytes.extend_from_slice(b"IHDR");
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    // Incompressible filler, like a real PNG's deflate stream.
    let mut x = 0x2545_f491_4f6c_dd1d_u64;
    while bytes.len() < len {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    bytes.truncate(len);
    bytes
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

#[test]
#[ignore = "a measurement, not a check"]
fn publish_cost() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("launch-image-cost-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for (label, windows, bytes) in [
        ("1 window, 1.5 MiB", 1, 1_572_864),
        ("1 window, 6 MiB", 1, 6 << 20),
        ("16 windows, 1.5 MiB", 16, 1_572_864),
    ] {
        let store = Store::new(&dir, Caps::default());
        let image = png(2880, 1800, bytes);
        let mut ms = Vec::new();
        for round in 0..30 {
            for w in 0..windows {
                let start = Instant::now();
                store.publish(&format!("win-{w}"), &image).unwrap();
                if round > 0 {
                    ms.push(start.elapsed().as_secs_f64() * 1e3);
                }
            }
        }
        ms.sort_by(f64::total_cmp);
        let on_disk: u64 = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .map(|e| e.metadata().unwrap().len())
            .sum();
        println!(
            "PUBLISH {label}: n={} p50 {:.2} ms p95 {:.2} ms max {:.2} ms; bytes written per publish {bytes}; folder after {on_disk} bytes",
            ms.len(),
            percentile(&ms, 0.5),
            percentile(&ms, 0.95),
            ms[ms.len() - 1]
        );
        let start = Instant::now();
        for _ in 0..1000 {
            assert!(store.current("win-0").is_some());
        }
        println!(
            "CURRENT {label}: {:.1} us per read",
            start.elapsed().as_secs_f64() * 1e6 / 1000.0
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
