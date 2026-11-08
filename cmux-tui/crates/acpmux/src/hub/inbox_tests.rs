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
        sender: Value::Null,
        class,
        report: false,
        at,
        text: text.to_owned(),
        details: None,
        tool_notice: None,
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
fn a_self_declared_label_has_a_distinct_thread_key_and_display() {
    let provenance = crate::prompt_provenance::named_sender("dot", "target");
    assert_eq!(thread_sender(Some(&provenance), "dot"), "declared:dot");
    assert_eq!(thread_key(None, "declared:dot", "hello"), "declared:dot");
    let sender = crate::prompt_provenance::sender_record(Some(&provenance), None, None);
    assert_eq!(display_sender(&sender, "dot"), "dot (self-declared, unauthenticated)");
    assert_eq!(label("declared:dot"), "dot (self-declared, unauthenticated)");
    assert_eq!(legacy_thread_key(Some(&provenance), "dot", "from:dot".into()), "declared:dot");
    assert_eq!(
        legacy_thread_key(Some(&provenance), "dot", "from:dot/pr:7".into()),
        "declared:dot/pr:7"
    );
    let mut old = item("old", "declared:dot", "dot", PromptClass::Result, 1, "hello");
    assert!(thread_matches(&old, "from:dot", true));
    old.thread = "from:other".into();
    assert!(!thread_matches(&old, "from:dot", true));
    let authenticated = crate::prompt_provenance::stamp_declared(
        crate::prompt_provenance::stamp_sender(
            crate::prompt_provenance::session_message("dot", "dot", "target"),
            Some(&crate::prompt_provenance::BoundSender {
                session_id: Some("dot".into()),
                harness: Some("codex".into()),
                relay: None,
            }),
        ),
        Some("other"),
    );
    assert_eq!(thread_sender(Some(&authenticated), "dot"), "dot");
    assert_eq!(thread_key(None, "dot", "hello"), "from:dot");
}

#[test]
fn an_authenticated_session_named_declared_does_not_collide_with_a_declared_label() {
    assert_eq!(thread_key(None, "declared:dot", "hello"), "declared:dot");
    assert_eq!(thread_key(None, "session:declared:dot", "hello"), "from:declared:dot");
    assert_eq!(thread_key(None, &thread_sender(None, "session:dot"), "hello"), "from:session:dot");
}

#[test]
fn an_authenticated_message_and_reply_keep_name_threads_on_each_side() {
    let authenticated = crate::prompt_provenance::stamp_sender(
        crate::prompt_provenance::session_message("dot-session", "dot", "target"),
        Some(&crate::prompt_provenance::BoundSender {
            session_id: Some("dot-session".into()),
            harness: Some("codex".into()),
            relay: None,
        }),
    );
    let sender = thread_sender(Some(&authenticated), "dot");
    let incoming = thread_key(None, &sender, "hello");
    assert_eq!(incoming, "from:dot");
    // `inbox_reply` uses this key for the message placed in the original sender's inbox.
    assert_eq!(reply_thread_key(&incoming, "target"), "from:target");
    assert_eq!(thread_key(None, "target", "reply"), "from:target");
}

