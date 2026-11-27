use serde_json::json;

use super::*;

fn chunk(kind: &str, id: Option<&str>, text: &str) -> String {
    let mut update = json!({ "sessionUpdate": kind, "content": { "type": "text", "text": text } });
    if let Some(id) = id {
        update["messageId"] = json!(id);
    }
    json!({ "jsonrpc": "2.0", "method": "_acpmux/event",
        "params": { "kind": kind, "msg": { "params": { "update": update } } } })
    .to_string()
}

fn view(width: f32, height: f32) -> View {
    View { width, height, line_height: 10.0, gap: 0.0, pad: 0.0 }
}

#[test]
fn narration_matches_the_page() {
    // The cases turns.ts `isWorkNarration` is tested and documented with.
    for quiet in [
        "Let me check the logs.",
        "I'll run the tests.",
        "Checking the build.",
        "Both jobs still running.",
        "Let me check. Running the suite.",
        "Checking the failed jobs.",
    ] {
        assert!(is_work_narration(quiet), "{quiet:?} is narration");
    }
    for answer in [
        "",
        "Let me check. The cache is stale.",
        "Running two tasks is faster",
        "Let me check; the cache is stale",
        "Checking the cache found no errors.",
        "Running both takes 2 s.",
        "Checking it crashed again.",
        "The fix is in.",
        "Let me check. Running it. Reading more.",
    ] {
        assert!(!is_work_narration(answer), "{answer:?} is not narration");
    }
}

#[test]
fn chunks_of_one_reply_make_one_row_and_a_new_id_starts_another() {
    let mut transcript = Transcript::new();
    assert!(transcript.message(&chunk("agent_message_chunk", Some("a"), "Hello ")));
    assert!(transcript.message(&chunk("agent_message_chunk", Some("a"), "world")));
    assert!(!transcript.message(&chunk("agent_message_chunk", Some("a"), "")));
    assert!(transcript.message(&chunk("agent_message_chunk", Some("b"), "Next")));
    assert!(transcript.message(&chunk("agent_thought_chunk", None, "hm")));
    assert!(transcript.message(&chunk("agent_thought_chunk", None, "m")));
    assert_eq!(transcript.len(), 3);
    let lines = transcript.layout(&view(1000.0, 100.0), &Advance::fixed(1.0));
    let texts: Vec<_> = lines.iter().map(|line| line.text).collect();
    assert_eq!(texts, ["Hello world", "Next", "hmm"]);
    assert_eq!(lines[2].y, 100.0);
    assert_eq!(lines[0].y, 80.0);
}

#[test]
fn attach_answer_replays_its_events_and_tool_updates_change_their_row() {
    let mut transcript = Transcript::new();
    let attach = json!({ "jsonrpc": "2.0", "id": 2, "result": { "events": [
        { "kind": "user_message", "msg": { "text": "Fix it" } },
        { "kind": "tool_call", "msg": { "params": { "update": {
            "toolCallId": "t1", "title": "cargo test", "_meta": { "claude": { "tool": "Bash" } } } } } },
        { "kind": "agent_message_chunk", "msg": { "params": { "update": {
            "messageId": "m", "content": { "text": "Let me check the logs." } } } } },
    ] } });
    assert!(transcript.message(&attach.to_string()));
    let done = json!({ "jsonrpc": "2.0", "method": "_acpmux/event", "params": {
        "kind": "tool_call_update", "msg": { "params": { "update": {
            "toolCallId": "t1", "status": "completed", "title": "cargo test" } } } } });
    assert!(transcript.message(&done.to_string()));
    assert!(!transcript.message("not json"));
    let lines = transcript.layout(&view(1000.0, 100.0), &Advance::fixed(1.0));
    let shown: Vec<_> = lines.iter().map(|line| (line.text, line.style)).collect();
    assert_eq!(
        shown,
        [
            ("Fix it", Style::User),
            ("cargo test (completed)", Style::Tool),
            ("Let me check the logs.", Style::Quiet),
        ]
    );
}

#[test]
fn layout_wraps_to_the_width_and_stops_at_the_top() {
    let mut transcript = Transcript::new();
    for at in 0..50 {
        transcript.message(&chunk("agent_message_chunk", Some(&format!("m{at}")), "aaa bbb ccc"));
    }
    // Seven columns: "aaa bbb" then "ccc"; 30 px tall: three lines, the newest at the bottom.
    let lines = transcript.layout(&view(7.0, 30.0), &Advance::fixed(1.0));
    let texts: Vec<_> = lines.iter().map(|line| line.text).collect();
    assert_eq!(texts, ["ccc", "aaa bbb", "ccc"]);
}

#[test]
fn wrap_breaks_a_word_wider_than_the_line_and_keeps_hard_breaks() {
    let text = "abcdefghij x\nyz";
    let lines: Vec<_> = wrap(text, 4.0, &Advance::fixed(1.0))
        .into_iter()
        .map(|(start, end)| &text[start..end])
        .collect();
    assert_eq!(lines, ["abcd", "efgh", "ij x", "yz"]);
}

#[test]
fn only_the_newest_rows_are_kept() {
    let mut transcript = Transcript::new();
    for at in 0..(KEEP + 30) {
        transcript.message(&chunk("agent_message_chunk", Some(&format!("m{at}")), "x"));
    }
    assert_eq!(transcript.len(), KEEP);
}

#[test]
fn a_long_row_lays_out_its_tail() {
    let mut transcript = Transcript::new();
    let long = format!("{}é{}", "a".repeat(TAIL_BYTES), "b".repeat(10));
    transcript.message(&chunk("agent_thought_chunk", None, &long));
    let lines = transcript.layout(&view(100_000.0, 10.0), &Advance::fixed(1.0));
    assert_eq!(lines.len(), 1);
    assert!(lines[0].text.ends_with("bbbbbbbbbb"));
    assert!(lines[0].text.len() <= TAIL_BYTES);
}
