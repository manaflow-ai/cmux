//! A sampled heap profile of the running daemon, by allocation site, in the shipped build: no
//! ptrace, no profiler build, no restart. The global allocator is [`Sampled`] around the one the
//! build ships (mimalloc on musl Linux, the system's elsewhere). Off, each allocation and free
//! costs one relaxed load. On (`acpmux daemon heap-dump --start`, or [`RATE_ENV`] at start), about
//! one allocation per `rate` bytes records its stack, and a free of a recorded block takes it
//! back, so [`report`] answers the bytes held now by each stack: what grows, and where.
//!
//! Nothing here allocates on the allocation path: the recorded blocks and stacks live in fixed
//! tables (zero pages until profiling touches them), the stack is walked without a lock or a
//! buffer (`backtrace::trace_unsynchronized`), and a thread already inside the sampler takes no
//! second sample. The tables are bounded; what does not fit is counted as dropped.
//!
//! Each recorded block stands for `max(size, rate)` bytes (one sample per `rate` bytes on
//! average, the interval drawn from [1, 2*rate)), so a stack's estimate is unbiased for small
//! blocks and exact for blocks at or above the rate.

use std::alloc::{GlobalAlloc, Layout};
use std::cell::Cell;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};

use serde_json::{Value, json};

/// Bytes between samples to start with at daemon start (e.g. `524288`); unset or 0: off.
pub const RATE_ENV: &str = "ACPMUX_HEAP_SAMPLE_BYTES";
/// The rate `--start` uses without a value: 512 KiB, jemalloc's default.
pub const DEFAULT_RATE: usize = 512 * 1024;
const MIN_RATE: usize = 4 * 1024;
const FRAMES: usize = 32;
const STACKS: usize = 1 << 13;
const SLOTS: usize = 1 << 17;
const PROBES: usize = 64;
const EMPTY: usize = 0;
const TOMB: usize = 1;

static ON: AtomicBool = AtomicBool::new(false);
static RATE: AtomicUsize = AtomicUsize::new(DEFAULT_RATE);
static STARTED_MS: AtomicU64 = AtomicU64::new(0);
static DROPPED_SLOTS: AtomicU64 = AtomicU64::new(0);
static DROPPED_STACKS: AtomicU64 = AtomicU64::new(0);
static STACK_LOCK: Mutex<()> = Mutex::new(());

struct Stack {
    hash: AtomicU64,
    depth: AtomicU32,
    frames: [AtomicUsize; FRAMES],
    live_bytes: AtomicU64,
    live_blocks: AtomicU64,
    total_bytes: AtomicU64,
    total_blocks: AtomicU64,
}

impl Stack {
    const fn new() -> Self {
        Self {
            hash: AtomicU64::new(0),
            depth: AtomicU32::new(0),
            frames: [const { AtomicUsize::new(0) }; FRAMES],
            live_bytes: AtomicU64::new(0),
            live_blocks: AtomicU64::new(0),
            total_bytes: AtomicU64::new(0),
            total_blocks: AtomicU64::new(0),
        }
    }
}

struct Slot {
    ptr: AtomicUsize,
    weight: AtomicU64,
    stack: AtomicU32,
}

static STACK_TABLE: [Stack; STACKS] = [const { Stack::new() }; STACKS];
static SLOT_TABLE: [Slot; SLOTS] = [const {
    Slot { ptr: AtomicUsize::new(EMPTY), weight: AtomicU64::new(0), stack: AtomicU32::new(0) }
}; SLOTS];

thread_local! {
    static UNTIL: Cell<isize> = const { Cell::new(0) };
    static BUSY: Cell<bool> = const { Cell::new(false) };
    static SEED: Cell<u64> = const { Cell::new(0) };
}

/// The build's allocator `A`, sampled while profiling is on.
pub struct Sampled<A>(pub A);

