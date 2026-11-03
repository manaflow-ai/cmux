//! Tests of the journal: format, group commit, ack after durable, recovery, failures, and the
//! crash simulation (every acked record survives a crash at any storage operation; nothing is
//! half applied; the lost tail is a suffix).
//!
//! The crash simulation runs `CMUX_JOURNAL_CRASH_SEEDS` seeds per crash kind (default 200; the
//! acceptance run in R-DURABILITY/DESIGN.md section 7 uses 100000 on the fleet). A failing seed
//! prints itself: rerun it alone with `CMUX_JOURNAL_CRASH_SEED=<seed>`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::format::{self, SEGMENT_HEADER_LEN};
use crate::{
    AppendError, Class, Config, Crash, Damage, FsStorage, Journal, Lsn, OpenError, OpenReport,
    SimRng, SimStorage, Storage, WaitError,
};

const WAIT: Duration = Duration::from_secs(10);

/// One record as a replay saw it: (lsn, kind, class, payload).
type SeenRecord = (Lsn, u16, Class, Vec<u8>);
type Seen = Vec<SeenRecord>;
/// What the crash runs appended: LSN to (class, payload).
type Model = Arc<Mutex<BTreeMap<Lsn, (Class, Vec<u8>)>>>;

fn dir() -> PathBuf {
    PathBuf::from("/sim/journal")
}

fn quick() -> Config {
    Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        stream_sync_delay: Duration::from_millis(20),
        ..Config::default()
    }
}

/// Opens the journal in `storage` from compaction point `from`.
fn open_at(
    storage: &SimStorage,
    config: Config,
    from: Lsn,
) -> Result<(Journal, OpenReport, Seen), OpenError> {
    let mut seen = Vec::new();
    let (journal, report) =
        Journal::open(Arc::new(storage.clone()), &dir(), config, from, &mut |record| {
            seen.push((record.lsn, record.kind, record.class, record.payload.to_vec()));
            Ok(())
        })?;
    Ok((journal, report, seen))
}

fn open(storage: &SimStorage) -> (Journal, OpenReport, Seen) {
    open_at(storage, quick(), 0).unwrap_or_else(|error| panic!("open: {error}"))
}

fn lsns(seen: &[SeenRecord]) -> Vec<Lsn> {
    seen.iter().map(|record| record.0).collect()
}

fn payload(lsn: Lsn) -> Vec<u8> {
    format!("record-{lsn}-{}", "x".repeat(usize::try_from(lsn % 97).unwrap_or(0))).into_bytes()
}

/// Polls `check` for up to 5 s.
fn eventually(check: impl Fn() -> bool) -> bool {
    (0..1000).any(|_| {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
        false
    })
}

#[test]
fn a_zero_record_header_never_checks_out() {
    let header = [0u8; format::RECORD_HEADER_LEN];
    let decoded = format::RecordHeader::decode(&header).unwrap_or_else(|| panic!("decode"));
    assert!(decoded.verify(&header, &[], 0).is_err(), "a zeroed header must fail its checksum");
}

#[test]
fn segment_names_sort_and_parse_for_every_number() {
    for seq in [0, 1, 42, u64::MAX] {
        assert_eq!(format::parse_segment_name(&format::segment_name(seq)), Some(seq));
    }
    assert!(format::segment_name(9) < format::segment_name(10));
    assert_eq!(format::parse_segment_name("LOCK"), None);
    assert_eq!(format::parse_segment_name("42.seg"), None);
}

#[test]
fn records_round_trip_in_order_across_a_reopen() {
    let storage = SimStorage::new(1);
    let (journal, report, seen) = open(&storage);
    assert!(seen.is_empty());
    assert_eq!(report.next_lsn, 1);
    for lsn in 1..=50u64 {
        let class = if lsn.is_multiple_of(3) { Class::Stream } else { Class::Ack };
        assert_eq!(journal.append(7, class, &payload(lsn)), Ok(lsn));
    }
    journal.wait_durable(49, WAIT).unwrap_or_else(|error| panic!("wait: {error}"));
    assert_eq!(journal.seal(WAIT), Ok(50));
    drop(journal);
    let (journal, report, seen) = open(&storage.restart(Crash::PowerLoss));
    assert_eq!(report.replayed, 50);
    assert_eq!(report.next_lsn, 51);
    assert_eq!(report.damage, Vec::new());
    assert_eq!(lsns(&seen), (1..=50).collect::<Vec<_>>());
    for (lsn, kind, class, bytes) in &seen {
        assert_eq!(*kind, 7);
        assert_eq!(*class, if lsn.is_multiple_of(3) { Class::Stream } else { Class::Ack });
        assert_eq!(*bytes, payload(*lsn));
    }
    assert_eq!(journal.append(7, Class::Ack, b"next"), Ok(51));
}

