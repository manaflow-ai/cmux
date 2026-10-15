//! Wire tests for the cloud conversations proxy (`cloud-conversations-v1`,
//! plans/cmux-next/home-cloud-proxy.md): the commands over the daemon's line
//! protocol with a scripted cloud, the reply fields, and the events.

use std::time::{Duration, Instant};

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::tests::captured_writer;
use super::super::*;
use crate::cloud_conversations::testing::{FakeBackend, wait_until};
use crate::cloud_conversations::{CloudConversations, ServiceOptions};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const ME: &str = "user_00000000000000000001";

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn cloud_mux() -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("cloud-conversations", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        max_concurrent_requests: 1,
        api_origins: vec!["https://api.cmux.test".into()],
        ..ServiceOptions::default()
    };
    assert!(
        mux.install_cloud_conversations(CloudConversations::with_options(backend.clone(), options))
    );
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client, backend)
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

/// Runs `request` through the full request path and returns the reply line,
/// which may arrive from another thread.
fn reply(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let (writer, outbound) = captured_writer();
    let request: Request = serde_json::from_value(request).unwrap();
    assert!(handle_request(mux, client, request, &writer));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(line) = outbound.try_pop() {
            return serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn sign_in(mux: &Arc<Mux>, client: u64) {
    let set = run(
        mux,
        client,
        json!({"cmd":"cloud-session-set","api_base_url":"https://api.cmux.test",
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64,
               "client_version":"0.70.0"}),
    )
    .unwrap();
    assert_eq!(set["state"], "active");
}

fn cloud_events(events: &crate::MuxEventReceiver) -> Vec<Value> {
    events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::CloudConversation(_)))
        .map(|event| subscribed_event_json(&event))
        .collect()
}

#[test]
fn capability_is_advertised_only_with_a_cloud_transport() {
    let (mux, client, _) = cloud_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "cloud-conversations-v1"));
    assert!(capabilities.iter().any(|value| value == "local-conversations-v1"));

    let bare = Mux::new_for_test("no-cloud", crate::SurfaceOptions::default());
    let local = bare.control_clients.register(ClientTransport::Unix, writer());
    let identity = run(&bare, local, json!({"cmd":"identify"})).unwrap();
    assert!(
        !identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "cloud-conversations-v1")
    );
    let error = run(&bare, local, json!({"cmd":"cloud-session-status"})).unwrap_err();
    assert!(error.to_string().contains("not available"), "{error}");
}

#[test]
fn session_lease_round_trips_without_echoing_the_token() {
    let (mux, client, _) = cloud_mux();
    assert_eq!(
        run(&mux, client, json!({"cmd":"cloud-session-status"})).unwrap(),
        json!({"state":"signed_out"})
    );
    sign_in(&mux, client);
    let status = run(&mux, client, json!({"cmd":"cloud-session-status"})).unwrap();
    assert_eq!(status["state"], "active");
    assert_eq!(status["api_base_url"], "https://api.cmux.test");
    assert!(!status.to_string().contains("stack.jwt.token"));
    assert_eq!(
        run(&mux, client, json!({"cmd":"cloud-session-clear"})).unwrap(),
        json!({"state":"signed_out"})
    );
    let bad = run(
        &mux,
        client,
        json!({"cmd":"cloud-session-set","api_base_url":"http://evil.example","access_token":"t","expires_at":1}),
    )
    .unwrap_err();
    assert!(bad.to_string().starts_with("bad request: api_base_url"), "{bad}");
}

#[test]
fn every_command_requires_a_trusted_local_connection() {
    let (mux, _, backend) = cloud_mux();
    let remote = mux.control_clients.register(ClientTransport::WebSocket, writer());
    for request in [
        json!({"cmd":"cloud-session-status"}),
        json!({"cmd":"cloud-session-set","api_base_url":"https://api.cmux.test","access_token":"t","expires_at":1}),
        json!({"cmd":"cloud-inbox-list"}),
        json!({"cmd":"cloud-conversation-subscribe","conversation":CONV}),
        json!({"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"k",
               "op":{"kind":"title.set","title":"t"}}),
    ] {
        let error = run(&mux, remote, request.clone()).unwrap_err();
        assert!(error.to_string().contains("trusted local connection"), "{request}: {error}");
    }
    assert!(backend.posted().is_empty());
}

