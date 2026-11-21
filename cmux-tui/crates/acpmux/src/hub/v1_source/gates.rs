//! Row 3b's gate (`benches/v2/mod.rs`): the god chat caught up from nothing over the v1 source.
//! Run: `cargo test --profile gate -p acpmux --lib v2_pr03b_ -- --ignored --nocapture`.
//!
//! One small catch-up nobody measures runs first, then small, then god, in one process. Each
//! writes its chat's log through v1's store and catches the book up through the actor. The
//! measure is bytes known allocated: the test allocator counts the actor thread's bytes from its
//! first chunk (`peer_snapshot/disk_tests.rs`), and the peak is the most it held at once, over
//! that start, in any stretch of [`STRETCH`] chunks (the same length at both sizes) or at the
//! end. It counts what the actor keeps as the chat grows (a map that kept one entry per row, say,
//! would climb every stretch) and nothing the allocator or the kernel keeps for it.
//!
//! The probe prints, per stretch, what resident size did: the high-water rise over a baseline
//! taken after `malloc_trim(0)` (the kernel's mark reset at each stretch's start), anonymous and
//! file-backed resident bytes, and glibc's heap in use and free. That rise is not the gate: on
//! the same harness the small side's read 64 to 608 KiB from one run to the next with the same
//! work, as it reused free heap pages glibc kept resident or not, and god's carried `rows.idx`'s
//! mapped pages (page cache, 56 to 124 KiB). `CATCHUP_PROBE_SMAPS=1` adds the largest mappings.

use super::tests::{Home, ID, book_rows, translated, wait_ready};
use super::*;
use acpmux_core::chat::ChatActor;
use serde::{Deserialize, Serialize};

/// Chunks in one measured stretch: 2 MiB of log, all of the small chat.
const STRETCH: u64 = 8;

/// How far god's resident anonymous bytes may grow from the stretch a quarter of the way through
/// to the last: three runs read 0, 0 and 0 KiB (stretches 157 to 624), and the same run with the
/// test-only sync wait record kept whole read 524. 64 KiB is one early-stretch step of the
/// allocator's (the probe saw 60) and an eighth of that leak.
const GOD_ANON_ALLOWANCE_KIB: i64 = 64;

