//! Wire tests for the cloud conversations proxy (`cloud-conversations-v1`,
//! plans/cmux-next/home-cloud-proxy.md): the commands over the daemon's line
//! protocol with a scripted cloud, the reply fields, and the events.

use std::time::{Duration, Instant};

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::tests::captured_writer;
use super::super::*;
use crate::cloud_conversations::testing::{FakeBackend, wait_until};
use crate::cloud_conversations::{CloudConversations, CloudError, ServiceOptions};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const ME: &str = "user_00000000000000000001";

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn cloud_mux() -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    cloud_mux_with(|options| options)
}

fn cloud_mux_with(
    adjust: impl FnOnce(ServiceOptions) -> ServiceOptions,
) -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("cloud-conversations", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = adjust(ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        max_concurrent_requests: 1,
        api_origins: vec!["https://api.cmux.test".into()],
        ..ServiceOptions::default()
    });
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

/// `cloud-conversation-typing`: the owner's `typing {on, conversation}` frame
/// goes out on the conversation's shared socket once it is live, from any
/// client of the daemon while the conversation has a subscriber (a Chief
/// brain subscribes on one connection and writes on another); without a
/// subscriber it is refused and nothing is sent.
#[test]
fn typing_goes_out_as_the_owners_typing_frame_on_the_shared_socket() {
    let (mux, client, backend) = cloud_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "cloud-conversation-typing-v1"),
        "{identity}"
    );
    sign_in(&mux, client);
    let refused = reply(
        &mux,
        client,
        json!({"id":1,"cmd":"cloud-conversation-typing","conversation":CONV,"on":true}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["reason"], "not_subscribed", "{refused}");

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
    let typing_frames = |wire: &crate::cloud_conversations::testing::ScriptedWire| -> Vec<Value> {
        wire.sent()
            .iter()
            .filter_map(|frame| serde_json::from_str::<Value>(frame).ok())
            .filter(|frame| frame["t"] == "typing")
            .collect()
    };
    let frame = |on: bool| json!({"t":"typing","on":on,"conversation":CONV});
    let writer_client = mux.control_clients.register(ClientTransport::Unix, writer());
    for (n, on) in [true, false, true].into_iter().enumerate() {
        let sent = run(
            &mux,
            writer_client,
            json!({"cmd":"cloud-conversation-typing","conversation":CONV,"on":on}),
        )
        .unwrap();
        assert_eq!(sent["conversation"], CONV, "{sent}");
        wait_until("the typing frame", || typing_frames(&wire).len() > n);
    }
    assert_eq!(typing_frames(&wire), vec![frame(true), frame(false), frame(true)]);

    // The socket drops while on: the owner turned it off at the close, so the
    // next socket sends it again once live.
    let second = backend.wire();
    wire.push_close(None);
    second.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    wait_until("the typing frame on the new socket", || !typing_frames(&second).is_empty());
    assert_eq!(typing_frames(&second), vec![frame(true)]);
    // The sender's connection closes while on; the subscriber keeps the
    // socket, so the daemon turns it off.
    disconnect_client(&mux, writer_client, false);
    wait_until("the typing off", || typing_frames(&second).len() > 1);
    assert_eq!(typing_frames(&second), vec![frame(true), frame(false)]);
    mux.cloud_conversations().unwrap().shutdown();
}