#[test]
fn op_forwards_the_key_and_returns_the_owner_result() {
    let (mux, client, backend) = cloud_mux();
    // `origin: "user"` is the verified cmux app's (cloud-lease-app-only-v1).
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    sign_in(&mux, client);
    backend.reply("/v1/ops", 200, json!({"ok":true,"op":"dm.open",
        "value":{"conversation":{"id":"conv_dm_0123456789ABCDEFGHJKMNPQRS","owner":"cloud"}},"revision":"1",
        "transaction":"tx-dm","idempotency_key":"dm-1","replayed":false,"stream":"conv:conv_dm_0123456789ABCDEFGHJKMNPQRS","sequence":1}));
    let reply = reply(
        &mux,
        client,
        json!({"id":7,"cmd":"cloud-conversation-op","idempotency_key":"dm-1","origin":"user",
               "op":{"kind":"dm.open","peer":"user_00000000000000000002"}}),
    );
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["value"]["conversation"]["owner"], "cloud");
    assert_eq!(reply["data"]["transaction"], "tx-dm");
    let posted = backend.posted();
    assert_eq!(posted[0].url, "https://api.cmux.test/v1/ops");
    assert_eq!(posted[0].bearer, "stack.jwt.token");
    assert_eq!(
        posted[0].body,
        json!({"op":"dm.open","params":{"peer":"user_00000000000000000002"},"idempotency_key":"dm-1","origin":"user"})
    );
}

#[test]
fn rejects_carry_error_code_reason_and_retryable() {
    let (mux, client, backend) = cloud_mux();
    let signed_out = reply(&mux, client, json!({"id":1,"cmd":"cloud-inbox-list"}));
    assert_eq!(signed_out["ok"], false);
    assert_eq!(signed_out["error_code"], "cloud_signed_out");
    assert_eq!(signed_out["reason"], "missing");
    assert_eq!(signed_out["retryable"], false);

    sign_in(&mux, client);
    backend.reply(
        "/v1/ops",
        200,
        json!({"ok":false,"op":"participants.add",
        "error":{"code":"not_reachable","message":"not_reachable","retryable":false},
        "transaction":"","idempotency_key":"p1","replayed":false,"stream":"","sequence":0}),
    );
    let refused = reply(
        &mux,
        client,
        json!({"id":2,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"p1",
               "op":{"kind":"participants.add","participant":{"id":"user_x","kind":"human","display_name":"X"}}}),
    );
    assert_eq!(refused["error_code"], "cloud_conversation_rejected");
    assert_eq!(refused["reason"], "not_reachable");
    assert_eq!(refused["retryable"], false);

    backend.fail("/v1/ops", "connection reset");
    let lost = reply(
        &mux,
        client,
        json!({"id":3,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"t1",
               "op":{"kind":"title.set","title":"Launch"}}),
    );
    assert_eq!(
        (lost["error_code"].as_str(), lost["retryable"].as_bool()),
        (Some("cloud_unavailable"), Some(true))
    );

    let unsupported = reply(
        &mux,
        client,
        json!({"id":4,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"x",
               "op":{"kind":"conversation.import"}}),
    );
    assert_eq!(unsupported["reason"], "unsupported_op");
    assert_eq!(backend.posted().len(), 2, "an unsupported op never reaches the cloud");
}

#[test]
fn subscription_publishes_cloud_events_to_subscribers() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    wire.push_text(
        json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":2,"decided":[],
               "state":{"id":CONV,"title":"Launch","kind":"group","participants":[],"last_seq":0,"rev":2,
                        "created_at":"2026-10-03T00:00:00.000Z","updated_at":"2026-10-03T00:00:00.000Z",
                        "read_cursors":{}},
               "rows":{"table":"msg","rows":[]}})
        .to_string(),
    );
    let subscribed =
        run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV}))
            .unwrap();
    assert_eq!(subscribed, json!({"state":"connecting","conversation":CONV}));
    let mut seen = Vec::new();
    wait_until("the resync event", || {
        seen.extend(cloud_events(&events));
        seen.iter().any(|event| event["event"] == "cloud-conversation-resynced")
    });
    let resynced =
        seen.iter().find(|event| event["event"] == "cloud-conversation-resynced").unwrap();
    assert_eq!(resynced["conversation"], CONV);
    assert_eq!(resynced["seq"], 2);
    assert_eq!(resynced["summary"]["owner"], "cloud");
    assert!(seen.iter().any(|event| event["event"] == "cloud-subscription-state"
        && event["scope"] == "conversation"
        && event["state"] == "live"));

    run(&mux, client, json!({"cmd":"cloud-conversation-unsubscribe","conversation":CONV})).unwrap();
    let service = mux.cloud_conversations().unwrap();
    let target = crate::cloud_conversations::Target::Conversation(CONV.into());
    wait_until("the stream to close", || !service.has_stream(&target));
}

