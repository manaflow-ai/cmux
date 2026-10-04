//! Behavior of the cloud conversations proxy (home-cloud-proxy.md): request
//! and reply mapping, the upstream stream state machine, and the service
//! with a scripted backend. Frames use the shapes of backend/apps/api and
//! home-core (ConversationDO snapshot and event frames, inbox entries).

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};

use super::contract::{conversation_change, op_body, snapshot_data};
use super::stream::{StreamAction, StreamState};
use super::testing::{Events, FakeBackend, wait_until};
use super::*;

pub(crate) const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const ME: &str = "user_00000000000000000001";
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
    json!({"t": "welcome", "principal": {"user": ME}, "server_time": 1, "streams": [format!("conv:{CONV}")]}).to_string()
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

struct Clock(Arc<AtomicU64>);

fn service(backend: &Arc<FakeBackend>) -> (CloudConversations, Events, Clock) {
    let now = Arc::new(AtomicU64::new(1_000_000));
    let clock = now.clone();
    let options = ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        max_conversation_subscriptions: 2,
        now_ms: Arc::new(move || clock.load(Ordering::SeqCst)),
    };
    let service = CloudConversations::with_options(backend.clone(), options);
    let events = Events::default();
    service.set_sink(events.sink());
    (service, events, Clock(now))
}

#[test]
fn session_lease_validates_the_origin_and_never_shows_the_token() {
    let backend = Arc::new(FakeBackend::default());
    let (service, _, _) = service(&backend);
    for bad in [
        "http://api.cmux.test",
        "https://api.cmux.test/v1",
        "https://u:p@api.cmux.test",
        "https://api.cmux.test/?q=1",
        "ftp://x",
    ] {
        let mut params = session_params(2_000_000);
        params.api_base_url = bad.into();
        let error = service.set_session(params).expect_err(bad);
        assert!(matches!(error, CloudError::BadRequest(_)), "{bad}: {error:?}");
    }
    let mut local = session_params(2_000_000);
    local.api_base_url = "http://127.0.0.1:8787/".into();
    assert_eq!(service.set_session(local).unwrap()["api_base_url"], "http://127.0.0.1:8787");
    let set = service.set_session(session_params(2_000_000)).unwrap();
    assert_eq!(set, json!({"state": "active", "api_base_url": ORIGIN, "expires_at": 2_000_000}));
    let status = service.session_status();
    assert_eq!(status["state"], "active");
    assert!(!status.to_string().contains("stack.jwt.token"));
    assert!(!format!("{:?}", session_params(1)).contains("stack.jwt.token"));
    assert_eq!(service.clear_session(), json!({"state": "signed_out"}));
    assert_eq!(service.session_status(), json!({"state": "signed_out"}));
}

#[test]
fn op_body_forwards_one_vocabulary_with_the_client_key_and_origin() {
    let send = op_request(
        Some(CONV),
        "c1",
        json!({"kind": "message.send", "client_msg_id": "c1", "parts": [{"type": "text", "text": "hi"}]}),
    );
    assert_eq!(
        op_body(&send).unwrap(),
        json!({"op": "message.send", "idempotency_key": "c1", "origin": "cli",
               "params": {"conversation": CONV, "client_msg_id": "c1", "parts": [{"type": "text", "text": "hi"}]}})
    );
    let mut dm = op_request(None, "dm-1", json!({"kind": "dm.open", "peer": {"email": "a@b.co"}}));
    dm.origin = Some("user".into());
    assert_eq!(
        op_body(&dm).unwrap(),
        json!({"op": "dm.open", "idempotency_key": "dm-1", "origin": "user", "params": {"peer": {"email": "a@b.co"}}})
    );
    let unsupported = op_request(Some(CONV), "k", json!({"kind": "conversation.import"}));
    let error = op_body(&unsupported).unwrap_err();
    assert_eq!(error.reason().as_deref(), Some("unsupported_op"));
    assert_eq!(error.error_code(), Some("cloud_conversation_rejected"));
    for (request, why) in [
        (
            op_request(None, "k", json!({"kind": "message.retract", "message_id": "m"})),
            "needs a conversation",
        ),
        (
            op_request(Some(CONV), "k", json!({"kind": "dm.open", "peer": "user_x"})),
            "does not name",
        ),
        (
            op_request(Some("conv_../x"), "k", json!({"kind": "title.set", "title": "t"})),
            "not a conversation id",
        ),
        (op_request(Some(CONV), "", json!({"kind": "title.set", "title": "t"})), "idempotency_key"),
        (
            op_request(Some(CONV), "k", json!({"kind": "title.set", "conversation": CONV})),
            "top level",
        ),
    ] {
        let error = op_body(&request).unwrap_err();
        assert!(matches!(error, CloudError::BadRequest(_)), "{why}: {error:?}");
        assert!(error.to_string().contains(why), "{why}: {error}");
    }
    let mut bad_origin = send;
    bad_origin.origin = Some("robot".into());
    assert!(op_body(&bad_origin).is_err());
}

