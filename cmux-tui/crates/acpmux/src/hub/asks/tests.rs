use super::*;
use serde_json::json;

fn rec(seq: u64, at: u64, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: "mux".into(), kind: "user_message".into(), msg, host_seq: None }
}

/// A prompt the daemon admitted as the person's (`prompt_provenance::marked` with none).
fn person(prompt_id: &str, text: &str) -> Value {
    crate::prompt_provenance::marked(json!({"text": text, "promptId": prompt_id}), None)
}

fn ledger() -> AskLedger {
    AskLedger::open_as(None, "mac".into())
}

fn asks_of(l: &AskLedger, q: &AsksQuery) -> Vec<Value> {
    l.query(q, |_| None)["asks"].as_array().unwrap().clone()
}

fn all() -> AsksQuery {
    AsksQuery { limit: DEFAULT_LIMIT, ..Default::default() }
}

#[test]
fn an_ask_id_is_stable_and_shaped() {
    let a = ask_id("chat-1", "p-1");
    assert_eq!(a, ask_id("chat-1", "p-1"), "the same message gives the same id");
    assert_ne!(a, ask_id("chat-2", "p-1"), "another chat's message is another ask");
    assert_ne!(a, ask_id("chat-1", "p-2"));
    assert!(a.starts_with("ask-"));
    let hex = &a["ask-".len()..];
    assert_eq!(hex.len(), 10);
    assert!(hex.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    // sha256("chat-1\np-1") truncated: pinned, so a change of the scheme is seen.
    let digest = crate::sha256::sha256_hex(b"chat-1\np-1");
    assert_eq!(a, format!("ask-{}", &digest[..10]));
}

#[test]
fn capture_classifies_the_next_board_at_the_event_boundary() {
    assert_eq!(classify("build the next list"), AskKind::Ask);
    assert_eq!(classify("go ahead and ship it"), AskKind::Decision);
    assert_eq!(classify("yes"), AskKind::Reply);
    assert_eq!(classify("   "), AskKind::Reply);
}

#[test]
fn replies_are_captured_as_events_but_hidden_from_the_next_list() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("ask", "build the next list")), || "codex".into());
    l.record("chat", &rec(2, 20, person("reply", "yes")), || "codex".into());
    l.record("chat", &rec(3, 30, person("decision", "go ahead and ship it")), || "codex".into());

    let rows = asks_of(&l, &all());
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["kind"], "decision");
    assert_eq!(rows[1]["kind"], "ask");
    {
        let state = l.lock();
        assert_eq!(state.events.len(), 3);
        assert_eq!(state.events[1].target.as_deref(), Some("reply"));
    }
    assert_eq!(l.query(&AsksQuery { next: true, ..all() }, |_| None)["view"], "next");
}

#[test]
fn the_same_message_twice_is_one_ask() {
    let l = ledger();
    l.record("chat", &rec(3, 1_000, person("p1", "build the ledger")), || "claude".into());
    l.record("chat", &rec(9, 2_000, person("p1", "build the ledger")), || "claude".into());
    let asks = asks_of(&l, &all());
    assert_eq!(asks.len(), 1);
    let a = &asks[0];
    assert_eq!(a["id"], ask_id("chat", "p1"));
    assert_eq!(a["ts"], 1_000);
    assert_eq!(a["text"], "build the ledger");
    assert_eq!(a["harness"], "claude");
    assert_eq!(a["sessionId"], "chat");
    assert_eq!(a["host"], "mac");
    assert_eq!(a["messageId"], "p1");
    assert_eq!(a["status"], "open");
    assert_eq!(a["prs"], json!([]));
}

#[test]
fn a_record_with_no_prompt_id_is_named_by_its_seq() {
    let l = ledger();
    let msg = crate::prompt_provenance::marked(json!({"text": "hi"}), None);
    l.record("chat", &rec(7, 1, msg), || "codex".into());
    let asks = asks_of(&l, &all());
    assert_eq!(asks[0]["messageId"], "seq-7");
    assert_eq!(asks[0]["id"], ask_id("chat", "seq-7"));
}

