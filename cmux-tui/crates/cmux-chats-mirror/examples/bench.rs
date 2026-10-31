//! Times the mirror on a recorded-shape fixture: `cargo run --release --example bench -- DIR`
//! with DIR holding `page.json` (one `_acpmux/chats_watch` page line) and `changes.jsonl`.
//! Prints parse (off main) and apply (main) times and the mirror's heap.

use cmux_chats_mirror::{Feed, Line};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicIsize, Ordering};
use std::time::Instant;

struct Counting;
static LIVE: AtomicIsize = AtomicIsize::new(0);

// SAFETY: forwards to the system allocator and only counts bytes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn stats(mut values: Vec<f64>) -> (f64, f64) {
    values.sort_by(f64::total_cmp);
    let p95 = values[((values.len() as f64 * 0.95) as usize).min(values.len() - 1)];
    (values[values.len() / 2], p95)
}

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| ".".into());
    let page = std::fs::read(format!("{dir}/page.json")).expect("page.json");
    let changes = std::fs::read_to_string(format!("{dir}/changes.jsonl")).expect("changes.jsonl");

    let mut parse = Vec::new();
    for _ in 0..10 {
        let started = Instant::now();
        let line = Line::parse(&page).expect("a page");
        parse.push(started.elapsed().as_secs_f64() * 1e3);
        drop(line);
    }
    let before = LIVE.load(Ordering::Relaxed);
    let mut feed = Feed::new();
    let line = Line::parse(&page).expect("a page");
    let started = Instant::now();
    feed.apply([line]);
    let page_apply = started.elapsed().as_secs_f64() * 1e6;
    let heap = LIVE.load(Ordering::Relaxed) - before;

    let mut change_parse = Vec::new();
    let mut lines = Vec::new();
    for text in changes.lines() {
        let started = Instant::now();
        let line = Line::parse(text.as_bytes());
        change_parse.push(started.elapsed().as_secs_f64() * 1e6);
        lines.extend(line);
    }
    let mut apply = Vec::new();
    for line in lines {
        let started = Instant::now();
        feed.apply([line]);
        apply.push(started.elapsed().as_secs_f64() * 1e6);
    }
    let total: f64 = apply.iter().sum::<f64>() / 1e3;
    let mut newest = Vec::new();
    for _ in 0..200 {
        let started = Instant::now();
        let _ = feed.index().listed().take(24).cloned().collect::<Vec<_>>();
        newest.push(started.elapsed().as_secs_f64() * 1e6);
    }
    let mut projects = Vec::new();
    for _ in 0..20 {
        let started = Instant::now();
        let _ = serde_json::to_vec(&feed.index().projects());
        projects.push(started.elapsed().as_secs_f64() * 1e3);
    }
    let (parse_median, parse_p95) = stats(parse);
    let (cp_median, cp_p95) = stats(change_parse);
    let (apply_median, apply_p95) = stats(apply);
    let (newest_median, _) = stats(newest);
    let (projects_median, _) = stats(projects);
    println!("rust chats={} page_bytes={}", feed.index().len(), page.len());
    println!("page_parse_ms median={parse_median:.2} p95={parse_p95:.2} (off main)");
    println!("page_apply_us={page_apply:.1} (main) mirror_heap_bytes={heap}");
    println!("change_parse_us median={cp_median:.1} p95={cp_p95:.1} (off main)");
    println!("apply_us median={apply_median:.2} p95={apply_p95:.2} total_ms={total:.2} (main)");
    println!("listed24_us median={newest_median:.1} projects_ms median={projects_median:.2}");
}
