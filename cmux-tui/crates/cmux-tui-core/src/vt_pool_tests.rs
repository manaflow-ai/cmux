//! The VT pool (p01-process-120): runs in order, at most one per terminal,
//! a wake during a run runs it again, a flood yields after one slice, a
//! blocking call moves the shard's other terminals to a new thread, and an
//! owner's shards end after its last terminal.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;

const WAIT: Duration = Duration::from_secs(10);

fn one_shard(slice: SliceBudget) -> VtPool {
    VtPool::new(VtPoolConfig { shards: 1, slice })
}

/// A source that reports each run and how its run ends.
struct Probe {
    runs: Sender<&'static str>,
    name: &'static str,
    /// Runs left before it ends.
    left: usize,
    finished: Arc<AtomicBool>,
}

impl VtSource for Probe {
    fn run(&mut self, _: &mut Slice) -> VtFlow {
        let _ = self.runs.send(self.name);
        self.left = self.left.saturating_sub(1);
        if self.left == 0 { VtFlow::Finished } else { VtFlow::Idle }
    }

    fn finish(self: Box<Self>) {
        self.finished.store(true, Ordering::Release);
    }
}

fn probe(name: &'static str, left: usize) -> (Probe, Receiver<&'static str>, Arc<AtomicBool>) {
    let (runs, received) = mpsc::channel();
    let finished = Arc::new(AtomicBool::new(false));
    (Probe { runs, name, left, finished: finished.clone() }, received, finished)
}

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        std::thread::yield_now();
    }
}

#[test]
fn a_registered_terminal_runs_only_when_woken_and_finishes_once() {
    let pool = one_shard(SliceBudget::DEFAULT);
    let (source, runs, finished) = probe("a", 2);
    let wake = pool.register(Box::new(source)).map_err(drop).unwrap();
    assert!(runs.recv_timeout(Duration::from_millis(50)).is_err(), "ran before a wake");
    wake.wake();
    assert_eq!(runs.recv_timeout(WAIT), Ok("a"));
    assert!(!finished.load(Ordering::Acquire));
    wake.wake();
    assert_eq!(runs.recv_timeout(WAIT), Ok("a"));
    wait_for("the terminal finished", || finished.load(Ordering::Acquire));
    wait_for("the finished terminal left the pool", || pool.sources() == 0);
    // A wake after the end runs nothing.
    wake.wake();
    assert!(runs.recv_timeout(Duration::from_millis(50)).is_err());
}

/// A source whose first run wakes itself (output came while it parsed):
/// it runs once more after that run, never twice at once.
struct WakesItself {
    wake: Arc<Mutex<Option<VtWake>>>,
    running: Arc<AtomicBool>,
    runs: Sender<usize>,
    count: usize,
}

impl VtSource for WakesItself {
    fn run(&mut self, _: &mut Slice) -> VtFlow {
        assert!(!self.running.swap(true, Ordering::AcqRel), "two runs at once");
        self.count += 1;
        if self.count == 1
            && let Some(wake) = self.wake.lock().unwrap().as_ref()
        {
            wake.wake();
            wake.wake();
        }
        let _ = self.runs.send(self.count);
        self.running.store(false, Ordering::Release);
        VtFlow::Idle
    }

    fn finish(self: Box<Self>) {}
}

#[test]
fn a_wake_during_a_run_runs_the_terminal_once_more_after_it() {
    let pool = one_shard(SliceBudget::DEFAULT);
    let slot = Arc::new(Mutex::new(None));
    let (runs, received) = mpsc::channel();
    let source = WakesItself {
        wake: slot.clone(),
        running: Arc::new(AtomicBool::new(false)),
        runs,
        count: 0,
    };
    let wake = pool.register(Box::new(source)).map_err(drop).unwrap();
    *slot.lock().unwrap() = Some(wake.clone());
    wake.wake();
    assert_eq!(received.recv_timeout(WAIT), Ok(1));
    assert_eq!(received.recv_timeout(WAIT), Ok(2), "the wake during the run was lost");
    assert!(received.recv_timeout(Duration::from_millis(50)).is_err(), "two wakes, one more run");
}

