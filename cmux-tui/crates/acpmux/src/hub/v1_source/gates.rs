//! Row 3b's gate (`benches/v2/mod.rs`): the god chat caught up from nothing over the v1 source.
//! Run: `cargo test --profile gate -p acpmux --lib v2_pr03b_ -- --ignored --nocapture`.
//!
//! One small catch-up nobody measures runs first, then small, then god, in one process. Each writes its chat's log through v1's store,
//! returns free pages (`malloc_trim(0)`), takes its baseline, and catches the book up through the
//! actor. Every stretch of [`STRETCH`] chunks (the same length at both sizes) starts with the
//! kernel's high-water mark reset, and the peak is the largest rise over the baseline any stretch
//! reached.

use super::tests::{Home, ID, book_rows, translated, wait_ready};
use super::*;
use acpmux_core::chat::ChatActor;
use serde::{Deserialize, Serialize};

/// Chunks in one measured stretch: 2 MiB of log, all of the small chat.
const STRETCH: u64 = 8;

#[derive(Debug, Default, Serialize, Deserialize)]
struct CatchUp {
    /// The largest rise of resident size over the baseline in any stretch, in KiB.
    peak_kib: u64,
    /// The largest buffer the source built, and the chunk bound.
    held_max: u64,
    /// Bytes the store took from the log's files, and the log's length.
    read: u64,
    log_bytes: u64,
    chunks: u64,
    rows: usize,
    equal: bool,
}

fn memory_kib(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap()
        .lines()
        .find_map(|line| line.strip_prefix(field).and_then(|s| s.split_whitespace().next()))
        .and_then(|s| s.parse().ok())
        .unwrap()
}

fn trim() {
    // SAFETY: no pointer is passed; glibc documents `malloc_trim` as MT-Safe.
    unsafe {
        libc::malloc_trim(0);
    }
}

/// A source that resets the high-water mark at each stretch's start and reads the rise at its end.
struct Measured {
    inner: V1Source<Arc<dyn Store>>,
    baseline: u64,
    peak: Arc<AtomicU64>,
    chunks: u64,
}

impl RawSource for Measured {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        if self.chunks.is_multiple_of(STRETCH) {
            if self.chunks > 0 {
                let rise = memory_kib("VmHWM:").saturating_sub(self.baseline);
                self.peak.fetch_max(rise, Ordering::SeqCst);
            }
            std::fs::write("/proc/self/clear_refs", b"5\n")?;
        }
        self.chunks += 1;
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
}

fn catch_up(shape: &crate::god_fixture::Shape) -> CatchUp {
    let home = Home::with_chat(shape.god_messages, shape.god_bytes);
    let log = home.log();
    let log_bytes = {
        let mut bytes = 0;
        home.store
            .scan(ID, 0, &mut |record| {
                bytes += serde_json::to_vec(&record).map_or(0, |line| line.len() as u64 + 1);
                true
            })
            .unwrap();
        bytes
    };
    trim();
    let baseline = memory_kib("VmRSS:");
    let peak = Arc::new(AtomicU64::new(0));
    let (inner, measured_peak) = (log.clone(), peak.clone());
    let factory: SourceFactory = Arc::new(move || {
        Ok(Box::new(Measured {
            inner: inner.open()?,
            baseline,
            peak: measured_peak.clone(),
            chunks: 0,
        }) as Box<dyn RawSource>)
    });
    let mut config = home.config(&log);
    config.source_factory = factory;
    let actor = ChatActor::spawn(config);
    wait_ready(&actor);
    peak.fetch_max(memory_kib("VmHWM:").saturating_sub(baseline), Ordering::SeqCst);
    actor.join();
    let rows = book_rows(&home.book());
    let equal = rows == translated(home.store.as_ref());
    CatchUp {
        peak_kib: peak.load(Ordering::SeqCst),
        held_max: log.counters.held_max.load(Ordering::SeqCst),
        read: log.counters.read.load(Ordering::SeqCst),
        log_bytes,
        chunks: log.counters.chunks.load(Ordering::SeqCst),
        rows: rows.len(),
        equal,
    }
}
fn shape_from_env(case: &str) -> crate::god_fixture::Shape {
    if case == "god" {
        crate::god_fixture::Shape::god_from_env()
    } else {
        crate::god_fixture::Shape::small()
    }
}

fn worker(case: &str) -> CatchUp {
    catch_up(&shape_from_env(case))
}

#[test]
#[ignore = "release gate: the god chat caught up from nothing over the v1 source"]
fn v2_pr03b_catchup_peak_rss() {
    // One catch-up nobody measures pays the process's one-time costs (the allocator's arenas,
    // the first actor thread, the store's first open) before either side, so neither pays them.
    let _ = worker("small");
    let small = worker("small");
    let god = worker("god");
    eprintln!("v2.pr03b.catchup_peak_rss small={small:?}");
    eprintln!("v2.pr03b.catchup_peak_rss god={god:?}");
    let chunk = acpmux_core::chat::source::CHUNK_BYTES as u64;
    for (name, run) in [("small", &small), ("god", &god)] {
        assert!(run.equal, "{name}: the book equals what translate gives");
        assert!(run.held_max <= chunk, "{name}: the source held one chunk ({})", run.held_max);
        assert!(
            run.read * 5 <= run.log_bytes * 6,
            "{name}: read {} of {}",
            run.read,
            run.log_bytes
        );
    }
    let ratio = god.peak_kib as f64 / small.peak_kib.max(1) as f64;
    eprintln!(
        "v2.pr03b.catchup_peak_rss small_kib={} god_kib={} ratio={ratio:.3} chunk_kib={}",
        small.peak_kib,
        god.peak_kib,
        chunk / 1024
    );
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        use std::io::Write;
        let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(
            output,
            "{{\"name\":\"v2.pr03b.catchup_peak_rss\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"KiB\"}}",
            small.peak_kib, god.peak_kib
        )
        .unwrap();
    }
    assert!(ratio <= 1.2, "god's peak {} KiB against small's {} KiB", god.peak_kib, small.peak_kib);
}
