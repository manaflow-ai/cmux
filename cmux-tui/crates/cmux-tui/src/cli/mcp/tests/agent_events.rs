//! `agents_events` at the MCP boundary: an agent long-polls what changes in
//! cmux (dialogs, notifications, tabs, workspaces, agent states) and
//! continues from the cursor it got, with no gaps and no duplicates.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Change, Fake, WORKSPACE, call, sent_of};
use crate::cli::mcp::Server;

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const AGENT: &str = "agent_0123456789abcdef0123456789abcdef";

/// One workspace with a terminal tab whose agent works, an empty journal
/// and no pending dialog.
fn fake() -> Fake {
    let fake = Fake::live(
        Some(json!({
            "workspaces": [{"id": WORKSPACE}],
            "tabs": [{"id": TAB}],
            "terminals": [{"id": TERMINAL, "tab_id": TAB}],
            "agents": [{"id": AGENT, "terminal_id": TERMINAL, "state": "working"}],
        })),
        Some(json!({"items": []})),
    );
    fake.live.borrow_mut().journal = Some(Vec::new());
    fake
}

/// Makes `change` due now on a running server.
fn now(server: &Server<Fake>, change: Change) {
    server.backend.live.borrow_mut().changes.push((Instant::now(), change));
}

fn tab(id: &str, name: &str) -> Value {
    json!({"kind": "upsert", "sequence": 0, "resource": "tab", "id": id,
           "value": {"id": id, "name": name, "content_kind": "terminal", "focused": false}})
}

fn agent(state: &str) -> Value {
    json!({"kind": "upsert", "sequence": 0, "resource": "agent", "id": AGENT,
           "value": {"id": AGENT, "terminal_id": TERMINAL, "state": state,
                     "updated_at_ms": "1700000000000"}})
}

fn dialog(id: &str) -> Value {
    json!({"id": id, "request_id": format!("request_{id}"), "workstream_id": "chat_build",
           "source": "claude", "kind": "permissionRequest", "status": "pending",
           "title": "Run a command", "input": {"command": "rm -rf ~/secret"},
           "text": "the agent's whole message"})
}

/// The answer of a successful call.
fn events(server: &mut Server<Fake>, arguments: Value) -> Value {
    let result = call(server, "agents_events", arguments.clone());
    assert_eq!(result["isError"], false, "{arguments}: {result}");
    result["structuredContent"].clone()
}

fn list(answer: &Value) -> Vec<Value> {
    answer["events"].as_array().cloned().unwrap_or_else(|| panic!("events: {answer}"))
}

/// A cursor from now, without waiting.
fn start(server: &mut Server<Fake>) -> String {
    let answer = events(server, json!({"timeout_seconds": 0}));
    assert_eq!(list(&answer), Vec::<Value>::new(), "{answer}");
    answer["next_after"].as_str().unwrap().to_owned()
}

#[test]
fn agents_events_is_listed_as_a_bounded_read() {
    let mut server = Server::new(Fake::default(), None);
    let tools = server.list();
    let tool = tools.iter().find(|tool| tool["name"] == "agents_events").expect("agents_events");
    assert_eq!(tool["annotations"]["readOnlyHint"], true, "{tool}");
    assert_eq!(tool["annotations"]["destructiveHint"], false);
    let schema = &tool["inputSchema"];
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(schema["properties"]["timeout_seconds"]["maximum"], 60);
    assert_eq!(
        schema["properties"]["kinds"]["items"]["enum"],
        json!(["dialog", "notification", "tab", "workspace", "agent"])
    );
    assert!(schema["properties"].get("idempotency_key").is_none(), "a read takes no key");
    let description = tool["description"].as_str().unwrap();
    assert!(description.contains("one call at a time"), "{description}");
    assert!(description.contains("every second"), "polled kinds are named: {description}");
}