#[test]
fn a_closed_connection_releases_its_subscriptions() {
    let (mux, client, _) = cloud_mux();
    run(&mux, client, json!({"cmd":"cloud-inbox-subscribe"})).unwrap();
    let service = mux.cloud_conversations().unwrap();
    assert!(service.has_stream(&crate::cloud_conversations::Target::Inbox));
    disconnect_client(&mux, client, false);
    wait_until("the inbox stream to close", || {
        !service.has_stream(&crate::cloud_conversations::Target::Inbox)
    });
}

#[test]
fn a_connection_bound_to_an_agent_cannot_use_the_humans_cloud_session() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let minted =
        run(&mux, client, json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap();
    let agent = mux.control_clients.register(ClientTransport::Unix, writer());
    run(
        &mux,
        agent,
        json!({"cmd":"conversation-bind","participant":"agent_mux","token":minted["token"]}),
    )
    .unwrap();
    for request in [
        json!({"cmd":"cloud-session-status"}),
        json!({"cmd":"cloud-session-set","api_base_url":"https://evil.example","access_token":"t",
               "expires_at":4_102_444_800_000_u64}),
        json!({"cmd":"cloud-inbox-list"}),
        json!({"cmd":"cloud-inbox-subscribe"}),
        json!({"cmd":"cloud-conversation-subscribe","conversation":CONV}),
        json!({"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"k",
               "origin":"user","op":{"kind":"title.set","title":"t"}}),
        json!({"cmd":"cloud-session-clear"}),
    ] {
        let error = run(&mux, agent, request.clone()).unwrap_err();
        assert!(error.to_string().contains("bound to a conversation agent"), "{request}: {error}");
    }
    let refused = reply(
        &mux,
        agent,
        json!({"id":9,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"k2",
               "op":{"kind":"title.set","title":"t"}}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(backend.posted().is_empty(), "a bound agent never reaches the cloud");
    let service = mux.cloud_conversations().unwrap();
    assert!(!service.has_stream(&crate::cloud_conversations::Target::Inbox));
    let status = run(&mux, client, json!({"cmd":"cloud-session-status"})).unwrap();
    assert_eq!(status["api_base_url"], "https://api.cmux.test", "the human's lease is untouched");
}

#[test]
fn a_request_over_the_concurrency_limit_is_refused_at_once() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let held = mux.cloud_conversations().unwrap().begin_request().unwrap();
    let refused = reply(
        &mux,
        client,
        json!({"id":5,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"t1",
               "op":{"kind":"title.set","title":"Launch"}}),
    );
    assert_eq!(refused["error_code"], "cloud_unavailable", "{refused}");
    assert_eq!(refused["retryable"], true);
    assert!(backend.posted().is_empty(), "nothing leaves over the limit");
    drop(held);
}

#[test]
fn a_later_subscriber_gets_the_current_state_and_a_state_event_after_its_reply() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    let mut seen = Vec::new();
    wait_until("the socket to go live", || {
        seen.extend(cloud_events(&events));
        seen.iter()
            .any(|event| event["event"] == "cloud-subscription-state" && event["state"] == "live")
    });

    let second = mux.control_clients.register(ClientTransport::Unix, writer());
    let _ = cloud_events(&events);
    let subscribed = reply(
        &mux,
        second,
        json!({"id":7,"cmd":"cloud-conversation-subscribe","conversation":CONV}),
    );
    assert_eq!(subscribed["ok"], true, "{subscribed}");
    assert_eq!(subscribed["data"]["state"], "live", "{subscribed}");
    // The current state also follows the reply as an event, so a client
    // whose reply raced a change still ends on the true state.
    let mut after = Vec::new();
    wait_until("the state event after the reply", || {
        after.extend(cloud_events(&events));
        after.iter().any(|event| {
            event["event"] == "cloud-subscription-state"
                && event["conversation"] == CONV
                && event["state"] == "live"
        })
    });
    mux.cloud_conversations().unwrap().shutdown();
}

