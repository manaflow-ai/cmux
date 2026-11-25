//! A tool call's oversized output cut to its head (`toolOutputMaxBytes`).

use super::*;

fn record(seq: u64, kind: &str, update: Value) -> EventRecord {
    let msg = json!({"jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": "c", "update": update}});
    EventRecord { seq, at: seq, dir: "in".into(), kind: kind.into(), msg, host_seq: None }
}

fn log_text(bytes: usize) -> String {
    let mut out = String::new();
    let mut line = 0;
    while out.len() < bytes {
        line += 1;
        out.push_str(&format!("INFO build step {line} of 99999 ok\n"));
    }
    out
}

const MAX: usize = 64 * 1024;

#[test]
fn a_tool_output_past_the_cap_keeps_its_head_and_says_how_large_the_record_was() {
    let text = log_text(2 << 20);
    let rec = record(
        7,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "t", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": text}}],
            "rawOutput": {"exit_code": 0, "formatted_output": text}}),
    );
    let bytes = record_bytes(&rec);
    let (cut, after) = cut_tool_output(rec, bytes, MAX);
    assert!(after <= MAX, "the cut record is {after} bytes");
    assert_eq!(after, record_bytes(&cut));
    let update = &cut.msg["params"]["update"];
    assert_eq!(update["_meta"]["acpmux"]["cut"], json!({"bytes": bytes, "seq": 7}));
    let kept = update["content"][0]["content"]["text"].as_str().unwrap();
    assert!(text.starts_with(kept) && kept.len() < text.len());
    assert!(kept.ends_with('\n'), "a log is cut after a whole line");
    // Its `rawOutput` copy is cut the same way; short fields stay.
    let raw = update["rawOutput"]["formatted_output"].as_str().unwrap();
    assert!(text.starts_with(raw) && raw.len() < text.len());
    assert_eq!(update["rawOutput"]["exit_code"], 0);
    assert_eq!(update["toolCallId"], "t");
    assert_eq!(update["status"], "completed");
}

#[test]
fn records_that_fit_diffs_and_non_tool_records_go_whole() {
    let small = record(
        1,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "t",
            "content": [{"type": "content", "content": {"type": "text", "text": "ok"}}]}),
    );
    let bytes = record_bytes(&small);
    let (same, after) = cut_tool_output(small.clone(), bytes, MAX);
    assert_eq!((same.msg, after), (small.msg, bytes));

    // A diff: the phone counts its lines, so it is never cut.
    let big = log_text(512 * 1024);
    let diff = record(
        2,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "d",
            "content": [{"type": "diff", "path": "a.swift", "oldText": big, "newText": big}]}),
    );
    let bytes = record_bytes(&diff);
    let (same, after) = cut_tool_output(diff.clone(), bytes, MAX);
    assert_eq!((same.msg, after), (diff.msg, bytes));

    // An answer chunk is no tool output.
    let chunk = record(
        3,
        "agent_message_chunk",
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": big}}),
    );
    let bytes = record_bytes(&chunk);
    let (same, _) = cut_tool_output(chunk.clone(), bytes, MAX);
    assert_eq!(same.msg, chunk.msg);
}

#[test]
fn a_cut_never_splits_a_character() {
    let text = "é".repeat(200 * 1024);
    let rec = record(
        4,
        "tool_call",
        json!({"sessionUpdate": "tool_call", "toolCallId": "t", "_meta": {"other": 1},
            "content": [{"type": "content", "content": {"type": "text", "text": text}}]}),
    );
    let bytes = record_bytes(&rec);
    let (cut, after) = cut_tool_output(rec, bytes, MAX);
    assert!(after <= MAX);
    let update = &cut.msg["params"]["update"];
    let kept = update["content"][0]["content"]["text"].as_str().unwrap();
    assert!(!kept.is_empty() && kept.chars().all(|c| c == 'é'));
    // The update's own `_meta` keeps what it held.
    assert_eq!(update["_meta"]["other"], 1);
    assert_eq!(update["_meta"]["acpmux"]["cut"]["seq"], 4);
}
