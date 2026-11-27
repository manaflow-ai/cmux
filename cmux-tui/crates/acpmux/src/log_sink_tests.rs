use super::*;
use std::sync::mpsc;

/// A log output that takes no bytes until the test lets it go, then keeps every byte.
struct Stuck {
    entered: mpsc::SyncSender<()>,
    release: mpsc::Receiver<()>,
    released: bool,
    kept: Arc<Mutex<Vec<u8>>>,
}

impl Write for Stuck {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if !self.released {
            let _ = self.entered.try_send(());
            let _ = self.release.recv();
            self.released = true;
        }
        self.kept.lock().unwrap_or_else(PoisonError::into_inner).extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn stuck() -> (Stuck, mpsc::Receiver<()>, mpsc::Sender<()>, Arc<Mutex<Vec<u8>>>) {
    let (entered_tx, entered) = mpsc::sync_channel(1);
    let (release, release_rx) = mpsc::channel();
    let kept = Arc::new(Mutex::new(Vec::new()));
    let out =
        Stuck { entered: entered_tx, release: release_rx, released: false, kept: kept.clone() };
    (out, entered, release, kept)
}

fn log(sink: &Sink, text: &str) {
    use tracing_subscriber::fmt::MakeWriter as _;
    let mut line = sink.make_writer();
    let _ = line.write_all(text.as_bytes());
}

/// A log output that takes no bytes never makes a logging thread wait: the lines past the queue
/// are dropped, counted, and the count is written before the next line written.
#[test]
fn a_log_output_that_takes_no_bytes_never_stops_a_logging_thread() {
    let (out, entered, release, kept) = stuck();
    let sink = Sink::start(out).expect("the writer thread starts");
    log(&sink, "first\n");
    entered.recv_timeout(Duration::from_secs(10)).expect("the writer thread writes the first line");
    let started = Instant::now();
    let lines = QUEUE_LINES + 100;
    for n in 0..lines {
        log(&sink, &format!("line {n}\n"));
    }
    assert!(started.elapsed() < Duration::from_secs(5), "logging waited: {:?}", started.elapsed());
    release.send(()).expect("the writer thread waits");
    assert!(flush_shared(&sink.shared, Duration::from_secs(10)), "the queue is written");
    log(&sink, "after\n");
    assert!(flush_shared(&sink.shared, Duration::from_secs(10)), "the next line is written");
    let text = String::from_utf8(kept.lock().unwrap_or_else(PoisonError::into_inner).clone())
        .expect("utf-8 lines");
    let written: Vec<&str> = text.lines().collect();
    assert_eq!(written.first(), Some(&"first"));
    // The queued lines in order, then the drop count, then the line after.
    let queued: Vec<&str> = written.iter().copied().filter(|l| l.starts_with("line ")).collect();
    let want: Vec<String> = (0..queued.len()).map(|n| format!("line {n}")).collect();
    assert_eq!(queued, want);
    assert_eq!(queued.len(), QUEUE_LINES);
    let dropped = lines - QUEUE_LINES;
    let notice = written[written.len() - 2];
    assert!(
        notice.contains(&format!("  WARN {dropped} log lines were dropped")),
        "the drop count comes before the next line: {notice:?}"
    );
    assert_eq!(written.last(), Some(&"after"));
}

/// The byte bound holds too: a few long lines fill the queue before the line bound does.
#[test]
fn long_lines_are_bounded_by_bytes() {
    let (out, entered, release, kept) = stuck();
    let sink = Sink::start(out).expect("the writer thread starts");
    log(&sink, "first\n");
    entered.recv_timeout(Duration::from_secs(10)).expect("the writer thread writes the first line");
    let long = format!("{}\n", "x".repeat(1 << 20));
    for _ in 0..20 {
        log(&sink, &long);
    }
    assert!(sink.shared.queued_bytes.load(Ordering::Acquire) <= QUEUE_BYTES);
    assert_eq!(sink.shared.dropped.load(Ordering::Relaxed), 20 - (QUEUE_BYTES / long.len()) as u64);
    release.send(()).expect("the writer thread waits");
    log(&sink, "after\n");
    assert!(flush_shared(&sink.shared, Duration::from_secs(10)));
    let kept = kept.lock().unwrap_or_else(PoisonError::into_inner);
    assert_eq!(kept.iter().filter(|&&b| b == b'\n').count(), 1 + QUEUE_BYTES / long.len() + 2);
}

/// A flush that the log output never lets finish returns at its budget.
#[test]
fn a_flush_returns_at_its_budget() {
    let (out, entered, _release, _kept) = stuck();
    let sink = Sink::start(out).expect("the writer thread starts");
    log(&sink, "first\n");
    entered.recv_timeout(Duration::from_secs(10)).expect("the writer thread writes the first line");
    let started = Instant::now();
    assert!(!flush_shared(&sink.shared, Duration::from_millis(200)));
    assert!(started.elapsed() < Duration::from_secs(5));
}

/// The lines a `tracing` subscriber formats keep their format through the sink.
#[test]
fn a_subscribers_lines_keep_their_format() {
    let kept = Arc::new(Mutex::new(Vec::new()));
    struct Keep(Arc<Mutex<Vec<u8>>>);
    impl Write for Keep {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap_or_else(PoisonError::into_inner).extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let sink = Sink::start(Keep(kept.clone())).expect("the writer thread starts");
    let logs = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_target(false)
        .with_writer(sink.clone())
        .finish();
    tracing::subscriber::with_default(logs, || {
        tracing::warn!("ownership epoch unreadable: gone");
        tracing::info!("loaded the chat logs of 2 sessions in 3 ms");
    });
    assert!(flush_shared(&sink.shared, Duration::from_secs(10)));
    let text = String::from_utf8(kept.lock().unwrap_or_else(PoisonError::into_inner).clone())
        .expect("utf-8 lines");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(lines[0].ends_with("  WARN ownership epoch unreadable: gone"), "{text}");
    assert!(lines[1].ends_with("  INFO loaded the chat logs of 2 sessions in 3 ms"), "{text}");
}

/// A log output that counts its writes, and takes none until the test lets it go.
struct Counted {
    gate: Arc<(Mutex<bool>, Condvar)>,
    writes: Arc<AtomicU64>,
    kept: Arc<Mutex<Vec<u8>>>,
}

impl Write for Counted {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let (open, cv) = &*self.gate;
        let mut guard = open.lock().unwrap_or_else(PoisonError::into_inner);
        while !*guard {
            guard = cv.wait(guard).unwrap_or_else(PoisonError::into_inner);
        }
        drop(guard);
        self.writes.fetch_add(1, Ordering::Relaxed);
        self.kept.lock().unwrap_or_else(PoisonError::into_inner).extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// `count` lines queued while the output takes no bytes, then let go: the writes it took, and
/// every byte in order.
fn burst(count: usize) -> (u64, Vec<u8>) {
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (writes, kept) = (Arc::new(AtomicU64::new(0)), Arc::new(Mutex::new(Vec::new())));
    let out = Counted { gate: gate.clone(), writes: writes.clone(), kept: kept.clone() };
    let sink = Sink::start(out).expect("the writer thread starts");
    for n in 0..count {
        log(
            &sink,
            &format!("2026-11-27T05:00:00.000000Z DEBUG acpmux::hub: line {n} of a burst\n"),
        );
    }
    *gate.0.lock().unwrap_or_else(PoisonError::into_inner) = true;
    gate.1.notify_all();
    assert!(flush_shared(&sink.shared, Duration::from_secs(30)), "the burst is written");
    let kept = kept.lock().unwrap_or_else(PoisonError::into_inner).clone();
    (writes.load(Ordering::Relaxed), kept)
}

/// A burst of queued lines goes out in a few writes, not one a line, and in order.
#[test]
fn a_burst_of_lines_is_written_in_few_writes_in_order() {
    let (writes, kept) = burst(4000);
    let text = String::from_utf8(kept).expect("utf-8 lines");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 4000);
    for (n, line) in lines.iter().enumerate() {
        assert!(line.contains(&format!(" line {n} of a burst")), "line {n} out of order: {line}");
    }
    // The first line may go alone (the writer took it before the rest were queued).
    assert!(writes <= 1 + (text.len() / BATCH_BYTES) as u64 + 1, "{writes} writes for 4000 lines");
}

/// `cargo test -p acpmux --lib log_sink::tests::burst_bench -- --ignored --nocapture`: writes
/// and drain time of an 8000-line burst, five runs (the before/after of cmux#perf-rust-alloc).
#[test]
#[ignore = "bench"]
fn burst_bench() {
    for run in 0..5 {
        let started = Instant::now();
        let (writes, kept) = burst(8000);
        println!(
            "burst_bench run={run} lines=8000 bytes={} writes={writes} ms={:.3}",
            kept.len(),
            started.elapsed().as_secs_f64() * 1e3
        );
    }
}
