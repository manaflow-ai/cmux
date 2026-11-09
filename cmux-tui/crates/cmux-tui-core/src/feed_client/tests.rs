//! The daemon's feed client against a scripted cloud backend, `gh` and
//! acpmux mailbox (ports of Swift `CloudFeedSourceTests`,
//! `CloudFeedSourceAuthTests`, `FeedModelTests`' settle rules,
//! `GitHubFeedSourceTests`' poll and `AcpmuxMailboxReaderTests`).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_feed_core::client::github::Query;
use cmux_feed_core::client::{FeedItem, Layout, Poster, Priority, Reject, ViewRequest};
use serde_json::{Value, json};

use super::{
    FeedClient, FeedDeps, FeedError, FeedEvent, GhRunner, GitHubConfig, IntentReply, Mailbox,
};
use crate::cloud_conversations::testing::{FakeBackend, ScriptedWire, wait_until};
use crate::cloud_conversations::{CloudConversations, CloudEvent, ConnectError};

const NOW: i64 = 1_800_000_000_000;

#[derive(Default)]
struct FakeGh {
    answers: Mutex<VecDeque<Result<Vec<u8>, String>>>,
    calls: Mutex<Vec<Vec<String>>>,
}

impl GhRunner for FakeGh {
    fn run(&self, args: &[String]) -> Result<Vec<u8>, String> {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner).push(args.to_vec());
        self.answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| Ok(b"HTTP/2.0 304 Not Modified\r\n\r\n".to_vec()))
    }
}

#[derive(Default)]
struct FakeMailbox {
    pages: Mutex<VecDeque<Result<Value, String>>>,
    asked: Mutex<Vec<(String, u64)>>,
}

impl Mailbox for FakeMailbox {
    fn available(&self) -> bool {
        true
    }

    fn wait(&self, recipient: &str, after: u64, _: usize, _: Duration) -> Result<Value, String> {
        self.asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((recipient.to_owned(), after));
        let next = self.pages.lock().unwrap_or_else(PoisonError::into_inner).pop_front();
        // An empty mailbox answers after a short wait, as acpmux's timeout.
        next.unwrap_or_else(|| {
            std::thread::sleep(Duration::from_millis(20));
            Ok(json!({"messages": [], "nextCursor": after}))
        })
    }
}

struct Harness {
    feed: FeedClient,
    events: Arc<Mutex<Vec<FeedEvent>>>,
    gh: Arc<FakeGh>,
    mailbox: Arc<FakeMailbox>,
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.feed.shutdown();
    }
}

fn harness(cloud: Option<CloudConversations>) -> Harness {
    let events = Arc::new(Mutex::new(Vec::new()));
    let gh = Arc::new(FakeGh::default());
    let mailbox = Arc::new(FakeMailbox::default());
    let sink = Arc::clone(&events);
    let feed = FeedClient::new(FeedDeps {
        cloud,
        gh: gh.clone(),
        mailbox: mailbox.clone(),
        sink: Arc::new(move |event| {
            sink.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        }),
        now_ms: Arc::new(|| NOW),
        place: Arc::new(|| Box::new(|_| None)),
    });
    Harness { feed, events, gh, mailbox }
}

fn signed_in(backend: &Arc<FakeBackend>) -> (CloudConversations, Arc<Mutex<Vec<CloudEvent>>>) {
    let cloud = CloudConversations::new(backend.clone());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&seen);
    cloud.set_sink(Arc::new(move |event| {
        sink.lock().unwrap_or_else(PoisonError::into_inner).push(event);
    }));
    cloud
        .set_session(
            serde_json::from_value(json!({
                "api_base_url": "https://api.cmux.test", "access_token": "stack.jwt.token",
                "expires_at": 4_102_444_800_000_u64
            }))
            .unwrap(),
        )
        .unwrap();
    (cloud, seen)
}

fn request(id: &str) -> FeedItem {
    let mut item = FeedItem::notice(id, "Ship it?", Poster::new("agent", "Agent"), NOW - 1000);
    item.kind = "question".to_owned();
    item.priority = Priority::Normal;
    item.prompt = json!({"question": "Ship?"});
    item
}

