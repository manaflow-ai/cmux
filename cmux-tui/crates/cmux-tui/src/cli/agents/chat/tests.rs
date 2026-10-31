use super::{ChatCommand, MAX_EVENT_PAGES, Transcript, load, parse};
use serde_json::{Value, json};

fn update(seq: u64, update: Value) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update",
            "msg": {"method": "session/update", "params": {"update": update}}})
}

fn mux(seq: u64, kind: &str, msg: Value) -> Value {
    json!({"seq": seq, "dir": "mux", "kind": kind, "msg": msg})
}

fn transcript(events: &[Value]) -> Transcript {
    let mut transcript = Transcript::default();
    for event in events {
        transcript.apply(event);
    }
    transcript
}

/// An event source serving `events` one page of `per_page` at a time,
/// then, when `live`, one new answer chunk per request forever (a chat
/// still writing its turn); `loads` counts the requests.
fn source(
    events: Vec<Value>,
    per_page: usize,
    live: bool,
    loads: &mut usize,
) -> impl FnMut(u64) -> Result<Value, String> + '_ {
    move |cursor| {
        *loads += 1;
        let rest: Vec<Value> =
            events.iter().filter(|event| event["seq"].as_u64() > Some(cursor)).cloned().collect();
        if rest.is_empty() && live {
            let chunk = update(
                cursor + 1,
                json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "."}}),
            );
            return Ok(json!({"events": [chunk], "hasMore": true}));
        }
        let page: Vec<Value> = rest.iter().take(per_page).cloned().collect();
        Ok(json!({"events": page, "hasMore": live || rest.len() > per_page}))
    }
}

fn running_tool(seq: u64, id: &str) -> Value {
    update(
        seq,
        json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute", "status": "in_progress"}),
    )
}

fn chunk(seq: u64) -> Value {
    update(seq, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "."}}))
}

#[test]
fn a_read_of_a_live_turn_with_a_running_tool_stops_at_the_newest_event() {
    // The tool holds `next_after`, and its turn is still being written:
    // no turn end settles it yet, so the read stops where acpmux says
    // the log ends and holds `next_after` at the item before the tool.
    let mut events = vec![mux(1, "user_message", json!({"text": "run it"})), running_tool(2, "t1")];
    events.extend((3..=9).map(chunk));
    let mut loads = 0;
    let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
    assert_eq!(loads, 3);
    assert!(!more);
    let page = transcript.page("c", 0, 2, more, cursor);
    assert_eq!(page["items"][1]["partial"], true, "{page}");
    assert_eq!(page["next_after"], 1, "{page}");
    assert_eq!(page["has_more"], true);
}

#[test]
fn a_tool_whose_turn_ends_pages_past_a_full_read_still_settles_in_it() {
    // A harness that never finishes a tool call leaves its turn end to
    // settle it. Were the read to stop a few pages after it is full, a
    // turn end further on would never be read: every read restarts at
    // `after`, so `next_after` would stay at the tool for good.
    let mut events = vec![mux(1, "user_message", json!({"text": "run it"})), running_tool(2, "t1")];
    events.extend((3..=12).map(chunk));
    events.push(mux(13, "turn_result", json!({"status": "cancelled"})));
    let mut loads = 0;
    let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
    assert_eq!(loads, 5);
    assert!(loads < MAX_EVENT_PAGES);
    let page = transcript.page("c", 0, 2, more, cursor);
    assert_eq!(page["items"][1]["partial"], Value::Null, "{page}");
    assert_eq!(page["next_after"], 2, "{page}");
    assert_eq!(page["has_more"], true);
}

#[test]
fn a_running_tool_past_the_items_a_read_returns_does_not_extend_it() {
    let events = vec![
        mux(1, "user_message", json!({"text": "one"})),
        mux(2, "user_message", json!({"text": "two"})),
        running_tool(3, "t1"),
    ];
    let mut loads = 0;
    let (transcript, more, cursor) = load(0, 1, source(events, 3, true, &mut loads)).unwrap();
    assert_eq!(loads, 1);
    let page = transcript.page("c", 0, 1, more, cursor);
    assert_eq!(page["next_after"], 1, "{page}");
    assert_eq!(page["has_more"], true);
}

#[test]
fn a_read_loads_on_to_the_turn_end_that_settles_a_tool_it_returns() {
    let events = vec![
        mux(1, "user_message", json!({"text": "run it"})),
        running_tool(2, "t1"),
        update(3, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "a"}})),
        update(4, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "b"}})),
        mux(5, "turn_result", json!({"status": "cancelled"})),
    ];
    let mut loads = 0;
    let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
    assert_eq!(loads, 2);
    let page = transcript.page("c", 0, 2, more, cursor);
    assert_eq!(page["items"][1]["partial"], Value::Null, "{page}");
    assert_eq!(page["next_after"], 2, "{page}");
    assert_eq!(page["has_more"], true);
}

#[test]
fn a_tool_call_left_running_by_an_ended_turn_does_not_hold_the_read() {
    let mut events = vec![
        mux(1, "user_message", json!({"text": "run it"})),
        update(
            2,
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute", "status": "in_progress"}),
        ),
        mux(3, "turn_result", json!({"status": "cancelled"})),
    ];
    for seq in 4..10 {
        events.push(mux(seq, "user_message", json!({"text": format!("prompt {seq}")})));
    }
    let transcript = transcript(&events);
    let page = transcript.page("c", 1, 2, false, 9);
    assert_eq!(page["items"][0]["role"], "tool");
    assert_eq!(page["items"][0]["partial"], Value::Null);
    assert_eq!(page["next_after"], 3, "{page}");
    assert_eq!(page["has_more"], true);
}

