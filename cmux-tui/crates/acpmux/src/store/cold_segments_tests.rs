//! Cold segments (`store/cold_segments.rs`): every reader reads them as before, and a crash, a
//! full disk or a damaged archive at any point loses nothing.

use super::*;
use std::collections::BTreeSet;

/// The smallest segment a store rolls at (`LocalStore::new`).
pub(super) const SEGMENT: u64 = 64 * 1024;
pub(super) const ID: &str = "c";

pub(super) fn record(seq: u64) -> EventRecord {
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

pub(super) fn store(sessions: &Path) -> LocalStore {
    LocalStore::new(sessions.to_path_buf(), SEGMENT).unwrap()
}

/// A chat of `total` records in a fresh home: the home, its sessions folder and the store.
pub(super) fn chat(total: u64) -> (tempfile::TempDir, PathBuf, LocalStore) {
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join("sessions");
    let store = store(&sessions);
    for seq in 1..=total {
        store.append(ID, &record(seq)).unwrap();
    }
    store.close_log(ID);
    (home, sessions, store)
}

pub(super) fn all(store: &dyn Store) -> Vec<EventRecord> {
    let mut out = Vec::new();
    store
        .scan(ID, 0, &mut |rec| {
            out.push(rec);
            true
        })
        .unwrap();
    out
}

pub(super) fn expected(total: u64) -> Vec<EventRecord> {
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
pub(super) fn move_all(store: &LocalStore) -> u64 {
    let mut moved = 0;
    while let Some(staged) = store.stage_cold_segments(ID, 2, DEFAULT_LEVEL).unwrap() {
        let done = store.commit_cold_segments(ID, staged).unwrap();
        assert!(done.segments > 0, "a staged segment did not move");
        moved += done.segments;
    }
    moved
}

pub(super) fn names(dir: &Path) -> BTreeSet<String> {
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

/// A chat of `total` records with a `turn_result` every 50th, the rest agent output.
fn chat_with_turns(total: u64) -> (tempfile::TempDir, PathBuf, LocalStore) {
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join("sessions");
    let store = store(&sessions);
    for seq in 1..=total {
        store.append(ID, &turn_record(seq)).unwrap();
    }
    store.close_log(ID);
    (home, sessions, store)
}

fn turn_record(seq: u64) -> EventRecord {
    if seq % 50 == 0 {
        EventRecord {
            seq,
            at: seq,
            dir: "mux".into(),
            kind: "turn_result".into(),
            msg: serde_json::json!({"status": "failed", "turnId": format!("t{seq}")}),
            host_seq: None,
        }
    } else {
        record(seq)
    }
}

/// Every `turn_result` back from the end through the copies (`scan_back_indexed`, a log load's
/// catch-up and rate hold), and the raw bytes of cold chunks the read decoded.
fn results_back(store: &LocalStore) -> (Vec<u64>, u64) {
    DECODED.with(|n| n.set(0));
    let mut seqs = Vec::new();
    store
        .scan_back_indexed(ID, 0, u64::MAX, &|_, kind| kind != b"turn_result", &mut |rec| {
            seqs.push(rec.seq);
            true
        })
        .unwrap();
    (seqs, DECODED.with(std::cell::Cell::get))
}

/// A read back over a chat's history for indexed kinds reads a cold segment's copy, carried over
/// from its `.ndjson` when it went cold, and decodes none of its chunks: each such read (a log
/// load's catch-up, rate hold and resume, on every start) decoded every cold segment of the chat,
/// about 1 GB of allocations on the first start after a 1 GB chat went cold (goal
/// infinite-chats, `restartPeakRss` 1.41x). A segment that lost its copy gets one by the next
/// kinds scan, so only that scan decodes it.
#[test]
fn a_read_back_for_indexed_kinds_reads_cold_segments_copies_not_their_chunks() {
    let (_home, sessions, store) = chat_with_turns(1500);
    let want: Vec<u64> = (1..=1500).rev().filter(|s| s % 50 == 0).collect();
    // Every sealed segment has its copy (the append path's, `store/segment_writer.rs`).
    assert_eq!(results_back(&store).0, want);
    let moved = move_all(&store);
    assert!(moved > 3, "{moved} segments went cold");
    assert_eq!(results_back(&store), (want.clone(), 0), "a read back decoded cold chunks");
    // A store opened again (a restart) reads the same copies.
    let reopened = self::store(&sessions);
    assert_eq!(results_back(&reopened), (want.clone(), 0));
    // A forward scan for indexed kinds (a log load's) reads them too.
    let forward = |store: &LocalStore| {
        DECODED.with(|n| n.set(0));
        let mut seqs = Vec::new();
        store
            .scan_kinds(ID, &["turn_result"], &mut |rec| {
                seqs.push(rec.seq);
                true
            })
            .unwrap();
        (seqs.len(), DECODED.with(std::cell::Cell::get))
    };
    assert_eq!(forward(&reopened), (30, 0), "a kinds scan decoded cold chunks");
    // A cold segment whose copy is gone: the next kinds scan decodes it once and makes the copy
    // again, as it does a local segment's; the reads after it decode nothing.
    let copy = sessions.join(ID).join(super::kind_index::DIR).join("000001.ndjson");
    std::fs::remove_file(&copy).unwrap();
    let (n, decoded) = forward(&reopened);
    assert_eq!(n, 30);
    assert!(decoded > 0, "the copy was made without reading the segment");
    assert!(copy.exists(), "no copy was made for the cold segment");
    assert_eq!(forward(&reopened), (30, 0));
    assert_eq!(results_back(&reopened), (want, 0));
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

/// An index whose chunk names a huge compressed length is damage read as an error, never an
/// allocation of that length (#43562 review F4).
#[test]
fn an_index_naming_a_huge_chunk_is_a_clear_error() {
    let (_home, sessions, store) = chat(1200);
    move_all(&store);
    let idx = idx_path(&sessions.join(ID), 2);
    let saved = std::fs::read(&idx).unwrap();
    let mut doc: serde_json::Value = serde_json::from_slice(&saved).unwrap();
    doc["chunks"][0][3] = serde_json::json!(u64::MAX / 2);
    std::fs::write(&idx, serde_json::to_vec(&doc).unwrap()).unwrap();
    let error =
        store.scan(ID, 0, &mut |_| true).expect_err("a chunk past the archive fails the read");
    assert!(format!("{error:#}").contains("damaged"), "{error:#}");
    std::fs::write(&idx, &saved).unwrap();
    assert_eq!(all(&store), expected(1200));
}

/// A warm or settle of a name that is not one chat folder (`..`, a separator, an absolute
/// path) is refused before it touches a file (#43562 review F1).
#[test]
fn a_warm_or_settle_outside_the_chat_tree_is_refused() {
    let (home, sessions, store) = chat(1200);
    move_all(&store);
    let outside = home.path().join("other");
    std::fs::create_dir_all(outside.join(COLD_DIR)).unwrap();
    std::fs::write(outside.join(COLD_DIR).join("000001.zst"), b"not ours").unwrap();
    for id in ["../other", "..", ".", "a/b", "/tmp", "", "a\\b"] {
        assert!(store.warm_cold_segments(id).is_err(), "{id:?} warmed");
        assert!(store.settle_cold_segments(id).is_err(), "{id:?} settled");
    }
    assert!(outside.join(COLD_DIR).join("000001.zst").exists(), "nothing outside sessions/ moved");
    assert_eq!(all(&store), expected(1200));
    let _ = sessions;
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
/// A retention pass asked to keep an archive keeps the chat's cold segments in it too, each
/// archive and index byte for byte: the archive holds the whole history (#43562 review P1-F1).
#[test]
fn a_retention_archive_keeps_the_cold_segments() {
    let (home, sessions, store) = chat(1500);
    move_all(&store);
    let session = sessions.join(ID);
    let cold: Vec<u32> = names(&session.join(COLD_DIR))
        .iter()
        .filter_map(|n| n.strip_suffix(".zst")?.parse().ok())
        .collect();
    assert!(!cold.is_empty());
    let root = home.path().join("kept");
    let staged = store
        .stage_compaction(ID, CompactMode::Write { archive: Some(&root) })
        .unwrap()
        .expect("a log");
    assert!(store.commit_compaction(ID, staged).unwrap());
    let pass = std::fs::read_dir(root.join(ID)).unwrap().next().unwrap().unwrap().path();
    for index in cold {
        for from in [zst_path(&session, index), idx_path(&session, index)] {
            let kept = pass.join("events").join(from.file_name().unwrap());
            assert_eq!(
                std::fs::read(&kept).unwrap(),
                std::fs::read(&from).unwrap(),
                "{}",
                kept.display()
            );
        }
    }
    assert_eq!(all(&store), expected(1500));
}

/// An index whose chunks leave a gap is damage read as an error, never history that ends early
/// (#43562 review F4).
#[test]
fn an_index_with_a_gap_is_a_clear_error() {
    let (_home, sessions, store) = chat(1200);
    move_all(&store);
    let idx = idx_path(&sessions.join(ID), 2);
    let saved = std::fs::read(&idx).unwrap();
    let mut doc: serde_json::Value = serde_json::from_slice(&saved).unwrap();
    // Its one chunk now ends 4 KiB short of the segment: the rest is a gap.
    let raw_len = doc["rawLen"].as_u64().unwrap();
    doc["rawLen"] = serde_json::json!(raw_len + 4096);
    std::fs::write(&idx, serde_json::to_vec(&doc).unwrap()).unwrap();
    let error = store.scan(ID, 0, &mut |_| true).expect_err("a gapped index fails the read");
    assert!(format!("{error:#}").contains("cover"), "{error:#}");
    std::fs::write(&idx, &saved).unwrap();
    assert_eq!(all(&store), expected(1200));
}

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

/// The whole-chat archive takes a cold segment only as its archive decodes whole to what its index
/// records. An index damaged to a shorter `rawLen`, still valid JSON, would otherwise stage only
/// that prefix, hash the prefix as the file, and let the commit drop the intact segment archive
/// (#43562 review F1 at 8dd36113).
#[test]
fn a_whole_chat_archive_refuses_a_cold_segment_whose_index_is_short() {
    let (_home, sessions, store) = chat(1500);
    assert!(move_all(&store) > 0);
    let session = sessions.join(ID);
    let idx = names(&session.join("events"))
        .into_iter()
        .find(|n| n.ends_with(".cold.idx"))
        .expect("a cold segment's index");
    let idx = session.join("events").join(idx);
    let mut doc: serde_json::Value = serde_json::from_slice(&std::fs::read(&idx).unwrap()).unwrap();
    let raw = doc["rawLen"].as_u64().unwrap();
    doc["rawLen"] = (raw / 2).into();
    std::fs::write(&idx, serde_json::to_vec(&doc).unwrap()).unwrap();
    let archives = names(&session.join(COLD_DIR));
    assert!(store.stage_cold(ID).is_err(), "a short index is refused, not archived as the segment");
    assert!(!store.is_cold(ID));
    assert_eq!(names(&session.join(COLD_DIR)), archives, "every segment archive is still there");
    doc["rawLen"] = raw.into();
    std::fs::write(&idx, serde_json::to_vec(&doc).unwrap()).unwrap();
    assert_eq!(all(&store), expected(1500), "the history is whole once the index is");
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

/// Every record of the chat's plain segments, read as files are (no store): what a reader
/// returned before cold segments existed.
fn plain_records(sessions: &Path) -> Vec<EventRecord> {
    let events = sessions.join(ID).join("events");
    let mut out = Vec::new();
    for name in names(&events) {
        assert!(!name.contains(IDX_SUFFIX), "{name}: no cold segment with the setting off");
        if !name.ends_with(".ndjson") {
            continue;
        }
        let bytes = std::fs::read(events.join(&name)).unwrap();
        for line in bytes.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            out.push(serde_json::from_slice(line).unwrap());
        }
    }
    out
}

/// The chat folder, every file's name and bytes.
fn chat_files(sessions: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
    let session = sessions.join(ID);
    let mut out = std::collections::BTreeMap::new();
    for dir in ["events", COLD_DIR] {
        for name in names(&session.join(dir)) {
            out.insert(
                format!("{dir}/{name}"),
                std::fs::read(session.join(dir).join(&name)).unwrap(),
            );
        }
    }
    out
}

/// Pages of 400 back from the end of `records`, as `pages` reads them.
fn pages_of(records: &[EventRecord]) -> Vec<Vec<EventRecord>> {
    records.rchunks(400).map(|page| page.iter().rev().cloned().collect()).collect()
}

/// With the setting off a chat has no cold file, and every reader that now goes through the
/// cold-segment code (`open_segment`, the listing that parses index names, the seal hook, the
/// writer's open) reads and writes exactly what plain files hold: forward scans, pages back,
/// `tail_after`, a fork view, a settle, retention and a cut, and a reopened writer that goes on
/// in the same segment.
#[test]
fn with_the_setting_off_every_reader_reads_the_plain_files_as_before() {
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join("sessions");
    let store = store(&sessions);
    // The hook goes in before the first record: the chat's every roll-over calls it.
    let sealed = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let seen = sealed.clone();
    Store::on_segment_sealed(
        &store,
        std::sync::Arc::new(move |_: &str| {
            seen.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }),
    );
    for seq in 1..=1600 {
        store.append(ID, &record(seq)).unwrap();
    }
    store.close_log(ID);
    assert!(sealed.load(std::sync::atomic::Ordering::Relaxed) > 0, "the hook ran on seals");
    let plain = plain_records(&sessions);
    assert_eq!(plain, expected(1600));
    let files = chat_files(&sessions);
    assert!(files.keys().all(|k| k.starts_with("events/") && k.ends_with(".ndjson")), "{files:?}");

    assert_eq!(all(&store), plain, "a forward scan");
    assert_eq!(pages(&store), pages_of(&plain), "pages back");
    for after in [0, 1, 399, 1234, 1599, 1600] {
        let tail: Vec<_> = plain.iter().filter(|r| r.seq > after).collect();
        let last = tail.last().map_or(after, |r| r.seq);
        assert_eq!(
            store.tail_after(ID, after).unwrap(),
            (tail.len() as u64, last),
            "after {after}"
        );
    }
    let fork = ForkView::new(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    assert_eq!(all(&fork), plain, "through a fork view");
    store.settle_cold_segments(ID).unwrap();
    assert_eq!(chat_files(&sessions), files, "a settle changes nothing");

    // A reopened writer goes on in the segment it left, as it always did.
    drop(fork);
    drop(store);
    let store = LocalStore::new(sessions.clone(), SEGMENT).unwrap();
    store.append(ID, &record(1601)).unwrap();
    store.close_log(ID);
    let after = chat_files(&sessions);
    assert_eq!(
        after.keys().collect::<Vec<_>>(),
        files.keys().collect::<Vec<_>>(),
        "no new segment for one more record"
    );
    let last = files.keys().last().unwrap();
    let mut grown = files[last].clone();
    grown.extend_from_slice(&serde_json::to_vec(&record(1601)).unwrap());
    grown.push(b'\n');
    assert_eq!(after[last], grown, "the record went at the end of the last segment");

    // Retention and a cut, on plain files.
    let staged =
        store.stage_compaction(ID, CompactMode::Write { archive: None }).unwrap().expect("a log");
    assert!(store.commit_compaction(ID, staged).unwrap());
    assert_eq!(all(&store), plain_records(&sessions));
    assert_eq!(all(&store), expected(1601));
    assert!(store.truncate_after(ID, 700).unwrap());
    assert_eq!(all(&store), expected(700));
    assert_eq!(plain_records(&sessions), expected(700));
}

/// Through the journal with the setting off: a kill replays each record once into plain
/// segments, and the repair reads them as files.
#[test]
fn with_the_setting_off_the_journal_repair_writes_plain_segments_as_before() {
    use cmux_journal::{Crash, SimStorage};
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(11);
    let store = journal_store(home.path(), &journal);
    for seq in 1..=1500 {
        store.append(ID, &record(seq)).unwrap();
    }
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap());
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = journal_store(home.path(), &killed);
    let sessions = home.path().join("sessions");
    assert_eq!(all(store.as_ref()), expected(1500), "each record once");
    assert_eq!(plain_records(&sessions), expected(1500), "in plain segments");
    assert!(!sessions.join(ID).join(COLD_DIR).exists());
}

fn segment_bytes(sessions: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
    chat_files(sessions)
        .into_iter()
        .filter(|(k, _)| k.starts_with("events/") && k.ends_with(".ndjson"))
        .collect()
}

/// `cmux chats warm`: every cold segment comes back as the plain file it was, byte for byte, and
/// nothing of the cold layout is left.
#[test]
fn warm_brings_every_cold_segment_back_byte_for_byte() {
    let (_home, sessions, store) = chat(1500);
    let before = segment_bytes(&sessions);
    let moved = move_all(&store);
    assert!(moved > 2);
    let warmed = store.warm_cold_segments(ID).unwrap();
    assert_eq!(warmed.segments, moved);
    assert!(warmed.left.is_empty(), "{warmed:?}");
    assert_eq!(chat_files(&sessions), before, "the same files, the same bytes");
    assert!(!sessions.join(ID).join(COLD_DIR).exists());
    assert_eq!(all(&store), expected(1500));
    assert_eq!(store.warm_cold_segments(ID).unwrap(), ColdWarmed::default(), "nothing left to do");
    assert_eq!(move_all(&store), moved, "they can go cold again");
}

/// A crash after each step of a warm: the chat reads every record at once, a settle leaves a
/// whole log, and a second warm brings every segment back.
#[test]
fn a_crash_at_every_step_of_a_warm_loses_nothing() {
    for step in [Step::WarmWritten, Step::WarmPlaced, Step::WarmCommitted] {
        let (_home, sessions, store) = chat(1500);
        let before = segment_bytes(&sessions);
        move_all(&store);
        CRASH_AFTER.with(|c| c.set(Some(step)));
        let crashed = store.warm_cold_segments(ID);
        CRASH_AFTER.with(|c| c.set(None));
        assert!(crashed.is_err(), "{step:?}");
        // The crash ends the store: the next one settles what it left, its temporary file too.
        drop(store);
        let store = self::store(&sessions);
        assert_eq!(all(&store), expected(1500), "{step:?}: read after the crash");
        store.settle_cold_segments(ID).unwrap();
        assert_eq!(all(&store), expected(1500), "{step:?}: read after the settle");
        let warmed = store.warm_cold_segments(ID).unwrap();
        assert!(warmed.left.is_empty(), "{step:?}: {warmed:?}");
        assert_eq!(chat_files(&sessions), before, "{step:?}: every segment plain again");
        assert_eq!(all(&store), expected(1500), "{step:?}");
    }
}

/// A full disk while a warm writes: each segment stays cold, intact and readable, no temporary
/// file is left, and a later warm brings them back.
#[test]
fn a_full_disk_while_warming_keeps_every_segment_cold_and_a_later_warm_brings_them_back() {
    let (_home, sessions, store) = chat(1500);
    let before = segment_bytes(&sessions);
    let moved = move_all(&store);
    let cold = chat_files(&sessions);
    DISK_FULL_AFTER.with(|c| c.set(Some(16)));
    let full = store.warm_cold_segments(ID);
    DISK_FULL_AFTER.with(|c| c.set(None));
    let full = full.unwrap();
    assert_eq!(full.segments, 0);
    assert_eq!(full.left.len() as u64, moved, "{full:?}");
    assert!(full.left.iter().all(|(_, e)| e.contains("no space left")), "{full:?}");
    assert_eq!(chat_files(&sessions), cold, "every file as it was, no temporary file");
    assert_eq!(all(&store), expected(1500));
    let warmed = store.warm_cold_segments(ID).unwrap();
    assert_eq!(warmed.segments, moved);
    assert_eq!(chat_files(&sessions), before);
}

/// A damaged archive with no segment left to rebuild it from: a warm leaves it cold as it is,
/// names it with a clear error, and brings the others back; nothing is removed.
#[test]
fn a_damaged_archive_stays_cold_with_a_clear_error_and_the_others_come_back() {
    let (_home, sessions, store) = chat(1500);
    let before = segment_bytes(&sessions);
    let moved = move_all(&store);
    let session = sessions.join(ID);
    let zst = zst_path(&session, 2);
    let saved = std::fs::read(&zst).unwrap();
    flip_byte(&zst, saved.len() / 2);
    let damaged = std::fs::read(&zst).unwrap();
    let warmed = store.warm_cold_segments(ID).unwrap();
    assert_eq!(warmed.segments, moved - 1);
    assert_eq!(warmed.left.len(), 1, "{warmed:?}");
    assert_eq!(warmed.left[0].0, 2);
    assert!(warmed.left[0].1.contains("damaged"), "{warmed:?}");
    assert_eq!(std::fs::read(&zst).unwrap(), damaged, "the archive is as it was");
    assert!(idx_path(&session, 2).exists(), "its index too");
    assert!(!session.join("events").join("000002.ndjson").exists(), "no segment made from it");
    assert!(
        names(&session.join("events")).iter().all(|n| !n.contains(".tmp-")),
        "no temporary file"
    );
    std::fs::write(&zst, &saved).unwrap();
    assert_eq!(store.warm_cold_segments(ID).unwrap().segments, 1);
    assert_eq!(chat_files(&sessions), before);
}

/// A page-back read that listed the segments while they were cold reads each one whole as a warm
/// brings them back under it.
#[test]
fn a_page_back_while_segments_warm_reads_every_record() {
    let (_home, _sessions, store) = chat(1500);
    move_all(&store);
    let mut warmed = false;
    let mut seen = Vec::new();
    store
        .scan_back(ID, 0, u64::MAX, &|_, _| false, &mut |rec| {
            if !warmed {
                warmed = true;
                assert!(store.warm_cold_segments(ID).unwrap().segments > 0);
            }
            seen.push(rec);
            true
        })
        .unwrap();
    seen.reverse();
    assert_eq!(seen, expected(1500), "one read across the warm");
}
