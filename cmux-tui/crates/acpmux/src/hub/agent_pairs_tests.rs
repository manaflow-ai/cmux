//! Unit tests of `agent_pairs.rs`: message likeness, settings, what counts as progress, and
//! what a restart finds still held.

use super::*;

#[test]
fn a_rendered_message_compares_by_its_body() {
    let text = "[cmux agent message] from builder (acp:a)\nMessage id: m-1\nNote\n---\nPlease check the build\n--- end of message m-1 ---";
    assert_eq!(message_body(text), "Please check the build");
    assert_eq!(message_body("plain text"), "plain text");
}

#[test]
fn near_identical_ignores_case_digits_and_spacing() {
    let a = words("Please  check the BUILD, run 1");
    let b = words("please check the build run 22");
    assert!(similarity(&a, &b) >= 0.9);
    let c = words("the build is green, merging now");
    assert!(similarity(&a, &c) < 0.9);
}

#[test]
fn settings_come_from_the_environment() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |k: &str| pairs.iter().find(|(key, _)| *key == k).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(PairGuard::from_env(env(&[])), PairGuard::default());
    let off = PairGuard::from_env(env(&[(GUARD_ENV, "0")]));
    assert!(!off.enabled);
    let tuned = PairGuard::from_env(env(&[
        (ALTERNATIONS_ENV, "10"),
        (REPEATS_ENV, "1"),
        (SIMILARITY_ENV, "80"),
    ]));
    assert_eq!((tuned.alternations, tuned.repeats), (10, 3));
    assert!((tuned.similarity - 0.8).abs() < f64::EPSILON);
    assert_eq!((tuned.max_messages, tuned.window.as_secs()), (20, 600));
    let uncapped = PairGuard::from_env(env(&[(MAX_MESSAGES_ENV, "0"), (WINDOW_ENV, "60")]));
    assert_eq!((uncapped.max_messages, uncapped.window.as_secs()), (0, 60));
    assert!(!uncapped.capped());
}

#[test]
fn messaging_calls_are_not_progress() {
    let rec = |update: Value| EventRecord {
        seq: 1,
        at: 0,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"update": update}}),
        host_seq: None,
    };
    assert!(!progress_record(&rec(json!({"title": "mcp__cmux-subsessions__send_message"}))));
    assert!(!progress_record(&rec(
        json!({"title": "Bash", "rawInput": {"command": "cmux agent message acp:b hi"}})
    )));
    assert!(progress_record(&rec(json!({"title": "Edit notes.md", "kind": "edit"}))));
    assert!(!progress_record(&rec(json!({"title": "Tool: cmux-subsessions/send_message"}))));
    assert!(!progress_record(&rec(
        json!({"title": "Shell", "rawInput": {"command": ["bash", "-lc", "cmux agent inbox"]}})
    )));
}

#[test]
fn subsession_and_chat_tools_are_not_progress_but_starting_one_is() {
    let rec = |title: &str| EventRecord {
        seq: 1,
        at: 0,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"update": {"title": title}}}),
        host_seq: None,
    };
    for title in [
        "mcp__cmux-subsessions__send_message",
        "mcp__cmux-subsessions__wait_for_sessions",
        "mcp__cmux-subsessions__get_session",
        "mcp__cmux-subsessions__list_sessions",
        "mcp__cmux-subsessions__stop_session",
        "mcp__cmux-subsessions__set_session_limits",
        "cmux-subsessions.send_message",
        "send_message",
        "wait_for_sessions",
        "mcp__cmux__agents_chat_send",
        "agents_chat_read",
    ] {
        assert!(!progress_record(&rec(title)), "{title} is messaging, not progress");
    }
    // Starting a sub-session hands work off; another server's tool of the same name is work.
    for title in
        ["mcp__cmux-subsessions__start_session", "mcp__slack__send_message", "github.list_sessions"]
    {
        assert!(progress_record(&rec(title)), "{title} is progress");
    }
}

