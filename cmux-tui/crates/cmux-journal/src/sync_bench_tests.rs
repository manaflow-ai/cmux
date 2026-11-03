//! R-DURABILITY S0 measurement: what one sync costs on this host, for each sync primitive the
//! journal can use, and what one acked batch costs through the real journal. A measurement, not
//! a test of behavior: it runs only in a fleet step whose key names it (`CMUX_CI_STEP_KEY`
//! contains `sync-bench`), and elsewhere it prints `SYNC-BENCH SKIP` and passes, as row g's crash
//! fuzz does (no CI test, CLAUDE.md).
//!
//! Each line it prints is `SYNC-BENCH <what> <bytes> n=<n> p50=<us> p95=<us> p99=<us> max=<us>`:
//! one write of `<bytes>` at the end of a file in the step's checkout, then one sync, `n` times.
//! `journal-ack` is one `Journal::append` of an acked record and the wait until it is durable.

use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::{Class, Config, FsStorage, Journal, Storage, SyncLevel};

const ROUNDS: usize = 1000;
const SIZES: [usize; 2] = [4096, 256 * 1024];

fn enabled() -> bool {
    std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|key| key.contains("sync-bench"))
}

/// Microseconds at p50, p95, p99 and max (nearest rank).
fn report(what: &str, bytes: usize, samples: &mut [Duration]) {
    samples.sort_unstable();
    let last = samples.len().saturating_sub(1);
    let at = |permille: usize| {
        let rank = last.saturating_mul(permille).checked_div(1000).unwrap_or(0);
        samples.get(rank).map_or(0, Duration::as_micros)
    };
    println!(
        "SYNC-BENCH {what} {bytes} n={} p50={} p95={} p99={} max={}",
        samples.len(),
        at(500),
        at(950),
        at(990),
        at(1000)
    );
}

/// One write then one sync of `level` (or none), `ROUNDS` times, through the journal's own
/// storage seam (so the call is the one the writer makes).
fn time_storage(dir: &std::path::Path, what: &str, bytes: usize, level: Option<SyncLevel>) {
    let storage = FsStorage;
    let path = dir.join(format!("{what}-{bytes}.bin"));
    let mut file = storage
        .open(&path, crate::OpenMode::Create)
        .unwrap_or_else(|error| panic!("open {}: {error}", path.display()));
    let block = vec![0x5Au8; bytes];
    let mut samples = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let start = Instant::now();
        file.append(&block).unwrap_or_else(|error| panic!("write: {error}"));
        if let Some(level) = level {
            file.sync(level).unwrap_or_else(|error| panic!("sync: {error}"));
        }
        samples.push(start.elapsed());
    }
    report(what, bytes, &mut samples);
}

/// `std::fs::File::sync_data` (fdatasync on Linux; F_FULLFSYNC on macOS through std).
fn time_std_sync_data(dir: &std::path::Path, bytes: usize) {
    let path = dir.join(format!("std-sync-data-{bytes}.bin"));
    let mut file = std::fs::File::create(&path).unwrap_or_else(|error| panic!("create: {error}"));
    let block = vec![0xA5u8; bytes];
    let mut samples = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let start = Instant::now();
        file.write_all(&block).unwrap_or_else(|error| panic!("write: {error}"));
        file.sync_data().unwrap_or_else(|error| panic!("sync_data: {error}"));
        samples.push(start.elapsed());
    }
    report("std-sync-data", bytes, &mut samples);
}

/// One acked append and its durable wait, through the real journal and writer thread.
fn time_journal_ack(dir: &std::path::Path, bytes: usize) {
    let storage: Arc<dyn Storage> = Arc::new(FsStorage);
    let (journal, _) = Journal::open(
        storage,
        &dir.join(format!("journal-{bytes}")),
        Config::default(),
        0,
        &mut |_| Ok(()),
    )
    .unwrap_or_else(|error| panic!("open: {error}"));
    let payload = vec![0x3Cu8; bytes];
    let mut samples = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let start = Instant::now();
        let lsn = journal
            .append(1, Class::Ack, &payload)
            .unwrap_or_else(|error| panic!("append: {error}"));
        journal
            .wait_durable(lsn, Duration::from_secs(30))
            .unwrap_or_else(|error| panic!("wait: {error}"));
        samples.push(start.elapsed());
    }
    report("journal-ack", bytes, &mut samples);
    let stats = journal.stats();
    println!(
        "SYNC-BENCH journal-ack-syncs {bytes} barrier={} full={} batches={}",
        stats.barrier_syncs, stats.full_syncs, stats.batches
    );
}

#[test]
fn sync_bench_measures_each_primitive_on_this_host() {
    if !enabled() {
        println!("SYNC-BENCH SKIP (runs in a fleet step whose key contains sync-bench)");
        return;
    }
    // In the step's checkout: the disk the daemons use on this host, not a tmpfs.
    let root = std::env::current_dir()
        .unwrap_or_else(|error| panic!("current dir: {error}"))
        .join("target")
        .join("sync-bench");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap_or_else(|error| panic!("mkdir: {error}"));
    println!("SYNC-BENCH host os={} root={}", std::env::consts::OS, root.display());
    for bytes in SIZES {
        time_storage(&root, "write-only", bytes, None);
        time_storage(&root, "barrier", bytes, Some(SyncLevel::Barrier));
        time_storage(&root, "full", bytes, Some(SyncLevel::Full));
        time_std_sync_data(&root, bytes);
        time_journal_ack(&root, bytes);
    }
    let _ = std::fs::remove_dir_all(&root);
}