/// Prints without end: each run parses chunks until its slice is spent.
/// Another terminal of its shard gets output after the first chunk of each
/// slice: the flood wakes it there (the holder link's DATA for it).
struct Flood {
    chunks: Arc<AtomicUsize>,
    echo: Arc<Mutex<Option<VtWake>>>,
    woken: Sender<usize>,
}

const CHUNK: usize = 16 * 1024;
const CHUNKS_PER_SLICE: usize = 4;

impl VtSource for Flood {
    fn run(&mut self, slice: &mut Slice) -> VtFlow {
        loop {
            let parsed = self.chunks.fetch_add(1, Ordering::AcqRel) + 1;
            slice.charge(CHUNK);
            if parsed % CHUNKS_PER_SLICE == 1
                && let Some(echo) = self.echo.lock().unwrap().as_ref()
            {
                let _ = self.woken.send(parsed);
                echo.wake();
            }
            if slice.spent() {
                return VtFlow::Yield;
            }
        }
    }

    fn finish(self: Box<Self>) {}
}

/// Reports the flood's chunk count when it runs.
struct Echo {
    chunks: Arc<AtomicUsize>,
    ran: Sender<usize>,
}

impl VtSource for Echo {
    fn run(&mut self, _: &mut Slice) -> VtFlow {
        let _ = self.ran.send(self.chunks.load(Ordering::Acquire));
        VtFlow::Idle
    }

    fn finish(self: Box<Self>) {}
}

/// A flood in one terminal delays a chunk of another terminal of its shard
/// by at most one slice: the flood finishes its slice and goes to the back
/// of the queue, behind the other terminal.
#[test]
fn a_flood_delays_another_terminal_of_its_shard_by_at_most_one_slice() {
    let slice = SliceBudget { bytes: CHUNKS_PER_SLICE * CHUNK, time: Duration::from_secs(60) };
    let pool = one_shard(slice);
    let chunks = Arc::new(AtomicUsize::new(0));
    let echo_slot = Arc::new(Mutex::new(None));
    let (woken, wakes) = mpsc::channel();
    let flood = Flood { chunks: chunks.clone(), echo: echo_slot.clone(), woken };
    let flood = pool.register(Box::new(flood)).map_err(drop).unwrap();
    let (ran, echoes) = mpsc::channel();
    let echo = pool.register(Box::new(Echo { chunks, ran })).map_err(drop).unwrap();
    *echo_slot.lock().unwrap() = Some(echo);
    flood.wake();
    for _ in 0..100 {
        let woken = wakes.recv_timeout(WAIT).expect("the flood ran a slice");
        let parsed = echoes.recv_timeout(WAIT).expect("the echo ran");
        // Woken at the slice's first chunk: the rest of that slice, no more.
        assert!(
            parsed - woken < CHUNKS_PER_SLICE,
            "the echo waited {} flood chunks",
            parsed - woken
        );
    }
    echo_slot.lock().unwrap().take();
}

/// Time bounds a slice too: a run that never reaches the byte budget still
/// yields once its time is spent, and the byte budget ends a slice whose
/// time is not.
#[test]
fn a_slice_ends_at_its_bytes_or_its_time() {
    let mut slice = Slice::start(SliceBudget { bytes: usize::MAX, time: Duration::ZERO });
    slice.charge(1);
    assert!(slice.spent(), "a spent time budget ends the slice");
    let mut slice = Slice::start(SliceBudget { bytes: SLICE_BYTES, time: Duration::from_secs(60) });
    slice.charge(SLICE_BYTES - 1);
    assert!(!slice.spent());
    slice.charge(1);
    assert!(slice.spent());
    assert_eq!(SliceBudget::DEFAULT, SliceBudget { bytes: 64 * 1024, time: SLICE_TIME });
    assert_eq!(SLICE_TIME, Duration::from_millis(1));
}

/// Blocks inside `will_block` until released.
struct Blocks {
    entered: Sender<()>,
    release: Arc<Mutex<Option<Receiver<()>>>>,
}

