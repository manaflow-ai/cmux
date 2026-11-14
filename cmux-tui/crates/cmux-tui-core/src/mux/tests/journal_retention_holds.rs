//! The retention pass gives the registry lock back while it deletes ONE
//! sealed segment.
//!
//! The pass deleted a segment and each row of its records (about 12 subject
//! index rows a record, the event index, the kept reducer rows, the ingress
//! receipts) in one transaction and one hold of the registry lock. On a
//! generated registry of a long-lived session that hold was 61 ms in the
//! mean and 0.74 s to 2.2 s at its longest, on the lock that each create,
//! rename and key of the daemon takes (2026-11-12, `registry-migration-proof`).
//!
//! This test writes one segment of more than two holds of records through
//! the real ingress paths, then runs the worker's own tick until the floor
//! passes that segment and the pass deletes it. At each point where the pass
//! gave the lock back, a second thread takes the lock, counts the records of
//! the segment that still have a row, and reads the segment through the
//! three journal readers. It times nothing.
#![cfg(unix)]

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use super::journal_retention_bound::{Agent, RECORDS, head, session, step, write_through};
use super::*;
use crate::journal_reducers::AgentRoster;
use crate::mux::journal_segment_retention::{
    AFTER_RETENTION_HOLD_FOR_TEST, BEFORE_NEXT_RETENTION_HOLD_FOR_TEST,
};
use crate::workspace_registry::JournalSubject;
use crate::workspace_registry::journal_retention::RETENTION_ROWS_PER_HOLD;

/// The most records that lose their last row in one hold of the pass: a
/// hold deletes at most this many rows.
const RECORDS_A_HOLD: u64 = RETENTION_ROWS_PER_HOLD;
/// Records written before the first seal: one segment of more than two
/// holds of rows.
const BIG_SEGMENT_RECORDS: u64 = 700;
/// How long the second thread tries to take the registry lock at a point.
const LOCK_WAIT: Duration = Duration::from_secs(10);
/// The journal's page limit (`MAX_JOURNAL_PAGE_SIZE`): one page holds the
/// whole segment.
const PAGE: usize = 1_024;

/// The segment the test watches, and what each reader gave from it before
/// the pass came to it.
pub(super) struct Big {
    start: u64,
    pub(super) end: u64,
    records: u64,
    subject: JournalSubject,
    whole: Answers,
}

/// The sequences at or below the segment's end that each reader gives from
/// a cursor before the segment's first record.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Answers {
    /// `session_journal_after`: each record.
    page: Vec<u64>,
    /// `session_journal_kinds_after` with the agent roster's kinds.
    kinds: Vec<u64>,
    /// The subject page of `Big::subject` on a reader connection.
    subjects: Vec<u64>,
}

/// What a second thread found at one point where the pass had given the
/// registry lock back.
#[derive(Debug)]
struct Point {
    /// The sequence retention has deleted through.
    floor: u64,
    /// The segment row (and so its content) is there.
    segment_there: bool,
    /// Records of the segment that still have a row in one of the four
    /// tables of rows a record.
    records_with_rows: u64,
    answers: Result<Answers, String>,
}

fn read(
    mux: &Mux,
    big_start: u64,
    big_end: u64,
    subject: &JournalSubject,
) -> anyhow::Result<Answers> {
    let after = big_start - 1;
    let in_segment = |sequences: Vec<u64>| -> Vec<u64> {
        sequences.into_iter().filter(|sequence| *sequence <= big_end).collect()
    };
    let page = mux.session_journal_after(after, PAGE)?;
    let (kinds, _) =
        mux.session_journal_kinds_after(after, big_end, AgentRoster::folds_kind, PAGE)?;
    let reader = mux.session_journal_reader()?.expect("an on-disk registry");
    let subjects = reader.after_subjects(after, PAGE, std::slice::from_ref(subject))?;
    Ok(Answers {
        page: in_segment(page.records.iter().map(|record| record.sequence).collect()),
        kinds: in_segment(kinds.iter().map(|record| record.sequence).collect()),
        subjects: in_segment(subjects.records.iter().map(|record| record.sequence).collect()),
    })
}

