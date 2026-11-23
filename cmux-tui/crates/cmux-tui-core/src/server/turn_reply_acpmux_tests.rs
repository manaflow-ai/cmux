use serde_json::{Value, json};

use super::{MAX_REPLY_BYTES, TurnReply, read_reply};

const SESSION: &str = "s1";

/// A fake acpmux log: `(seq, at, kind, msg)` records, answered as
/// `_acpmux/events` pages are (kinds, afterSeq, beforeSeq, limit).
fn log_events(log: &[(u64, u64, &str, Value)]) -> impl Fn(Value) -> Option<Value> + '_ {
    move |params: Value| {
        let kinds: Vec<&str> = params["kinds"]
            .as_array()
            .map(|k| k.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let after = params["afterSeq"].as_u64().unwrap_or(0);
        let before = params["beforeSeq"].as_u64().unwrap_or(u64::MAX);
        let limit = params["limit"].as_u64().unwrap_or(5000) as usize;
        let matching: Vec<Value> = log
            .iter()
            .filter(|(seq, _, kind, _)| kinds.contains(kind) && *seq > after && *seq < before)
            .map(|(seq, at, kind, msg)| json!({"seq": seq, "at": at, "kind": kind, "msg": msg}))
            .collect();
        // afterSeq pages oldest first from the start; otherwise the newest `limit`.
        let page: Vec<Value> = if params.get("afterSeq").is_some() {
            matching.into_iter().take(limit).collect()
        } else {
            let skip = matching.len().saturating_sub(limit);
            matching.into_iter().skip(skip).collect()
        };
        Some(json!({"events": page}))
    }
}

fn known(session: &str) -> Option<Value> {
    Some(json!({"sessionId": session}))
}

fn chunk(text: &str) -> Value {
    json!({"params": {"update": {"content": {"type": "text", "text": text}}}})
}

#[test]
fn the_reply_is_the_text_of_the_prompts_own_turn() {
    let log = vec![
        (1, 1_000, "turn_started", json!({"promptId": "other", "turnId": "t0"})),
        (2, 1_001, "agent_message_chunk", chunk("not mine")),
        (
            3,
            1_002,
            "turn_result",
            json!({"promptId": "other", "turnSeq": 1, "status": "completed"}),
        ),
        (4, 2_000, "turn_started", json!({"promptId": "p", "turnId": "t1"})),
        (5, 2_001, "agent_message_chunk", chunk("Fixed ")),
        (6, 2_002, "agent_message_chunk", chunk("the typo.")),
        (7, 2_003, "turn_result", json!({"promptId": "p", "turnSeq": 4, "status": "completed"})),
        (8, 3_000, "agent_message_chunk", chunk("a later turn")),
    ];
    let reply = read_reply(log_events(&log), known, SESSION, "p", 2_000);
    assert_eq!(
        reply,
        TurnReply::Ended { status: "completed".into(), text: "Fixed the typo.".into() }
    );
}

#[test]
fn a_prompt_with_no_ended_turn_is_pending() {
    let log = vec![
        (1, 2_000, "turn_started", json!({"promptId": "p", "turnId": "t1"})),
        (2, 2_001, "agent_message_chunk", chunk("working")),
    ];
    assert_eq!(read_reply(log_events(&log), known, SESSION, "p", 2_000), TurnReply::Pending);
}

#[test]
fn results_older_than_the_send_end_the_search() {
    let mut log = Vec::new();
    for seq in 1..=1_000u64 {
        log.push((seq, seq, "turn_result", json!({"promptId": format!("old{seq}"), "turnSeq": 0})));
    }
    // Sent long after every result: the first page ends the search.
    let reply = read_reply(log_events(&log), known, SESSION, "p", 10_000_000);
    assert_eq!(reply, TurnReply::Pending);
}

#[test]
fn a_cancelled_turn_that_never_started_has_no_text() {
    let log = vec![(
        1,
        2_000,
        "turn_result",
        json!({"promptId": "p", "turnSeq": 0, "status": "cancelled"}),
    )];
    let reply = read_reply(log_events(&log), known, SESSION, "p", 2_000);
    assert_eq!(reply, TurnReply::Ended { status: "cancelled".into(), text: String::new() });
}

#[test]
fn an_unknown_session_or_a_silent_acpmux_is_unreadable() {
    let log = vec![];
    assert_eq!(read_reply(log_events(&log), |_| None, SESSION, "p", 0), TurnReply::Unreadable);
    assert_eq!(read_reply(|_| None, known, SESSION, "p", 0), TurnReply::Unreadable);
}

#[test]
fn a_long_reply_is_cut_on_a_character_boundary() {
    let big = "é".repeat(MAX_REPLY_BYTES);
    let log = vec![
        (1, 2_000, "turn_started", json!({"promptId": "p"})),
        (2, 2_001, "agent_message_chunk", chunk(&big)),
        (3, 2_002, "turn_result", json!({"promptId": "p", "turnSeq": 1, "status": "completed"})),
    ];
    let TurnReply::Ended { text, .. } = read_reply(log_events(&log), known, SESSION, "p", 2_000)
    else {
        panic!("ended")
    };
    assert!(text.len() <= MAX_REPLY_BYTES && text.len() >= MAX_REPLY_BYTES - 1);
}
