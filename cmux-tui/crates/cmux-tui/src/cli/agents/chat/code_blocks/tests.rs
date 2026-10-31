use super::{MAX_FIELD_BYTES, MAX_SCAN_BYTES, extract, load};
use serde_json::{Value, json};

fn text(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update", "msg": {
        "method": "session/update", "params": {"update": {
            "sessionUpdate": "agent_message_chunk", "content": {"text": text}
        }}
    }})
}

fn end(seq: u64) -> Value {
    json!({"seq": seq, "dir": "mux", "kind": "turn_result", "msg": {"status": "completed"}})
}

#[test]
fn latest_code_block_reads_the_tail_of_a_long_history() {
    let mut history = Vec::new();
    for seq in (1..=1000).step_by(2) {
        history.extend([text(seq, "```sh\necho old\n```"), end(seq + 1)]);
    }
    history.extend([text(1001, "```rust\nlet latest = true;\n```"), end(1002)]);
    let mut requests = 0;
    let block = load(|before| {
        requests += 1;
        let matching: Vec<_> =
            history.iter().filter(|event| event["seq"].as_u64().unwrap() < before).collect();
        let start = matching.len().saturating_sub(5);
        Ok(json!({"events": &matching[start..], "hasMore": start > 0}))
    })
    .unwrap();
    assert_eq!(block, json!({"language": "rust", "code": "let latest = true;"}));
    assert_eq!(requests, 1, "reads newest records rather than replaying the conversation");
}

#[test]
fn latest_code_block_reassembles_an_answer_across_reverse_pages() {
    let mut requests = Vec::new();
    let block = load(|before| {
        requests.push(before);
        Ok(match before {
            u64::MAX => json!({"events": [text(3, "latest\n```"), end(4)], "hasMore": true}),
            3 => json!({"events": [end(1), text(2, "```sh\necho ")], "hasMore": true}),
            _ => panic!("unexpected cursor {before}"),
        })
    })
    .unwrap();
    assert_eq!(requests, vec![u64::MAX, 3]);
    assert_eq!(block, json!({"language": "sh", "code": "echo latest"}));
}

#[test]
fn latest_code_block_refuses_an_incomplete_scan_instead_of_returning_old_code() {
    let result = load(|before| Ok(json!({"events": [text(before - 1, "text")], "hasMore": true})));
    assert!(result.is_err());
    let large = "x".repeat(MAX_SCAN_BYTES);
    assert!(load(|_| Ok(json!({"events": [text(1, &large)], "hasMore": false}))).is_err());
    assert!(load(|_| Ok(json!({"events": [], "hasMore": true}))).is_err());
}

#[test]
fn latest_code_block_ignores_user_code_but_reads_closed_fences_in_live_answers() {
    let block = load(|_| {
        Ok(json!({"events": [
        {"seq": 1, "dir": "mux", "kind": "user_message", "msg": {"text": "```sh\nsecret\n```"}},
        text(2, "```sh\necho still working\n```"),
    ], "hasMore": false}))
    })
    .unwrap();
    assert_eq!(block, json!({"language": "sh", "code": "echo still working"}));
}

#[test]
fn latest_code_block_supports_markdown_containers_and_matching_fences() {
    for (markdown, language, code) in [
        ("> ```sh\n> echo quoted\n> ```", "sh", "echo quoted"),
        ("- ```sh\n  echo listed\n  ```", "sh", "echo listed"),
        ("```sh title\r\necho crlf\r\n```", "sh", "echo crlf"),
        ("~~~~rust\nlet x = 1;\n~~~~", "rust", "let x = 1;"),
        ("```txt\na\n\n\n```", "txt", "a\n\n"),
        ("````md\n```\nnested\n```\n````", "md", "```\nnested\n```"),
        ("```rust```\n```sh\necho ok\n```", "sh", "echo ok"),
    ] {
        assert_eq!(
            extract(markdown),
            Some(json!({"language": language, "code": code})),
            "{markdown}"
        );
    }
    for markdown in [
        "inline `code`",
        "    indented code",
        "```rust\nunfinished",
        "~~~~\nx\n~~~",
        "```sh\necho unfinished\n    ```",
    ] {
        assert_eq!(extract(markdown), None, "{markdown}");
    }
}

#[test]
fn latest_code_block_bounds_json_and_masks_before_truncating() {
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let answer = format!("```{}\n{key}\n{}\n```", "x".repeat(2000), "\u{1}".repeat(100_000));
    let block =
        load(|_| Ok(json!({"events": [text(1, &answer), end(2)], "hasMore": false}))).unwrap();
    assert!(!block.to_string().contains(&key));
    assert!(block["code"].as_str().unwrap().contains("[AWS access key]"));
    assert_eq!(block["truncated"], true);
    assert!(block.to_string().len() <= MAX_FIELD_BYTES + 32);
}

#[test]
fn latest_code_block_masks_secrets_decoded_from_markdown_info() {
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let block = extract("```AKIA&#81;7ZJ4XK2MD5P3WRT\necho ok\n```").unwrap();
    assert!(!block.to_string().contains(&key), "{block}");
    assert_eq!(block["language"], "[AWS access key]");
}