/// The owner's `conversation-typing` broadcast of a subscribed conversation
/// (a Cloud Chief, or another person, types) reaches the daemon socket's
/// subscribers that echoed `cloud-conversation-typing-v1` as
/// `cloud-conversation-typing {conversation, participant, on}`, on and off,
/// so the app's Home page shows the Chief typing. Another conversation's
/// frame and a frame without a participant or a boolean `on` do not pass; a
/// connection that did not echo the capability hears none.
#[cfg(unix)]
#[test]
fn the_owners_typing_reaches_the_socket_subscribers_that_asked_for_it() {
    use super::super::client_hello::tests::Client;
    const CHIEF: &str = "agent_01M4X1B5362SM3QJVJ155DA0GB";
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let mut page = Client::connect(&mux, "cloud-typing-page");
    let echoed = page.request(json!({"cmd":"set-client-info","name":"cmux page: home-channels",
        "capabilities":["cloud-conversation-typing-v1"]}));
    assert_eq!(echoed["ok"], true, "{echoed}");
    assert_eq!(page.request(json!({"cmd":"subscribe"}))["ok"], true);
    let mut old = Client::connect(&mux, "cloud-typing-old");
    assert_eq!(old.request(json!({"cmd":"subscribe"}))["ok"], true);

    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    let live =
        |event: &Value| event["event"] == "cloud-subscription-state" && event["state"] == "live";
    assert!(page.event_within(Duration::from_secs(10), live).is_some(), "the socket went live");
    // The old connection hears the stream (its silence below is the capability).
    assert!(old.event_within(Duration::from_secs(10), live).is_some(), "the old one hears it");

    let typing = |conversation: &str, on: Value| {
        json!({"t":"conversation-typing","conversation":conversation,"participant":CHIEF,"on":on})
            .to_string()
    };
    wire.push_text(typing("conv_ZZZZZZZZZZZZZZZZZZZZZZZZZZ", json!(true)));
    wire.push_text(json!({"t":"conversation-typing","conversation":CONV,"on":true}).to_string());
    wire.push_text(typing(CONV, json!("yes")));
    wire.push_text(typing(CONV, json!(true)));
    wire.push_text(typing(CONV, json!(false)));
    let is_typing = |event: &Value| event["event"] == "cloud-conversation-typing";
    let mut seen = Vec::new();
    while let Some(event) = page.event_within(Duration::from_secs(10), is_typing) {
        seen.push(event);
        if seen.len() == 2 {
            break;
        }
    }
    let expected = |on: bool| json!({"event":"cloud-conversation-typing","conversation":CONV,"participant":CHIEF,"on":on});
    assert_eq!(seen, vec![expected(true), expected(false)]);
    // Nothing else came: the dropped frames were before the two that passed.
    assert!(page.event_within(Duration::from_millis(300), is_typing).is_none());

    // The Chief types again and the socket drops: its `off` could only come
    // on that socket, so the daemon turns it off for the page.
    wire.push_text(typing(CONV, json!(true)));
    let on = page.event_within(Duration::from_secs(10), is_typing);
    assert_eq!(on, Some(expected(true)));
    let _next = backend.wire();
    wire.push_close(None);
    let off = page.event_within(Duration::from_secs(10), is_typing);
    assert_eq!(off, Some(expected(false)));
    assert!(old.event_within(Duration::from_millis(300), is_typing).is_none());
    mux.cloud_conversations().unwrap().shutdown();
}