#[test]
fn only_the_persons_own_messages_are_asks() {
    let l = ledger();
    let agent = json!({"kind": "agent_message", "from": "lane-a", "to": "chat", "msgId": "m", "threadId": "t"});
    let session =
        json!({"kind": "session_message", "from": "other", "fromName": "Other", "to": "chat"});
    let other_person = json!({"kind": "person_message", "from": "tailnet:bob", "fromName": "Bob"});
    let unverified = crate::prompt_provenance::unverified("chat", "unix", Default::default());
    let trigger = json!({"kind": "trigger", "triggerId": "x"});
    for (n, p) in [agent, session, other_person, unverified, trigger].iter().enumerate() {
        let msg = crate::prompt_provenance::marked(
            json!({"text": "do it", "promptId": format!("a{n}")}),
            Some(p),
        );
        assert!(!is_person_message(&msg), "{p}");
        l.record("chat", &rec(n as u64, 1, msg), || "claude".into());
    }
    // A record with no origin mark (a watched desktop turn, a log from before the mark).
    l.record("chat", &rec(20, 1, json!({"text": "watched", "promptId": "w"})), || "claude".into());
    // An empty prompt says nothing.
    l.record("chat", &rec(21, 1, person("e", "   ")), || "claude".into());
    // Another kind of record is never one.
    let mut queued = rec(22, 1, person("q", "queued"));
    queued.kind = "queued".into();
    l.record("chat", &queued, || "claude".into());
    assert!(asks_of(&l, &all()).is_empty());
    // A steer is the person's words.
    let steer = crate::prompt_provenance::marked(
        json!({"text": "also this", "promptId": "s", "steer": true}),
        None,
    );
    l.record("chat", &rec(23, 1, steer), || "claude".into());
    assert_eq!(asks_of(&l, &all()).len(), 1);
}

#[test]
fn trace_ids_come_from_the_trailer_and_bare_tokens() {
    let body = "Fixes it.\n\nLeo-Ask-Trace: ask-0123456789, ask-abcdefabcd\nSee also ask-1111111111.\nask-0123456789 again";
    assert_eq!(trace_ids(body), vec!["ask-0123456789", "ask-abcdefabcd", "ask-1111111111"]);
    for no in [
        "task-0123456789",
        "ask-012345678",
        "ask-0123456789a",
        "ask-01234567890",
        "ASK-0123456789",
        "ask-ABCDEF0123",
        "ask-0123456789_x",
    ] {
        assert!(trace_ids(no).is_empty(), "{no}");
    }
    assert_eq!(trace_ids("(ask-0123456789)"), vec!["ask-0123456789"]);
    let many: String = (0..40).map(|i| format!("ask-{i:010x} ")).collect();
    assert_eq!(trace_ids(&many).len(), MAX_TRACES_PER_PR);
}

#[test]
fn a_chat_lists_its_asks_and_each_names_its_chat() {
    let l = ledger();
    l.record("a", &rec(1, 10, person("p1", "first in a")), || "claude".into());
    l.record("b", &rec(1, 20, person("p1", "first in b")), || "codex".into());
    l.record("a", &rec(2, 30, person("p2", "second in a")), || "claude".into());
    let q = AsksQuery { session_id: Some("a".into()), ..all() };
    let a: Vec<String> =
        asks_of(&l, &q).iter().map(|r| r["text"].as_str().unwrap().to_owned()).collect();
    assert_eq!(a, ["second in a", "first in a"], "newest first");
    let every: Vec<Value> = asks_of(&l, &all());
    assert_eq!(
        every.iter().map(|r| r["sessionId"].clone()).collect::<Vec<_>>(),
        [json!("a"), json!("b"), json!("a")]
    );
    assert_eq!(every[1]["harness"], "codex");
    let titled = l.query(&all(), |sid| Some(format!("chat {sid}")));
    assert_eq!(titled["asks"][0]["sessionTitle"], "chat a");
}

