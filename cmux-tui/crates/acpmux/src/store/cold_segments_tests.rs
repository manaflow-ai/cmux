//! Cold segments (`store/cold_segments.rs`): every reader reads them as before, and a crash, a
//! full disk or a damaged archive at any point loses nothing.

use super::*;
use std::collections::BTreeSet;

/// The smallest segment a store rolls at (`LocalStore::new`).
const SEGMENT: u64 = 64 * 1024;
const ID: &str = "c";

fn record(seq: u64) -> EventRecord {
    let pad = "x".repeat((seq as usize * 37) % 900);
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: serde_json::json!({"text": format!("{seq} {pad}")}),
        host_seq: None,
    }
}

fn store(sessions: &Path) -> LocalStore {
    LocalStore::new(sessions.to_path_buf(), SEGMENT).unwrap()
}

/// A chat of `total` records in a fresh home: the home, its sessions folder and the store.
fn chat(total: u64) -> (tempfile::TempDir, PathBuf, LocalStore) {
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join("sessions");
    let store = store(&sessions);
    for seq in 1..=total {
        store.append(ID, &record(seq)).unwrap();
    }
    store.close_log(ID);
    (home, sessions, store)
}

fn all(store: &dyn Store) -> Vec<EventRecord> {
    let mut out = Vec::new();
    store
        .scan(ID, 0, &mut |rec| {
            out.push(rec);
            true
        })
        .unwrap();
    out
}

fn expected(total: u64) -> Vec<EventRecord> {
    (1..=total).map(record).collect()
}

/// Pages of 400 back from the end (`scan_back`, the paging read).
fn pages(store: &LocalStore) -> Vec<Vec<EventRecord>> {
    let mut out = Vec::new();
    let mut before = u64::MAX;
    loop {
        let mut page = Vec::new();
        store
            .scan_back(ID, 0, before, &|_, _| false, &mut |rec| {
                page.push(rec);
                page.len() < 400
            })
            .unwrap();
        let Some(last) = page.last() else { break };
        before = last.seq;
        out.push(page);
    }
    out
}

/// Every sealed segment moved cold: how many.
fn move_all(store: &LocalStore) -> u64 {
    let mut moved = 0;
    while let Some(staged) = store.stage_cold_segments(ID, 2, DEFAULT_LEVEL).unwrap() {
        let done = store.commit_cold_segments(ID, staged).unwrap();
        assert!(done.segments > 0, "a staged segment did not move");
        moved += done.segments;
    }
    moved
}

