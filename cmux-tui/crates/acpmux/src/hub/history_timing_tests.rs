use super::*;

fn rec(seq: u64, at: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// Feeds `records` as `history` does, opening a turn on each person's `user_message`.
fn fold(records: &[EventRecord]) -> Vec<serde_json::Map<String, Value>> {
    let mut timing = Timing::default();
    let mut turns = Vec::new();
    let mut cur: Option<serde_json::Map<String, Value>> = None;
    for e in records {
        let opened = e.kind == "user_message" && e.msg.get("steer").is_none();
        if opened {
            turns.extend(cur.take());
            let mut t = serde_json::Map::new();
            t.insert("startedAt".into(), json!(e.at));
            cur = Some(t);
        }
        timing.note(e, cur.as_mut(), opened);
    }
    turns.extend(cur);
    turns
}

/// Leo's new chat of 2026-11-05 ("Thinking 46s"), with the times read from its log: the agent up
/// at 0.9 s, its start effort answered at 15.9 s and its start mode at 24.2 s, then the prompt,
/// and the model's first stream event 2.1 s after the prompt was written.
#[test]
fn a_new_chat_names_its_start_apart_from_the_model() {
    let records = [
        rec(1, 0, "mux", "created", json!({"harness": "claude"})),
        rec(2, 60, "out", "initialize", json!({"id": 1, "method": "initialize"})),
        rec(3, 900, "in", "response", json!({"id": 1, "result": {}})),
        rec(4, 905, "out", "session/set_config_option", json!({"id": 2})),
        rec(5, 15_900, "in", "response", json!({"id": 2, "result": {}})),
        rec(6, 15_905, "out", "session/set_mode", json!({"id": 3})),
        rec(7, 24_200, "in", "response", json!({"id": 3, "result": {}})),
        rec(8, 24_210, "mux", "user_message", json!({"text": "remap the port"})),
        rec(9, 24_215, "out", "session/prompt", json!({"id": 4})),
        rec(10, 26_315, "in", "claude.stream_event", json!({})),
        rec(11, 30_000, "in", "claude.stream_event", json!({})),
        rec(12, 31_000, "in", "tool_call", json!({})),
    ];
    let turns = fold(&records);
    assert_eq!(turns.len(), 1);
    let t = &turns[0];
    assert_eq!(t["toAgentMs"], json!(5));
    assert_eq!(t["firstModelMs"], json!(2_100));
    let start = &t["agentStart"];
    assert_eq!(start["firstPromptMs"], json!(24_210));
    assert_eq!(start["readyMs"], json!(24_200));
    assert_eq!(
        start["steps"],
        json!([
            {"method": "initialize", "ms": 840},
            {"method": "session/set_config_option", "ms": 14_995},
            {"method": "session/set_mode", "ms": 8_295},
        ])
    );
}

/// A later turn whose agent had to start again (the idle census ended it) shows that start as
/// its own `toAgentMs`; a mode change between turns is no part of the chat's start.
#[test]
fn a_later_turn_names_its_own_agent_start() {
    let records = [
        rec(1, 0, "mux", "created", json!({})),
        rec(2, 10, "mux", "user_message", json!({"text": "one"})),
        rec(3, 20, "out", "session/prompt", json!({"id": 1})),
        rec(4, 1_020, "in", "tool_call", json!({})),
        rec(5, 2_000, "out", "session/set_mode", json!({"id": 2})),
        rec(6, 2_010, "in", "response", json!({"id": 2})),
        rec(7, 9_000, "mux", "user_message", json!({"text": "steer", "steer": true})),
        rec(8, 60_000, "mux", "user_message", json!({"text": "two"})),
        rec(9, 64_000, "out", "session/prompt", json!({"id": 3})),
        rec(10, 65_500, "in", "claude.stream_event", json!({})),
    ];
    let turns = fold(&records);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0]["agentStart"], json!({"firstPromptMs": 10, "steps": []}));
    assert_eq!(turns[0]["firstModelMs"], json!(1_000));
    assert!(!turns[1].contains_key("agentStart"));
    assert_eq!(turns[1]["toAgentMs"], json!(4_000));
    assert_eq!(turns[1]["firstModelMs"], json!(1_500));
}

/// A turn whose prompt never reached the agent (refused, stopped) names no times it does not have.
#[test]
fn a_prompt_never_written_names_no_agent_times() {
    let records = [
        rec(1, 0, "mux", "user_message", json!({"text": "one"})),
        rec(2, 500, "in", "claude.stream_event", json!({})),
    ];
    let turns = fold(&records);
    assert!(!turns[0].contains_key("toAgentMs"));
    assert!(!turns[0].contains_key("firstModelMs"));
    assert!(!turns[0].contains_key("agentStart"));
}