/// One point, or `None` when the second thread did not get the registry
/// lock in [`LOCK_WAIT`].
fn observe(mux: &Mux, start: u64, end: u64, subject: &JournalSubject) -> Option<Point> {
    let (floor, segment_there, records_with_rows) = {
        // Another thread of the daemon can hold the lock for a moment: the
        // second thread tries until it has it. While the pass's own thread
        // holds it, no try ends.
        let deadline = Instant::now() + LOCK_WAIT;
        let registry = loop {
            match mux.workspace_registry.try_lock() {
                Ok(registry) => break registry,
                Err(_) if Instant::now() < deadline => std::thread::yield_now(),
                Err(_) => return None,
            }
        };
        let floor = registry.journal_pruned_through().unwrap();
        let db = registry.connection.get();
        let range = [i64::try_from(start).unwrap(), i64::try_from(end).unwrap()];
        let segment_there: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM journal_segments
                               WHERE start_sequence = ?1 AND end_sequence = ?2)",
                range,
                |row| row.get(0),
            )
            .unwrap();
        let records_with_rows: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM (
                   SELECT sequence FROM journal_segment_reducer_records
                    WHERE sequence >= ?1 AND sequence <= ?2
                   UNION
                   SELECT sequence FROM journal_subject_index
                    WHERE sequence >= ?1 AND sequence <= ?2
                   UNION
                   SELECT sequence FROM journal_event_index
                    WHERE sequence >= ?1 AND sequence <= ?2
                   UNION
                   SELECT journal_sequence FROM journal_ingress_receipts
                    WHERE journal_sequence >= ?1 AND journal_sequence <= ?2
                 )",
                range,
                |row| row.get(0),
            )
            .unwrap();
        (floor, segment_there, u64::try_from(records_with_rows).unwrap())
    };
    let answers = read(mux, start, end, subject).map_err(|error| format!("{error:#}"));
    Some(Point { floor, segment_there, records_with_rows, answers })
}

/// [`observe`] on a second thread: the caller's thread is the one that
/// runs the pass.
fn observe_on_a_second_thread(
    mux: &Mux,
    start: u64,
    end: u64,
    subject: &JournalSubject,
) -> Option<Point> {
    std::thread::scope(|scope| {
        scope.spawn(|| observe(mux, start, end, subject)).join().expect("the observer ran")
    })
}

/// A session whose first sealed segment has more than two holds of
/// records, and that segment.
pub(super) fn session_with_a_big_segment(
    root: &Path,
    next_step: &mut u64,
) -> (Arc<Mux>, Vec<Agent>, Big) {
    let (mux, agents) = session(1, root);
    // No checkpoint and no tick while these are written: they seal as one
    // segment.
    let target = head(&mux) + BIG_SEGMENT_RECORDS;
    while head(&mux) < target {
        step(&mux, &agents, *next_step);
        *next_step += 1;
    }
    settled(&mux);
    mux.create_journal_checkpoint("retention-test", "retention-holds-big").unwrap();
    mux.run_journal_maintenance_for_test();
    let segments = mux.journal_segments().unwrap();
    let segment = segments
        .iter()
        .max_by_key(|segment| segment.record_count)
        .expect("the setup: the tick sealed a segment");
    assert!(
        segment.record_count > 2 * RECORDS_A_HOLD,
        "the setup: a segment of more than {} records: {segments:?}",
        2 * RECORDS_A_HOLD
    );
    let (start, end) = (segment.start_sequence, segment.end_sequence);
    // A subject that more than one record of the segment names.
    let page = mux.session_journal_after(start - 1, PAGE).unwrap();
    let subject = page
        .records
        .iter()
        .filter(|record| record.sequence <= end && record.kind.starts_with("agent."))
        .find_map(|record| record.subjects.first().cloned())
        .expect("the setup: an agent record of the segment names a subject");
    let whole = read(&mux, start, end, &subject).unwrap();
    assert_eq!(
        u64::try_from(whole.page.len()).unwrap(),
        segment.record_count,
        "the setup: one page holds each record of the segment"
    );
    assert!(whole.kinds.len() > 1, "the setup: the segment has agent records");
    assert!(whole.subjects.len() > 1, "the setup: records of the segment name {subject:?}");
    let big = Big { start, end, records: segment.record_count, subject, whole };
    (mux, agents, big)
}