#[test]
fn snapshot_becomes_a_cloud_summary_without_token_hashes_or_loop_counters() {
    let messages = [message(2, ME, "two"), message(1, ME, "one")];
    let data = snapshot_data(&snapshot_frame(9, 7, &messages)).unwrap();
    assert_eq!(data["rev"], 7);
    assert_eq!(data["seq"], 9);
    assert_eq!(
        data["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["seq"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        [1, 2]
    );
    let summary = &data["conversation"];
    assert_eq!(summary["owner"], "cloud");
    assert_eq!(summary["id"], CONV);
    assert_eq!(summary["kind"], "group");
    assert_eq!(summary["last_message"]["seq"], 2);
    assert!(summary.get("agent_text_streak").is_none());
    assert!(summary["invites"][0].get("token_hash").is_none());
    assert_eq!(summary["invites"][0]["id"], "inv_1");
    let mut empty = snapshot_frame(1, 1, &[]);
    empty["state"] = Value::Null;
    assert_eq!(
        snapshot_data(&empty).unwrap_err().reason().as_deref(),
        Some("unknown_conversation")
    );
}

#[test]
fn events_map_to_the_local_change_shapes() {
    let sent = send_event(5, 6, &message(3, ME, "hi"));
    let (rev, change) = conversation_change(&sent).unwrap();
    assert_eq!(rev, 6);
    assert_eq!(change["kind"], "message");
    assert_eq!(change["message"]["seq"], 3);

    let mut edit = sent.clone();
    edit["op"] = json!("message.edit");
    assert_eq!(conversation_change(&edit).unwrap().1["kind"], "message-updated");

    let mut cursor = sent.clone();
    cursor["op"] = json!("read_cursor.set");
    cursor["params"] = json!({"seq": 1});
    cursor["effects"]["writes"] = json!([]);
    assert_eq!(
        conversation_change(&cursor).unwrap().1,
        json!({"kind": "read-cursor", "participant": ME, "seq": 1})
    );

    let mut title = cursor.clone();
    title["op"] = json!("title.set");
    let (_, change) = conversation_change(&title).unwrap();
    assert_eq!(change["kind"], "conversation");
    assert_eq!(change["conversation"]["owner"], "cloud");

    let mut bare = sent;
    bare.as_object_mut().unwrap().remove("effects");
    assert!(conversation_change(&bare).is_none());
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

#[test]
fn inbox_stream_subscribes_the_welcomed_users_inbox() {
    let mut stream = StreamState::new(Target::Inbox);
    let actions = stream.on_text(&welcome());
    assert_eq!(sent(&actions[0]), json!({"t": "subscribe", "stream": format!("inbox:{ME}")}));
    let reset = stream.on_text(&json!({"t": "snapshot", "stream": format!("inbox:{ME}"), "seq": 3, "state": {"next_pin": 0}, "decided": []}).to_string());
    assert_eq!(reset, vec![StreamAction::Emit(CloudEvent::InboxReset { seq: 3 })]);
    let entry =
        json!({"conversation": CONV, "rev": 2, "kind": "group", "title": "Launch", "unread": 1});
    let bump = json!({"t": "event", "stream": format!("inbox:{ME}"), "seq": 4, "tx": "t4", "op": "inbox.bump",
                      "effects": {"state": {"next_pin": 0}, "writes": [
                          {"table": "entry", "op": "upsert", "key": CONV, "n": null, "row": entry},
                          {"table": "peer", "op": "upsert", "key": "user_x", "n": null, "row": {}}]}});
    assert_eq!(
        stream.on_text(&bump.to_string()),
        vec![StreamAction::Emit(CloudEvent::InboxChanged {
            seq: 4,
            transaction: "t4".into(),
            entries: vec![entry]
        })]
    );
    let mut anonymous = StreamState::new(Target::Inbox);
    assert_eq!(
        anonymous.on_text(r#"{"t":"welcome","principal":{}}"#),
        vec![StreamAction::Forbidden]
    );
}

#[test]
fn commands_without_a_lease_send_nothing_and_ask_for_one() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events, clock) = service(&backend);
    let error = service.inbox_list(None, false).unwrap_err();
    assert_eq!(error, CloudError::SignedOut);
    assert_eq!(error.error_code(), Some("cloud_signed_out"));
    assert!(backend.posted().is_empty());
    assert_eq!(
        events.take(),
        vec![CloudEvent::SessionNeeded { reason: "missing", expires_at: None }]
    );

    service.set_session(session_params(1_100_000)).unwrap();
    clock.0.store(1_100_000, Ordering::SeqCst);
    assert_eq!(service.snapshot(CONV, 10).unwrap_err(), CloudError::SessionExpired);
    assert!(backend.posted().is_empty());
    assert_eq!(
        events.take(),
        vec![CloudEvent::SessionNeeded { reason: "expired", expires_at: Some(1_100_000) }]
    );
}

#[test]
fn op_posts_with_the_lease_and_returns_the_owner_result_or_reject() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events, _) = service(&backend);
    service.set_session(session_params(9_000_000)).unwrap();
    let change = json!({"kind": "message", "message": message(1, ME, "hi")});
    backend.reply("/v1/ops", 200, json!({"ok": true, "op": "message.send",
        "value": {"rev": 2, "seq": 1, "message_id": "msg_1", "change": change}, "revision": "2",
        "transaction": "tx-1", "idempotency_key": "c1", "replayed": false, "stream": format!("conv:{CONV}"), "sequence": 2}));
    let request = op_request(
        Some(CONV),
        "c1",
        json!({"kind": "message.send", "client_msg_id": "c1", "parts": [{"type": "text", "text": "hi"}]}),
    );
    let data = service.op(&request).unwrap();
    assert_eq!(data["rev"], 2);
    assert_eq!(data["seq"], 1);
    assert_eq!(data["change"], change);
    assert_eq!(data["value"]["message_id"], "msg_1");
    assert_eq!(data["transaction"], "tx-1");
    assert_eq!(data["replayed"], false);
    assert_eq!(data["sequence"], 2);
    let posted = backend.posted();
    assert_eq!(posted[0].url, format!("{ORIGIN}/v1/ops"));
    assert_eq!(posted[0].bearer, "stack.jwt.token");
    assert_eq!(posted[0].client_version.as_deref(), Some("0.70.0"));
    assert_eq!(posted[0].body["idempotency_key"], "c1");

    backend.reply("/v1/ops", 200, json!({"ok": false, "op": "participants.add",
        "error": {"code": "not_reachable", "message": "not_reachable", "retryable": false},
        "transaction": "", "idempotency_key": "p1", "replayed": false, "stream": "", "sequence": 0}));
    let add = op_request(
        Some(CONV),
        "p1",
        json!({"kind": "participants.add", "participant": {"id": "user_x", "kind": "human", "display_name": "X"}}),
    );
    let error = service.op(&add).unwrap_err();
    assert_eq!(error.reason().as_deref(), Some("not_reachable"));
    assert_eq!(error.retryable(), Some(false));

    backend.reply(
        "/v1/ops",
        401,
        json!({"code": "auth.unauthenticated", "message": "missing or invalid bearer token"}),
    );
    assert_eq!(service.op(&add).unwrap_err(), CloudError::Unauthenticated);
    assert_eq!(
        events.take(),
        vec![CloudEvent::SessionNeeded { reason: "unauthenticated", expires_at: Some(9_000_000) }]
    );

    backend.reply(
        "/v1/ops",
        403,
        json!({"code": "client.too_old", "message": "this team requires cmux 1.0"}),
    );
    assert_eq!(service.op(&add).unwrap_err().reason().as_deref(), Some("client.too_old"));
    backend.reply("/v1/ops", 503, json!({"code": "owner.unreachable"}));
    assert!(matches!(service.op(&add).unwrap_err(), CloudError::Unavailable(_)));
    backend.fail("/v1/ops", "connection reset");
    let error = service.op(&add).unwrap_err();
    assert_eq!((error.error_code(), error.retryable()), (Some("cloud_unavailable"), Some(true)));
}

