//! Behavior of the cloud conversations proxy (home-cloud-proxy.md): request
//! and reply mapping, the upstream stream state machine, and the service
//! with a scripted backend. Frames use the shapes of backend/apps/api and
//! home-core (ConversationDO snapshot and event frames, inbox entries).

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};

use super::contract::{mutation_data, op_body, read_value};
use super::stream::{StreamAction, StreamState};
use super::testing::{Events, FakeBackend, wait_until};
use super::*;

pub(crate) const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const ME: &str = "user_00000000000000000001";
const OTHER: &str = "user_00000000000000000002";
const ORIGIN: &str = "https://api.cmux.test";

pub(crate) fn message(seq: u64, author: &str, text: &str) -> Value {
    json!({"id": format!("msg_{seq:026}"), "conversation": CONV, "seq": seq,
           "client_msg_id": format!("c{seq}"), "author": author,
           "parts": [{"type": "text", "text": text}],
           "created_at": "2026-10-03T00:00:00.000Z", "reactions": []})
}

pub(crate) fn head(rev: u64, last_seq: u64) -> Value {
    json!({"id": CONV, "title": "Launch", "kind": "group", "created_by": ME,
           "participants": [{"id": ME, "kind": "human", "display_name": "Me", "role": "owner", "joined_seq": 0}],
           "last_seq": last_seq, "rev": rev, "created_at": "2026-10-03T00:00:00.000Z",
           "updated_at": "2026-10-03T00:00:00.000Z", "read_cursors": {ME: 1}, "state": "active",
           "settings": {"wake_policy": "auto", "agent_budget": {"turns": 4, "gap_ms": 2000}, "history_visible": "all"},
           "agent_text_streak": 0,
           "invites": [{"id": "inv_1", "address": "addr_1", "token_hash": "secret-hash", "status": "pending"}]})
}

pub(crate) fn snapshot_frame(seq: u64, rev: u64, messages: &[Value]) -> Value {
    let rows: Vec<Value> =
        messages.iter().map(|m| json!({"key": m["id"], "n": m["seq"], "row": m})).collect();
    json!({"t": "snapshot", "stream": format!("conv:{CONV}"), "seq": seq,
           "state": head(rev, messages.len() as u64), "decided": [],
           "rows": {"table": "msg", "rows": rows}})
}

pub(crate) fn send_event(seq: u64, rev: u64, msg: &Value) -> Value {
    json!({"t": "event", "stream": format!("conv:{CONV}"), "seq": seq, "tx": format!("tx{seq}"),
           "op": "message.send", "params": {"client_msg_id": msg["client_msg_id"]},
           "actor": {"identity": format!("user:{ME}"), "user": ME, "kind": "session"},
           "origin": "user", "at": 1,
           "effects": {"state": head(rev, msg["seq"].as_u64().unwrap()),
                       "writes": [{"table": "msg", "op": "upsert", "key": msg["id"], "n": msg["seq"], "row": msg},
                                  {"table": "msgkey", "op": "upsert", "key": "k", "n": null, "row": {}}]}})
}

fn welcome() -> String {
    welcome_as(ME)
}

fn welcome_as(user: &str) -> String {
    json!({"t": "welcome", "principal": {"user": user}, "server_time": 1, "streams": [format!("conv:{CONV}")]}).to_string()
}

fn inbox_snapshot(user: &str, seq: u64) -> String {
    json!({"t": "snapshot", "stream": format!("inbox:{user}"), "seq": seq, "state": {"next_pin": 0}, "decided": []}).to_string()
}

pub(crate) fn session_params(expires_at: u64) -> SessionParams {
    SessionParams {
        api_base_url: ORIGIN.into(),
        access_token: "stack.jwt.token".into(),
        expires_at,
        client_version: Some("0.70.0".into()),
    }
}

