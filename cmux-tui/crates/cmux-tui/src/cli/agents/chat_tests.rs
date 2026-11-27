use super::{MAX_EVENT_PAGES, Transcript, load, sender_name_of, shown_in_workspace};
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

/// manaflow-ai/cmux#51004: a Chief turn's send names the Chief (its `mux.label`), never its
/// session name (`optchat-<home>-<n>`); any other chat names itself; a name is one line of at
/// most 64 characters, and a chat with no shown name names none.
#[test]
fn a_chat_send_names_the_chief_or_the_sending_chat() {
    let chief = json!({"name": "optchat-b902d10e-10474",
                       "tags": {"mux.label": "Chief", "cmux.chief.participant": "agent_mux"}});
    assert_eq!(sender_name_of(&chief).as_deref(), Some("Chief"));
    let lane = json!({"name": "45953: Cloud first-token speed", "tags": {}});
    assert_eq!(sender_name_of(&lane).as_deref(), Some("45953: Cloud first-token speed"));
    let messy = json!({"name": "x", "tags": {"mux.label": "  Night\nshift\u{200B}  Chief "}});
    assert_eq!(sender_name_of(&messy).as_deref(), Some("Night shift Chief"));
    let long = json!({"name": "n".repeat(100)});
    assert_eq!(sender_name_of(&long).map(|name| name.chars().count()), Some(64));
    assert_eq!(sender_name_of(&json!({"name": "  ", "tags": {"mux.label": ""}})), None);
    assert_eq!(sender_name_of(&json!({})), None);
}

/// `cmux chat --wait`'s reads after its wait (the wait, the turn's start, the turn) reach acpmux
/// on one connection: before, each built a runtime and dialed again, hello and all.
#[cfg(unix)]
#[test]
fn reads_of_one_acpmux_share_one_connection() {
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let accepted = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(AtomicUsize::new(0));
    {
        let (accepted, requests) = (accepted.clone(), requests.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                accepted.fetch_add(1, Ordering::SeqCst);
                let requests = requests.clone();
                std::thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { return };
                        let request: Value = serde_json::from_str(&line).unwrap();
                        requests.fetch_add(1, Ordering::SeqCst);
                        let result = match request["method"].as_str() {
                            Some("_acpmux/wait") => json!({"sessions": [{"status": "ready"}],
                                "resolved": [{"status": "ready"}], "timedOut": false}),
                            Some("_acpmux/events") => json!({"events": [], "hasMore": false}),
                            _ => json!({}),
                        };
                        let answer =
                            json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                        writeln!(writer, "{answer}").unwrap();
                    }
                });
            }
        });
    }
    let socket = Some(path.as_path());
    let waited = super::acp::wait_turn("chat", std::time::Duration::from_secs(5), socket).unwrap();
    assert_eq!(waited["timedOut"], false);
    super::acp::events_before("chat", u64::MAX, 1000, socket).unwrap();
    super::acp::events("chat", 0, 100, socket).unwrap();
    super::acp::events("chat", 1, 100, socket).unwrap();
    assert_eq!(accepted.load(Ordering::SeqCst), 1, "one connection for every read");
    // The hello, then one request per read.
    assert_eq!(requests.load(Ordering::SeqCst), 5);
}

/// A chat brought back from a Cloud machine runs with no workspace in its env (the move clears
/// it); the app's tab for it in a workspace of this session puts it in scope (probe
/// cloud-session-move-to-local-production, chat.out_of_scope). A tab in another session's
/// workspace, or a tab of another chat, does not.
#[test]
fn a_chat_a_tab_of_this_session_shows_is_in_scope() {
    let chat = "01a218d8-3400-74e8-bd76-510a00992eb2";
    let other = "01a218d8-1111-7000-8000-000000000000";
    let snapshot = json!({"workspaces": [{"id": "ws_ours", "extra": {"key": "k1"}}]});
    let topology = json!({"workspaces": [
        {"id": "ws_ours", "panes": [{"tabs": [
            {"id": "tab-moved", "kind": "conversation", "agent_session": format!("acp:{chat}")},
        ]}]},
        {"id": "ws_theirs", "panes": [{"tabs": [
            {"id": "tab-elsewhere", "kind": "conversation", "agent_session": other},
        ]}]},
    ]});
    assert!(shown_in_workspace(&snapshot, &topology, chat));
    assert!(!shown_in_workspace(&snapshot, &topology, other));
    assert!(!shown_in_workspace(&json!({"workspaces": []}), &topology, chat));
    assert!(!shown_in_workspace(&snapshot, &json!({}), chat));
}
