//! A steer that lands as its turn ends (`hub/steer_end.rs`): the hub logs it as a steer
//! `user_message`, the agent answers `STEER_NO_TURN`, and the hub runs it as the next
//! prompt, logging a second `user_message` with the same `promptId` and no `steer`.
//! The transcript shows that prompt once, live, replayed, and across forward pages.

use super::*;
use serde_json::json;

const SID: &str = "s1";

/// The records the hub logs for prompt "go" (turn t1), a steer "also this" (p2) that
/// lands as t1 ends, and its run as the next prompt (turn t2), from `seq` 10.
fn steer_relog_records() -> Vec<Value> {
    let mux = |seq: u64, kind: &str, msg: Value| json!({"seq": seq, "at": 1_000 + seq, "dir": "mux", "kind": kind, "msg": msg});
    let chunk = |seq: u64, text: &str| {
        json!({"seq": seq, "at": 1_000 + seq, "dir": "in", "kind": "session/update", "msg": {
            "method": "session/update",
            "params": {"sessionId": SID, "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text},
            }},
        }})
    };
    vec![
        mux(
            10,
            "user_message",
            json!({"text": "go", "client": "tui", "promptId": "p1", "turnId": "t1"}),
        ),
        mux(11, "turn_started", json!({"prompt": "go", "promptId": "p1", "turnId": "t1"})),
        chunk(12, "working on it"),
        mux(
            13,
            "user_message",
            json!({"text": "also this", "steer": true, "client": "tui", "promptId": "p2", "turnId": "t1"}),
        ),
        mux(14, "turn_end", json!({"stopReason": "end_turn", "turnId": "t1", "promptId": "p1"})),
        mux(
            15,
            "user_message",
            json!({"text": "also this", "client": "tui", "promptId": "p2", "turnId": "t2"}),
        ),
        mux(16, "turn_started", json!({"prompt": "also this", "promptId": "p2", "turnId": "t2"})),
        chunk(17, "done"),
    ]
}

/// (text, steer, queued) of every user row, in order.
fn user_rows(t: &Transcript) -> Vec<(String, bool, bool)> {
    t.items
        .iter()
        .filter_map(|i| match i {
            Item::User { text, steer, queued } => Some((text.clone(), *steer, *queued)),
            _ => None,
        })
        .collect()
}

fn index_of_user(t: &Transcript, text: &str) -> usize {
    t.items
        .iter()
        .position(|i| matches!(i, Item::User { text: x, .. } if x == text))
        .unwrap_or_else(|| panic!("no user row {text:?}: {:?}", t.items))
}

/// The prompt shows once, as a prompt, after the turn the steer missed; the turn it
/// started belongs to its one row.
fn assert_one_relogged_prompt(t: &Transcript) {
    assert_eq!(
        user_rows(t),
        vec![("go".into(), false, false), ("also this".into(), false, false)],
        "items: {:?}",
        t.items
    );
    let turn_end = t.items.iter().position(|i| matches!(i, Item::TurnEnd { .. })).unwrap();
    let relogged = index_of_user(t, "also this");
    assert!(relogged > turn_end, "the re-run prompt sits after t1's end: {:?}", t.items);
    assert_eq!(t.turn_span(relogged), Some((1_016, None)), "t2 belongs to its row");
    assert_eq!(t.user_at.get(&relogged), Some(&1_015));
    assert_eq!(t.turn_span(index_of_user(t, "go")), Some((1_011, Some(1_014))));
}

#[test]
fn steer_relog_live_shows_the_prompt_once() {
    let mut t = Transcript::default();
    let records = steer_relog_records();
    for e in &records[..3] {
        t.apply_event(e);
    }
    // The TUI echoes a steer before the daemon logs it (`tui/mod.rs` send).
    t.items.push(Item::User { text: "also this".into(), steer: true, queued: false });
    t.optimistic.push("also this".into());
    for e in &records[3..] {
        t.apply_event(e);
    }
    assert!(t.optimistic.is_empty());
    assert_one_relogged_prompt(&t);
}

#[test]
fn steer_relog_replayed_from_history_shows_the_prompt_once() {
    let mut t = Transcript::default();
    for e in &steer_relog_records() {
        t.apply_event(e);
    }
    assert_one_relogged_prompt(&t);
}

#[test]
fn steer_relog_split_across_forward_pages_shows_the_prompt_once() {
    // Lag recovery reads forward pages (`afterSeq`); the daemon may repeat the boundary.
    let records = steer_relog_records();
    for split in [4, 5] {
        let mut t = Transcript::default();
        for e in &records[..split] {
            t.apply_event(e);
        }
        assert_eq!(
            user_rows(&t),
            vec![("go".into(), false, false), ("also this".into(), true, false)],
            "before the re-run, the steer shows as a steer"
        );
        for e in &records[split - 1..] {
            t.apply_event(e);
        }
        assert_one_relogged_prompt(&t);
    }
}

