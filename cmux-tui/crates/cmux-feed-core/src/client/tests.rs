//! Tests of the feed client, with the Swift expectations they port
//! (FeedRowsViewTests, FeedLocalOwnerBoundTests, GitHubHeldForTrialFeedTests,
//! the FeedModel overlay and settle rules, CloudFeedSource's frames).

use serde_json::{Value, json};

use super::github::{Effect, GitHubSync, Query, Response, parse_http, parse_time, stable_id};
use super::*;

const NOW: i64 = 1_800_000_000_000;

fn agent() -> Poster {
    Poster::new("agent", "Agent")
}

fn notice(id: &str, ago_s: i64) -> FeedItem {
    FeedItem::notice(id, &format!("Notice {id}"), agent(), NOW - ago_s * 1000)
}

fn request(id: &str, kind: &str, priority: Priority, ago_s: i64) -> FeedItem {
    let mut item = notice(id, ago_s);
    item.kind = kind.to_owned();
    item.priority = priority;
    item.prompt = json!({"question": "Ship?"});
    item
}

fn no_place(_: &FeedItem) -> Option<Place> {
    None
}

// MARK: Wire model

#[test]
fn an_item_decodes_leniently_and_writes_back_what_it_did_not_read() {
    let wire = json!({
        "id": "fi_1", "title": "Deploy?", "kind": "x-acme.deploy", "type": "request",
        "prompt": {"env": "prod"}, "answer_schema": {"type": "object"},
        "poster": {"kind": "martian", "label": "acme", "install": "inst_1"},
        "priority": "bogus", "state": "weird", "created_at": 5.0, "mail": {"thread": "t"},
        "attachments": [{"id": "a", "name": "x.diff"}, {"bad": true}],
    });
    let item = FeedItem::from_value(&wire).expect("decodes");
    assert_eq!(item.kind, "x-acme.deploy");
    assert_eq!(item.poster.kind, "agent", "an unknown poster kind reads as agent");
    assert_eq!(item.priority, Priority::Normal, "a custom kind's default priority");
    assert_eq!(item.state, State::Open);
    assert_eq!(item.created_at, 5);
    assert_eq!(item.updated_at, 5);
    assert_eq!(item.attachments.len(), 1);
    assert_eq!(Prompt::parse(&item.kind, &item.prompt), Prompt::Custom);
    let back = item.to_value();
    assert_eq!(back["answer_schema"], json!({"type": "object"}));
    assert_eq!(back["mail"], json!({"thread": "t"}));
    assert_eq!(back["prompt"], json!({"env": "prod"}));
    assert_eq!(back["type"], "request");
    assert_eq!(back["poster"]["install"], "inst_1");
    assert_eq!(back["read_at"], Value::Null);
    let again: FeedItem = serde_json::from_value(back).expect("round trip");
    assert_eq!(again, item);
}

#[test]
fn an_item_without_its_required_members_is_dropped() {
    for wire in [
        json!({"title": "t", "poster": {}, "created_at": 1}),
        json!({"id": "fi", "poster": {}, "created_at": 1}),
        json!({"id": "fi", "title": "t", "created_at": 1}),
        json!({"id": "fi", "title": "t", "poster": {}}),
    ] {
        assert!(FeedItem::from_value(&wire).is_none(), "{wire}");
    }
    let built_in = FeedItem::from_value(
        &json!({"id": "fi", "title": "t", "kind": "approve", "poster": {}, "created_at": 1}),
    )
    .unwrap();
    assert_eq!(built_in.priority, Priority::High, "a built-in request defaults to high");
}

// MARK: Rows (FeedRowsViewTests)

#[test]
fn a_row_says_what_who_where_and_when() {
    let mut item = FeedItem::notice("fi_1", "Finished: updated FeedModel.swift (1)", agent(), NOW);
    item.body = "Ran `swift test --filter FeedModelTests`: 42 passed.\nMore detail.".into();
    let row = Row::of(&item, None);
    assert_eq!(row.headline, "Finished: updated FeedModel.swift (1)");
    assert_eq!(row.detail.as_deref(), Some("Ran swift test --filter FeedModelTests: 42 passed."));
    assert_eq!(row.icon, "notification");
}

#[test]
fn content_names_the_poster_only_when_it_says_something() {
    let mut bridge = FeedItem::notice("fi_a", "Allow Bash?", agent(), NOW);
    bridge.kind = "approve".into();
    bridge.prompt = json!({"action": {"type": "command", "summary": "Run", "command": "rm -rf build\nnpm run build"}});
    let bare = Row::of(&bridge, None);
    assert_eq!((bare.who.as_deref(), bare.place.as_deref()), (None, None));
    assert_eq!(bare.detail.as_deref(), Some("rm -rf build"));
    assert!(bare.detail_is_code);
    assert_eq!(bare.icon, "terminal");
    let place = Place {
        agent: Some("Claude".into()),
        workspace: Some("cmux-next".into()),
        tab: Some("Feed perf".into()),
    };
    let named = Row::of(&bridge, Some(&place));
    assert_eq!(named.who.as_deref(), Some("Claude"));
    assert_eq!(named.place.as_deref(), Some("cmux-next › Feed perf"));

    let mut hook_poster = Poster::new("harness", "api-server");
    hook_poster.harness = Some("Claude Code".into());
    let hook = FeedItem::notice("fi_b", "Run make?", hook_poster, NOW);
    let row = Row::of(&hook, None);
    assert_eq!(
        (row.who.as_deref(), row.place.as_deref()),
        (Some("Claude Code"), Some("api-server"))
    );

    let mut github = FeedItem::notice("fi_c", "GitHub", Poster::new("integration", "GitHub"), NOW);
    github.body = "manaflow-ai/cmux#26530".into();
    let row = Row::of(&github, None);
    assert_eq!(row.headline, "manaflow-ai/cmux#26530");
    assert_eq!(row.detail, None);
    assert_eq!(row.icon, "integration");
}

