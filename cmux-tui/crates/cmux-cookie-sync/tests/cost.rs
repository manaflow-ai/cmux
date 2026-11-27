//! What one scan costs on a synthetic store of 3000 cookies over 400 hosts
//! (a heavy browsing profile): wall and thread CPU time per scan, and the
//! memory a kept fingerprint holds. Prints the numbers (run with
//! `--nocapture`); the bounds only catch a gross regression.

mod common;

use cmux_cookie_sync::engine::measure;
use common::{MODERN, create};
use rusqlite::params;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

// SAFETY: forwards to the system allocator; only counts.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let now = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
        PEAK.fetch_max(now, Ordering::Relaxed);
        // SAFETY: the caller's layout.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        // SAFETY: allocated above with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

#[test]
fn scan_cost_of_3000_cookies_over_400_hosts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Cookies");
    let conn = create(&path, MODERN);
    conn.execute_batch("BEGIN").unwrap();
    for n in 0..3000u32 {
        let host = format!(".site{}.example.com", n % 400);
        let encrypted: Vec<u8> = (0..120u32).map(|i| (i.wrapping_mul(31) ^ n) as u8).collect();
        conn.execute(
            "INSERT INTO cookies VALUES(?1, ?2, '', ?3, '', ?4, '/', 13400000000000000, 1, 1, ?1, 1, 1, 1, 1, 2, 443, ?1, 0, 0)",
            params![13_300_000_000_000_000i64 + i64::from(n), host, format!("cookie_{n}"), encrypted],
        )
        .unwrap();
    }
    conn.execute_batch("COMMIT").unwrap();
    drop(conn);
    let file_kb = std::fs::metadata(&path).unwrap().len() / 1024;

    let mut wall = Vec::new();
    let mut cpu = Vec::new();
    let mut kept = 0;
    let mut peak = 0;
    for _ in 0..7 {
        let before = LIVE.load(Ordering::Relaxed);
        PEAK.store(before, Ordering::Relaxed);
        let (scan, cost) = measure(&path);
        let scan = scan.unwrap();
        assert_eq!((scan.rows, scan.fingerprint.len()), (3000, 400));
        kept = LIVE.load(Ordering::Relaxed).saturating_sub(before);
        peak = PEAK.load(Ordering::Relaxed).saturating_sub(before).max(peak);
        wall.push(cost.scan_ms);
        cpu.extend(cost.cpu_ms);
    }
    wall.sort_by(f64::total_cmp);
    cpu.sort_by(f64::total_cmp);
    let median = |v: &[f64]| v.get(v.len() / 2).copied().unwrap_or(f64::NAN);
    println!(
        "cookie-sync scan cost: 3000 cookies, 400 hosts, {file_kb} KiB store; scan_ms median {:.2} (min {:.2}, max {:.2}); \
         cpu_ms median {:.2}; fingerprint kept {kept} bytes; peak heap during a scan {} KiB",
        median(&wall),
        wall.first().unwrap(),
        wall.last().unwrap(),
        median(&cpu),
        peak / 1024,
    );
    assert!(median(&wall) < 5000.0);
    assert!(kept < 256 * 1024, "the fingerprint is per host, not per cookie: {kept} bytes");
}