#[test]
fn steer_relog_older_page_after_the_later_one_is_dropped() {
    // A transcript only moves forward: records at or below the last applied seq are
    // dropped, so an older page read after a later one adds no second row.
    let records = steer_relog_records();
    let mut t = Transcript::default();
    for e in &records[4..] {
        t.apply_event(e);
    }
    for e in &records[..5] {
        t.apply_event(e);
    }
    assert_eq!(user_rows(&t), vec![("also this".into(), false, false)]);
}

#[test]
fn steer_relog_that_waited_in_the_queue_shows_the_prompt_once() {
    // Another prompt took the turn first: the re-run waits in the queue, then runs.
    let mut records = steer_relog_records();
    records.insert(
        5,
        json!({"seq": 14, "at": 1_014, "dir": "mux", "kind": "queued", "msg": {
            "text": "also this", "client": "tui", "promptId": "p2", "turnId": "t2",
        }}),
    );
    for (i, r) in records.iter_mut().enumerate() {
        r["seq"] = json!(10 + i as u64);
    }
    let mut t = Transcript::default();
    for e in &records {
        t.apply_event(e);
    }
    assert_eq!(
        user_rows(&t),
        vec![("go".into(), false, false), ("also this".into(), false, false)],
        "items: {:?}",
        t.items
    );
}

#[test]
fn steer_then_a_new_prompt_with_the_same_text_keeps_both_rows() {
    // Only the steer's own prompt id replaces it: a later prompt that says the same
    // thing is its own message.
    let mut records = steer_relog_records();
    records[5]["msg"]["promptId"] = json!("p3");
    let mut t = Transcript::default();
    for e in &records {
        t.apply_event(e);
    }
    assert_eq!(
        user_rows(&t),
        vec![
            ("go".into(), false, false),
            ("also this".into(), true, false),
            ("also this".into(), false, false),
        ]
    );
}

/// Numbers `records` (kind, msg) from seq 10, `at` = 1_000 + seq.
fn numbered(records: Vec<(&str, Value)>) -> Vec<Value> {
    records
        .into_iter()
        .enumerate()
        .map(|(i, (kind, msg))| {
            let seq = 10 + i as u64;
            let dir = if kind == "chunk" { "in" } else { "mux" };
            let msg = if kind == "chunk" {
                json!({"method": "session/update", "params": {"sessionId": SID, "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": msg},
                }}})
            } else {
                msg
            };
            let kind = if kind == "chunk" { "session/update" } else { kind };
            json!({"seq": seq, "at": 1_000 + seq, "dir": dir, "kind": kind, "msg": msg})
        })
        .collect()
}

fn prompt(text: &str, id: &str, turn: &str) -> Value {
    json!({"text": text, "client": "tui", "promptId": id, "turnId": turn})
}

fn steer(text: &str, id: &str, turn: &str) -> Value {
    json!({"text": text, "steer": true, "client": "tui", "promptId": id, "turnId": turn})
}

fn turn(kind: &str, id: &str) -> Value {
    json!({"turnId": id, "stopReason": "end_turn", "kind": kind})
}

/// Applies `records`; `echo` names the steers the TUI showed (and queued in `optimistic`)
/// before the daemon logged them, each just before the record at that index.
fn applied(records: &[Value], echo: &[(usize, &str)]) -> Transcript {
    let mut t = Transcript::default();
    for (i, e) in records.iter().enumerate() {
        for (_, text) in echo.iter().filter(|(at, _)| *at == i) {
            t.items.push(Item::User { text: (*text).into(), steer: true, queued: false });
            t.optimistic.push((*text).into());
        }
        t.apply_event(e);
    }
    t
}

#[test]
fn steer_relog_behind_a_queued_prompt_shows_the_prompt_once() {
    // T runs with B queued. Steer S misses T: its re-run queues behind B, and B's own
    // `user_message` comes first (`hub/queue.rs`).
    let records = numbered(vec![
        ("user_message", prompt("go", "p1", "t1")),
        ("turn_started", turn("start", "t1")),
        ("queued", prompt("bee", "pb", "tb")),
        ("chunk", json!("working")),
        ("user_message", steer("sea", "ps", "t1")),
        ("turn_end", turn("end", "t1")),
        ("queued", prompt("sea", "ps", "ts")),
        ("user_message", prompt("bee", "pb", "tb")),
        ("turn_started", turn("start", "tb")),
        ("turn_end", turn("end", "tb")),
        ("user_message", prompt("sea", "ps", "ts")),
        ("turn_started", turn("start", "ts")),
    ]);
    for echo in [vec![], vec![(4, "sea")]] {
        let t = applied(&records, &echo);
        assert_eq!(
            user_rows(&t),
            vec![
                ("go".into(), false, false),
                ("bee".into(), false, false),
                ("sea".into(), false, false),
            ],
            "echo {echo:?}: {:?}",
            t.items
        );
    }
}