#[test]
fn pages_go_back_by_time() {
    let l = ledger();
    for i in 0..5u64 {
        l.record("a", &rec(i, 100 + i, person(&format!("p{i}"), "x")), || "claude".into());
    }
    let first = l.query(&AsksQuery { limit: 2, ..all() }, |_| None);
    assert_eq!(first["asks"].as_array().unwrap().len(), 2);
    assert_eq!(first["next"], 103);
    let second = l.query(&AsksQuery { limit: 2, before: Some(103), ..all() }, |_| None);
    assert_eq!(second["asks"][0]["ts"], 102);
    let last = l.query(&AsksQuery { limit: 10, before: Some(101), ..all() }, |_| None);
    assert_eq!(last["asks"].as_array().unwrap().len(), 1);
    assert!(last.get("next").is_none());
}

#[test]
fn a_pull_request_links_the_asks_its_body_names_and_its_state_moves_the_status() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "claude".into());
    l.record("chat", &rec(2, 20, person("p2", "two")), || "claude".into());
    let (one, two) = (ask_id("chat", "p1"), ask_id("chat", "p2"));
    let body = format!("Summary\n\nLeo-Ask-Trace: {one}, ask-9999999999");
    let note = PrNote::from_params(
        &json!({"repo": "acme/widgets", "number": 7, "state": "open", "body": body}),
    )
    .unwrap();
    let reply = l.note_pr(note, 50);
    assert_eq!(reply["url"], "https://github.com/acme/widgets/pull/7");
    assert_eq!(reply["linked"], json!([one]), "only asks this ledger holds are linked");
    assert_eq!(reply["traceIds"], json!([one, "ask-9999999999"]));
    let rows = asks_of(&l, &all());
    let row = |id: &str| rows.iter().find(|r| r["id"] == id).unwrap().clone();
    assert_eq!(row(&one)["status"], "pr");
    assert_eq!(row(&one)["prs"][0]["repo"], "acme/widgets");
    assert_eq!(row(&one)["prs"][0]["number"], 7);
    assert_eq!(row(&one)["prs"][0]["state"], "open");
    assert_eq!(row(&two)["status"], "open");

    // A state change with no body keeps the links.
    let merged = PrNote::from_params(
        &json!({"url": "https://github.com/acme/widgets/pull/7", "state": "merged"}),
    )
    .unwrap();
    l.note_pr(merged, 60);
    assert_eq!(asks_of(&l, &all()).iter().find(|r| r["id"] == one).unwrap()["status"], "merged");

    // A new body replaces the links.
    let moved = PrNote::from_params(
        &json!({"url": "https://github.com/acme/widgets/pull/7", "body": format!("now {two}")}),
    )
    .unwrap();
    let reply = l.note_pr(moved, 70);
    assert_eq!(reply["state"], "merged", "a note with no state keeps the known one");
    let rows = asks_of(&l, &all());
    assert_eq!(rows.iter().find(|r| r["id"] == one).unwrap()["status"], "open");
    assert_eq!(rows.iter().find(|r| r["id"] == two).unwrap()["status"], "merged");
}

#[test]
fn a_created_pull_request_links_and_its_merge_or_close_settles_it() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "claude".into());
    let one = ask_id("chat", "p1");
    let url = "https://github.com/acme/widgets/pull/9";
    // A merge of a pull request no ask names notes nothing.
    l.note_settled("https://github.com/acme/widgets/pull/1", true, 5);
    assert!(l.lock().prs.is_empty());
    l.note_created(url, vec![one.clone()], 20);
    assert_eq!(asks_of(&l, &all())[0]["status"], "pr");
    l.note_settled(url, false, 30);
    assert_eq!(asks_of(&l, &all())[0]["prs"][0]["state"], "closed");
    assert_eq!(asks_of(&l, &all())[0]["status"], "pr");
    l.note_settled(url, true, 40);
    assert_eq!(asks_of(&l, &all())[0]["status"], "merged");
}

#[test]
fn lifecycle_events_keep_distinct_targets_at_the_same_timestamp() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "codex".into());
    let ask = ask_id("chat", "p1");
    l.note_created("https://github.com/a/b/pull/1", vec![ask.clone()], 20);
    l.note_created("https://github.com/a/b/pull/2", vec![ask], 20);
    let row = &asks_of(&l, &all())[0];
    assert_eq!(row["events"].as_array().unwrap().len(), 3);
    assert_eq!(row["prs"].as_array().unwrap().len(), 2);
}

