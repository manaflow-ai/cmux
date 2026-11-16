use super::*;

fn record(seq: u64, at: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

#[test]
fn folds_fixture_journal_into_categories_and_tokens() {
    let mut state = State::default();
    for record in [
        record(1, 1_000, "turn_started", serde_json::json!({"turnSeq": 1, "turnId": "t1"})),
        record(2, 2_000, "agent_thought_chunk", serde_json::json!({})),
        record(3, 5_000, "tool_call", serde_json::json!({"toolCallId": "r", "kind": "read"})),
        record(
            4,
            9_000,
            "tool_call_update",
            serde_json::json!({"toolCallId": "r", "status": "completed"}),
        ),
        record(5, 10_000, "permission_request", serde_json::json!({})),
        record(6, 13_000, "permission_decision", serde_json::json!({})),
        record(
            7,
            15_000,
            "turn_result",
            serde_json::json!({"usage": {"inputTokens": 5, "outputTokens": 7}}),
        ),
    ] {
        state.record(&record);
    }
    let result = state.snapshot(15_000);
    assert_eq!(result.total_ms, 14_000);
    assert_eq!(result.total_tokens, Some(12));
    assert!(result.categories.iter().all(|c| c.tokens.is_none()));
    assert!(result.spans.iter().all(|s| s.turn_tokens == Some(12)));
    assert_eq!(result.categories.iter().find(|c| c.id == "think").unwrap().wall_ms, 3_000);
    assert_eq!(result.categories.iter().find(|c| c.id == "read").unwrap().wall_ms, 4_000);
    assert_eq!(result.categories.iter().find(|c| c.id == "person").unwrap().wall_ms, 3_000);
    assert!(result.spans.iter().any(|span| span.category == "read" && span.turn_seq == 1));
}

#[test]
fn repeated_records_and_snapshots_do_not_replay() {
    let mut state = State::default();
    let started = record(1, 10, "turn_started", serde_json::json!({"turnSeq": 1}));
    let ended = record(2, 20, "turn_result", serde_json::json!({}));
    state.record(&started);
    state.record(&ended);
    state.record(&ended);
    let first = state.snapshot(20);
    let second = state.snapshot(20);
    assert_eq!(first, second);
    assert_eq!(first.total_ms, 10);
}

#[test]
fn end_marker_waits_for_result_usage() {
    let mut state = State::default();
    state.record(&record(1, 10, "turn_started", serde_json::json!({"turnSeq": 1})));
    state.record(&record(2, 20, "turn_end", serde_json::json!({})));
    state.record(&record(3, 30, "turn_result", serde_json::json!({"usage": {"outputTokens": 4}})));
    let result = state.snapshot(30);
    assert_eq!(result.total_ms, 10);
    assert_eq!(result.total_tokens, Some(4));
    assert!(result.tokens_complete);
}

#[test]
fn reads_flattened_turn_result_usage() {
    let mut state = State::default();
    state.record(&record(1, 10, "turn_started", serde_json::json!({"turnSeq": 1})));
    state.record(&record(
            2,
            20,
            "turn_result",
            serde_json::json!({"inputTokens": 3, "outputTokens": 5, "cacheReadTokens": 2, "inputExcludesCache": true}),
        ));
    let result = state.snapshot(20);
    assert_eq!(result.total_tokens, Some(10));
    assert!(result.tokens_complete);
    assert!(result.spans.iter().all(|s| s.turn_tokens == Some(10)));
}

#[test]
fn updates_identity_when_user_message_precedes_turn_started() {
    let mut state = State::default();
    state.record(&record(1, 10, "user_message", serde_json::json!({"text": "hi"})));
    state.record(&record(2, 20, "turn_started", serde_json::json!({"turnSeq": 7, "turnId": "t7"})));
    state.record(&record(3, 30, "agent_message_chunk", serde_json::json!({})));
    state.record(&record(4, 40, "turn_result", serde_json::json!({})));
    assert!(
        state
            .snapshot(40)
            .spans
            .iter()
            .all(|span| span.turn_seq == 7 && span.turn_id.as_deref() == Some("t7"))
    );
}

#[test]
fn keeps_live_segments_bounded_while_totals_remain_complete() {
    let mut state = State::default();
    state.record(&record(1, 0, "turn_started", serde_json::json!({"turnSeq": 1})));
    for i in 0..(MAX_SPANS as u64 + 40) {
        let at = 10 + i * 2;
        let kind = if i % 2 == 0 { "agent_thought_chunk" } else { "agent_message_chunk" };
        state.record(&record(i + 2, at, kind, serde_json::json!({})));
    }
    state.record(&record(MAX_SPANS as u64 + 42, 2_000, "turn_result", serde_json::json!({})));
    let result = state.snapshot(2_000);
    assert!(result.spans.len() <= MAX_SPANS);
    assert_eq!(result.total_ms, 2_000);
    assert_eq!(result.categories.iter().map(|c| c.wall_ms).sum::<u64>(), result.total_ms);
}

#[test]
fn live_turn_is_included_without_becoming_durable_total() {
    let mut state = State::default();
    state.record(&record(1, 100, "turn_started", serde_json::json!({"turnSeq": 1})));
    state.record(&record(2, 150, "agent_thought_chunk", serde_json::json!({})));
    let result = state.snapshot(200);
    assert_eq!(result.total_ms, 100);
    assert_eq!(result.categories.iter().find(|c| c.id == "think").unwrap().wall_ms, 50);
    assert_eq!(result.spans.len(), 2);
}

#[test]
fn durable_envelopes_permissions_and_late_usage() {
    let mut state = State::default();
    for line in include_str!("fixture.jsonl").lines() {
        state.record(&serde_json::from_str(line).unwrap());
    }
    let result = state.snapshot(100_000);
    assert_eq!(result.total_ms, 21_000);
    assert_eq!(result.total_tokens, Some(24));
    assert!(result.tokens_complete);
    let ms = |id| result.categories.iter().find(|c| c.id == id).unwrap().wall_ms;
    assert_eq!(ms("read"), 3_000);
    assert_eq!(ms("run"), 10_000);
    assert_eq!(ms("person"), 4_000);
    assert_eq!(ms("think"), 0);
    assert!(result.spans.iter().all(|s| s.turn_id.as_deref() == Some("t7") && s.turn_seq == 7));
}

#[test]
fn stopped_turn_does_not_accumulate_idle_time_without_result() {
    let mut state = State::default();
    state.record(&record(1, 10, "turn_started", serde_json::json!({"turnId": "t"})));
    state.record(&record(2, 20, "turn_error", serde_json::json!({"turnId": "t"})));
    assert_eq!(state.snapshot(50).total_ms, 10);
    assert_eq!(state.snapshot(500_000).total_ms, 10);
    assert!(!state.snapshot(500_000).tokens_complete);
}

#[test]
fn same_phase_chunks_do_not_grow_or_advance_segments() {
    let mut state = State::default();
    state.record(&record(1, 0, "turn_started", serde_json::json!({})));
    state.record(&record(2, 10, "agent_thought_chunk", serde_json::json!({})));
    for seq in 3..1_000 {
        state.record(&record(seq, seq * 10, "agent_thought_chunk", serde_json::json!({})));
    }
    let turn = state.reducer.turn.as_ref().unwrap();
    assert_eq!(turn.last_at, 10);
    assert_eq!(turn.segments.len(), 1);
    assert_eq!(state.snapshot(10_000).total_ms, 10_000);
}

#[test]
fn ambiguous_cache_usage_stays_unknown_and_aliases_are_not_added_twice() {
    assert_eq!(usage(&serde_json::json!({"inputTokens": 10, "cacheReadTokens": 5})), None);
    assert_eq!(
        usage(&serde_json::json!({"inputTokens": 10, "input_tokens": 10, "outputTokens": 5})),
        Some(15)
    );
    assert_eq!(
        usage(&serde_json::json!({"totalTokens": 12, "inputTokens": 10, "cacheReadTokens": 5})),
        Some(12)
    );
}

#[test]
fn completed_tool_call_does_not_claim_remaining_turn() {
    let mut state = State::default();
    state.record(&record(1, 0, "turn_started", serde_json::json!({})));
    state.record(&record(
        2,
        10,
        "tool_call",
        serde_json::json!({"toolCallId": "r", "kind": "read", "status": "completed"}),
    ));
    state.record(&record(3, 20, "turn_result", serde_json::json!({})));
    assert_eq!(state.snapshot(20).categories.iter().find(|c| c.id == "read").unwrap().wall_ms, 0);
}

#[test]
fn closed_session_without_a_result_stops_the_live_clock() {
    let mut state = State::default();
    state.record(&record(1, 0, "turn_started", serde_json::json!({})));
    state.record(&record(2, 100, "status", serde_json::json!({"status": "closed"})));
    assert_eq!(state.snapshot(1_000_000).total_ms, 100);
}

#[test]
fn lifetime_totals_survive_completed_turn_eviction() {
    let mut state = State::default();
    for turn in 0..600 {
        state.record(&record(
            turn * 2 + 1,
            turn * 10,
            "turn_started",
            serde_json::json!({"turnId": format!("t{turn}")}),
        ));
        state.record(&record(
            turn * 2 + 2,
            turn * 10 + 5,
            "turn_result",
            serde_json::json!({"outputTokens": 2}),
        ));
    }
    let result = state.snapshot(7_000);
    assert_eq!(result.total_ms, 3_000);
    assert_eq!(result.total_tokens, Some(1_200));
    assert_eq!(result.spans.len(), MAX_SPANS);
    assert!(result.tokens_complete);
}
