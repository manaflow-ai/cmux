//! The crash simulation (R-DURABILITY acceptance A1). In each epoch, clients append and wait for
//! acks while the storage crashes at a random operation, and sometimes fails one write or sync
//! before it. Then the next process opens the journal, and sometimes crashes inside that recovery
//! too, before a new epoch of appends. After each open that succeeds:
//!
//! - every record is exactly what was appended at its LSN (nothing half applied);
//! - every record an earlier open replayed comes back, first and in order;
//! - after them come the last epoch's records, as a prefix of its appends (a lost tail is a
//!   suffix, never a hole);
//! - that prefix reaches every record a client was told is durable (fully durable, when a power
//!   loss came since), and every written one when only processes crashed and no write or sync
//!   failed;
//! - a crash is never reported as damage.
//!
//! `CMUX_JOURNAL_CRASH_SEEDS` seeds per test (default 200; the acceptance run in
//! R-DURABILITY/DESIGN.md section 7 uses 100000 on the fleet). A failing seed prints itself:
//! rerun it with `CMUX_JOURNAL_CRASH_SEED=<seed>`. The clients run on threads, so a seed fixes the
//! faults and the record sizes but not where batches end: a rerun can take another path and pass.
//! The random runs are the acceptance property. The forced run below is the red/green proof: it
//! fails every seed on the code before the S1 fix.
//!
//! The S1 review found an order (F4) that the random faults reached in 1 of 800 runs: a sync
//! fails and drops its pages, the process is killed in the writer's backoff, the next open goes
//! on from the page cache, and an OS crash or a power loss follows. So one epoch in four of the
//! random runs aims the failed sync and the crash at it (only the mixed run has both a process
//! crash and an OS crash, so only it can fail on that order), and one more run forces the order on
//! every seed.
//!
//! The last tests check the simulated machine itself: the write-back error behavior, the aimed
//! faults, and the ordered log of names that the crash runs depend on.

use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::{
    Class, Config, Crash, Journal, Lsn, OpenError, OpenMode, OpenReport, SIM_PAGE, SimRng,
    SimStorage, Storage, SyncLevel, WaitError,
};

/// LSN to (class, payload): what was appended, in every epoch.
type Model = Arc<Mutex<BTreeMap<Lsn, (Class, Vec<u8>)>>>;
/// One record as a replay saw it: (lsn, kind, class, payload).
type Seen = Vec<(Lsn, u16, Class, Vec<u8>)>;

const KIND: u16 = 4;

fn dir() -> PathBuf {
    PathBuf::from("/sim/journal")
}

fn open(storage: &SimStorage, config: &Config) -> Result<(Journal, OpenReport, Seen), OpenError> {
    let mut seen = Vec::new();
    let (journal, report) =
        Journal::open(Arc::new(storage.clone()), &dir(), config.clone(), 0, &mut |record| {
            seen.push((record.lsn, record.kind, record.class, record.payload.to_vec()));
            Ok(())
        })?;
    Ok((journal, report, seen))
}

/// What one epoch of appends leaves to check.
struct Epoch {
    /// The LSN the epoch's first append took.
    start: Lsn,
    /// The highest acked, fully durable and written LSN, as the clients and the writer saw them.
    durable: Lsn,
    full_durable: Lsn,
    written: Lsn,
    /// A write or sync failed in the epoch (not by the crash).
    failed: bool,
}

fn rank(crash: Crash) -> u8 {
    match crash {
        Crash::Process => 0,
        Crash::Os => 1,
        Crash::PowerLoss => 2,
    }
}

/// The crash of the two that loses more.
fn worse(a: Crash, b: Crash) -> Crash {
    if rank(b) > rank(a) { b } else { a }
}

fn pick(kinds: &[Crash], rng: &mut SimRng) -> Crash {
    kinds.get(rng.index(kinds.len())).copied().unwrap_or(Crash::Process)
}

