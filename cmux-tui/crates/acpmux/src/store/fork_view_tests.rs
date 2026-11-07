use super::*;

fn meta(id: &str, history_from: Option<HistoryRef>) -> SessionMeta {
    let mut meta: SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "fake", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    meta.history_from = history_from;
    meta
}

fn record(seq: u64, kind: &str) -> EventRecord {
    EventRecord {
        seq,
        at: seq,
        dir: if kind == "turn_result" { "mux" } else { "in" }.into(),
        kind: kind.into(),
        msg: serde_json::json!({"n": seq}),
        host_seq: None,
    }
}

/// A chat of `n` records (every third a status record no fork shows), and a fork of it through
/// `through` holding `own` records of its own past that.
fn forked(store: Box<dyn Store>, n: u64, through: u64, own: u64) -> ForkView {
    let view = ForkView::new(store);
    view.save(&meta("chat", None)).unwrap();
    for seq in 1..=n {
        let kind = if seq % 3 == 0 { "status" } else { "agent_message_chunk" };
        view.append("chat", &record(seq, kind)).unwrap();
    }
    let reference = HistoryRef { session: "chat".into(), through_seq: through };
    view.save(&meta("fork", Some(reference))).unwrap();
    for seq in through + 1..=through + own {
        view.append("fork", &record(seq, "user_message")).unwrap();
    }
    view
}

fn seqs(records: &[EventRecord]) -> Vec<u64> {
    records.iter().map(|r| r.seq).collect()
}

/// What the fork shows: the chat's history kinds through the seq, then its own records.
fn expected(through: u64, own: u64) -> Vec<u64> {
    (1..=through).filter(|seq| seq % 3 != 0).chain(through + 1..=through + own).collect()
}

#[test]
fn a_fork_shows_its_chats_history_then_its_own() {
    let view = forked(Box::new(MemoryStore::default()), 30, 20, 4);
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
    // A page from the middle, and one that ends inside the history.
    assert_eq!(seqs(&view.events("fork", 10, 3).unwrap()), vec![11, 13, 14]);
    assert_eq!(seqs(&view.events("fork", 19, 10).unwrap()), vec![20, 21, 22, 23, 24]);
    let mut back = Vec::new();
    view.scan_back("fork", 0, u64::MAX, &|_, _| false, &mut |r| {
        back.push(r.seq);
        back.len() < 6
    })
    .unwrap();
    assert_eq!(back, vec![24, 23, 22, 21, 20, 19]);
    assert_eq!(view.tail_after("fork", 0).unwrap(), (expected(20, 4).len() as u64, 24));
    assert_eq!(view.tail_after("fork", 20).unwrap(), (4, 24));
    // The chat's records past the seq are never the fork's.
    let mut kinds = Vec::new();
    view.scan_kinds("fork", &["agent_message_chunk", "user_message"], &mut |r| {
        kinds.push(r.seq);
        true
    })
    .unwrap();
    assert_eq!(kinds, expected(20, 4));
}

#[test]
fn the_chat_going_writes_the_history_into_the_fork_first() {
    for store in [
        Box::new(MemoryStore::default()) as Box<dyn Store>,
        Box::new(LocalStore::new(tempfile::tempdir().unwrap().keep(), 1 << 20).unwrap()),
    ] {
        let view = forked(store, 30, 20, 4);
        view.delete("chat").unwrap();
        assert!(view.load("fork").unwrap().unwrap().history_from.is_none());
        assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
        // It goes on after: its next record follows its own.
        view.append("fork", &record(25, "user_message")).unwrap();
        assert_eq!(view.events("fork", 24, 10).unwrap().len(), 1);
    }
}

/// A save from a meta the hub kept from before a materialize never puts the reference back.
#[test]
fn a_dropped_reference_stays_dropped() {
    let view = forked(Box::new(MemoryStore::default()), 30, 20, 4);
    let stale = view.load("fork").unwrap().unwrap();
    view.materialize("fork").unwrap();
    view.save(&stale).unwrap();
    let saved = view.load("fork").unwrap().unwrap();
    assert!(saved.history_from.is_none());
    // Its log skips the chat's seqs through 20, and says so (Edit and resend's proof reads it).
    assert_eq!(saved.history_kept_through, Some(20));
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
}

/// A store whose save of a meta naming a reference takes a while, as a slow disk's may.
struct SlowSave(LocalStore);

impl Store for SlowSave {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        if meta.history_from.is_some() {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.0.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0.delete(id)
    }
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        self.0.history_writer(id)
    }
}

