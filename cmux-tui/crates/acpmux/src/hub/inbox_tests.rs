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
        notice: None,
        answered: None,
        thread: thread.to_owned(),
        from: from.to_owned(),
        from_session: None,
        class,
        report: false,
        at,
        text: text.to_owned(),
        details: None,
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
    // Multibyte text around the markers: the number after `#` or `pull/` is read on its own
    // char boundary.
    assert_eq!(thread_key(None, "lane-a", "合并 #42 完成"), "from:lane-a/pr:42");
    assert_eq!(thread_key(None, "lane-a", "見て pull/7"), "from:lane-a/pr:7");
    assert_eq!(thread_key(None, "lane-a", "末尾#"), "from:lane-a");
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
    assert!(plain_send(false, false, false, false, false));
    assert!(!plain_send(true, false, false, false, false), "a peer's or the relay's forward");
    assert!(!plain_send(false, true, false, false, false), "a team message");
    assert!(!plain_send(false, false, true, false, false), "a correction under a supersede key");
    assert!(!plain_send(false, false, false, true, false), "a steer-only send");
    assert!(!plain_send(false, false, false, false, true), "a cmux agent message");
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
    // Short: every message whole, and no instructions (the tools say what the inbox is).
    assert_eq!(lines[0], "[inbox] New messages from other agents in 3 threads.", "{text}");
    assert_eq!(
        lines[1],
        "- [blocker] 1 new in \"plan\" from lane-d: which branch? (thread topic:plan)"
    );
    assert_eq!(lines[2], "- 1 new in messages from lane-b: fyi (thread from:lane-b)");
    assert_eq!(lines[3], "- 2 new in #9 from lane-a, lane-c (thread pr:9):");
    assert_eq!(
        lines[4..],
        ["  > lane-a: first", "  >", &format!("  > lane-c: {}", "x".repeat(130)), "  > more"]
    );
    assert_eq!(
        parts[2],
        json!({
            "threadId": "pr:9", "label": "#9", "new": 2, "from": ["lane-a", "lane-c"],
            "promptIds": ["a1", "a2"], "blocker": false,
            "preview": format!("{}…", "x".repeat(120)), "newestAt": 3,
            "messages": [
                {"promptId": "a1", "from": "lane-a", "at": 1, "text": "first"},
                {"promptId": "a2", "from": "lane-c", "at": 3, "text": format!("{}\nmore", "x".repeat(130))},
            ],
        })
    );
    assert_eq!(parts[0]["blocker"], true);
    assert_eq!(parts[0]["label"], "\"plan\"");
}

#[test]
fn a_long_notice_has_previews_and_says_how_to_read_a_thread_from_any_harness() {
    let long = format!("landed\n{}", "y".repeat(WHOLE_BYTES));
    let mut sent = item("a1", "pr:9", "lane-a", PromptClass::Result, 1, &long);
    sent.from_session = Some("s-a".into());
    let items = [sent];
    let refs: Vec<&Item> = items.iter().collect();
    let (text, parts) = render(&refs);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(
        lines[0].starts_with("[inbox] New messages from other agents in 1 thread. Read one whole")
    );
    assert!(
        lines[0].contains("acpmux session inbox \"$ACPMUX_SESSION_ID\" --thread ID --mark-read"),
        "the shell form, for an agent with no inbox_read tool: {text}"
    );
    assert_eq!(lines[1], "- 1 new in #9 from lane-a: landed (thread pr:9)");
    assert_eq!(parts[0]["fromSession"], "s-a");
    assert_eq!(parts[0]["preview"], "landed");
    assert!(parts[0].get("messages").is_none(), "previews only: {}", parts[0]);
}

#[test]
fn a_whole_notice_keeps_every_message_as_it_was_sent() {
    let items = [
        item("a1", "pr:9", "lane-a", PromptClass::Result, 1, "   \n"),
        item("b1", "pr:7", "lane-b", PromptClass::Result, 2, "\n    let x = 1;\n    x\n\n"),
    ];
    let refs: Vec<&Item> = items.iter().collect();
    let (text, parts) = render(&refs);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(
        lines[1..],
        [
            "- 1 new in #7 from lane-b (thread pr:7):",
            "  >     let x = 1;",
            "  >     x",
            "- 1 new in #9 from lane-a (thread pr:9):",
            "  >",
        ],
        "a blank message keeps its line, an indented one its indent: {text}"
    );
    assert_eq!(parts[0]["messages"][0]["text"], "\n    let x = 1;\n    x\n\n");
    assert_eq!(parts[1]["messages"][0]["text"], "   \n");
    // The 4 KB counts the text as sent, blank lines and spaces too.
    let padded = format!("ok{}", " ".repeat(WHOLE_BYTES));
    let items = [item("c1", "pr:9", "lane-a", PromptClass::Result, 1, &padded)];
    let refs: Vec<&Item> = items.iter().collect();
    assert!(render(&refs).1[0].get("messages").is_none());
}