#[test]
fn a_row_marks_urgent_dimmed_and_local() {
    let mut item = request("fi_q", "question", Priority::High, 1);
    item.home = "local:inst".into();
    let row = Row::of(&item, None);
    assert!(row.urgent && row.local && !row.dimmed);
    assert_eq!(row.icon, "agent.question");
    assert_eq!(row.headline, "Notice fi_q");
    assert_eq!(row.detail.as_deref(), Some("Ship?"));
    item.state = State::Expired;
    let row = Row::of(&item, None);
    assert!(!row.urgent && row.dimmed);
    assert_eq!(agent_name("codex"), "Codex");
}

// MARK: Integration owner (FeedLocalOwnerBoundTests, InMemoryFeedSource)

#[test]
fn the_local_owner_keeps_its_newest_items_and_every_open_request() {
    let mut owner = IntegrationOwner::new("Mac");
    let mut mirror = Mirror::new("Mac");
    let feed = |events: Vec<OwnerEvent>, mirror: &mut Mirror| {
        for event in events {
            mirror.event(Owner::Local, event.items, event.removed, event.tx.as_deref(), NOW);
        }
    };
    let mut old_request = request("fi_req", "question", Priority::High, 0);
    old_request.created_at = 0;
    old_request.updated_at = 0;
    let (_, events) = owner.post(old_request);
    feed(events, &mut mirror);
    let local = |index: i64, read: bool| {
        let mut item = FeedItem::notice(
            &format!("fi_{index}"),
            "GitHub",
            Poster::new("agent", "GitHub"),
            1_000 + index,
        );
        item.dedupe_key = Some(format!("github:notification:{index}"));
        item.read_at = read.then_some(1);
        item
    };
    let (_, events) = owner.post(local(-1, true));
    feed(events, &mut mirror);
    let limit = MAX_INTEGRATION_ITEMS as i64;
    for index in 0..limit * 3 {
        let (_, events) = owner.post(local(index, index % 2 == 0 && index < limit));
        feed(events, &mut mirror);
    }
    assert_eq!(owner.len(), MAX_INTEGRATION_ITEMS);
    assert!(owner.contains("fi_req"));
    assert!(owner.contains(&format!("fi_{}", limit * 3 - 1)));
    assert!(!owner.contains("fi_0"));
    assert!(!owner.contains("fi_-1"));
    assert_eq!(
        mirror.confirmed_items().count(),
        MAX_INTEGRATION_ITEMS,
        "the mirror follows the owner's removals"
    );
}

#[test]
fn a_post_dedupes_by_key() {
    let mut owner = IntegrationOwner::new("Mac");
    let mut first = notice("fi_1", 10);
    first.dedupe_key = Some("k".into());
    first.read_at = Some(1);
    owner.post(first);
    let mut second = notice("fi_2", 0);
    second.dedupe_key = Some("k".into());
    second.title = "newer".into();
    let (posted, events) = owner.post(second);
    assert_eq!(posted, Posted { id: "fi_1".into(), deduped: true });
    let item = &events[0].items[0];
    assert_eq!(
        (item.id.as_str(), item.title.as_str(), item.count, item.read_at),
        ("fi_1", "newer", 2, None)
    );
    assert_eq!(item.created_at, NOW - 10_000, "keeps its first post time");
    assert_eq!(item.revision, 2);
    let mut asked = request("fi_r", "question", Priority::High, 0);
    asked.dedupe_key = Some("r".into());
    owner.post(asked.clone());
    asked.id = "fi_r2".into();
    let (posted, events) = owner.post(asked);
    assert_eq!(posted, Posted { id: "fi_r".into(), deduped: true });
    assert!(events.is_empty(), "a request comes back unchanged");
}

#[test]
fn the_owner_refuses_a_late_answer_with_the_item() {
    let mut owner = IntegrationOwner::new("Mac");
    owner.post(request("fi_r", "question", Priority::High, 0));
    let answer = Intent::new(
        "k1",
        IntentKind::Answer { item: "fi_r".into(), value: json!({"text": "yes"}) },
        NOW,
    );
    let (result, events) = owner.commit(&answer);
    assert!(result.is_ok());
    assert_eq!(events[0].tx.as_deref(), Some("k1"));
    assert_eq!(events[0].items[0].state, State::Answered);
    let late = Intent::new("k2", IntentKind::Decline { item: "fi_r".into() }, NOW);
    let (result, events) = owner.commit(&late);
    assert!(matches!(result, Err(Reject::Closed(item)) if item.state == State::Answered));
    assert!(events.is_empty());
}

// MARK: Mirror (FeedModel)

fn connected_mirror(items: Vec<FeedItem>) -> Mirror {
    let mut mirror = Mirror::new("Mac");
    mirror.set_connection(Connection::Connected);
    mirror.cloud_snapshot("usr_me", items, NOW);
    mirror
}