#[test]
fn the_retention_pass_gives_the_registry_lock_back_while_it_deletes_one_segment() {
    let root = std::env::temp_dir()
        .join(format!("cmux-journal-retention-holds-{}", crate::workspace_registry::new_uuid_v4()));
    let mut next_step = 0;
    let (mux, agents, big) = session_with_a_big_segment(&root, &mut next_step);
    let before = observe_on_a_second_thread(&mux, big.start, big.end, &big.subject)
        .expect("the setup: no pass runs, the lock is free");
    assert!(before.segment_there && before.floor < big.end, "the setup: {before:?}");
    assert_eq!(
        before.records_with_rows, big.records,
        "the setup: each record of the segment has a row"
    );

    // Each point where the pass gave the lock back, in order. `None`: the
    // second thread did not get the lock there.
    let points: Rc<RefCell<Vec<Option<Point>>>> = Rc::default();
    {
        let (mux, points) = (Arc::clone(&mux), Rc::clone(&points));
        let (start, end, subject) = (big.start, big.end, big.subject.clone());
        AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                let point = observe_on_a_second_thread(&mux, start, end, &subject);
                points.borrow_mut().push(point);
            }));
        });
    }
    write_through(&mux, &agents, &mut next_step, head(&mux) + RECORDS);
    for _ in 0..32 {
        mux.run_journal_maintenance_for_test();
    }
    // The seam holds the mux: it goes before the shutdown.
    AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| slot.borrow_mut().take());

    let points = points.borrow();
    let none = Answers { page: Vec::new(), kinds: Vec::new(), subjects: Vec::new() };
    // The segment's content goes last and whole: the page read and the kind
    // read give each record until then. The subject page starts above the
    // floor, so it has no record of the segment from the first hold on.
    let from_the_content = Answers {
        page: big.whole.page.clone(),
        kinds: big.whole.kinds.clone(),
        subjects: Vec::new(),
    };
    let mut problems = Vec::new();
    let mut previous = big.records;
    // Points at which the segment was at or below the floor with its row
    // still there: the pass had begun its delete and had not ended it.
    let mut during = 0;
    for (index, point) in points.iter().enumerate() {
        let Some(point) = point else {
            problems.push(format!("point {index}: a second thread did not get the registry lock"));
            continue;
        };
        let deleted = previous.saturating_sub(point.records_with_rows);
        if deleted > RECORDS_A_HOLD {
            problems.push(format!(
                "point {index}: one hold deleted the rows of {deleted} records (at most \
                 {RECORDS_A_HOLD}); floor {}, segment row there: {}",
                point.floor, point.segment_there
            ));
        }
        previous = point.records_with_rows;
        let begun = point.floor >= big.end;
        let wanted = match (begun, point.segment_there) {
            (false, _) => &big.whole,
            (true, true) => {
                during += 1;
                &from_the_content
            }
            (true, false) => &none,
        };
        match &point.answers {
            Ok(answers) if answers == wanted => {}
            Ok(answers) => {
                let count = |sequences: &[u64]| sequences.len();
                problems.push(format!(
                    "point {index} (floor {}, segment row there: {}, {} records with rows): the \
                     readers gave page {} kinds {} subjects {} records of the segment; wanted \
                     page {} kinds {} subjects {}",
                    point.floor,
                    point.segment_there,
                    point.records_with_rows,
                    count(&answers.page),
                    count(&answers.kinds),
                    count(&answers.subjects),
                    count(&wanted.page),
                    count(&wanted.kinds),
                    count(&wanted.subjects),
                ));
            }
            Err(error) => problems.push(format!("point {index}: a reader failed: {error}")),
        }
    }
    println!(
        "journal_retention_holds: segment [{}..={}] of {} records; {} points, {during} of them \
         while its delete was not ended",
        big.start,
        big.end,
        big.records,
        points.len()
    );
    if during < 3 {
        problems.push(format!(
            "the pass gave the lock back {during} times while it deleted the segment of {} \
             records; at least 3 (after the floor moved and after each of 2 or more holds of rows)",
            big.records
        ));
    }
    match points.iter().rev().flatten().next() {
        Some(last) if !last.segment_there && last.records_with_rows == 0 => {}
        last => problems.push(format!("the setup: the pass did not delete the segment: {last:?}")),
    }
    drop(points);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
    assert!(problems.is_empty(), "{problems:#?}");
}