#[test]
fn class_aliases_name_the_inbox_kinds() {
    assert_eq!(PromptClass::parse("blocker"), Some(PromptClass::Block));
    assert_eq!(PromptClass::parse("action"), Some(PromptClass::Result));
    assert_eq!(kind_of(PromptClass::Question), "blocker");
    assert_eq!(kind_of(PromptClass::Result), "action");
    assert_eq!(kind_of(PromptClass::Fyi), "fyi");
}

#[test]
fn trim_lets_go_only_of_answered_read_messages_and_remembers_them() {
    let mut inbox = Inbox::default();
    for n in 0..KEEP + 3 {
        let mut i = item(&format!("m-{n}"), "from:a", "a", PromptClass::Result, n as u64, "x");
        (i.noticed, i.read) = (true, true);
        // The first two are answered; the third went in with no answer yet (its notice runs).
        if n < 2 {
            i.answered = Some(Ok(json!({"stopReason": "end_turn"})));
        }
        inbox.items.push(i);
    }
    trim(&mut inbox);
    assert_eq!(inbox.items.len(), KEEP + 1, "only the answered ones go");
    assert!(inbox.trimmed.contains("m-0") && inbox.trimmed.contains("m-1"));
    assert!(inbox.items.iter().any(|i| i.prompt_id == "m-2"));
}

#[test]
fn an_answered_record_keeps_an_answer_or_an_error() {
    let ok =
        json!({"noticePromptId": "n-1", "promptIds": ["a"], "answer": {"stopReason": "end_turn"}});
    let (notice, answer) = answered_record(&ok).unwrap();
    assert_eq!(
        (notice.as_str(), answer.unwrap()["stopReason"].clone()),
        ("n-1", json!("end_turn"))
    );
    let failed = RpcError::internal("the agent died");
    let err = json!({"noticePromptId": "n-2", "promptIds": ["b"], "error": failed});
    let (_, answer) = answered_record(&err).unwrap();
    assert_eq!(answer.unwrap_err().message, "the agent died");
}

/// An idle chat whose cut turn's automatic continuation may still fire (`auto_resume.rs`) does
/// not wake for its inbox: a turn of its own would supersede the continuation. The inbox is
/// looked at again on its timer, and goes in once nothing waits.
#[tokio::test]
async fn an_idle_chat_waits_for_its_cut_turns_continuation_before_its_inbox() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "inbox-wait",
        "name": "inbox-wait", "harness": "claude", "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve("inbox-wait").unwrap();
    let due = now_ms().saturating_sub(FLUSH_MS + 1);
    let blocked = item("p1", "t", "other", PromptClass::Block, due, "blocked on review");
    session.inbox.lock().unwrap().items.push(blocked);
    hub.set_ending_for_test(&session, Some("cut"));
    hub.inbox_review(&session);
    {
        let inbox = session.inbox.lock().unwrap();
        assert!(inbox.in_flight.is_none(), "no notice while the continuation may fire");
        assert!(inbox.timer.is_some(), "looked at again on its timer");
    }
    hub.set_ending_for_test(&session, None);
    hub.inbox_review(&session);
    assert!(session.inbox.lock().unwrap().in_flight.is_some(), "it goes in once nothing waits");
}