/// `cloud-conversation-presence`: the person views the conversation while
/// any client of the daemon does, so only a change of that goes out as the
/// owner's `presence.set {conversation, viewing}` frame on the shared
/// socket: again on a new socket while viewing, and off when the last
/// viewing client closes or unsubscribes. Without a subscriber it is
/// refused and nothing is sent.
#[test]
fn presence_goes_out_as_the_owners_presence_set_frame_on_the_shared_socket() {
    let (mux, client, backend) = cloud_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    let advertised = identity["capabilities"].as_array().unwrap();
    assert!(advertised.iter().any(|v| v == "cloud-conversation-presence-v1"), "{identity}");
    sign_in(&mux, client);
    let presence = json!({"id":1,"cmd":"cloud-conversation-presence","conversation":CONV,
                          "viewing":true});
    let refused = reply(&mux, client, presence);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["reason"], "not_subscribed", "{refused}");

    let welcome = || {
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string()
    };
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(welcome());
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    // Another subscriber keeps the socket when `client` unsubscribes.
    let other = mux.control_clients.register(ClientTransport::Unix, writer());
    run(&mux, other, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    let mut seen = Vec::new();
    wait_until("the socket to go live", || {
        seen.extend(cloud_events(&events));
        seen.iter()
            .any(|event| event["event"] == "cloud-subscription-state" && event["state"] == "live")
    });
    let frames = |wire: &crate::cloud_conversations::testing::ScriptedWire| -> Vec<Value> {
        wire.sent()
            .iter()
            .filter_map(|frame| serde_json::from_str::<Value>(frame).ok())
            .filter(|frame| frame["t"] == "presence.set")
            .collect()
    };
    let frame = |viewing: bool| json!({"t":"presence.set","conversation":CONV,"viewing":viewing});
    let view = |client: u64, viewing: bool| {
        let sent = run(
            &mux,
            client,
            json!({"cmd":"cloud-conversation-presence","conversation":CONV,"viewing":viewing}),
        )
        .unwrap();
        assert_eq!(sent["conversation"], CONV, "{sent}");
    };
    let first = mux.control_clients.register(ClientTransport::Unix, writer());
    let second = mux.control_clients.register(ClientTransport::Unix, writer());
    view(first, true);
    wait_until("the viewing frame", || !frames(&wire).is_empty());
    // A second viewer, and the first one leaving, change nothing upstream.
    view(second, true);
    view(first, false);
    // The last viewer's connection closes: the person stops viewing.
    disconnect_client(&mux, second, false);
    wait_until("the viewing off", || frames(&wire).len() > 1);
    view(first, true);
    wait_until("the viewing again", || frames(&wire).len() > 2);
    assert_eq!(frames(&wire), vec![frame(true), frame(false), frame(true)]);

    // The socket drops while viewing: the next socket sends it again once live.
    let next = backend.wire();
    wire.push_close(None);
    next.push_text(welcome());
    wait_until("the viewing frame on the new socket", || !frames(&next).is_empty());
    // A subscriber views too; the first viewer closes; then the subscriber
    // unsubscribes (`other` keeps the socket) and the person stops viewing.
    view(client, true);
    disconnect_client(&mux, first, false);
    run(&mux, client, json!({"cmd":"cloud-conversation-unsubscribe","conversation":CONV})).unwrap();
    wait_until("the viewing off on the new socket", || frames(&next).len() > 1);
    assert_eq!(frames(&next), vec![frame(true), frame(false)]);
    mux.cloud_conversations().unwrap().shutdown();
}

