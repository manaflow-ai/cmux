use super::*;

#[test]
fn a_recap_is_trimmed_and_capped_and_an_empty_one_is_none() {
    assert_eq!(clean("  Goal: x. Next: y.\n"), Some("Goal: x. Next: y.".to_owned()));
    assert_eq!(clean(" \n "), None);
    let long = "word ".repeat(200);
    let capped = clean(&long).unwrap();
    assert!(capped.ends_with('…'));
    assert!(capped.chars().count() <= MAX_CHARS + 1);
}

#[test]
fn an_older_settings_file_keeps_the_recap_on() {
    let old: crate::chats::ChatSettings =
        serde_json::from_str(r#"{"enabled": true, "discovery": false, "roots": []}"#).unwrap();
    assert!(old.session_recap);
    let off = crate::chats::ChatSettings::from_params(&json!({"sessionRecap": false})).unwrap();
    assert!(!off.session_recap);
    assert!(crate::chats::ChatSettings::from_params(&json!({})).unwrap().session_recap);
}

fn prompt(seq: u64, turn: &str, text: &str) -> crate::store::EventRecord {
    crate::store::EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": text, "promptId": format!("p-{turn}"), "turnId": turn}),
        host_seq: None,
    }
}

fn chunk(seq: u64, text: &str) -> crate::store::EventRecord {
    crate::store::EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "chat",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}),
        host_seq: None,
    }
}

fn turn_end(seq: u64, turn: &str) -> crate::store::EventRecord {
    crate::store::EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "turn_result".into(),
        msg: json!({"turnId": turn, "status": "completed"}),
        host_seq: None,
    }
}

#[test]
fn the_recent_turns_are_each_prompt_and_its_reply_text() {
    let records = vec![
        prompt(1, "t1", "make the parser tolerate missing fields"),
        chunk(2, "Reading "),
        chunk(3, "foo.rs."),
        turn_end(4, "t1"),
        prompt(5, "t2", "now add a test"),
        chunk(6, "Added the test."),
        turn_end(7, "t2"),
    ];
    assert_eq!(
        recent_said(&records),
        vec![
            Said::Prompt("make the parser tolerate missing fields".into()),
            Said::Reply("Reading foo.rs.".into()),
            Said::Prompt("now add a test".into()),
            Said::Reply("Added the test.".into()),
        ]
    );
    // A page that starts inside a reply begins with that reply.
    assert_eq!(recent_said(&records[2..4]), vec![Said::Reply("foo.rs.".into())]);
}

#[test]
fn the_recap_prompt_keeps_the_newest_turns_within_its_bound() {
    let said: Vec<Said> = (0..200)
        .flat_map(|n| {
            [
                Said::Prompt(format!("prompt {n} {}", "p".repeat(300))),
                Said::Reply(format!("{} reply {n}", "r".repeat(300))),
            ]
        })
        .collect();
    let max = crate::complete::MAX_PROMPT_BYTES;
    let prompt = recap_prompt(&said, max).unwrap();
    assert!(prompt.len() <= max, "{} bytes", prompt.len());
    assert!(prompt.starts_with(INSTRUCTION));
    assert!(prompt.contains("reply 199"), "the newest reply is kept");
    assert!(prompt.contains("prompt 199"), "the newest prompt is kept");
    assert!(!prompt.contains("prompt 0 "), "the oldest turns are left out");
    // Oldest first, as the turns ran.
    assert!(prompt.find("prompt 198").unwrap() < prompt.find("prompt 199").unwrap());
}

#[test]
fn one_long_line_is_cut_and_never_crowds_out_the_rest() {
    let said = vec![
        Said::Prompt(format!("fix the build {}", "x".repeat(20_000))),
        Said::Reply(format!("{} Next I will rerun the tests.", "y".repeat(20_000))),
    ];
    let prompt = recap_prompt(&said, crate::complete::MAX_PROMPT_BYTES).unwrap();
    assert!(prompt.len() <= crate::complete::MAX_PROMPT_BYTES);
    assert!(prompt.contains("Person: fix the build"), "a prompt keeps its start");
    assert!(prompt.contains("Next I will rerun the tests."), "a reply keeps its end");
    // A multi-byte character is never split.
    let wide = vec![Said::Reply("é".repeat(5_000))];
    let prompt = recap_prompt(&wide, crate::complete::MAX_PROMPT_BYTES).unwrap();
    assert!(prompt.len() <= crate::complete::MAX_PROMPT_BYTES);
}

#[test]
fn nothing_to_read_makes_no_prompt() {
    assert_eq!(recap_prompt(&[], crate::complete::MAX_PROMPT_BYTES), None);
    assert_eq!(recap_prompt(&[Said::Prompt("hi".into())], 10), None);
}

fn message(seq: u64, id: &str, text: &str) -> crate::store::EventRecord {
    crate::store::EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "chat",
            "update": {"sessionUpdate": "agent_message_chunk", "messageId": id,
                       "content": {"type": "text", "text": text}}}}),
        host_seq: None,
    }
}

#[test]
fn a_reply_the_harness_abandoned_after_a_steer_is_not_read() {
    // A prompt, a steer while its reply streams, then the harness retries (`stream.rs`
    // `message_superseded`): the abandoned reply is hidden from the recap as in the transcript.
    let superseded = crate::store::EventRecord {
        seq: 5,
        at: 5,
        dir: "mux".into(),
        kind: "message_superseded".into(),
        msg: json!({"oldMessageId": "m1", "newMessageId": "m2", "reason": "harness_retry"}),
        host_seq: None,
    };
    let records = vec![
        prompt(1, "t1", "make the parser tolerate missing fields"),
        message(2, "m1", "Half an answer that was abandoned"),
        prompt(3, "t1", "and keep the old format working"),
        message(4, "m1", " and more of it"),
        superseded,
        message(6, "m2", "Both formats parse now."),
        turn_end(7, "t1"),
        // A record the recap does not read.
        crate::store::EventRecord {
            seq: 8,
            at: 8,
            dir: "mux".into(),
            kind: "cost".into(),
            msg: json!({}),
            host_seq: None,
        },
    ];
    // What `read_recent` reads: its kinds only.
    let read: Vec<_> =
        records.into_iter().filter(|r| READ_KINDS.contains(&r.kind.as_str())).collect();
    let said = recent_said(&read);
    assert!(
        !said.iter().any(|s| matches!(s, Said::Reply(t) if t.contains("abandoned"))),
        "{said:?}"
    );
    assert_eq!(said.last(), Some(&Said::Reply("Both formats parse now.".into())), "{said:?}");
}

#[test]
fn the_recap_walks_back_only_its_scan_budget_of_records() {
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["true"]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let filler = |seq: u64| crate::store::EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "cost".into(),
        msg: json!({}),
        host_seq: None,
    };
    let mut records =
        vec![prompt(1, "t1", "an old prompt"), chunk(2, "An old reply."), turn_end(3, "t1")];
    records.extend((4..=103).map(filler));
    records.extend([
        prompt(104, "t2", "the newest prompt"),
        chunk(105, "The newest reply."),
        turn_end(106, "t2"),
    ]);
    for record in &records {
        hub.store.append("chat", record).unwrap();
    }
    // Within a budget of 10 records: the newest turn only, never a walk back to the first.
    assert_eq!(
        read_recent(&hub, "chat", 106, 10),
        vec![Said::Prompt("the newest prompt".into()), Said::Reply("The newest reply.".into())]
    );
    // A budget past the log's start reads it all.
    assert_eq!(read_recent(&hub, "chat", 106, 1000).len(), 4);
}
