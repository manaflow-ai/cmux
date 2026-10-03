//! The storage interface (decision T1): the replica sees every group commit
//! before the owner answers, and the lease epoch fences a stale owner.

use std::fs;
use std::io;
use std::sync::{Arc, Mutex};

use cmux_tasks::engine::{Clock, Engine};
use cmux_tasks::identity::Caller;
use cmux_tasks::protocol::{ErrorCode, Request};
use cmux_tasks::store::{
    Durability, EpochClaim, Journal, JournalReplica, Limits, NoopReplica, OpenError, RangeLimit,
    Replica,
};
use cmux_tasks_core::ids::Principal;
use serde_json::json;

fn clock() -> Clock {
    let mut now = 1_000;
    Box::new(move || {
        now += 7;
        now
    })
}

type Shipped = Arc<Mutex<Vec<(u64, u64, u64, Vec<u8>)>>>;

struct Recording {
    shipped: Shipped,
    fail: bool,
}

impl Replica for Recording {
    fn commit(&mut self, epoch: u64, first: u64, last: u64, bytes: &[u8]) -> io::Result<()> {
        if self.fail {
            return Err(io::Error::other("tier unreachable"));
        }
        self.shipped.lock().unwrap().push((epoch, first, last, bytes.to_vec()));
        Ok(())
    }

    /// The tier holds what was shipped.
    fn high_water(&mut self) -> io::Result<Option<u64>> {
        Ok(Some(self.shipped.lock().unwrap().last().map_or(0, |(_, _, last, _)| *last)))
    }
}

fn request(i: u64, epoch: Option<u64>) -> Request {
    Request {
        id: i,
        op: "task.create".to_owned(),
        params: json!({"id": format!("task_{i}"), "title": format!("Task {i}")}),
        key: Some(format!("k{i}")),
        origin: None,
        credential: None,
        epoch,
    }
}

fn me() -> Caller {
    Caller::person(Principal::user("usr_a"))
}

fn claim(epoch: u64, host: &str) -> Option<EpochClaim> {
    Some(EpochClaim { epoch, host: host.to_owned() })
}

fn open(
    dir: &std::path::Path,
    epoch: Option<EpochClaim>,
    shipped: &Shipped,
) -> Result<Engine, OpenError> {
    let replica = Box::new(Recording { shipped: Arc::clone(shipped), fail: false });
    Engine::open_durable(dir, "t", "CMX", clock(), Limits::default(), Durability { epoch, replica })
}

fn log_bytes(dir: &std::path::Path) -> Vec<u8> {
    let mut files: Vec<_> =
        fs::read_dir(dir.join("log")).unwrap().map(|e| e.unwrap().path()).collect();
    files.sort();
    files.iter().flat_map(|f| fs::read(f).unwrap()).collect()
}

#[test]
fn the_replica_receives_each_group_commit_as_appended() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    let mut engine = open(dir.path(), claim(3, "host_a"), &shipped).unwrap();
    engine.handle(&me(), request(1, None)).unwrap().reply.unwrap();
    let batch = vec![(me(), request(2, Some(3))), (me(), request(3, None))];
    engine.handle_batch(batch).unwrap();
    // A read-only request ships nothing.
    let get = Request {
        op: "task.get".to_owned(),
        params: json!({"task": "CMX-1"}),
        key: None,
        ..request(4, None)
    };
    engine.handle(&me(), get).unwrap().reply.unwrap();
    let shipped = shipped.lock().unwrap();
    let ranges: Vec<_> = shipped.iter().map(|(e, f, l, _)| (*e, *f, *l)).collect();
    assert_eq!(ranges, vec![(3, 1, 1), (3, 2, 3)], "one call per group commit");
    let all: Vec<u8> = shipped.iter().flat_map(|(_, _, _, b)| b.clone()).collect();
    assert_eq!(all, log_bytes(dir.path()), "the replica sees exactly the appended bytes");
}