#[test]
fn an_old_from_key_falls_back_only_when_no_exact_session_thread_exists() {
    let declared = item("declared", "declared:dot", "dot", PromptClass::Result, 1, "old");
    assert!(thread_matches(&declared, "from:dot", true));
    assert!(!thread_matches(&declared, "from:dot", false));
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

/// A tool's notice in the inbox (`prompt_provenance::notice`) keeps its structure in the notice's
/// thread parts, and a thread says its loudest severity, so a fold never hides a fire.
#[test]
fn a_tools_notice_keeps_its_structure_in_the_inbox_notice() {
    let notice =
        |severity: &str| json!({"sender": "base-red-watch", "severity": severity, "title": "t"});
    let mut warn = item("n1", "from:base-red-watch", "base-red-watch", PromptClass::Result, 1, "w");
    warn.tool_notice = Some(notice("warn"));
    let mut fire = item("n2", "from:base-red-watch", "base-red-watch", PromptClass::Result, 2, "f");
    fire.tool_notice = Some(notice("fire"));
    let plain = item("m1", "from:lane-a", "lane-a", PromptClass::Result, 3, "merged");
    let items = [warn, fire, plain];
    let refs: Vec<&Item> = items.iter().collect();
    let (_, parts) = render(&refs);
    let thread =
        |key: &str| parts.as_array().unwrap().iter().find(|p| p["threadId"] == key).unwrap();
    let notices = thread("from:base-red-watch");
    assert_eq!(notices["severity"], "fire", "{notices}");
    assert_eq!(notices["messages"][0]["notice"], notice("warn"));
    assert_eq!(notices["messages"][1]["notice"], notice("fire"));
    let messages = thread("from:lane-a");
    assert!(messages.get("severity").is_none(), "{messages}");
    assert!(messages["messages"][0].get("notice").is_none(), "{messages}");
    // A notice's provenance is a plain message from another agent: it joins the inbox.
    assert!(plain_kind(Some(&crate::prompt_provenance::notice(&notice("info"), "s"))));
    assert_eq!(
        tool_notice_of(Some(&crate::prompt_provenance::notice(&notice("info"), "s"))),
        Some(notice("info"))
    );
    assert_eq!(tool_notice_of(Some(&json!({"kind": "agent_message", "notice": {}}))), None);
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

/// A hub with one idle chat `id` that ran turns before, its store in memory and no agent.
fn hub_with_chat(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(id).unwrap();
    (hub, session)
}

/// The chat runs another agent's turn (not the person's) that takes steers.
fn running(session: &Session) {
    let turn = TurnInfo::prompted("test", "go", "t-run", "p-run", Control::Local);
    *session.turn.lock().unwrap() = Some(turn);
    session.steering.store(true, Ordering::SeqCst);
}

/// The ids the notice in flight carries, sorted; none when no notice went.
fn carried(session: &Session) -> Option<Vec<String>> {
    let inbox = session.inbox.lock().unwrap();
    inbox.in_flight.as_ref().map(|(_, ids)| {
        let mut ids = ids.clone();
        ids.sort();
        ids
    })
}

/// FYIs alone never interrupt a running turn: no steer before their flush, only the timer for it
/// (Leo, 2026-11-08, of tool notices sent as FYIs: "Once an hour is extremely infrequent in the
/// grand scheme of things"). Once the oldest is `FLUSH_MS` old they steer in, so none is
/// stranded.
#[tokio::test]
async fn fyis_alone_steer_into_a_running_turn_only_at_their_flush() {
    let (hub, session) = hub_with_chat("fyi-steer");
    running(&session);
    let fresh = item("f1", "t", "ci", PromptClass::Fyi, now_ms(), "CI is slow");
    session.inbox.lock().unwrap().items.push(fresh);
    hub.inbox_review(&session);
    assert_eq!(carried(&session), None, "no steer before the flush");
    {
        let inbox = session.inbox.lock().unwrap();
        assert!(inbox.timer.is_some(), "the flush is timed");
        assert!(inbox.items.iter().all(|i| !i.noticed), "it waits, new");
    }

    // The flush's deadline: the timer's review steers it in.
    session.inbox.lock().unwrap().items[0].at = now_ms().saturating_sub(FLUSH_MS + 1);
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["f1".to_owned()]), "steered in at its flush");
    assert!(session.inbox.lock().unwrap().timer.is_none(), "the delivery ends the timer");
}

/// A message that is no FYI steers into the running turn at once, and carries the FYIs that
/// waited for it in the same notice.
#[tokio::test]
async fn a_message_that_is_no_fyi_steers_in_and_carries_the_waiting_fyis() {
    for class in [PromptClass::Result, PromptClass::Question, PromptClass::Block] {
        let (hub, session) = hub_with_chat("fyi-carried");
        running(&session);
        let fyi = item("f1", "t", "ci", PromptClass::Fyi, now_ms(), "CI is slow");
        session.inbox.lock().unwrap().items.push(fyi);
        hub.inbox_review(&session);
        assert_eq!(carried(&session), None, "the FYI waits ({class:?})");
        let other = item("r1", "t2", "lane-b", class, now_ms(), "done with #9");
        session.inbox.lock().unwrap().items.push(other);
        hub.inbox_review(&session);
        let both = Some(vec!["f1".to_owned(), "r1".to_owned()]);
        assert_eq!(carried(&session), both, "one steer carries both ({class:?})");
    }
}