fn names(dir: &Path) -> BTreeSet<String> {
    std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

fn flip_byte(path: &Path, at: usize) {
    let mut bytes = std::fs::read(path).unwrap();
    bytes[at] ^= 0x5a;
    std::fs::write(path, &bytes).unwrap();
}

/// Sealed segments moved cold read back through the store as they were: every record by a
/// forward scan, and pages from the end (`scan_back`, the paging read) the same as before. Only
/// the open segment, never `000000` or the newest, stays a `.ndjson`.
#[test]
fn cold_segments_page_back_as_before() {
    let (_home, sessions, store) = chat(1500);
    let local = pages(&store);
    let segs = store.segment_files(ID).unwrap();
    assert!(segs.len() > 4, "{} segments", segs.len());
    assert_eq!(move_all(&store), segs.len() as u64 - 1);
    let listed = store.segment_files(ID).unwrap();
    assert_eq!(listed.len(), segs.len());
    assert!(listed[..listed.len() - 1].iter().all(|(_, p)| is_cold(p)));
    assert!(!is_cold(&listed[listed.len() - 1].1));
    let events = sessions.join(ID).join("events");
    assert_eq!(names(&events).iter().filter(|n| n.ends_with(".ndjson")).count(), 1);
    assert_eq!(all(&store), expected(1500));
    assert_eq!(pages(&store), local);
    // A store opened again lists the same and appends past the newest.
    let reopened = self::store(&sessions);
    reopened.append(ID, &record(1501)).unwrap();
    assert_eq!(all(&reopened), expected(1501));
}

/// `tail_after` reads newest first through every segment, cold ones too.
#[test]
fn tail_after_counts_cold_segments() {
    let (_home, _sessions, store) = chat(1500);
    move_all(&store);
    assert_eq!(store.tail_after(ID, 0).unwrap(), (1500, 1500));
    assert_eq!(store.tail_after(ID, 10).unwrap(), (1490, 1500));
}

/// A crash after each step of a move: the store opened again reads every record once, the next
/// settle leaves no temporary file, stray archive or second copy, and the next pass finishes.
#[test]
fn a_crash_at_every_step_of_a_move_loses_nothing() {
    for step in [Step::Written, Step::Renamed, Step::IndexStaged, Step::Committed, Step::Removed] {
        let (_home, sessions, store) = chat(1200);
        let before = all(&store);
        CRASH_AFTER.with(|c| c.set(Some(step)));
        let crashed =
            store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).and_then(|staged| match staged {
                Some(staged) => store.commit_cold_segments(ID, staged).map(|_| ()),
                None => Ok(()),
            });
        CRASH_AFTER.with(|c| c.set(None));
        let error = crashed.expect_err("the injected crash");
        assert!(error.is::<Crash>(), "{step:?}: {error:#}");
        drop(store);

        let restarted = self::store(&sessions);
        assert_eq!(all(&restarted), before, "{step:?}: read after the crash");
        restarted.settle_cold_segments(ID).unwrap();
        assert_eq!(all(&restarted), before, "{step:?}: read after the settle");
        let events = names(&sessions.join(ID).join("events"));
        let cold = names(&sessions.join(ID).join(COLD_DIR));
        assert!(
            events.iter().chain(&cold).all(|n| !n.contains(".tmp-")),
            "{step:?}: {events:?} {cold:?}"
        );
        for name in &cold {
            let index: u32 = name.trim_end_matches(".zst").parse().unwrap();
            let idx = format!("{index:06}{IDX_SUFFIX}");
            let ndjson = format!("{index:06}.ndjson");
            assert!(events.contains(&idx), "{step:?}: {name} has no index");
            assert!(!events.contains(&ndjson), "{step:?}: {name} beside its segment");
        }
        move_all(&restarted);
        assert_eq!(all(&restarted), before, "{step:?}: read after the next pass");
    }
}

/// A full disk while the archive is written: the segment stays as it was, no part of the
/// archive is left, and the next pass moves it.
#[test]
fn a_full_disk_while_archiving_keeps_the_segment_and_the_next_pass_moves_it() {
    let (_home, sessions, store) = chat(1200);
    let events = sessions.join(ID).join("events");
    let first = events.join("000001.ndjson");
    let bytes = std::fs::read(&first).unwrap();
    DISK_FULL_AFTER.with(|c| c.set(Some(16)));
    let full = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL);
    DISK_FULL_AFTER.with(|c| c.set(None));
    let error = full.err().expect("a full disk fails the move");
    assert!(
        error.chain().any(|e| e
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::StorageFull)),
        "{error:#}"
    );
    assert_eq!(std::fs::read(&first).unwrap(), bytes, "the segment is as it was");
    assert!(names(&sessions.join(ID).join(COLD_DIR)).is_empty());
    assert!(names(&events).iter().all(|n| !n.contains(IDX_SUFFIX)));
    assert_eq!(all(&store), expected(1200));
    assert!(move_all(&store) > 0, "the next pass moves it");
    assert_eq!(all(&store), expected(1200));
}

/// An archive whose bytes are wrong before its check never goes in place: the segment stays.
#[test]
fn a_byte_flipped_before_the_check_keeps_the_segment() {
    let (_home, sessions, store) = chat(1200);
    FLIP_BEFORE_CHECK.with(|c| c.set(true));
    let staged = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL);
    FLIP_BEFORE_CHECK.with(|c| c.set(false));
    assert!(staged.is_err(), "a damaged archive is refused before it goes in place");
    assert!(names(&sessions.join(ID).join(COLD_DIR)).is_empty());
    assert!(sessions.join(ID).join("events").join("000001.ndjson").exists());
    assert_eq!(all(&store), expected(1200));
}