#[test]
fn a_replica_failure_stops_the_writer() {
    let dir = tempfile::tempdir().unwrap();
    let replica = Box::new(Recording { shipped: Shipped::default(), fail: true });
    let mut engine = Engine::open_durable(
        dir.path(),
        "t",
        "CMX",
        clock(),
        Limits::default(),
        Durability { epoch: claim(1, "host_a"), replica },
    )
    .unwrap();
    // An Err from handle means: no reply was released; the server exits.
    assert!(engine.handle(&me(), request(1, None)).is_err());
    // The engine stays poisoned: memory is ahead of the tier.
    let get = Request {
        op: "task.settings.get".to_owned(),
        params: json!({}),
        key: None,
        ..request(2, None)
    };
    assert!(engine.handle(&me(), get).is_err());
}

#[test]
fn the_same_host_reopens_its_epoch_and_others_are_fenced() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    drop(open(dir.path(), claim(5, "host_a"), &shipped).unwrap());
    // A supervisor restart on the same host re-adopts epoch 5.
    drop(open(dir.path(), claim(5, "host_a"), &shipped).unwrap());
    // Another host cannot start the same epoch.
    let err = open(dir.path(), claim(5, "host_b"), &shipped).err().unwrap();
    assert!(matches!(&err, OpenError::Fenced(m) if m.contains("host_a")), "{err}");
    // An older epoch cannot start after a newer one.
    let err = open(dir.path(), claim(4, "host_a"), &shipped).err().unwrap();
    assert!(matches!(&err, OpenError::Fenced(m) if m.contains("owner_moved")), "{err}");
    // A newer epoch may.
    drop(open(dir.path(), claim(6, "host_b"), &shipped).unwrap());
}

#[test]
fn a_stale_owner_writes_nothing_after_a_newer_epoch_appears() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    let mut engine = open(dir.path(), claim(1, "host_a"), &shipped).unwrap();
    engine.handle(&me(), request(1, None)).unwrap().reply.unwrap();
    let before = log_bytes(dir.path());
    // A restore elsewhere claimed epoch 2 on the same tier.
    fs::write(dir.path().join(format!("epoch-{:020}", 2)), "host_b").unwrap();
    assert!(engine.handle(&me(), request(2, None)).is_err());
    assert_eq!(log_bytes(dir.path()), before, "the stale owner appended nothing");
    assert_eq!(shipped.lock().unwrap().len(), 1, "and shipped nothing");
}

#[test]
fn a_request_routed_under_another_epoch_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    let mut engine = open(dir.path(), claim(2, "host_a"), &shipped).unwrap();
    let err = engine.handle(&me(), request(1, Some(1))).unwrap().reply.unwrap_err();
    assert_eq!(err.code, ErrorCode::OwnerMoved);
    assert_eq!(err.code.exit_code(), 5);
    engine.handle(&me(), request(1, Some(2))).unwrap().reply.unwrap();
    // Without a fence the owner accepts any routed epoch (local dev).
    let local = tempfile::tempdir().unwrap();
    let mut engine = Engine::open(local.path(), "t", "CMX", clock()).unwrap();
    engine.handle(&me(), request(1, Some(9))).unwrap().reply.unwrap();
}

/// Review finding: a crash between the local fsync and the replica left a
/// permanent hole in the tier. The store re-ships the tail before serving.
#[test]
fn an_unshipped_tail_is_shipped_again_at_open() {
    let dir = tempfile::tempdir().unwrap();
    let replica = Box::new(Recording { shipped: Shipped::default(), fail: true });
    let mut engine = Engine::open_durable(
        dir.path(),
        "t",
        "CMX",
        clock(),
        Limits::default(),
        Durability { epoch: claim(1, "host_a"), replica },
    )
    .unwrap();
    assert!(engine.handle(&me(), request(1, None)).is_err(), "fsynced locally, not shipped");
    drop(engine);
    let shipped = Shipped::default();
    let mut engine = open(dir.path(), claim(1, "host_a"), &shipped).unwrap();
    {
        let shipped = shipped.lock().unwrap();
        let ranges: Vec<_> = shipped.iter().map(|(e, f, l, _)| (*e, *f, *l)).collect();
        assert_eq!(ranges, vec![(1, 1, 1)], "the tail ships before the owner serves");
        assert_eq!(shipped[0].3, log_bytes(dir.path()));
    }
    engine.handle(&me(), request(2, None)).unwrap().reply.unwrap();
    assert_eq!(shipped.lock().unwrap().last().map(|s| (s.1, s.2)), Some((2, 2)));
}