// SAFETY: every call goes to `A` unchanged; the sampler only reads the returned pointers and
// writes its own static tables.
unsafe impl<A: GlobalAlloc> GlobalAlloc for Sampled<A> {
    #[inline]
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller's contract, passed on.
        let p = unsafe { self.0.alloc(layout) };
        if ON.load(Ordering::Relaxed) && !p.is_null() {
            on_alloc(p, layout.size());
        }
        p
    }

    #[inline]
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller's contract, passed on.
        let p = unsafe { self.0.alloc_zeroed(layout) };
        if ON.load(Ordering::Relaxed) && !p.is_null() {
            on_alloc(p, layout.size());
        }
        p
    }

    #[inline]
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if ON.load(Ordering::Relaxed) {
            on_free(ptr);
        }
        // SAFETY: the caller's contract, passed on.
        unsafe { self.0.dealloc(ptr, layout) }
    }

    #[inline]
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // Taken back before the old block can be freed and its address reused by another thread.
        let on = ON.load(Ordering::Relaxed);
        if on {
            on_free(ptr);
        }
        // SAFETY: the caller's contract, passed on.
        let p = unsafe { self.0.realloc(ptr, layout, new_size) };
        if on && !p.is_null() {
            on_alloc(p, new_size);
        }
        p
    }
}

/// Starts sampling one allocation per about `rate` bytes (at least 4 KiB), clearing what an
/// earlier profile recorded. Returns the rate in use.
pub fn start(rate: usize) -> usize {
    let rate = rate.max(MIN_RATE);
    let _busy = Busy::enter();
    ON.store(false, Ordering::SeqCst);
    let _lock = STACK_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    for slot in &SLOT_TABLE {
        slot.ptr.store(EMPTY, Ordering::Relaxed);
    }
    for stack in &STACK_TABLE {
        stack.hash.store(0, Ordering::Relaxed);
        stack.live_bytes.store(0, Ordering::Relaxed);
        stack.live_blocks.store(0, Ordering::Relaxed);
        stack.total_bytes.store(0, Ordering::Relaxed);
        stack.total_blocks.store(0, Ordering::Relaxed);
    }
    DROPPED_SLOTS.store(0, Ordering::Relaxed);
    DROPPED_STACKS.store(0, Ordering::Relaxed);
    RATE.store(rate, Ordering::Relaxed);
    STARTED_MS.store(now_ms(), Ordering::Relaxed);
    ON.store(true, Ordering::SeqCst);
    rate
}

/// Stops sampling; what was recorded stays for [`report`] until the next [`start`].
pub fn stop() {
    ON.store(false, Ordering::SeqCst);
}