/// A restart rebuilds what is still owed: a held message a cut-short resume never delivered
/// stays held; one that reached the session, or was dropped, does not.
#[test]
fn a_restart_holds_only_what_never_reached_the_session() {
    let rec = |kind: &str, msg: Value| EventRecord {
        seq: 1,
        at: 0,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    let held = |id: &str| {
        rec(
            "agent_pair_held",
            json!({"from": "a", "to": "b", "promptId": id, "client": "acpmux",
                   "prompt": [{"type": "text", "text": id}],
                   "provenance": {"kind": "subsession_message", "from": "a", "to": "b"},
                   "interrupt": id == "h3"}),
        )
    };
    let records = vec![
        held("h1"),
        held("h2"),
        held("h3"),
        held("h4"),
        rec("agent_pair_dropped", json!({"peer": "a", "promptId": "h2"})),
        held("h5"),
        rec("agent_pair_released", json!({"peer": "a", "promptId": "h5"})),
    ];
    let recorded: HashSet<String> = ["h1".to_owned()].into();
    let owed = still_held("b", records, &recorded);
    let ids: Vec<&str> = owed.held.iter().map(|h| h.prompt_id.as_str()).collect();
    assert_eq!(ids, ["h3", "h4"]);
    assert!(owed.held[0].interrupt, "the flags come back as sent");
    assert!(owed.resumed.is_empty(), "never resumed: still paused");
    assert!(still_held("b", vec![held("h1")], &recorded).held.is_empty());
    // A resume, then a hold while it delivered: still the resume's to deliver. A new pause
    // after it (a release that failed, or the pair tripping again) is paused again.
    let resumed = rec("agent_pair_resumed", json!({"peer": "a", "by": "request"}));
    let paused = rec("agent_pair_paused", json!({"peer": "a", "reason": "release_failed"}));
    let owed = still_held("b", vec![held("h3"), resumed.clone(), held("h4")], &recorded);
    assert!(owed.resumed.contains("a"));
    assert_eq!(owed.held.len(), 2);
    let owed = still_held("b", vec![held("h3"), resumed, paused, held("h4")], &recorded);
    assert!(owed.resumed.is_empty());
}

#[test]
fn only_a_whole_messaging_call_is_not_progress() {
    let rec = |update: Value| EventRecord {
        seq: 1,
        at: 0,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"update": update}}),
        host_seq: None,
    };
    // An edit of a file that mentions a messaging tool is an edit.
    assert!(progress_record(&rec(json!({"title": "Edit send_message.rs", "kind": "edit"}))));
    // A command that also runs something else is work.
    assert!(progress_record(&rec(json!({"title": "Bash",
        "rawInput": {"command": "cargo test && cmux agent message acp:b done"}}))));
    assert!(progress_record(&rec(json!({"title": "Bash",
        "rawInput": {"command": "grep -r 'cmux agent message' docs"}}))));
    // Punctuation inside the quoted message is the message's.
    for quoted in [
        "cmux agent message acp:b 'ready; waiting'",
        "cmux agent message acp:b \"done && green | ok\"",
        "cmux agent message acp:b ready\\;\\ waiting",
    ] {
        assert!(
            !progress_record(&rec(json!({"title": "Bash", "rawInput": {"command": quoted}}))),
            "{quoted}"
        );
    }
    assert!(progress_record(&rec(json!({"title": "Bash",
        "rawInput": {"command": "cmux agent message acp:b \"$(make deploy)\""}}))));
    assert!(progress_record(&rec(json!({"title": "Bash",
        "rawInput": {"command": "cmux agent message acp:b 'a' ; make"}}))));
}

/// A held message keeps its class (`prompt_class.rs`) in its record, so a restart releases it as
/// what it was; a record from before classes has none (its release reads it as a result).
#[test]
fn a_held_message_keeps_its_class_across_its_record() {
    let held = Held {
        from: "a".into(),
        to: "b".into(),
        blocks: vec![json!({"type": "text", "text": "stuck"})],
        client: "acpmux".into(),
        steer: true,
        steer_only: false,
        interrupt: false,
        prompt_id: "p-1".into(),
        provenance: json!({"kind": "session_message", "from": "a", "fromName": "lane", "to": "b"}),
        control: Control::Local,
        trust_gate: false,
        class: Some(crate::prompt_class::PromptClass::Block),
        order: 3,
        failures: 0,
    };
    let record = held.record("lane");
    assert_eq!(record["class"], "block");
    let back = Held::from_record("b", &record).expect("a held record reads back");
    assert_eq!(back.class, Some(crate::prompt_class::PromptClass::Block));
    let mut old = record.clone();
    old.as_object_mut().unwrap().remove("class");
    assert_eq!(Held::from_record("b", &old).unwrap().class, None);
}