/// The frame a `Send` action carries, as JSON (key order is not part of the wire).
fn sent(action: &StreamAction) -> Value {
    match action {
        StreamAction::Send(text) => serde_json::from_str(text).unwrap(),
        other => panic!("expected a frame to send, got {other:?}"),
    }
}

fn frames(texts: Vec<String>) -> Vec<Value> {
    texts.iter().map(|text| serde_json::from_str(text).unwrap()).collect()
}

fn op_request(conversation: Option<&str>, key: &str, op: Value) -> OpRequest {
    OpRequest {
        conversation: conversation.map(str::to_string),
        idempotency_key: key.into(),
        origin: None,
        op,
    }
}

fn service(backend: &Arc<FakeBackend>) -> (CloudConversations, Events) {
    let clock = Arc::new(AtomicU64::new(1_000_000));
    let options = ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        max_conversation_subscriptions: 2,
        max_concurrent_requests: 2,
        now_ms: Arc::new(move || clock.load(Ordering::SeqCst)),
    };
    let service = CloudConversations::with_options(backend.clone(), options);
    let events = Events::default();
    service.set_sink(events.sink());
    (service, events)
}

#[test]
fn stream_resumes_drops_duplicates_and_resyncs_on_a_gap() {
    let mut stream = StreamState::new(Target::Conversation(CONV.into()));
    let actions = stream.on_text(&welcome());
    assert_eq!(actions.len(), 2);
    assert_eq!(sent(&actions[0]), json!({"t": "subscribe"}));
    assert_eq!(actions[1], StreamAction::Live);
    // Nothing is confirmed before the snapshot.
    assert!(stream.on_text(&send_event(4, 4, &message(1, ME, "early")).to_string()).is_empty());
    let resynced = stream.on_text(&snapshot_frame(4, 4, &[message(1, ME, "one")]).to_string());
    assert!(matches!(
        &resynced[..],
        [StreamAction::Emit(CloudEvent::ConversationResynced { seq: 4, rev: 4, .. })]
    ));
    let next = stream.on_text(&send_event(5, 5, &message(2, ME, "two")).to_string());
    assert!(matches!(
        &next[..],
        [StreamAction::Emit(CloudEvent::ConversationChanged { seq: 5, rev: 5, .. })]
    ));
    assert!(
        stream.on_text(&send_event(5, 5, &message(2, ME, "two")).to_string()).is_empty(),
        "duplicate"
    );
    let gap = stream.on_text(&send_event(7, 7, &message(4, ME, "gap")).to_string());
    assert_eq!(gap.len(), 1);
    assert_eq!(sent(&gap[0]), json!({"t": "snapshot.request"}));
    assert!(stream.on_text(&send_event(8, 8, &message(5, ME, "held")).to_string()).is_empty());
    stream.on_text(&snapshot_frame(8, 8, &[]).to_string());
    assert_eq!(stream.last_seq(), Some(8));
    stream.on_connect();
    assert_eq!(sent(&stream.on_text(&welcome())[0]), json!({"t": "subscribe", "after_seq": 8}));
    // Another conversation's frames are ignored.
    let mut other = send_event(9, 9, &message(6, ME, "x"));
    other["stream"] = json!("conv:conv_OTHER");
    assert!(stream.on_text(&other.to_string()).is_empty());
}

fn is_state(event: &CloudEvent, wanted: &str) -> bool {
    matches!(event, CloudEvent::SubscriptionState { state, .. } if *state == wanted)
}