/// A replica ahead of the local log means the local copy lost data: refuse.
#[test]
fn a_replica_ahead_of_the_log_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    shipped.lock().unwrap().push((1, 1, 5, Vec::new()));
    let err = open(dir.path(), claim(1, "host_a"), &shipped).err().unwrap();
    assert!(matches!(&err, OpenError::Corrupt(m) if m.contains("restore")), "{err}");
}

/// A real replica without a lease epoch could collide across hosts.
#[test]
fn a_replica_needs_an_epoch() {
    let dir = tempfile::tempdir().unwrap();
    assert!(open(dir.path(), None, &Shipped::default()).is_err());
}

/// Review finding: the in-process CLI (no supervisor environment) must not
/// write a supervised directory past its fence and replica.
#[test]
fn an_unsupervised_open_of_a_supervised_dir_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    drop(open(dir.path(), claim(1, "host_a"), &Shipped::default()).unwrap());
    let err = Engine::open(dir.path(), "t", "CMX", clock()).err().unwrap();
    assert!(matches!(&err, OpenError::Fenced(m) if m.contains("supervised")), "{err}");
}

fn segments(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut files: Vec<_> =
        fs::read_dir(dir.join("log")).unwrap().map(|e| e.unwrap().path()).collect();
    files.sort();
    files
}

/// Review finding: a stale owner that resumed after a newer owner took over
/// appends a record with a sequence the new owner also used. Recovery drops
/// the stale record by epoch instead of silently keeping whichever came first.
#[test]
fn records_a_stale_epoch_wrote_after_a_newer_owner_are_dropped() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    {
        let mut engine = open(dir.path(), claim(1, "host_a"), &shipped).unwrap();
        engine.handle(&me(), request(1, None)).unwrap().reply.unwrap();
    }
    {
        let mut engine = open(dir.path(), claim(2, "host_b"), &shipped).unwrap();
        engine.handle(&me(), request(2, None)).unwrap().reply.unwrap();
    }
    let files = segments(dir.path());
    assert_eq!(files.len(), 2, "each owner writes its own segment: {files:?}");
    // The stale epoch-1 owner appends its own seq 2 to its segment.
    let newer = fs::read_to_string(&files[1]).unwrap();
    let mut stale: serde_json::Value = serde_json::from_str(newer.lines().next().unwrap()).unwrap();
    stale["epoch"] = json!(1);
    stale["op"]["params"]["title"] = json!("stale");
    let mut text = fs::read_to_string(&files[0]).unwrap();
    text.push_str(&format!("{stale}\n"));
    fs::write(&files[0], text).unwrap();
    let engine = open(dir.path(), claim(3, "host_c"), &shipped).unwrap();
    assert_eq!(engine.state().tasks["task_2"].title, "Task 2", "the epoch-2 record wins");
}

/// The same sequence twice within one epoch is corruption, never a skip.
#[test]
fn a_duplicate_sequence_in_one_epoch_is_corruption() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    {
        let mut engine = open(dir.path(), claim(1, "host_a"), &shipped).unwrap();
        engine.handle(&me(), request(1, None)).unwrap().reply.unwrap();
        engine.handle(&me(), request(2, None)).unwrap().reply.unwrap();
    }
    let file = segments(dir.path()).pop().unwrap();
    let text = fs::read_to_string(&file).unwrap();
    let first = text.lines().next().unwrap().to_owned();
    fs::write(&file, format!("{text}{first}\n")).unwrap();
    let err = open(dir.path(), claim(1, "host_a"), &shipped).err().unwrap();
    assert!(matches!(&err, OpenError::Corrupt(m) if m.contains("duplicate")), "{err}");
}