/// The owner's `conversation-presence` set of a subscribed conversation
/// reaches the daemon socket's subscribers that echoed
/// `cloud-conversation-presence-v1` as `cloud-conversation-presence
/// {conversation, participants:[{participant, viewing}]}`. Another
/// conversation's set and a malformed one do not pass; when the socket ends
/// the daemon sends an empty set (the owner sends it again only to the next
/// socket). A subscribe replays the live socket's last set after its reply.
/// A connection that did not echo the capability hears none.
#[cfg(unix)]
#[test]
fn the_owners_presence_reaches_the_socket_subscribers_that_asked_for_it() {
    use super::super::client_hello::tests::Client;
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let mut page = Client::connect(&mux, "cloud-presence-page");
    let echoed = page.request(json!({"cmd":"set-client-info","name":"cmux page: home-channels",
        "capabilities":["cloud-conversation-presence-v1"]}));
    assert_eq!(echoed["ok"], true, "{echoed}");
    assert_eq!(page.request(json!({"cmd":"subscribe"}))["ok"], true);
    let mut old = Client::connect(&mux, "cloud-presence-old");
    assert_eq!(old.request(json!({"cmd":"subscribe"}))["ok"], true);

    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    let live =
        |event: &Value| event["event"] == "cloud-subscription-state" && event["state"] == "live";
    assert!(page.event_within(Duration::from_secs(10), live).is_some(), "the socket went live");
    assert!(old.event_within(Duration::from_secs(10), live).is_some(), "the old one hears it");

    let viewers = json!([{"participant":ME,"viewing":true}]);
    let set = |conversation: &str, participants: Value| {
        json!({"t":"conversation-presence","conversation":conversation,
               "participants":participants})
        .to_string()
    };
    wire.push_text(set("conv_ZZZZZZZZZZZZZZZZZZZZZZZZZZ", viewers.clone()));
    wire.push_text(set(CONV, json!([{"participant":ME}])));
    wire.push_text(set(CONV, viewers.clone()));
    let is_presence = |event: &Value| event["event"] == "cloud-conversation-presence";
    let expected = |participants: Value| {
        json!({"event":"cloud-conversation-presence","conversation":CONV,
               "participants":participants})
    };
    let shown = page.event_within(Duration::from_secs(10), is_presence);
    assert_eq!(shown, Some(expected(viewers.clone())));
    // The dropped frames were before the one that passed.
    assert!(page.event_within(Duration::from_millis(300), is_presence).is_none());

    // A subscribe (a page that lost events subscribes again) replays the
    // current set after its reply, without waiting for a change.
    let again = mux.control_clients.register(ClientTransport::Unix, writer());
    let subscribed = reply(
        &mux,
        again,
        json!({"id":7,"cmd":"cloud-conversation-subscribe","conversation":CONV}),
    );
    assert_eq!(subscribed["ok"], true, "{subscribed}");
    let replayed = page.event_within(Duration::from_secs(10), is_presence);
    assert_eq!(replayed, Some(expected(viewers)));

    // The socket drops: the set it showed empties for the page.
    let _next = backend.wire();
    wire.push_close(None);
    let emptied = page.event_within(Duration::from_secs(10), is_presence);
    assert_eq!(emptied, Some(expected(json!([]))));
    assert!(old.event_within(Duration::from_millis(300), is_presence).is_none());
    mux.cloud_conversations().unwrap().shutdown();
}

/// One `message.send` event of the conversation stream at `seq`.
fn message_event(seq: u64) -> String {
    json!({"t":"event","stream":format!("conv:{CONV}"),"seq":seq,"tx":format!("tx-{seq}"),
           "op":"message.send","params":{},"actor":{"user":ME},"origin":"user","at":seq,
           "effects":{"state":{"id":CONV,"title":"Launch","kind":"group","participants":[],
                               "last_seq":seq,"rev":seq,"read_cursors":{},
                               "created_at":"2026-10-03T00:00:00.000Z",
                               "updated_at":"2026-10-03T00:00:00.000Z"},
                      "writes":[{"table":"msg","op":"upsert","key":format!("m{seq}"),"n":seq,
                                 "row":{"id":format!("m{seq}"),"seq":seq,"text":format!("hi {seq}")}}]}})
    .to_string()
}

fn conversation_snapshot(seq: u64) -> String {
    json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":seq,"decided":[],
           "state":{"id":CONV,"title":"Launch","kind":"group","participants":[],"last_seq":seq,
                    "rev":seq,"created_at":"2026-10-03T00:00:00.000Z",
                    "updated_at":"2026-10-03T00:00:00.000Z","read_cursors":{}},
           "rows":{"table":"msg","rows":[]}})
    .to_string()
}

/// The stream seqs of the conversation events seen, in order, with their kind.
fn stream_seqs(seen: &[Value]) -> Vec<(String, u64)> {
    seen.iter()
        .filter(|event| {
            matches!(
                event["event"].as_str(),
                Some("cloud-conversation-changed" | "cloud-conversation-resynced")
            )
        })
        .map(|event| (event["event"].as_str().unwrap().to_string(), event["seq"].as_u64().unwrap()))
        .collect()
}

