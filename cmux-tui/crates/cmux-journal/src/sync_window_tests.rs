//! How often the journal syncs for a person's typing and for a turn's acknowledged records, and
//! what a crash of each kind can take back, with the default [`Config`] (cmuxterm-hq#11322).
//!
//! macOS charges a process for every page a write makes dirty again after a sync cleaned it (16
//! KiB on arm64), so the journal's cost is about one page per sync, whatever the records weigh.
//! Two record streams synced far more often than their durability needs:
//!
//! - **Drafts** (kept records, [`Journal::append_kept`]): each key a person types is a draft
//!   change, answered once written. They were synced once the journal had been quiet for 10 ms,
//!   which every gap between two keys is: one sync per key (about 24,000 an hour, 390 MiB an hour
//!   on macOS, typing a key every 150 ms).
//! - **A turn's acknowledged records**: a turn's end and the next prompt append about ten acked
//!   records within two milliseconds (the reply, `turn_end`, `turn_result`, a status, the chat's
//!   metadata, ...). The writer took each alone and synced it alone.
//!
//! [`crash_bounds_per_class`] pins what each class may lose: the table in the PR.

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::{Class, Config, Crash, Journal, Lsn, SimStorage};

const WAIT: Duration = Duration::from_secs(10);

fn open(storage: &SimStorage, config: Config) -> Journal {
    let (journal, _) =
        Journal::open(Arc::new(storage.clone()), Path::new("/sim/journal"), config, 0, &mut |_| {
            Ok(())
        })
        .unwrap_or_else(|e| panic!("open: {e}"));
    journal
}

/// The LSNs a reopen of `storage` after `crash` replays.
fn kept_after(storage: &SimStorage, crash: Crash) -> Vec<Lsn> {
    let mut seen = Vec::new();
    let (_journal, _) = Journal::open(
        Arc::new(storage.snapshot(crash)),
        Path::new("/sim/journal"),
        Config::default(),
        0,
        &mut |record| {
            seen.push(record.lsn);
            Ok(())
        },
    )
    .unwrap_or_else(|e| panic!("reopen after {crash:?}: {e}"));
    seen
}

fn syncs(journal: &Journal) -> u64 {
    let stats = journal.stats();
    stats.barrier_syncs + stats.full_syncs
}

