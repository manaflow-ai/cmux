//! The metadata writer's order and hand-back (`meta_save.rs`, fuzz row g finding g2), without a
//! hub: `write` copies a shared value and records the copy, as `session.json` would hold it.

use super::{MetaWriter, Wait};
use cmux_journal::{Crash, SimStorage};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How long a test waits for a writer to reach its hold before it fails instead of hanging.
const ARRIVE: Duration = Duration::from_secs(30);

/// The value the "metadata" holds now, and every copy written, in order.
#[derive(Default)]
struct Disk {
    value: Mutex<u32>,
    written: Mutex<Vec<u32>>,
}

impl Disk {
    fn set(&self, v: u32) {
        *self.value.lock().unwrap() = v;
    }
    fn write(&self) -> anyhow::Result<()> {
        let copy = *self.value.lock().unwrap();
        self.written.lock().unwrap().push(copy);
        Ok(())
    }
    fn written(&self) -> Vec<u32> {
        self.written.lock().unwrap().clone()
    }
}

fn requested(writer: &MetaWriter) -> u64 {
    writer.state.lock().unwrap().requested
}

/// A change made while a commit of an older copy runs is answered only after a commit whose copy
/// holds it, and the older copy is never written after it.
#[test]
fn a_change_that_races_a_running_commit_is_answered_after_a_commit_that_holds_it() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    // A: changes the value to 1 and commits; its first write copies, then waits for the release.
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let held = AtomicBool::new(true);
            disk.set(1);
            writer.commit(Wait::Durable, &|| {
                let copy = *disk.value.lock().unwrap();
                if held.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                disk.written.lock().unwrap().push(copy);
                Ok(())
            })
        })
    };
    copied.recv_timeout(ARRIVE).expect("the first write never reached its hold after its copy");
    // B: changes the value to 2 while A's copy (1) waits to be written, and commits.
    let b = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            disk.set(2);
            writer.commit(Wait::Durable, &|| disk.write()).unwrap();
            // What the disk held when B was answered.
            disk.written()
        })
    };
    // B took its version while A's commit runs.
    while requested(&writer) < 2 {
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    a.join().unwrap().unwrap();
    let at_answer = b.join().unwrap();
    assert_eq!(at_answer.last(), Some(&2), "B was answered before a commit held its change");
    assert_eq!(disk.written(), vec![1, 2], "the copies were not written in version order");
    let state = writer.state.lock().unwrap();
    assert_eq!((state.durable, state.writing), (2, false));
}

/// A writer that panics hands the role back: its waiters fail, and the next change becomes the
/// writer and commits.
#[test]
fn a_writer_that_panics_hands_the_role_back() {
    let writer = MetaWriter::default();
    let disk = Disk::default();
    disk.set(1);
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        writer.commit(Wait::Durable, &|| panic!("write panics"))
    }));
    assert!(panicked.is_err());
    assert!(!writer.state.lock().unwrap().writing, "the panicked writer kept the role");
    disk.set(2);
    writer.commit(Wait::Durable, &|| disk.write()).expect("the next change commits");
    assert_eq!(disk.written(), vec![2]);
}

/// A commit that fails fails the requests it covered, with its error, and leaves no writer; the
/// next change commits again.
#[test]
fn a_failed_commit_fails_its_request_and_the_next_change_commits() {
    let writer = MetaWriter::default();
    let disk = Disk::default();
    disk.set(1);
    let failed = writer.commit(Wait::Durable, &|| anyhow::bail!("disk full"));
    assert!(failed.unwrap_err().to_string().contains("disk full"));
    assert!(!writer.state.lock().unwrap().writing);
    disk.set(2);
    writer.commit(Wait::Durable, &|| disk.write()).expect("the next change commits");
    assert_eq!(disk.written(), vec![2]);
    assert!(writer.state.lock().unwrap().failed.is_none());
}