fn seeds() -> Vec<u64> {
    if let Some(seed) = std::env::var("CMUX_JOURNAL_CRASH_SEED").ok().and_then(|s| s.parse().ok()) {
        return vec![seed];
    }
    let count = std::env::var("CMUX_JOURNAL_CRASH_SEEDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(200u64);
    (0..count).collect()
}

/// What goes wrong in each epoch of a crash run.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Faults {
    /// In each epoch, at random: a crash at a random operation, sometimes after a failed write or
    /// sync; or (one epoch in four) the aimed fault below, with the crash at one of the three
    /// operations after the failed sync and a crash of any kind after it.
    Random,
    /// In the first epoch, the first sync of a write that spans pages fails and the disk gets none
    /// of them; the process is killed at the next storage operation (the writer's retry, after
    /// its backoff). The open after the kill does not crash, so it reads the failed segment from
    /// the page cache. The next epoch ends in an OS crash, which loses every page the failed sync
    /// dropped, and a third open checks what is left. The code before the S1 fix fails every seed.
    FailedSyncThenKill,
}

fn crash_run(seed: u64, kinds: &[Crash]) -> Result<(), String> {
    crash_run_with(seed, kinds, Faults::Random)
}

fn crash_run_with(seed: u64, kinds: &[Crash], faults: Faults) -> Result<(), String> {
    let mut rng = SimRng::new(seed);
    let mut storage = SimStorage::new(rng.next_u64());
    let config = Config {
        segment_bytes: 300 + rng.below(3000),
        max_pending_bytes: 1 << 20,
        full_sync_interval: Duration::from_millis(rng.below(4)),
        stream_sync_delay: Duration::from_millis(rng.below(3)),
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(2),
    };
    let model: Model = Arc::default();
    let mut kept: Vec<Lsn> = Vec::new();
    let mut last: Option<Epoch> = None;
    let mut worst = Crash::Process;
    let epochs = match faults {
        Faults::FailedSyncThenKill => 2,
        Faults::Random => 1 + rng.below(3),
    };
    for epoch in 0..=epochs {
        // The open, which may crash inside recovery; the next process tries again.
        let mut attempts = 0;
        let (journal, report, seen) = loop {
            attempts += 1;
            if faults == Faults::Random && attempts < 4 && rng.below(2) == 0 {
                storage.crash_after(1 + rng.below(40));
            }
            match open(&storage, &config) {
                Ok(opened) => break opened,
                Err(_) if storage.is_crashed() => {
                    let crash = pick(kinds, &mut rng);
                    worst = worse(worst, crash);
                    storage = storage.restart(crash);
                }
                Err(error) => return Err(format!("epoch {epoch}: open: {error}")),
            }
        };
        check(&seen, &report, &kept, last.as_ref(), worst, &model)
            .map_err(|error| format!("epoch {epoch}: {error}"))?;
        kept = seen.iter().map(|record| record.0).collect();
        if epoch == epochs {
            return Ok(());
        }
        // This epoch's faults. Each replaces a crash point the open did not reach.
        let aimed = match faults {
            Faults::FailedSyncThenKill => epoch == 0,
            Faults::Random => rng.below(4) == 0,
        };
        if aimed {
            // The first sync of a batch: every record spans two pages (`appends`), so it has two.
            storage.fail_next_sync(2, ErrorKind::Other);
            let after = if faults == Faults::Random { 1 + rng.below(3) } else { 1 };
            storage.crash_after_failure(after);
        } else {
            storage.crash_after(1 + rng.below(80));
            if rng.below(2) == 0 {
                let kind =
                    if rng.below(2) == 0 { ErrorKind::StorageFull } else { ErrorKind::Other };
                storage.fail_after(1 + rng.below(40), kind);
            }
        }
        let start = report.next_lsn;
        let (durable, full_durable) =
            appends(seed ^ epoch, &journal, &storage, &model, &mut rng, aimed);
        let stats = journal.stats();
        last = Some(Epoch {
            start,
            durable: durable.max(stats.durable_lsn),
            full_durable: full_durable.max(stats.full_durable_lsn),
            written: stats.written_lsn,
            failed: storage.failures() > 0,
        });
        drop(journal);
        if faults == Faults::FailedSyncThenKill
            && aimed
            && (storage.failures() == 0 || !storage.is_crashed())
        {
            return Err(format!("epoch {epoch}: the aimed failed sync and kill did not happen"));
        }
        let crash = match faults {
            Faults::FailedSyncThenKill if epoch == 0 => Crash::Process,
            Faults::FailedSyncThenKill => Crash::Os,
            Faults::Random => pick(kinds, &mut rng),
        };
        worst = crash;
        storage = storage.restart(crash);
    }
    Ok(())
}