/// G9: a client cannot name a chief. `cloud-mux-ack` takes ids only (an
/// `agent` field is refused at parse), and `cloud-mux-subscribe` with a
/// person's lease is refused: the queue is the chief token's own.
#[test]
fn the_mux_commands_never_take_a_chief_from_the_request() {
    let (mux, client, _backend) = cloud_mux();
    let named = serde_json::from_value::<Command>(json!({
        "cmd": "cloud-mux-ack", "conversation": CONV, "seq": 3, "agent": "agent_other"
    }));
    assert!(named.is_err(), "an agent field must not parse");
    let subscribe_named = serde_json::from_value::<Command>(json!({
        "cmd": "cloud-mux-subscribe", "agent": "agent_other"
    }));
    assert!(subscribe_named.is_err(), "subscribe takes no agent");
    run(&mux, client, json!({"cmd": "cloud-session-set", "api_base_url": "https://api.cmux.test",
                             "access_token": "stack.jwt.token", "expires_at": 9_999_999_999_999u64}))
        .unwrap();
    let refused = run(&mux, client, json!({"cmd": "cloud-mux-subscribe"})).unwrap_err();
    assert!(refused.to_string().contains("chief token"), "{refused}");
}

/// `cloud-conversation-thread` (cx-59n8.6) is `POST /v1/read
/// conversation.thread` with the value passed through, and
/// `cloud-conversation-history` keeps the owner's `threads` root stats.
#[test]
fn thread_read_and_root_stats_pass_through_the_proxy() {
    let (mux, client, backend) = cloud_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "conversation-thread-v1")
    );
    sign_in(&mux, client);
    let root = json!({"id":"msg_01","seq":1,"author":ME,"parts":[]});
    let reply_message =
        json!({"id":"msg_02","seq":2,"author":ME,"parts":[],"thread_root":"msg_01"});
    let summary = json!({"root":"msg_01","reply_count":1,"last_reply_seq":2,
                         "last_reply_at":"2026-10-11T00:00:00.000Z","authors":[ME]});
    let value = json!({"root":root,"replies":[reply_message],"has_more":false,"thread":summary});
    backend.reply(
        "/v1/read",
        200,
        json!({"ok":true,"op":"conversation.thread","value":value,"revision":""}),
    );
    let thread = reply(
        &mux,
        client,
        json!({"id":3,"cmd":"cloud-conversation-thread","conversation":CONV,"root":"msg_01",
               "after_seq":0,"limit":20}),
    );
    assert_eq!(thread["ok"], true, "{thread}");
    assert_eq!(thread["data"], value);
    assert_eq!(
        backend.posted()[0].body,
        json!({"op":"conversation.thread",
               "params":{"conversation":CONV,"root":"msg_01","after_seq":0,"limit":20}})
    );

    backend.reply(
        "/v1/read",
        200,
        json!({"ok":true,"op":"conversation.history",
        "value":{"messages":[root],"has_more":false,"threads":[summary]},"revision":""}),
    );
    let history = reply(
        &mux,
        client,
        json!({"id":4,"cmd":"cloud-conversation-history","conversation":CONV,"before_seq":2,"limit":1}),
    );
    assert_eq!(history["ok"], true, "{history}");
    assert_eq!(history["data"]["threads"], json!([summary]), "{history}");

    // The Worker's 400 body (`{_tag, code, message}` at top level) is a
    // clear owner refusal, never a transport error.
    backend.reply(
        "/v1/read",
        400,
        json!({"_tag":"HomeReadError","code":"unknown_message",
        "message":"not a thread root"}),
    );
    let refused = reply(
        &mux,
        client,
        json!({"id":5,"cmd":"cloud-conversation-thread","conversation":CONV,"root":"msg_02"}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "cloud_conversation_rejected", "{refused}");
    assert_eq!(refused["reason"], "unknown_message", "{refused}");
    assert_eq!(refused["retryable"], false, "{refused}");

    let bad = run(
        &mux,
        client,
        json!({"cmd":"cloud-conversation-thread","conversation":CONV,"root":"msg_01","limit":201}),
    )
    .unwrap_err();
    assert!(bad.to_string().contains("limit must be 1-200"), "{bad}");
}

