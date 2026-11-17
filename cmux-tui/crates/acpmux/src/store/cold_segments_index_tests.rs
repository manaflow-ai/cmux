//! The chat's one index of its cold segments (`store/cold_segments.rs`, `events/segments.cold.idx`):
//! one file however many segments went cold, its rename the commit point; a crash at each step,
//! a damaged index, a chat written with one index file per segment, and a reader during the
//! commit all read every record.

use super::tests::{ID, all, chat, expected, move_all, names, store};
use super::*;

const ONE: &str = "segments.cold.idx";

fn events(sessions: &Path) -> PathBuf {
    sessions.join(ID).join("events")
}

/// The segments the chat's one index names, or None when there is none.
fn indexed(sessions: &Path) -> Option<Vec<u32>> {
    let bytes = std::fs::read(events(sessions).join(ONE)).ok()?;
    let doc: serde_json::Value = serde_json::from_slice(&bytes).expect("the index reads");
    let segments = doc["segments"].as_object().expect("a map of segments");
    Some(segments.keys().map(|k| k.parse().unwrap()).collect())
}

/// The per-segment index files in `events/` (`NNNNNN.cold.idx`, the layout before one index).
fn legacy(sessions: &Path) -> Vec<String> {
    names(&events(sessions))
        .into_iter()
        .filter(|n| n.len() == 6 + ".cold.idx".len() && n.ends_with(".cold.idx"))
        .collect()
}

/// The cold segments' archives in place (`NNNNNN.zst`).
fn archives(sessions: &Path) -> Vec<u32> {
    names(&sessions.join(ID).join(COLD_DIR))
        .into_iter()
        .filter_map(|n| n.strip_suffix(".zst").and_then(|s| s.parse().ok()))
        .collect()
}

/// Turns the chat's one index into one file per segment, as a build before it wrote them: each
/// segment's entry as `events/NNNNNN.cold.idx`, and the one index gone. `keep`: segments whose
/// entry also stays in the one index.
fn to_legacy(sessions: &Path, keep: &[u32]) {
    let path = events(sessions).join(ONE);
    let Ok(bytes) = std::fs::read(&path) else { return };
    let mut doc: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let segments = doc["segments"].as_object().unwrap().clone();
    for (key, entry) in &segments {
        let index: u32 = key.parse().unwrap();
        let file = events(sessions).join(format!("{index:06}.cold.idx"));
        std::fs::write(file, serde_json::to_vec(entry).unwrap()).unwrap();
    }
    doc["segments"] = serde_json::Value::Object(
        segments.into_iter().filter(|(k, _)| keep.contains(&k.parse().unwrap())).collect(),
    );
    if keep.is_empty() {
        std::fs::remove_file(&path).unwrap();
    } else {
        std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
    }
}

/// However many segments go cold, `events/` holds one index beside the open segment: no file per
/// segment, and every cold segment named in it.
#[test]
fn every_cold_segment_is_in_the_one_index() {
    let (_home, sessions, store) = chat(1500);
    let moved = move_all(&store);
    assert!(moved > 4, "{moved}");
    let files = names(&events(&sessions));
    assert_eq!(files.iter().filter(|n| n.ends_with(".ndjson")).count(), 1, "{files:?}");
    assert!(legacy(&sessions).is_empty(), "{files:?}");
    assert!(files.contains(ONE), "{files:?}");
    assert_eq!(files.len(), 2, "the open segment and the one index: {files:?}");
    assert_eq!(indexed(&sessions).unwrap(), archives(&sessions));
    assert_eq!(all(&store), expected(1500));
}

