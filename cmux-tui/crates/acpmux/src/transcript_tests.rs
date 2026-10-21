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