impl VtSource for Blocks {
    fn run(&mut self, _: &mut Slice) -> VtFlow {
        let release = self.release.lock().unwrap().take();
        will_block(|| {
            let _ = self.entered.send(());
            if let Some(release) = release {
                let _ = release.recv_timeout(WAIT);
            }
        });
        VtFlow::Idle
    }

    fn finish(self: Box<Self>) {}
}

/// A terminal whose run waits (a query answer to a child that does not
/// read) holds only its own thread: the other terminals of its shard run
/// meanwhile, and it runs again after the wait.
#[test]
fn a_blocking_run_never_holds_up_the_other_terminals_of_its_shard() {
    let pool = one_shard(SliceBudget::DEFAULT);
    let (entered, blocked) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let blocking = Blocks { entered, release: Arc::new(Mutex::new(Some(released))) };
    let stuck = pool.register(Box::new(blocking)).map_err(drop).unwrap();
    let (other, runs, _) = probe("other", usize::MAX);
    let other = pool.register(Box::new(other)).map_err(drop).unwrap();
    stuck.wake();
    blocked.recv_timeout(WAIT).expect("the run blocked");
    for _ in 0..3 {
        other.wake();
        assert_eq!(runs.recv_timeout(WAIT), Ok("other"), "the shard waited for the blocked run");
    }
    release.send(()).unwrap();
    // Handed back to the shard: it runs again (and does not block now).
    wait_for("the blocked terminal went idle", || stuck.phase.load(Ordering::Acquire) == IDLE);
    stuck.wake();
    blocked.recv_timeout(WAIT).expect("the blocked terminal ran again after its wait");
    other.wake();
    assert_eq!(runs.recv_timeout(WAIT), Ok("other"));
}

/// Terminals spread over the shards, and a dropped owner's shards end with
/// its last terminal, which still finishes.
#[test]
fn terminals_spread_over_the_shards_and_outlive_a_dropped_owner() {
    let pool = VtPool::new(VtPoolConfig { shards: 3, slice: SliceBudget::DEFAULT });
    let mut wakes = Vec::new();
    let mut ends = Vec::new();
    for _ in 0..6 {
        let (source, runs, finished) = probe("t", 1);
        wakes.push(pool.register(Box::new(source)).map_err(drop).unwrap());
        ends.push((runs, finished));
    }
    assert_eq!(pool.started_shards(), 3);
    drop(pool);
    for wake in &wakes {
        wake.wake();
    }
    for (runs, finished) in &ends {
        assert_eq!(runs.recv_timeout(WAIT), Ok("t"));
        wait_for("a terminal of a dropped owner finished", || finished.load(Ordering::Acquire));
    }
}

/// `perf-hot: vt-pool-dispatch`: one holder-link wake of a terminal, both
/// while its run is queued (no send) and from idle (one send).
#[test]
#[ignore = "bench: cargo test -p cmux-tui-core --release --lib -- vt_pool_dispatch_bench --ignored --nocapture"]
fn vt_pool_dispatch_bench() {
    const WAKES: u32 = 1_000_000;
    let pool = one_shard(SliceBudget::DEFAULT);
    let (source, runs, _) = probe("bench", usize::MAX);
    let wake = pool.register(Box::new(source)).map_err(drop).unwrap();
    // Queued: a run is pending, so a wake only reads the phase.
    wake.phase.store(QUEUED, Ordering::Release);
    let started = Instant::now();
    for _ in 0..WAKES {
        wake.wake();
    }
    let queued = started.elapsed() / WAKES;
    wake.phase.store(IDLE, Ordering::Release);
    let mut idle = Duration::ZERO;
    for _ in 0..10_000 {
        wait_for("the run went idle", || wake.phase.load(Ordering::Acquire) == IDLE);
        let started = Instant::now();
        wake.wake();
        idle += started.elapsed();
        runs.recv_timeout(WAIT).expect("the woken run");
    }
    eprintln!("vt-pool-dispatch: queued {queued:?}/wake, idle {:?}/wake", idle / 10_000);
}