/// A crash after each step of a move, with segments already cold: before the commit point the
/// index is the old one byte for byte (the segment still hot); after it the new segment is in it.
/// The store opened again reads every record, a settle leaves every archive indexed and no
/// temporary file, and the next pass finishes.
#[test]
fn a_crash_at_every_step_keeps_the_old_index_until_its_rename() {
    for step in [Step::Written, Step::Renamed, Step::IndexStaged, Step::Committed, Step::Removed] {
        let (_home, sessions, store) = chat(1500);
        let staged = store.stage_cold_segments(ID, 2, DEFAULT_LEVEL).unwrap().unwrap();
        assert_eq!(store.commit_cold_segments(ID, staged).unwrap().segments, 2);
        let old = std::fs::read(events(&sessions).join(ONE)).expect("the one index");
        CRASH_AFTER.with(|c| c.set(Some(step)));
        let crashed =
            store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).and_then(|staged| match staged {
                Some(staged) => store.commit_cold_segments(ID, staged).map(|_| ()),
                None => Ok(()),
            });
        CRASH_AFTER.with(|c| c.set(None));
        assert!(crashed.expect_err("the injected crash").is::<Crash>(), "{step:?}");
        let now = std::fs::read(events(&sessions).join(ONE)).unwrap();
        let committed = matches!(step, Step::Committed | Step::Removed);
        if committed {
            assert_eq!(indexed(&sessions).unwrap(), vec![1, 2, 3], "{step:?}");
        } else {
            assert_eq!(now, old, "{step:?}: the old index until the rename");
        }
        drop(store);

        let restarted = self::store(&sessions);
        assert_eq!(all(&restarted), expected(1500), "{step:?}: read after the crash");
        restarted.settle_cold_segments(ID).unwrap();
        assert_eq!(all(&restarted), expected(1500), "{step:?}: read after the settle");
        let files = names(&events(&sessions));
        assert!(files.iter().all(|n| !n.contains(".tmp-")), "{step:?}: {files:?}");
        assert_eq!(indexed(&sessions).unwrap(), archives(&sessions), "{step:?}");
        for index in archives(&sessions) {
            assert!(!files.contains(&format!("{index:06}.ndjson")), "{step:?}: {index} twice");
        }
        move_all(&restarted);
        assert_eq!(all(&restarted), expected(1500), "{step:?}: read after the next pass");
        assert_eq!(indexed(&sessions).unwrap(), archives(&sessions), "{step:?}");
    }
}

/// The one index damaged (cut short): a read fails with an error that names it, never a page
/// with records missing; a settle sets it aside and makes it again from the archives, every
/// chunk checked, and the chat reads whole.
#[test]
fn a_damaged_index_is_a_clear_error_and_a_settle_makes_it_again() {
    let (_home, sessions, store) = chat(1500);
    move_all(&store);
    let path = events(&sessions).join(ONE);
    let text = std::fs::read(&path).unwrap();
    std::fs::write(&path, &text[..text.len() / 2]).unwrap();
    let error = store.scan(ID, 0, &mut |_| true).expect_err("a cut index fails the read");
    assert!(format!("{error:#}").contains("does not read"), "{error:#}");
    let before = archives(&sessions);
    store.settle_cold_segments(ID).unwrap();
    assert_eq!(archives(&sessions), before, "every archive is where it was");
    assert!(
        names(&events(&sessions)).iter().any(|n| n.starts_with(ONE) && n.contains(".damaged-"))
    );
    assert_eq!(indexed(&sessions).unwrap(), before);
    assert_eq!(all(&store), expected(1500));
    assert_eq!(store.warm_cold_segments(ID).unwrap().segments, before.len() as u64);
    assert_eq!(all(&store), expected(1500));
}

/// The one index damaged and one archive damaged too: nothing can be made again for that
/// segment, so the settle leaves every file as it is and the read stays a clear error.
#[test]
fn a_damaged_index_beside_a_damaged_archive_is_left_as_it_is() {
    let (_home, sessions, store) = chat(1500);
    move_all(&store);
    let path = events(&sessions).join(ONE);
    let text = std::fs::read(&path).unwrap();
    std::fs::write(&path, b"{\"schema\":").unwrap();
    let zst = zst_path(&sessions.join(ID), 2);
    let saved = std::fs::read(&zst).unwrap();
    let mut bytes = saved.clone();
    let at = bytes.len() / 2;
    bytes[at] ^= 0x5a;
    std::fs::write(&zst, &bytes).unwrap();
    let files = (names(&events(&sessions)), names(&sessions.join(ID).join(COLD_DIR)));
    assert!(store.settle_cold_segments(ID).is_err(), "a settle that cannot make it says so");
    assert_eq!((names(&events(&sessions)), names(&sessions.join(ID).join(COLD_DIR))), files);
    assert!(store.scan(ID, 0, &mut |_| true).is_err());
    std::fs::write(&path, &text).unwrap();
    std::fs::write(&zst, &saved).unwrap();
    assert_eq!(all(&store), expected(1500));
}