#[test]
fn steer_relog_of_two_missed_steers_shows_each_once() {
    // S1 and S2 both get STEER_NO_TURN; S1's re-run takes the turn, S2's waits.
    let records = numbered(vec![
        ("user_message", prompt("go", "p1", "t1")),
        ("turn_started", turn("start", "t1")),
        ("user_message", steer("one", "s1", "t1")),
        ("user_message", steer("two", "s2", "t1")),
        ("turn_end", turn("end", "t1")),
        ("user_message", prompt("one", "s1", "t2")),
        ("queued", prompt("two", "s2", "t3")),
        ("turn_started", turn("start", "t2")),
        ("turn_end", turn("end", "t2")),
        ("user_message", prompt("two", "s2", "t3")),
        ("turn_started", turn("start", "t3")),
    ]);
    for echo in [vec![], vec![(2, "one"), (3, "two")], vec![(2, "one"), (2, "two")]] {
        let t = applied(&records, &echo);
        assert_eq!(
            user_rows(&t),
            vec![
                ("go".into(), false, false),
                ("one".into(), false, false),
                ("two".into(), false, false),
            ],
            "echo {echo:?}: {:?}",
            t.items
        );
    }
}

#[test]
fn steer_relog_removes_its_own_row_when_two_steers_were_shown_first() {
    // The TUI showed S1 and S2 before the daemon logged S1: S1's record maps to S1's row.
    let records = numbered(vec![
        ("user_message", prompt("go", "p1", "t1")),
        ("turn_started", turn("start", "t1")),
        ("user_message", steer("one", "s1", "t1")),
        ("turn_end", turn("end", "t1")),
        ("user_message", prompt("one", "s1", "t2")),
    ]);
    let t = applied(&records, &[(2, "one"), (2, "two")]);
    assert_eq!(
        user_rows(&t),
        vec![
            ("go".into(), false, false),
            ("two".into(), true, false),
            ("one".into(), false, false)
        ],
        "{:?}",
        t.items
    );
}

#[test]
fn steer_with_the_text_of_a_queued_prompt_keeps_the_queued_row() {
    // A steer is never a queued prompt starting: the queued row with the same text stays
    // queued, and the steer's re-run (queued behind it) replaces the steer's own row.
    let records = numbered(vec![
        ("user_message", prompt("go", "p1", "t1")),
        ("turn_started", turn("start", "t1")),
        ("queued", prompt("same", "pb", "tb")),
        ("user_message", steer("same", "ps", "t1")),
        ("turn_end", turn("end", "t1")),
        ("queued", prompt("same", "ps", "ts")),
        ("user_message", prompt("same", "pb", "tb")),
        ("turn_started", turn("start", "tb")),
        ("turn_end", turn("end", "tb")),
        ("user_message", prompt("same", "ps", "ts")),
    ]);
    let t = applied(&records[..4], &[]);
    assert_eq!(
        user_rows(&t),
        vec![
            ("go".into(), false, false),
            ("same".into(), false, true),
            ("same".into(), true, false)
        ],
        "{:?}",
        t.items
    );
    let t = applied(&records, &[]);
    assert_eq!(
        user_rows(&t),
        vec![
            ("go".into(), false, false),
            ("same".into(), false, false),
            ("same".into(), false, false),
        ],
        "{:?}",
        t.items
    );
}