#[test]
fn a_tool_call_in_a_running_turn_still_holds_the_read() {
    let events = vec![
        update(
            2,
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute", "status": "in_progress"}),
        ),
        update(
            3,
            json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "still going"}}),
        ),
        update(
            4,
            json!({"sessionUpdate": "tool_call", "toolCallId": "t2", "kind": "read", "status": "completed"}),
        ),
    ];
    let page = transcript(&events).page("c", 1, 10, false, 4);
    assert_eq!(page["items"][0]["partial"], true);
    assert_eq!(page["next_after"], 1, "{page}");
}

#[test]
fn only_agent_message_provenance_marks_a_prompt_as_another_agents() {
    let events = vec![
        mux(
            1,
            "user_message",
            json!({"text": "hi", "_meta": {"provenance": {"kind": "agent_message", "from": "chat-a", "fromName": "A", "msgId": "m1"}}}),
        ),
        mux(
            2,
            "user_message",
            json!({"text": "resume", "_meta": {"provenance": {"kind": "auto_resume", "promptId": "p", "attempt": 1, "turnId": "t"}}}),
        ),
        mux(
            3,
            "user_message",
            json!({"text": "result", "_meta": {"provenance": {"kind": "offer_result", "offerId": "o", "childSessionId": "c2", "title": "x"}}}),
        ),
    ];
    let page = transcript(&events).page("c", 0, 10, false, 3);
    let items = page["items"].as_array().unwrap();
    assert_eq!(items[0]["origin"], "agent_message");
    assert_eq!(items[0]["from"], "chat-a");
    assert_eq!(items[0]["from_name"], "A");
    assert_eq!(items[0]["message_id"], "m1");
    for item in &items[1..] {
        assert_eq!(item["origin"], Value::Null, "{item}");
        assert_eq!(item["from"], Value::Null, "{item}");
    }
}

#[test]
fn a_turn_of_agent_messages_names_its_senders() {
    let events = vec![mux(
        1,
        "user_message",
        json!({"text": "2 messages", "_meta": {"provenance": {"kind": "agent_digest", "messages": [{"promptId": "p1", "from": "lane-a"}, {"promptId": "p2", "from": "lane-b"}]}}}),
    )];
    let page = transcript(&events).page("c", 0, 10, false, 1);
    let item = &page["items"][0];
    assert_eq!(item["origin"], "agent_digest", "{item}");
    assert_eq!(item["senders"], json!(["lane-a", "lane-b"]), "{item}");
}

#[test]
fn a_read_masks_a_secret_split_across_chunks_and_holds_back_a_half_written_one() {
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let (head, tail) = key.split_at(9);
    let chunk = |seq, text: &str| {
        update(seq, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": text}}))
    };
    let mut events = vec![
        mux(
            1,
            "user_message",
            json!({"text": format!("use {key} now"),
                "_meta": {"provenance": {"kind": "agent_message", "from": "c1",
                                         "fromName": format!("bot {key}"), "msgId": "m1"}}}),
        ),
        chunk(2, &format!("set {head}")),
    ];
    // Still being written: the half of the key is not shown.
    let page = transcript(&events).page("c", 0, 10, false, 2);
    assert_eq!(page["items"][1]["partial"], true, "{page}");
    assert_eq!(page["items"][1]["text"], "set", "{page}");
    events.push(chunk(3, &format!("{tail} done")));
    events.push(mux(4, "turn_result", json!({"status": "completed"})));
    let page = transcript(&events).page("c", 0, 10, false, 4);
    assert!(!page.to_string().contains(head), "{page}");
    assert_eq!(page["items"][0]["text"], "use [AWS access key] now", "{page}");
    assert_eq!(page["items"][0]["from_name"], "bot [AWS access key]", "{page}");
    assert_eq!(page["items"][1]["text"], "set [AWS access key] done", "{page}");
}

#[test]
fn read_can_request_the_latest_complete_code_block() {
    let events = vec![
        mux(1, "user_message", json!({"text": "show code"})),
        update(
            2,
            json!({"sessionUpdate": "agent_message_chunk", "content": {"text":
                    "Here is one:\n```rust\nlet first = 1;\n```\nAnd the latest:\n```sh\necho latest\n```"}}),
        ),
        mux(3, "turn_result", json!({"status": "completed"})),
    ];
    let transcript = transcript(&events);
    assert_eq!(
        super::code_blocks::from_transcript(&transcript, false),
        Some(json!({"language": "sh", "code": "echo latest"}))
    );
}

#[test]
fn latest_code_block_is_secret_masked_and_incomplete_fences_are_ignored() {
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let events = vec![
        update(
            1,
            json!({"sessionUpdate": "agent_message_chunk", "content": {"text":
                    format!("```\nuse {key}\n```\n```rust\nunfinished")}}),
        ),
        mux(2, "turn_result", json!({"status": "completed"})),
    ];
    let transcript = transcript(&events);
    assert_eq!(
        super::code_blocks::from_transcript(&transcript, false),
        Some(json!({"language": "", "code": "use [AWS access key]"}))
    );
}

#[test]
fn read_parser_accepts_last_code_block_flag() {
    assert_eq!(
        parse(&["read", "chat-1", "--last-code-block"]),
        Ok(ChatCommand::Read {
            target: "chat-1".into(),
            after: 0,
            limit: super::DEFAULT_READ_LIMIT,
            code_block: true,
        })
    );
}