#[test]
fn conversation_subscription_relays_events_and_resumes_after_a_drop() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    service.set_session(session_params(9_000_000)).unwrap();
    let first = backend.wire();
    first.push_text(welcome());
    first.push_text(snapshot_frame(4, 4, &[message(1, ME, "one")]).to_string());
    first.push_text(send_event(5, 5, &message(2, ME, "two")).to_string());
    first.push_close(Some(1006));
    let second = backend.wire();
    second.push_text(welcome());
    second.push_text(send_event(6, 6, &message(3, ME, "three")).to_string());

    let target = Target::Conversation(CONV.into());
    assert_eq!(
        service.subscribe(1, target.clone()).unwrap(),
        json!({"state": "connecting", "conversation": CONV})
    );
    let seen = events.wait_for(|seen| {
        seen.iter().any(|e| matches!(e, CloudEvent::ConversationChanged { seq: 6, .. }))
    });
    let relayed: Vec<u64> = seen
        .iter()
        .filter_map(|e| match e {
            CloudEvent::ConversationResynced { seq, .. }
            | CloudEvent::ConversationChanged { seq, .. } => Some(*seq),
            _ => None,
        })
        .collect();
    assert_eq!(relayed, [4, 5, 6]);
    assert!(seen.iter().any(|e| is_state(e, "live")));
    assert!(seen.iter().any(|e| is_state(e, "disconnected")));
    assert_eq!(frames(first.sent()), [json!({"t": "subscribe"})]);
    assert_eq!(frames(second.sent()), [json!({"t": "subscribe", "after_seq": 5})]);
    let connected = backend.connected();
    assert_eq!(connected[0].url, format!("wss://api.cmux.test/v1/wire/conv/{CONV}"));
    assert_eq!(connected[0].bearer, "stack.jwt.token");

    // A second client shares the socket; the stream ends after both leave.
    service.subscribe(2, target.clone()).unwrap();
    assert_eq!(backend.connected().len(), 2);
    service.unsubscribe(1, &target);
    assert!(service.has_stream(&target));
    service.client_closed(2);
    wait_until("the stream to retire", || !service.has_stream(&target));
}

#[test]
fn subscription_waits_for_a_new_lease_after_401_and_stops_when_forbidden() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    let target = Target::Conversation(CONV.into());
    assert_eq!(service.subscribe(1, target.clone()).unwrap()["state"], "disconnected");
    events.wait_for(|seen| {
        seen.iter()
            .any(|e| matches!(e, CloudEvent::SubscriptionState { reason: Some("signed_out"), .. }))
    });
    assert!(backend.connected().is_empty());

    backend.refuse(ConnectError::Unauthenticated);
    service.set_session(session_params(9_000_000)).unwrap();
    events.wait_for(|seen| {
        seen.iter()
            .any(|e| matches!(e, CloudEvent::SessionNeeded { reason: "unauthenticated", .. }))
    });
    std::thread::sleep(Duration::from_millis(30));
    assert_eq!(backend.connected().len(), 1, "no retry until a new lease arrives");

    backend.refuse(ConnectError::Forbidden);
    let mut renewed = session_params(9_500_000);
    renewed.access_token = "stack.jwt.renewed".into();
    service.set_session(renewed).unwrap();
    events.wait_for(|seen| {
        seen.iter().any(|e| {
            matches!(
                e,
                CloudEvent::SubscriptionState { state: "closed", reason: Some("forbidden"), .. }
            )
        })
    });
    assert_eq!(backend.connected()[1].bearer, "stack.jwt.renewed");
    wait_until("the forbidden stream to end", || !service.has_stream(&target));
}

#[test]
fn idempotency_keys_match_the_backend_limit_of_128() {
    let title = json!({"kind": "title.set", "title": "t"});
    let at_limit = "k".repeat(128);
    assert!(op_body(&op_request(Some(CONV), &at_limit, title.clone())).is_ok());
    let over = "k".repeat(129);
    let error = op_body(&op_request(Some(CONV), &over, title)).unwrap_err();
    assert!(matches!(error, CloudError::BadRequest(_)), "{error:?}");
    assert!(error.to_string().contains("1-128"), "{error}");
}