#[test]
fn agents_events_from_now_returns_nothing_old_and_times_out_empty() {
    let fake = fake();
    {
        let mut live = fake.live.borrow_mut();
        live.journal = Some(vec![json!([tab(TAB, "old")])]);
        live.feed = Some(json!({"items": [dialog("feed_old")]}));
    }
    let mut server = Server::new(fake, None);
    let started = Instant::now();
    let answer = events(&mut server, json!({"timeout_seconds": 1}));
    let elapsed = started.elapsed();
    assert_eq!(list(&answer), Vec::<Value>::new(), "nothing old: {answer}");
    assert_eq!(answer["timed_out"], true);
    assert!(answer["next_after"].as_str().unwrap().starts_with("evc1_"), "{answer}");
    assert!(elapsed >= Duration::from_millis(900), "it waited: {elapsed:?}");
    assert!(elapsed < Duration::from_millis(2500), "within the timeout: {elapsed:?}");
    assert_eq!(answer["sources"], json!({"daemon": true, "app": true}));
}

#[test]
fn agents_events_returns_at_once_when_events_are_pending() {
    let mut server = Server::new(fake(), None);
    let after = start(&mut server);
    now(&server, Change::Journal(json!([tab(TAB, "build")])));
    let started = Instant::now();
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 30}));
    assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(got[0]["kind"], "tab");
    assert_eq!(got[0]["change"], "changed");
    assert_eq!(got[0]["id"], TAB);
    assert_eq!(got[0]["name"], "build");
    assert_eq!(got[0]["seq"], 1);
    assert!(got[0]["at"].as_u64().is_some(), "{answer}");
    assert_eq!(answer["timed_out"], false);
    // The stream resumed from the cursor's journal position.
    let streams = sent_of(&server, "events");
    assert_eq!(streams.last().unwrap()["cursor"]["generation"], "gen_fake", "{streams:?}");

    // Even a call with timeout 0 reads what is pending.
    let after = answer["next_after"].as_str().unwrap().to_owned();
    now(&server, Change::Journal(json!([tab(TAB, "test")])));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert_eq!(list(&answer).len(), 1, "{answer}");
    assert_eq!(list(&answer)[0]["seq"], 2);
}

#[test]
fn agents_events_wakes_on_the_first_daemon_or_app_event_mid_wait() {
    let mut server = Server::new(fake(), None);
    let after = start(&mut server);
    server.backend.live.borrow_mut().changes.push((
        Instant::now() + Duration::from_millis(600),
        Change::Journal(json!([agent("idle")])),
    ));
    let started = Instant::now();
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 10}));
    let elapsed = started.elapsed();
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(got[0]["kind"], "agent");
    assert_eq!(got[0]["state"], "idle");
    assert_eq!(got[0]["source"], "terminal");
    assert_eq!(got[0]["terminal_id"], TERMINAL);
    assert!(elapsed >= Duration::from_millis(500), "{elapsed:?}");
    assert!(elapsed < Duration::from_secs(3), "on the event, not the timeout: {elapsed:?}");

    // A dialog has no event; the app is read every second.
    let after = answer["next_after"].as_str().unwrap().to_owned();
    server.backend.live.borrow_mut().changes.push((
        Instant::now() + Duration::from_millis(300),
        Change::Feed(json!({"items": [dialog("feed_1")]})),
    ));
    let started = Instant::now();
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 10}));
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(got[0]["kind"], "dialog");
    assert_eq!(got[0]["change"], "opened");
    assert_eq!(got[0]["request_id"], "request_feed_1");
    assert_eq!(got[0]["dialog_kind"], "permissionRequest", "{answer}");
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());
}