/// A change no request waits for returns while another writer works, and that writer commits it.
#[test]
fn a_change_nobody_waits_for_is_committed_by_the_writer_at_work() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let held = AtomicBool::new(true);
            disk.set(1);
            writer.commit(Wait::Durable, &|| {
                let copy = *disk.value.lock().unwrap();
                if held.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                disk.written.lock().unwrap().push(copy);
                Ok(())
            })
        })
    };
    copied.recv_timeout(ARRIVE).expect("the first write never reached its hold after its copy");
    disk.set(2);
    // Returns at once: A is the writer.
    writer.commit(Wait::No, &|| panic!("only the writer at work writes")).unwrap();
    release.send(()).unwrap();
    a.join().unwrap().unwrap();
    assert_eq!(disk.written(), vec![1, 2]);
}

/// A failed commit leaves no change behind that came while it ran: a change nobody waits for
/// returned at once, trusting the writer at work, and that writer commits it after the failure
/// (a commit of the newer version, not a retry of the failed one). Review of #29311, finding 2.
#[test]
fn a_change_that_came_during_a_failed_commit_is_still_committed() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let first = AtomicBool::new(true);
            disk.set(1);
            writer.commit(Wait::Durable, &|| {
                if first.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    anyhow::bail!("disk full");
                }
                disk.write()
            })
        })
    };
    copied.recv_timeout(ARRIVE).expect("the first write never reached its hold after its copy");
    disk.set(2);
    // Returns at once: A is the writer.
    writer.commit(Wait::No, &|| panic!("only the writer at work writes")).unwrap();
    release.send(()).unwrap();
    let a = a.join().unwrap();
    // A's own change is in the newer copy, which is durable: A may answer either way, but the
    // newer copy must be written.
    let _ = a;
    assert_eq!(disk.written(), vec![2], "the change that came during the failed commit was lost");
    let state = writer.state.lock().unwrap();
    assert_eq!((state.durable, state.writing), (2, false));
}