#[test]
fn a_4xx_without_an_error_body_is_a_final_reject_except_429() {
    for status in [404_u16, 405, 413] {
        let reply = HttpReply { status, body: Value::Null };
        let error = mutation_data(reply.clone()).unwrap_err();
        assert_eq!(error.error_code(), Some("cloud_conversation_rejected"), "{status}");
        assert_eq!(error.reason(), Some(format!("http_{status}")), "{status}");
        assert_eq!(error.retryable(), Some(false), "{status}");
        assert_eq!(read_value(reply).unwrap_err().reason(), Some(format!("http_{status}")));
    }
    let limited = mutation_data(HttpReply { status: 429, body: json!("slow down") }).unwrap_err();
    assert_eq!(limited.error_code(), Some("cloud_conversation_rejected"));
    assert_eq!(limited.reason().as_deref(), Some("rate_limited"));
    assert_eq!(limited.retryable(), Some(true));
    // A 4xx with the owner's body keeps the owner's code and flag.
    let coded = HttpReply { status: 429, body: json!({"code": "quota.exceeded", "message": "m"}) };
    assert_eq!(mutation_data(coded).unwrap_err().reason().as_deref(), Some("quota.exceeded"));
}

#[test]
fn concurrent_cloud_requests_are_bounded() {
    let backend = Arc::new(FakeBackend::default());
    let (service, _) = service(&backend);
    let first = service.begin_request().unwrap();
    let _second = service.begin_request().unwrap();
    let error = service.begin_request().err().expect("a third request must be refused");
    assert_eq!(error.error_code(), Some("cloud_unavailable"));
    assert_eq!(error.retryable(), Some(true));
    drop(first);
    assert!(service.begin_request().is_ok(), "a released slot is reusable");
}

#[test]
fn a_new_principal_resubscribes_from_a_snapshot_not_the_old_seq() {
    let mut stream = StreamState::new(Target::Conversation(CONV.into()));
    stream.on_text(&welcome_as(ME));
    stream.on_text(&snapshot_frame(8, 8, &[]).to_string());
    stream.on_connect();
    assert_eq!(sent(&stream.on_text(&welcome_as(OTHER))[0]), json!({"t": "subscribe"}));
    assert_eq!(stream.last_seq(), None);

    let mut inbox = StreamState::new(Target::Inbox);
    inbox.on_text(&welcome_as(ME));
    inbox.on_text(&inbox_snapshot(ME, 7));
    inbox.on_connect();
    assert_eq!(
        sent(&inbox.on_text(&welcome_as(OTHER))[0]),
        json!({"t": "subscribe", "stream": format!("inbox:{OTHER}")})
    );
}

#[test]
fn an_account_switch_resets_the_inbox_instead_of_resuming_the_old_users_seq() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    service.set_session(session_params(9_000_000)).unwrap();
    let first = backend.wire();
    first.push_text(welcome_as(ME));
    first.push_text(inbox_snapshot(ME, 7));
    let second = backend.wire();
    second.push_text(welcome_as(OTHER));
    second.push_text(inbox_snapshot(OTHER, 2));

    service.subscribe(1, Target::Inbox).unwrap();
    events.wait_for(|seen| seen.contains(&CloudEvent::InboxReset { seq: 7, account: None }));
    let mut other = session_params(9_000_000);
    other.access_token = "stack.jwt.other-user".into();
    service.set_session(other).unwrap();
    events.wait_for(|seen| seen.contains(&CloudEvent::InboxReset { seq: 2, account: None }));
    assert_eq!(frames(first.sent()), [json!({"t": "subscribe", "stream": format!("inbox:{ME}")})]);
    assert_eq!(
        frames(second.sent()),
        [json!({"t": "subscribe", "stream": format!("inbox:{OTHER}")})],
        "user B's subscribe must not carry user A's after_seq"
    );
    service.shutdown();
}

/// A Stack-shaped access token whose payload names `sub` (unsigned; the
/// daemon only reads the account for tagging, the Worker verifies).
fn jwt(sub: &str) -> String {
    use base64::Engine;
    let encode = |value: Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value.to_string().as_bytes())
    };
    format!(
        "{}.{}.signature",
        encode(json!({"alg": "ES256", "typ": "JWT"})),
        encode(json!({"sub": sub, "exp": 1}))
    )
}