#[derive(Debug, Default, Serialize, Deserialize)]
struct CatchUp {
    /// The probe: the largest rise of resident size over the baseline in any stretch, in KiB.
    peak_kib: u64,
    /// The most bytes the actor thread held at once over its first chunk's, in KiB.
    held_kib: u64,
    /// The largest buffer the source built, and the chunk bound.
    held_max: u64,
    /// Bytes the store took from the log's files, and the log's length.
    read: u64,
    log_bytes: u64,
    chunks: u64,
    rows: usize,
    equal: bool,
    /// Resident anonymous KiB at the stretch a quarter of the way through, and at the last.
    anon_quarter: (u64, u64),
    anon_last: (u64, u64),
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
    free: u64,
    /// The actor thread's most bytes held in the stretch, over the first chunk's (KiB).
    held: u64,
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

/// Whether the probe reads `/proc/self/smaps` (it allocates a copy of it, in the stretch).
fn smaps_on() -> bool {
    std::env::var_os("CATCHUP_PROBE_SMAPS").is_some()
}

/// glibc's heap: bytes in use, and bytes free but held (both KiB).
fn heap_kib() -> (u64, u64) {
    // SAFETY: glibc's mallinfo2 takes no pointer and only reads the allocator's counters.
    let info = unsafe { libc::mallinfo2() };
    (((info.uordblks + info.hblkhd) / 1024) as u64, (info.fordblks / 1024) as u64)
}

fn sample(n: u64, rise: u64) -> Stretch {
    let (heap, free) = heap_kib();
    Stretch {
        n,
        rise,
        anon: memory_kib("RssAnon:"),
        file: memory_kib("RssFile:"),
        shmem: memory_kib("RssShmem:"),
        heap,
        free,
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
    /// The most bytes the actor's thread held at once over what it held at the first chunk, in
    /// any stretch (the test allocator's count, `peer_snapshot/disk_tests.rs`).
    held: Arc<AtomicU64>,
}

impl Measured {
    /// The actor thread's most bytes held since the last call, over the first chunk's.
    fn take_held(&self) -> u64 {
        let most = crate::hub::peer_snapshot::thread_peak_take().unwrap_or(0) as u64;
        self.held.fetch_max(most, Ordering::SeqCst);
        most
    }
}

impl Drop for Measured {
    /// The last stretch, through the end's checkpoint: the actor drops its source on its thread.
    fn drop(&mut self) {
        self.take_held();
    }
}

impl RawSource for Measured {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        if self.chunks == 0 {
            crate::hub::peer_snapshot::thread_peak_start();
        }
        if self.chunks.is_multiple_of(STRETCH) {
            let held = if self.chunks > 0 { self.take_held() } else { 0 };
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
                s.held = held / 1024;
                s.chunks_read = counters.chunks.load(Ordering::Relaxed);
                s.bytes_read = counters.read.load(Ordering::Relaxed);
                s.syncs = counters.syncs.load(Ordering::Relaxed);
                if smaps_on() {
                    s.idx_rss = mapped_rss_kib("/book/rows.idx");
                }
                {
                    let mut waits = counters.sync_waits.lock().unwrap();
                    s.waits_bytes = (waits.capacity() * 8) as u64;
                    // A test-only record of every sync's wait (`Counters::sync_waits`, one u64
                    // each, absent from a product build): god syncs about 36,600 times and small
                    // 98, so kept whole it alone climbs 512 KiB with length. Each stretch starts
                    // it empty.
                    *waits = Vec::new();
                }
                let mut stretches = self.stretches.lock().unwrap();
                if stretches.len() < stretches.capacity() {
                    stretches.push(s);
                }
                drop(stretches);
                if smaps_on() && n > 0 && n.is_multiple_of(128) {
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
    let held = Arc::new(AtomicU64::new(0));
    let measured_held = held.clone();
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
            held: measured_held.clone(),
        }) as Box<dyn RawSource>)
    });
    let mut config = home.config(&log);
    config.source_factory = factory;
    let actor = ChatActor::spawn(config);
    wait_ready(&actor);
    let last_rise = memory_kib("VmHWM:").saturating_sub(baseline);
    peak.fetch_max(last_rise, Ordering::SeqCst);
    let at_end = sample(u64::MAX, last_rise);
    if smaps_on() {
        smaps_top(&format!("ready rows_msgs={}", shape.god_messages), &home_path);
    }
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
    eprintln!(
        "v2.pr03b.catchup_peak_rss book_files msgs={} heads={} lists={} {book_files:?}",
        shape.god_messages,
        log.counters.heads.load(Ordering::SeqCst),
        log.counters.lists.load(Ordering::SeqCst)
    );
    let (anon_quarter, anon_last) = {
        let b = at_baseline;
        eprintln!(
            "v2.pr03b.catchup_peak_rss stretches msgs={} baseline vmrss={baseline} anon={} file={} shmem={} heap={}",
            shape.god_messages, b.anon, b.file, b.shmem, b.heap
        );
        let stretches = stretches.lock().unwrap();
        for s in stretches.iter().chain(std::iter::once(&at_end)) {
            eprintln!(
                "v2.pr03b.catchup_peak_rss stretch msgs={} n={} rise={} d_anon={} d_file={} d_shmem={} d_heap={} d_free={} held={} chunks={} read={} syncs={} waits_bytes={} idx_rss={}",
                shape.god_messages,
                s.n as i64,
                s.rise,
                s.anon as i64 - b.anon as i64,
                s.file as i64 - b.file as i64,
                s.shmem as i64 - b.shmem as i64,
                s.heap as i64 - b.heap as i64,
                s.free as i64 - b.free as i64,
                s.held,
                s.chunks_read,
                s.bytes_read,
                s.syncs,
                s.waits_bytes,
                s.idx_rss
            );
        }
        // Stretches end at n = 1.. (n = 0 is the first chunk's start).
        let ended: Vec<&Stretch> = stretches.iter().filter(|s| s.n > 0).collect();
        let at = |s: Option<&&Stretch>| s.map_or((0, 0), |s| (s.n, s.anon));
        (at(ended.get(ended.len() / 4)), at(ended.last()))
    };
    let rows = book_rows(&home.book());
    let equal = rows == translated(home.store.as_ref());
    CatchUp {
        peak_kib: peak.load(Ordering::SeqCst),
        held_kib: held.load(Ordering::SeqCst) / 1024,
        held_max: log.counters.held_max.load(Ordering::SeqCst),
        read: log.counters.read.load(Ordering::SeqCst),
        log_bytes,
        chunks: log.counters.chunks.load(Ordering::SeqCst),
        rows: rows.len(),
        equal,
        anon_quarter,
        anon_last,
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
    // The probe: resident size's rise, which glibc's held free pages and the kernel's page cache
    // move (printed, not gated).
    eprintln!(
        "v2.pr03b.catchup_peak_rss rss small_kib={} god_kib={} ratio={:.3} chunk_kib={}",
        small.peak_kib,
        god.peak_kib,
        god.peak_kib as f64 / small.peak_kib.max(1) as f64,
        chunk / 1024
    );
    let ratio = god.held_kib as f64 / small.held_kib.max(1) as f64;
    eprintln!(
        "v2.pr03b.catchup_peak_rss small_kib={} god_kib={} ratio={ratio:.3}",
        small.held_kib, god.held_kib
    );
    // God against itself, for what the thread count cannot see (other threads, mapped pages):
    // its resident anonymous bytes at the last stretch against a quarter of the way through.
    let ((quarter_n, quarter), (last_n, last)) = (god.anon_quarter, god.anon_last);
    let growth = last as i64 - quarter as i64;
    eprintln!(
        "v2.pr03b.catchup_peak_rss god_anon quarter_n={quarter_n} quarter_kib={quarter} \
         last_n={last_n} last_kib={last} growth_kib={growth}"
    );
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        use std::io::Write;
        let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(
            output,
            "{{\"name\":\"v2.pr03b.catchup_peak_rss\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"KiB\"}}",
            small.held_kib, god.held_kib
        )
        .unwrap();
    }
    assert!(
        ratio <= 1.2,
        "god's actor held {} KiB at most against small's {} KiB",
        god.held_kib,
        small.held_kib
    );
    // With no stretch ended both are (0, 0), and a growth of 0 would pass.
    assert!(
        last_n > quarter_n,
        "god's growth check needs two stretches ended: a quarter of the way at {quarter_n}, the last at {last_n}"
    );
    assert!(
        growth <= GOD_ANON_ALLOWANCE_KIB,
        "god's resident anonymous bytes grew {growth} KiB from stretch {quarter_n} to {last_n} \
         (allowance {GOD_ANON_ALLOWANCE_KIB} KiB)"
    );
}
