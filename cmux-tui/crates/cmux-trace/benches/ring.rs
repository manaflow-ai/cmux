//! The overhead of a Rust trace point (p09-observability-090, done check 3 of
//! plans/cmux-next/chrome-parity/p09-observability.md: a write at most 40 ns p99): a point whose
//! category is off, a black-box write on one thread and on 8 threads at once, a write through a
//! [`Writer`] (the ring alone, no thread-local lookup), and a `trace_scope!` open and close. Each
//! case prints its ns per operation at p50 and p99 and asserts that it makes no heap allocation.
//!
//! Chrome measures its trace macros the same way, as a perf test that prints numbers and gates
//! nothing. No criterion (std and libc only): a fixed warm-up, then batches of [`BATCH`]
//! operations timed as a whole on the trace clock, so the clock read is amortized; the
//! percentiles are of the per-operation time of each batch.
//!
//! `cargo bench -p cmux-trace --bench ring` runs it; under `cargo test --all-targets` (no
//! `--bench` argument) it only says so and exits.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::hint::black_box;
use std::sync::Barrier;

use cmux_trace::clock::now_ns;
use cmux_trace::{
    Phase, Record, Role, ThreadIdentity, Tracer, TracerConfig, Writer, trace_instant, trace_scope,
};

/// Counts the allocations of the calling thread only.
struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.realloc(ptr, layout, new_size) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn allocations() -> usize {
    ALLOCATIONS.with(Cell::get)
}

const BATCH: usize = 64;
const BATCHES: usize = 20_000;
const WARM_BATCHES: usize = 500;
const THREADS: usize = 8;

/// One case's numbers.
struct Numbers {
    name: String,
    /// Nanoseconds per operation, one per batch, sorted.
    nanos: Vec<f64>,
    threads: usize,
    allocations: usize,
}

impl Numbers {
    fn percentile(&self, quantile: f64) -> f64 {
        let last = self.nanos.len().saturating_sub(1);
        self.nanos.get(((last as f64) * quantile + 0.5) as usize).copied().unwrap_or(0.0)
    }

    fn print(&self, extra: &str) {
        println!(
            "trace-bench (rust): {}: p50 {:.2} ns, p99 {:.2} ns, max {:.1} ns ({} threads x {BATCHES} batches of {BATCH}); allocations {}{extra}",
            self.name,
            self.percentile(0.50),
            self.percentile(0.99),
            self.nanos.last().copied().unwrap_or(0.0),
            self.threads,
            self.allocations,
        );
    }
}

/// Times `count` batches of `operation` into `samples` (raw batch nanoseconds).
#[inline(always)]
fn time_batches(count: usize, samples: &mut [u64], mut operation: impl FnMut(u64)) {
    let mut index = 0u64;
    for sample in 0..count {
        let start = now_ns();
        for _ in 0..BATCH {
            operation(black_box(index));
            index = index.wrapping_add(1);
        }
        samples[sample % samples.len()] = now_ns().wrapping_sub(start);
    }
}

/// Sorted nanoseconds per operation.
fn per_operation(samples: &[u64]) -> Vec<f64> {
    let mut nanos: Vec<f64> = samples.iter().map(|&batch| batch as f64 / BATCH as f64).collect();
    nanos.sort_by(f64::total_cmp);
    nanos
}

/// Times `operation` on the calling thread; the allocations are the timed batches' only.
fn run(name: &str, mut operation: impl FnMut(u64)) -> Numbers {
    let mut samples = vec![0u64; BATCHES];
    time_batches(WARM_BATCHES, &mut samples, &mut operation);
    let before = allocations();
    time_batches(BATCHES, &mut samples, &mut operation);
    let allocations = allocations() - before;
    Numbers { name: name.to_owned(), nanos: per_operation(&samples), threads: 1, allocations }
}

/// Times `operation(thread, index)` on [`THREADS`] threads that start their timed batches together.
fn run_contended(name: &str, operation: impl Fn(usize, u64) + Sync) -> Numbers {
    let start = Barrier::new(THREADS);
    let (samples, allocations) = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..THREADS)
            .map(|thread| {
                let (start, operation) = (&start, &operation);
                scope.spawn(move || {
                    let mut samples = vec![0u64; BATCHES];
                    // The thread's first write registers it in the ring: warm before counting.
                    time_batches(WARM_BATCHES, &mut samples, |index| operation(thread, index));
                    start.wait();
                    let before = allocations();
                    time_batches(BATCHES, &mut samples, |index| operation(thread, index));
                    (samples, allocations() - before)
                })
            })
            .collect();
        let mut all = Vec::with_capacity(BATCHES * THREADS);
        let mut allocations = 0;
        for handle in handles {
            let (samples, counted) = handle.join().expect("a bench thread panicked");
            all.extend(samples);
            allocations += counted;
        }
        (all, allocations)
    });
    Numbers { name: name.to_owned(), nanos: per_operation(&samples), threads: THREADS, allocations }
}

fn assert_no_allocation(numbers: &Numbers) {
    assert_eq!(numbers.allocations, 0, "{} allocated", numbers.name);
}

fn main() {
    if !std::env::args().any(|argument| argument == "--bench") {
        println!("cmux-trace ring bench: run it with `cargo bench -p cmux-trace --bench ring`");
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-trace-bench-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("bench directory");
    // The black box records BLACKBOX (daemon on, frame off), in its file, as in a real process.
    cmux_trace::init_blackbox(&dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    assert!(cmux_trace::enabled(cmux_trace::category::DAEMON));
    assert!(!cmux_trace::enabled(cmux_trace::category::FRAME));

    let mut results = Vec::new();

    results.push(run("disabled point", |index| {
        trace_instant!(frame, "frame.sequence", index);
    }));
    results.push(run("disabled scope", |index| {
        let _scope = trace_scope!(frame, "frame.sequence", index);
    }));

    let single = run("black-box write, 1 thread", |index| {
        trace_instant!(daemon, "daemon.request.parsed", index);
    });
    let contended = run_contended("black-box write, 8 threads", |thread, index| {
        trace_instant!(daemon, "daemon.request.parsed", thread as u64, index);
    });

    results.push(run("scope open and close", |index| {
        let _scope = trace_scope!(daemon, "daemon.request", index);
    }));

    // The ring alone: a Writer on its own tracer's heap ring, no thread-local lookup.
    let tracer = Tracer::new(TracerConfig::for_process(&dir, Role::Daemon));
    let mut writer = Writer::new(&tracer, ThreadIdentity::new(1, 0, "bench"));
    results.push(run("Writer::write, heap ring", |index| {
        writer.write(Record {
            t_ns: now_ns(),
            name: 44,
            phase: Phase::Instant,
            flags: 0,
            arg0: index,
            arg1: 0,
        });
    }));
    drop(writer);

    for numbers in &results {
        numbers.print("");
    }
    single.print("");
    let ratio = contended.percentile(0.99) / single.percentile(0.99).max(0.001);
    contended.print(&format!("; p99 / 1-thread p99 = {ratio:.2}"));

    let _ = std::fs::remove_dir_all(&dir);
    for numbers in results.iter().chain([&single, &contended]) {
        assert_no_allocation(numbers);
    }
}