/// FYIs alone that the person's own turn held back start no turn of their own when it ends:
/// they wait for the flush, as they would have in any turn. Anything else it held back is due at
/// once, as before.
#[tokio::test]
async fn fyis_alone_the_persons_turn_held_back_wait_for_their_flush() {
    let (hub, session) = hub_with_chat("fyi-held");
    {
        let mut inbox = session.inbox.lock().unwrap();
        inbox.items.push(item("f1", "t", "ci", PromptClass::Fyi, now_ms(), "CI is slow"));
        inbox.held_by_person = true;
    }
    hub.inbox_review(&session);
    assert_eq!(carried(&session), None, "no turn of its own before the flush");
    {
        let inbox = session.inbox.lock().unwrap();
        assert!(inbox.timer.is_some(), "the flush is timed");
        assert!(!inbox.held_by_person, "the hold lets go of FYIs alone");
    }
    assert!(!turn_coming(&session), "no turn comes for FYIs alone");
    session.inbox.lock().unwrap().items[0].at = now_ms().saturating_sub(FLUSH_MS + 1);
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["f1".to_owned()]), "a turn at its flush");

    // A result the person's turn held back (it wakes no one here) is due at once, as before.
    let (hub, session) = hub_with_chat("result-held");
    {
        let mut inbox = session.inbox.lock().unwrap();
        inbox.items.push(item("r1", "t", "lane-b", PromptClass::Result, now_ms(), "done"));
        inbox.held_by_person = true;
    }
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["r1".to_owned()]), "due at once");
}