#[test]
fn repeated_same_state_pr_observations_do_not_emit_lifecycle_events() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "codex".into());
    let ask = ask_id("chat", "p1");
    let url = "https://github.com/a/b/pull/1";
    l.note_created(url, vec![ask.clone()], 20);
    l.note_created(url, vec![ask], 30);
    assert_eq!(asks_of(&l, &all())[0]["events"].as_array().unwrap().len(), 2);
}

#[test]
fn linking_another_ask_to_an_unchanged_pr_emits_only_its_lifecycle_event() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "codex".into());
    l.record("chat", &rec(2, 11, person("p2", "two")), || "codex".into());
    let url = "https://github.com/a/b/pull/1";
    l.note_created(url, vec![ask_id("chat", "p1")], 20);
    l.note_created(url, vec![ask_id("chat", "p1"), ask_id("chat", "p2")], 30);
    for row in asks_of(&l, &all()) {
        let events = row["events"].as_array().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1]["kind"], "prOpened");
        assert_eq!(events[1]["ts"], if row["id"] == ask_id("chat", "p1") { 20 } else { 30 });
    }
}

#[test]
fn replay_repairs_an_ask_whose_capture_event_was_torn() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(store::FILE);
    let ask = Ask {
        id: ask_id("chat", "p1"),
        ts: 10,
        text: "one".into(),
        harness: "codex".into(),
        session_id: "chat".into(),
        host: "mac".into(),
        message_id: "p1".into(),
        kind: AskKind::Ask,
    };
    std::fs::write(&path, format!("{}\n", serde_json::to_string(&Line::Ask(ask)).unwrap()))
        .unwrap();
    let l = AskLedger::open_as(Some(dir.path().to_owned()), "mac".into());
    l.record("chat", &rec(1, 99, person("p1", "one")), || "codex".into());
    assert_eq!(asks_of(&l, &all())[0]["events"].as_array().unwrap().len(), 1);
    l.flush();
    assert!(std::fs::read_to_string(&path).unwrap().contains("\"t\":\"e\""));
}

#[test]
fn a_pr_note_needs_a_github_pull_url_or_a_repo_and_number() {
    assert!(PrNote::from_params(&json!({})).is_err());
    assert!(PrNote::from_params(&json!({"url": "https://example.com/x"})).is_err());
    assert!(PrNote::from_params(&json!({"repo": "acme", "number": 1})).is_err());
    assert!(PrNote::from_params(&json!({"repo": "acme/w"})).is_err());
    assert!(
        PrNote::from_params(&json!({"repo": "acme/w", "number": 1, "state": "weird"})).is_err()
    );
    let n =
        PrNote::from_params(&json!({"url": "https://github.com/a/b/pull/3", "state": "MERGED"}))
            .unwrap();
    assert_eq!(
        (n.repo.as_deref(), n.number, n.state, n.traces),
        (Some("a/b"), Some(3), Some(PrState::Merged), None)
    );
}

#[test]
fn a_purged_chat_takes_its_asks_and_adds_none_after() {
    let l = ledger();
    l.record("gone", &rec(1, 10, person("p1", "secret")), || "claude".into());
    l.record("kept", &rec(1, 20, person("p1", "kept")), || "claude".into());
    l.purge("gone");
    l.record("gone", &rec(2, 30, person("p2", "late")), || "claude".into());
    let rows = asks_of(&l, &all());
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["sessionId"], "kept");
    l.reopen("gone");
    l.record("gone", &rec(3, 40, person("p3", "new chat")), || "claude".into());
    assert_eq!(asks_of(&l, &all()).len(), 2);
}