/// A Cloud Chief's live frames (`chief-live-v1`): the owner's `step.delta`,
/// `run.activity` and `run.live` frames of a subscribed conversation reach
/// the daemon's clients under `type`, unchanged; a frame of another
/// conversation does not; and a subscriber asks the owner for the
/// `run.live` snapshot on the shared socket, which a stranger cannot.
#[test]
fn a_cloud_chiefs_live_frames_pass_through_and_a_subscriber_asks_for_the_snapshot() {
    let (mux, client, backend) = cloud_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "cloud-chief-live-v1"),
        "{identity}"
    );
    sign_in(&mux, client);
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    wire.push_text(
        json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":2,"decided":[],
               "state":{"id":CONV,"title":"Launch","kind":"group","participants":[],"last_seq":0,"rev":2,
                        "created_at":"2026-10-03T00:00:00.000Z","updated_at":"2026-10-03T00:00:00.000Z",
                        "read_cursors":{}},
               "rows":{"table":"msg","rows":[]}})
        .to_string(),
    );
    // The owner names live frames with `type` (the brain contract) or `t`.
    let delta = json!({"type":"step.delta","conversation":CONV,"run":"run_7","step":"talk:0",
                       "kind":"talk","seq":0,"text":"Checking the release"});
    wire.push_text(delta.to_string());
    wire.push_text(
        json!({"t":"run.activity","conversation":CONV,"run":"run_7",
               "line":"Editing src/app.ts in sb-3","since":1_791_968_740_000u64,"at":1_791_968_741_000u64})
            .to_string(),
    );
    wire.push_text(
        json!({"type":"step.delta","conversation":"conv_ZZZZZZZZZZZZZZZZZZZZZZZZZZ","run":"run_1",
               "step":"talk:0","kind":"talk","seq":0,"text":"not here"})
        .to_string(),
    );
    let snapshot = json!({"type":"run.live","conversation":CONV,"runs":[{"run":"run_7",
        "steps":[{"step":"talk:0","kind":"talk","seq":0,"text":"Checking the release"}],
        "activity":{"line":"Editing src/app.ts in sb-3","since":1_791_968_740_000u64,"at":1_791_968_741_000u64}}]});
    wire.push_text(snapshot.to_string());

    // A stranger to the conversation cannot ask for its snapshot.
    let early = run(&mux, client, json!({"cmd":"cloud-conversation-live","conversation":CONV}))
        .unwrap_err();
    assert!(early.to_string().contains("subscribe"), "{early}");

    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    let mut seen = Vec::new();
    wait_until("the live frames", || {
        seen.extend(cloud_events(&events));
        seen.iter().filter(|event| event["event"] == "cloud-conversation-live").count() >= 3
    });
    let live: Vec<&Value> =
        seen.iter().filter(|event| event["event"] == "cloud-conversation-live").collect();
    assert_eq!(live.len(), 3, "{seen:?}");
    assert!(live.iter().all(|event| event["conversation"] == CONV), "{live:?}");
    let mut expected = delta;
    expected["t"] = json!("step.delta");
    assert_eq!(live[0]["frame"], expected);
    assert_eq!(live[1]["frame"]["type"], "run.activity", "{:?}", live[1]);
    assert_eq!(live[1]["frame"]["t"], "run.activity", "{:?}", live[1]);
    assert_eq!(live[1]["frame"]["line"], "Editing src/app.ts in sb-3");
    let mut expected = snapshot;
    expected["t"] = json!("run.live");
    assert_eq!(live[2]["frame"], expected);

    // The subscriber asks again (a page that joined late, or saw a gap).
    let asked =
        run(&mux, client, json!({"cmd":"cloud-conversation-live","conversation":CONV})).unwrap();
    assert_eq!(asked["conversation"], CONV, "{asked}");
    wait_until("the run.live.get frame", || {
        wire.sent().iter().any(|frame| {
            let frame: Value = serde_json::from_str(frame).unwrap_or_default();
            frame["t"] == "run.live.get" && frame["conversation"] == CONV
        })
    });
    let sent = wire.sent();
    let subscribe = sent.iter().position(|frame| frame.contains("\"subscribe\"")).unwrap();
    let get = sent.iter().position(|frame| frame.contains("run.live.get")).unwrap();
    assert!(subscribe < get, "{sent:?}");
}