#[test]
fn a_gap_resyncs_replays_the_buffered_events_and_a_reconnect_resumes_after_them() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let events = mux.subscribe();
    let first = backend.wire();
    first.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    first.push_text(conversation_snapshot(2));
    first.push_text(message_event(3));
    // 4 is lost upstream: 5 and 6 arrive after a gap.
    first.push_text(message_event(5));
    first.push_text(message_event(6));
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    wait_until("the snapshot request", || {
        first.sent().iter().any(|frame| frame.contains("snapshot.request"))
    });
    // The owner answers the gap with its snapshot at 4; the buffered 5 and 6
    // then reach clients in order instead of being dropped.
    first.push_text(conversation_snapshot(4));
    let mut seen = Vec::new();
    wait_until("the buffered events", || {
        seen.extend(cloud_events(&events));
        stream_seqs(&seen).iter().any(|(_, seq)| *seq == 6)
    });
    let changed = |seq| ("cloud-conversation-changed".to_string(), seq);
    let resynced = |seq| ("cloud-conversation-resynced".to_string(), seq);
    assert_eq!(
        stream_seqs(&seen),
        vec![resynced(2), changed(3), resynced(4), changed(5), changed(6)],
        "{seen:#?}"
    );
    let requests: Vec<String> =
        first.sent().into_iter().filter(|frame| frame.contains("snapshot.request")).collect();
    assert_eq!(requests.len(), 1, "one request per gap: {:?}", first.sent());

    // The socket drops; the next connection resumes after the last event.
    let second = backend.wire();
    first.push_close(None);
    second.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    second.push_text(message_event(6));
    second.push_text(message_event(7));
    wait_until("the event after the resume", || {
        seen.extend(cloud_events(&events));
        stream_seqs(&seen).iter().any(|(_, seq)| *seq == 7)
    });
    let subscribe: Value = second
        .sent()
        .iter()
        .map(|frame| serde_json::from_str::<Value>(frame).unwrap())
        .find(|frame| frame["t"] == "subscribe")
        .expect("a subscribe on the second connection");
    assert_eq!(subscribe["after_seq"], 6, "{subscribe}");
    // The replayed 6 is a duplicate: 7 follows 6 exactly once.
    assert_eq!(stream_seqs(&seen)[5..], [changed(7)], "{seen:#?}");

    // The owner lost its tail (a recreated owner): it answers the resume
    // with a snapshot behind the position, which replaces it.
    let third = backend.wire();
    second.push_close(None);
    third.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    third.push_text(conversation_snapshot(1));
    third.push_text(message_event(2));
    wait_until("the events of the recreated owner", || {
        seen.extend(cloud_events(&events));
        stream_seqs(&seen).len() >= 8
    });
    assert_eq!(stream_seqs(&seen)[6..], [resynced(1), changed(2)], "{seen:#?}");
}

/// A snapshot frame of the conversation stream whose `seq` does not decode.
fn undecodable_snapshot() -> String {
    json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":"not-a-seq","decided":[],
           "state":{}})
    .to_string()
}

#[test]
fn a_snapshot_that_does_not_decode_is_asked_for_again_and_the_stream_recovers() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    // The owner's answer to the subscribe does not decode, and events follow it.
    wire.push_text(undecodable_snapshot());
    wire.push_text(message_event(3));
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    wait_until("a new snapshot request", || {
        wire.sent().iter().any(|frame| frame.contains("snapshot.request"))
    });
    // The owner answers with a snapshot that decodes; the stream is live again
    // and the event that waited for it reaches clients after it.
    wire.push_text(conversation_snapshot(2));
    wire.push_text(message_event(4));
    let mut seen = Vec::new();
    wait_until("the events after the snapshot", || {
        seen.extend(cloud_events(&events));
        stream_seqs(&seen).iter().any(|(_, seq)| *seq == 4)
    });
    let changed = |seq| ("cloud-conversation-changed".to_string(), seq);
    let resynced = |seq| ("cloud-conversation-resynced".to_string(), seq);
    assert_eq!(stream_seqs(&seen), vec![resynced(2), changed(3), changed(4)], "{seen:#?}");
}

