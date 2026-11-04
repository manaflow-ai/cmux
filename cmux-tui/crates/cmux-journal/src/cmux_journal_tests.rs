//! Tests of the journal: format, group commit, ack after durable, recovery, failures, and the
//! regressions of the S1 review (a crash inside recovery's quarantine step, a damaged last
//! header, a panic on the writer thread, a restart after a failed sync, open files at recovery).
//! The crash simulation is in `crash_sim_tests.rs`.

use std::path::{Path, PathBuf};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::format::{self, SEGMENT_HEADER_LEN};
use crate::{
    AppendError, Class, Config, Crash, Damage, FsStorage, Journal, Lsn, OpenError, OpenReport,
    SIM_PAGE, SimStorage, Storage, WaitError,
};

const WAIT: Duration = Duration::from_secs(10);

/// One record as a replay saw it: (lsn, kind, class, payload).
type SeenRecord = (Lsn, u16, Class, Vec<u8>);
type Seen = Vec<SeenRecord>;

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
    assert!(decoded.check(&header, &[]).is_err(), "a zeroed header must fail its checksum");
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

/// `check_append` says what `append` would do: a caller that checks under its own lock, writes
/// elsewhere, then appends, is never refused after it wrote (acpmux's journal store).
#[test]
fn check_append_says_what_append_would_do() {
    let storage = SimStorage::new(36);
    let config = Config { max_pending_bytes: 4096, ..quick() };
    let (journal, _, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    storage.set_sync_delay(Duration::from_millis(500));
    let big = vec![b'a'; 1000];
    let mut refused = false;
    for _ in 0..50 {
        let checked = journal.check_append(big.len());
        let appended = journal.append(1, Class::Ack, &big).map(|_| ());
        assert_eq!(checked, appended, "check_append and append disagree");
        if appended == Err(AppendError::Backlog) {
            refused = true;
            break;
        }
    }
    assert!(refused, "the pending cap never refused an append");
    assert_eq!(journal.check_append(crate::MAX_PAYLOAD_LEN + 1), Err(AppendError::TooLarge));
    storage.set_sync_delay(Duration::ZERO);
    assert!(journal.seal(WAIT).is_ok());
    assert_eq!(journal.check_append(1), Err(AppendError::Closed));
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
    // The second process: its compaction point (9) is past the journal's end (1).
    let second = storage.restart(Crash::Process);
    let (journal, report, _) = open_at(&second, quick(), 9).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(report.damage, vec![Damage::Ahead { journal_end: 1, from: 9 }]);
    assert_eq!(journal.append(1, Class::Ack, b"b"), Ok(10));
    assert_eq!(journal.seal(WAIT), Ok(10));
    drop(journal);
    let (_, report, seen) =
        open_at(&second.restart(Crash::PowerLoss), quick(), 0).unwrap_or_else(|e| panic!("{e}"));
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

// ---------------------------------------------------------------- S1 review regressions

/// 40 acked records over several segments, with media damage in the first record of segment 2
/// (so every later segment goes to quarantine at the next open); and its config.
fn damaged_in_the_middle(seed: u64) -> (SimStorage, Config) {
    let storage = SimStorage::new(seed);
    let config = Config { segment_bytes: 400, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=40 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(journal.stats().segments_created >= 3, "{:?}", journal.stats());
    drop(journal);
    storage.corrupt(&dir().join(format::segment_name(2)), SEGMENT_HEADER_LEN + 2);
    (storage.restart(Crash::Process), config)
}

/// F1: the next open after a crash in the middle of the quarantine step (after a segment moved,
/// before the segment that skips its LSNs is durable) never gives a quarantined LSN to a new record.
#[test]
fn a_crash_inside_the_quarantine_step_never_reuses_a_quarantined_lsn() {
    let (damaged, config) = damaged_in_the_middle(50);
    // Every open after the damage reports it (G2 of the re-review), also after a crash at the
    // open's last step, which no later open can see the damage from.
    // At the segment where the journal ends (N4 of the fourth review: the record is made before
    // the moves, so a crash after them never turns it into a vaguer one).
    let reports_the_loss = |report: &OpenReport| {
        report.damage.iter().any(|damage| {
            matches!(damage, Damage::Corrupt { lost_through: 40, segment, .. }
                if segment.as_str() == "00000000000000000002.seg")
        })
    };
    // And tells it once (N1 of the third review): no reported loss lies inside another one.
    let reports_it_once = |report: &OpenReport| {
        let ranges: Vec<(Lsn, Lsn)> = report
            .damage
            .iter()
            .filter_map(|damage| match damage {
                Damage::Corrupt { lost_after, lost_through, .. } => {
                    Some((*lost_after, *lost_through))
                }
                _ => None,
            })
            .collect();
        ranges.iter().enumerate().all(|(i, (after, through))| {
            ranges.iter().enumerate().all(|(j, (other_after, other_through))| {
                i == j || !(other_after <= after && through <= other_through)
            })
        })
    };
    // Every storage operation of the open is a crash point once.
    let probe = damaged.snapshot(Crash::Process);
    let (journal, report, _) = open_at(&probe, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert!(matches!(report.damage.first(), Some(Damage::Corrupt { .. })), "{report:?}");
    let operations = probe.ops();
    drop(journal);
    let mut crashed_after_a_move = 0;
    for crash in [Crash::Process, Crash::Os] {
        for at in 1..=operations {
            let storage = damaged.snapshot(Crash::Process);
            storage.crash_after(at);
            let (journal, report, opened) = match open_at(&storage, config.clone(), 0) {
                Ok((journal, report, _)) => (journal, report, storage),
                Err(_) => {
                    let restarted = storage.restart(crash);
                    if !restarted.names_in(&dir().join("quarantine")).is_empty() {
                        crashed_after_a_move += 1;
                    }
                    let (journal, report, _) = open_at(&restarted, config.clone(), 0)
                        .unwrap_or_else(|e| panic!("{crash:?} at op {at}, then open: {e}"));
                    (journal, report, restarted)
                }
            };
            assert_eq!(
                journal.append(3, Class::Ack, b"after"),
                Ok(41),
                "{crash:?} at op {at}: {report:?}"
            );
            assert!(reports_the_loss(&report), "{crash:?} at op {at}: {report:?}");
            assert!(reports_it_once(&report), "{crash:?} at op {at}: {report:?}");
            assert_names_every_quarantined_file(&opened, &report);
        }
    }
    assert!(crashed_after_a_move > 0, "no crash point fell after a move");
}

/// F2: a damaged header in the last segment: its records are read for their LSNs, so none is
/// given to a new record.
#[test]
fn a_damaged_header_in_the_last_segment_never_reuses_its_lsns() {
    let storage = SimStorage::new(51);
    let config = Config { segment_bytes: 300, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=20 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(journal.stats().segments_created >= 2, "{:?}", journal.stats());
    drop(journal);
    let last = storage
        .names_in(&dir())
        .into_iter()
        .filter(|name| name.ends_with(".seg"))
        .max()
        .unwrap_or_else(|| panic!("no segment"));
    // One byte of the journal id in its header (media damage).
    storage.corrupt(&dir().join(&last), 20);
    let (journal, report, seen) =
        open_at(&storage.restart(Crash::Process), config, 0).unwrap_or_else(|e| panic!("{e}"));
    match report.damage.first() {
        Some(Damage::Corrupt { lost_through, .. }) => assert_eq!(*lost_through, 20, "{report:?}"),
        other => panic!("no damage report: {other:?} ({report:?})"),
    }
    assert!(!seen.is_empty() && seen.len() < 20, "{report:?}");
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(21));
}

/// F3: a panic on the writer thread (here a durable listener's) closes the journal: waits end,
/// appends fail, and the listeners are dropped, so the channel a held reply waits on closes.
#[test]
fn a_panic_on_the_writer_thread_closes_the_journal() {
    let storage = SimStorage::new(52);
    let (journal, _, _) = open(&storage);
    let (sender, receiver) = std::sync::mpsc::channel();
    journal.on_durable(move |lsn| {
        let _ = sender.send(lsn);
    });
    journal.on_durable(|_| panic!("a durable listener panicked"));
    storage.set_sync_delay(Duration::from_millis(200));
    assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
    assert!(eventually(|| journal.stats().written_lsn >= 1), "{:?}", journal.stats());
    // Record 2 waits while record 1 syncs; then the listener's panic ends the writer thread.
    assert_eq!(journal.append(1, Class::Ack, b"b"), Ok(2));
    assert_eq!(receiver.recv_timeout(WAIT), Ok(1));
    assert_eq!(journal.wait_durable(2, Duration::from_secs(2)), Err(WaitError::WriterEnded));
    assert_eq!(journal.append(1, Class::Ack, b"c"), Err(AppendError::Closed));
    assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Err(RecvTimeoutError::Disconnected));
    assert!(journal.stats().failing.is_some(), "{:?}", journal.stats());
}

/// F4: a sync fails, so its pages never reach the disk, though a later sync on another descriptor
/// reports success; the process is killed before the writer tries again. Every record acked after
/// the restart survives a later OS crash.
#[test]
fn a_restart_after_a_failed_sync_keeps_every_later_ack() {
    let slow_retry = Config {
        retry_min: Duration::from_secs(60),
        retry_max: Duration::from_secs(60),
        ..quick()
    };
    for seed in 0..8 {
        let storage = SimStorage::new(53 + seed);
        let (journal, _, _) =
            open_at(&storage, slow_retry.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(journal.append(1, Class::Ack, b"a"), Ok(1));
        journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
        assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
        // Record 2 spans whole pages: its write, then its sync, which fails.
        storage.fail_after(2, std::io::ErrorKind::Other);
        assert_eq!(journal.append(1, Class::Ack, &vec![b'b'; 3 * SIM_PAGE]), Ok(2));
        assert!(eventually(|| journal.stats().failures == 1), "{:?}", journal.stats());
        assert_eq!(journal.durable_lsn(), 1);
        // A kill -9 while the writer waits to try again.
        let restarted = storage.restart(Crash::Process);
        drop(journal);
        let (journal, _, seen) = open(&restarted);
        assert_eq!(lsns(&seen), vec![1, 2], "seed {seed}");
        assert_eq!(journal.append(1, Class::Ack, b"c"), Ok(3));
        journal.wait_durable(3, WAIT).unwrap_or_else(|e| panic!("{e}"));
        drop(journal);
        let (_, report, seen) = open(&restarted.restart(Crash::Os));
        assert_eq!(lsns(&seen), vec![1, 2, 3], "seed {seed}: {report:?}");
    }
}

/// F6: recovery opens one segment at a time, so a journal of many segments never reaches the
/// descriptor limit at open.
#[test]
fn recovery_holds_at_most_two_files_open() {
    let storage = SimStorage::new(54);
    let config = Config { segment_bytes: 200, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=60 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(journal.stats().segments_created >= 15, "{:?}", journal.stats());
    drop(journal);
    let restarted = storage.restart(Crash::Process);
    let (_journal, report, seen) = open_at(&restarted, config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(seen.len(), 60, "{report:?}");
    assert!(
        restarted.peak_open_files() <= 2,
        "{} files open at once ({report:?})",
        restarted.peak_open_files()
    );
}

/// G1 of the re-review: a sync fails and drops its pages, and the process is killed before the
/// writer tries again. The next open reads those pages from the cache and replays their records;
/// then the kernel evicts the pages, and a second read would see the disk's zeros. The copy that
/// recovery writes must hold the records the replay got, so a later OS crash keeps them.
#[test]
fn recovery_copies_the_records_it_checked_when_the_cache_drops_them() {
    let slow_retry = Config {
        retry_min: Duration::from_secs(60),
        retry_max: Duration::from_secs(60),
        ..quick()
    };
    let storage = SimStorage::new(64);
    let (journal, _, _) = open_at(&storage, slow_retry, 0).unwrap_or_else(|e| panic!("{e}"));
    // Record 1 fills page 0 and part of page 1, and is fully synced, its marker too.
    assert_eq!(journal.append(1, Class::Ack, &vec![b'a'; SIM_PAGE + 1000]), Ok(1));
    journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
    // Record 2's sync fails, and the disk gets none of its pages (page 1 on).
    storage.fail_next_sync(2, std::io::ErrorKind::Other);
    assert_eq!(journal.append(1, Class::Ack, &vec![b'b'; 2 * SIM_PAGE]), Ok(2));
    assert!(eventually(|| journal.stats().failures == 1), "{:?}", journal.stats());
    // A kill -9 while the writer waits to try again.
    let restarted = storage.restart(Crash::Process);
    drop(journal);
    // Each read of the next open sees the cache, then evicts the dropped pages it read.
    restarted.evict_dropped_pages_after_read(true);
    let (journal, report, seen) = open(&restarted);
    restarted.evict_dropped_pages_after_read(false);
    assert_eq!(lsns(&seen), vec![1, 2], "{report:?}");
    assert_eq!(journal.append(1, Class::Ack, b"c"), Ok(3));
    journal.wait_durable(3, WAIT).unwrap_or_else(|e| panic!("{e}"));
    drop(journal);
    let (_, report, seen) = open(&restarted.restart(Crash::Os));
    assert_eq!(lsns(&seen), vec![1, 2, 3], "{report:?}");
    assert!(report.damage.is_empty(), "{report:?}");
}

/// G4 of the re-review: once a segment that an open made after its quarantine is live, the
/// quarantined segments hold no LSN above it, so later opens read none of them.
#[test]
fn an_open_after_a_finished_quarantine_reads_no_quarantined_segment() {
    let (damaged, config) = damaged_in_the_middle(55);
    let (journal, report, _) =
        open_at(&damaged, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert!(matches!(report.damage.first(), Some(Damage::Corrupt { .. })), "{report:?}");
    drop(journal);
    let restarted = damaged.restart(Crash::Process);
    let quarantine = dir().join("quarantine");
    let moved = restarted.names_in(&quarantine);
    assert!(!moved.is_empty());
    let (journal, _, _) = open_at(&restarted, config, 0).unwrap_or_else(|e| panic!("{e}"));
    for name in &moved {
        assert_eq!(restarted.reads(&quarantine.join(name)), 0, "{name} was read");
    }
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(41));
}

/// The newest segment after a finished quarantine, and the storage once that open has ended.
fn after_a_finished_quarantine(seed: u64) -> (SimStorage, Config, String) {
    let (damaged, config) = damaged_in_the_middle(seed);
    let (journal, report, _) =
        open_at(&damaged, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert!(matches!(report.damage.first(), Some(Damage::Corrupt { .. })), "{report:?}");
    drop(journal);
    let storage = damaged.restart(Crash::Process);
    let newest = storage
        .names_in(&dir())
        .into_iter()
        .filter(|name| name.ends_with(".seg"))
        .max()
        .unwrap_or_else(|| panic!("no segment"));
    (storage, config, newest)
}

/// G7 of the third review, scenario A: after a finished quarantine, the empty segment the open
/// made gets one damaged header byte. The next open must still count the quarantined LSNs.
#[test]
fn a_damaged_header_after_a_quarantine_never_reuses_a_quarantined_lsn() {
    let (storage, config, newest) = after_a_finished_quarantine(56);
    // One byte of the journal id in the header of the empty newest segment.
    storage.corrupt(&dir().join(&newest), 20);
    let (journal, report, _) =
        open_at(&storage.restart(Crash::Process), config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(41), "{report:?}");
}

/// G7 scenario B: the newest segment holds acked records 41..43, and its header and its first
/// record are damaged. The loss must be reported through 43, and no LSN of it given out again.
#[test]
fn a_damaged_newest_segment_after_a_quarantine_reports_its_records() {
    let (storage, config, newest) = after_a_finished_quarantine(57);
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 41..=43 {
        assert_eq!(journal.append(3, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    assert_eq!(journal.seal(WAIT), Ok(43));
    drop(journal);
    let storage = storage.restart(Crash::Process);
    let newest_now = storage
        .names_in(&dir())
        .into_iter()
        .filter(|name| name.ends_with(".seg"))
        .max()
        .unwrap_or_else(|| panic!("no segment"));
    // The segment that holds 41..43 (the open made a new, empty one after it: damage both).
    for name in [&newest, &newest_now] {
        storage.corrupt(&dir().join(name), 20);
        storage.corrupt(&dir().join(name), SEGMENT_HEADER_LEN + 2);
    }
    let (journal, report, _) =
        open_at(&storage.restart(Crash::Process), config, 0).unwrap_or_else(|e| panic!("{e}"));
    let lost_through = report
        .damage
        .iter()
        .filter_map(|damage| match damage {
            Damage::Corrupt { lost_through, .. } => Some(*lost_through),
            _ => None,
        })
        .max()
        .unwrap_or(0);
    assert!(lost_through >= 43, "the loss of 41..43 is not reported: {report:?}");
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(44), "{report:?}");
    // N3 of the fourth review: the absorbed loss's files stay named, for a salvage.
    assert_names_every_quarantined_file(&storage, &report);
}

/// Every segment file in `quarantine/` is named by a reported loss (a salvage finds its records).
fn assert_names_every_quarantined_file(storage: &SimStorage, report: &OpenReport) {
    let named: std::collections::BTreeSet<&str> = report
        .damage
        .iter()
        .flat_map(|damage| match damage {
            Damage::Corrupt { moved, .. } => moved.iter().map(String::as_str).collect(),
            _ => Vec::new(),
        })
        .collect();
    for name in storage.names_in(&dir().join("quarantine")) {
        if !name.starts_with("damage-report") {
            assert!(named.contains(name.as_str()), "{name} is not named: {report:?}");
        }
    }
}

/// G8 of the fourth review: a recovery copy is numbered above the quarantine, but its records
/// start below the quarantined LSNs. Records 2..5 are written, not synced, and a kill -9 comes:
/// open #1 copies them into segment 2 (C1), and the writer goes on there with 6..10. C1's header
/// is damaged: open #2 quarantines C1, copies 2..5 again into segment 3 (C2) and makes the empty
/// segment 4 (E, first LSN 11). E's header is damaged too. Open #3 must still give 11.
#[test]
fn a_recovery_copy_above_a_quarantine_never_reuses_a_quarantined_lsn() {
    let storage = SimStorage::new(58);
    let config = Config { stream_sync_delay: Duration::from_secs(60), ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, b"one"), Ok(1));
    journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
    for lsn in 2..=5 {
        assert_eq!(journal.append(1, Class::Stream, &payload(lsn)), Ok(lsn));
    }
    assert!(eventually(|| journal.stats().written_lsn >= 5), "{:?}", journal.stats());
    assert_eq!(journal.durable_lsn(), 1, "the stream records must not be synced yet");
    let killed = storage.restart(Crash::Process);
    drop(journal);
    // Open #1: the copy C1 (segment 2), and 6..10 in it.
    let (journal, report, seen) =
        open_at(&killed, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!((lsns(&seen), report.rewritten), ((1..=5).collect::<Vec<_>>(), 4), "{report:?}");
    for lsn in 6..=10 {
        assert_eq!(journal.append(1, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    assert_eq!(journal.seal(WAIT), Ok(10));
    drop(journal);
    let killed = killed.restart(Crash::Process);
    killed.corrupt(&dir().join(format::segment_name(2)), 20);
    // Open #2: C1 to quarantine, C2 (segment 3) and the empty E (segment 4); no append.
    let (journal, report, _) =
        open_at(&killed, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(report.next_lsn, 11, "{report:?}");
    drop(journal);
    let killed = killed.restart(Crash::Process);
    killed.corrupt(&dir().join(format::segment_name(4)), 20);
    // Open #3.
    let (journal, report, _) = open_at(&killed, config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, b"after"), Ok(11), "{report:?}");
    assert_names_every_quarantined_file(&killed, &report);
}

/// G9 of the fifth review: an open skips LSNs (damaged synced records in the last segment) and
/// copies the records before the damage into a new segment; the empty segment after the copy
/// carried the skip in its header alone. With that header damaged, the next open must still skip.
#[test]
fn a_skip_hidden_behind_a_recovery_copy_is_never_given_out_again() {
    let storage = SimStorage::new(59);
    let config = Config { stream_sync_delay: Duration::from_secs(60), ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, &payload(1)), Ok(1));
    journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
    // 2..10 written, not synced; 11's sync covers them all: one synced run, marker 11 after it.
    for lsn in 2..=10 {
        assert_eq!(journal.append(1, Class::Stream, &payload(lsn)), Ok(lsn));
    }
    assert_eq!(journal.append(1, Class::Ack, &payload(11)), Ok(11));
    assert_eq!(journal.seal(WAIT), Ok(11));
    drop(journal);
    // Media damage in a payload byte of record 5.
    let record = |lsn: Lsn| format::RECORD_HEADER_LEN + payload(lsn).len();
    let at = SEGMENT_HEADER_LEN
        + record(1)
        + format::RECORD_HEADER_LEN
        + (2..=4).map(record).sum::<usize>()
        + format::RECORD_HEADER_LEN
        + 1;
    let storage = storage.restart(Crash::Process);
    storage.corrupt(&dir().join(format::segment_name(1)), at);
    // Open #1: (4, 11] reported, 2..4 copied into segment 2, the empty segment 3 from 12.
    let (journal, report, _) =
        open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    let reported = report
        .damage
        .iter()
        .any(|damage| matches!(damage, Damage::Corrupt { lost_after: 4, lost_through: 11, .. }));
    assert!(reported, "{report:?}");
    assert_eq!((report.next_lsn, report.rewritten), (12, 3), "{report:?}");
    drop(journal);
    let storage = storage.restart(Crash::Process);
    storage.corrupt(&dir().join(format::segment_name(3)), 20);
    // Open #2.
    let (journal, report, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, b"after"), Ok(12), "{report:?}");
}

/// The same for torn records (an OS crash wrote some pages of an unsynced write): their LSNs are
/// never given out again, also when a copy hides the segment that holds them.
#[test]
fn torn_lsns_hidden_behind_a_recovery_copy_are_never_given_out_again() {
    let storage = SimStorage::new(60);
    let config = Config { stream_sync_delay: Duration::from_secs(60), ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, &payload(1)), Ok(1));
    journal.wait_durable(1, WAIT).unwrap_or_else(|e| panic!("{e}"));
    assert!(eventually(|| journal.full_durable_lsn() >= 1), "{:?}", journal.stats());
    for lsn in 2..=3 {
        assert_eq!(journal.append(1, Class::Stream, &payload(lsn)), Ok(lsn));
    }
    assert!(eventually(|| journal.stats().written_lsn >= 3), "{:?}", journal.stats());
    let storage = storage.restart(Crash::Process);
    drop(journal);
    // A torn write after them: bytes that are not an entry, then record 5 whole.
    let path = dir().join(format::segment_name(1));
    let mut bytes = storage.contents(&path).unwrap_or_default();
    bytes.extend_from_slice(&[0x5A; 13]);
    let torn = payload(5);
    format::encode_record(&mut bytes, 5, 1, Class::Stream, &torn, &format::payload_crc(&torn));
    write_whole(&storage, &path, &bytes);
    // Open #1: torn LSNs 4..5, 2..3 copied into segment 2, the empty segment 3 from 6.
    let (journal, report, _) =
        open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!((report.torn_lsns, report.next_lsn), (Some((4, 5)), 6), "{report:?}");
    drop(journal);
    let storage = storage.restart(Crash::Process);
    storage.corrupt(&dir().join(format::segment_name(3)), 20);
    // Open #2.
    let (journal, report, _) = open_at(&storage, config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(journal.append(1, Class::Ack, b"after"), Ok(6), "{report:?}");
}

// ---------------------------------------------------------------- retirement (S2)

/// 60 acked records over many 200-byte segments, sealed; and the config.
fn many_segments(seed: u64) -> (SimStorage, Config) {
    let storage = SimStorage::new(seed);
    let config = Config { segment_bytes: 200, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=60 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    assert_eq!(journal.seal(WAIT), Ok(60));
    drop(journal);
    (storage.restart(Crash::Process), config)
}

fn segment_count(storage: &SimStorage) -> usize {
    storage.names_in(&dir()).iter().filter(|name| name.ends_with(".seg")).count()
}

#[test]
fn retirement_deletes_only_the_segments_a_compaction_point_covers() {
    let (storage, config) = many_segments(60);
    let (journal, _, _) = open_at(&storage, config.clone(), 40).unwrap_or_else(|e| panic!("{e}"));
    let before = segment_count(&storage);
    let retired = journal.retire_through(40).unwrap_or_else(|e| panic!("{e}"));
    assert!(retired >= 5, "{retired} of {before} segments retired");
    assert_eq!(segment_count(&storage), before - retired);
    assert_eq!(journal.stats().segments_retired, u64::try_from(retired).unwrap_or(0));
    assert_eq!(journal.retire_through(40).unwrap_or_else(|e| panic!("{e}")), 0, "covered once");
    drop(journal);
    // The deletes were made durable: an OS crash keeps them, and every record after 40 is kept.
    let restarted = storage.restart(Crash::Os);
    assert_eq!(segment_count(&restarted), before - retired);
    let (journal, report, seen) =
        open_at(&restarted, config.clone(), 40).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(segment_count(&restarted), before - retired + 1, "the open made one segment");
    assert_eq!(lsns(&seen), (41..=60).collect::<Vec<_>>(), "{report:?}");
    assert!(report.damage.is_empty(), "{report:?}");
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(61));
    drop(journal);
    // A compaction point older than the retired segments is told, not hidden.
    let (_, report, _) =
        open_at(&restarted.restart(Crash::Process), config, 0).unwrap_or_else(|e| panic!("{e}"));
    assert!(matches!(report.damage.first(), Some(Damage::Missing { after: 0, .. })), "{report:?}");
}

#[test]
fn a_crash_at_any_point_of_a_retirement_keeps_every_record_after_it() {
    let (base, config) = many_segments(61);
    // Every storage operation of one retirement is a crash point once.
    let probe = base.snapshot(Crash::Process);
    let (journal, _, _) = open_at(&probe, config.clone(), 40).unwrap_or_else(|e| panic!("{e}"));
    let before = probe.ops();
    assert!(journal.retire_through(40).unwrap_or_else(|e| panic!("{e}")) >= 5);
    let operations = probe.ops() - before;
    drop(journal);
    for crash in [Crash::Process, Crash::Os, Crash::PowerLoss] {
        for at in 1..=operations {
            let storage = base.snapshot(Crash::Process);
            let (journal, _, _) =
                open_at(&storage, config.clone(), 40).unwrap_or_else(|e| panic!("{e}"));
            storage.crash_after(at);
            assert!(journal.retire_through(40).is_err(), "{crash:?} at op {at}: no crash");
            drop(journal);
            let restarted = storage.restart(crash);
            let (journal, report, seen) = open_at(&restarted, config.clone(), 40)
                .unwrap_or_else(|e| panic!("{crash:?} at op {at}: {e}"));
            assert_eq!(lsns(&seen), (41..=60).collect::<Vec<_>>(), "{crash:?} at {at}: {report:?}");
            assert!(report.damage.is_empty(), "{crash:?} at op {at}: {report:?}");
            assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(61), "{crash:?} at op {at}");
        }
    }
}

#[test]
fn retirement_never_deletes_the_segment_the_writer_appends_to() {
    let (storage, config) = many_segments(62);
    let (journal, _, _) = open_at(&storage, config.clone(), 60).unwrap_or_else(|e| panic!("{e}"));
    // Past the durable LSN: capped at it.
    journal.retire_through(Lsn::MAX).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(segment_count(&storage), 1, "only the newest segment is left");
    assert_eq!(journal.append(3, Class::Ack, b"after"), Ok(61));
    journal.wait_durable(61, WAIT).unwrap_or_else(|e| panic!("{e}"));
    drop(journal);
    let (_, report, seen) =
        open_at(&storage.restart(Crash::Os), config, 60).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), vec![61], "{report:?}");
    assert!(report.damage.is_empty(), "{report:?}");
}

#[test]
fn retirement_keeps_segments_the_writer_made_after_the_point() {
    let storage = SimStorage::new(63);
    let config = Config { segment_bytes: 200, ..quick() };
    let (journal, _, _) = open_at(&storage, config.clone(), 0).unwrap_or_else(|e| panic!("{e}"));
    for lsn in 1..=30 {
        let got = journal.append(3, Class::Ack, &payload(lsn)).unwrap_or_else(|e| panic!("{e}"));
        journal.wait_durable(got, WAIT).unwrap_or_else(|e| panic!("{e}"));
    }
    // The point is in the middle of what this writer wrote.
    journal.retire_through(12).unwrap_or_else(|e| panic!("{e}"));
    drop(journal);
    let (_, report, seen) =
        open_at(&storage.restart(Crash::Os), config, 12).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(lsns(&seen), (13..=30).collect::<Vec<_>>(), "{report:?}");
    assert!(report.damage.is_empty(), "{report:?}");
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

/// G3 of the re-review: the daemon's state folder, or the journal folder itself, may be a
/// symlink (GNU stow, state kept on another volume). The journal opens there and round-trips.
#[cfg(unix)]
#[test]
fn a_journal_in_a_symlinked_folder_opens_and_round_trips() {
    let root = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let real = root.path().join("real");
    let journal_real = root.path().join("journal-real");
    for folder in [&real, &journal_real] {
        std::fs::create_dir(folder).unwrap_or_else(|e| panic!("mkdir: {e}"));
    }
    let state = root.path().join("state");
    std::os::unix::fs::symlink(&real, &state).unwrap_or_else(|e| panic!("symlink: {e}"));
    let journal_link = real.join("journal");
    std::os::unix::fs::symlink(&journal_real, &journal_link)
        .unwrap_or_else(|e| panic!("symlink: {e}"));
    let storage: Arc<dyn Storage> = Arc::new(FsStorage);
    // A journal folder in a symlinked state folder; a journal folder that is a symlink.
    for dir in [state.join("chats-journal"), journal_link] {
        let (journal, _) =
            Journal::open(storage.clone(), &dir, Config::default(), 0, &mut |_| Ok(()))
                .unwrap_or_else(|e| panic!("open {}: {e}", dir.display()));
        assert_eq!(journal.append(5, Class::Ack, b"x"), Ok(1));
        assert_eq!(journal.seal(WAIT), Ok(1));
        drop(journal);
        let mut seen = Vec::new();
        Journal::open(storage.clone(), &dir, Config::default(), 0, &mut |record| {
            seen.push(record.lsn);
            Ok(())
        })
        .unwrap_or_else(|e| panic!("reopen {}: {e}", dir.display()));
        assert_eq!(seen, vec![1], "{}", dir.display());
    }
}

/// The journal's id is the same after a reopen (and after its segments are retired, one is always
/// kept), and another journal has another one: a caller that keeps LSNs outside the journal tells
/// them apart by it.
#[test]
fn the_journal_id_survives_a_reopen_and_differs_between_journals() {
    let storage = SimStorage::new(90);
    let (journal, _, _) = open(&storage);
    let id = journal.journal_id();
    assert_ne!(id, 0, "a journal id of 0");
    for lsn in 1..=20u64 {
        assert_eq!(journal.append(7, Class::Ack, &payload(lsn)), Ok(lsn));
    }
    journal.wait_durable(20, WAIT).unwrap_or_else(|error| panic!("wait: {error}"));
    journal.retire_through(20).unwrap_or_else(|error| panic!("retire: {error}"));
    assert_eq!(journal.seal(WAIT), Ok(20));
    drop(journal);
    let (journal, _, _) = open_at(&storage.restart(Crash::Process), quick(), 20)
        .unwrap_or_else(|error| panic!("open: {error}"));
    assert_eq!(journal.journal_id(), id, "a reopen changed the journal's id");
    let (other, _, _) = open(&SimStorage::new(91));
    assert_ne!(other.journal_id(), id, "two journals with one id");
}
