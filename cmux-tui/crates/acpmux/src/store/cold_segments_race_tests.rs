//! Cold segments against the other changes that remove one of a chat's log's copies (#43562
//! review): a settle against a warm (F1) and against a whole-chat archive and its rehydrate
//! (P2-F1, P3-F2), the chat folder's sync before a segment goes (F2, P3-F1), and a quarantined
//! archive a whole-chat archive would drop (P2-F2). Each interleaving is forced with the store's
//! test stops and notes, never a timer.

use super::tests::{ID, all, chat, expected, move_all, store};
use super::*;
use crate::store::cold::NOTE_COLD_LOCK_WAITS;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

const ARRIVE: std::time::Duration = std::time::Duration::from_secs(30);

type Stop = (Receiver<()>, Sender<()>);

/// Puts a stop in `slot` on this thread: the first channel hears it reached it, the second
/// releases it.
fn stop_at(slot: &'static std::thread::LocalKey<super::super::log_sync::HoldSlot>) -> Stop {
    let (arrived_tx, arrived) = channel();
    let (release, release_rx) = channel();
    slot.with(|hold| *hold.borrow_mut() = Some((arrived_tx, release_rx)));
    (arrived, release)
}

/// F1: a settle while a warm has put a segment back beside its index and archive. Without the
/// chat's cold lock the settle took the `.ndjson` for a crash's leftover beside its committed
/// archive and removed it; the warm then removed the index and the archive, and reported success.
#[test]
fn a_settle_while_a_warm_puts_a_segment_back_loses_nothing() {
    let (_home, _sessions, store) = chat(1500);
    assert!(move_all(&store) > 0);
    let store = Arc::new(store);
    let (tx, rx) = channel::<Stop>();
    let warm = {
        let store = store.clone();
        std::thread::spawn(move || {
            tx.send(stop_at(&HOLD_WARM_PLACED)).unwrap();
            store.warm_cold_segments(ID).unwrap()
        })
    };
    let (arrived, release) = rx.recv_timeout(ARRIVE).expect("the warm never installed its stop");
    arrived.recv_timeout(ARRIVE).expect("the warm never put a segment back");
    // The settle either waits for the warm's lock ("waits") or, with none, settles now.
    let (said, heard) = channel::<&'static str>();
    let settle = {
        let store = store.clone();
        let done = said.clone();
        std::thread::spawn(move || {
            NOTE_COLD_LOCK_WAITS.with(|note| *note.borrow_mut() = Some(said));
            store.settle_cold_segments(ID).unwrap();
            let _ = done.send("settled");
        })
    };
    let first = heard.recv_timeout(ARRIVE).expect("the settle neither waited nor finished");
    release.send(()).unwrap();
    let warmed = warm.join().unwrap();
    settle.join().unwrap();
    assert_eq!(all(&*store), expected(1500), "the settle went first: {first}; {warmed:?}");
    assert_eq!(first, "waits");
    assert!(warmed.left.is_empty(), "{warmed:?}");
}

/// P2-F1, P3-F2: a settle that checked a `.ndjson` a crash left beside its committed archive,
/// then a whole-chat archive and its rehydrate before the settle removes it. Without the chat's
/// cold lock the settle then removed the rehydrated segment, its index and archive already gone.
#[test]
fn a_settle_against_a_whole_chat_archive_and_rehydrate_loses_nothing() {
    let (_home, sessions, store) = chat(1500);
    // A crash after a move's commit point: the index is in place, the `.ndjson` still there.
    CRASH_AFTER.with(|c| c.set(Some(Step::Committed)));
    let staged = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).unwrap().unwrap();
    let crashed = store.commit_cold_segments(ID, staged);
    CRASH_AFTER.with(|c| c.set(None));
    assert!(crashed.unwrap_err().is::<Crash>());
    drop(store);
    let store = Arc::new(self::store(&sessions));

    let (tx, rx) = channel::<Stop>();
    let settle = {
        let store = store.clone();
        std::thread::spawn(move || {
            tx.send(stop_at(&HOLD_SETTLE_BEFORE_REMOVE)).unwrap();
            store.settle_cold_segments(ID).unwrap();
        })
    };
    let (arrived, release) = rx.recv_timeout(ARRIVE).expect("the settle never installed its stop");
    arrived.recv_timeout(ARRIVE).expect("the settle never checked the crash's segment");
    // The whole-chat archive and its rehydrate either wait for the settle's lock ("waits") or,
    // with none, run now.
    let (said, heard) = channel::<&'static str>();
    let archive = {
        let store = store.clone();
        let done = said.clone();
        std::thread::spawn(move || {
            NOTE_COLD_LOCK_WAITS.with(|note| *note.borrow_mut() = Some(said));
            let staged = store.stage_cold(ID).unwrap().expect("a log to archive");
            assert!(store.commit_cold(ID, staged).unwrap());
            assert!(store.rehydrate(ID).unwrap());
            let _ = done.send("archived and rehydrated");
        })
    };
    let first = heard.recv_timeout(ARRIVE).expect("the archive neither waited nor finished");
    release.send(()).unwrap();
    settle.join().unwrap();
    archive.join().unwrap();
    assert_eq!(all(&*store), expected(1500), "the archive went first: {first}");
    assert_eq!(first, "waits");
}

/// F2, P3-F1: a move's first commit makes `cold-segments/`; the chat's folder, which holds its
/// entry, is synced before any segment goes. A failed sync of it leaves every segment.
#[test]
fn a_move_syncs_the_chat_folder_before_a_segment_goes() {
    let (_home, sessions, store) = chat(1200);
    let staged = store.stage_cold_segments(ID, 1, DEFAULT_LEVEL).unwrap().unwrap();
    let index = staged.indexes()[0];
    let src = sessions.join(ID).join("events").join(format!("{index:06}.ndjson"));
    super::super::log_sync::FAIL_DIR_SYNC.with(|fail| *fail.borrow_mut() = Some(sessions.join(ID)));
    let committed = store.commit_cold_segments(ID, staged);
    let synced = super::super::log_sync::FAIL_DIR_SYNC.with(|fail| fail.borrow_mut().take());
    assert!(synced.is_none(), "the chat's folder was never synced");
    assert!(committed.is_err(), "the move went on past a failed sync of the chat's folder");
    assert!(src.exists(), "{index:06}.ndjson went before its folder's entry was on the disk");
    assert_eq!(all(&store), expected(1200));
}

/// P2-F2: a whole-chat archive drops `cold-segments/` with the log; an archive a settle kept
/// aside there (`.orphan-`) may be the only copy of a segment, so the chat is not archived while
/// one is there, with an error that names it.
#[test]
fn a_whole_chat_archive_keeps_a_quarantined_cold_segment() {
    let (_home, sessions, store) = chat(1500);
    assert!(move_all(&store) > 0);
    let orphan = sessions.join(ID).join(COLD_DIR).join("000099.zst.orphan-1");
    std::fs::write(&orphan, b"the only copy").unwrap();
    let error = match store.stage_cold(ID) {
        Ok(Some(staged)) => {
            let committed = store.commit_cold(ID, staged);
            panic!("archived ({committed:?}): the orphan is {:?}", std::fs::read(&orphan).ok())
        }
        Ok(None) => panic!("no log to archive"),
        Err(e) => format!("{e:#}"),
    };
    assert!(error.contains("000099.zst.orphan-1"), "{error}");
    assert_eq!(std::fs::read(&orphan).unwrap(), b"the only copy");
    assert!(!store.is_cold(ID));
    assert_eq!(all(&store), expected(1500));
}