#[test]
fn replay_starts_after_the_compaction_point() {
    let storage = SimStorage::new(2);
    let (journal, _, _) = open(&storage);
    for lsn in 1..=20 {
        assert_eq!(journal.append(1, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    assert_eq!(journal.seal(WAIT), Ok(20));
    drop(journal);
    let (_, report, seen) =
        open_at(&storage.restart(Crash::Process), quick(), 12).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), (13..=20).collect::<Vec<_>>());
    assert_eq!(report.replayed, 8);
}

#[test]
fn an_ack_is_not_reported_before_its_sync_ends() {
    let storage = SimStorage::new(3);
    let (journal, _, _) = open(&storage);
    storage.set_sync_delay(Duration::from_millis(300));
    let lsn = journal.append(1, Class::Ack, b"draft: hello").unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.stats().written_lsn >= lsn), "the record was never written");
    // Written, and its sync takes 300 ms: not durable, so no reply may say it is.
    assert_eq!(journal.durable_lsn(), 0);
    assert_eq!(journal.wait_durable(lsn, Duration::from_millis(50)), Err(WaitError::Timeout));
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(journal.stats().barrier_syncs + journal.stats().full_syncs >= 1);
}

#[test]
fn a_burst_shares_one_sync_per_batch() {
    let storage = SimStorage::new(4);
    let (journal, _, _) = open(&storage);
    storage.set_sync_delay(Duration::from_millis(20));
    let journal = Arc::new(journal);
    let threads: Vec<_> = (0..8u64)
        .map(|thread| {
            let journal = journal.clone();
            std::thread::spawn(move || {
                for index in 0..50u64 {
                    let lsn = journal
                        .append(2, Class::Ack, &payload(thread * 1000 + index))
                        .unwrap_or_else(|e| panic!("{e}"));
                    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap_or_else(|_| panic!("a client thread panicked"));
    }
    let stats = journal.stats();
    assert_eq!(stats.records, 400);
    let syncs = stats.barrier_syncs + stats.full_syncs;
    // One sync per record would be 400; with 8 clients waiting at once, a batch holds several.
    assert!(syncs < 200, "group commit: {syncs} syncs for 400 acked records ({stats:?})");
    assert!(stats.max_batch_records >= 4, "{stats:?}");
}

#[test]
fn durable_listeners_see_each_advance_in_order() {
    let storage = SimStorage::new(5);
    let (journal, _, _) = open(&storage);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = seen.clone();
    journal.on_durable(move |lsn| sink.lock().unwrap_or_else(|e| e.into_inner()).push(lsn));
    for lsn in 1..=30 {
        assert_eq!(journal.append(1, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    let heard = || seen.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert!(eventually(|| heard().last() == Some(&30)), "{:?}", heard());
    let heard = heard();
    assert!(heard.windows(2).all(|pair| pair.first() < pair.get(1)), "{heard:?}");
}

#[test]
fn a_stream_record_is_written_at_once_and_synced_after_its_delay() {
    let storage = SimStorage::new(6);
    let config = Config { stream_sync_delay: Duration::from_millis(300), ..quick() };
    let (journal, _, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    let lsn = journal.append(9, Class::Stream, b"output").unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.stats().written_lsn >= lsn), "{:?}", journal.stats());
    assert_eq!(journal.durable_lsn(), 0, "a stream record alone is not synced at once");
    // Written, so a kill of every process now keeps it.
    let (_, _, seen) = open(&storage.snapshot(Crash::Process));
    assert_eq!(seen.first().map(|record| record.3.clone()), Some(b"output".to_vec()));
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
}

#[test]
fn an_idle_journal_touches_no_storage() {
    let storage = SimStorage::new(7);
    let config = Config { full_sync_interval: Duration::from_millis(50), ..quick() };
    let (journal, _, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    let lsn = journal.append(1, Class::Ack, b"x").unwrap_or_else(|e| panic!("{e}"));
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.full_durable_lsn() >= lsn), "{:?}", journal.stats());
    let before = storage.ops();
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(storage.ops(), before, "an idle journal touched the storage");
}

#[test]
fn a_full_sync_follows_the_first_barrier_sync_within_the_interval() {
    let storage = SimStorage::new(8);
    let config = Config { full_sync_interval: Duration::from_millis(500), ..quick() };
    let (journal, _, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    let lsn = journal.append(1, Class::Ack, b"x").unwrap_or_else(|e| panic!("{e}"));
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.stats().full_syncs, 0, "the ack waited for a drive cache flush");
    assert!(eventually(|| journal.full_durable_lsn() >= lsn), "{:?}", journal.stats());
    // A power loss now keeps it.
    let (_, _, seen) = open(&storage.snapshot(Crash::PowerLoss));
    assert_eq!(lsns(&seen), vec![lsn]);
}

#[test]
fn appends_past_the_pending_cap_fail_without_waiting() {
    let storage = SimStorage::new(9);
    let config = Config { max_pending_bytes: 4096, ..quick() };
    let (journal, _, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    storage.set_sync_delay(Duration::from_millis(500));
    let big = vec![b'a'; 1000];
    let refused = (0..50).any(|_| match journal.append(1, Class::Ack, &big) {
        Ok(_) => false,
        Err(AppendError::Backlog) => true,
        Err(other) => panic!("unexpected {other}"),
    });
    assert!(refused, "the pending cap never refused an append");
    let too_large = vec![0u8; crate::MAX_PAYLOAD_LEN + 1];
    assert_eq!(journal.append(1, Class::Ack, &too_large), Err(AppendError::TooLarge));
}

#[test]
fn a_sealed_journal_refuses_appends() {
    let storage = SimStorage::new(10);
    let (journal, _, _) = open(&storage);
    assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
    assert_eq!(journal.seal(WAIT), Ok(1));
    assert_eq!(journal.append(1, Class::Ack, b"b"), Err(AppendError::Closed));
    assert_eq!(journal.full_durable_lsn(), 1);
}

#[test]
fn a_second_writer_is_refused_while_the_first_holds_the_lock() {
    let storage = SimStorage::new(11);
    let (first, _, _) = open(&storage);
    assert!(matches!(open_at(&storage, quick(), 0), Err(OpenError::Locked)));
    drop(first);
    assert!(open_at(&storage, quick(), 0).is_ok());
}

#[test]
fn segments_rotate_and_recovery_reads_across_them() {
    let storage = SimStorage::new(12);
    let config = Config { segment_bytes: 600, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=40 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(journal.stats().segments_created >= 3, "{:?}", journal.stats());
    drop(journal);
    let (_, report, seen) =
        open_at(&storage.restart(Crash::PowerLoss), config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), (1..=40).collect::<Vec<_>>(), "{report:?}");
    assert!(report.segments >= 4);
    // From a compaction point in a later segment, the earlier segments' records are not read.
    let storage = storage.restart(Crash::Process);
    let (_, _, seen) = open_at(&storage, quick(), 35).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), (36..=40).collect::<Vec<_>>());
    assert_eq!(storage.reads(&dir().join(format::segment_name(1))), 1, "only its header");
}

#[test]
fn a_failed_write_retries_in_the_same_segment() {
    let storage = SimStorage::new(13);
    let (journal, _, _) = open(&storage);
    // The batch's write is the next storage operation; a full disk refuses it once.
    storage.fail_after(1, std::io::ErrorKind::StorageFull);
    let lsn = journal.append(1, Class::Ack, b"draft").unwrap_or_else(|e| panic!("{e}"));
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let stats = journal.stats();
    assert_eq!((stats.failures, stats.segments_created, stats.failing), (1, 0, None));
    drop(journal);
    let (_, report, seen) = open(&storage.restart(Crash::PowerLoss));
    assert_eq!(lsns(&seen), vec![1], "{report:?}");
}

#[test]
fn a_failed_sync_never_syncs_that_segment_again() {
    let storage = SimStorage::new(14);
    let (journal, _, _) = open(&storage);
    assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
    journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
    // Settled: the full sync of the power-loss window ran, so the next operations are the batch's.
    assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
    // The next batch: its write (1), then its sync (2), which fails.
    storage.fail_after(2, std::io::ErrorKind::Other);
    assert_eq!(journal.append(1, Class::Ack, b"b"), Ok(2));
    journal.wait_durable(2, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let stats = journal.stats();
    assert_eq!((stats.failures, stats.segments_created), (1, 1), "{stats:?}");
    drop(journal);
    let restarted = storage.restart(Crash::PowerLoss);
    assert_eq!(restarted.names_in(&dir()).iter().filter(|name| name.ends_with(".seg")).count(), 2);
    let (_, report, seen) = open(&restarted);
    assert_eq!(lsns(&seen), vec![1, 2], "{report:?}");
    assert!(report.damage.is_empty(), "{report:?}");
}

#[test]
fn every_acked_record_survives_a_failure_at_any_operation() {
    for at in 1..12 {
        let storage = SimStorage::new(15 + at);
        let (journal, _, _) = open(&storage);
        assert_eq!(journal.append(1, Class::Ack, b"before"), Ok(1));
        journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
        storage.fail_after(at, std::io::ErrorKind::Other);
        for index in 0..10 {
            let lsn =
                journal.append(1, Class::Ack, &payload(index)).unwrap_or_else(|e| panic!("{e}"));
            journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("failure at op {at}: {e}"));
        }
        assert!(journal.stats().failures <= 1);
        drop(journal);
        let (_, report, seen) = open(&storage.restart(Crash::PowerLoss));
        assert_eq!(lsns(&seen), (1..=11).collect::<Vec<_>>(), "failure at op {at}: {report:?}");
        assert!(report.damage.is_empty(), "failure at op {at}: {report:?}");
    }
}

#[test]
fn a_torn_tail_stays_in_its_file_and_the_journal_goes_on_after_it() {
    let storage = SimStorage::new(40);
    let (journal, _, _) = open(&storage);
    assert_eq!(journal.append(1, Class::Ack, b"one"), Ok(1));
    assert_eq!(journal.seal(WAIT), Ok(1));
    drop(journal);
    let first = dir().join(format::segment_name(1));
    // A crash in the middle of the next write: half a record.
    let mut torn = storage.contents(&first).unwrap_or_default();
    torn.extend_from_slice(&[0x33; 9]);
    let crashed = storage.restart(Crash::Process);
    write_whole(&crashed, &first, &torn);
    let (journal, report, seen) = open(&crashed);
    assert_eq!((lsns(&seen), report.torn_tail_bytes), (vec![1], 9));
    assert_eq!(crashed.contents(&first), Some(torn), "recovery shortened a segment");
    assert_eq!(journal.append(1, Class::Ack, b"two"), Ok(2));
    assert_eq!(journal.seal(WAIT), Ok(2));
    drop(journal);
    let (_, report, seen) = open(&crashed.restart(Crash::PowerLoss));
    assert_eq!(lsns(&seen), vec![1, 2]);
    assert_eq!(report.torn_tail_bytes, 0);
    assert!(report.damage.is_empty(), "{report:?}");
}

#[test]
fn a_damaged_segment_in_the_middle_is_quarantined_and_its_lsns_are_never_reused() {
    let storage = SimStorage::new(31);
    let config = Config { segment_bytes: 400, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=30 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(journal.stats().segments_created >= 3);
    drop(journal);
    // Media damage in the first record of segment 2.
    storage.corrupt(&dir().join(format::segment_name(2)), SEGMENT_HEADER_LEN + 2);
    let restarted = storage.restart(Crash::Process);
    let (journal, report, seen) = open_at(&restarted, config, 0).unwrap_or_else(|e| panic!("{e}"));
    let kept = Lsn::try_from(seen.len()).unwrap_or(0);
    assert!((1..30).contains(&kept), "the valid prefix stays: {kept}");
    assert_eq!(lsns(&seen), (1..=kept).collect::<Vec<_>>());
    match report.damage.first() {
        Some(Damage::Corrupt { moved, lost_after, lost_through, .. }) => {
            assert_eq!((*lost_after, *lost_through), (kept, 30), "{report:?}");
            assert!(!moved.is_empty());
        }
        other => panic!("no damage report: {other:?}"),
    }
    assert!(!restarted.names_in(&dir().join("quarantine")).is_empty(), "kept for a salvage");
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(31));
}

#[test]
fn a_compaction_point_past_the_end_never_reuses_an_lsn() {
    let storage = SimStorage::new(32);
    let (journal, _, _) = open(&storage);
    assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
    assert_eq!(journal.seal(WAIT), Ok(1));
    drop(journal);
    let (journal, report, _) =
        open_at(&storage.restart(Crash::Process), quick(), 9).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(report.damage, vec![Damage::Ahead { journal_end: 1, from: 9 }]);
    assert_eq!(journal.append(1, Class::Ack, b"b"), Ok(10));
    assert_eq!(journal.seal(WAIT), Ok(10));
    drop(journal);
    let (_, report, seen) =
        open_at(&storage.restart(Crash::PowerLoss), quick(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), vec![1, 10]);
    assert!(report.damage.is_empty(), "{report:?}");
}

#[test]
fn a_replay_error_stops_the_open() {
    let storage = SimStorage::new(33);
    let (journal, _, _) = open(&storage);
    assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
    assert_eq!(journal.seal(WAIT), Ok(1));
    drop(journal);
    let failed =
        Journal::open(Arc::new(storage.restart(Crash::Process)), &dir(), quick(), 0, &mut |_| {
            Err("no".into())
        });
    assert!(matches!(failed, Err(OpenError::Replay { lsn: 1, .. })));
}

/// Replaces `path`'s bytes in `storage` (a test's own damage).
fn write_whole(storage: &SimStorage, path: &Path, bytes: &[u8]) {
    let mut file = storage
        .open(path, crate::OpenMode::Create)
        .unwrap_or_else(|e| panic!("open {}: {e}", path.display()));
    file.append(bytes).unwrap_or_else(|e| panic!("write: {e}"));
    file.sync(crate::SyncLevel::Full).unwrap_or_else(|e| panic!("sync: {e}"));
}

// ---------------------------------------------------------------- crash simulation

/// Seeds per crash kind (module docs).
fn crash_seeds() -> Vec<u64> {
    if let Some(seed) = std::env::var("CMUX_JOURNAL_CRASH_SEED").ok().and_then(|s| s.parse().ok()) {
        return vec![seed];
    }
    let count = std::env::var("CMUX_JOURNAL_CRASH_SEEDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(200u64);
    (0..count).collect()
}

/// Waits until `lsn` is durable; false once the storage crashed first.
fn acked(journal: &Journal, storage: &SimStorage, lsn: Lsn) -> bool {
    loop {
        match journal.wait_durable(lsn, Duration::from_millis(5)) {
            Ok(()) => return true,
            Err(WaitError::Timeout) if !storage.is_crashed() => {}
            Err(_) => return false,
        }
    }
}

/// One crash run: clients append and wait while the storage crashes at a random operation; then
/// recovery runs. Every recovered record must be exactly what was appended at its LSN, the
/// records must be 1..=n, and n must reach every record a client was told is durable (fully
/// durable, for a power loss), and every written record for a process crash.
fn crash_run(seed: u64, crash: Crash) -> Result<(), String> {
    let mut rng = SimRng::new(seed);
    let storage = SimStorage::new(rng.next_u64());
    let config = Config {
        segment_bytes: 300 + rng.below(3000),
        max_pending_bytes: 1 << 20,
        full_sync_interval: Duration::from_millis(rng.below(4)),
        stream_sync_delay: Duration::from_millis(rng.below(3)),
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(2),
    };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).map_err(|e| e.to_string())?;
    let journal = Arc::new(journal);
    let appended: Model = Arc::default();
    let durable = Arc::new(AtomicU64::new(0));
    let full_durable = Arc::new(AtomicU64::new(0));
    storage.crash_after(1 + rng.below(80));
    let clients = 1 + rng.below(4);
    let threads: Vec<_> = (0..clients)
        .map(|client| {
            let journal = journal.clone();
            let storage = storage.clone();
            let appended = appended.clone();
            let durable = durable.clone();
            let full_durable = full_durable.clone();
            let mut rng = SimRng::new(seed ^ (client + 1).wrapping_mul(0x9E37));
            std::thread::spawn(move || {
                for index in 0..30u64 {
                    let class = if rng.below(4) == 0 { Class::Stream } else { Class::Ack };
                    let body = format!("{seed}-{client}-{index}-{}", "y".repeat(rng.index(64)));
                    let lsn = {
                        // The append and the model's copy are one step, so the model never misses
                        // an LSN the journal took.
                        let mut model = appended.lock().unwrap_or_else(|e| e.into_inner());
                        let Ok(lsn) = journal.append(4, class, body.as_bytes()) else { break };
                        model.insert(lsn, (class, body.into_bytes()));
                        lsn
                    };
                    if class == Class::Ack {
                        if !acked(&journal, &storage, lsn) {
                            break;
                        }
                        durable.fetch_max(lsn, Ordering::SeqCst);
                        if journal.full_durable_lsn() >= lsn {
                            full_durable.fetch_max(lsn, Ordering::SeqCst);
                        }
                    }
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().map_err(|_| "a client thread panicked".to_owned())?;
    }
    let stats = journal.stats();
    durable.fetch_max(stats.durable_lsn, Ordering::SeqCst);
    full_durable.fetch_max(stats.full_durable_lsn, Ordering::SeqCst);
    drop(journal);
    let restarted = storage.restart(crash);
    let (_, report, seen) = open_at(&restarted, config, 0).map_err(|e| e.to_string())?;
    let appended = appended.lock().unwrap_or_else(|e| e.into_inner());
    for (index, (lsn, kind, class, bytes)) in seen.iter().enumerate() {
        let position = Lsn::try_from(index).unwrap_or(0) + 1;
        if *lsn != position {
            return Err(format!("not a prefix: record {lsn} at position {position}"));
        }
        match appended.get(lsn) {
            Some((want_class, want)) if want_class == class && want == bytes && *kind == 4 => {}
            other => return Err(format!("record {lsn} is not what was appended: {other:?}")),
        }
    }
    let last = Lsn::try_from(seen.len()).unwrap_or(0);
    let must = match crash {
        Crash::Process => durable.load(Ordering::SeqCst).max(stats.written_lsn),
        Crash::Os => durable.load(Ordering::SeqCst),
        Crash::PowerLoss => full_durable.load(Ordering::SeqCst),
    };
    if last < must {
        return Err(format!("record {must} lost: recovered 1..={last} ({crash:?}, {report:?})"));
    }
    if !report.damage.is_empty() {
        return Err(format!("a crash is not damage: {report:?}"));
    }
    Ok(())
}

fn crash_runs(crash: Crash) {
    let mut failures = Vec::new();
    for seed in crash_seeds() {
        if let Err(error) = crash_run(seed, crash) {
            failures.push(format!("seed {seed}: {error}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} {crash:?} runs failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn a_process_crash_at_any_storage_operation_keeps_every_written_record() {
    crash_runs(Crash::Process);
}

#[test]
fn an_os_crash_at_any_storage_operation_keeps_every_acked_record() {
    crash_runs(Crash::Os);
}

#[test]
fn a_power_loss_keeps_every_fully_synced_record_and_a_prefix() {
    crash_runs(Crash::PowerLoss);
}

// ---------------------------------------------------------------- real file system

#[test]
fn the_real_file_system_round_trips_and_keeps_a_torn_tail_out() {
    let root = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let dir = root.path().join("journal");
    let storage: Arc<dyn Storage> = Arc::new(FsStorage);
    let open_fs = |seen: &mut Vec<Lsn>| {
        Journal::open(storage.clone(), &dir, Config::default(), 0, &mut |record| {
            seen.push(record.lsn);
            Ok(())
        })
        .unwrap_or_else(|e| panic!("open: {e}"))
    };
    let (journal, _) = open_fs(&mut Vec::new());
    for lsn in 1..=10 {
        assert_eq!(journal.append(5, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    journal.wait_durable(10, WAIT).unwrap_or_else(|e| panic!("{e}"));
    drop(journal);
    // A torn write after the last record: half a header.
    append_raw(&dir.join(format::segment_name(1)), &[0x11; 7]);
    let mut seen = Vec::new();
    let (journal, report) = open_fs(&mut seen);
    assert_eq!(seen, (1..=10).collect::<Vec<_>>());
    assert_eq!(report.torn_tail_bytes, 7);
    assert_eq!(journal.append(5, Class::Ack, b"after"), Ok(11));
    assert_eq!(journal.seal(WAIT), Ok(11));
    drop(journal);
    let mut seen = Vec::new();
    let (_, report) = open_fs(&mut seen);
    assert_eq!(seen, (1..=11).collect::<Vec<_>>());
    assert!(report.damage.is_empty(), "{report:?}");
}

fn append_raw(path: &Path, bytes: &[u8]) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(path)
        .unwrap_or_else(|e| panic!("open {}: {e}", path.display()));
    file.write_all(bytes).unwrap_or_else(|e| panic!("append: {e}"));
}
