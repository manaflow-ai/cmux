use super::*;
use std::alloc::System;

/// The tables are the process's own: one test at a time.
static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[inline(never)]
fn grow_by_site(heap: &Sampled<System>, n: usize, size: usize) -> Vec<*mut u8> {
    let layout = Layout::from_size_align(size, 8).unwrap();
    // SAFETY: a nonzero layout; each block is freed with it below.
    (0..n).map(|_| unsafe { heap.alloc(layout) }).collect()
}

fn free_all(heap: &Sampled<System>, blocks: &[*mut u8], size: usize) {
    let layout = Layout::from_size_align(size, 8).unwrap();
    for &p in blocks {
        // SAFETY: allocated by `grow_by_site` with this layout.
        unsafe { heap.dealloc(p, layout) };
    }
}

#[test]
fn off_records_nothing() {
    let _s = serial();
    start(MIN_RATE);
    stop();
    let heap = Sampled(System);
    let blocks = grow_by_site(&heap, 32, 64 * 1024);
    let r = report(5);
    free_all(&heap, &blocks, 64 * 1024);
    assert_eq!(r["on"], false);
    assert_eq!(r["liveBlocks"], 0, "{r}");
    assert_eq!(r["stacks"], 0, "{r}");
}

#[test]
fn held_bytes_follow_allocs_and_frees_by_stack() {
    let _s = serial();
    let heap = Sampled(System);
    let size = 64 * 1024;
    // Blocks above the rate are each recorded (bar the thread's first, which draws its interval).
    assert_eq!(start(1), MIN_RATE, "the rate has a floor");
    let blocks = grow_by_site(&heap, 64, size);
    let held = report(5);
    let live = held["liveBytes"].as_u64().unwrap();
    assert!((63 * size as u64..=64 * size as u64).contains(&live), "{held}");
    assert_eq!(held["droppedSlots"], 0);
    let top = &held["byLive"][0];
    assert_eq!(top["liveBytes"].as_u64(), Some(live), "one site holds it all: {held}");
    let frames: Vec<&str> =
        top["frames"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(
        frames.first().is_some_and(|f| !f.starts_with("<acpmux::heap_sample::Sampled")),
        "the sampler's own frames are left off: {frames:?}"
    );
    assert!(frames.iter().any(|f| f.contains("grow_by_site")), "the site is named: {frames:?}");

    free_all(&heap, &blocks[..32], size);
    let half = report(5)["liveBytes"].as_u64().unwrap();
    assert!((31 * size as u64..=32 * size as u64).contains(&half), "{half}");
    free_all(&heap, &blocks[32..], size);
    let after = report(5);
    stop();
    assert_eq!(after["liveBytes"], 0, "{after}");
    assert_eq!(after["byLive"].as_array().map(Vec::len), Some(0), "{after}");
    assert!(after["byTotal"][0]["totalBytes"].as_u64().unwrap() >= live, "{after}");
}

#[test]
fn realloc_moves_the_record_to_the_new_size() {
    let _s = serial();
    let heap = Sampled(System);
    start(MIN_RATE);
    let small = Layout::from_size_align(64 * 1024, 8).unwrap();
    // SAFETY: nonzero layouts; the block is freed with its last size.
    unsafe {
        let warm = heap.alloc(small);
        let p = heap.alloc(small);
        let q = heap.realloc(p, small, 256 * 1024);
        // `warm`, the thread's first allocation, only draws the interval; `p` is recorded, and
        // the realloc moves its record to the new block's size.
        let live = report(1)["liveBytes"].as_u64().unwrap();
        assert_eq!(live, 256 * 1024);
        heap.dealloc(q, Layout::from_size_align(256 * 1024, 8).unwrap());
        heap.dealloc(warm, small);
    }
    let after = report(1)["liveBytes"].as_u64().unwrap();
    stop();
    assert_eq!(after, 0);
}

#[test]
fn a_stack_interns_once_and_a_slot_takes_back_once() {
    let _s = serial();
    start(MIN_RATE);
    stop();
    let a = intern(&[1, 2, 3]).unwrap();
    assert_eq!(intern(&[1, 2, 3]), Some(a));
    assert_ne!(intern(&[1, 2, 4]), Some(a));
    assert_ne!(intern(&[1, 2]), Some(a));
    ON.store(true, Ordering::SeqCst);
    assert!(insert_slot(0x1000, 4096, a));
    STACK_TABLE[a as usize].live_bytes.store(4096, Ordering::Relaxed);
    STACK_TABLE[a as usize].live_blocks.store(1, Ordering::Relaxed);
    on_free(0x1000 as *mut u8);
    on_free(0x1000 as *mut u8);
    on_free(0x2000 as *mut u8);
    stop();
    assert_eq!(STACK_TABLE[a as usize].live_bytes.load(Ordering::Relaxed), 0);
    assert_eq!(STACK_TABLE[a as usize].live_blocks.load(Ordering::Relaxed), 0);
}

#[test]
fn intervals_average_the_rate() {
    let rate = 512 * 1024;
    let n = 4000;
    let sum: i64 = (0..n).map(|_| next_interval(rate) as i64).sum();
    let mean = sum / n;
    assert!((rate as i64 * 9 / 10..=rate as i64 * 11 / 10).contains(&mean), "{mean}");
    assert!((0..1000).all(|_| (1..2 * rate as isize).contains(&next_interval(rate))));
}

#[test]
fn request_starts_reports_and_stops() {
    let _s = serial();
    let r = request(&json!({"start": 8192, "top": 3}));
    assert_eq!(r["on"], true);
    assert_eq!(r["rate"], 8192);
    assert!(r["byLive"].is_array() && r["byTotal"].is_array());
    #[cfg(target_os = "linux")]
    assert!(r["mappings"]["rssKib"].as_u64().unwrap() > 0, "{r}");
    let r = request(&json!({"stop": true}));
    assert_eq!(r["on"], false);
    assert_eq!(r["rate"], 8192);
}
