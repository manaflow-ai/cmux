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
    assert!(view.load("fork").unwrap().unwrap().history_from.is_none());
    assert_eq!(seqs(&view.events("fork", 0, usize::MAX).unwrap()), expected(20, 4));
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