/// The journal store on `dir`, its event journal on `journal` (`cmux_journal::SimStorage`, so a
/// test sees what a crash keeps).
fn open_store(dir: &std::path::Path, journal: &SimStorage) -> Box<dyn crate::store::Store> {
    let config = crate::config::StoreConfig::default();
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    crate::store::open_with_journal(&config, dir, Arc::new(journal.clone()), journal_config)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

/// A hub on the stand-in agent, its store on disk in `dir` and its journal on `journal`, with
/// one chat that runs no agent.
fn hub_with_chat(
    dir: &std::path::Path,
    journal: &SimStorage,
) -> (Arc<crate::hub::Hub>, Arc<crate::hub::Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = serde_json::json!({"harnesses": {"fake": {"argv": ["python3", fake]}},
                                 "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = open_store(dir, journal);
    let hub = crate::hub::Hub::new(cfg, store);
    let id = uuid::Uuid::now_v7().to_string();
    let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "g2", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id, session.clone());
    (hub, session)
}

/// What `session.json` holds now (null when it was never written).
fn on_disk(dir: &std::path::Path, id: &str) -> serde_json::Value {
    let path = dir.join("sessions").join(id).join("session.json");
    std::fs::read_to_string(path)
        .map(|text| serde_json::from_str(&text).unwrap())
        .unwrap_or(serde_json::Value::Null)
}

/// What an OS crash leaves once a reply sent now reaches its client: the connection's gate sends
/// it only when the journal's durable LSN reaches the last acknowledged record appended by then
/// (`server/durable_gate.rs`). With the event journal a save is a `meta` record, and `session.json`
/// is written only by a checkpoint (`store/journal_store/meta.rs`).
fn crash_once_answered(hub: &crate::hub::Hub, journal: &SimStorage) -> SimStorage {
    let durability = hub.store.durability().expect("the store journals its writes");
    let acked = durability.acked.load(Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_secs(10);
    while *durability.durable.borrow() < acked {
        assert!(Instant::now() < deadline, "LSN {acked} was never durable");
        std::thread::sleep(Duration::from_millis(1));
    }
    journal.snapshot(Crash::Os)
}

/// The chat's metadata as the next open reads it after `crashed`, which replays its journal.
fn after_crash(dir: &std::path::Path, crashed: &SimStorage, id: &str) -> serde_json::Value {
    let store = open_store(dir, crashed);
    let meta = store.load(id).unwrap_or_else(|e| panic!("load {id}: {e:#}"));
    meta.map_or(serde_json::Value::Null, |meta| serde_json::to_value(meta).unwrap())
}

/// Holds the chat's next write after its copy; returns once it is held.
fn hold_next_write(
    hub: &Arc<crate::hub::Hub>,
    session: &Arc<crate::hub::Session>,
) -> (mpsc::Sender<()>, std::thread::JoinHandle<()>) {
    let (arrived_tx, arrived) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    *session.meta_writer.hold.lock().unwrap() = Some((arrived_tx, release_rx));
    let (hub, session) = (hub.clone(), session.clone());
    let writer = std::thread::spawn(move || hub.save_meta(&session));
    arrived.recv_timeout(ARRIVE).expect("the chat's next write never reached its hold");
    (release, writer)
}

/// The shutdown's flush saves each chat before the store is sealed, also while another save of
/// the chat runs: the chat's last change (here its unread mark) is on disk after the seal. Review
/// of #29311, finding 1.
#[test]
fn the_shutdown_flush_saves_a_change_made_while_another_save_runs() {
    let dir = std::env::temp_dir().join(format!("acpmux-g2-flush-{}", uuid::Uuid::now_v7()));
    let (hub, session) = hub_with_chat(&dir, &SimStorage::new(70));
    let (release, writer) = hold_next_write(&hub, &session);
    // The chat's last change, made while the older copy waits to be written.
    session.meta.lock().unwrap().unread = true;
    let shutdown = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            hub.flush();
            hub.seal();
        })
    };
    // The flush took its version; give it time to end if it does not wait.
    while session.meta_writer.state.lock().unwrap().requested < 2 {
        std::thread::yield_now();
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
    while !shutdown.is_finished() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    release.send(()).unwrap();
    writer.join().unwrap();
    shutdown.join().unwrap();
    assert_eq!(
        on_disk(&dir, &session.id)["unread"],
        true,
        "the flush let the store be sealed before the chat's last change was saved"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A move's commit answers `committed` only once `movedTo` is durable: else a crash in between
/// lets the source reopen the chat it moved. Review of #29311, finding 3.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_move_commit_answers_only_once_moved_to_is_durable() {
    let dir = std::env::temp_dir().join(format!("acpmux-g2-move-{}", uuid::Uuid::now_v7()));
    let journal = SimStorage::new(71);
    let (hub, session) = hub_with_chat(&dir, &journal);
    *session.moving.lock().unwrap() = Some("tx-g2".to_owned());
    let (release, writer) = hold_next_write(&hub, &session);
    let mut commit = {
        let (hub, session, journal) = (hub.clone(), session.clone(), journal.clone());
        tokio::spawn(async move {
            let answer = hub
                .transfer_commit_with_epoch(
                    &session,
                    "tx-g2",
                    serde_json::json!({}),
                    Some(session.ownership_epoch()),
                )
                .await;
            // What a crash right after the answer would leave.
            (answer, tokio::task::block_in_place(|| crash_once_answered(&hub, &journal)))
        })
    };
    let early = tokio::time::timeout(std::time::Duration::from_millis(500), &mut commit).await;
    release.send(()).unwrap();
    writer.join().unwrap();
    let (answer, crashed) = match early {
        Ok(done) => done.unwrap(),
        Err(_) => commit.await.unwrap(),
    };
    answer.expect("the commit");
    assert!(
        !after_crash(&dir, &crashed, &session.id)["movedTo"].is_null(),
        "transfer_commit answered committed before movedTo was durable"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A request that changed nothing, retried after a failed commit, commits again instead of
/// failing until some other change comes (a sticky barrier error). Review follow-up of #29311.
#[test]
fn a_no_op_after_a_failed_commit_commits_again() {
    let writer = MetaWriter::default();
    let disk = Disk::default();
    disk.set(1);
    assert!(writer.commit(Wait::Durable, &|| anyhow::bail!("disk full")).is_err());
    writer.barrier(&|| disk.write()).expect("the retried no-op commits again");
    assert_eq!(disk.written(), vec![1]);
}

/// A kept change (a draft) is saved as a kept copy; a barrier after it (`_acpmux/markUnread` on a
/// chat that is unread already) saves a durable copy, as the kept copy may hold a change the
/// barrier answers for. Review of #37137, finding 2.
#[test]
fn a_barrier_after_a_kept_copy_saves_a_durable_copy() {
    use crate::store::ShowAfter;
    let writer = MetaWriter::default();
    let saved = Mutex::new(Vec::new());
    let write = |keep: ShowAfter| {
        saved.lock().unwrap().push(keep);
        Ok(())
    };
    writer.commit_as(Wait::Durable, ShowAfter::Written, &write).expect("the kept change commits");
    writer.barrier_as(&write).expect("the barrier commits");
    // Nothing kept since the durable copy: the next barrier saves nothing.
    writer.barrier_as(&write).expect("the second barrier");
    assert_eq!(*saved.lock().unwrap(), vec![ShowAfter::Written, ShowAfter::Durable]);
}

/// A writer whose write panics still commits the changes nobody waits for that came during it,
/// and the panic still reaches its own caller. Review follow-up of #29311.
#[test]
fn a_writer_that_panics_still_commits_a_newer_change() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let first = AtomicBool::new(true);
            disk.set(1);
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                writer.commit(Wait::Durable, &|| {
                    if first.swap(false, Ordering::SeqCst) {
                        copied_tx.send(()).unwrap();
                        release_rx.recv().unwrap();
                        panic!("write panics");
                    }
                    disk.write()
                })
            }))
        })
    };
    copied.recv_timeout(ARRIVE).expect("the first write never reached its hold after its copy");
    disk.set(2);
    // Returns at once: A is the writer.
    writer.commit(Wait::No, &|| panic!("only the writer at work writes")).unwrap();
    release.send(()).unwrap();
    assert!(a.join().unwrap().is_err(), "the panic did not reach the writer's own caller");
    assert_eq!(disk.written(), vec![2], "the change that came during the panic was never written");
    assert!(!writer.state.lock().unwrap().writing);
}