/// A chat written with one index file per segment (the layout before one index) reads as it
/// did, and its next settle moves every file into the one index; a chat with both (a crash
/// between that index's rename and the old files' removal) settles the same.
#[test]
fn per_segment_index_files_read_and_settle_into_the_one_index() {
    for keep in [&[][..], &[1, 2][..]] {
        let (_home, sessions, store) = chat(1500);
        let moved = move_all(&store);
        let cold = archives(&sessions);
        to_legacy(&sessions, keep);
        assert_eq!(legacy(&sessions).len() as u64, moved, "{keep:?}");
        let fresh = self::store(&sessions);
        assert_eq!(all(&fresh), expected(1500), "{keep:?}: the old layout reads");
        assert_eq!(fresh.tail_after(ID, 10).unwrap(), (1490, 1500));
        fresh.settle_cold_segments(ID).unwrap();
        assert!(legacy(&sessions).is_empty(), "{keep:?}: {:?}", names(&events(&sessions)));
        assert_eq!(indexed(&sessions).unwrap(), cold, "{keep:?}");
        assert_eq!(all(&fresh), expected(1500), "{keep:?}");
        assert!(move_all(&fresh) == 0, "{keep:?}: nothing left to move");
    }
}

/// The old layout warms (`cmux chats warm`) and archives whole (`store/cold.rs`) as it did.
#[test]
fn per_segment_index_files_warm_and_archive_whole() {
    let (_home, sessions, store) = chat(1500);
    let plain: Vec<_> = names(&events(&sessions)).into_iter().collect();
    let moved = move_all(&store);
    to_legacy(&sessions, &[]);
    let warmed = store.warm_cold_segments(ID).unwrap();
    assert_eq!(warmed.segments, moved, "{warmed:?}");
    assert_eq!(names(&events(&sessions)).into_iter().collect::<Vec<_>>(), plain);
    assert_eq!(all(&store), expected(1500));

    move_all(&store);
    to_legacy(&sessions, &[]);
    let staged = store.stage_cold(ID).unwrap().expect("a log to archive");
    assert!(store.commit_cold(ID, staged).unwrap());
    assert!(store.is_cold(ID));
    assert_eq!(all(&store), expected(1500), "rehydrated byte for byte");
    assert_eq!(names(&events(&sessions)).into_iter().collect::<Vec<_>>(), plain);
}

/// Readers on other threads, forward and back, all through a move of every sealed segment: each
/// read returns every record once, in order.
#[test]
fn readers_during_the_commits_read_every_record() {
    let (_home, _sessions, store) = chat(2000);
    let store = std::sync::Arc::new(store);
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let readers: Vec<_> = (0..2)
        .map(|n| {
            let (store, done) = (store.clone(), done.clone());
            std::thread::spawn(move || {
                let mut reads = 0u64;
                while !done.load(std::sync::atomic::Ordering::SeqCst) || reads < 3 {
                    let mut seen = Vec::new();
                    if n == 0 {
                        store
                            .scan(ID, 0, &mut |rec| {
                                seen.push(rec);
                                true
                            })
                            .unwrap();
                    } else {
                        store
                            .scan_back(ID, 0, u64::MAX, &|_, _| false, &mut |rec| {
                                seen.push(rec);
                                true
                            })
                            .unwrap();
                        seen.reverse();
                    }
                    assert_eq!(seen, expected(2000), "reader {n}, read {reads}");
                    reads += 1;
                }
                reads
            })
        })
        .collect();
    while let Some(staged) = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).unwrap() {
        store.commit_cold_segments(ID, staged).unwrap();
    }
    done.store(true, std::sync::atomic::Ordering::SeqCst);
    for reader in readers {
        assert!(reader.join().unwrap() >= 3);
    }
    assert_eq!(all(&*store), expected(2000));
}