#[test]
fn a_pending_answer_shows_until_its_settle_line() {
    let mut mirror = connected_mirror(vec![request("fi_r", "question", Priority::High, 5)]);
    assert_eq!(mirror.counts().open_requests, 1);
    let intent = Intent::new(
        "k",
        IntentKind::Answer { item: "fi_r".into(), value: json!({"text": "ok"}) },
        NOW,
    );
    let (commit, routed) = mirror.begin(intent, true, NOW);
    assert_eq!(commit.changed, vec!["fi_r".to_owned()]);
    assert!(routed.cloud.is_some() && routed.local.is_none());
    let shown = mirror.visible("fi_r").unwrap();
    assert_eq!(shown.state, State::Answered);
    assert_eq!(shown.answer.as_ref().unwrap()["by"], "usr_me");
    assert_eq!(
        mirror.confirmed("fi_r").unwrap().state,
        State::Open,
        "the mirror is never written by an intent"
    );
    assert!(mirror.is_pending("fi_r"));
    assert_eq!(mirror.counts().open_requests, 0);
    let (_, outcome) = mirror.settle("k", None, NOW);
    assert_eq!(outcome, Some(Ok(())));
    assert!(!mirror.is_pending("fi_r"));
    assert_eq!(
        mirror.visible("fi_r").unwrap().state,
        State::Open,
        "nothing confirmed it: the overlay leaves"
    );
}

#[test]
fn a_closed_refusal_adopts_the_owners_item() {
    let mut mirror = connected_mirror(vec![request("fi_r", "question", Priority::High, 5)]);
    let intent = Intent::new("k", IntentKind::Decline { item: "fi_r".into() }, NOW);
    mirror.begin(intent, true, NOW);
    let mut closed = request("fi_r", "question", Priority::High, 5);
    closed.state = State::Answered;
    closed.revision = 2;
    let (_, outcome) = mirror.settle("k", Some(Reject::Closed(Box::new(closed))), NOW);
    assert!(matches!(outcome, Some(Err(Reject::Closed(_)))));
    assert_eq!(mirror.visible("fi_r").unwrap().state, State::Answered);
}

#[test]
fn an_echo_settles_and_owner_data_never_moves_back() {
    let mut mirror = connected_mirror(vec![notice("fi_1", 5)]);
    mirror.begin(Intent::new("k", IntentKind::Read { items: vec!["fi_1".into()] }, NOW), true, NOW);
    let mut read = notice("fi_1", 5);
    read.read_at = Some(NOW);
    read.revision = 3;
    let commit = mirror.event(Owner::Cloud, vec![read], vec![], Some("k"), NOW).unwrap();
    assert!(commit.changed.contains(&"fi_1".to_owned()));
    assert!(!mirror.is_pending("fi_1"));
    let stale = notice("fi_1", 5);
    mirror.event(Owner::Cloud, vec![stale], vec![], None, NOW);
    assert_eq!(
        mirror.visible("fi_1").unwrap().read_at,
        Some(NOW),
        "revision 1 never replaces revision 3"
    );
}

#[test]
fn an_intent_across_both_owners_settles_when_both_did() {
    let mut mirror = connected_mirror(vec![notice("fi_c", 5)]);
    mirror.event(Owner::Local, vec![notice("fi_l", 4)], vec![], None, NOW);
    let intent =
        Intent::new("k", IntentKind::Read { items: vec!["fi_c".into(), "fi_l".into()] }, NOW);
    let (_, routed) = mirror.begin(intent, true, NOW);
    assert_eq!(routed.local.unwrap().items(), Some(vec!["fi_l"]));
    assert_eq!(routed.cloud.unwrap().items(), Some(vec!["fi_c"]));
    // The local echo carries the key; it must not end the cloud half.
    mirror.event(Owner::Local, vec![], vec![], Some("k"), NOW);
    assert!(mirror.has_pending("k"));
    assert_eq!(mirror.settle("k", None, NOW).1, None);
    assert_eq!(mirror.settle("k", Some(Reject::Moving), NOW).1, Some(Err(Reject::Moving)));
    assert!(!mirror.has_pending("k"));
    // Mark All Read while disconnected goes to the local owner only.
    let (_, routed) =
        mirror.begin(Intent::new("m", IntentKind::MarkAllRead { before: NOW }, NOW), false, NOW);
    assert!(routed.local.is_some() && routed.cloud.is_none() && !routed.refused);
    assert_eq!(mirror.settle("m", None, NOW).1, Some(Ok(())));
    // A cloud answer while disconnected is refused.
    let (_, routed) = mirror.begin(
        Intent::new("a", IntentKind::Decline { item: "fi_c".into() }, NOW),
        false,
        NOW,
    );
    assert!(routed.refused);
}

#[test]
fn a_cloud_snapshot_keeps_the_local_owners_items() {
    let mut mirror = connected_mirror(vec![notice("fi_c", 5)]);
    mirror.event(Owner::Local, vec![notice("fi_l", 4)], vec![], None, NOW);
    mirror.cloud_snapshot("usr_me", vec![notice("fi_c2", 3)], NOW);
    let ids: Vec<&str> = mirror.timeline().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, vec!["fi_c2", "fi_l"]);
    mirror.clear_cloud(NOW);
    let ids: Vec<&str> = mirror.timeline().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, vec!["fi_l"]);
}