#[test]
fn a_snapshot_that_never_decodes_is_asked_for_a_bounded_number_of_times_then_the_stream_reconnects()
{
    let (mux, client, backend) = cloud_mux_with(|options| ServiceOptions {
        snapshot_backoff: crate::cloud_conversations::SnapshotBackoff {
            first_ms: 5,
            max_ms: 20,
            attempts: 2,
        },
        ..options
    });
    sign_in(&mux, client);
    let events = mux.subscribe();
    let welcome = json!({"t":"welcome","principal":{"user":ME},"streams":[format!("conv:{CONV}")]})
        .to_string();
    let requests = |wire: &crate::cloud_conversations::testing::ScriptedWire| {
        wire.sent().iter().filter(|frame| frame.contains("snapshot.request")).count()
    };
    let first = backend.wire();
    first.push_text(welcome.clone());
    first.push_text(undecodable_snapshot());
    run(&mux, client, json!({"cmd":"cloud-conversation-subscribe","conversation":CONV})).unwrap();
    // Each answer fails too, one request per attempt after its backoff: a
    // snapshot that decodes but has no conversation head counts like one
    // that does not decode.
    let headless = json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":3,"decided":[],
                          "state":null})
    .to_string();
    for (attempt, answer) in [(1, headless), (2, undecodable_snapshot())] {
        wait_until("the next snapshot request", || requests(&first) == attempt);
        first.push_text(answer);
    }
    // The last attempt failed: the socket is given up and a new one resumes.
    let second = backend.wire();
    second.push_text(welcome);
    second.push_text(conversation_snapshot(2));
    let mut seen = Vec::new();
    wait_until("the snapshot on the new connection", || {
        seen.extend(cloud_events(&events));
        !stream_seqs(&seen).is_empty()
    });
    assert_eq!(requests(&first), 2, "bounded: {:?}", first.sent());
    let subscribe: Value = second
        .sent()
        .iter()
        .map(|frame| serde_json::from_str::<Value>(frame).unwrap())
        .find(|frame| frame["t"] == "subscribe")
        .expect("a subscribe on the new connection");
    // The headless snapshot's position was never shown to clients: the new
    // connection subscribes fresh instead of resuming after it.
    assert!(subscribe.get("after_seq").is_none(), "{subscribe}");
    assert_eq!(
        stream_seqs(&seen),
        vec![("cloud-conversation-resynced".to_string(), 2)],
        "{seen:#?}"
    );
}

fn inbox_page(conversations: &[&str], next_cursor: Value, revision: &str) -> Value {
    let entries: Vec<Value> = conversations
        .iter()
        .map(|conversation| json!({"conversation": conversation, "last_seq": 1}))
        .collect();
    json!({"ok":true,"op":"inbox.list","value":{"entries":entries,"next_cursor":next_cursor},"revision":revision})
}

fn listed_ids(value: &Value) -> Vec<&str> {
    value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| entry["conversation"].as_str())
        .collect()
}

/// `cloud-inbox-list` is one page per call, from the client's cursor, and hands
/// back the owner's `next_cursor`, so a client can read past the newest 200.
#[test]
fn inbox_list_reads_one_page_from_the_cursor_and_returns_the_next() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    backend.reply("/v1/read", 200, inbox_page(&["conv_a"], json!("k1"), "7"));
    let first = reply(&mux, client, json!({"id":1,"cmd":"cloud-inbox-list"}));
    assert_eq!(first["data"]["next_cursor"], "k1", "{first}");
    backend.reply("/v1/read", 200, inbox_page(&["conv_b"], Value::Null, "8"));
    let second =
        reply(&mux, client, json!({"id":2,"cmd":"cloud-inbox-list","cursor":"k1","limit":5}));
    assert_eq!(listed_ids(&second["data"]), ["conv_b"], "{second}");
    assert_eq!(second["data"]["next_cursor"], Value::Null);
    let posted = backend.posted();
    assert_eq!(posted.len(), 2, "one read per call");
    assert_eq!(posted[0].body["params"], json!({"limit":200}));
    assert_eq!(posted[1].body["params"], json!({"limit":5,"cursor":"k1"}));
}