/// A crash between the commit and the segment's removal, then the archive damaged: the chat
/// reads from its segment, the settle sets the archive aside and keeps the segment, and the next
/// pass moves it again.
#[test]
fn a_damaged_archive_beside_its_segment_reads_from_the_segment() {
    let (_home, sessions, store) = chat(1200);
    CRASH_AFTER.with(|c| c.set(Some(Step::Committed)));
    let staged = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).unwrap().unwrap();
    assert!(store.commit_cold_segments(ID, staged).is_err());
    CRASH_AFTER.with(|c| c.set(None));
    let zst = zst_path(&sessions.join(ID), 1);
    flip_byte(&zst, 40);
    assert_eq!(all(&store), expected(1200), "read from the segment");
    store.settle_cold_segments(ID).unwrap();
    assert!(!zst.exists(), "the damaged archive is set aside");
    assert!(sessions.join(ID).join("events").join("000001.ndjson").exists());
    assert!(names(&sessions.join(ID).join(COLD_DIR)).iter().any(|n| n.contains(".damaged-")));
    assert_eq!(all(&store), expected(1200));
    move_all(&store);
    assert!(zst.exists());
    assert_eq!(all(&store), expected(1200));
}

/// A cold segment whose archive or index is damaged with no segment left: a read fails with an
/// error that names it (never a page with records missing), and no settle removes anything.
#[test]
fn a_damaged_archive_or_index_alone_is_a_clear_error_and_nothing_goes() {
    let (_home, sessions, store) = chat(1200);
    move_all(&store);
    let session = sessions.join(ID);
    let zst = zst_path(&session, 2);
    let saved = std::fs::read(&zst).unwrap();
    flip_byte(&zst, saved.len() / 2);
    let error = store.scan(ID, 0, &mut |_| true).expect_err("a damaged archive fails the read");
    assert!(format!("{error:#}").contains("damaged"), "{error:#}");
    let files = (names(&session.join("events")), names(&session.join(COLD_DIR)));
    store.settle_cold_segments(ID).unwrap();
    assert_eq!((names(&session.join("events")), names(&session.join(COLD_DIR))), files);
    std::fs::write(&zst, &saved).unwrap();
    assert_eq!(all(&store), expected(1200));

    let idx = idx_path(&session, 3);
    let text = std::fs::read(&idx).unwrap();
    std::fs::write(&idx, &text[..text.len() / 2]).unwrap();
    let error = store.scan(ID, 0, &mut |_| true).expect_err("a cut index fails the read");
    assert!(format!("{error:#}").contains("does not read"), "{error:#}");
    store.settle_cold_segments(ID).unwrap();
    assert!(idx.exists() && zst_path(&session, 3).exists(), "nothing is removed");
    std::fs::write(&idx, &text).unwrap();
    assert_eq!(all(&store), expected(1200));
}

/// A page-back read that listed the segments before they went cold reads each one whole: the
/// `.ndjson` a move removed under it is read from its archive.
#[test]
fn a_page_back_while_segments_go_cold_reads_every_record() {
    let (_home, _sessions, store) = chat(1500);
    let local = pages(&store);
    let mut moved = false;
    let mut seen = Vec::new();
    store
        .scan_back(ID, 0, u64::MAX, &|_, _| false, &mut |rec| {
            if !moved {
                moved = true;
                assert!(move_all(&store) > 0);
            }
            seen.push(rec);
            true
        })
        .unwrap();
    assert_eq!(seen, local.concat(), "one read across the move");
    // And a forward scan the same way.
    let (_home, _sessions, store) = chat(1500);
    let mut moved = false;
    let mut seen = Vec::new();
    store
        .scan(ID, 0, &mut |rec| {
            if !moved {
                moved = true;
                assert!(move_all(&store) > 0);
            }
            seen.push(rec);
            true
        })
        .unwrap();
    assert_eq!(seen, expected(1500));
}