/// Review finding: a stale owner that died inside its append leaves a torn
/// line in a segment that is no longer the newest one. That line was never
/// acknowledged, so the newer owner still reopens.
#[test]
fn a_torn_line_in_a_stale_owners_segment_does_not_block_recovery() {
    let dir = tempfile::tempdir().unwrap();
    let shipped = Shipped::default();
    {
        let mut engine = open(dir.path(), claim(1, "host_a"), &shipped).unwrap();
        engine.handle(&me(), request(1, None)).unwrap().reply.unwrap();
    }
    {
        let mut engine = open(dir.path(), claim(2, "host_b"), &shipped).unwrap();
        engine.handle(&me(), request(2, None)).unwrap().reply.unwrap();
    }
    // The stale epoch-1 owner, paused since before the takeover, dies
    // halfway through its next line.
    let files = segments(dir.path());
    assert_eq!(files.len(), 2);
    let mut text = fs::read_to_string(&files[0]).unwrap();
    text.push_str("{\"v\":1,\"seq\":2,\"epo");
    fs::write(&files[0], text).unwrap();
    let engine = open(dir.path(), claim(2, "host_b"), &shipped).unwrap();
    assert_eq!(engine.state().seq, 2);
    assert!(fs::read_to_string(&files[0]).unwrap().ends_with('\n'), "the torn line is gone");
}

/// The TeamVmDO journal's rules (team VM plan, e4c59605b9e): one append per
/// range, `first_seq = high_water + 1`, at most 1 MiB and 100,000 sequences,
/// refused after a higher epoch.
#[derive(Clone, Default)]
struct TeamVmJournal {
    appends: Shipped,
}

impl Journal for TeamVmJournal {
    fn append(
        &mut self,
        stream: &str,
        epoch: u64,
        first: u64,
        last: u64,
        bytes: &[u8],
    ) -> io::Result<()> {
        assert_eq!(stream, "tasks");
        let mut appends = self.appends.lock().unwrap();
        let high_water = appends.last().map_or(0, |a| a.2);
        let max_epoch = appends.iter().map(|a| a.0).max().unwrap_or(0);
        let limit = RangeLimit::TEAM_VM_JOURNAL;
        if first != high_water + 1 || last < first || epoch < max_epoch {
            return Err(io::Error::other(format!("refused: {first}..={last} after {high_water}")));
        }
        if bytes.len() > limit.max_bytes || last - first + 1 > limit.max_seqs {
            return Err(io::Error::other(format!("refused: {} bytes over the limit", bytes.len())));
        }
        let lines = bytes.split_inclusive(|b| *b == b'\n').count() as u64;
        assert_eq!(lines, last - first + 1, "whole records, one per sequence");
        appends.push((epoch, first, last, bytes.to_vec()));
        Ok(())
    }

    fn high_water(&mut self, stream: &str) -> io::Result<u64> {
        assert_eq!(stream, "tasks");
        Ok(self.appends.lock().unwrap().last().map_or(0, |a| a.2))
    }
}

fn open_journal(dir: &std::path::Path, journal: &TeamVmJournal) -> Result<Engine, OpenError> {
    let replica = Box::new(JournalReplica::new("tasks", journal.clone()));
    Engine::open_durable(
        dir,
        "t",
        "CMX",
        clock(),
        Limits::default(),
        Durability { epoch: claim(1, "host_a"), replica },
    )
}

/// About 200 KiB per op, so 1 MiB holds four or five records.
fn big(i: u64) -> Request {
    let mut r = request(i, None);
    r.params["description"] = json!("x".repeat(200 * 1024));
    r
}

fn assert_journal_holds_the_log(journal: &TeamVmJournal, dir: &std::path::Path, seqs: u64) {
    let appends = journal.appends.lock().unwrap();
    let mut next = 1;
    for (_, first, last, bytes) in appends.iter() {
        assert_eq!(*first, next, "ranges are consecutive and in order");
        assert!(bytes.len() <= RangeLimit::TEAM_VM_JOURNAL.max_bytes);
        next = last + 1;
    }
    assert_eq!(next, seqs + 1);
    let all: Vec<u8> = appends.iter().flat_map(|a| a.3.clone()).collect();
    assert_eq!(all, log_bytes(dir), "the journal holds exactly the local log");
}