/// A save of the fork's meta that began before the history was written in, and ends after: the
/// reference stays dropped on disk (review of #37020: the save wrote it back, and after a
/// restart the fork named its deleted chat and showed none of its history).
#[test]
fn a_save_racing_the_history_write_does_not_bring_the_reference_back() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = std::sync::Arc::new(forked(
        Box::new(SlowSave(LocalStore::new(dir.clone(), 1 << 20).unwrap())),
        30,
        20,
        4,
    ));
    let stale = view.load("fork").unwrap().unwrap();
    let saving = {
        let view = view.clone();
        std::thread::spawn(move || view.save(&stale).unwrap())
    };
    std::thread::sleep(std::time::Duration::from_millis(20));
    view.delete("chat").unwrap();
    saving.join().unwrap();
    // As after a restart: the meta on disk, read by a fresh view.
    let fresh = ForkView::new(Box::new(LocalStore::new(dir, 1 << 20).unwrap()));
    let on_disk = fresh.load("fork").unwrap().unwrap();
    assert!(on_disk.history_from.is_none(), "the fork names its deleted chat again");
    assert_eq!(on_disk.history_kept_through, Some(20));
    assert_eq!(seqs(&fresh.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
}

/// A fork of a fork reads through the first fork's own view.
#[test]
fn a_fork_of_a_fork_shows_both_histories() {
    let view = forked(Box::new(MemoryStore::default()), 30, 20, 4);
    let reference = HistoryRef { session: "fork".into(), through_seq: 24 };
    view.save(&meta("grandchild", Some(reference))).unwrap();
    view.append("grandchild", &record(25, "user_message")).unwrap();
    let mut want = expected(20, 4);
    want.push(25);
    assert_eq!(seqs(&view.events("grandchild", 0, usize::MAX).unwrap()), want);
}

/// Retention trims a chat's long tool output in place: a fork that shows it gets the history
/// first, whole (review of #37020: the fork lost what a copy had kept).
#[test]
fn compacting_the_chat_writes_the_history_into_the_fork_first() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = ForkView::new(Box::new(LocalStore::new(dir, 64 * 1024).unwrap()));
    let mut chat = meta("chat", None);
    chat.status = SessionStatus::Closed;
    view.save(&chat).unwrap();
    let output = "line of build output\n".repeat(600);
    let update = serde_json::json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": output}}]}}});
    view.append("chat", &record(1, "user_message")).unwrap();
    let long = EventRecord { msg: update, ..record(2, "tool_call_update") };
    view.append("chat", &long).unwrap();
    view.append("chat", &record(3, "turn_result")).unwrap();
    let reference = HistoryRef { session: "chat".into(), through_seq: 3 };
    view.save(&meta("fork", Some(reference))).unwrap();
    let shown = |view: &ForkView| -> usize {
        view.events("fork", 0, usize::MAX).unwrap().iter().map(|r| r.msg.to_string().len()).sum()
    };
    let before = shown(&view);

    let staged =
        view.stage_compaction("chat", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(staged.stats.trimmed > 0, "the chat's long output is trimmed: {:?}", staged.stats);
    assert!(view.commit_compaction("chat", staged).unwrap());
    assert!(view.load("fork").unwrap().unwrap().history_from.is_none());
    assert_eq!(shown(&view), before, "the fork shows its history as it was");
}

/// A fork of a fork read by a view that has not listed the store yet (a daemon opening one chat
/// by id at startup) still shows both histories: each meta is read before its reference is used
/// (review of #37020: the first fork's reference was unknown, so its chat's history was left out).
#[test]
fn a_fork_of_a_fork_read_before_any_list_shows_both_histories() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = forked(Box::new(LocalStore::new(dir.clone(), 1 << 20).unwrap()), 30, 20, 4);
    let reference = HistoryRef { session: "fork".into(), through_seq: 24 };
    view.save(&meta("grandchild", Some(reference))).unwrap();
    view.append("grandchild", &record(25, "user_message")).unwrap();
    drop(view);

    let fresh = ForkView::new(Box::new(LocalStore::new(dir, 1 << 20).unwrap()));
    let mut want = expected(20, 4);
    want.push(25);
    assert_eq!(seqs(&fresh.events("grandchild", 0, usize::MAX).unwrap()), want);
}

/// Two writes of one fork's history at once (the chat deleted while its fork's files are read)
/// write it once (review of #37020: each wrote it, and the fork showed it twice).
#[test]
fn a_forks_history_is_written_once_however_many_ask() {
    let store = LocalStore::new(tempfile::tempdir().unwrap().keep(), 1 << 20).unwrap();
    let view = std::sync::Arc::new(forked(Box::new(store), 6_000, 5_000, 4));
    let writers: Vec<_> = (0..4)
        .map(|_| {
            let view = view.clone();
            std::thread::spawn(move || view.materialize("fork").unwrap())
        })
        .collect();
    writers.into_iter().for_each(|w| w.join().unwrap());
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(5_000, 4));
}