fn until(deadline: Duration, check: impl Fn() -> bool) -> Option<Duration> {
    let started = Instant::now();
    while started.elapsed() < deadline {
        if check() {
            return Some(started.elapsed());
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    None
}

fn written(journal: &Journal, lsn: Lsn) {
    until(WAIT, || journal.stats().written_lsn >= lsn)
        .unwrap_or_else(|| panic!("never written: {:?}", journal.stats()));
}

/// A person types 30 keys, one every 50 ms (1.5 s), each answered once written. The drafts share
/// about one sync a second (and the full sync after it); the last one is synced within a second of its key, and a kill of
/// every process keeps every key a reply answered.
#[test]
fn drafts_typed_a_key_every_50_ms_share_a_sync_a_second() {
    let storage = SimStorage::new(113220);
    let journal = open(&storage, Config::default());
    let before = syncs(&journal);
    let mut last = 0;
    for key in 0..30u32 {
        last = journal
            .append_kept(7, format!("{{\"draft\":\"{}\"}}", "x".repeat(key as usize)).as_bytes())
            .unwrap_or_else(|e| panic!("{e}"));
        written(&journal, last);
        std::thread::sleep(Duration::from_millis(50));
    }
    let typed = syncs(&journal) - before;
    let all: Vec<Lsn> = (1..=last).collect();
    assert_eq!(kept_after(&storage, Crash::Process), all, "a kill -9 lost a draft a reply showed");
    let synced = until(Duration::from_secs(3), || journal.durable_lsn() >= last);
    eprintln!("30 keys in 1.5 s: {typed} syncs; the last key synced after {synced:?}");
    assert!(
        typed <= 4,
        "30 keys typed over 1.5 s took {typed} syncs, more than about one a second"
    );
    let synced =
        synced.unwrap_or_else(|| panic!("the last draft never synced: {:?}", journal.stats()));
    assert!(
        synced <= Duration::from_millis(1300),
        "the last draft synced {synced:?} after its key"
    );
    assert_eq!(kept_after(&storage, Crash::Os), all, "an OS crash after the sync lost a draft");
}

/// A send right after typing syncs the drafts with the prompt, at once: the draft a person sent
/// never waits out the window.
#[test]
fn a_send_syncs_the_drafts_typed_before_it_at_once() {
    let storage = SimStorage::new(113221);
    let journal = open(&storage, Config::default());
    let mut last = 0;
    for key in 0..5u32 {
        last = journal
            .append_kept(7, format!("{{\"draft\":\"{key}\"}}").as_bytes())
            .unwrap_or_else(|e| panic!("{e}"));
        written(&journal, last);
    }
    let started = Instant::now();
    let send =
        journal.append(1, Class::Ack, b"{\"prompt\":\"sent\"}").unwrap_or_else(|e| panic!("{e}"));
    journal.wait_durable(send, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let took = started.elapsed();
    assert!(journal.durable_lsn() >= last, "{:?}", journal.stats());
    assert!(took < Duration::from_millis(200), "the send waited {took:?} for its sync");
    assert_eq!(kept_after(&storage, Crash::Os), (1..=send).collect::<Vec<_>>());
}

/// A turn's end and the next prompt: ten acked records appended 200 µs apart (the harness saw
/// them within 2 ms of one another, `scripts/measure/journal-writes.py`). The first acked record
/// after a quiet time is synced at once; the ones that follow share a sync or two.
#[test]
fn a_turns_acked_records_share_their_syncs() {
    let storage = SimStorage::new(113222);
    let journal = open(&storage, Config::default());
    let quiet =
        journal.append(1, Class::Ack, b"{\"kind\":\"status\"}").unwrap_or_else(|e| panic!("{e}"));
    let started = Instant::now();
    journal.wait_durable(quiet, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let first = started.elapsed();
    // Past the window: the next acked record is the first after a quiet time again.
    std::thread::sleep(Duration::from_millis(100));
    let before = syncs(&journal);
    let started = Instant::now();
    let mut last = 0;
    for index in 0..10u32 {
        last = journal
            .append(1, Class::Ack, format!("{{\"turn\":\"end\",\"record\":{index}}}").as_bytes())
            .unwrap_or_else(|e| panic!("{e}"));
        std::thread::sleep(Duration::from_micros(200));
    }
    journal.wait_durable(last, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let took = started.elapsed();
    let turn = syncs(&journal) - before;
    eprintln!(
        "first ack after quiet: {first:?}; 10 acks 200 µs apart: {turn} syncs, all durable after {took:?}"
    );
    assert!(turn <= 3, "a turn's 10 acked records took {turn} syncs");
    assert!(took < Duration::from_millis(100), "the turn's acks waited {took:?} for their syncs");
    assert!(first < Duration::from_millis(100), "an ack after a quiet time waited {first:?}");
}

/// What a crash of each kind takes back, per class, with the default config:
///
/// - an acked record, once a reply could show it (durable): nothing, after a kill -9 or an OS
///   crash; after a power loss, nothing once its full sync ran (at most `full_sync_interval`, 1 s,
///   after it);
/// - a kept record (a draft, a name), once a reply could show it (written): nothing after a kill
///   -9; after an OS crash, nothing once it is synced, at most `stream_sync_delay` (1 s) after its
///   write;
/// - a stream record (agent output): as a kept record.
#[test]
fn crash_bounds_per_class() {
    let storage = SimStorage::new(113223);
    let config = Config::default();
    let stream_delay = config.stream_sync_delay;
    let full_interval = config.full_sync_interval;
    let journal = open(&storage, config);
    let ack =
        journal.append(1, Class::Ack, b"{\"prompt\":\"a\"}").unwrap_or_else(|e| panic!("{e}"));
    journal.wait_durable(ack, WAIT).unwrap_or_else(|e| panic!("{e}"));
    let kept = journal.append_kept(7, b"{\"draft\":\"b\"}").unwrap_or_else(|e| panic!("{e}"));
    let stream =
        journal.append(1, Class::Stream, b"{\"chunk\":\"c\"}").unwrap_or_else(|e| panic!("{e}"));
    written(&journal, stream);
    let written_at = Instant::now();
    // Shown: a kill -9 keeps all three; an OS crash keeps the acked one.
    assert_eq!(kept_after(&storage, Crash::Process), vec![ack, kept, stream]);
    assert!(kept_after(&storage, Crash::Os).contains(&ack), "an OS crash lost a durable ack");
    // Within the stream delay of their write, the kept and the stream record are synced.
    let synced =
        until(stream_delay + Duration::from_millis(300), || journal.durable_lsn() >= stream)
            .unwrap_or_else(|| panic!("not synced within the stream delay: {:?}", journal.stats()));
    eprintln!("kept and stream records synced {synced:?} after their write");
    assert!(written_at.elapsed() <= stream_delay + Duration::from_millis(300));
    assert_eq!(kept_after(&storage, Crash::Os), vec![ack, kept, stream]);
    // Within the full-sync interval of that, a power loss keeps them too.
    until(full_interval + Duration::from_millis(300), || journal.full_durable_lsn() >= stream)
        .unwrap_or_else(|| panic!("no full sync within its interval: {:?}", journal.stats()));
    assert_eq!(kept_after(&storage, Crash::PowerLoss), vec![ack, kept, stream]);
}
