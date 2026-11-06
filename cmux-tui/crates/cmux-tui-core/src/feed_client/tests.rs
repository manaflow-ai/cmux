//! The daemon's feed client against a scripted cloud backend, `gh` and
//! acpmux mailbox (ports of Swift `CloudFeedSourceTests`,
//! `CloudFeedSourceAuthTests`, `FeedModelTests`' settle rules,
//! `GitHubFeedSourceTests`' poll and `AcpmuxMailboxReaderTests`).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

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
        place: Arc::new(|_| None),
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
    // Another account empties the basket.
    let events =
        super::driver::change_account(&mut h.feed.inner.lock(), Some("u2".to_owned()), NOW);
    assert_eq!(events, vec![FeedEvent::Reports { revision: 2 }]);
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