/// A subagent's words (its text, now that the Claude bridge sends it to the
/// subagent's view) never join the chat's: `acpmux prompt` and `last` read the
/// newest assistant item, which stays the chat's own answer.
#[test]
fn a_subagents_words_never_join_the_chats_reply() {
    let mut t = Transcript::default();
    let update = |text: &str, subagent: Option<&str>| {
        let mut p = json!({"sessionId": SID, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}});
        if let Some(s) = subagent {
            p["_meta"] = json!({"acpmux": {"subagent": s}});
        }
        p
    };
    t.apply_update(&update("Checking the merge hook.", Some("s1/toolu_1")));
    t.apply_update(&update("The hook is fixed.", None));
    let said: Vec<&str> = t
        .items
        .iter()
        .filter_map(|i| match i {
            Item::Assistant { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(said, ["The hook is fixed."]);
}

/// The same from recorded events (`acpmux last`, a resent prompt's reply, TUI history).
#[test]
fn a_subagents_recorded_words_never_join_the_chats_reply() {
    let mut t = Transcript::default();
    let record = |seq: u64, text: &str, subagent: Option<&str>| {
        let mut params = json!({"sessionId": SID, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}});
        if let Some(s) = subagent {
            params["_meta"] = json!({"acpmux": {"subagent": s}});
        }
        json!({"seq": seq, "at": 1_000 + seq, "dir": "in", "kind": "agent_message_chunk",
               "msg": {"method": "session/update", "params": params}})
    };
    t.apply_event(&record(1, "Checking the merge hook.", Some("s1/toolu_1")));
    t.apply_event(&record(2, "The hook is fixed.", None));
    let said: Vec<&str> = t
        .items
        .iter()
        .filter_map(|i| match i {
            Item::Assistant { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(said, ["The hook is fixed."]);
}

/// A hibernation's exit and its wake's resume draw no row; an ordinary stop and resume do.
#[test]
fn a_hibernation_and_its_wake_draw_no_row() {
    let mux = |seq: u64, kind: &str, msg: Value| json!({"seq": seq, "at": 1_000 + seq, "dir": "mux", "kind": kind, "msg": msg});
    let mut t = Transcript::default();
    for ev in [
        mux(1, "stopped", json!({"code": 0, "hibernated": true})),
        mux(2, "exited", json!({"code": -15, "hibernated": true})),
        mux(3, "resumed", json!({"level": "exact", "wake": true})),
        mux(4, "config", json!({"replayed": true})),
    ] {
        t.apply_event(&ev);
    }
    assert!(t.items.is_empty(), "{:?}", t.items);
    t.apply_event(&mux(5, "stopped", json!({"code": 0, "hibernated": false})));
    t.apply_event(&mux(6, "resumed", json!({"level": "exact", "wake": false})));
    assert_eq!(t.items.len(), 2, "{:?}", t.items);
}

fn user(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "at": 1_000 + seq, "dir": "mux", "kind": "user_message", "msg": {"text": text}})
}

fn user_texts(t: &Transcript) -> Vec<&str> {
    t.items
        .iter()
        .filter_map(|i| match i {
            Item::User { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

/// An older page goes before what is shown, each record once, and keeps the state the TUI
/// set from the session detail after attach.
#[test]
fn prepend_keeps_order_dedupes_and_keeps_session_state() {
    let mut t = Transcript::default();
    for e in [user(20, "three"), user(21, "four")] {
        t.apply_event(&e);
    }
    // A live update after attach, kept with its place.
    t.apply_update(&json!({"sessionId": SID, "update": {
        "sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "reply"},
    }, "_meta": {"acpmux": {"seq": 22}}}));
    t.status = "running".into();
    t.mode = Some("plan".into());
    t.model = Some("m1".into());
    t.usage = Some((5, 10));
    t.available_commands = vec!["review".into()];
    t.optimistic.push("sent".into());
    t.items.push(Item::User { text: "sent".into(), steer: false, queued: false });
    t.layout_dirty_from = usize::MAX;
    let before = t.items.len();

    // The page overlaps the oldest shown record (20) and arrives out of order.
    let added = t.prepend_events(&[user(11, "two"), user(10, "one"), user(20, "three")]);

    assert_eq!(added, 2);
    assert_eq!(t.items.len(), before + 2);
    assert_eq!(user_texts(&t), ["one", "two", "three", "four", "sent"]);
    assert!(
        matches!(t.items.get(4), Some(Item::Assistant { text }) if text == "reply"),
        "{:?}",
        t.items
    );
    assert_eq!(t.oldest_seq(), Some(10));
    assert_eq!(t.last_seq, 22);
    assert_eq!(t.status, "running");
    assert_eq!(t.mode.as_deref(), Some("plan"));
    assert_eq!(t.model.as_deref(), Some("m1"));
    assert_eq!(t.usage, Some((5, 10)));
    assert_eq!(t.available_commands, ["review"]);
    assert_eq!(t.optimistic, ["sent"]);
    assert_eq!(t.layout_dirty_from, 0, "the rebuild lays every row out again");
    assert!(t.removed_items.is_empty());

    // A page of records already shown adds nothing.
    assert_eq!(t.prepend_events(&[user(10, "one"), user(21, "four")]), 0);
    assert_eq!(user_texts(&t), ["one", "two", "three", "four", "sent"]);
    // A live record after the rebuild still lands once, at the end.
    t.apply_event(&user(22, "dup"));
    t.apply_event(&user(23, "five"));
    assert_eq!(user_texts(&t), ["one", "two", "three", "four", "sent", "five"]);
}