/// Starts at daemon start when [`RATE_ENV`] names a rate. The variable is removed, so a process
/// this one starts profiles only if asked itself.
///
/// # Safety
/// Called while no other thread runs (it removes an environment variable).
pub unsafe fn start_from_env() {
    let Some(value) = std::env::var_os(RATE_ENV) else {
        return;
    };
    // SAFETY: the caller's: no other thread runs.
    unsafe { std::env::remove_var(RATE_ENV) };
    if let Some(rate) = value.to_str().and_then(|v| v.trim().parse::<usize>().ok())
        && rate > 0
    {
        start(rate);
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Marks this thread as inside the sampler, so its own allocations take no sample.
struct Busy(bool);

impl Busy {
    fn enter() -> Self {
        Self(BUSY.try_with(|b| !b.replace(true)).unwrap_or(false))
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        if self.0 {
            let _ = BUSY.try_with(|b| b.set(false));
        }
    }
}

fn next_interval(rate: usize) -> isize {
    let x = SEED
        .try_with(|s| {
            let mut x = s.get();
            if x == 0 {
                x = (s as *const Cell<u64> as u64) ^ now_ms() ^ 0x9e37_79b9_7f4a_7c15;
            }
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            s.set(x);
            x
        })
        .unwrap_or(0x2545_f491_4f6c_dd1d);
    let span = (rate as u64).saturating_mul(2).max(2);
    isize::try_from(1 + x % (span - 1)).unwrap_or(isize::MAX)
}

#[inline]
fn on_alloc(p: *mut u8, size: usize) {
    let rate = RATE.load(Ordering::Relaxed);
    let take = UNTIL
        .try_with(|c| {
            let left = c.get();
            if left == 0 {
                c.set(next_interval(rate));
                return false;
            }
            let left = left.saturating_sub(isize::try_from(size).unwrap_or(isize::MAX));
            if left > 0 {
                c.set(left);
                false
            } else {
                c.set(next_interval(rate));
                true
            }
        })
        .unwrap_or(false);
    if take {
        record(p as usize, size, rate);
    }
}

#[cold]
#[inline(never)]
fn record(ptr: usize, size: usize, rate: usize) {
    let busy = Busy::enter();
    if !busy.0 {
        return;
    }
    let mut frames = [0usize; FRAMES];
    let mut depth = 0usize;
    // SAFETY: no lock is held across it and nothing it calls back allocates: the callback writes
    // a local array.
    unsafe {
        backtrace::trace_unsynchronized(|frame| {
            if let Some(slot) = frames.get_mut(depth) {
                *slot = frame.ip() as usize;
                depth += 1;
            }
            depth < FRAMES
        });
    }
    let Some(stack) = intern(&frames[..depth]) else {
        DROPPED_STACKS.fetch_add(1, Ordering::Relaxed);
        return;
    };
    let weight = size.max(rate) as u64;
    if !insert_slot(ptr, weight, stack) {
        DROPPED_SLOTS.fetch_add(1, Ordering::Relaxed);
        return;
    }
    let entry = &STACK_TABLE[stack as usize];
    entry.live_bytes.fetch_add(weight, Ordering::Relaxed);
    entry.live_blocks.fetch_add(1, Ordering::Relaxed);
    entry.total_bytes.fetch_add(weight, Ordering::Relaxed);
    entry.total_blocks.fetch_add(1, Ordering::Relaxed);
}

fn mix(mut x: u64) -> u64 {
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
    x ^= x >> 33;
    x = x.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    x ^ (x >> 33)
}

fn intern(frames: &[usize]) -> Option<u32> {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for &f in frames {
        hash = mix(hash ^ f as u64);
    }
    let hash = hash.max(1);
    let _lock = STACK_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let start = (hash as usize) & (STACKS - 1);
    for i in 0..PROBES {
        let idx = (start + i) & (STACKS - 1);
        let entry = &STACK_TABLE[idx];
        let h = entry.hash.load(Ordering::Relaxed);
        if h == 0 {
            for (dst, &src) in entry.frames.iter().zip(frames) {
                dst.store(src, Ordering::Relaxed);
            }
            entry.depth.store(frames.len() as u32, Ordering::Relaxed);
            entry.hash.store(hash, Ordering::Release);
            return u32::try_from(idx).ok();
        }
        if h == hash
            && entry.depth.load(Ordering::Relaxed) as usize == frames.len()
            && entry.frames.iter().zip(frames).all(|(a, &b)| a.load(Ordering::Relaxed) == b)
        {
            return u32::try_from(idx).ok();
        }
    }
    None
}

fn slot_start(ptr: usize) -> usize {
    (mix(ptr as u64) as usize) & (SLOTS - 1)
}

fn insert_slot(ptr: usize, weight: u64, stack: u32) -> bool {
    let start = slot_start(ptr);
    for i in 0..PROBES {
        let slot = &SLOT_TABLE[(start + i) & (SLOTS - 1)];
        let cur = slot.ptr.load(Ordering::Relaxed);
        if (cur == EMPTY || cur == TOMB)
            && slot.ptr.compare_exchange(cur, ptr, Ordering::AcqRel, Ordering::Relaxed).is_ok()
        {
            slot.weight.store(weight, Ordering::Release);
            slot.stack.store(stack, Ordering::Release);
            return true;
        }
    }
    false
}

#[inline]
fn on_free(ptr: *mut u8) {
    let ptr = ptr as usize;
    let start = slot_start(ptr);
    for i in 0..PROBES {
        let slot = &SLOT_TABLE[(start + i) & (SLOTS - 1)];
        let cur = slot.ptr.load(Ordering::Acquire);
        if cur == EMPTY {
            return;
        }
        if cur == ptr {
            let weight = slot.weight.load(Ordering::Acquire);
            let stack = slot.stack.load(Ordering::Acquire) as usize;
            if slot.ptr.compare_exchange(ptr, TOMB, Ordering::AcqRel, Ordering::Relaxed).is_ok()
                && let Some(entry) = STACK_TABLE.get(stack)
            {
                // Saturating: a free racing a restart's clear must not wrap a stack's count.
                let _ = entry.live_bytes.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                    Some(v.saturating_sub(weight))
                });
                let _ = entry.live_blocks.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                    Some(v.saturating_sub(1))
                });
            }
            return;
        }
    }
}