/// The view is loaded only once the cloud owner's snapshot came: a first
/// connection that fails leaves it unloaded (an empty view then says nothing
/// about the cloud's requests), and an account change unloads it again.
#[test]
fn the_view_is_loaded_only_after_a_cloud_snapshot() {
    let mut mirror = Mirror::new("Mac");
    assert!(!mirror.loaded(), "a new mirror has no cloud snapshot");
    mirror.set_connection(Connection::Connecting);
    mirror.set_connection(Connection::Disconnected("offline".to_owned()));
    // The integration owner's items show at once; the view is still not loaded.
    mirror.event(Owner::Local, vec![notice("fi_l", 4)], vec![], None, NOW);
    assert!(!mirror.loaded(), "a failed first connection is not a loaded view");
    assert!(!view(&mirror, json!({"layout": "list"}))["loaded"].as_bool().unwrap_or(true));
    mirror.set_connection(Connection::Connecting);
    mirror.cloud_snapshot("usr_me", vec![request("fi_r", "question", Priority::High, 5)], NOW);
    mirror.set_connection(Connection::Connected);
    assert!(mirror.loaded());
    let shown = view(&mirror, json!({"layout": "list"}));
    assert_eq!(shown["loaded"], true, "{shown}");
    // The snapshot's request beside the integration owner's notice (newest first).
    let ids: Vec<&str> = mirror.timeline().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, vec!["fi_l", "fi_r"]);
    // Offline after it loaded: still loaded (the mirror keeps the cloud items).
    mirror.set_connection(Connection::Disconnected("offline".to_owned()));
    assert!(mirror.loaded());
    // Another account: unloaded until its own snapshot.
    mirror.clear_cloud(NOW);
    assert!(!mirror.loaded(), "a cleared cloud part is not loaded");
}

#[test]
fn the_list_orders_requests_by_priority_then_newest_and_counts_the_badge() {
    let mut snoozed = notice("fi_s", 1);
    snoozed.snoozed_until = Some(NOW + 60_000);
    let mut archived = notice("fi_a", 1);
    archived.archived_at = Some(NOW);
    let mut read = notice("fi_read", 2);
    read.read_at = Some(NOW);
    let mut mirror = connected_mirror(vec![
        notice("fi_n", 3),
        read,
        request("fi_low", "question", Priority::Low, 1),
        request("fi_urgent_old", "approve", Priority::Urgent, 50),
        request("fi_urgent_new", "approve", Priority::Urgent, 10),
        snoozed,
        archived,
    ]);
    let ids: Vec<&str> = mirror.list().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, vec!["fi_urgent_new", "fi_urgent_old", "fi_low", "fi_read", "fi_n"]);
    let counts = mirror.counts();
    assert_eq!((counts.open_requests, counts.unread_notices, counts.badge()), (3, 1, 4));
    assert_eq!(counts.unread, 6, "Mark All Read counts every unread visible item");
    // A snooze that ends shows again on the next tick.
    let commit = mirror.tick(NOW + 61_000).unwrap();
    assert_eq!(commit.changed, vec!["fi_s".to_owned()]);
    assert!(mirror.list().any(|item| item.id == "fi_s"));
}

#[test]
fn an_overlay_obeys_the_lifecycle_rules() {
    let mut open = request("fi_r", "question", Priority::High, 1);
    let archive = Intent::new("k", IntentKind::Archive { items: vec!["fi_r".into()] }, NOW);
    archive.apply(&mut open, "u", "Mac");
    assert_eq!(open.archived_at, None, "an open request cannot be archived");
    let snooze =
        Intent::new("k", IntentKind::Snooze { items: vec!["fi_r".into()], until: NOW + 1 }, NOW);
    snooze.apply(&mut open, "u", "Mac");
    assert_eq!(open.snoozed_until, None, "nor snoozed");
    let mut old = notice("fi_old", 100);
    let mut new = notice("fi_new", 0);
    new.created_at = NOW + 5;
    let all = Intent::new("k", IntentKind::MarkAllRead { before: NOW }, NOW);
    all.apply(&mut old, "u", "Mac");
    all.apply(&mut new, "u", "Mac");
    assert_eq!((old.read_at, new.read_at), (Some(NOW), None));
}

// MARK: Cloud stream (CloudFeedSource)

#[test]
fn the_stream_subscribes_takes_the_snapshot_and_resends_unsettled_intents() {
    let mut stream = CloudStream::new();
    let intent = Intent::new("k", IntentKind::Read { items: vec!["fi_1".into()] }, NOW);
    assert_eq!(
        stream.send(&intent),
        Err(Reject::Disconnected),
        "nothing queues before the snapshot"
    );
    stream.on_connect();
    let actions =
        stream.on_text(&json!({"t": "welcome", "principal": {"user": "usr_me"}}).to_string());
    assert_eq!(actions[0], CloudAction::User("usr_me".into()));
    let CloudAction::Send(subscribe) = &actions[1] else { panic!("{actions:?}") };
    assert_eq!(
        serde_json::from_str::<Value>(subscribe).unwrap(),
        json!({"t": "subscribe", "stream": "feed:usr_me", "pending": []})
    );
    let wire = notice("fi_1", 1).to_value();
    let actions = stream.on_text(
        &json!({"t": "snapshot", "seq": 3, "state": {"user": "usr_me", "items": {"fi_1": wire}}})
            .to_string(),
    );
    assert!(matches!(&actions[0], CloudAction::Snapshot { items, .. } if items.len() == 1));
    let CloudAction::Send(presence) = &actions[1] else { panic!() };
    assert_eq!(
        serde_json::from_str::<Value>(presence).unwrap(),
        json!({"t": "presence.set", "stream": "feed:usr_me", "state": {"active": false, "client": "mac"}})
    );
    let mut frames = stream.send(&intent).unwrap();
    assert_eq!(frames.len(), 1, "{frames:?}");
    let frame = frames.remove(0);
    assert_eq!(
        serde_json::from_str::<Value>(&frame).unwrap(),
        json!({"t": "op", "op": "feed.read", "params": {"items": ["fi_1"]}, "idempotency_key": "k", "origin": "user"})
    );
    // A reconnect: the welcome names the pending key, the snapshot resends it.
    stream.on_disconnect();
    stream.on_connect();
    let actions =
        stream.on_text(&json!({"t": "welcome", "principal": {"user": "usr_me"}}).to_string());
    let CloudAction::Send(subscribe) = &actions[1] else { panic!() };
    assert!(subscribe.contains("\"pending\":[\"k\"]"));
    let actions = stream.on_text(
        &json!({"t": "snapshot", "seq": 4, "state": {"user": "usr_me", "items": {}}}).to_string(),
    );
    assert_eq!(actions.last(), Some(&CloudAction::Send(frame)));
    // A reject, then its settle line.
    assert!(stream.on_text(&json!({"t": "reject", "idempotency_key": "k", "code": "feed.moving", "message": "m"}).to_string()).is_empty());
    let actions =
        stream.on_text(&json!({"t": "request-settled", "idempotency_key": "k"}).to_string());
    assert_eq!(
        actions,
        vec![CloudAction::Settled { key: "k".into(), reject: Some(Reject::Moving) }]
    );
}

