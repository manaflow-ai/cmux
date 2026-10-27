use super::*;

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, AtomicUsize};
use std::sync::mpsc;

/// What a [`Recorder`] saw, in call order.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Call {
    Parse { offset: u64, len: usize },
    Confirm(u64),
    Publish,
}

/// A terminal that counts its confirms and frames, checks it is never run
/// by two threads at once, and can keep its calls and bytes, log each call
/// to a channel, spin for a parse cost, or hold its parse until a test lets
/// it go.
struct Recorder {
    id: VtTerminalId,
    keep: bool,
    calls: Mutex<Vec<Call>>,
    bytes: Mutex<Vec<u8>>,
    confirmed: AtomicU64,
    publishes: AtomicUsize,
    /// The threads that parsed it.
    threads: Mutex<HashSet<String>>,
    busy: AtomicBool,
    overlapped: AtomicBool,
    log: Option<mpsc::Sender<(VtTerminalId, Call, Instant)>>,
    gate: Option<Mutex<mpsc::Receiver<()>>>,
    /// CPU time each parse call spins for.
    cost: Duration,
}

impl Recorder {
    fn new(id: VtTerminalId) -> Arc<Self> {
        Arc::new(Self::plain(id))
    }

    fn plain(id: VtTerminalId) -> Self {
        Self {
            id,
            keep: true,
            calls: Mutex::new(Vec::new()),
            bytes: Mutex::new(Vec::new()),
            confirmed: AtomicU64::new(0),
            publishes: AtomicUsize::new(0),
            threads: Mutex::new(HashSet::new()),
            busy: AtomicBool::new(false),
            overlapped: AtomicBool::new(false),
            log: None,
            gate: None,
            cost: Duration::ZERO,
        }
    }

    /// A terminal that keeps nothing and logs every call to `log`.
    fn logged(id: VtTerminalId, log: &mpsc::Sender<(VtTerminalId, Call, Instant)>) -> Self {
        Self { keep: false, log: Some(log.clone()), ..Self::plain(id) }
    }

    fn threads(&self) -> HashSet<String> {
        self.threads.lock().unwrap().clone()
    }

    fn calls(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }

    fn publishes(&self) -> usize {
        self.publishes.load(Ordering::SeqCst)
    }

    fn confirmed(&self) -> u64 {
        self.confirmed.load(Ordering::SeqCst)
    }

    fn record(&self, call: Call, at: Instant) {
        if let Some(log) = &self.log {
            let _ = log.send((self.id, call.clone(), at));
        }
        if self.keep {
            self.calls.lock().unwrap().push(call);
        }
    }
}

impl VtTerminal for Recorder {
    fn parse(&self, offset: u64, bytes: &[u8]) {
        let began = Instant::now();
        if let Some(name) = std::thread::current().name() {
            self.threads.lock().unwrap().insert(name.to_owned());
        }
        if self.busy.swap(true, Ordering::SeqCst) {
            self.overlapped.store(true, Ordering::SeqCst);
        }
        if let Some(gate) = &self.gate {
            let _ = gate.lock().unwrap().recv();
        }
        while began.elapsed() < self.cost {
            std::hint::spin_loop();
        }
        if self.keep {
            self.bytes.lock().unwrap().extend_from_slice(bytes);
        }
        self.record(Call::Parse { offset, len: bytes.len() }, began);
        self.busy.store(false, Ordering::SeqCst);
    }

    fn confirm_parsed(&self, end: u64) {
        self.record(Call::Confirm(end), Instant::now());
        self.confirmed.fetch_max(end, Ordering::SeqCst);
    }

    fn publish(&self) {
        self.record(Call::Publish, Instant::now());
        self.publishes.fetch_add(1, Ordering::SeqCst);
    }
}

fn config(visible: usize, hidden: usize) -> VtPoolConfig {
    VtPoolConfig {
        visible_threads: visible,
        hidden_threads: hidden,
        max_pending_bytes: 128 * 1024 * 1024,
        ..VtPoolConfig::for_performance_cores(8)
    }
}

fn pattern(offset: u64, len: usize) -> Vec<u8> {
    (0..len as u64).map(|i| ((offset + i) % 251) as u8).collect()
}

/// Waits (test only) until `done` holds.
fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::yield_now();
    }
}

#[test]
fn group_sizes_follow_the_performance_cores() {
    let sizes = |p| {
        let config = VtPoolConfig::for_performance_cores(p);
        (config.visible_threads, config.hidden_threads)
    };
    assert_eq!(sizes(0), (1, 1));
    assert_eq!(sizes(2), (1, 1));
    assert_eq!(sizes(4), (2, 1));
    assert_eq!(sizes(6), (3, 1));
    assert_eq!(sizes(8), (4, 2));
    assert_eq!(sizes(16), (4, 2));
    let host = VtPoolConfig::host();
    assert!((1..=MAX_VISIBLE_THREADS).contains(&host.visible_threads));
    assert!((1..=MAX_HIDDEN_THREADS).contains(&host.hidden_threads));
}

