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
    let view = std::sync::Arc::new(forked(Box::new(MemoryStore::default()), 30_000, 20_000, 4));
    let writers: Vec<_> = (0..4)
        .map(|_| {
            let view = view.clone();
            std::thread::spawn(move || view.materialize("fork").unwrap())
        })
        .collect();
    writers.into_iter().for_each(|w| w.join().unwrap());
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20_000, 4));
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