fn lease_for(token: &str) -> SessionParams {
    let mut params = session_params(9_000_000);
    params.access_token = token.into();
    params
}

fn wire_events(seen: &[CloudEvent], name: &str) -> Vec<Value> {
    seen.iter().map(CloudEvent::wire_json).filter(|event| event["event"] == name).collect()
}

#[test]
fn conversation_events_carry_the_account_of_the_lease_that_opened_the_socket() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    service.set_session(lease_for(&jwt("account-a"))).unwrap();
    let first = backend.wire();
    first.push_text(welcome_as(ME));
    first.push_text(snapshot_frame(4, 4, &[message(1, ME, "one")]).to_string());
    first.push_text(send_event(5, 5, &message(2, ME, "two")).to_string());
    let second = backend.wire();
    second.push_text(welcome_as(OTHER));
    second.push_text(snapshot_frame(2, 2, &[]).to_string());

    service.subscribe(1, Target::Conversation(CONV.into())).unwrap();
    let seen = events.wait_for(|seen| {
        seen.iter().any(|e| matches!(e, CloudEvent::ConversationChanged { seq: 5, .. }))
    });
    for name in ["cloud-conversation-resynced", "cloud-conversation-changed"] {
        let tagged = wire_events(&seen, name);
        assert!(!tagged.is_empty(), "{name}");
        assert!(tagged.iter().all(|event| event["account"] == "account-a"), "{name}: {tagged:#?}");
    }
    let live: Vec<Value> = wire_events(&seen, "cloud-subscription-state")
        .into_iter()
        .filter(|event| event["state"] == "live")
        .collect();
    assert_eq!(live.len(), 1, "{live:#?}");
    assert_eq!(live[0]["account"], "account-a");

    // Another account signs in: the socket reconnects and its events name
    // the new lease's account, so a client can drop the old account's events.
    events.take();
    service.set_session(lease_for(&jwt("account-b"))).unwrap();
    let seen = events.wait_for(|seen| {
        seen.iter().any(|e| matches!(e, CloudEvent::ConversationResynced { seq: 2, .. }))
    });
    let resynced = wire_events(&seen, "cloud-conversation-resynced");
    assert_eq!(resynced.len(), 1, "{resynced:#?}");
    assert_eq!(resynced[0]["account"], "account-b");
    service.shutdown();
}

#[test]
fn inbox_events_carry_the_account_and_omit_it_without_a_readable_sub() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    service.set_session(lease_for(&jwt("account-a"))).unwrap();
    let first = backend.wire();
    first.push_text(welcome_as(ME));
    first.push_text(inbox_snapshot(ME, 3));
    let entry = json!({"conversation": CONV, "rev": 2, "kind": "group", "title": "Launch"});
    first.push_text(
        json!({"t": "event", "stream": format!("inbox:{ME}"), "seq": 4, "tx": "t4", "op": "inbox.bump",
               "effects": {"state": {"next_pin": 0}, "writes": [
                   {"table": "entry", "op": "upsert", "key": CONV, "n": null, "row": entry}]}})
        .to_string(),
    );
    let second = backend.wire();
    second.push_text(welcome_as(OTHER));
    second.push_text(inbox_snapshot(OTHER, 2));

    service.subscribe(1, Target::Inbox).unwrap();
    let seen = events
        .wait_for(|seen| seen.iter().any(|e| matches!(e, CloudEvent::InboxChanged { seq: 4, .. })));
    for name in ["cloud-inbox-reset", "cloud-inbox-changed"] {
        let tagged = wire_events(&seen, name);
        assert_eq!(tagged.len(), 1, "{name}: {tagged:#?}");
        assert_eq!(tagged[0]["account"], "account-a", "{name}");
    }

    // A lease whose token has no readable `sub` tags nothing.
    events.take();
    service.set_session(lease_for("opaque.not-base64-json.token")).unwrap();
    let seen = events
        .wait_for(|seen| seen.iter().any(|e| matches!(e, CloudEvent::InboxReset { seq: 2, .. })));
    let reset = wire_events(&seen, "cloud-inbox-reset");
    assert_eq!(reset[0]["seq"], 2);
    assert!(reset[0].get("account").is_none(), "{reset:#?}");
    service.shutdown();
}