/// The writer answers its own request after the first commit that holds it, and hands the
/// next commit to a request that waits for one, so no request waits for more than the commit
/// under way and its own. Review follow-up of #29311.
#[test]
fn the_writer_answers_its_own_request_after_its_first_commit() {
    let writer = Arc::new(MetaWriter::default());
    let log = Arc::new(Mutex::new(Vec::<(&str, u32)>::new()));
    let value = Arc::new(Mutex::new(0u32));
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let a = {
        let (writer, log, value) = (writer.clone(), log.clone(), value.clone());
        std::thread::spawn(move || {
            let first = AtomicBool::new(true);
            *value.lock().unwrap() = 1;
            writer.commit(Wait::Durable, &|| {
                let copy = *value.lock().unwrap();
                if first.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                log.lock().unwrap().push(("a", copy));
                Ok(())
            })
        })
    };
    copied.recv_timeout(ARRIVE).expect("the first write never reached its hold after its copy");
    let b = {
        let (writer, log, value) = (writer.clone(), log.clone(), value.clone());
        std::thread::spawn(move || {
            *value.lock().unwrap() = 2;
            writer.commit(Wait::Durable, &|| {
                let copy = *value.lock().unwrap();
                log.lock().unwrap().push(("b", copy));
                Ok(())
            })
        })
    };
    // B took its version and waits (both under one hold of the state lock).
    while requested(&writer) < 2 {
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    a.join().unwrap().unwrap();
    b.join().unwrap().unwrap();
    assert_eq!(
        *log.lock().unwrap(),
        vec![("a", 1), ("b", 2)],
        "the writer served B's commit before it answered its own request"
    );
}

/// `goal_set` answers only once the goal is durable: the goal outlives a restart, so an answered
/// goal that a crash right after loses breaks that. Codex review of #36413, finding F2.
#[test]
fn a_goal_set_answers_only_once_the_goal_is_durable() {
    let dir = std::env::temp_dir().join(format!("acpmux-goal-durable-{}", uuid::Uuid::now_v7()));
    let journal = SimStorage::new(72);
    let (hub, session) = hub_with_chat(&dir, &journal);
    let (release, writer) = hold_next_write(&hub, &session);
    let set = {
        let (hub, session, journal) = (hub.clone(), session.clone(), journal.clone());
        std::thread::spawn(move || {
            let request = crate::generic_goal::GoalRequest {
                objective: "Make the suite pass".into(),
                done_when: "cargo test passes".into(),
                token_budget: None,
                time_budget_minutes: None,
            };
            let answer = hub.goal_set(&session, &request);
            // What a crash right after the answer would leave.
            (answer, crash_once_answered(&hub, &journal))
        })
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
    while !set.is_finished() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    release.send(()).unwrap();
    writer.join().unwrap();
    let (answer, crashed) = set.join().unwrap();
    answer.expect("the goal");
    assert!(
        !after_crash(&dir, &crashed, &session.id)["goal"].is_null(),
        "goal_set answered before the goal was durable"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Closed chats on disk, loaded without starting the background log pass or any agents.
fn loaded_closed_chats(
    count: usize,
) -> (tempfile::TempDir, Arc<crate::hub::Hub>, Arc<std::sync::atomic::AtomicU64>) {
    use crate::config::{Config, StoreConfig};
    use crate::store::{EventRecord, LocalStore, SessionMeta, Store};

    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), StoreConfig::default().segment_bytes)
        .unwrap();
    for i in 0..count {
        let meta: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": format!("chat-{i}"),
            "name": "closed chat", "harness": "fake", "cwd": "/tmp",
            "status": "closed", "createdAt": 1, "updatedAt": 2,
            "lastSeq": 1, "eventCount": 1,
        }))
        .unwrap();
        store.save(&meta).unwrap();
        store
            .append(
                &meta.id,
                &EventRecord {
                    seq: 1,
                    at: 1,
                    dir: "mux".into(),
                    kind: "created".into(),
                    msg: serde_json::json!({}),
                    host_seq: None,
                },
            )
            .unwrap();
    }
    let saves = store.meta_saves.clone();
    let cfg: Config = serde_json::from_value(serde_json::json!({})).unwrap();
    let hub =
        crate::hub::Hub::new_deferred(cfg, Box::new(store), crate::mailbox::Mailbox::memory());
    assert_eq!(hub.session_count(), count);
    saves.store(0, Ordering::Relaxed);
    (home, hub, saves)
}