/// Frames of the allocator and the sampler itself, left off the top of each stack.
fn is_alloc_frame(name: &str) -> bool {
    const PREFIXES: [&str; 8] = [
        "acpmux::heap_sample",
        "<acpmux::heap_sample",
        "backtrace::",
        "__rust_",
        "__rdl_",
        "alloc::alloc::",
        "<alloc::alloc::",
        "std::alloc::",
    ];
    PREFIXES.iter().any(|p| name.starts_with(p)) && !name.contains("heap_sample::tests::")
}

/// The profile now: whether sampling is on, its rate, the estimated bytes held by the recorded
/// stacks, and the `top` stacks by bytes held (each symbolized in place, its frames' addresses
/// relative to the executable's load address beside), plus the `top` by bytes allocated since
/// start. Symbolizing allocates; this thread takes no sample meanwhile.
pub fn report(top: usize) -> Value {
    let _busy = Busy::enter();
    let top = top.clamp(1, 200);
    let mut live_total = 0u64;
    let mut live_blocks = 0u64;
    let mut stacks = 0usize;
    let mut rows: Vec<(usize, u64, u64, u64, u64)> = Vec::new();
    for (idx, entry) in STACK_TABLE.iter().enumerate() {
        if entry.hash.load(Ordering::Acquire) == 0 {
            continue;
        }
        stacks += 1;
        let live = entry.live_bytes.load(Ordering::Relaxed);
        let blocks = entry.live_blocks.load(Ordering::Relaxed);
        live_total = live_total.saturating_add(live);
        live_blocks = live_blocks.saturating_add(blocks);
        rows.push((
            idx,
            live,
            blocks,
            entry.total_bytes.load(Ordering::Relaxed),
            entry.total_blocks.load(Ordering::Relaxed),
        ));
    }
    let base = exe_base();
    let row = |&(idx, live, blocks, total, total_blocks): &(usize, u64, u64, u64, u64)| {
        let entry = &STACK_TABLE[idx];
        let depth = (entry.depth.load(Ordering::Relaxed) as usize).min(FRAMES);
        let ips: Vec<usize> =
            entry.frames.iter().take(depth).map(|f| f.load(Ordering::Relaxed)).collect();
        let (frames, offsets) = symbolize(&ips, base);
        json!({
            "liveBytes": live,
            "liveBlocks": blocks,
            "totalBytes": total,
            "totalBlocks": total_blocks,
            "frames": frames,
            "offsets": offsets,
        })
    };
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    let by_live: Vec<Value> = rows.iter().filter(|r| r.1 > 0).take(top).map(&row).collect();
    rows.sort_by(|a, b| b.3.cmp(&a.3));
    let by_total: Vec<Value> = rows.iter().take(top.min(20)).map(&row).collect();
    json!({
        "on": ON.load(Ordering::Relaxed),
        "rate": RATE.load(Ordering::Relaxed),
        "startedAtMs": STARTED_MS.load(Ordering::Relaxed),
        "liveBytes": live_total,
        "liveBlocks": live_blocks,
        "stacks": stacks,
        "droppedSlots": DROPPED_SLOTS.load(Ordering::Relaxed),
        "droppedStacks": DROPPED_STACKS.load(Ordering::Relaxed),
        "exeBase": base.map(|b| format!("{b:#x}")),
        "byLive": by_live,
        "byTotal": by_total,
        "mappings": mappings(8),
    })
}

/// Each frame's demangled name (with file:line where the binary has them), the allocator's own
/// frames left off the top, and every frame's address relative to the executable.
fn symbolize(ips: &[usize], base: Option<usize>) -> (Vec<String>, Vec<String>) {
    let mut names = Vec::new();
    let mut offsets = Vec::new();
    let mut top = true;
    for &ip in ips {
        let mut name: Option<String> = None;
        backtrace::resolve(ip as *mut std::ffi::c_void, |sym| {
            if name.is_some() {
                return;
            }
            let mut s = sym.name().map(|n| format!("{n:#}")).unwrap_or_else(|| "?".to_owned());
            if let (Some(file), Some(line)) = (sym.filename(), sym.lineno()) {
                s.push_str(&format!(" ({}:{line})", file.display()));
            }
            name = Some(s);
        });
        let name = name.unwrap_or_else(|| "?".to_owned());
        if top && is_alloc_frame(&name) {
            continue;
        }
        top = false;
        offsets.push(match base {
            Some(b) if ip >= b => format!("{:#x}", ip - b),
            _ => format!("{ip:#x}"),
        });
        names.push(name);
    }
    (names, offsets)
}