#[test]
fn latest_code_block_refuses_a_transport_omission() {
    let result = load(|_| {
        Ok(json!({"events": [
        text(1, "```sh\necho old\n```"), end(2),
        {"seq": 3, "dir": "in", "kind": "agent_message_chunk",
         "msg": {"_meta": {"acpmux": {"omitted": {"bytes": 40000000, "reason": "too_large"}}}}},
        end(4),
    ], "hasMore": false}))
    });
    assert!(result.is_err(), "must not claim the old block is the latest: {result:?}");
}

fn identified_text(seq: u64, id: &str, body: &str) -> Value {
    let mut event = text(seq, body);
    event["msg"]["params"]["update"]["messageId"] = json!(id);
    event
}

fn superseded(seq: u64, old: &str, new: &str) -> Value {
    json!({"seq": seq, "dir": "mux", "kind": "message_superseded",
        "msg": {"oldMessageId": old, "newMessageId": new}})
}

#[test]
fn code_block_ignores_superseded_answers_across_reverse_pages() {
    let mut cursors = Vec::new();
    let block = load(|before| {
        cursors.push(before);
        Ok(match before {
            u64::MAX => json!({"events": [
                superseded(3, "old", "new"), identified_text(4, "new", "No code needed."), end(5),
            ], "hasMore": true}),
            3 => json!({"events": [end(1), identified_text(2, "old", "```sh\necho obsolete\n```\n")], "hasMore": false}),
            _ => panic!("unexpected cursor {before}"),
        })
    }).unwrap();
    assert_eq!(block, Value::Null, "superseded code is no longer in the chat");
    assert_eq!(cursors, [u64::MAX, 3]);
}

#[test]
fn code_block_does_not_join_fences_from_different_assistant_messages() {
    let block = load(|_| {
        Ok(json!({"events": [
        identified_text(1, "first", "```sh\necho unfinished\n"),
        identified_text(2, "second", "```"), end(3),
    ], "hasMore": false}))
    })
    .unwrap();
    assert_eq!(block, Value::Null, "separate messages cannot complete each other's fences");
}

#[test]
fn code_block_anonymous_chunks_preserve_message_identity() {
    let block = load(|_| {
        Ok(json!({"events": [
            identified_text(1, "old", "```sh\n"),
            text(2, "echo obsolete\n"),
            identified_text(3, "old", "```\n"),
            superseded(4, "old", "new"),
            identified_text(5, "new", "No code needed."), end(6),
        ], "hasMore": false}))
    })
    .unwrap();
    assert_eq!(block, Value::Null, "anonymous chunks must not lose the superseded identity");
}

#[test]
fn code_block_adopts_the_first_identity_after_anonymous_chunks() {
    let events = [text(1, "```sh\necho "), identified_text(2, "old", "ok\n```\n")];
    let block = load(|_| Ok(json!({"events": events, "hasMore": false}))).unwrap();
    assert_eq!(block, json!({"language": "sh", "code": "echo ok"}));
    let mut replaced = events.to_vec();
    replaced.extend([
        superseded(3, "old", "new"),
        identified_text(4, "new", "No code needed."),
        end(5),
    ]);
    let block = load(|_| Ok(json!({"events": replaced, "hasMore": false}))).unwrap();
    assert_eq!(block, Value::Null, "the adopted identity covers the entire answer");
}

#[test]
fn code_block_supersession_preserves_tools_and_transcript_pagination() {
    let mut transcript = super::super::Transcript::default();
    for event in [
        identified_text(1, "old", "```sh\necho obsolete\n```"),
        json!({"seq": 2, "dir": "in", "kind": "session/update", "msg": {
            "method": "session/update", "params": {"update": {
                "sessionUpdate": "tool_call", "toolCallId": "tool", "kind": "read", "status": "in_progress"
            }}
        }}),
        identified_text(3, "old", "also obsolete"),
        superseded(4, "old", "new"),
        superseded(5, "old", "new"),
        identified_text(6, "old", "late obsolete chunk"),
        identified_text(7, "new", "```sh\necho current\n```"),
        end(8),
    ] {
        transcript.apply(&event);
    }
    let first = transcript.page("chat", 0, 1, false, 8);
    assert_eq!(first["items"][0]["role"], "tool");
    assert_eq!(first["items"][0].get("partial"), None);
    assert_eq!(first["next_after"], 2);
    assert_eq!(first["has_more"], true);
    let rest = transcript.page("chat", 2, 10, false, 8);
    assert_eq!(rest["items"][0]["id"], 7);
    assert_eq!(rest["items"].as_array().unwrap().len(), 2);
    assert_eq!(rest["next_after"], 8);
    assert_eq!(rest["has_more"], false);
    assert!(!rest.to_string().contains("obsolete"));
    assert_eq!(transcript.text_bytes, "```sh\necho current\n```".len());
    assert_eq!(
        super::from_transcript(&transcript, false),
        Some(json!({"language": "sh", "code": "echo current"}))
    );
}