/// Loading a closed chat does not change its metadata. Only the unsaved draft is flushed.
#[test]
fn shutdown_flush_saves_only_the_changed_chat_among_300_loaded_closed_chats() {
    use crate::config::StoreConfig;
    use crate::store::{LocalStore, Store};

    let (home, hub, saves) = loaded_closed_chats(300);
    let session = hub.resolve_here("chat-17").unwrap();
    session.meta.lock().unwrap().composer_draft = Some("unsaved draft".into());
    hub.flush();
    assert_eq!(saves.load(Ordering::Relaxed), 1);
    let stored =
        LocalStore::new(home.path().join("sessions"), StoreConfig::default().segment_bytes)
            .unwrap();
    assert_eq!(
        stored.load(&session.id).unwrap().unwrap().composer_draft.as_deref(),
        Some("unsaved draft"),
    );
    saves.store(0, Ordering::Relaxed);
    hub.flush();
    assert_eq!(saves.load(Ordering::Relaxed), 0, "a successful flush left the chat dirty");
}

#[test]
fn a_failed_metadata_save_stays_dirty_until_a_successful_save() {
    let (home, hub, saves) = loaded_closed_chats(1);
    let session = hub.resolve_here("chat-0").unwrap();
    assert!(!session.meta_writer.needs_flush(&session));
    session.meta.lock().unwrap().composer_draft = Some("keep this".into());
    let path = home.path().join("sessions/chat-0/session.json");
    let backup = path.with_extension("backup");
    std::fs::rename(&path, &backup).unwrap();
    std::fs::create_dir(&path).unwrap();
    let saved = hub.write_meta(&session);
    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(&backup, &path).unwrap();
    assert!(saved.is_err(), "a file could not replace a directory");
    assert!(session.meta_writer.needs_flush(&session));
    assert!(
        session.meta_writer.state.lock().unwrap().saved.as_ref().unwrap().composer_draft.is_none()
    );
    hub.flush();
    assert_eq!(saves.load(Ordering::Relaxed), 2, "one failed attempt and one retry");
    assert!(!session.meta_writer.needs_flush(&session));
    assert_eq!(on_disk(home.path(), &session.id)["composerDraft"], "keep this");
}