/// The inbox goes in as soon as a continuation can no longer fire, however it went: a turn's end
/// reviews the inbox while the turn is still marked ending (`take_turn`), which puts the wake
/// off; the settle that finds no continuation (`schedule_auto_resume`), or a Stop, lets the mark
/// go, and the timer looks again then instead of `REFUSED_RETRY_MS` on.
#[tokio::test]
async fn a_turn_that_ends_with_no_continuation_lets_the_inbox_in_at_once() {
    for stop in [false, true] {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": "inbox-ended",
            "name": "inbox-ended", "harness": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        hub.begin_startup(false);
        let session = hub.resolve("inbox-ended").unwrap();
        let due = now_ms().saturating_sub(FLUSH_MS + 1);
        let blocked = item("p1", "t", "other", PromptClass::Block, due, "blocked on review");
        session.inbox.lock().unwrap().items.push(blocked);
        // A notice went in, or was tried: a hub with no agent refuses it at once, so `in_flight`
        // alone may come and go between two looks (`notice_done`).
        let tried = |inbox: &Inbox| {
            inbox.in_flight.is_some()
                || inbox.refused_at != 0
                || inbox.items.iter().any(|i| i.noticed || i.answered.is_some())
        };
        // The turn's end, as `finish_turn` runs it: marked ending, then the inbox reviewed.
        hub.set_ending_for_test(&session, Some("t1"));
        hub.inbox_review(&session);
        assert!(!tried(&session.inbox.lock().unwrap()), "not while it may continue");
        if stop {
            hub.stop_auto_resume(&session);
        } else {
            // It ended well: no continuation.
            hub.schedule_auto_resume(&session, "t1", None);
        }
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while !tried(&session.inbox.lock().unwrap()) {
            assert!(tokio::time::Instant::now() < deadline, "held past the settle (stop: {stop})");
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }
}

/// Whether a notice's reader can open a thread comes from what its agent was given and what its
/// next spawn gets, both from memory: an agent a restart adopted (launch unknown here) that its
/// last daemon started with no `acpmux` server reads previews it cannot follow, whatever its
/// profile says now (router review of #28707).
#[tokio::test]
async fn a_notice_reader_has_tools_only_by_its_last_launch_and_its_next_spawn() {
    let row = |enabled: bool| {
        json!({"id": "mcp:acpmux", "name": "acpmux", "kind": "cmux", "source": "cmux",
            "enabled": enabled, "canToggle": true})
    };
    let cases = [
        ("launched with it", json!([row(true)]), json!({}), json!({}), true),
        ("launched without tools", json!([]), json!({}), json!({}), false),
        ("its server turned off", json!([row(false)]), json!({}), json!({}), false),
        (
            "spawns without tools",
            json!([row(true)]),
            json!({"ACPMUX_AGENT_TOOLS": "0"}),
            json!({}),
            false,
        ),
        (
            "spawns without its server",
            json!([row(true)]),
            json!({}),
            json!({"ACPMUX_AGENT_TOOL_SERVERS": "cmux,cmux-forum"}),
            false,
        ),
        // `${model}` is the chat's model, `0` (`modelRequest`), once the spawn expands it.
        (
            "its switch is a placeholder the spawn expands",
            json!([row(true)]),
            json!({"ACPMUX_AGENT_TOOLS": "${model}"}),
            json!({}),
            false,
        ),
        // No catalog profile: a folder profile, whose file a notice does not read.
        ("a folder profile", json!([row(true)]), json!({}), json!({}), false),
    ];
    for (case, rows, profile_env, session_env, has) in cases {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let profile = json!({"argv": ["true"], "env": profile_env});
        cfg.harnesses.insert("fake".into(), serde_json::from_value(profile).unwrap());
        let harness = if case == "a folder profile" { "folder-fake" } else { "fake" };
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": "inbox-reader",
            "name": "inbox-reader", "harness": harness, "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2, "tools": {"rows": rows}, "sessionEnv": session_env,
            "modelRequest": "0"});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        hub.begin_startup(false);
        let session = hub.resolve("inbox-reader").unwrap();
        assert_eq!(hub.notice_reader_has_tools(&session).await, has, "{case}");
    }
}

/// Only the person's own prompt makes a turn theirs (`persons_prompt`): never another agent's
/// message, nor acpmux's own prompts (a notice, a digest, the turn cap's notice, a subagent's
/// retry, a cut turn's continuation), whose turns take notices as before.
#[test]
fn only_the_persons_own_prompt_makes_a_turn_theirs() {
    assert!(persons_prompt(None, None));
    assert!(persons_prompt(None, Some(&json!({"kind": "something_else"}))));
    assert!(!persons_prompt(Some("lane-a"), None));
    let retry = super::super::subagent_retry::PROVENANCE_KIND;
    for kind in [NOTICE_KIND, "inbox_digest", "auto_resume", retry] {
        assert!(!persons_prompt(None, Some(&json!({"kind": kind}))), "{kind}");
    }
    let cap = json!({"kind": super::super::turn_cap::NOTICE_KIND});
    assert!(!persons_prompt(None, Some(&cap)), "{cap}");
}