#[test]
fn presence_waits_for_a_live_stream_after_a_reconnect() {
    let mut stream = CloudStream::new();
    stream.on_connect();
    stream.on_text(&json!({"t": "welcome", "principal": {"user": "u"}}).to_string());
    stream.on_text(&json!({"t": "snapshot", "seq": 1, "state": {"items": {}}}).to_string());
    assert!(stream.set_presence(true).is_some(), "a live stream sends presence at once");
    stream.on_disconnect();
    stream.on_connect();
    assert_eq!(stream.set_presence(false), None, "no presence before the new subscribe");
    stream.on_text(&json!({"t": "welcome", "principal": {"user": "u"}}).to_string());
    assert_eq!(stream.set_presence(true), None, "nor before the snapshot");
    let actions =
        stream.on_text(&json!({"t": "snapshot", "seq": 2, "state": {"items": {}}}).to_string());
    let CloudAction::Send(presence) = &actions[1] else { panic!("{actions:?}") };
    assert!(presence.contains("\"active\":true"), "the snapshot sends the latest state");
}

#[test]
fn an_event_names_removed_items_by_what_is_still_present() {
    let mut stream = CloudStream::new();
    stream.on_text(&json!({"t": "welcome", "principal": {"user": "u"}}).to_string());
    let items = json!({"fi_1": notice("fi_1", 1).to_value(), "fi_2": notice("fi_2", 1).to_value()});
    stream.on_text(&json!({"t": "snapshot", "seq": 1, "state": {"items": items}}).to_string());
    let actions = stream
        .on_text(&json!({"t": "event", "seq": 2, "items": [], "present": ["fi_2"]}).to_string());
    assert_eq!(actions, vec![CloudAction::Event { items: vec![], removed: vec!["fi_1".into()] }]);
    // Mark All Read with nothing unread known before its cut sends nothing.
    let mut read = notice("fi_2", 1);
    read.read_at = Some(NOW);
    stream.on_text(&json!({"t": "event", "seq": 3, "items": [read.to_value()]}).to_string());
    let all = Intent::new("m", IntentKind::MarkAllRead { before: NOW }, NOW);
    assert_eq!(stream.send(&all), Ok(Vec::new()));
    stream.on_text(
        &json!({"t": "event", "seq": 4, "items": [notice("fi_3", 1).to_value()]}).to_string(),
    );
    let frames = stream.send(&all).unwrap();
    assert_eq!(frames.len(), 1, "{frames:?}");
    assert!(frames[0].contains("\"params\":{\"all\":true}"));
    assert_eq!(stream.reset(), vec!["m".to_owned()]);
}

