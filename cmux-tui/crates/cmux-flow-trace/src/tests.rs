use super::*;

fn shared() -> std::sync::Arc<Shared> {
    std::sync::Arc::new(Shared {
        ring: Ring::new(),
        dropped: AtomicU64::new(0),
        nudged: AtomicBool::new(false),
        asleep: AtomicBool::new(false),
        written: Mutex::new(0),
        written_changed: Condvar::new(),
        drains: AtomicU64::new(0),
    })
}

/// A writer thread on its own ring, writing to /dev/null. It never ends: the test process ends it.
fn writer(shared: &std::sync::Arc<Shared>) -> Sink {
    let file = std::fs::OpenOptions::new().write(true).open("/dev/null").unwrap();
    let drained = shared.clone();
    let thread = std::thread::spawn(move || write_records(file, &drained));
    Sink { shared: shared.clone(), writer: thread.thread().clone() }
}

fn plain(flow: u64) -> Record {
    Record { name: "x", flow, terminal: [0; TERMINAL_BYTES], terminal_len: 0, tid: 0, t_ns: 0 }
}

/// A producer preempted between its claim of a slot (the compare-and-swap on `tail`) and its publish leaves
/// `waiting()` above 0 with nothing to pop. The writer looped with no park while `waiting()` was above 0, so it
/// spun a core until that producer ran again, and for good if it never did.
#[cfg(unix)]
#[test]
fn a_claimed_slot_not_yet_published_does_not_spin_the_writer() {
    let shared = shared();
    shared.ring.tail.fetch_add(1, Ordering::Relaxed); // a claim whose producer never publishes
    let _sink = writer(&shared);
    std::thread::sleep(Duration::from_millis(300));
    let drains = shared.drains.load(Ordering::Relaxed);
    assert!(
        drains <= 12,
        "the writer looped {drains} times in 300 ms over an unpublished slot (timed drains: 6)"
    );
}

/// Tracing on but idle: the writer drained every 50 ms for good, 20 wakeups a second in every traced process
/// with nothing to write. After a second with no records it sleeps until a hop wakes it, and that hop's record
/// still reaches the file at once.
#[cfg(unix)]
#[test]
fn an_idle_writer_sleeps_until_a_hop_wakes_it() {
    let shared = shared();
    let sink = writer(&shared);
    std::thread::sleep(IDLE_BEFORE_SLEEP + Duration::from_millis(300));
    let asleep = shared.drains.load(Ordering::Relaxed);
    std::thread::sleep(Duration::from_millis(500));
    let later = shared.drains.load(Ordering::Relaxed);
    assert_eq!(later, asleep, "an idle writer woke {} times in 500 ms", later - asleep);

    push(&sink, plain(1));
    let deadline = std::time::Instant::now() + DRAIN_INTERVAL / 2;
    let mut written = shared.written.lock().unwrap();
    while *written < 1 && std::time::Instant::now() < deadline {
        written = shared.written_changed.wait_timeout(written, Duration::from_millis(5)).unwrap().0;
    }
    assert_eq!(
        *written, 1,
        "the hop after a sleep did not wake the writer within half a drain interval"
    );
}

#[test]
fn hex_matches_the_daemon_terminal_id() {
    assert_eq!(hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
}

#[test]
fn json_safe_keeps_ids_and_drops_the_rest() {
    assert_eq!(json_safe("ab12.x_y-z"), "ab12.x_y-z");
    assert_eq!(json_safe("a\"b\\c\nd"), "abcd");
}

#[test]
fn the_clock_moves_forward() {
    let first = now_ns();
    let second = now_ns();
    assert!(first > 0 && second >= first);
}

#[test]
fn the_ring_keeps_order_and_refuses_when_full() {
    let ring = Ring::new();
    let record = |flow| Record {
        name: "x",
        flow,
        terminal: [0; TERMINAL_BYTES],
        terminal_len: 0,
        tid: 0,
        t_ns: 0,
    };
    for flow in 0..RING_SLOTS as u64 {
        assert!(ring.push(record(flow)));
    }
    assert!(!ring.push(record(u64::MAX)), "a full ring took a record");
    assert_eq!(ring.pop().map(|r| r.flow), Some(0));
    assert!(ring.push(record(7)), "a freed slot was not reused");
    let mut last = 0;
    while let Some(r) = ring.pop() {
        last = r.flow;
    }
    assert_eq!(last, 7);
    assert_eq!(ring.waiting(), 0);
}