/// A meta read before the history was written in and noted after it never brings the reference
/// back (review of #37020: the fork then hid the history it holds).
#[test]
fn a_stale_meta_noted_after_the_write_names_no_reference() {
    let view = forked(Box::new(MemoryStore::default()), 30, 20, 4);
    let stale = view.inner.load("fork").unwrap().unwrap();
    view.materialize("fork").unwrap();
    view.note(&stale);
    assert!(view.reference("fork").is_none());
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
}

/// A fork named before its meta is saved: deleting the chat then writes the history into it first,
/// and the fork's meta, saved later naming the chat, names it no more; a chat already gone refuses
/// the fork (review of #37020: a delete or compaction between the fork's seq and its meta passed
/// it by, and the fork lost its history).
#[test]
fn a_fork_reserved_before_its_meta_keeps_the_history_of_a_chat_deleted_meanwhile() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = forked(Box::new(LocalStore::new(dir, 1 << 20).unwrap()), 30, 20, 0);
    let reference = HistoryRef { session: "chat".into(), through_seq: 20 };
    view.reserve_reference("late", &reference).unwrap();
    // Its meta is not saved yet: the chat stays until it is.
    assert!(view.delete("chat").is_err(), "the chat went before its fork could hold the history");
    assert!(view.load("chat").unwrap().is_some());
    view.save(&meta("late", Some(reference.clone()))).unwrap();
    view.delete("chat").unwrap();
    let saved = view.load("late").unwrap().unwrap();
    assert!(saved.history_from.is_none(), "the fork names its deleted chat");
    assert_eq!(seqs(&view.events("late", 0, usize::MAX).unwrap()), expected(20, 0));
    assert!(view.reserve_reference("later", &reference).is_err(), "the chat is gone");
}

/// A store whose saves of a meta that names no reference fail while `failing` is set.
struct FailingSave(LocalStore, std::sync::Arc<std::sync::atomic::AtomicBool>);

impl Store for FailingSave {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        if meta.history_from.is_none() && self.1.load(std::sync::atomic::Ordering::SeqCst) {
            anyhow::bail!("disk full");
        }
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.0.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0.delete(id)
    }
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        self.0.history_writer(id)
    }
}

/// The history written in, then its meta's save failing: the reference stands, the chat is kept,
/// and the next try finishes the job (review of #37020: the reference was dropped here but not on
/// disk, so after a restart the written history was never read).
#[test]
fn a_failed_meta_save_leaves_the_reference_to_try_again() {
    let dir = tempfile::tempdir().unwrap().keep();
    let failing = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let store = FailingSave(LocalStore::new(dir, 1 << 20).unwrap(), failing.clone());
    let view = forked(Box::new(store), 30, 20, 4);
    let flag = |on: bool| failing.store(on, std::sync::atomic::Ordering::SeqCst);
    flag(true);
    assert!(view.delete("chat").is_err());
    assert!(view.reference("fork").is_some(), "the reference was dropped");
    assert!(view.load("chat").unwrap().is_some(), "the chat went without its fork's history");
    flag(false);
    view.delete("chat").unwrap();
    assert!(view.load("fork").unwrap().unwrap().history_from.is_none());
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
}

/// A fork whose history was written in before it logged a record of its own: its records go to
/// segment `000001`, and writing the history again (a retry) keeps them (review of #37020: they
/// went into `000000` and the rename replaced them).
#[test]
fn a_forks_own_records_never_go_into_its_history_segment() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = forked(Box::new(LocalStore::new(dir.clone(), 1 << 20).unwrap()), 30, 20, 0);
    let reference = HistoryRef { session: "chat".into(), through_seq: 20 };
    view.materialize("fork").unwrap();
    view.append("fork", &record(21, "user_message")).unwrap();
    view.flush_session("fork").unwrap();
    let mut on_disk: Vec<_> = std::fs::read_dir(dir.join("fork").join("events"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.ends_with(".ndjson"))
        .collect();
    on_disk.sort();
    assert_eq!(on_disk, ["000000.ndjson", "000001.ndjson"]);
    // Written again (as after a meta save that failed): the fork's own record stays.
    view.refs.write().unwrap().dropped.remove("fork");
    view.refs.write().unwrap().by_fork.insert("fork".into(), reference);
    view.materialize("fork").unwrap();
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 1));
}

/// A store whose first scan of the chat stalls before it reads, as a slow disk's may.
struct SlowScan(LocalStore, std::sync::atomic::AtomicBool);

impl Store for SlowScan {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.0.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        if id == "chat" && !self.1.swap(true, std::sync::atomic::Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        self.0.scan(id, after, visit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0.delete(id)
    }
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        self.0.history_writer(id)
    }
}