/// Retention leaves a cold segment as it is (every byte, the same file), and a cut that would
/// leave out a record of one is refused with the log unchanged.
#[test]
fn retention_leaves_cold_segments_and_a_cut_into_one_is_refused() {
    let (_home, sessions, store) = chat(1500);
    move_all(&store);
    let session = sessions.join(ID);
    let zst = zst_path(&session, 1);
    let archive = std::fs::read(&zst).unwrap();
    let staged =
        store.stage_compaction(ID, CompactMode::Write { archive: None }).unwrap().expect("a log");
    assert!(store.commit_compaction(ID, staged).unwrap());
    assert_eq!(std::fs::read(&zst).unwrap(), archive);
    assert!(names(&session.join(COLD_DIR)).iter().all(|n| n.ends_with(".zst")));
    assert_eq!(all(&store), expected(1500));

    let refused = store.truncate_after(ID, 5);
    assert!(refused.is_err(), "a cut into a cold segment: {refused:?}");
    assert_eq!(std::fs::read(&zst).unwrap(), archive);
    assert_eq!(all(&store), expected(1500));
}

/// The whole-chat archive (`store/cold.rs`) takes a chat with cold segments, every byte of them,
/// and brings it back as plain segments.
#[test]
fn a_whole_chat_archive_takes_its_cold_segments_and_brings_them_back() {
    let (_home, sessions, store) = chat(1500);
    move_all(&store);
    let staged = store.stage_cold(ID).unwrap().expect("a log to archive");
    assert!(store.commit_cold(ID, staged).unwrap());
    let session = sessions.join(ID);
    assert!(store.is_cold(ID));
    assert!(!session.join(COLD_DIR).exists(), "its archives went into the chat's");
    assert_eq!(all(&store), expected(1500), "rehydrated byte for byte");
    assert!(names(&session.join("events")).iter().all(|n| n.ends_with(".ndjson")));
    store.settle_cold_segments(ID).unwrap();
    assert!(move_all(&store) > 0, "its sealed segments go cold again");
    assert_eq!(all(&store), expected(1500));
}

fn journal_store(home: &Path, journal: &cmux_journal::SimStorage) -> Box<dyn Store> {
    let config = crate::config::StoreConfig { segment_bytes: SEGMENT, ..Default::default() };
    let journal_config = cmux_journal::Config {
        retry_min: std::time::Duration::from_millis(1),
        retry_max: std::time::Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    crate::store::open_with_journal(
        &config,
        home,
        std::sync::Arc::new(journal.clone()),
        journal_config,
    )
    .unwrap()
}

fn checkpointed(home: &Path) -> u64 {
    std::fs::read(home.join("journal-projected.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v["lsn"].as_u64())
        .unwrap_or(0)
}

/// Through the journal (the daemon's store): a segment goes cold only once the checkpoint covers
/// its last line, and a kill after it replays each record once, none into an archive.
#[test]
fn a_segment_goes_cold_only_once_the_checkpoint_covers_it_and_a_kill_replays_each_record_once() {
    use cmux_journal::{Crash, SimStorage};
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(7);
    let store = journal_store(home.path(), &journal);
    for seq in 1..=1500 {
        store.append(ID, &record(seq)).unwrap();
    }
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap());
    let staged = store.stage_cold_segments(ID, usize::MAX, DEFAULT_LEVEL).unwrap().unwrap();
    let lsn = staged.lsn.expect("the chat's newest record");
    assert!(checkpointed(home.path()) < lsn, "no checkpoint covers the pass yet");
    let moved = store.commit_cold_segments(ID, staged).unwrap();
    assert!(moved.segments > 2, "{moved:?}");
    assert!(checkpointed(home.path()) >= lsn, "the checkpoint covers every line moved");
    let archives: Vec<(String, Vec<u8>)> =
        names(&home.path().join("sessions").join(ID).join(COLD_DIR))
            .into_iter()
            .map(|n| {
                let bytes =
                    std::fs::read(home.path().join("sessions").join(ID).join(COLD_DIR).join(&n));
                (n, bytes.unwrap())
            })
            .collect();
    for seq in 1501..=1700 {
        store.append(ID, &record(seq)).unwrap();
    }
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap());
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = journal_store(home.path(), &killed);
    assert_eq!(all(store.as_ref()), expected(1700), "each record once");
    for (name, bytes) in archives {
        let now = std::fs::read(home.path().join("sessions").join(ID).join(COLD_DIR).join(&name));
        assert_eq!(now.unwrap(), bytes, "{name} is as it went cold");
    }
}