/// cmux#37378 review: the Inbox's Mark All Read is one intent (one gesture) of every shown id;
/// the cloud owner takes at most MAX_INTENT_IDS per op, so the stream sends it as several ops
/// and settles the intent once, when every op settled, with the first refusal.
#[test]
fn a_long_read_goes_as_ops_of_the_owners_size_and_settles_once() {
    let mut stream = CloudStream::new();
    stream.on_text(&json!({"t": "welcome", "principal": {"user": "u"}}).to_string());
    stream.on_text(&json!({"t": "snapshot", "seq": 1, "state": {"items": {}}}).to_string());
    let ids: Vec<String> = (0..300).map(|n| format!("fi_{n}")).collect();
    let read = Intent::new("k", IntentKind::Read { items: ids.clone() }, NOW);
    let frames: Vec<Value> = stream
        .send(&read)
        .unwrap()
        .iter()
        .map(|frame| serde_json::from_str(frame).unwrap())
        .collect();
    assert_eq!(frames.len(), 2, "{frames:?}");
    assert_eq!(frames[0]["idempotency_key"], "k");
    assert_eq!(frames[1]["idempotency_key"], "k:2");
    let sent: Vec<String> = frames
        .iter()
        .flat_map(|frame| frame["params"]["items"].as_array().unwrap().clone())
        .map(|id| id.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(frames[0]["params"]["items"].as_array().unwrap().len(), MAX_INTENT_IDS);
    assert_eq!(sent, ids, "every id goes out once, in order");
    // A reconnect names both pending ops.
    let actions = stream.on_text(&json!({"t": "welcome", "principal": {"user": "u"}}).to_string());
    let CloudAction::Send(subscribe) = &actions[1] else { panic!("{actions:?}") };
    assert!(subscribe.contains("\"pending\":[\"k\",\"k:2\"]"), "{subscribe}");
    // The first op's refusal waits for the second op; the intent settles once, refused.
    stream.on_text(
        &json!({"t": "reject", "idempotency_key": "k", "code": "feed.moving", "message": "m"})
            .to_string(),
    );
    let settled = |key: &str| json!({"t": "request-settled", "idempotency_key": key}).to_string();
    assert!(stream.on_text(&settled("k")).is_empty());
    assert_eq!(
        stream.on_text(&settled("k:2")),
        vec![CloudAction::Settled { key: "k".into(), reject: Some(Reject::Moving) }]
    );
    // An unsettled split intent is refused once on reset.
    stream.on_text(&json!({"t": "snapshot", "seq": 2, "state": {"items": {}}}).to_string());
    assert_eq!(stream.send(&Intent::new("r", read.kind.clone(), NOW)).unwrap().len(), 2);
    assert_eq!(stream.reset(), vec!["r".to_owned()]);
}

#[test]
fn a_closed_reject_carries_the_item() {
    let item = request("fi_r", "question", Priority::High, 1).to_value();
    let frame = Frame::decode(&json!({"t": "reject", "idempotency_key": "k", "code": "feed.closed", "message": "closed", "details": {"item": item}}).to_string());
    assert!(matches!(frame, Frame::Reject { reject: Reject::Closed(_), .. }));
    assert_eq!(reject("validation.invalid", "bad", None), Reject::Invalid("bad".into()));
    assert_eq!(reject("x", "y", None), Reject::Other("x: y".into()));
}

// MARK: View (FeedListSections, FeedInboxGroups, FeedInboxFilter)

fn view(mirror: &Mirror, request: Value) -> Value {
    let request: ViewRequest = serde_json::from_value(request).unwrap();
    let context = ViewContext {
        mirror,
        account: None,
        now: NOW,
        github: None,
        github_enabled: false,
        reports_available: true,
        place: &no_place,
    };
    context.view(&request)
}

fn group_ids(view: &Value, group: usize) -> Vec<String> {
    view["groups"][group]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["id"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_inbox_groups_by_the_readers_day_and_collapses_threads() {
    // NOW is 2027-01-15 08:00 UTC; at UTC-9 it is still the 14th.
    let mut a = notice("fi_a", 60);
    a.thread = Some("t".into());
    let mut b = notice("fi_b", 120);
    b.thread = Some("t".into());
    // 23:00 UTC yesterday, 14:00 of the same day at UTC-9.
    let yesterday = notice("fi_y", 9 * 3600);
    let ask = request("fi_r", "question", Priority::High, 1);
    let mirror = connected_mirror(vec![a, b, yesterday, ask]);
    let utc = view(&mirror, json!({"layout": "inbox"}));
    assert_eq!(utc["groups"][0]["id"], "needs_you");
    assert_eq!(group_ids(&utc, 0), vec!["fi_r"]);
    assert_eq!(group_ids(&utc, 1), vec!["thread:t:fi_a"]);
    assert_eq!(utc["groups"][1]["entries"][0]["members"][0]["id"], "fi_b");
    assert_eq!(utc["groups"][1]["entries"][0]["unread"], 2);
    assert_eq!(group_ids(&utc, 2), vec!["fi_y"]);
    let west = view(&mirror, json!({"layout": "inbox", "tz_offset_min": -540}));
    assert_eq!(group_ids(&west, 1), vec!["thread:t:fi_a", "fi_y"], "the reader's calendar day");
    assert_eq!(west["total"], 3);
    let item = &utc["groups"][0]["entries"][0]["item"];
    assert_eq!(item["pending"], false);
    assert_eq!(item["row"]["icon"], "agent.question");
    assert_eq!(
        utc["counts"],
        json!({"open_requests": 1, "unread_notices": 3, "badge": 4, "unread": 4})
    );
    assert_eq!(utc["connection"], json!({"state": "connected"}));
    assert_eq!(utc["reports"], json!({"available": true}));
}

#[test]
fn the_list_and_needs_you_layouts_and_the_limit() {
    let mirror = connected_mirror(vec![
        notice("fi_1", 1),
        notice("fi_2", 2),
        request("fi_r", "confirm", Priority::High, 3),
    ]);
    let list = view(&mirror, json!({"layout": "list", "limit": 2}));
    assert_eq!(list["groups"][0]["id"], "requests");
    assert_eq!(group_ids(&list, 0), vec!["fi_r"]);
    assert_eq!(group_ids(&list, 1), vec!["fi_1"]);
    assert_eq!(list["total"], 3);
    let needs = view(&mirror, json!({"layout": "needs_you"}));
    assert_eq!(needs["groups"].as_array().unwrap().len(), 1);
    assert_eq!(group_ids(&needs, 0), vec!["fi_r"]);
}

#[test]
fn the_filter_matches_terms_case_and_diacritic_insensitive() {
    let mut cafe = notice("fi_cafe", 1);
    cafe.title = "Café deploy".into();
    let mut github = notice("fi_gh", 2);
    github.dedupe_key = Some("github:review:a/b:1".into());
    let mirror =
        connected_mirror(vec![cafe, github, request("fi_r", "question", Priority::High, 3)]);
    let found = view(
        &mirror,
        json!({"filter": {"connection": "feed", "category": "all", "query": "CAFE  depl"}}),
    );
    assert_eq!(group_ids(&found, 1), vec!["fi_cafe"]);
    let gh = view(&mirror, json!({"filter": {"connection": "github", "category": "all"}}));
    assert_eq!((group_ids(&gh, 0), group_ids(&gh, 1)), (vec![], vec!["fi_gh".to_owned()]));
    let notices = view(&mirror, json!({"filter": {"connection": "feed", "category": "notices"}}));
    assert_eq!(group_ids(&notices, 0), Vec::<String>::new());
    let needs = view(&mirror, json!({"filter": {"connection": "feed", "category": "needs_you"}}));
    assert_eq!(group_ids(&needs, 0), vec!["fi_r"]);
    assert_eq!(fold("Ｃａｆé ß"), "cafe ss");
    assert!(serde_json::from_value::<ViewRequest>(json!({"layout": "grid"})).is_err());
}

// MARK: Choice (FeedChoiceValidation)

#[test]
fn a_choice_answer_is_checked_before_it_is_sent() {
    let prompt = json!({"questions": [
        {"id": "q1", "question": "Which?", "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}]},
        {"id": "q2", "question": "Also?", "multi": true, "allow_other": true, "options": [{"id": "x", "label": "X"}, {"id": "y", "label": "Y"}]},
    ]});
    let Prompt::Choice { questions } = Prompt::parse("choice", &prompt) else { panic!() };
    let answer = json!({"answers": {"q1": {"selected": ["a", "b"]}, "q2": {"selected": ["z"], "other": " "}, "q9": {"selected": []}}});
    let issues = normalize_choice(&answer, &questions).unwrap_err();
    assert_eq!(
        issues,
        vec![
            ChoiceIssue::UnknownQuestion { question: "q9".into() },
            ChoiceIssue::TooMany { question: "q1".into() },
            ChoiceIssue::UnknownOption { question: "q2".into(), option: "z".into() },
        ]
    );
    let good =
        json!({"answers": {"q1": {"selected": ["a"]}, "q2": {"selected": [], "other": "  mine "}}});
    assert_eq!(
        normalize_choice(&good, &questions).unwrap(),
        json!({"answers": {"q1": {"selected": ["a"]}, "q2": {"selected": [], "other": "mine"}}})
    );
    let blank = json!({"answers": {"q1": {"selected": [], "other": "x"}}});
    let issues = normalize_choice(&blank, &questions).unwrap_err();
    assert!(issues.contains(&ChoiceIssue::OtherNotAllowed { question: "q1".into() }));
    assert!(issues.contains(&ChoiceIssue::Unanswered { question: "q2".into() }));
}

// MARK: GitHub (GitHubHeldForTrialFeedTests, GitHubCLIClient)

const DATE: &str = "2023-11-14T22:13:20Z";

fn held_answer(pulls: Value) -> Response {
    Response {
        status: 200,
        etag: Some("\"e\"".into()),
        body: json!({"items": pulls}).to_string().into_bytes(),
    }
}

fn held_pull() -> Value {
    json!({"id": 30817, "number": 30817, "title": "Spaces switcher", "html_url": "https://github.com/acme/app/pull/30817",
           "repository_url": "https://api.github.com/repos/acme/app", "user": {"login": "me"}, "state": "open", "updated_at": DATE})
}

fn apply(
    sync: &mut GitHubSync,
    owner: &mut IntegrationOwner,
    query: Query,
    response: &Response,
) -> Result<(), String> {
    for effect in sync.apply(query, response, NOW)? {
        match effect {
            Effect::Post(item) => {
                owner.post(*item);
            }
            Effect::Withdraw(key) => {
                owner.withdraw(&key, NOW);
            }
        }
    }
    Ok(())
}

#[test]
fn a_pull_request_held_for_your_trial_is_an_open_needs_you_request() {
    let mut sync = GitHubSync::new();
    let effects = sync.apply(Query::HeldForTrial, &held_answer(json!([held_pull()])), NOW).unwrap();
    let [Effect::Post(item)] = effects.as_slice() else { panic!("{effects:?}") };
    assert_eq!(item.dedupe_key.as_deref(), Some("github:held:acme/app:30817"));
    assert!(item.is_open_request());
    assert_eq!(item.body, "acme/app#30817");
    assert_eq!(item.kind, "review");
    assert_eq!(
        item.prompt,
        json!({"subject": "pr", "ref": "https://github.com/acme/app/pull/30817"})
    );
    assert_eq!(item.context_str("url"), Some("https://github.com/acme/app/pull/30817"));
    assert_eq!(item.home, "local:github");
    assert_eq!(item.created_at, parse_time(DATE).unwrap());
    assert_eq!(item.expires_at, Some(NOW + 7 * 24 * 3600 * 1000));
    assert_eq!(item.id, stable_id("github:held:acme/app:30817"));
    assert_eq!(sync.detail(item).unwrap().title, "Spaces switcher");
    assert_eq!(sync.etag(Query::HeldForTrial), Some("\"e\""));
    let actions = github::actions(item, sync.detail(item)).unwrap();
    assert_eq!(actions, vec!["open", "start_agent", "approve", "comment"]);
}

#[test]
fn a_held_pull_request_missing_from_a_fresh_answer_is_no_longer_an_open_request() {
    let mut sync = GitHubSync::new();
    let mut owner = IntegrationOwner::new("Mac");
    let key = "github:held:acme/app:30817";
    let find = |owner: &IntegrationOwner| owner.item(&stable_id(key)).cloned().unwrap();
    apply(&mut sync, &mut owner, Query::HeldForTrial, &held_answer(json!([held_pull()]))).unwrap();
    assert!(find(&owner).is_open_request());
    let not_modified = Response { status: 304, etag: None, body: Vec::new() };
    apply(&mut sync, &mut owner, Query::HeldForTrial, &not_modified).unwrap();
    assert!(find(&owner).is_open_request());
    let failure = Response { status: 502, etag: None, body: b"bad gateway".to_vec() };
    assert!(apply(&mut sync, &mut owner, Query::HeldForTrial, &failure).is_err());
    assert!(find(&owner).is_open_request());
    apply(&mut sync, &mut owner, Query::HeldForTrial, &held_answer(json!([]))).unwrap();
    let closed = find(&owner);
    assert!(!closed.is_open_request());
    assert_eq!(closed.cancel.as_ref().unwrap()["reason"], "poster");
    // The hold goes back on: the PR is a Needs you request again.
    apply(&mut sync, &mut owner, Query::HeldForTrial, &held_answer(json!([held_pull()]))).unwrap();
    assert!(find(&owner).is_open_request());
}

#[test]
fn notifications_map_to_items_by_reason() {
    let rows = json!([
        {"id": "1", "reason": "review_requested", "updated_at": DATE,
         "subject": {"title": "Fix", "url": "https://api.github.com/repos/a/b/pulls/7", "type": "PullRequest"},
         "repository": {"full_name": "a/b", "html_url": "https://github.com/a/b/"}},
        {"id": "2", "reason": "ci_activity", "updated_at": DATE, "subject": {"title": "CI"}, "repository": {"full_name": "a/b", "html_url": "https://github.com/a/b"}},
        {"id": "3", "reason": "subscribed", "updated_at": DATE, "subject": {"title": "x"}, "repository": {"full_name": "a/b"}},
    ]);
    let mut sync = GitHubSync::new();
    let response = Response { status: 200, etag: None, body: rows.to_string().into_bytes() };
    let effects = sync.apply(Query::Notifications, &response, NOW).unwrap();
    assert_eq!(effects.len(), 2, "unsupported reasons are left out");
    let Effect::Post(review) = &effects[0] else { panic!() };
    assert_eq!(review.dedupe_key.as_deref(), Some("github:review:a/b:7"));
    assert_eq!(review.context_str("url"), Some("https://github.com/a/b/pull/7"));
    assert_eq!((review.kind.as_str(), review.body.as_str()), ("review", "a/b#7"));
    assert_eq!(review.thread.as_deref(), Some("github:a/b"));
    let Effect::Post(ci) = &effects[1] else { panic!() };
    assert_eq!(ci.dedupe_key.as_deref(), Some("github:notification:2"));
    assert_eq!(
        (ci.kind.as_str(), ci.priority, ci.body.as_str()),
        ("notice", Priority::High, "a/b")
    );
    assert_eq!(ci.context_str("url"), Some("https://github.com/a/b"));
}

#[test]
fn gh_asks_with_its_queries_and_etags_and_its_output_parses() {
    assert_eq!(
        Query::HeldForTrial.gh_args(Some("W/\"1\"")),
        [
            "api",
            "--include",
            "-X",
            "GET",
            "search/issues",
            "-f",
            "per_page=50",
            "-f",
            "q=is:pr is:open author:@me label:hold archived:false",
            "-H",
            "If-None-Match: W/\"1\""
        ]
    );
    assert_eq!(
        Query::Notifications.gh_args(None),
        ["api", "--include", "-X", "GET", "notifications", "-f", "per_page=100"]
    );
    let parsed = parse_http(b"HTTP/2.0 304 Not Modified\r\nEtag: \"abc\"\r\n\r\n");
    assert_eq!(
        (parsed.status, parsed.etag.as_deref(), parsed.body.len()),
        (304, Some("\"abc\""), 0)
    );
    let parsed = parse_http(b"HTTP/2.0 200 OK\nETag: \"x\"\n\n[1]");
    assert_eq!((parsed.status, parsed.body.as_slice()), (200, b"[1]".as_slice()));
    assert_eq!(parse_http(b"[]").status, 200);
    assert_eq!(stable_id("k").len(), 23);
    assert!(stable_id("k").starts_with("fi_"));
    assert_eq!(parse_time("1970-01-01T00:00:01Z"), Some(1000));
}

// MARK: Reports (FeedLocalOwnerBoundTests)

#[test]
fn the_reports_basket_shows_the_newest_reports() {
    let mut reports = Reports::default();
    let rows: Vec<Value> = (0..REPORTS_LIMIT * 5)
        .map(|i| json!({"message": {"id": format!("r{i}"), "sender": "host/a", "body": format!("report {i}"), "seq": i, "createdAt": i}}))
        .collect();
    let page = MailPage::from_value(&json!({"messages": rows}));
    assert_eq!(page.cursor_after(3), (REPORTS_LIMIT * 5 - 1) as u64);
    assert!(reports.apply(&page));
    let list = reports.list();
    assert_eq!(list.len(), REPORTS_LIMIT);
    assert_eq!(list[0].id, format!("r{}", REPORTS_LIMIT * 5 - 1));
    assert_eq!(list[REPORTS_LIMIT - 1].id, format!("r{}", REPORTS_LIMIT * 4));
    assert!(!reports.apply(&page), "the same page changes nothing");
    assert_eq!(
        MailPage::from_value(&json!({"messages": [], "nextCursor": 9})).cursor_after(12),
        12,
        "never back"
    );
}