/// Clients append and wait for their acks until the storage crashes. Returns the highest acked
/// and the highest fully durable LSN a client saw.
fn appends(
    seed: u64,
    journal: &Journal,
    storage: &SimStorage,
    model: &Model,
    rng: &mut SimRng,
    large: bool,
) -> (Lsn, Lsn) {
    let durable = AtomicU64::new(0);
    let full_durable = AtomicU64::new(0);
    let clients = 1 + rng.below(4);
    std::thread::scope(|scope| {
        for client in 0..clients {
            let mut rng = SimRng::new(seed ^ (client + 1).wrapping_mul(0x9E37));
            let (durable, full_durable) = (&durable, &full_durable);
            scope.spawn(move || {
                for index in 0..30u64 {
                    let class = if rng.below(4) == 0 { Class::Stream } else { Class::Ack };
                    // Now and then a record over several pages; when `large`, every record spans
                    // two pages, so the first batch's sync has two dirty pages.
                    let size = if large {
                        5000 + rng.index(5000)
                    } else if rng.below(10) == 0 {
                        2000 + rng.index(8000)
                    } else {
                        rng.index(64)
                    };
                    let body = format!("{seed}-{client}-{index}-{}", "y".repeat(size));
                    let lsn = {
                        // The append and the model's copy are one step, so the model never misses
                        // an LSN the journal took.
                        let mut model = model.lock().unwrap_or_else(|e| e.into_inner());
                        let Ok(lsn) = journal.append(KIND, class, body.as_bytes()) else { break };
                        model.insert(lsn, (class, body.into_bytes()));
                        lsn
                    };
                    if class == Class::Ack {
                        if !acked(journal, storage, lsn) {
                            break;
                        }
                        durable.fetch_max(lsn, Ordering::SeqCst);
                        if journal.full_durable_lsn() >= lsn {
                            full_durable.fetch_max(lsn, Ordering::SeqCst);
                        }
                    }
                }
            });
        }
    });
    (durable.load(Ordering::SeqCst), full_durable.load(Ordering::SeqCst))
}

/// Waits until `lsn` is durable; false once the storage crashed first.
fn acked(journal: &Journal, storage: &SimStorage, lsn: Lsn) -> bool {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        match journal.wait_durable(lsn, Duration::from_millis(5)) {
            Ok(()) => return true,
            Err(WaitError::Timeout) if !storage.is_crashed() => {
                assert!(Instant::now() < deadline, "the writer stalled: {:?}", journal.stats());
            }
            Err(_) => return false,
        }
    }
}