#[test]
fn groups_run_at_their_qos_under_their_names() {
    assert_eq!(VtGroup::Visible.thread_type().qos(), cmux_threads::ThreadQos::UserInitiated);
    assert_eq!(VtGroup::Hidden.thread_type().qos(), cmux_threads::ThreadQos::Utility);
    assert_eq!(VtGroup::Visible.thread_name(3), "vt-pool-v-3");
    assert_eq!(VtGroup::Hidden.thread_name(0), "vt-pool-h-0");

    let pool = VtPool::start(config(2, 1)).unwrap();
    let expected = [
        ("vt-pool-v-0", cmux_threads::ThreadQos::UserInitiated),
        ("vt-pool-v-1", cmux_threads::ThreadQos::UserInitiated),
        ("vt-pool-h-0", cmux_threads::ThreadQos::Utility),
    ];
    // A thread joins the registry as it starts.
    wait_until("the pool threads registered", || {
        let threads = cmux_threads::snapshot();
        expected.iter().all(|(name, qos)| {
            threads.iter().any(|thread| thread.name == *name && thread.declared == *qos)
        })
    });
    assert_eq!(pool.stats().threads, [2, 1]);
}

#[test]
fn bytes_are_parsed_in_order_in_slices_and_confirmed() {
    let pool = VtPool::start(config(2, 1)).unwrap();
    let terminal = Recorder::new(1);
    pool.register(1, terminal.clone(), VtGroup::Visible, 100).unwrap();
    let mut offset = 100;
    for len in [1, 70_000, 3, 200_000] {
        pool.push(1, offset, pattern(offset, len)).unwrap();
        offset += len as u64;
    }
    wait_until("all bytes confirmed", || terminal.confirmed() == offset);

    assert_eq!(*terminal.bytes.lock().unwrap(), pattern(100, (offset - 100) as usize));
    let mut expected = 100;
    let mut since_confirm = 0;
    for call in terminal.calls() {
        match call {
            Call::Parse { offset, len } => {
                assert_eq!(offset, expected, "bytes out of order");
                assert!(len <= STEP_BYTES);
                expected += len as u64;
                since_confirm += len;
                assert!(since_confirm <= SLICE_BYTES, "a slice parsed more than {SLICE_BYTES}");
            }
            Call::Confirm(end) => {
                assert_eq!(end, expected);
                since_confirm = 0;
            }
            Call::Publish => {}
        }
    }
    assert!(!terminal.overlapped.load(Ordering::SeqCst));
}

#[test]
fn a_push_that_skips_or_overruns_is_refused() {
    let pool = VtPool::start(VtPoolConfig { max_pending_bytes: 10, ..config(1, 1) }).unwrap();
    let terminal = Recorder::new(7);
    assert_eq!(pool.push(7, 0, vec![1]), Err(VtPoolError::UnknownTerminal(7)));
    pool.register(7, terminal.clone(), VtGroup::Hidden, 5).unwrap();
    assert_eq!(
        pool.register(7, terminal.clone(), VtGroup::Hidden, 5),
        Err(VtPoolError::AlreadyRegistered(7))
    );
    assert_eq!(pool.push(7, 6, vec![1]), Err(VtPoolError::Gap { id: 7, expected: 5, offset: 6 }));
    assert_eq!(
        pool.push(7, 5, vec![0; 11]),
        Err(VtPoolError::Full { id: 7, pending: 11, limit: 10 })
    );
    pool.push(7, 5, vec![0; 10]).unwrap();
    wait_until("the bytes confirmed", || terminal.confirmed() == 15);
}

#[test]
fn a_hidden_terminal_parses_without_frames_and_publishes_once_when_shown() {
    let pool = VtPool::start(config(1, 1)).unwrap();
    let terminal = Recorder::new(2);
    pool.register(2, terminal.clone(), VtGroup::Hidden, 0).unwrap();
    let mut offset = 0;
    for _ in 0..20 {
        pool.push(2, offset, pattern(offset, 50_000)).unwrap();
        offset += 50_000;
    }
    wait_until("hidden bytes confirmed", || terminal.confirmed() == offset);
    assert_eq!(terminal.publishes(), 0, "a hidden terminal did frame work");

    pool.set_group(2, VtGroup::Visible).unwrap();
    wait_until("one publish after show", || terminal.publishes() == 1);
    // Nothing new to show: hiding and showing again publishes nothing.
    pool.set_group(2, VtGroup::Hidden).unwrap();
    pool.set_group(2, VtGroup::Visible).unwrap();
    pool.push(2, offset, vec![b'x']).unwrap();
    wait_until("the next byte confirmed", || terminal.confirmed() == offset + 1);
    wait_until("its frame", || terminal.publishes() == 2);
    assert_eq!(pool.stats().runnable, [0, 0]);
}