/// A second thread that has the registry lock and keeps it.
struct Holder {
    release: std::sync::mpsc::Sender<()>,
    thread: std::thread::JoinHandle<()>,
}

/// Starts a second thread that takes the registry lock and keeps it until
/// [`Holder::let_go`]. `None` when it did not get the lock in [`LOCK_WAIT`].
fn hold_the_registry_lock(mux: &Arc<Mux>) -> Option<Holder> {
    let (has_it, held) = std::sync::mpsc::channel::<()>();
    let (release, released) = std::sync::mpsc::channel::<()>();
    let mux = Arc::clone(mux);
    let thread = std::thread::spawn(move || {
        let deadline = Instant::now() + LOCK_WAIT;
        let registry = loop {
            match mux.workspace_registry.try_lock() {
                Ok(registry) => break registry,
                Err(_) if Instant::now() < deadline => std::thread::yield_now(),
                // `has_it` drops: the caller reads that as "no lock".
                Err(_) => return,
            }
        };
        let _ = has_it.send(());
        let _ = released.recv();
        drop(registry);
    });
    match held.recv() {
        Ok(()) => Some(Holder { release, thread }),
        Err(_) => {
            thread.join().expect("the holder ran");
            None
        }
    }
}

impl Holder {
    fn let_go(self) {
        let _ = self.release.send(());
        self.thread.join().expect("the holder ran");
    }
}

/// What a second thread got at the end of one hold of the pass.
enum AfterHold {
    /// The registry lock, which it keeps.
    Held(Holder),
    /// No lock in [`LOCK_WAIT`].
    NoLock,
}

/// What the pass had done with the commits of one hold at the point where
/// it was free to begin the next hold.
#[derive(Debug)]
struct Handoff {
    /// A second thread had the registry lock from the end of the hold to
    /// this point.
    lock_was_free: bool,
    /// Commits that no flush was asked for.
    unrequested: u64,
    /// Commits that the WAL syncer had not begun to look at.
    unhandled: u64,
}