/// A waiting send of an FYI is refused at once (`not_woken`) wherever only FYIs are new: it would
/// wait for the flush in a running turn too. Any other class, or an FYI behind a message that is
/// no FYI, is not.
#[tokio::test]
async fn a_waiting_fyi_strands_in_a_running_turn_unless_a_notice_comes() {
    let (_hub, session) = hub_with_chat("fyi-strand");
    running(&session);
    let meta = session.meta();
    let strands = |class| would_strand(&session, &session.inbox.lock().unwrap(), &meta, class);
    assert!(strands(PromptClass::Fyi), "an FYI alone waits for the flush");
    assert!(!strands(PromptClass::Result), "a result steers in");
    let other = item("r1", "t", "lane-b", PromptClass::Result, now_ms(), "done");
    session.inbox.lock().unwrap().items.push(other);
    assert!(!strands(PromptClass::Fyi), "it goes with the result's notice");

    // A first work's hold brings no notice sooner for FYIs alone (router review of #38603, F1).
    let (_hub, session) = hub_with_chat("fyi-first");
    session.inbox.lock().unwrap().first = Some("p-first".to_owned());
    let meta = session.meta();
    let strands = |class| would_strand(&session, &session.inbox.lock().unwrap(), &meta, class);
    assert!(strands(PromptClass::Fyi), "an FYI waits past the first work too");
    assert!(!strands(PromptClass::Result), "the first work's turn brings a result");
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

/// The lane-gh broker's label around a lane VM's message, as `send_label` writes it.
fn relayed_text(nonce: &str, sender: &str, body: &str) -> String {
    format!(
        "[message {nonce} from {sender} (an agent, not Leo), relayed by the lane-gh broker; its text \
         ends at \"[end of message {nonce}]\"]\n\n{body}\n\n[end of message {nonce}]"
    )
}

#[test]
fn a_relay_label_is_left_out_of_a_preview_and_nothing_else_is() {
    let text =
        relayed_text("7f70dca3", "gcp-agent-lane-2/lock-proof-routes", "fm2-r3 status: done\nmore");
    assert_eq!(relay_body(&text), "fm2-r3 status: done\nmore");
    assert_eq!(preview(&text), "fm2-r3 status: done");
    // No closing line of its own, a closing line for another nonce, or a typed look-alike head
    // are the text as written.
    let inline = text.replace("\n\n[end of message 7f70dca3]", " [end of message 7f70dca3]");
    assert_eq!(relay_body(&inline), inline);
    let other = text.replace("[end of message 7f70dca3]", "[end of message 00000000]");
    assert_eq!(relay_body(&other), other);
    assert_eq!(relay_body("[message hi from me]\nbody"), "[message hi from me]\nbody");
    assert_eq!(relay_body("plain words"), "plain words");
}

/// Leo, 2026-11-07, on "Received 4 messages" (three of them "NAME (self-declared,
/// unauthenticated)" with the broker's label as their text): "Why does it say it's self-declared
/// if we can just detect the thing?" A relayed sender reads as the relay vouched for it, the
/// transcript's parts name any sender without the agent's words for a declared one, and a
/// thread's preview is the message, not the label. The agent's own text keeps both.
#[test]
fn a_relayed_sender_is_named_plainly_and_its_preview_is_the_message() {
    let relay =
        json!({"by": "lane-gh", "machine": "gcp-agent-lane-2", "session": "lock-proof-routes"});
    let relayed = crate::prompt_provenance::stamp_sender(
        crate::prompt_provenance::stamp_declared(
            crate::prompt_provenance::named_sender("gcp-agent-lane-2/lock-proof-routes", "target"),
            Some("gcp-agent-lane-2/lock-proof-routes"),
        ),
        Some(&crate::prompt_provenance::BoundSender {
            session_id: None,
            harness: Some("claude".into()),
            relay: Some(crate::prompt_provenance::RelaySender {
                by: "lane-gh".into(),
                machine: "gcp-agent-lane-2".into(),
                session: Some("lock-proof-routes".into()),
            }),
        }),
    );
    let verified = crate::prompt_provenance::sender_record(Some(&relayed), None, None);
    assert_eq!((&verified["authenticated"], &verified["relay"]), (&json!(true), &relay));
    let name = "gcp-agent-lane-2/lock-proof-routes";
    assert_eq!(display_sender(&verified, name), name);
    assert_eq!(thread_sender(Some(&relayed), name), name);

    let declared = crate::prompt_provenance::sender_record(
        Some(&crate::prompt_provenance::named_sender("gcp-codex-swarm-05/cloud-start-matrix", "t")),
        None,
        None,
    );
    let long = "x".repeat(WHOLE_BYTES);
    let mut a = item(
        "p1",
        &format!("from:{name}"),
        name,
        PromptClass::Result,
        1,
        &relayed_text("7f70dca3", name, &long),
    );
    a.sender = verified;
    let mut b = item(
        "p2",
        "declared:gcp-codex-swarm-05/cloud-start-matrix",
        "gcp-codex-swarm-05/cloud-start-matrix",
        PromptClass::Result,
        2,
        &relayed_text("56d7d1c5", "gcp-codex-swarm-05/cloud-start-matrix", "matrix green"),
    );
    b.sender = declared;
    let (text, parts) = render(&[&a, &b]);
    // What the agent reads: the label in a message's text, and a declared sender said so.
    assert!(
        text.contains(
            "from gcp-codex-swarm-05/cloud-start-matrix (self-declared, unauthenticated)"
        ),
        "{text}"
    );
    // What the transcript draws: names and labels alone, previews of the messages.
    let shown = parts.to_string();
    assert!(!shown.contains("self-declared") && !shown.contains("unauthenticated"), "{shown}");
    let part = |id: &str| {
        parts.as_array().unwrap().iter().find(|p| p["promptIds"][0] == id).unwrap().clone()
    };
    assert_eq!(part("p1")["from"], json!([name]));
    assert_eq!(part("p1")["preview"], json!(format!("{}…", "x".repeat(PREVIEW_CHARS))));
    assert_eq!(part("p1")["sender"]["verification"], "verified");
    assert_eq!(part("p2")["from"], json!(["gcp-codex-swarm-05/cloud-start-matrix"]));
    assert_eq!(part("p2")["label"], "messages");
    assert_eq!(part("p2")["preview"], "matrix green");
    assert_eq!(part("p2")["sender"]["verification"], "declared");
}

mod agent_messaging {
    use super::*;

    /// The session that started a chat or first gave it work controls it: its message is the next
    /// step of that work, a prompt (`inbox_route`), and it wakes the chat; nobody else's result does.
    #[test]
    fn the_chats_parent_or_delegator_controls_it_and_no_one_else() {
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "lane", "harness": "fake",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        meta.turn_count = 3;
        meta.delegator = Some("s-coord".into());
        assert!(controls(&meta, Some("s-coord")));
        assert!(!controls(&meta, Some("s-other")));
        assert!(!controls(&meta, None), "a sender with no session controls nothing");
        assert!(wakes_as(&meta, PromptClass::Result, false, Some("s-coord")));
        assert!(!wakes_as(&meta, PromptClass::Result, false, Some("s-other")));
        assert!(wakes_as(&meta, PromptClass::Question, false, Some("s-other")), "a question wakes");
        assert!(!wakes_as(&meta, PromptClass::Fyi, false, Some("s-coord")), "an fyi never does");
        assert!(
            wakes_as(&meta, PromptClass::Result, true, Some("s-other")),
            "a report of its work"
        );
    }

    /// A Claude Code subagent's message names the subagent beside its lead's session, and the notice
    /// says how each sender gets an answer: the one that waits gets this turn's reply, another
    /// session `inbox_reply` or `acpmux send`, and a subagent only the reply to its own send.
    #[test]
    fn a_notice_names_a_subagent_and_says_how_each_sender_gets_its_answer() {
        let sub = json!({"id": "a0a68e7af3df5967e", "type": "general-purpose"});
        let provenance = crate::prompt_provenance::with_subagent(
            crate::prompt_provenance::session_message("s-lead", "claude-17", "s-alpha"),
            &json!({"_meta": {"acpmux": {"callerSubagent": sub}}}),
        );
        assert_eq!(provenance[crate::prompt_provenance::FROM_SUBAGENT], sub);
        assert_eq!(provenance["verified"], true, "still the session its caller token proved");
        let sender = crate::prompt_provenance::sender_record(Some(&provenance), None, None);
        assert_eq!(sender["subagent"], sub);
        assert_eq!(
            display_sender(&sender, "claude-17"),
            "claude-17's general-purpose subagent a0a68e7a"
        );

        // Waiting on its send: this turn's reply goes back to it.
        let mut asked = item("p1", "from:claude-17", "claude-17", PromptClass::Question, 1, "2+2?");
        asked.from_session = Some("s-lead".into());
        asked.sender = sender.clone();
        let (tx, _rx) = tokio::sync::watch::channel(None);
        asked.answer = Some(tx);
        let hint = reply_hint(&[&asked]).expect("a hint");
        assert!(
            hint.starts_with("Reply with acpmux, not your harness's own messaging: "),
            "{hint}"
        );
        assert!(
            hint.contains("goes back to claude-17's general-purpose subagent a0a68e7a, waiting"),
            "{hint}"
        );
        assert!(hint.contains("`acpmux send claude-17` reaches claude-17 itself"), "{hint}");

        // Another session that no longer waits: the commands that reach it.
        let mut lane = item("p2", "from:lane-b", "lane-b", PromptClass::Result, 2, "merged");
        lane.from_session = Some("s-b".into());
        let hint = reply_hint(&[&lane]).unwrap();
        assert!(
            hint.contains("To answer lane-b, inbox_reply or `acpmux send lane-b \"…\"`"),
            "{hint}"
        );
        assert!(!hint.contains("goes back"), "nobody waits: {hint}");

        // A sender with no session that does not wait can be answered by nobody: no hint.
        let declared = item("p3", "declared:x", "x", PromptClass::Result, 3, "hi");
        assert_eq!(reply_hint(&[&declared]), None);
        // A session message with no subagent says nothing of one.
        let plain = crate::prompt_provenance::with_subagent(
            crate::prompt_provenance::session_message("s-lead", "claude-17", "s-alpha"),
            &json!({"_meta": {"acpmux": {"callerSubagent": {"id": "a b", "type": "x"}}}}),
        );
        assert!(plain.get(crate::prompt_provenance::FROM_SUBAGENT).is_none(), "{plain}");
        let named = crate::prompt_provenance::with_subagent(
            crate::prompt_provenance::named_sender("dot", "s-alpha"),
            &json!({"_meta": {"acpmux": {"callerSubagent": sub}}}),
        );
        assert!(
            named.get(crate::prompt_provenance::FROM_SUBAGENT).is_none(),
            "only a proven session"
        );
    }
}