fn local_request(id: &str) -> FeedItem {
    let mut item = request(id);
    item.home = "local:test".to_owned();
    item
}

fn view(feed: &FeedClient) -> Value {
    feed.view(&ViewRequest { layout: Layout::List, ..ViewRequest::default() })
}

fn connected(wire: &ScriptedWire, items: Vec<FeedItem>) {
    wire.push_text(json!({"t": "welcome", "principal": {"user": "u1"}}).to_string());
    let items: serde_json::Map<String, Value> =
        items.into_iter().map(|item| (item.id.clone(), item.to_value())).collect();
    wire.push_text(
        json!({"t": "snapshot", "seq": 1, "state": {"user": "u1", "items": items}}).to_string(),
    );
}

fn sent_ops(wire: &ScriptedWire) -> Vec<Value> {
    wire.sent()
        .iter()
        .filter_map(|text| serde_json::from_str::<Value>(text).ok())
        .filter(|frame| frame["t"] == "op")
        .collect()
}

#[test]
fn the_client_subscribes_on_the_lease_and_mirrors_the_snapshot() {
    let backend = Arc::new(FakeBackend::default());
    let wire = backend.wire();
    connected(&wire, vec![request("fi_1")]);
    let (cloud, _) = signed_in(&backend);
    let h = harness(Some(cloud));
    wait_until("the snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    let connections = backend.connected();
    assert!(connections[0].url.ends_with("/v1/wire/feed"), "{connections:?}");
    assert_eq!(connections[0].bearer, "stack.jwt.token");
    let shown = view(&h.feed);
    assert_eq!(shown["groups"][0]["entries"][0]["id"], "fi_1", "{shown}");
    assert_eq!(shown["counts"]["open_requests"], 1);
    let subscribe: Value = serde_json::from_str(&wire.sent()[0]).unwrap();
    assert_eq!(subscribe, json!({"t": "subscribe", "stream": "feed:u1", "pending": []}));
    assert!(h.events.lock().unwrap().iter().any(|event| matches!(event, FeedEvent::View { .. })));
}

/// A first connection that fails leaves the view unloaded, so the app sends
/// no empty Needs you set to the phone (which would close its requests); the
/// next connection's snapshot loads it with the items.
#[test]
fn a_failed_first_connection_is_not_loaded_until_a_snapshot_comes() {
    let backend = Arc::new(FakeBackend::default());
    let (cloud, _) = signed_in(&backend);
    let h = harness(Some(cloud));
    wait_until("the failed first connection", || {
        let shown = view(&h.feed);
        shown["connection"]["state"] == "disconnected" && shown["connection"]["reason"] == "offline"
    });
    let offline = view(&h.feed);
    assert_eq!(offline["loaded"], false, "{offline}");
    assert_eq!(offline["total"], 0, "{offline}");
    // The backoff's next connection takes the snapshot.
    let wire = backend.wire();
    connected(&wire, vec![request("fi_1")]);
    wait_until("the snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    let shown = view(&h.feed);
    assert_eq!(shown["loaded"], true, "{shown}");
    assert_eq!(shown["groups"][0]["entries"][0]["id"], "fi_1", "{shown}");
}

fn person_session(user_payload: &str) -> serde_json::Value {
    json!({
        "api_base_url": "https://api.cmux.test",
        "access_token": format!("eyJhbGciOiJub25lIn0.{user_payload}.sig"),
        "expires_at": 4_102_444_800_000_u64
    })
}

/// The view names the account it is for (the lease's person) from the
/// moment the lease names it, before any snapshot: a reader that kept
/// account A's requests drops them when B's view arrives, even while B is
/// unloaded and its connections fail. Signed out the view is no one's.
#[test]
fn the_view_names_its_account_before_any_snapshot() {
    const USER_1: &str = "eyJzdWIiOiJzdGFja191c2VyXzEiLCJhdWQiOiJwcm9qXzEifQ";
    const USER_2: &str = "eyJzdWIiOiJzdGFja191c2VyXzIiLCJhdWQiOiJwcm9qXzEifQ";
    let signed_out = harness(None);
    let none = view(&signed_out.feed);
    assert_eq!(none["account"], Value::Null, "{none}");
    drop(signed_out);

    let backend = Arc::new(FakeBackend::default());
    let cloud = CloudConversations::new(backend.clone());
    cloud.set_session(serde_json::from_value(person_session(USER_1)).unwrap()).unwrap();
    let wire = backend.wire();
    connected(&wire, vec![request("fi_a")]);
    let h = harness(Some(cloud.clone()));
    wait_until("A's snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    let a = view(&h.feed);
    assert_eq!(
        a["account"],
        json!({"id": "stack:proj_1:stack_user_1", "user": "stack_user_1"}),
        "{a}"
    );
    assert_eq!(a["loaded"], true, "{a}");
    // B's lease: no connection will take it (the fake has no wire left).
    cloud.set_session(serde_json::from_value(person_session(USER_2)).unwrap()).unwrap();
    h.feed.lease_changed();
    let b = view(&h.feed);
    assert_eq!(
        b["account"],
        json!({"id": "stack:proj_1:stack_user_2", "user": "stack_user_2"}),
        "{b}"
    );
    assert_eq!(b["loaded"], false, "{b}");
    assert_eq!(b["total"], 0, "A's request is gone from B's view: {b}");
    wait_until("B's failed connection", || view(&h.feed)["connection"]["reason"] == "offline");
    let failed = view(&h.feed);
    assert_eq!(failed["account"]["id"], "stack:proj_1:stack_user_2", "{failed}");
    assert_eq!(failed["loaded"], false, "{failed}");
}

#[test]
fn an_answer_shows_at_once_and_answers_on_the_owners_settle_line() {
    let backend = Arc::new(FakeBackend::default());
    let wire = backend.wire();
    connected(&wire, vec![request("fi_1")]);
    let (cloud, _) = signed_in(&backend);
    let h = harness(Some(cloud));
    wait_until("the snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    let reply =
        h.feed.intent("k1", &json!({"kind": "answer", "item": "fi_1", "answer": "yes"})).unwrap();
    let item = &h.feed.items(&["fi_1".to_owned()], false)[0];
    assert_eq!(item["pending"], true);
    assert_eq!(item["state"], "answered", "{item}");
    // The owner's item is unchanged until it commits.
    assert_eq!(h.feed.items(&["fi_1".to_owned()], true)[0]["state"], "open");
    wait_until("the op frame", || !sent_ops(&wire).is_empty());
    let op = &sent_ops(&wire)[0];
    assert_eq!(op["op"], "feed.answer", "{op}");
    assert_eq!(op["idempotency_key"], "k1");
    assert_eq!(op["origin"], "user");
    let mut answered = request("fi_1");
    answered.state = cmux_feed_core::client::State::Answered;
    answered.answer = Some(json!("yes"));
    answered.revision = 2;
    wire.push_text(json!({"t": "event", "seq": 2, "items": [answered.to_value()]}).to_string());
    wire.push_text(json!({"t": "request-settled", "idempotency_key": "k1"}).to_string());
    assert_eq!(reply.wait(), Some(Ok(())));
    let item = &h.feed.items(&["fi_1".to_owned()], false)[0];
    assert_eq!(item["pending"], false);
    assert_eq!(item["state"], "answered");
    // A retry of the settled key answers again without a second op.
    assert!(matches!(
        h.feed.intent("k1", &json!({"kind": "decline", "item": "fi_1"})),
        Ok(IntentReply::Now(Ok(())))
    ));
    assert_eq!(sent_ops(&wire).len(), 1);
}

#[test]
fn a_late_answer_is_refused_with_the_owners_item() {
    let backend = Arc::new(FakeBackend::default());
    let wire = backend.wire();
    connected(&wire, vec![request("fi_1")]);
    let (cloud, _) = signed_in(&backend);
    let h = harness(Some(cloud));
    wait_until("the snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    let reply =
        h.feed.intent("k1", &json!({"kind": "answer", "item": "fi_1", "answer": "yes"})).unwrap();
    wait_until("the op frame", || !sent_ops(&wire).is_empty());
    let mut closed = request("fi_1");
    closed.state = cmux_feed_core::client::State::Answered;
    closed.revision = 3;
    wire.push_text(
        json!({"t": "reject", "idempotency_key": "k1", "code": "feed.closed", "message": "answered", "details": {"item": closed.to_value()}})
            .to_string(),
    );
    wire.push_text(json!({"t": "request-settled", "idempotency_key": "k1"}).to_string());
    match reply.wait() {
        Some(Err(Reject::Closed(item))) => assert_eq!(item.id, "fi_1"),
        other => panic!("expected feed.closed, got {other:?}"),
    }
    assert_eq!(h.feed.items(&["fi_1".to_owned()], true)[0]["state"], "answered");
}

#[test]
fn a_refused_token_asks_the_app_for_a_new_lease_and_waits_for_it() {
    let backend = Arc::new(FakeBackend::default());
    backend.refuse(ConnectError::Unauthenticated);
    let (cloud, seen) = signed_in(&backend);
    let h = harness(Some(cloud.clone()));
    wait_until("the unauthenticated state", || {
        view(&h.feed)["connection"]["reason"] == "unauthenticated"
    });
    wait_until("cloud-session-needed", || {
        seen.lock().unwrap().iter().any(|event| {
            matches!(event, CloudEvent::SessionNeeded { reason: "unauthenticated", .. })
        })
    });
    // The same token is not tried again; a new lease reconnects.
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(backend.connected().len(), 1);
    let wire = backend.wire();
    connected(&wire, vec![]);
    cloud
        .set_session(
            serde_json::from_value(json!({
                "api_base_url": "https://api.cmux.test", "access_token": "renewed.jwt.token",
                "expires_at": 4_102_444_800_000_u64
            }))
            .unwrap(),
        )
        .unwrap();
    wait_until("the reconnect", || view(&h.feed)["connection"]["state"] == "connected");
    assert_eq!(backend.connected()[1].bearer, "renewed.jwt.token");
}

#[test]
fn a_cloud_intent_while_disconnected_is_refused_and_local_items_still_change() {
    let h = harness(None);
    let posted = h.feed.post(local_request("fi_local"));
    assert!(!posted.deduped);
    assert_eq!(h.feed.post(local_request("fi_local")).id, "fi_local");
    let reply = h
        .feed
        .intent("k1", &json!({"kind": "answer", "item": "fi_local", "answer": "ok"}))
        .unwrap();
    assert_eq!(reply.wait(), Some(Ok(())));
    let item = &h.feed.items(&["fi_local".to_owned()], true)[0];
    assert_eq!(item["state"], "answered", "{item}");
    // A second answer is refused with the owner's item.
    match h.feed.intent("k2", &json!({"kind": "answer", "item": "fi_local", "answer": "no"})) {
        Err(FeedError::Rejected(Reject::Closed(item))) => assert_eq!(item.id, "fi_local"),
        other => panic!("expected feed.closed, got {:?}", other.map(|_| ())),
    }
    assert_eq!(h.feed.list(Some("closed"), Some("local"), true).len(), 1);
    assert!(h.feed.list(Some("open"), None, true).is_empty());
    assert_eq!(h.feed.withdraw("nothing"), Vec::<String>::new());
}

#[test]
fn an_intent_is_checked_before_it_is_logged() {
    let h = harness(None);
    h.feed.post(local_request("fi_1"));
    let invalid = |params: Value| matches!(h.feed.intent("k", &params), Err(FeedError::Invalid(_)));
    assert!(invalid(json!({"kind": "fly"})));
    assert!(invalid(json!({"kind": "answer", "item": "nope", "answer": "x"})));
    assert!(invalid(json!({"kind": "answer", "item": "fi_1"})));
    assert!(invalid(json!({"kind": "read", "items": []})));
    // More ids than one cloud op carries is refused, never shown changed and sent cut short.
    let many: Vec<String> = (0..=256).map(|n| format!("fi_{n}")).collect();
    assert!(invalid(json!({"kind": "read", "items": many})));
    assert!(invalid(json!({"kind": "snooze", "items": ["fi_1"]})));
    // Nothing left to send settles at once (an open request is not archivable).
    assert!(matches!(
        h.feed.intent("k3", &json!({"kind": "archive", "items": ["fi_1"]})),
        Ok(IntentReply::Now(Ok(())))
    ));
}

fn search(pulls: Value) -> Vec<u8> {
    format!("HTTP/2.0 200 OK\r\nETag: \"e1\"\r\n\r\n{}", json!({"items": pulls})).into_bytes()
}

fn review_pull() -> Value {
    json!({"id": 7, "number": 7, "title": "Fix it", "html_url": "https://github.com/acme/app/pull/7",
           "repository_url": "https://api.github.com/repos/acme/app", "user": {"login": "you"},
           "state": "open", "updated_at": "2026-11-06T10:00:00Z"})
}

#[test]
fn the_github_poller_posts_with_etags_and_stops_when_turned_off() {
    let h = harness(None);
    {
        let mut answers = h.gh.answers.lock().unwrap();
        answers.push_back(Ok(b"HTTP/2.0 304 Not Modified\r\nETag: \"n1\"\r\n\r\n".to_vec()));
        answers.push_back(Ok(search(json!([review_pull()]))));
    }
    h.feed.configure_github(GitHubConfig { enabled: true, interval_s: 3600 });
    wait_until("the review request", || h.feed.list(Some("open"), Some("local"), true).len() == 1);
    let shown = view(&h.feed);
    assert_eq!(shown["github"]["enabled"], true);
    let item = &shown["groups"][0]["entries"][0]["item"];
    assert_eq!(item["github"]["number"], 7, "{item}");
    assert!(
        item["github_actions"].as_array().is_some_and(|actions| actions.contains(&json!("open")))
    );
    // A refresh is one more pass, with the ETags it learned.
    wait_until("the first pass", || h.gh.calls.lock().unwrap().len() >= 4);
    assert!(h.feed.refresh_github());
    wait_until("the refresh", || h.gh.calls.lock().unwrap().len() >= 8);
    let calls = h.gh.calls.lock().unwrap().clone();
    assert!(calls[4].iter().any(|arg| arg == "If-None-Match: \"n1\""), "{:?}", calls[4]);
    h.feed.configure_github(GitHubConfig { enabled: false, interval_s: 3600 });
    wait_until("the poller to stop", || !h.feed.inner.lock().github_running);
    assert!(!h.feed.refresh_github());
}

#[test]
fn another_account_starts_the_github_poller_over() {
    let h = harness(None);
    super::driver::change_account(&mut h.feed.inner.lock(), Some("u1".to_owned()), NOW);
    {
        let mut answers = h.gh.answers.lock().unwrap();
        answers.push_back(Ok(b"HTTP/2.0 304 Not Modified\r\nETag: \"n1\"\r\n\r\n".to_vec()));
        answers.push_back(Ok(search(json!([review_pull()]))));
    }
    h.feed.configure_github(GitHubConfig { enabled: true, interval_s: 3600 });
    wait_until("the first pass", || h.gh.calls.lock().unwrap().len() >= 4);
    wait_until("the review request", || h.feed.list(Some("open"), Some("local"), true).len() == 1);
    assert!(h.feed.inner.lock().github.etag(Query::POLLED[0]).is_some());
    let epoch = h.feed.inner.lock().github_epoch;
    {
        let mut state = h.feed.inner.lock();
        super::driver::change_account(&mut state, Some("u2".to_owned()), NOW);
        assert!(state.owner.is_empty(), "a GitHub row of the old account stays");
        assert_eq!(state.github_epoch, epoch.wrapping_add(1));
        assert!(
            state.github.etag(Query::POLLED[0]).is_none(),
            "an ETag of the old account is kept"
        );
    }
    h.feed.inner.wake.notify_all();
    // The account change wakes the poller for a pass with no old validators.
    wait_until("the pass for the new account", || h.gh.calls.lock().unwrap().len() >= 8);
    let calls = h.gh.calls.lock().unwrap().clone();
    for call in calls.get(4..8).unwrap_or_default() {
        assert!(!call.iter().any(|arg| arg.starts_with("If-None-Match")), "{call:?}");
    }
    let epoch = h.feed.inner.lock().github_epoch;
    h.feed.configure_github(GitHubConfig { enabled: false, interval_s: 3600 });
    assert_eq!(h.feed.inner.lock().github_epoch, epoch.wrapping_add(1), "a poll in flight is kept");
    wait_until("the poller to stop", || !h.feed.inner.lock().github_running);
}

#[test]
fn reports_read_the_users_mailbox_and_page_by_cursor() {
    let h = harness(None);
    h.mailbox.pages.lock().unwrap().push_back(Ok(json!({
        "messages": [{"message": {"id": "r1", "seq": 4, "sender": "host:s1", "body": "done", "createdAt": NOW}}],
        "nextCursor": 4,
    })));
    h.feed.ensure_started();
    {
        let mut state = h.feed.inner.lock();
        let events = super::driver::change_account(&mut state, Some("u1".to_owned()), NOW);
        assert!(events.is_empty());
    }
    h.feed.inner.wake.notify_all();
    wait_until("the report", || {
        h.feed.reports()["reports"].as_array().is_some_and(|rows| rows.len() == 1)
    });
    let reports = h.feed.reports();
    assert_eq!(
        reports["reports"][0],
        json!({"id": "r1", "sender": "host:s1", "body": "done", "created_at": NOW})
    );
    assert_eq!(reports["available"], true);
    wait_until("the next wait", || h.mailbox.asked.lock().unwrap().len() >= 2);
    let asked = h.mailbox.asked.lock().unwrap().clone();
    assert_eq!(asked[0], ("reports:u1".to_owned(), 0));
    assert_eq!(asked[1], ("reports:u1".to_owned(), 4));
    assert!(
        h.events
            .lock()
            .unwrap()
            .iter()
            .any(|event| matches!(event, FeedEvent::Reports { revision: 1 }))
    );
    // Signed out and in again as the same person: the basket was emptied, so
    // the mailbox is read from the start, not from the old cursor.
    let events = super::driver::change_account(&mut h.feed.inner.lock(), None, NOW);
    assert!(events.contains(&FeedEvent::Reports { revision: 2 }), "{events:?}");
    super::driver::change_account(&mut h.feed.inner.lock(), Some("u1".to_owned()), NOW);
    h.feed.inner.wake.notify_all();
    wait_until("the read from the start", || {
        h.mailbox
            .asked
            .lock()
            .unwrap()
            .iter()
            .skip(2)
            .any(|asked| asked == &("reports:u1".to_owned(), 0))
    });
}

#[test]
fn a_lease_of_another_person_forgets_the_old_account_before_it_connects() {
    let backend = Arc::new(FakeBackend::default());
    let cloud = CloudConversations::new(backend);
    cloud
        .set_session(
            serde_json::from_value(json!({
                "api_base_url": "https://api.cmux.test",
                "access_token": "eyJhbGciOiJub25lIn0.eyJzdWIiOiJzdGFja191c2VyXzEiLCJhdWQiOiJwcm9qXzEifQ.sig",
                "expires_at": 4_102_444_800_000_u64
            }))
            .unwrap(),
        )
        .unwrap();
    let h = harness(Some(cloud.clone()));
    {
        // Account A was read on another person's lease.
        let mut state = h.feed.inner.lock();
        state.lease_identity = Some("stack:proj_1:stack_user_0".to_owned());
        super::driver::change_account(&mut state, Some("user_a".to_owned()), NOW);
        let _ = state.mirror.cloud_snapshot("user_a", vec![request("fi_a")], NOW);
    }
    // (The mirror itself: a feed read would start the driver, which does the same.)
    assert!(h.feed.inner.lock().mirror.confirmed("fi_a").is_some());
    // Before any socket opens on the new lease, A's items are gone (the
    // daemon's cloud-session-set calls this).
    h.feed.lease_changed();
    let state = h.feed.inner.lock();
    assert!(state.mirror.confirmed("fi_a").is_none());
    assert_eq!(state.account, None);
    assert_eq!(state.lease_identity.as_deref(), Some("stack:proj_1:stack_user_1"));
    drop(state);
    // The same person's lease (a refreshed token) keeps what it has.
    h.feed.inner.lock().account = Some("user_b".to_owned());
    super::driver::forget_other_lease(&h.feed.inner, &cloud);
    assert_eq!(h.feed.inner.lock().account.as_deref(), Some("user_b"));
}

#[test]
fn a_frame_of_an_old_lease_is_dropped_under_the_feed_lock() {
    let h = harness(None);
    let welcome = json!({"t": "welcome", "principal": {"user": "user_a"}}).to_string();
    // The lease moved after the receive returned: nothing of the frame lands.
    assert_eq!(
        super::driver::apply(&h.feed.inner, &welcome, || false),
        super::driver::Applied::OldLease
    );
    assert_eq!(h.feed.inner.lock().account, None);
    assert_eq!(
        super::driver::apply(&h.feed.inner, &welcome, || true),
        super::driver::Applied::Frame
    );
    assert_eq!(h.feed.inner.lock().account.as_deref(), Some("user_a"));
}

#[test]
fn the_reports_mailbox_is_the_lease_s_stack_user() {
    let backend = Arc::new(FakeBackend::default());
    let cloud = CloudConversations::new(backend);
    // {"sub":"stack_user_1","aud":"proj_1"}: the address the app's reader used before.
    cloud
        .set_session(
            serde_json::from_value(json!({
                "api_base_url": "https://api.cmux.test",
                "access_token": "eyJhbGciOiJub25lIn0.eyJzdWIiOiJzdGFja191c2VyXzEiLCJhdWQiOiJwcm9qXzEifQ.sig",
                "expires_at": 4_102_444_800_000_u64
            }))
            .unwrap(),
        )
        .unwrap();
    let h = harness(Some(cloud));
    // Signed in, before (or without) any FeedDO welcome: the lease names the mailbox.
    assert_eq!(super::reports::person(&h.feed.inner, None).as_deref(), Some("stack_user_1"));
    assert_eq!(
        super::reports::person(&h.feed.inner, Some("user_0123abcd")).as_deref(),
        Some("stack_user_1")
    );
    assert_eq!(view(&h.feed)["reports"]["available"], true, "Reports show with FeedDO unreachable");
    // With no lease person (no cloud link, a self-hosted lease) the account itself.
    assert_eq!(
        super::reports::person(&harness(None).feed.inner, Some("u1")).as_deref(),
        Some("u1")
    );
    assert_eq!(super::reports::person(&harness(None).feed.inner, None), None);
}

#[test]
fn a_reply_goes_through_the_installed_sender() {
    let h = harness(None);
    assert!(!h.feed.reply("host:s1", "thanks", "p1"));
    let sent = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&sent);
    h.feed.set_reply_sender(Some(Arc::new(move |session: &str, text: &str, prompt: &str| {
        log.lock().unwrap().push((session.to_owned(), text.to_owned(), prompt.to_owned()));
        true
    })));
    assert!(h.feed.reply("host:s1", "thanks", "p1"));
    assert_eq!(
        *sent.lock().unwrap(),
        vec![("host:s1".to_owned(), "thanks".to_owned(), "p1".to_owned())]
    );
}

#[test]
fn shutdown_ends_every_thread() {
    let backend = Arc::new(FakeBackend::default());
    let wire = backend.wire();
    connected(&wire, vec![]);
    let (cloud, _) = signed_in(&backend);
    let h = harness(Some(cloud));
    h.feed.configure_github(GitHubConfig { enabled: true, interval_s: 3600 });
    wait_until("the snapshot", || view(&h.feed)["connection"]["state"] == "connected");
    h.feed.shutdown();
    wait_until("the poller to stop", || !h.feed.inner.lock().github_running);
    wait_until("the driver to stop", || view(&h.feed)["connection"]["state"] == "disconnected");
}

#[test]
fn find_work_reads_reviews_and_assignments_now() {
    let h = harness(None);
    h.gh.answers.lock().unwrap().push_back(Ok(search(json!([review_pull()]))));
    h.gh.answers.lock().unwrap().push_back(Ok(search(json!([]))));
    let work = h.feed.find_work().unwrap();
    assert_eq!(work["reviews"][0]["author"], "you", "{work}");
    assert_eq!(work["reviews"][0]["repo"], "acme/app", "{work}");
    assert_eq!(work["reviews"][0]["number"], 7, "{work}");
    assert_eq!(work["assigned"], json!([]));
    h.gh.answers.lock().unwrap().push_back(Err("gh is not installed".to_owned()));
    assert!(matches!(h.feed.find_work(), Err(FeedError::Unavailable(_))));
}
