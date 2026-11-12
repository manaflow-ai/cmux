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