/// The executable's load address (its first mapping in `/proc/self/maps`), for symbolizing the
/// offsets offline against the same build.
#[cfg(target_os = "linux")]
fn exe_base() -> Option<usize> {
    let exe = std::fs::read_link("/proc/self/exe").ok()?;
    let exe = exe.to_str()?.to_owned();
    let maps = std::fs::read_to_string("/proc/self/maps").ok()?;
    let line = maps.lines().find(|l| l.ends_with(exe.as_str()))?;
    let start = line.split('-').next()?;
    usize::from_str_radix(start, 16).ok()
}

#[cfg(not(target_os = "linux"))]
fn exe_base() -> Option<usize> {
    None
}

/// The `n` mappings holding the most resident bytes (`/proc/self/smaps`), with the process's
/// totals: whether the resident set is the allocator's heap, thread stacks or files.
#[cfg(target_os = "linux")]
fn mappings(n: usize) -> Value {
    let Ok(smaps) = std::fs::read_to_string("/proc/self/smaps") else {
        return Value::Null;
    };
    let mut rows: Vec<(u64, u64, String)> = Vec::new();
    let (mut rss_total, mut anon_total, mut count) = (0u64, 0u64, 0u64);
    let mut head: Option<String> = None;
    let (mut rss, mut anon) = (0u64, 0u64);
    let kib =
        |l: &str| l.split_whitespace().nth(1).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    let mut flush = |head: &mut Option<String>, rss: &mut u64, anon: &mut u64| {
        if let Some(h) = head.take() {
            count += 1;
            rss_total += *rss;
            anon_total += *anon;
            rows.push((*rss, *anon, h));
        }
        *rss = 0;
        *anon = 0;
    };
    for line in smaps.lines() {
        let first = line.split_whitespace().next().unwrap_or("");
        if first.contains('-') && !first.ends_with(':') {
            flush(&mut head, &mut rss, &mut anon);
            let mut parts = line.split_whitespace();
            let range = parts.next().unwrap_or("");
            let perms = parts.next().unwrap_or("");
            let path = parts.nth(3).unwrap_or("[anon]");
            let size = range
                .split_once('-')
                .and_then(|(a, b)| {
                    Some(u64::from_str_radix(b, 16).ok()? - u64::from_str_radix(a, 16).ok()?)
                })
                .unwrap_or(0);
            head = Some(format!("{range} {perms} {} MiB {path}", size >> 20));
        } else if line.starts_with("Rss:") {
            rss = kib(line);
        } else if line.starts_with("Anonymous:") {
            anon = kib(line);
        }
    }
    flush(&mut head, &mut rss, &mut anon);
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    let top: Vec<Value> = rows
        .iter()
        .take(n)
        .map(|(rss, anon, h)| json!({"rssKib": rss, "anonKib": anon, "mapping": h}))
        .collect();
    json!({"count": count, "rssKib": rss_total, "anonKib": anon_total, "top": top})
}

#[cfg(not(target_os = "linux"))]
fn mappings(_n: usize) -> Value {
    Value::Null
}

/// `_acpmux/heap_profile` with `sample`: `{"start": BYTES}` (0 or absent: [`DEFAULT_RATE`]),
/// `{"stop": true}`, or neither (report only); each answers the report with `top` stacks.
pub fn request(sample: &Value) -> Value {
    if let Some(rate) = sample.get("start") {
        let rate = rate.as_u64().and_then(|r| usize::try_from(r).ok()).filter(|r| *r > 0);
        start(rate.unwrap_or(DEFAULT_RATE));
    }
    if sample.get("stop").and_then(Value::as_bool) == Some(true) {
        stop();
    }
    let top = sample.get("top").and_then(Value::as_u64).unwrap_or(20);
    report(usize::try_from(top).unwrap_or(20))
}

#[cfg(test)]
#[path = "heap_sample_tests.rs"]
mod tests;
