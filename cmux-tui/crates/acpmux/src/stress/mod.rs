//! Synthetic stress: break the daemon's stores fast and repeatedly, and fail on growth.
//!
//! Leo, 2026-11-10: "I hate soaks ... synthetically just break it fast and repeatedly ... under
//! constraint, under load, under degenerate cases. And then you repeat it until it gets good."
//!
//! No test here waits for wall time. Thousands of chats or deliveries go in at once, a day of
//! history is written with its own timestamps (compressed time), restarts and torn writes come
//! in the middle of the work, and each run measures what one more operation costs:
//!
//! - bytes written by this thread (`/proc/thread-self/io`, so tests running beside it don't
//!   count), the class of `acpmux::hub::outbox::Outbox::save` rewriting a whole file per change
//!   (cmuxterm-hq#8660);
//! - bytes left on disk;
//! - open file descriptors and resident memory, in a child process of this test binary that runs
//!   one test alone ([`isolated`]), since both are process-wide.
//!
//! A check fails when the cost of one operation grows with the size around it (the god size over
//! the small size past [`GOD_OVER_SMALL`]) or when a resource keeps growing after warm-up (a
//! positive slope past the stated noise band). Run: `cargo test -p acpmux --lib stress::`.
//!
//! Time is ticked, not waited for: [`reconnect`] runs a peer's whole reconnect loop through a day
//! and more of outage under tokio's paused clock, with the wall clock following it
//! (`store::test_clock::follow_tokio`) and a seeded jitter, so hours of backoff take
//! milliseconds and a seed replays a run draw for draw.

mod outbox;
mod reconnect;
mod store;

use std::path::Path;

/// A per-operation cost may be this much more at the god size than at the small size.
pub(crate) const GOD_OVER_SMALL: f64 = 1.2;

/// Bytes this thread has passed to `write` and its relatives so far (`wchar`). None off Linux.
pub(crate) fn thread_written() -> Option<u64> {
    let text = std::fs::read_to_string("/proc/thread-self/io").ok()?;
    io_field(&text, "wchar")
}

fn io_field(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(':').map(str::trim))
        .and_then(|v| v.parse().ok())
}

/// Open file descriptors of this process. None off Linux.
pub(crate) fn open_fds() -> Option<usize> {
    std::fs::read_dir("/proc/self/fd").ok().map(|d| d.count())
}

/// Resident memory of this process in bytes. None off Linux.
pub(crate) fn rss_bytes() -> Option<u64> {
    let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
    let pages: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
    // SAFETY: sysconf has no preconditions.
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    Some(pages * u64::try_from(page).ok()?)
}

/// Bytes of every file under `dir`.
pub(crate) fn disk_bytes(dir: &Path) -> u64 {
    let mut total = 0;
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        total += if meta.is_dir() { disk_bytes(&entry.path()) } else { meta.len() };
    }
    total
}

/// The growth per sample of `ys` over their index, robust to one step (a pool the allocator
/// grows once, a compaction): the median of the slopes between every two samples (Theil-Sen).
/// A leak raises every pair's slope, so it raises the median; one step raises only the pairs
/// that straddle it.
pub(crate) fn slope(ys: &[f64]) -> f64 {
    let mut pairs = Vec::new();
    for (i, a) in ys.iter().enumerate() {
        for (j, b) in ys.iter().enumerate().skip(i + 1) {
            pairs.push((b - a) / (j - i) as f64);
        }
    }
    if pairs.is_empty() {
        return 0.0;
    }
    pairs.sort_by(f64::total_cmp);
    let mid = pairs.len() / 2;
    if !pairs.len().is_multiple_of(2) { pairs[mid] } else { (pairs[mid - 1] + pairs[mid]) / 2.0 }
}

/// The least-squares slope of `ys` over their index (printed beside the robust one).
pub(crate) fn mean_slope(ys: &[f64]) -> f64 {
    let n = ys.len() as f64;
    if ys.len() < 2 {
        return 0.0;
    }
    let mean_x = (n - 1.0) / 2.0;
    let mean_y = ys.iter().sum::<f64>() / n;
    let (mut num, mut den) = (0.0, 0.0);
    for (i, y) in ys.iter().enumerate() {
        let dx = i as f64 - mean_x;
        num += dx * (y - mean_y);
        den += dx * dx;
    }
    num / den
}