#[test]
fn the_file_keeps_asks_and_links_across_a_restart_and_a_purge_rewrites_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("asks");
    let url = "https://github.com/acme/widgets/pull/4";
    {
        let l = AskLedger::open_as(Some(path.clone()), "mac".into());
        l.record("a", &rec(1, 10, person("p1", "kept")), || "claude".into());
        l.record("b", &rec(1, 20, person("p1", "purged")), || "claude".into());
        l.record("a", &rec(1, 10, person("p1", "kept")), || "claude".into());
        l.note_created(url, vec![ask_id("a", "p1")], 30);
        l.note_settled(url, true, 40);
        l.purge("b");
        l.flush();
        assert!(l.close(std::time::Duration::from_secs(5)));
    }
    let text = std::fs::read_to_string(path.join(store::FILE)).unwrap();
    assert!(!text.contains("purged"), "a purge leaves no words of the chat: {text}");
    assert!(text.contains("\"t\":\"e\""), "capture events are append-only: {text}");
    // A torn last line is cut off and the rest still reads.
    std::fs::write(path.join(store::FILE), format!("{text}{{\"t\":\"a\",\"id\"")).unwrap();
    let l = AskLedger::open_as(Some(path.clone()), "mac".into());
    let rows = asks_of(&l, &all());
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["text"], "kept");
    assert_eq!(rows[0]["status"], "merged");
    assert_eq!(rows[0]["prs"][0]["url"], url);
    assert!(std::fs::read_to_string(path.join(store::FILE)).unwrap().ends_with('\n'));
}

#[test]
fn a_long_prompt_keeps_its_first_characters() {
    let l = ledger();
    let long = "é".repeat(MAX_TEXT_CHARS + 50);
    l.record("chat", &rec(1, 1, person("p", &long)), || "claude".into());
    assert_eq!(asks_of(&l, &all())[0]["text"].as_str().unwrap().chars().count(), MAX_TEXT_CHARS);
}

#[test]
fn query_params_are_checked() {
    assert_eq!(AsksQuery::from_params(&json!({})).unwrap(), all());
    assert_eq!(AsksQuery::from_params(&json!({"limit": 1_000_000})).unwrap().limit, MAX_LIMIT);
    assert!(AsksQuery::from_params(&json!({"limit": 0})).is_err());
    assert!(AsksQuery::from_params(&json!({"sessionId": 3})).is_err());
    assert!(AsksQuery::from_params(&json!({"before": "x"})).is_err());
}

/// The hub's own append path feeds it: the person's prompt is an ask of its chat with the chat's
/// title, another agent's message is not, and a fork's copies (the cost ledger's fence) are not.
#[test]
fn the_hubs_append_path_records_the_persons_prompts_only() {
    use crate::store::{MemoryStore, SessionMeta};
    let meta = |id: &str| -> SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": "asks chat", "title": "Ask ledger",
            "harness": "claude-acp", "family": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap()
    };
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    // Build outside a runtime so no background task holds an Arc. Opt in only this
    // in-memory fixture, without depending on or changing the machine's settings.
    let mut hub = crate::hub::Hub::new(cfg, Box::new(MemoryStore::default()));
    std::sync::Arc::get_mut(&mut hub).unwrap().asks = ledger();
    let chat = hub.insert_test_session(meta("chat"));
    hub.append(&chat, "mux", "user_message", person("p1", "make it a service"));
    let agent = json!({"kind": "agent_message", "from": "lane", "to": "chat", "msgId": "m", "threadId": "t"});
    hub.append(
        &chat,
        "mux",
        "user_message",
        crate::prompt_provenance::marked(json!({"text": "done", "promptId": "p2"}), Some(&agent)),
    );
    let fork = hub.insert_test_session(meta("fork"));
    hub.ledger.suppress("fork");
    hub.append(&fork, "mux", "user_message", person("p1", "make it a service"));
    hub.ledger.unsuppress("fork");
    let reply = hub.asks_read(&json!({})).unwrap();
    let asks = reply["asks"].as_array().unwrap();
    assert_eq!(asks.len(), 1, "{reply}");
    assert_eq!(asks[0]["id"], ask_id("chat", "p1"));
    assert_eq!(asks[0]["sessionTitle"], "Ask ledger");
    assert_eq!(asks[0]["harness"], "claude");
    let one = hub.asks_read(&json!({"sessionId": "fork"})).unwrap();
    assert_eq!(one["asks"], json!([]));
    let linked = hub
        .asks_link_pr(&json!({"repo": "acme/w", "number": 2, "state": "merged",
            "body": format!("Leo-Ask-Trace: {}", ask_id("chat", "p1"))}))
        .unwrap();
    assert_eq!(linked["linked"], json!([ask_id("chat", "p1")]));
    assert_eq!(
        hub.asks_read(&json!({"sessionId": "chat"})).unwrap()["asks"][0]["status"],
        "merged"
    );
}