fn check(
    seen: &Seen,
    report: &OpenReport,
    kept: &[Lsn],
    last: Option<&Epoch>,
    worst: Crash,
    model: &Model,
) -> Result<(), String> {
    if !report.damage.is_empty() {
        return Err(format!("a crash is not damage: {report:?}"));
    }
    let model = model.lock().unwrap_or_else(|e| e.into_inner());
    for (lsn, kind, class, bytes) in seen {
        match model.get(lsn) {
            Some((want_class, want)) if want_class == class && want == bytes && *kind == KIND => {}
            other => return Err(format!("record {lsn} is not what was appended: {other:?}")),
        }
    }
    let got: Vec<Lsn> = seen.iter().map(|record| record.0).collect();
    if got.get(..kept.len()) != Some(kept) {
        return Err(format!("records an earlier open replayed are gone: {kept:?}, then {got:?}"));
    }
    if report.next_lsn <= got.last().copied().unwrap_or(0) {
        return Err(format!("the next LSN reuses a recovered one: {report:?}"));
    }
    let new = got.get(kept.len()..).unwrap_or_default();
    let Some(epoch) = last else {
        return if new.is_empty() { Ok(()) } else { Err(format!("records from nowhere: {new:?}")) };
    };
    for (lsn, want) in new.iter().zip(epoch.start..) {
        if *lsn != want {
            return Err(format!("not a prefix of the appends from {}: {new:?}", epoch.start));
        }
    }
    let through = epoch.start.saturating_add(new.len() as u64).saturating_sub(1);
    let must = match worst {
        Crash::Process if !epoch.failed => epoch.durable.max(epoch.written),
        Crash::Process | Crash::Os => epoch.durable,
        Crash::PowerLoss => epoch.full_durable,
    };
    if must >= epoch.start && through < must {
        return Err(format!(
            "record {must} lost: the appends from {} came back through {through} ({worst:?}, {report:?})",
            epoch.start
        ));
    }
    Ok(())
}

