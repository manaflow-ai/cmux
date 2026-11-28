use super::*;

fn record(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn suffix(events: &[(&str, Value)]) -> Vec<(&'static str, Value)> {
    let mut state = Pending::default();
    for (i, (kind, msg)) in events.iter().enumerate() {
        state.read(&record(i as u64 + 1, kind, msg.clone())).unwrap();
    }
    state.suffix()
}

#[test]
fn dequeued_without_start_is_still_pending() {
    let ids = json!({"promptId":"p","turnId":"t"});
    let got = suffix(&[("queued", ids.clone()), ("dequeued", ids)]);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "queue_removed");
    assert_eq!(got[0].1["promptId"], "p");
}

#[test]
fn direct_unstarted_and_interrupted_turn_have_different_completions() {
    let ids = json!({"promptId":"p","turnId":"t"});
    assert_eq!(suffix(&[("user_message", ids.clone())])[0].0, "queue_removed");
    let got = suffix(&[("user_message", ids.clone()), ("turn_started", ids)]);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "turn_result");
    assert_eq!(got[0].1["turnSeq"], 2);
}

#[test]
fn completed_history_needs_no_suffix() {
    let ids = json!({"promptId":"p","turnId":"t"});
    assert!(
        suffix(&[
            ("queued", ids.clone()),
            ("dequeued", ids.clone()),
            ("turn_started", ids.clone()),
            ("turn_end", ids.clone()),
            ("turn_result", ids)
        ])
        .is_empty()
    );
}

#[test]
fn only_unhandled_inbox_items_are_removed() {
    let got = suffix(&[
        ("inbox", json!({"promptId":"a"})),
        ("inbox", json!({"promptId":"b"})),
        ("inbox_noticed", json!({"promptIds":["a"],"noticePromptId":"notice"})),
    ]);
    assert_eq!(got, vec![("inbox_removed", json!({"promptId":"b","reason":"fixture_complete"}))]);
    assert_eq!(
        suffix(&[("inbox", json!({"promptId":"p"})), ("inbox_read", json!({"promptIds":["p"]}))])
            [0]
        .0,
        "inbox_removed"
    );
}

#[test]
fn one_removal_closes_a_turn_with_multiple_queued_prompts_and_a_lost_dequeue() {
    let mut state = Pending::default();
    for (seq, p) in [(1, "peer-a"), (2, "peer-b")] {
        state.read(&record(seq, "queued", json!({"promptId":p,"turnId":"t"}))).unwrap();
    }
    state.read(&record(3, "dequeued", json!({"promptId":"direct","turnId":"t"}))).unwrap();
    let got = state.suffix();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].1["promptId"], "direct");
    state.read(&record(4, got[0].0, got[0].1.clone())).unwrap();
    assert!(state.suffix().is_empty());
}

#[test]
fn unsupported_digest_is_rejected_before_writing() {
    let mut state = Pending::default();
    assert!(
        state
            .read(&record(1, "dequeued", json!({"digestPromptId":"d","promptId":"p","turnId":"t"})))
            .is_err()
    );
}

#[test]
fn settlement_preserves_prefix_updates_metadata_and_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let store = LocalStore::new(home.join("sessions"), 8 << 20).unwrap();
    let id = "seed";
    let e = record(1, "user_message", json!({"promptId":"p","turnId":"t"}));
    store.append(id, &e).unwrap();
    let meta = acpmux::god_fixture::session_meta(id, "coord-sim-test", "/tmp", "agent", 1, 1);
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    store.flush().unwrap();
    drop(store);
    let events = home.join("sessions").join(id).join("events");
    let path = std::fs::read_dir(&events).unwrap().next().unwrap().unwrap().path();
    let before = std::fs::read(&path).unwrap();
    let got = settle(home, id).unwrap();
    assert_eq!(got.appended, 1);
    assert!(std::fs::read(&path).unwrap().starts_with(&before));
    assert_eq!(got.bytes, std::fs::read(&path).unwrap().len() as u64);
    assert_eq!((got.records, got.last_seq, got.turns), (2, 2, 1));
    let store = LocalStore::new(home.join("sessions"), 8 << 20).unwrap();
    let meta = store.load(id).unwrap().unwrap();
    assert_eq!((meta.event_count, meta.last_seq, meta.transcript_seq), (2, 2, got.transcript_seq));
    assert!(!home.join("sessions").join(id).join("events-index").exists());
    assert_eq!(settle(home, id).unwrap().appended, 0);
}

#[test]
fn repeated_turns_follow_the_completions_and_settle_where_they_open() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let store = LocalStore::new(home.join("sessions"), 8 << 20).unwrap();
    let id = "seed";
    let ids = |p: &str, t: &str| json!({"promptId": p, "turnId": t});
    let events = [
        ("user_message", ids("p1", "t1")),
        ("turn_started", ids("p1", "t1")),
        ("turn_result", json!({"promptId": "p1"})),
        ("user_message", ids("p2", "t2")),
        ("turn_started", ids("p2", "t2")),
        ("queued", ids("peer", "t9")),
        ("turn_result", json!({"promptId": "p2"})),
        ("user_message", ids("p3", "t3")),
        ("turn_started", ids("p3", "t3")),
    ];
    for (i, (kind, msg)) in events.iter().enumerate() {
        store.append(id, &record(i as u64 + 1, kind, msg.clone())).unwrap();
    }
    let meta = acpmux::god_fixture::session_meta(id, "coord-sim-test", "/tmp", "agent", 9, 9);
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    store.flush().unwrap();
    drop(store);
    let settled = settle(home, id).unwrap();
    // The open turn t3 and the queued peer prompt.
    assert_eq!(settled.appended, 2);
    let history_end = settled.last_seq - settled.appended;
    // A target past the history repeats only its last whole turn (t2, seqs 4..=7).
    let tail = append_settled_turns(home, id, history_end, 1 << 30).unwrap();
    assert_eq!((tail.from, tail.through, tail.records, tail.turns), (3, 7, 4, 1));
    let store = LocalStore::new(home.join("sessions"), 8 << 20).unwrap();
    let mut log = vec![];
    store
        .scan_strict(id, 0, &mut |e| {
            log.push(e);
            true
        })
        .unwrap();
    let kinds: Vec<_> =
        log.iter().skip(settled.last_seq as usize).map(|e| e.kind.as_str()).collect();
    // The copy's queued prompt is removed right after it, before the copy's turn ends.
    assert_eq!(kinds, ["user_message", "turn_started", "queued", "queue_removed", "turn_result"]);
    assert_eq!(tail.completion_seqs, vec![settled.last_seq + 4]);
    assert_eq!(log.last().unwrap().seq, tail.last_seq);
    assert_eq!(log[settled.last_seq as usize].msg["promptId"], "p2~tail");
    let mut state = Pending::default();
    for e in &log {
        state.read(e).unwrap();
    }
    assert!(state.suffix().is_empty());
    assert_eq!(store.load(id).unwrap().unwrap().last_seq, tail.last_seq);
}