#[test]
fn labs_is_explicitly_opt_in_and_off_creates_no_store() {
    use crate::user_settings::Settings;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("asks");
    for settings in [
        Settings::Missing,
        Settings::Unreadable("bad JSON".into()),
        Settings::Parsed(json!({})),
        Settings::Parsed(json!({"labs.askLedger": false})),
        Settings::Parsed(json!({"labs.askLedger": "true"})),
    ] {
        let l = AskLedger::open_configured(Some(path.clone()), "mac".into(), &settings);
        l.record("chat", &rec(1, 10, person("p1", "private")), || unreachable!());
        l.note_created("https://github.com/a/b/pull/1", vec![ask_id("chat", "p1")], 20);
        assert_eq!(l.query(&all(), |_| unreachable!()), json!({"enabled": false, "asks": []}));
        assert!(l.lock().asks.is_empty());
        assert!(l.lock().prs.is_empty());
        assert!(l.thread.lock().unwrap().is_none());
        assert!(!path.exists());
    }
    for doc in [json!({"labs.askLedger": true}), json!({"labs": {"askLedger": true}})] {
        let l = AskLedger::open_configured(None, "mac".into(), &Settings::Parsed(doc));
        l.record("chat", &rec(1, 10, person("p1", "enabled")), || "codex".into());
        assert_eq!(l.query(&all(), |_| None)["enabled"], true);
        assert_eq!(asks_of(&l, &all()).len(), 1);
    }
}

#[test]
fn disabled_ledger_still_purges_previously_captured_chat() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("asks");
    let l = AskLedger::open_as(Some(path.clone()), "mac".into());
    l.record("chat", &rec(1, 10, person("p1", "delete me")), || "codex".into());
    assert!(l.close(std::time::Duration::from_secs(2)));
    let off = AskLedger::open_enabled(Some(path.clone()), "mac".into(), false);
    assert!(asks_of(&off, &all()).is_empty());
    off.purge("chat");
    assert!(off.close(std::time::Duration::from_secs(2)));
    let again = AskLedger::open_as(Some(path), "mac".into());
    assert!(asks_of(&again, &all()).is_empty());
}

#[test]
fn equal_time_pages_keep_every_ask() {
    let l = ledger();
    for i in 0..5 {
        l.record("chat", &rec(i, 100, person(&format!("p{i}"), "ask")), || "codex".into());
    }
    let mut q = AsksQuery { limit: 2, ..all() };
    let mut ids = Vec::new();
    loop {
        let page = l.query(&q, |_| None);
        ids.extend(
            page["asks"].as_array().unwrap().iter().map(|a| a["id"].as_str().unwrap().to_owned()),
        );
        let Some(next) = page["next"].as_u64() else { break };
        q.before = Some(next);
        q.before_id = page["nextId"].as_str().map(str::to_owned);
    }
    assert_eq!(ids.len(), 5);
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 5);
}

#[test]
fn an_explicit_empty_body_unlinks_but_a_state_only_note_preserves_links() {
    let l = ledger();
    l.record("chat", &rec(1, 10, person("p1", "one")), || "codex".into());
    let url = "https://github.com/a/b/pull/1";
    l.note_created(url, vec![ask_id("chat", "p1")], 20);
    l.note_settled(url, true, 30);
    assert_eq!(asks_of(&l, &all())[0]["status"], "merged");
    l.note_pr(PrNote::from_params(&json!({"url": url, "body": "No linked asks"})).unwrap(), 40);
    assert_eq!(asks_of(&l, &all())[0]["status"], "open");
}