#[test]
fn moving_between_groups_during_a_flood_keeps_offset_order() {
    let pool = VtPool::start(config(4, 2)).unwrap();
    let terminals: Vec<Arc<Recorder>> = (0..4).map(Recorder::new).collect();
    for terminal in &terminals {
        pool.register(terminal.id, terminal.clone(), VtGroup::Hidden, 0).unwrap();
    }
    let mut offset = 0;
    for round in 0..200 {
        for terminal in &terminals {
            pool.push(terminal.id, offset, pattern(offset, 9_000)).unwrap();
            let group =
                if (round + terminal.id) % 2 == 0 { VtGroup::Visible } else { VtGroup::Hidden };
            pool.set_group(terminal.id, group).unwrap();
        }
        offset += 9_000;
    }
    for terminal in &terminals {
        wait_until("every byte confirmed", || terminal.confirmed() == offset);
        assert_eq!(*terminal.bytes.lock().unwrap(), pattern(0, offset as usize));
        assert!(!terminal.overlapped.load(Ordering::SeqCst), "two threads parsed one terminal");
    }
}

/// The acceptance row: a 64 MiB flood delays a visible chunk by at most one
/// slice. Hidden, the flood runs on the hidden thread and never on the
/// visible one. Shown, it shares the one visible thread, and at most one
/// flood slice ends between the echo's push and its parse: the one running
/// (or just requeued from the hidden thread) when the echo was pushed.
#[test]
fn a_64_mib_flood_delays_a_visible_chunk_by_at_most_one_slice() {
    const FLOOD: usize = 64 * 1024 * 1024;
    let (log, seen) = mpsc::channel();
    let pool = VtPool::start(config(1, 1)).unwrap();
    // About 1 ms per slice, so the flood outlasts the test.
    let flood =
        Arc::new(Recorder { cost: Duration::from_micros(250), ..Recorder::logged(1, &log) });
    pool.register(1, flood.clone(), VtGroup::Hidden, 0).unwrap();
    pool.register(2, Arc::new(Recorder::logged(2, &log)), VtGroup::Visible, 0).unwrap();
    pool.push(1, 0, pattern(0, FLOOD)).unwrap();
    wait_until("the flood to start", || flood.confirmed() > 0);

    let mut echo_offset = 0;
    for shown in [false, true] {
        if shown {
            pool.set_group(1, VtGroup::Visible).unwrap();
            wait_until("the flood on the visible thread", || flood.publishes() > 0);
        }
        for _ in 0..20 {
            pool.push(2, echo_offset, vec![b'k']).unwrap();
            let pushed = Instant::now();
            echo_offset += 1;
            let mut slices_ahead = 0;
            loop {
                let (id, call, at) = seen.recv_timeout(Duration::from_secs(10)).unwrap();
                match (id, call) {
                    (2, Call::Parse { .. }) => {
                        // A slice is about 1 ms; the whole flood about 1 s.
                        let waited = at.duration_since(pushed);
                        assert!(waited < Duration::from_millis(50), "echo waited {waited:?}");
                        break;
                    }
                    (1, Call::Confirm(_)) if at > pushed => slices_ahead += 1,
                    _ => {}
                }
            }
            if shown {
                assert!(slices_ahead <= 1, "the echo waited for {slices_ahead} flood slices");
            }
        }
        if !shown {
            assert_eq!(flood.publishes(), 0, "the hidden flood ran on the visible thread");
        }
    }
    assert!(flood.confirmed() < FLOOD as u64, "the flood ended before the test measured it");
}