/// Even when memory returns to its saved value, the writer's held copy can be different.
#[test]
fn shutdown_flush_keeps_a_change_taken_back_while_an_older_save_runs() {
    let home = tempfile::tempdir().unwrap();
    let (hub, session) = hub_with_chat(home.path(), &SimStorage::new(83));
    hub.write_meta(&session).unwrap();
    session.meta.lock().unwrap().unread = true;
    let (release, writer) = hold_next_write(&hub, &session);
    session.meta.lock().unwrap().unread = false;
    assert!(session.meta_writer.needs_flush(&session));
    let shutdown = {
        let hub = hub.clone();
        std::thread::spawn(move || hub.flush())
    };
    while requested(&session.meta_writer) < 3 {
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    writer.join().unwrap();
    shutdown.join().unwrap();
    assert_eq!(on_disk(home.path(), &session.id)["unread"], false);
    assert!(!session.meta_writer.needs_flush(&session));
}

#[test]
fn startup_repairs_are_dirty_even_before_any_commit_is_requested() {
    use crate::store::{MemoryStore, SessionMeta};

    let cfg = serde_json::from_value(serde_json::json!({})).unwrap();
    let hub = crate::hub::Hub::new(cfg, Box::new(MemoryStore::default()));
    for (id, status, saved) in [("normalized", "running", true), ("failed-repair", "closed", false)]
    {
        let meta: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": "chat",
            "harness": "fake", "cwd": "/tmp", "status": status,
            "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap();
        hub.install_stored_session(meta, true, false, saved);
        let session = hub.resolve_here(id).unwrap();
        assert!(session.meta_writer.needs_flush(&session));
        hub.flush();
        assert!(!session.meta_writer.needs_flush(&session));
    }
}

#[test]
fn shutdown_flush_syncs_a_successful_kept_save_without_another_metadata_commit() {
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(84);
    let (hub, session) = hub_with_chat(home.path(), &journal);
    hub.write_meta(&session).unwrap();
    session.meta.lock().unwrap().composer_draft = Some("kept draft".into());
    hub.save_meta_kept(&session).unwrap();
    let before = {
        let state = session.meta_writer.state.lock().unwrap();
        assert!(!state.writing);
        assert_eq!(state.requested, state.durable);
        assert!(state.kept > state.synced);
        state.requested
    };
    hub.flush();
    assert_eq!(requested(&session.meta_writer), before, "an unchanged kept copy was saved again");
    assert_eq!(on_disk(home.path(), &session.id)["composerDraft"], "kept draft");
    let crashed = journal.snapshot(Crash::Os);
    assert_eq!(after_crash(home.path(), &crashed, &session.id)["composerDraft"], "kept draft");
}