fn crash_runs(kinds: &[Crash]) {
    let failures: Vec<String> = seeds()
        .into_iter()
        .filter_map(|seed| {
            crash_run(seed, kinds).err().map(|error| format!("seed {seed}: {error}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "{} {kinds:?} runs failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn process_crashes_at_any_operation_keep_every_written_record() {
    crash_runs(&[Crash::Process]);
}

#[test]
fn os_crashes_at_any_operation_keep_every_acked_record() {
    crash_runs(&[Crash::Os]);
}

#[test]
fn power_losses_keep_every_fully_synced_record_and_a_prefix() {
    crash_runs(&[Crash::PowerLoss]);
}

#[test]
fn mixed_crashes_keep_what_the_worst_of_them_keeps() {
    crash_runs(&[Crash::Process, Crash::Os, Crash::PowerLoss]);
}

/// F4 of the S1 review: a sync fails and drops its pages, the process is killed before the writer
/// tries again, and later an OS crash comes. Every record the open after the kill replayed, and
/// every record acked after it, must survive. With random faults this order is rare (the random
/// runs found it once in 800 runs on the code before the fix), so each seed here forces it.
#[test]
fn a_kill_after_a_failed_sync_then_os_crashes_keep_every_acked_record() {
    let failures: Vec<String> = seeds()
        .into_iter()
        .filter_map(|seed| {
            crash_run_with(seed, &[Crash::Os], Faults::FailedSyncThenKill)
                .err()
                .map(|error| format!("seed {seed}: {error}"))
        })
        .collect();
    assert!(failures.is_empty(), "{} runs failed:\n{}", failures.len(), failures.join("\n"));
}

// ---------------------------------------------------------------- the simulated machine

/// A folder with one empty file in it, all durable.
fn machine_with_file(seed: u64, path: &Path) -> (SimStorage, Box<dyn crate::StorageFile>) {
    let storage = SimStorage::new(seed);
    let folder = path.parent().unwrap_or(Path::new("/"));
    storage.create_dir_all(folder).unwrap_or_else(|e| panic!("mkdir: {e}"));
    let file = storage.open(path, OpenMode::Create).unwrap_or_else(|e| panic!("create: {e}"));
    for dir in folder.ancestors() {
        storage.sync_dir(dir).unwrap_or_else(|e| panic!("sync {}: {e}", dir.display()));
    }
    (storage, file)
}

#[test]
fn the_sim_never_writes_the_pages_a_failed_sync_dropped() {
    let mut dropped = 0;
    for seed in 0..64 {
        let path = dir().join("file");
        let (storage, mut file) = machine_with_file(seed, &path);
        let page = |byte: u8| vec![byte; SIM_PAGE];
        file.append(&page(1)).unwrap_or_else(|e| panic!("{e}"));
        file.sync(SyncLevel::Full).unwrap_or_else(|e| panic!("{e}"));
        file.append(&[page(2), page(2)].concat()).unwrap_or_else(|e| panic!("{e}"));
        storage.fail_after(1, ErrorKind::Other);
        assert!(file.sync(SyncLevel::Full).is_err());
        // A later sync reports success, and reads still see every byte.
        file.sync(SyncLevel::Full).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(storage.contents(&path).map(|bytes| bytes.len()), Some(3 * SIM_PAGE));
        let after = storage.restart(Crash::Os).contents(&path).unwrap_or_default();
        assert_eq!(after.get(..SIM_PAGE), Some(page(1).as_slice()), "seed {seed}");
        for chunk in after.get(SIM_PAGE..).unwrap_or_default().chunks(SIM_PAGE) {
            // A page the failed sync wrote, or one it dropped, which never reached the disk.
            assert!(chunk == page(2).as_slice() || chunk == page(0).as_slice(), "seed {seed}");
            dropped += usize::from(chunk == page(0).as_slice());
        }
    }
    assert!(dropped > 0, "no failed sync dropped a page");
}

#[test]
fn the_sim_fails_the_aimed_sync_and_crashes_in_the_backoff() {
    let path = dir().join("file");
    let (storage, mut file) = machine_with_file(9, &path);
    storage.fail_next_sync(2, ErrorKind::Other);
    storage.crash_after_failure(2);
    // One dirty page: the aimed failure waits for a sync of more.
    file.append(&[1; 100]).unwrap_or_else(|e| panic!("{e}"));
    file.sync(SyncLevel::Barrier).unwrap_or_else(|e| panic!("{e}"));
    file.append(&vec![2; 2 * SIM_PAGE]).unwrap_or_else(|e| panic!("{e}"));
    assert!(file.sync(SyncLevel::Barrier).is_err(), "the aimed sync did not fail");
    assert_eq!(storage.failures(), 1);
    assert!(file.size().is_ok(), "the first operation after the failure must run");
    assert!(file.size().is_err() && storage.is_crashed(), "the second must be the crash");
    // None of the failed sync's pages reached the disk.
    let after = storage.restart(Crash::Os).contents(&path).unwrap_or_default();
    assert!(after.iter().skip(100).all(|byte| *byte != 2), "a dropped page reached the disk");
}

#[test]
fn the_sim_keeps_a_rename_between_folders_whole() {
    let (mut moved, mut stayed) = (0, 0);
    for seed in 0..64 {
        let from = dir().join("a").join("file");
        let to = dir().join("b").join("file");
        let (storage, _file) = machine_with_file(seed, &from);
        storage.create_dir_all(&dir().join("b")).unwrap_or_else(|e| panic!("{e}"));
        storage.sync_dir(&dir()).unwrap_or_else(|e| panic!("{e}"));
        storage.rename(&from, &to).unwrap_or_else(|e| panic!("{e}"));
        // No folder sync: an OS crash keeps the rename or not, never half of it.
        let after = storage.restart(Crash::Os);
        let a = after.names_in(&dir().join("a")).len();
        let b = after.names_in(&dir().join("b")).len();
        assert_eq!(a + b, 1, "seed {seed}: the file is in {a} + {b} folders");
        moved += b;
        stayed += a;
    }
    assert!(moved > 0 && stayed > 0, "{moved} moved, {stayed} stayed");
}

#[test]
fn the_sim_keeps_a_rename_its_folder_sync_made_durable() {
    for seed in 0..32 {
        let from = dir().join("file.new");
        let to = dir().join("file");
        let (storage, _file) = machine_with_file(seed, &from);
        storage.rename(&from, &to).unwrap_or_else(|e| panic!("{e}"));
        storage.sync_dir(&dir()).unwrap_or_else(|e| panic!("{e}"));
        for crash in [Crash::Os, Crash::PowerLoss] {
            let after = storage.snapshot(crash);
            assert_eq!(after.names_in(&dir()), vec!["file".to_owned()], "seed {seed}, {crash:?}");
        }
    }
}