/// Ten hidden floods, each kept at its 512 KiB credit window, while a
/// visible terminal gets `keys` one-byte chunks: each chunk's push-to-parse
/// latency, sorted.
fn ten_hidden_floods(keys: u64) -> Vec<Duration> {
    const WINDOW: u64 = 512 * 1024;
    const CHUNK: usize = 64 * 1024;
    let pool = VtPool::start(VtPoolConfig::for_performance_cores(8)).unwrap();
    let floods: Vec<Arc<Recorder>> =
        (10..20).map(|id| Arc::new(Recorder { keep: false, ..Recorder::plain(id) })).collect();
    let chunk = pattern(0, CHUNK);
    let mut flood_ends = vec![0u64; floods.len()];
    for flood in &floods {
        pool.register(flood.id, flood.clone(), VtGroup::Hidden, 0).unwrap();
    }
    let (log, seen) = mpsc::channel();
    let echo = Arc::new(Recorder::logged(1, &log));
    pool.register(1, echo.clone(), VtGroup::Visible, 0).unwrap();

    let mut latencies = Vec::new();
    for key in 0..keys {
        for (flood, end) in floods.iter().zip(&mut flood_ends) {
            while *end - flood.confirmed() + CHUNK as u64 <= WINDOW {
                pool.push(flood.id, *end, chunk.clone()).unwrap();
                *end += CHUNK as u64;
            }
        }
        let pushed = Instant::now();
        pool.push(1, key, vec![b'k']).unwrap();
        loop {
            let (_, call, at) = seen.recv_timeout(Duration::from_secs(10)).unwrap();
            if let Call::Parse { offset, .. } = call {
                assert_eq!(offset, key);
                latencies.push(at.duration_since(pushed));
                break;
            }
        }
    }
    for flood in &floods {
        assert!(flood.confirmed() > 0, "a flood never ran");
        assert_eq!(flood.publishes(), 0, "a hidden flood did frame work");
        let threads = flood.threads();
        assert!(threads.iter().all(|name| name.starts_with("vt-pool-h-")), "{threads:?}");
    }
    let threads = echo.threads();
    assert!(threads.iter().all(|name| name.starts_with("vt-pool-v-")), "{threads:?}");
    latencies.sort();
    latencies
}

/// Hidden floods never run on a visible thread, and the visible terminal
/// never on a hidden one: a flood cannot take the focused echo's thread.
#[test]
fn ten_hidden_floods_never_run_on_the_visible_threads() {
    let latencies = ten_hidden_floods(100);
    assert_eq!(latencies.len(), 100);
}

/// The acceptance row behind bench-typing.py STRESS: ten hidden floods
/// leave the focused echo parsed within 5 ms at p99. A latency bench: run it
/// by hand on an idle host, release build.
#[test]
#[ignore = "bench: run by hand (bench-typing.py STRESS row; perf-hot terminal-feed)"]
fn ten_hidden_floods_leave_the_focused_echo_under_5_ms_at_p99() {
    let latencies = ten_hidden_floods(400);
    let p99 = latencies[latencies.len() * 99 / 100];
    assert!(p99 <= Duration::from_millis(5), "focused echo p99 {p99:?} with ten hidden floods");
}

#[test]
fn unregister_during_a_slice_drops_the_terminal_after_it() {
    let (open, gate) = mpsc::channel();
    let terminal = Arc::new(Recorder { gate: Some(Mutex::new(gate)), ..Recorder::plain(3) });
    let pool = VtPool::start(config(1, 1)).unwrap();
    pool.register(3, terminal.clone(), VtGroup::Visible, 0).unwrap();
    pool.push(3, 0, vec![1; 100]).unwrap();
    wait_until("the slice to start", || terminal.busy.load(Ordering::SeqCst));
    pool.unregister(3).unwrap();
    assert_eq!(pool.push(3, 100, vec![1]), Err(VtPoolError::UnknownTerminal(3)));
    open.send(()).unwrap();
    wait_until("the terminal to leave", || pool.stats().pending_bytes == 0);
    assert_eq!(pool.stats().terminals, 0);
    assert_eq!(pool.register(3, terminal, VtGroup::Visible, 0), Ok(()));
}

#[test]
fn a_panicking_terminal_is_dropped_and_the_pool_keeps_running() {
    struct Panics;
    impl VtTerminal for Panics {
        fn parse(&self, _: u64, _: &[u8]) {
            panic!("parse failed");
        }
        fn confirm_parsed(&self, _: u64) {}
        fn publish(&self) {}
    }
    let pool = VtPool::start(config(1, 1)).unwrap();
    pool.register(9, Arc::new(Panics), VtGroup::Visible, 0).unwrap();
    pool.push(9, 0, vec![1]).unwrap();
    wait_until("the panic counted", || pool.stats().panicked == 1);
    let terminal = Recorder::new(4);
    pool.register(4, terminal.clone(), VtGroup::Visible, 0).unwrap();
    pool.push(4, 0, vec![1]).unwrap();
    wait_until("the next terminal parsed", || terminal.confirmed() == 1);
    assert_eq!(pool.push(9, 1, vec![1]), Err(VtPoolError::UnknownTerminal(9)));
}

#[test]
fn shutdown_joins_the_threads_and_refuses_new_work() {
    let mut pool = VtPool::start(config(2, 2)).unwrap();
    let terminal = Recorder::new(5);
    pool.register(5, terminal.clone(), VtGroup::Hidden, 0).unwrap();
    pool.push(5, 0, pattern(0, 1_000_000)).unwrap();
    pool.shutdown();
    assert!(pool.threads.is_empty());
    assert_eq!(pool.push(5, 1_000_000, vec![1]), Err(VtPoolError::ShutDown));
    assert_eq!(pool.register(6, terminal, VtGroup::Visible, 0), Err(VtPoolError::ShutDown));
}