#[test]
fn a_later_subscriber_is_told_the_shared_sockets_current_state() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events) = service(&backend);
    service.set_session(session_params(9_000_000)).unwrap();
    let wire = backend.wire();
    wire.push_text(welcome());
    wire.push_text(snapshot_frame(4, 4, &[message(1, ME, "one")]).to_string());
    let target = Target::Conversation(CONV.into());
    assert_eq!(service.subscribe(1, target.clone()).unwrap()["state"], "connecting");
    events.wait_for(|seen| seen.iter().any(|e| is_state(e, "live")));

    // The socket is shared and already live: a second client must not be
    // told `connecting` with no event to follow.
    assert_eq!(
        service.subscribe(2, target).unwrap(),
        json!({"state": "live", "conversation": CONV})
    );
    assert_eq!(backend.connected().len(), 1, "the socket is shared");

    // Every later change of the shared socket reaches subscribers.
    events.take();
    wire.push_close(Some(1006));
    events.wait_for(|seen| seen.iter().any(|e| is_state(e, "disconnected")));
    service.shutdown();
}

// G9: the chief's MuxDO wake queue (plans/cmux-next/cloud-chief-vm.md).

const CHIEF: &str = "agent_chief01";

/// A chief token: `sub` the owner, `agt` the chief.
fn chief_jwt(agent: &str) -> String {
    use base64::Engine;
    let encode = |value: Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value.to_string().as_bytes())
    };
    format!(
        "{}.{}.signature",
        encode(json!({"alg": "ES256", "typ": "JWT"})),
        encode(json!({"sub": ME, "agt": agent, "exp": 1}))
    )
}

/// The queue is the lease's own chief's: its agent comes from the chief
/// token, the socket opens `/v1/wire/mux/<agt>`, a person's token is refused,
/// and an ack names the wake row in its idempotency key.
#[test]
fn the_mux_queue_and_its_acks_belong_to_the_leased_chief_only() {
    let backend = Arc::new(FakeBackend::default());
    let (service, _events) = service(&backend);
    service.set_session(lease_for(&jwt(ME))).unwrap();
    assert_eq!(
        service.mux_target().unwrap_err().reason().as_deref(),
        Some("mux_needs_chief"),
        "a person's session has no wake queue"
    );
    service.set_session(lease_for(&chief_jwt(CHIEF))).unwrap();
    let target = service.mux_target().unwrap();
    assert_eq!(target, Target::Mux(CHIEF.into()));
    let wire = backend.wire();
    wire.push_text(welcome());
    service.subscribe(1, target).unwrap();
    wait_until("the mux socket", || !backend.connected().is_empty());
    assert_eq!(backend.connected()[0].url, format!("wss://api.cmux.test/v1/wire/mux/{CHIEF}"));
    backend.reply("/v1/ops", 200, json!({"ok": true, "op": "mux.ack", "value": {"cursor": 4}, "revision": "1", "transaction": "t", "idempotency_key": "k", "replayed": false, "stream": "mux", "sequence": 1}));
    service.mux_ack(CONV, 4).unwrap();
    let posted = backend.posted();
    let body = posted.last().unwrap().body.clone();
    assert_eq!(body["op"], "mux.ack");
    assert_eq!(body["params"], json!({"agent": CHIEF, "conversation": CONV, "seq": 4}));
    assert_eq!(body["idempotency_key"], format!("mux-ack:{CONV}:4"));
    service.client_closed(1);
    service.shutdown();
}