#[test]
fn relinking_a_pr_preserves_shared_links_and_cleans_only_removed_asks() {
    let l = ledger();
    let one = "ask-0000000001";
    let two = "ask-0000000002";
    let three = "ask-0000000003";
    let unrelated = "ask-0000000004";
    let first = "https://github.com/a/b/pull/1";
    let second = "https://github.com/a/b/pull/2";
    l.note_created(first, vec![one.into(), two.into()], 10);
    l.note_created(second, vec![one.into(), unrelated.into()], 11);
    let original = l.lock().by_ask.clone();

    l.note_created(first, vec![one.into(), two.into()], 12);
    l.note_settled(first, true, 13);
    {
        let state = l.lock();
        assert_eq!(state.by_ask, original, "unchanged links keep PR order and membership");
        let pr = state.prs.get(first).unwrap();
        assert_eq!(pr.repo.as_deref(), Some("a/b"));
        assert_eq!(pr.number, Some(1), "state-only updates retain known metadata");
        assert_eq!(pr.state, PrState::Merged);
    }

    l.note_pr(
        PrNote::from_params(&json!({"url": first, "body": format!("{one} {three}")})).unwrap(),
        14,
    );
    {
        let state = l.lock();
        assert_eq!(state.by_ask.get(one), original.get(one), "retained links stay in order");
        assert!(!state.by_ask.contains_key(two), "the last removed link leaves no empty entry");
        assert_eq!(state.by_ask.get(three), Some(&vec![first.to_owned()]));
        assert_eq!(state.by_ask.get(unrelated), original.get(unrelated));
    }

    l.note_pr(PrNote::from_params(&json!({"url": first, "body": ""})).unwrap(), 15);
    let state = l.lock();
    assert_eq!(state.by_ask.get(one), Some(&vec![second.to_owned()]));
    assert_eq!(state.by_ask.get(unrelated), original.get(unrelated));
    assert!(!state.by_ask.contains_key(three));
    assert_eq!(state.by_ask.len(), 2);
    assert!(state.prs.get(first).unwrap().asks.is_empty());
    assert_eq!(state.prs.get(second).unwrap().asks, [one, unrelated]);
}

/// Run this unchanged against the old and new put_pr on the same runner. Setup is outside
/// the timed regions; no wall-clock threshold makes a busy runner fail the correctness test.
#[test]
fn ask_ledger_pr_update_duress_reports_unrelated_index_scaling() {
    use std::time::Instant;

    const UPDATES: u64 = 500;
    for unrelated in [0, 20_000] {
        let mut state = State::default();
        let mut pr = PullRequest {
            url: "https://github.com/a/b/pull/1".into(),
            repo: Some("a/b".into()),
            number: Some(1),
            state: PrState::Open,
            asks: vec!["ask-0000000001".into()],
            at: 1,
        };
        // Seed a consistent large index directly so baseline setup does not itself pay
        // for the scan being measured. Each unrelated ask has its own known PR.
        for i in 0..unrelated {
            let mut other = pr.clone();
            other.url = format!("https://github.com/a/b/pull/{}", i + 2);
            other.number = Some(i + 2);
            other.asks = vec![format!("unrelated-{i}")];
            state.by_ask.insert(format!("unrelated-{i}"), vec![other.url.clone()]);
            state.prs.insert(other.url.clone(), other);
        }
        state.put_pr(pr.clone());

        let started = Instant::now();
        for i in 0..UPDATES {
            pr.at = i + 2;
            // Pairs of duplicate observations alternate with state-only changes.
            pr.state = if i % 4 < 2 { PrState::Merged } else { PrState::Open };
            std::hint::black_box(state.put_pr(pr.clone()));
        }
        let unchanged_us = started.elapsed().as_micros();

        let started = Instant::now();
        for i in 0..UPDATES {
            pr.at = UPDATES + i + 2;
            pr.asks = vec![format!("ask-{:010x}", 1 + i % 2)];
            std::hint::black_box(state.put_pr(pr.clone()));
        }
        let relink_us = started.elapsed().as_micros();
        assert_eq!(state.by_ask.len(), unrelated as usize + 1);
        assert_eq!(state.prs.len(), unrelated as usize + 1);
        assert_eq!(state.by_ask.get("ask-0000000002"), Some(&vec![pr.url.clone()]));
        assert!(!state.by_ask.contains_key("ask-0000000001"));
        for i in 0..unrelated {
            assert_eq!(
                state.by_ask.get(&format!("unrelated-{i}")),
                Some(&vec![format!("https://github.com/a/b/pull/{}", i + 2)])
            );
        }
        println!(
            "ask-ledger PR-update duress: unrelated_linked_asks={unrelated} updates_per_phase={UPDATES} unchanged_us={unchanged_us} relink_us={relink_us}"
        );
    }
}