#[test]
fn agents_events_cursor_continues_without_gaps_or_duplicates() {
    let mut server = Server::new(fake(), None);
    let mut after = start(&mut server);
    // Seven changes in three batches, one of which says the same state again.
    now(&server, Change::Journal(json!([tab("tab_a", "a"), tab("tab_b", "b"), tab("tab_c", "c")])));
    now(&server, Change::Journal(json!([agent("working"), agent("idle")])));
    now(
        &server,
        Change::Journal(json!([
            {"kind": "delete", "sequence": 0, "resource": "tab", "id": "tab_b"},
            {"kind": "upsert", "sequence": 1, "resource": "pane", "id": "pane_a", "value": {}},
            {"kind": "upsert", "sequence": 2, "resource": "workspace", "id": WORKSPACE,
             "value": {"id": WORKSPACE, "name": "main", "focused": true}},
        ])),
    );
    now(&server, Change::Feed(json!({"items": [dialog("feed_1")]})));
    let mut seen = Vec::new();
    for _ in 0..10 {
        let answer = events(&mut server, json!({"after": after, "limit": 2, "timeout_seconds": 0}));
        let got = list(&answer);
        assert!(got.len() <= 2, "{answer}");
        after = answer["next_after"].as_str().unwrap().to_owned();
        if got.is_empty() {
            break;
        }
        seen.extend(got);
    }
    let named = seen
        .iter()
        .map(|event| {
            let detail = event["state"].as_str().or(event["change"].as_str()).unwrap();
            format!(
                "{} {} {detail}",
                event["kind"].as_str().unwrap(),
                event["id"].as_str().unwrap()
            )
        })
        .collect::<Vec<_>>();
    let mut expected = vec![
        "dialog feed_1 opened".to_owned(),
        "tab tab_a changed".to_owned(),
        "tab tab_b changed".to_owned(),
        "tab tab_c changed".to_owned(),
        // `working` again is no event: the cursor knew it.
        format!("agent {AGENT} idle"),
        "tab tab_b closed".to_owned(),
        format!("workspace {WORKSPACE} changed"),
    ];
    let mut sorted = named.clone();
    sorted.sort();
    expected.sort();
    assert_eq!(sorted, expected, "each change once: {named:?}");
    let seqs = seen.iter().map(|event| event["seq"].as_u64().unwrap()).collect::<Vec<_>>();
    assert_eq!(seqs, (1..=7).collect::<Vec<_>>(), "{named:?}");

    // The dialog closes: one event, then nothing.
    now(&server, Change::Feed(json!({"items": []})));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(
        (got[0]["kind"].as_str(), got[0]["change"].as_str()),
        (Some("dialog"), Some("closed"))
    );
    let after = answer["next_after"].as_str().unwrap().to_owned();
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert_eq!(list(&answer), Vec::<Value>::new(), "{answer}");
}