/// A read of a fork that the chat's delete lands in the middle of still reads the whole history
/// (review of #37020: the read took the reference, the delete wrote the history in and removed
/// the chat, and the read went on in a chat that was gone, so an export held no history).
#[test]
fn a_read_that_a_delete_lands_in_still_reads_the_history() {
    let dir = tempfile::tempdir().unwrap().keep();
    let view = std::sync::Arc::new(forked(
        Box::new(SlowScan(LocalStore::new(dir, 1 << 20).unwrap(), Default::default())),
        30,
        20,
        4,
    ));
    view.reference("fork").expect("the fork names its chat");
    let reading = {
        let view = view.clone();
        std::thread::spawn(move || {
            let mut seen = Vec::new();
            view.scan("fork", 0, &mut |r| {
                seen.push(r.seq);
                true
            })
            .unwrap();
            seen
        })
    };
    std::thread::sleep(std::time::Duration::from_millis(30));
    view.delete("chat").unwrap();
    assert_eq!(reading.join().unwrap(), expected(20, 4), "the read lost the history");
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
}

/// The disk store runs through the event journal since #37118: a fork there is by reference, its
/// history is written in when its chat goes, and a kill -9 and an open after keep every line of
/// it once, the history's and its own (review of #37020, F2: the journal store wrote no history,
/// so every fork copied its chat again).
#[test]
fn a_fork_on_the_journal_store_keeps_its_history_through_a_kill() {
    use cmux_journal::{Crash, SimStorage};
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(64);
    let config = cmux_journal::Config {
        retry_min: std::time::Duration::from_millis(1),
        retry_max: std::time::Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let open = |storage: SimStorage| {
        crate::store::open_with_journal(
            &crate::config::StoreConfig::default(),
            home.path(),
            std::sync::Arc::new(storage),
            config.clone(),
        )
        .unwrap()
    };
    let view = forked(open(journal.clone()), 30, 20, 2);
    assert!(view.writes_history(), "the journal store writes no history: forks copy theirs");
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 2));
    view.delete("chat").unwrap();
    view.append("fork", &record(23, "user_message")).unwrap();
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 3));
    assert!(view.wait_durable(std::time::Duration::from_secs(10)).unwrap(), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(view);
    let view = ForkView::new(open(killed));
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 3), "each once");
    assert!(view.load("fork").unwrap().unwrap().history_from.is_none());
}

/// The memory store keeps a fork's history only once the fork is stored: a chat deleted between
/// the fork's reservation and its first save waits for that save (review of #37020, F1).
#[test]
fn a_chat_deleted_before_its_reserved_fork_is_saved_waits_for_the_save_in_memory() {
    let view = forked(Box::new(MemoryStore::default()), 30, 20, 0);
    let reference = HistoryRef { session: "chat".into(), through_seq: 20 };
    view.reserve_reference("late", &reference).unwrap();
    assert!(view.delete("chat").is_err(), "the chat went before its fork could hold the history");
    view.save(&meta("late", Some(reference))).unwrap();
    view.delete("chat").unwrap();
    assert_eq!(seqs(&view.events("late", 0, usize::MAX).unwrap()), expected(20, 0));
    assert!(view.load("late").unwrap().unwrap().history_from.is_none());
}

/// On the journal store no fork folder is made before the fork's meta: its meta's save makes
/// the folder and records it, so a kill keeps the fork and its history (review of #37020, F2).
#[test]
fn a_reserved_fork_on_the_journal_store_gets_no_folder_before_its_meta() {
    use cmux_journal::{Crash, SimStorage};
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(64);
    let config = cmux_journal::Config {
        retry_min: std::time::Duration::from_millis(1),
        retry_max: std::time::Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let open = |storage: SimStorage| {
        crate::store::open_with_journal(
            &crate::config::StoreConfig::default(),
            home.path(),
            std::sync::Arc::new(storage),
            config.clone(),
        )
        .unwrap()
    };
    let view = forked(open(journal.clone()), 30, 20, 0);
    let reference = HistoryRef { session: "chat".into(), through_seq: 20 };
    view.reserve_reference("late", &reference).unwrap();
    assert!(view.delete("chat").is_err(), "the chat went before its fork could hold the history");
    let folder = view.session_path("late").unwrap();
    assert!(!folder.exists(), "the fork's folder was made before its meta");
    view.save(&meta("late", Some(reference))).unwrap();
    view.delete("chat").unwrap();
    view.append("late", &record(21, "user_message")).unwrap();
    assert!(view.wait_durable(std::time::Duration::from_secs(10)).unwrap(), "never durable");
    let killed = journal.restart(Crash::Process);
    drop(view);
    let view = ForkView::new(open(killed));
    assert_eq!(seqs(&view.events("late", 0, usize::MAX).unwrap()), expected(20, 1));
    assert!(view.load("late").unwrap().unwrap().history_from.is_none());
}