/// Fails when the per-operation cost at the god size is over [`GOD_OVER_SMALL`] times the
/// small size's, plus `floor` (fixed costs such as a line's own id, which a bigger fixture
/// names with more digits).
#[track_caller]
pub(crate) fn assert_flat_with_size(what: &str, small: f64, god: f64, floor: f64) {
    eprintln!("STRESS {what}: small={small:.1} god={god:.1} ratio={:.2}", god / small.max(1.0));
    assert!(
        god <= small * GOD_OVER_SMALL + floor,
        "{what}: one operation costs {god:.1} at the god size and {small:.1} at the small size \
         (over {GOD_OVER_SMALL}x): its cost grows with what is already there"
    );
}

/// Fails when `samples` (one per round, after warm-up) grow by more than `band` per round.
#[track_caller]
pub(crate) fn assert_no_growth(what: &str, samples: &[f64], band: f64) {
    let s = slope(samples);
    let mean = mean_slope(samples);
    eprintln!(
        "STRESS {what}: slope={s:.1}/round (least squares {mean:.1}) band={band:.1} samples={samples:?}"
    );
    assert!(s <= band, "{what} grows {s:.1} per round after warm-up (band {band:.1}): {samples:?}");
}

/// Runs test `name` (its full path) alone in a child process of this test binary, so the
/// process-wide meters (fds, memory) see only it. The child runs with `ACPMUX_STRESS_CHILD`
/// set; the test body returns at once without it.
pub(crate) fn isolated(name: &str) {
    if !cfg!(target_os = "linux") {
        return;
    }
    let exe = std::env::current_exe().unwrap();
    let out = std::process::Command::new(exe)
        .args([name, "--exact", "--test-threads=1", "--nocapture"])
        .env("ACPMUX_STRESS_CHILD", "1")
        .output()
        .unwrap();
    let text =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    for line in text.lines().filter(|l| l.starts_with("STRESS ")) {
        eprintln!("{line}");
    }
    assert!(out.status.success() && text.contains("1 passed"), "{name} failed alone:\n{text}");
}

/// Whether this process is the child [`isolated`] started.
pub(crate) fn in_child() -> bool {
    std::env::var_os("ACPMUX_STRESS_CHILD").is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slope_is_the_growth_per_sample() {
        assert!((slope(&[1.0, 2.0, 3.0, 4.0]) - 1.0).abs() < 1e-9);
        assert!(slope(&[5.0, 5.0, 5.0]).abs() < 1e-9);
        assert!(slope(&[4.0, 3.0, 2.0]) < 0.0);
        // One step (a pool grown once) is not growth; a steady climb is.
        assert!(slope(&[10.0, 20.0, 20.0, 20.0, 20.0, 20.0]).abs() < 1e-9);
        assert!((slope(&[10.0, 11.0, 12.0, 13.0, 14.0, 15.0]) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn io_field_reads_wchar() {
        let text = "rchar: 10\nwchar: 2048\nsyscr: 1\n";
        assert_eq!(io_field(text, "wchar"), Some(2048));
        assert_eq!(io_field(text, "rchar"), Some(10));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn thread_written_counts_this_threads_writes_only() {
        let dir = tempfile::tempdir().unwrap();
        let before = thread_written().unwrap();
        // Another thread's writes are not this thread's.
        let p = dir.path().join("other");
        std::thread::spawn(move || std::fs::write(p, vec![0u8; 1 << 20]).unwrap()).join().unwrap();
        let mid = thread_written().unwrap();
        std::fs::write(dir.path().join("mine"), vec![0u8; 4096]).unwrap();
        let after = thread_written().unwrap();
        assert!(mid - before < 4096, "{before} {mid}");
        assert!(after - mid >= 4096, "{mid} {after}");
    }
}