#[test]
fn capture_masks_credentials_before_truncating() {
    // Use the scanner's established synthetic fixture: repeated-character tokens
    // are intentionally excluded as low-entropy placeholders.
    let secret = "ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k";
    for prefix in ["Fix this token ".to_owned(), format!("{} ", "é".repeat(MAX_TEXT_CHARS - 11))] {
        let l = ledger();
        let text = format!("{prefix}{secret} and more words after it");
        l.record("chat", &rec(1, 10, person("p1", &text)), || "codex".into());
        let rows = asks_of(&l, &all());
        let captured = rows[0]["text"].as_str().unwrap();
        assert!(!captured.contains("ghp_"), "{captured}");
        assert!(!captured.contains("aZ3kQ9"), "{captured}");
        assert!(captured.chars().count() <= MAX_TEXT_CHARS);
    }
}

#[test]
fn capture_fixture_reports_provenance_and_trace_link_counts() {
    let l = ledger();
    for i in 0..100 {
        let msg = if i < 83 {
            person(&format!("p{i}"), "human request")
        } else {
            crate::prompt_provenance::marked(
                json!({"text": "machine request", "promptId": format!("p{i}")}),
                Some(&json!({"kind": "trigger", "triggerId": "fixture"})),
            )
        };
        l.record("fixture", &rec(i, i, msg), || "codex".into());
    }
    assert_eq!(asks_of(&l, &all()).len(), 83);
    assert!(asks_of(&l, &all()).iter().all(|a| a["text"] == "human request"));
    assert_eq!(l.lock().prs.len(), 0);
    l.note_created("https://github.com/a/b/pull/1", vec![ask_id("fixture", "p1")], 101);
    assert_eq!(asks_of(&l, &all()).iter().filter(|a| a["status"] == "pr").count(), 1);
    println!(
        "ask-ledger deterministic fixture: inputs=100 human=83 machine=17; captured_nonhuman=0; trace_linked_prs=0->1"
    );
}

#[test]
fn ask_ledger_duress_reports_bounded_capture_query_and_replay() {
    use std::time::Instant;

    let dir = tempfile::tempdir().unwrap();
    let started = Instant::now();
    let l = AskLedger::open_as(Some(dir.path().to_owned()), "mac".into());
    for i in 0..1_000u64 {
        let text = if i % 11 == 0 { "yes" } else { "record this request" };
        l.record("duress", &rec(i, i, person(&format!("p{i}"), text)), || "codex".into());
        if i % 101 == 0 {
            l.record("duress", &rec(i, i + 1, person(&format!("p{i}"), text)), || "codex".into());
        }
    }
    let capture_ms = started.elapsed().as_millis();
    let ask = ask_id("duress", "p1");
    l.note_created("https://github.com/a/b/pull/1", vec![ask.clone()], 2_000);
    l.note_created("https://github.com/a/b/pull/1", vec![ask], 2_001);
    let query_started = Instant::now();
    let page = l.query(&all(), |_| None);
    let query_ms = query_started.elapsed().as_millis();
    let rows = page["asks"].as_array().unwrap();
    assert_eq!(rows.len(), 200, "replies stay captured but off the Next board");
    l.flush();
    assert!(l.close(std::time::Duration::from_secs(5)));

    let replay_started = Instant::now();
    let replay = AskLedger::open_as(Some(dir.path().to_owned()), "mac".into());
    let replay_rows = asks_of(&replay, &AsksQuery { limit: MAX_LIMIT, ..all() });
    let replay_ms = replay_started.elapsed().as_millis();
    assert_eq!(replay_rows.len(), 909);
    let linked = replay_rows.iter().find(|row| row["id"] == ask_id("duress", "p1")).unwrap();
    assert_eq!(linked["events"].as_array().unwrap().len(), 2);
    println!(
        "ask-ledger duress: inputs=1000 replies=91 duplicate_observations=10 rows={} capture_ms={} query_ms={} replay_ms={}",
        rows.len(),
        capture_ms,
        query_ms,
        replay_ms
    );
    assert!(replay.close(std::time::Duration::from_secs(5)));
}