/// The pass writes megabytes with no request between its commits, so no
/// request's answer asks the WAL syncer to checkpoint them. It asked one
/// time, at the end of a tick: the WAL file took each byte of the tick (284
/// MB for one tick of 8 segments on a generated registry of a long-lived
/// session, 2026-11-12), on a registry whose WAL the syncer keeps near 4 MiB
/// for requests.
///
/// After each hold the pass hands its commits to the syncer and waits for
/// the syncer's look at them before it writes more. It waits with the
/// registry lock free: at each hold's end this test gives the lock to a
/// second thread, which keeps it until the pass is free to begin its next
/// hold. A pass that held the lock there, or took it in between, would not
/// get to that point. It times nothing, so its failure is a hang (the
/// time limit of the test run), not an assert.
#[test]
fn the_retention_pass_hands_each_hold_to_the_wal_syncer_with_the_registry_lock_free_or_hangs() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-handoff-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mut next_step = 0;
    let (mux, agents, big) = session_with_a_big_segment(&root, &mut next_step);

    // The second thread of the hold that just ended. `None`: no hold ended
    // since the last hand-off.
    let holder: Rc<RefCell<Option<AfterHold>>> = Rc::default();
    let handoffs: Rc<RefCell<Vec<Handoff>>> = Rc::default();
    {
        let (mux, holder) = (Arc::clone(&mux), Rc::clone(&holder));
        AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                let started =
                    hold_the_registry_lock(&mux).map_or(AfterHold::NoLock, AfterHold::Held);
                if let Some(AfterHold::Held(earlier)) = holder.borrow_mut().replace(started) {
                    earlier.let_go();
                }
            }));
        });
    }
    {
        let (mux, holder, handoffs) = (Arc::clone(&mux), Rc::clone(&holder), Rc::clone(&handoffs));
        BEFORE_NEXT_RETENTION_HOLD_FOR_TEST.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                let Some(held) = holder.borrow_mut().take() else { return };
                // Read while the second thread still has the lock.
                let unrequested = mux.registry_connection.unrequested_commits_for_test();
                let unhandled = mux.registry_connection.unhandled_commits_for_test();
                let lock_was_free = matches!(held, AfterHold::Held(_));
                if let AfterHold::Held(held) = held {
                    held.let_go();
                }
                handoffs.borrow_mut().push(Handoff { lock_was_free, unrequested, unhandled });
            }));
        });
    }
    write_through(&mux, &agents, &mut next_step, head(&mux) + RECORDS);
    for _ in 0..32 {
        mux.run_journal_maintenance_for_test();
    }
    // The seams hold the mux: they go before the shutdown.
    AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| slot.borrow_mut().take());
    BEFORE_NEXT_RETENTION_HOLD_FOR_TEST.with(|slot| slot.borrow_mut().take());
    if let Some(AfterHold::Held(left)) = holder.borrow_mut().take() {
        left.let_go();
    }

    let deleted = mux.journal_pruned_through().unwrap() >= big.end;
    let handoffs = handoffs.borrow();
    let mut problems = Vec::new();
    if !deleted || handoffs.is_empty() {
        problems.push(format!(
            "the setup: the pass did not delete the segment that ends at {} ({} hand-offs)",
            big.end,
            handoffs.len()
        ));
    }
    let count = |is: fn(&Handoff) -> bool| handoffs.iter().filter(|handoff| is(handoff)).count();
    let held = count(|handoff| !handoff.lock_was_free);
    if held > 0 {
        problems.push(format!(
            "at {held} of {} points a second thread did not get the registry lock after a hold \
             of the pass",
            handoffs.len()
        ));
    }
    let unrequested = count(|handoff| handoff.unrequested > 0);
    if unrequested > 0 {
        let most = handoffs.iter().map(|handoff| handoff.unrequested).max().unwrap_or(0);
        problems.push(format!(
            "at {unrequested} of {} points the pass was free to begin its next hold with commits \
             that no flush was asked for (up to {most}): the WAL takes each byte of a tick",
            handoffs.len()
        ));
    }
    let unhandled = count(|handoff| handoff.unhandled > 0);
    if unhandled > 0 {
        let most = handoffs.iter().map(|handoff| handoff.unhandled).max().unwrap_or(0);
        problems.push(format!(
            "at {unhandled} of {} points the pass was free to begin its next hold before the WAL \
             syncer took its commits (up to {most}): the pass did not wait for it",
            handoffs.len()
        ));
    }
    println!(
        "journal_retention_holds: {} hand-offs after a hold; segment [{}..={}] deleted: {deleted}",
        handoffs.len(),
        big.start,
        big.end
    );
    drop(handoffs);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
    assert!(problems.is_empty(), "{problems:#?}");
}
