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

/// One stretch's end: the high-water rise, and resident and heap bytes then (KiB, absolute).
#[derive(Clone, Copy, Debug, Default)]
struct Stretch {
    n: u64,
    rise: u64,
    anon: u64,
    file: u64,
    shmem: u64,
    heap: u64,
    chunks_read: u64,
    bytes_read: u64,
    syncs: u64,
    /// The test-only `Counters::sync_waits` buffer's capacity, in bytes.
    waits_bytes: u64,
    /// `rows.idx`'s resident pages in this process's mapping, in KiB.
    idx_rss: u64,
}

/// Resident KiB of the mappings whose path ends with `suffix`.
fn mapped_rss_kib(suffix: &str) -> u64 {
    let Ok(text) = std::fs::read_to_string("/proc/self/smaps") else { return 0 };
    let (mut inside, mut kib) = (false, 0);
    for line in text.lines() {
        let first = line.split_whitespace().next().unwrap_or("");
        if first.contains('-') && !first.ends_with(':') {
            inside = line.trim_end().ends_with(suffix);
        } else if inside && first == "Rss:" {
            kib += line.split_whitespace().nth(1).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
        }
    }
    kib
}

fn heap_kib() -> u64 {
    // SAFETY: glibc's mallinfo2 takes no pointer and only reads the allocator's counters.
    let info = unsafe { libc::mallinfo2() };
    ((info.uordblks + info.hblkhd) / 1024) as u64
}

fn sample(n: u64, rise: u64) -> Stretch {
    Stretch {
        n,
        rise,
        anon: memory_kib("RssAnon:"),
        file: memory_kib("RssFile:"),
        shmem: memory_kib("RssShmem:"),
        heap: heap_kib(),
        ..Stretch::default()
    }
}

/// Resident KiB by mapping (path, or `[anon]`), the largest first.
fn smaps_top(label: &str, base: &str) {
    let Ok(text) = std::fs::read_to_string("/proc/self/smaps") else { return };
    let mut by: std::collections::BTreeMap<String, (u64, u64, u64)> = Default::default();
    let mut current = String::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let first = fields.next().unwrap_or("");
        if first.contains('-') && !first.ends_with(':') {
            let path = line.split_whitespace().nth(5).unwrap_or("[anon]");
            current = path.replace(base, "<home>");
            continue;
        }
        let kib = fields.next().and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
        let entry = by.entry(current.clone()).or_default();
        match first {
            "Rss:" => entry.0 += kib,
            "Anonymous:" => entry.1 += kib,
            "Size:" => entry.2 += kib,
            _ => {}
        }
    }
    let mut rows: Vec<_> = by.into_iter().filter(|(_, v)| v.0 > 0).collect();
    rows.sort_by_key(|(_, v)| std::cmp::Reverse(v.0));
    for (path, (rss, anon, size)) in rows.into_iter().take(12) {
        eprintln!(
            "v2.pr03b.catchup_peak_rss smaps {label} rss_kib={rss} anon_kib={anon} size_kib={size} {path}"
        );
    }
}

/// A source that resets the high-water mark at each stretch's start and reads the rise at its end.
struct Measured {
    inner: V1Source<Arc<dyn Store>>,
    baseline: u64,
    peak: Arc<AtomicU64>,
    chunks: u64,
    stretches: Arc<std::sync::Mutex<Vec<Stretch>>>,
    home: String,
}

impl RawSource for Measured {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        if self.chunks.is_multiple_of(STRETCH) {
            let rise = if self.chunks > 0 {
                memory_kib("VmHWM:").saturating_sub(self.baseline)
            } else {
                0
            };
            {
                if self.chunks > 0 {
                    self.peak.fetch_max(rise, Ordering::SeqCst);
                }
                let n = self.chunks / STRETCH;
                let counters = &self.inner.counters;
                let mut s = sample(n, rise);
                s.chunks_read = counters.chunks.load(Ordering::Relaxed);
                s.bytes_read = counters.read.load(Ordering::Relaxed);
                s.syncs = counters.syncs.load(Ordering::Relaxed);
                s.idx_rss = mapped_rss_kib("/book/rows.idx");
                {
                    let mut waits = counters.sync_waits.lock().unwrap();
                    s.waits_bytes = (waits.capacity() * 8) as u64;
                    if std::env::var_os("CATCHUP_DRAIN_WAITS").is_some() {
                        *waits = Vec::new();
                    }
                }
                let mut stretches = self.stretches.lock().unwrap();
                if stretches.len() < stretches.capacity() {
                    stretches.push(s);
                }
                drop(stretches);
                if n > 0 && n.is_multiple_of(128) {
                    smaps_top(&format!("stretch={n}"), &self.home);
                }
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
    let at_baseline = sample(0, 0);
    let stretches = Arc::new(std::sync::Mutex::new(Vec::with_capacity(4096)));
    let home_path = home.dir.path().display().to_string();
    let peak = Arc::new(AtomicU64::new(0));
    let (inner, measured_peak, measured_stretches, measured_home) =
        (log.clone(), peak.clone(), stretches.clone(), home_path.clone());
    let factory: SourceFactory = Arc::new(move || {
        Ok(Box::new(Measured {
            inner: inner.open()?,
            baseline,
            peak: measured_peak.clone(),
            chunks: 0,
            stretches: measured_stretches.clone(),
            home: measured_home.clone(),
        }) as Box<dyn RawSource>)
    });
    let mut config = home.config(&log);
    config.source_factory = factory;
    let actor = ChatActor::spawn(config);
    wait_ready(&actor);
    let last_rise = memory_kib("VmHWM:").saturating_sub(baseline);
    peak.fetch_max(last_rise, Ordering::SeqCst);
    let at_end = sample(u64::MAX, last_rise);
    smaps_top(&format!("ready rows_msgs={}", shape.god_messages), &home_path);
    actor.join();
    let book_files = std::fs::read_dir(home.book())
        .into_iter()
        .flatten()
        .chain(std::fs::read_dir(home.book().join("rows")).into_iter().flatten())
        .flatten()
        .filter_map(|e| {
            Some((e.file_name().to_string_lossy().into_owned(), e.metadata().ok()?.len()))
        })
        .collect::<Vec<_>>();
    eprintln!("v2.pr03b.catchup_peak_rss book_files msgs={} {book_files:?}", shape.god_messages);
    {
        let b = at_baseline;
        eprintln!(
            "v2.pr03b.catchup_peak_rss stretches msgs={} baseline vmrss={baseline} anon={} file={} shmem={} heap={}",
            shape.god_messages, b.anon, b.file, b.shmem, b.heap
        );
        let stretches = stretches.lock().unwrap();
        for s in stretches.iter().chain(std::iter::once(&at_end)) {
            eprintln!(
                "v2.pr03b.catchup_peak_rss stretch msgs={} n={} rise={} d_anon={} d_file={} d_shmem={} d_heap={} chunks={} read={} syncs={} waits_bytes={} idx_rss={}",
                shape.god_messages,
                s.n as i64,
                s.rise,
                s.anon as i64 - b.anon as i64,
                s.file as i64 - b.file as i64,
                s.shmem as i64 - b.shmem as i64,
                s.heap as i64 - b.heap as i64,
                s.chunks_read,
                s.bytes_read,
                s.syncs,
                s.waits_bytes,
                s.idx_rss
            );
        }
    }
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