/// `home-inbox`'s Cloud rows: every page, an entry a later page lists again
/// once (first copy), the first page's revision.
#[test]
fn inbox_list_all_reads_every_page_once() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    backend.reply("/v1/read", 200, inbox_page(&["conv_a", "conv_b"], json!("k1"), "7"));
    backend.reply("/v1/read", 200, inbox_page(&["conv_b", "conv_c"], json!("k2"), "8"));
    backend.reply("/v1/read", 200, inbox_page(&["conv_d"], Value::Null, "9"));
    let all = super::lease_user(&mux, client)
        .unwrap()
        .inbox_list_all(false, Duration::from_secs(60))
        .unwrap();
    assert_eq!(listed_ids(&all), ["conv_a", "conv_b", "conv_c", "conv_d"]);
    assert_eq!(all["revision"], "7");
    assert_eq!(all["next_cursor"], Value::Null);
    let cursors: Vec<Value> =
        backend.posted().iter().map(|post| post.body["params"]["cursor"].clone()).collect();
    assert_eq!(cursors, [Value::Null, json!("k1"), json!("k2")]);
}

/// A cursor the owner hands back unchanged ends the read instead of looping;
/// any page that fails fails the read (the app then keeps its last rows).
#[test]
fn inbox_list_all_stops_on_a_stuck_cursor_and_fails_on_a_later_failure() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let service = super::lease_user(&mux, client).unwrap();
    backend.reply("/v1/read", 200, inbox_page(&["conv_a"], json!("k1"), "7"));
    backend.reply("/v1/read", 200, inbox_page(&["conv_b"], json!("k1"), "7"));
    let stuck = service.inbox_list_all(false, Duration::from_secs(60)).unwrap();
    assert_eq!(listed_ids(&stuck), ["conv_a", "conv_b"]);
    assert_eq!(backend.posted().len(), 2);

    backend.reply("/v1/read", 200, inbox_page(&["conv_c"], json!("k9"), "8"));
    backend.fail("/v1/read", "connection reset");
    assert!(service.inbox_list_all(false, Duration::from_secs(60)).is_err());

    // The first page's failure is the read's.
    backend.fail("/v1/read", "connection reset");
    assert!(service.inbox_list_all(false, Duration::from_secs(60)).is_err());
}

/// Past the budget, no further page is read.
#[test]
fn inbox_list_all_stops_at_its_budget() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    backend.reply("/v1/read", 200, inbox_page(&["conv_a"], json!("k1"), "7"));
    let read =
        super::lease_user(&mux, client).unwrap().inbox_list_all(false, Duration::ZERO).unwrap();
    assert_eq!(listed_ids(&read), ["conv_a"]);
    assert_eq!(read["next_cursor"], "k1");
    assert_eq!(backend.posted().len(), 1);
}

/// A page the owner refuses mid-read (a rate limit) leaves the Cloud rows
/// `unavailable`, never `signed_out`: the app keeps its last rows instead of
/// showing the person signed out.
#[test]
fn a_refused_inbox_page_leaves_the_cloud_rows_unavailable() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    backend.reply("/v1/read", 200, inbox_page(&["conv_a"], json!("k1"), "7"));
    backend.reply(
        "/v1/read",
        429,
        json!({"error":{"code":"rate_limited","message":"slow down","retryable":true}}),
    );
    let error = super::lease_user(&mux, client)
        .unwrap()
        .inbox_list_all(false, Duration::from_secs(60))
        .map_err(anyhow::Error::from)
        .unwrap_err();
    assert_eq!(conversations::cloud_rows_failure(&error), "unavailable", "{error}");
    for (signed_out, state) in [
        (CloudError::SignedOut, "signed_out"),
        (CloudError::SessionExpired, "signed_out"),
        (CloudError::Unauthenticated, "signed_out"),
        (CloudError::Unavailable("reset".into()), "unavailable"),
    ] {
        assert_eq!(conversations::cloud_rows_failure(&signed_out.into()), state);
    }
}