#[test]
fn reads_map_inbox_history_and_snapshot() {
    let backend = Arc::new(FakeBackend::default());
    let (service, _, _) = service(&backend);
    service.set_session(session_params(9_000_000)).unwrap();
    backend.reply("/v1/read", 200, json!({"op": "inbox.list", "value": {"entries": [{"conversation": CONV}]}, "stream": format!("inbox:{ME}"), "revision": "12"}));
    assert_eq!(
        service.inbox_list(Some(20), true).unwrap(),
        json!({"entries": [{"conversation": CONV}], "revision": "12"})
    );
    assert_eq!(
        backend.posted()[0].body,
        json!({"op": "inbox.list", "params": {"limit": 20, "include_archived": true}})
    );
    backend.reply("/v1/read", 200, json!({"op": "conversation.history", "value": {"messages": [message(1, ME, "a")], "has_more": true}, "stream": "", "revision": ""}));
    let history = service.history(CONV, 2, 50).unwrap();
    assert_eq!(history["has_more"], true);
    assert_eq!(
        backend.posted()[1].body["params"],
        json!({"conversation": CONV, "before_seq": 2, "limit": 50})
    );
    backend.reply("/v1/read", 200, json!({"op": "conversation.snapshot", "value": snapshot_frame(3, 3, &[message(1, ME, "a")]), "stream": "", "revision": "3"}));
    assert_eq!(service.snapshot(CONV, 50).unwrap()["seq"], 3);
    backend.reply(
        "/v1/read",
        403,
        json!({"code": "auth.forbidden", "message": "not a participant"}),
    );
    assert_eq!(service.snapshot(CONV, 50).unwrap_err().reason().as_deref(), Some("auth.forbidden"));
    assert!(matches!(service.snapshot(CONV, 51).unwrap_err(), CloudError::BadRequest(_)));
    assert!(matches!(service.inbox_list(Some(0), false).unwrap_err(), CloudError::BadRequest(_)));
}

fn is_state(event: &CloudEvent, wanted: &str) -> bool {
    matches!(event, CloudEvent::SubscriptionState { state, .. } if *state == wanted)
}

#[test]
fn conversation_subscription_relays_events_and_resumes_after_a_drop() {
    let backend = Arc::new(FakeBackend::default());
    let (service, events, _) = service(&backend);
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
    let (service, events, _) = service(&backend);
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
fn conversation_subscriptions_are_bounded_and_ids_are_checked() {
    let backend = Arc::new(FakeBackend::default());
    let (service, _, _) = service(&backend);
    service.subscribe(1, Target::Conversation("conv_0000000000000000000000000A".into())).unwrap();
    service
        .subscribe(1, Target::Conversation("conv_dm_0000000000000000000000000B".into()))
        .unwrap();
    let error = service.subscribe(1, Target::Conversation(CONV.into())).unwrap_err();
    assert_eq!(error.reason().as_deref(), Some("too_many_subscriptions"));
    service.subscribe(1, Target::Inbox).unwrap();
    assert!(matches!(
        service.subscribe(1, Target::Conversation("conv_x/../../v1".into())).unwrap_err(),
        CloudError::BadRequest(_)
    ));
    service.shutdown();
}
