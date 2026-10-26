//! The conversation and Chief store locks as checked scopes: taking one for
//! SQLite on a thread that disallows blocking records one `sqlite` site at the
//! caller, the upload-only conversation lock records none, and a wait of 2 ms
//! or more names the holder thread (`cmux_threads::lock_waits`).

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_threads::blocking::{BlockingKind, BlockingMode, disallow_blocking, set_mode, snapshot};

use crate::chief_registry::ChiefHost;
use crate::conversation_store::ConversationHost;

fn sqlite_count_at(line: u32) -> u64 {
    snapshot()
        .site(file!(), line)
        .filter(|site| site.kinds.contains(BlockingKind::Sqlite))
        .map_or(0, |site| site.count)
}

#[test]
fn disallowed_store_locks_record_one_sqlite_site_at_their_caller() {
    set_mode(BlockingMode::Record);
    let (chief, conversation, upload) = std::thread::Builder::new()
        .name("mux-conn-store-test".into())
        .spawn(|| {
            disallow_blocking();
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
    assert_eq!(sqlite_count_at(chief), 1);
    assert_eq!(sqlite_count_at(conversation), 1);
    assert_eq!(snapshot().site(file!(), upload), None, "no SQL, no check");
}

#[test]
fn a_long_chief_store_wait_names_the_holder() {
    const WAITER: &str = "chief-store-waiter-test";
    let chiefs = Arc::new(ChiefHost::default());
    let (held_tx, held_rx) = channel();
    let holder = {
        let chiefs = Arc::clone(&chiefs);
        std::thread::Builder::new()
            .name("chief-store-holder-test".into())
            .spawn(move || {
                let store = chiefs.lock_store();
                held_tx.send(()).expect("held");
                std::thread::sleep(Duration::from_millis(20));
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
    assert_eq!((wait.file, wait.line), (file!(), line));
}
