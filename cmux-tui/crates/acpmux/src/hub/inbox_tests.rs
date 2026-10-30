//! The inbox's pure parts (`inbox.rs`): threads, what it takes, what wakes a chat, the notice.

use super::*;

fn item(
    prompt_id: &str,
    thread: &str,
    from: &str,
    class: PromptClass,
    at: u64,
    text: &str,
) -> Item {
    Item {
        prompt_id: prompt_id.to_owned(),
        thread: thread.to_owned(),
        from: from.to_owned(),
        from_session: None,
        class,
        report: false,
        at,
        text: text.to_owned(),
        noticed: false,
        read: false,
        answer: None,
    }
}

#[test]
fn a_thread_is_the_senders_pr_or_topic_else_the_pr_its_first_line_names_else_the_sender() {
    assert_eq!(thread_key(Some("pr:12"), "lane-a", "anything"), "pr:12");
    assert_eq!(thread_key(None, "lane-a", "merged #27133 at last\nsee #1"), "from:lane-a/pr:27133");
    let link = "https://github.com/manaflow-ai/cmux/pull/27520 is green";
    assert_eq!(thread_key(None, "lane-a", link), "from:lane-a/pr:27520");
    assert_eq!(thread_key(None, "lane-a", "no number here\n#5 below"), "from:lane-a");
    assert_eq!(thread_key(None, "lane-a", "#0 is nothing"), "from:lane-a");
}

#[test]
fn an_explicit_thread_is_a_pr_number_or_a_one_line_topic() {
    let of = |v: Value| explicit_thread(Some(&v));
    assert_eq!(of(json!({"pr": 12})).unwrap().as_deref(), Some("pr:12"));
    assert_eq!(of(json!({"pr": "#12"})).unwrap().as_deref(), Some("pr:12"));
    assert_eq!(of(json!({"topic": "plan"})).unwrap().as_deref(), Some("topic:plan"));
    // A threadId the receiver's inbox named is that thread.
    assert_eq!(
        of(json!({"topic": "from:lane-a/pr:3"})).unwrap().as_deref(),
        Some("from:lane-a/pr:3")
    );
    assert_eq!(of(json!({})).unwrap(), None);
    for bad in [json!({"pr": 0}), json!({"pr": "x"}), json!({"topic": "a\nb"}), json!({"topic": 3})]
    {
        let e = of(bad.clone()).unwrap_err();
        assert_eq!(e.data.as_ref().unwrap()["reason"], "thread.value_refused", "{bad}");
    }
}

#[test]
fn the_inbox_takes_another_agents_text_only() {
    let text = [json!({"type": "text", "text": "merged"})];
    assert!(takes(true, false, Control::Local, &text, None));
    assert!(!takes(false, false, Control::Local, &text, None), "the person's own");
    assert!(!takes(true, true, Control::Local, &text, None), "sent now");
    assert!(!takes(true, false, Control::Web, &text, None), "a Web one");
    let image = [json!({"type": "image", "mimeType": "image/png", "data": ""})];
    assert!(!takes(true, false, Control::Local, &image, None));
    let hidden = [json!({"type": "text", "text": "x", "_meta": {"hidden": true}})];
    assert!(!takes(true, false, Control::Local, &hidden, None));
    let slash = [json!({"type": "text", "text": "/compact"})];
    assert!(!takes(true, false, Control::Local, &slash, None));
    let notice = json!({"kind": NOTICE_KIND});
    assert!(!takes(true, false, Control::Local, &text, Some(&notice)));
}

#[test]
fn only_a_plain_send_from_this_host_goes_to_the_inbox() {
    assert!(plain_send(false, false, false, false));
    assert!(!plain_send(true, false, false, false), "a peer's or the relay's forward");
    assert!(!plain_send(false, true, false, false), "a team message");
    assert!(!plain_send(false, false, true, false), "a correction under a supersede key");
    assert!(!plain_send(false, false, false, true), "a steer-only send");
    assert!(plain_kind(None));
    assert!(plain_kind(Some(&json!({"kind": "session_message"}))));
    assert!(plain_kind(Some(&json!({"kind": "agent_message"}))));
    for kind in ["lane_report", "task_result", "offer_result", "agent_digest"] {
        assert!(!plain_kind(Some(&json!({"kind": kind}))), "{kind}");
    }
}

#[test]
fn blockers_wake_any_chat_actions_only_from_its_parent_or_delegator_and_fyis_never() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "lane", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    meta.turn_count = 3;
    let from = |class, session: Option<&str>| {
        let mut i = item("p", "t", "x", class, 0, "");
        i.from_session = session.map(str::to_owned);
        i
    };
    let (block, question) = (from(PromptClass::Block, None), from(PromptClass::Question, None));
    assert!(wakes(&meta, &block) && wakes(&meta, &question));
    assert!(!wakes(&meta, &from(PromptClass::Fyi, Some("parent"))));
    let stranger = from(PromptClass::Result, Some("other"));
    assert!(!wakes(&meta, &stranger));
    meta.delegator = Some("other".into());
    assert!(wakes(&meta, &stranger), "its delegator");
    meta.delegator = None;
    let mut report = from(PromptClass::Result, Some("child"));
    report.report = true;
    assert!(wakes(&meta, &report), "a report of work it gave");
    meta.lineage = Some(crate::store::Lineage {
        parent: "parent".into(),
        root: "parent".into(),
        depth: 1,
        tool_call_id: None,
    });
    assert!(wakes(&meta, &from(PromptClass::Result, Some("parent"))), "its parent");
    meta.delegator = None;
    meta.turn_count = 0;
    assert!(wakes(&meta, &from(PromptClass::Result, None)), "a chat's first work");
}

#[test]
fn a_notice_is_one_line_per_thread_blockers_first_then_the_newest() {
    let items = [
        item("a1", "pr:9", "lane-a", PromptClass::Result, 1, "first"),
        item("b1", "from:lane-b", "lane-b", PromptClass::Fyi, 5, "fyi"),
        item("a2", "pr:9", "lane-c", PromptClass::Result, 3, &format!("{}\nmore", "x".repeat(130))),
        item("q1", "topic:plan", "lane-d", PromptClass::Question, 2, "which branch?"),
    ];
    let refs: Vec<&Item> = items.iter().collect();
    let (text, parts) = render(&refs);
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].starts_with("[inbox] New messages from other agents in 3 threads."), "{text}");
    assert_eq!(
        lines[1],
        "- [blocker] 1 new in \"plan\" from lane-d: which branch? (thread topic:plan)"
    );
    assert_eq!(lines[2], "- 1 new in messages from lane-b: fyi (thread from:lane-b)");
    assert_eq!(
        lines[3],
        format!("- 2 new in #9 from lane-a, lane-c: {}… (thread pr:9)", "x".repeat(120))
    );
    assert_eq!(
        parts[2],
        json!({"threadId": "pr:9", "new": 2, "from": ["lane-a", "lane-c"], "promptIds": ["a1", "a2"]})
    );
}

#[test]
fn class_aliases_name_the_inbox_kinds() {
    assert_eq!(PromptClass::parse("blocker"), Some(PromptClass::Block));
    assert_eq!(PromptClass::parse("action"), Some(PromptClass::Result));
    assert_eq!(kind_of(PromptClass::Question), "blocker");
    assert_eq!(kind_of(PromptClass::Result), "action");
    assert_eq!(kind_of(PromptClass::Fyi), "fyi");
}