#[test]
fn agents_events_kinds_filter_what_returns() {
    let mut server = Server::new(fake(), None);
    let after = start(&mut server);
    now(&server, Change::Journal(json!([tab(TAB, "build"), agent("idle")])));
    now(&server, Change::Feed(json!({"items": [dialog("feed_1")]})));
    let answer = events(
        &mut server,
        json!({"after": after, "kinds": ["dialog", "agent"], "timeout_seconds": 0}),
    );
    let mut kinds = list(&answer)
        .iter()
        .map(|event| event["kind"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    kinds.sort();
    assert_eq!(kinds, ["agent", "dialog"], "{answer}");
    // A kind not asked for is skipped, not kept for later.
    let after = answer["next_after"].as_str().unwrap().to_owned();
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert_eq!(list(&answer), Vec::<Value>::new(), "{answer}");
}

#[test]
fn agents_events_stay_in_the_session_like_agents_snapshot() {
    let topology = |state: &str| {
        json!({"topology": {"windows": [{"id": "win_a", "workspaces": [
            {"id": WORKSPACE, "tabs": [{"id": "page_chat", "kind": "page",
                                        "agent_state": state, "agent_session": "chat_a"}]},
            {"id": "ws_other", "tabs": [{"id": "page_other", "kind": "page",
                                         "agent_state": state, "agent_session": "chat_b"}]},
        ]}]}})
    };
    let fake = fake();
    fake.live.borrow_mut().topology = Some(topology("working"));
    let mut server = Server::new(fake, None);
    let after = start(&mut server);
    now(&server, Change::Topology(topology("idle")));
    let mut other = dialog("feed_other");
    other["terminal_id"] = json!("term_fedcba9876543210fedcba9876543210");
    let mut mine = dialog("feed_mine");
    mine["terminal_id"] = json!(TERMINAL);
    now(&server, Change::Feed(json!({"items": [other, mine]})));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let ids = list(&answer)
        .iter()
        .map(|event| event["id"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(ids, ["feed_mine", "page_chat"], "{answer}");
    let chat = &list(&answer)[1];
    assert_eq!(chat["source"], "chat");
    assert_eq!(chat["state"], "idle");
    assert_eq!(chat["agent_session"], "chat_a");
}

#[test]
fn agents_events_carry_ids_and_short_titles_only() {
    let mut server = Server::new(fake(), None);
    let after = start(&mut server);
    let long = "secret build log line ".repeat(40);
    now(
        &server,
        Change::Journal(json!([{
            "kind": "upsert", "sequence": 0, "resource": "notification", "id": "notif_1",
            "value": {"id": "notif_1", "title": long, "body": long, "level": "info",
                      "terminal_id": TERMINAL, "created_at_ms": "1700000000001", "read_by": []},
        }])),
    );
    now(&server, Change::Feed(json!({"items": [dialog("feed_1")]})));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let got = list(&answer);
    let notification = got.iter().find(|event| event["kind"] == "notification").expect("one");
    assert_eq!(notification["change"], "created");
    assert_eq!(notification["truncated"], true, "{notification}");
    assert_eq!(notification["at"], 1_700_000_000_001u64);
    assert!(notification["body"].as_str().unwrap().chars().count() <= 161, "{notification}");
    assert!(notification["title"].as_str().unwrap().chars().count() <= 81, "{notification}");
    let dialog = got.iter().find(|event| event["kind"] == "dialog").expect("one");
    assert!(dialog.get("input").is_none() && dialog.get("text").is_none(), "{dialog}");
    assert!(!answer.to_string().contains("rm -rf"), "no tool input: {answer}");
    assert_eq!(dialog["title"], "Run a command");
}

#[test]
fn agents_events_restarts_from_a_snapshot_when_the_cursor_is_unknown() {
    let mut server = Server::new(fake(), None);
    let mut after = start(&mut server);
    for name in ["a", "b"] {
        now(&server, Change::Journal(json!([tab(TAB, name)])));
        let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
        after = answer["next_after"].as_str().unwrap().to_owned();
    }
    // Another daemon (a restart with a shorter journal) does not know it.
    let mut server = Server::new(fake(), None);
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(got[0]["kind"], "reset");
    assert_eq!(got[0]["reason"], "cursor_invalid");
    let after = answer["next_after"].as_str().unwrap().to_owned();
    now(&server, Change::Journal(json!([tab(TAB, "c")])));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert_eq!(list(&answer).len(), 1, "it continues from the new journal: {answer}");
    assert_eq!(list(&answer)[0]["name"], "c");
}

#[test]
fn agents_events_refuses_bad_arguments_before_reaching_an_owner() {
    for arguments in [
        json!({"after": "evc1_notacursor"}),
        json!({"after": "tab_0123"}),
        json!({"after": 7}),
        json!({"kinds": ["terminal"]}),
        json!({"kinds": []}),
        json!({"kinds": "tab"}),
        json!({"timeout_seconds": 61}),
        json!({"timeout_seconds": -1}),
        json!({"limit": 0}),
        json!({"limit": 201}),
        json!({"idempotency_key": "k"}),
        json!({"bogus": 1}),
    ] {
        let mut server = Server::new(fake(), None);
        let result = call(&mut server, "agents_events", arguments.clone());
        assert_eq!(result["isError"], true, "{arguments}: {result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{arguments}");
        assert!(server.backend.sent.borrow().is_empty(), "{arguments} reached an owner");
    }
}

#[test]
fn agents_events_leak_nothing_from_other_sessions_when_the_daemon_read_fails() {
    let topology = |state: &str| {
        json!({"topology": {"windows": [{"id": "win_a", "workspaces": [
            {"id": WORKSPACE, "tabs": [{"id": "page_chat", "kind": "page",
                                        "agent_state": state, "agent_session": "chat_a"}]},
            {"id": "ws_other", "tabs": [{"id": "page_other", "kind": "page",
                                         "agent_state": state, "agent_session": "chat_b"}]},
        ]}]}})
    };
    let fake = fake();
    fake.live.borrow_mut().topology = Some(topology("working"));
    let mut server = Server::new(fake, None);
    let after = start(&mut server);
    // The daemon read fails while another session's chat and dialog change.
    now(&server, Change::DaemonDown(true));
    now(&server, Change::Topology(topology("idle")));
    let mut other = dialog("feed_other");
    other["terminal_id"] = json!("term_fedcba9876543210fedcba9876543210");
    now(&server, Change::Feed(json!({"items": [other]})));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let leaked = answer.to_string();
    assert!(!leaked.contains("page_other") && !leaked.contains("feed_other"), "{answer}");
    // The daemon answers again: this session's change comes, the other's not.
    let after = answer["next_after"].as_str().unwrap().to_owned();
    now(&server, Change::DaemonDown(false));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let ids = list(&answer)
        .iter()
        .map(|event| event["id"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(ids, ["page_chat"], "{answer}");
}

/// Every event from `after` on, one call of `limit` at a time.
fn walk(server: &mut Server<Fake>, mut after: String, limit: u64) -> (Vec<Value>, String) {
    let mut seen = Vec::new();
    for _ in 0..20 {
        let answer = events(server, json!({"after": after, "limit": limit, "timeout_seconds": 0}));
        let got = list(&answer);
        assert!(got.len() as u64 <= limit, "{answer}");
        after = answer["next_after"].as_str().unwrap().to_owned();
        if got.is_empty() {
            return (seen, after);
        }
        seen.extend(got);
    }
    panic!("no end: {seen:?}");
}

#[test]
fn agents_events_keeps_a_reset_that_finds_the_answer_full() {
    let mut server = Server::new(fake(), None);
    let mut after = start(&mut server);
    for name in ["a", "b"] {
        now(&server, Change::Journal(json!([tab(TAB, name)])));
        let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
        after = answer["next_after"].as_str().unwrap().to_owned();
    }
    // Another daemon that does not know the cursor, and a dialog that fills
    // a one-event answer first.
    let fake = fake();
    fake.live.borrow_mut().feed = Some(json!({"items": [dialog("feed_1")]}));
    let mut server = Server::new(fake, None);
    let (seen, _) = walk(&mut server, after, 1);
    let kinds = seen.iter().map(|event| event["kind"].as_str().unwrap()).collect::<Vec<_>>();
    assert_eq!(kinds.iter().filter(|kind| **kind == "reset").count(), 1, "{seen:?}");
    assert_eq!(kinds.iter().filter(|kind| **kind == "dialog").count(), 1, "{seen:?}");
}

#[test]
fn agents_events_reports_a_restarted_or_expired_journal_as_a_reset() {
    for (change, reason) in [
        (Change::Generation("gen_new"), "generation_changed"),
        (Change::Expire(1), "cursor_expired"),
    ] {
        let mut server = Server::new(fake(), None);
        let after = start(&mut server);
        now(&server, Change::Journal(json!([tab(TAB, "a")])));
        now(&server, change);
        let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
        let got = list(&answer);
        assert_eq!(got.len(), 1, "{reason}: {answer}");
        assert_eq!(got[0]["kind"], "reset", "{reason}");
        assert_eq!(got[0]["reason"], reason);
        // It continues from the snapshot's position.
        let after = answer["next_after"].as_str().unwrap().to_owned();
        now(&server, Change::Journal(json!([tab(TAB, "b")])));
        let (seen, _) = walk(&mut server, after, 10);
        assert_eq!(seen.len(), 1, "{reason}: {seen:?}");
        assert_eq!(seen[0]["name"], "b");
    }
}

#[test]
fn agents_events_keeps_its_cursor_under_the_size_cap() {
    let many = (0..2000)
        .map(|index| dialog(&format!("feed_{index:04}_0123456789abcdef0123456789abcdef")))
        .collect::<Vec<_>>();
    let fake = fake();
    fake.live.borrow_mut().feed = Some(json!({"items": many}));
    let mut server = Server::new(fake, None);
    let answer = events(&mut server, json!({"timeout_seconds": 0}));
    let after = answer["next_after"].as_str().unwrap().to_owned();
    assert!(after.len() <= 64 << 10, "{} bytes", after.len());
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(
        (got[0]["kind"].as_str(), got[0]["reason"].as_str()),
        (Some("reset"), Some("cursor_too_large"))
    );
    // The cursor it gave still works.
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert!(answer["next_after"].as_str().unwrap().len() <= 64 << 10);
}

#[test]
fn agents_events_stays_within_its_timeout_when_the_app_is_slow() {
    let fake = Fake { app_delay: Some(Duration::from_secs(10)), ..fake() };
    let mut server = Server::new(fake, None);
    let started = Instant::now();
    let answer = events(&mut server, json!({"timeout_seconds": 1}));
    let elapsed = started.elapsed();
    assert!(elapsed < Duration::from_secs(3), "{elapsed:?}");
    assert_eq!(answer["sources"]["app"], false, "{answer}");
    assert_eq!(answer["timed_out"], true);
}

/// `after` with its JSON edited by `edit`, as a client could send it.
fn edited(after: &str, edit: impl FnOnce(&mut Value)) -> String {
    use base64::Engine as _;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let body = after.strip_prefix("evc1_").expect("a cursor");
    let mut value =
        serde_json::from_slice::<Value>(&URL_SAFE_NO_PAD.decode(body).unwrap()).unwrap();
    edit(&mut value);
    format!("evc1_{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap()))
}

#[test]
fn agents_events_refuses_an_edited_cursor_without_failing_the_server() {
    let mut server = Server::new(fake(), None);
    let after = start(&mut server);
    now(&server, Change::Journal(json!([tab(TAB, "a")])));
    let edited = edited(&after, |value| value["s"] = json!(u64::MAX));
    let result = call(&mut server, "agents_events", json!({"after": edited, "timeout_seconds": 0}));
    assert_eq!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["state"], "not_run", "{result}");
    // The server still answers.
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    assert_eq!(list(&answer).len(), 1, "{answer}");
}

#[test]
fn agents_events_from_now_reads_the_daemon_once_for_its_baseline_and_scope() {
    let mut server = Server::new(fake(), None);
    events(&mut server, json!({"timeout_seconds": 0}));
    let reads = sent_of(&server, "resource")
        .into_iter()
        .filter(|sent| sent["request"]["operation"] == "session.snapshot")
        .count();
    assert_eq!(reads, 1, "the baseline's snapshot also scopes the app");
}

#[test]
fn agents_events_reports_what_it_missed_while_the_daemon_was_unreachable() {
    let fake = fake();
    fake.live.borrow_mut().daemon_down = true;
    let mut server = Server::new(fake, None);
    let answer = events(&mut server, json!({"timeout_seconds": 0}));
    assert_eq!(answer["sources"]["daemon"], false, "{answer}");
    let after = answer["next_after"].as_str().unwrap().to_owned();
    // The daemon comes back with changes this caller never saw.
    now(&server, Change::DaemonDown(false));
    now(&server, Change::Journal(json!([tab(TAB, "missed")])));
    let answer = events(&mut server, json!({"after": after, "timeout_seconds": 0}));
    let got = list(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!(
        (got[0]["kind"].as_str(), got[0]["reason"].as_str()),
        (Some("reset"), Some("daemon_unavailable"))
    );
}