/// Coordinator item: the re-ship of a large unshipped tail at open splits
/// into journal appends of at most 1 MiB of whole records, in order.
#[test]
fn a_large_unshipped_tail_ships_in_journal_sized_ranges() {
    let dir = tempfile::tempdir().unwrap();
    {
        // The store ran with the local fsync as its only copy (no journal
        // yet), then moves onto the journal: everything is an unshipped tail.
        let mut engine = Engine::open_durable(
            dir.path(),
            "t",
            "CMX",
            clock(),
            Limits::default(),
            Durability { epoch: claim(1, "host_a"), replica: Box::new(NoopReplica) },
        )
        .unwrap();
        for i in 1..=12 {
            engine.handle(&me(), big(i)).unwrap().reply.unwrap();
        }
    }
    assert!(log_bytes(dir.path()).len() > 2 * RangeLimit::TEAM_VM_JOURNAL.max_bytes);
    let journal = TeamVmJournal::default();
    let mut engine = open_journal(dir.path(), &journal).unwrap();
    assert!(journal.appends.lock().unwrap().len() >= 3, "the tail ships as several appends");
    assert_journal_holds_the_log(&journal, dir.path(), 12);
    engine.handle(&me(), request(13, None)).unwrap().reply.unwrap();
    assert_journal_holds_the_log(&journal, dir.path(), 13);
}

/// A group commit over 1 MiB ships as several ranges before any reply.
#[test]
fn a_group_commit_over_the_journal_limit_ships_in_ranges() {
    let dir = tempfile::tempdir().unwrap();
    let journal = TeamVmJournal::default();
    let mut engine = open_journal(dir.path(), &journal).unwrap();
    let batch: Vec<_> = (1..=10).map(|i| (me(), big(i))).collect();
    for outcome in engine.handle_batch(batch).unwrap() {
        outcome.reply.unwrap();
    }
    assert!(journal.appends.lock().unwrap().len() >= 2);
    assert_journal_holds_the_log(&journal, dir.path(), 10);
}

/// An op too large for one journal append is refused as `invalid`; nothing
/// is logged or shipped and the writer keeps serving.
#[test]
fn an_op_over_the_size_bound_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let journal = TeamVmJournal::default();
    let mut engine = open_journal(dir.path(), &journal).unwrap();
    let mut huge = request(1, None);
    huge.params["description"] = json!("x".repeat(cmux_tasks::engine::MAX_OP_BYTES + 1));
    let err = engine.handle(&me(), huge).unwrap().reply.unwrap_err();
    assert_eq!(err.code, ErrorCode::Invalid);
    assert!(log_bytes(dir.path()).is_empty());
    assert!(journal.appends.lock().unwrap().is_empty());
    engine.handle(&me(), request(2, None)).unwrap().reply.unwrap();
    assert_journal_holds_the_log(&journal, dir.path(), 1);
}

#[test]
fn ranges_respect_both_limits_and_keep_whole_lines() {
    use cmux_tasks::store::durability::split_ranges;
    let limit = RangeLimit { max_bytes: 10, max_seqs: 3 };
    assert_eq!(split_ranges(&[], limit), Ok(vec![]));
    assert_eq!(split_ranges(&[4, 4, 4, 4], limit), Ok(vec![0..2, 2..4]), "bytes");
    assert_eq!(split_ranges(&[1, 1, 1, 1, 1, 1, 1], limit), Ok(vec![0..3, 3..6, 6..7]), "seqs");
    assert_eq!(split_ranges(&[10, 10], limit), Ok(vec![0..1, 1..2]), "exactly the limit fits");
    assert_eq!(split_ranges(&[3, 11, 2], limit), Err(1), "one line over the limit");
}
