//! The conversation and Chief store locks as checked scopes: taking one for
//! SQLite on a thread that disallows blocking records one `sqlite` note at
//! the caller, the upload-only conversation lock records none, and a wait of
//! 2 ms or more names the holder thread (`cmux_threads::lock_waits`).
//!
//! The `sqlite` notes are counted in a recording request scope of the test
//! thread's own, so no other thread can add to them.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_threads::blocking::{BlockingKind, BlockingMode, disallow_blocking, set_mode, snapshot};

use crate::chief_registry::ChiefHost;
use crate::conversation_store::ConversationHost;
use crate::request_path::{
    BlockingKind as NoteKind, RequestPathMode, RequestPathScope, RequestPathStats,
};

/// The `sqlite` notes the scope recorded at `line` of this file.
fn sqlite_notes_at(stats: &RequestPathStats, line: u32) -> usize {
    stats
        .sites()
        .iter()
        .filter(|noted| {
            noted.kind == NoteKind::Sqlite
                && noted.site.file() == file!()
                && noted.site.line() == line
        })
        .count()
}

#[test]
fn disallowed_store_locks_record_one_sqlite_site_at_their_caller() {
    set_mode(BlockingMode::Record);
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let scope_stats = Arc::clone(&stats);
    let (chief, conversation, upload) = std::thread::Builder::new()
        .name("mux-conn-store-test".into())
        .spawn(move || {
            disallow_blocking();
            let _scope = RequestPathScope::enter(&scope_stats);
            let chiefs = ChiefHost::default();
            let conversations = ConversationHost::default();
            let chief = line!() + 1;
            drop(chiefs.lock_store());
            let conversation = line!() + 1;
            drop(conversations.lock_store_for_sqlite());
            let upload = line!() + 1;
            drop(conversations.lock_store());
            (chief, conversation, upload)
        })
        .expect("spawn")
        .join()
        .expect("test thread");
    assert_eq!(sqlite_notes_at(&stats, chief), 1);
    assert_eq!(sqlite_notes_at(&stats, conversation), 1);
    let snapshot = snapshot();
    for line in [chief, conversation] {
        let site = snapshot.site(file!(), line).expect("violation recorded");
        assert!(site.kinds.contains(BlockingKind::Sqlite), "{site:?}");
    }
    assert_eq!(sqlite_notes_at(&stats, upload), 0);
    assert_eq!(snapshot.site(file!(), upload), None, "no SQL, no check");
}

#[test]
fn a_long_chief_store_wait_names_the_holder() {
    const WAITER: &str = "chief-store-waiter-test";
    const HOLD: Duration = Duration::from_millis(20);
    cmux_threads::set_holder_tracking(true);
    let chiefs = Arc::new(ChiefHost::default());
    let (held_tx, held_rx) = channel();
    let holder = {
        let chiefs = Arc::clone(&chiefs);
        std::thread::Builder::new()
            .name("chief-store-holder-test".into())
            .spawn(move || {
                let store = chiefs.lock_store();
                held_tx.send(()).expect("held");
                // Until the waiter's try failed, then long enough to record.
                while chiefs.store_waiting() == 0 {
                    std::thread::yield_now();
                }
                std::thread::sleep(HOLD);
                drop(store);
            })
            .expect("spawn holder")
    };
    held_rx.recv().expect("the holder took the store");
    let line = std::thread::Builder::new()
        .name(WAITER.into())
        .spawn(move || {
            let line = line!() + 1;
            drop(chiefs.lock_store());
            line
        })
        .expect("spawn waiter")
        .join()
        .expect("waiter");
    holder.join().expect("holder");
    let waits = cmux_threads::lock_waits();
    let wait = waits.recent.iter().find(|wait| wait.waiter == WAITER).expect("recorded");
    assert_eq!(wait.lock, "chief.store");
    assert_eq!(wait.holder.as_deref(), Some("chief-store-holder-test"));
    assert!(wait.waited >= HOLD, "{wait:?}");
    assert_eq!((wait.file, wait.line), (file!(), line));
}
