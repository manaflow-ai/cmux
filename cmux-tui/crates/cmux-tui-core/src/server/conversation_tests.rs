//! Wire tests for the local conversation owner (`local-conversations-v1`,
//! plans/cmux-next/home.md section 2). The JSON matches what the cmux-next
//! app sends and decodes (CmuxNextDaemon/Conversations).

use super::LOCAL_CONVERSATIONS_CAPABILITY;

use super::super::*;

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn conversation_mux() -> (Arc<Mux>, u64) {
    let mux = Mux::new_for_test("conversations", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client)
}

/// A second trusted local connection bound to agent `participant` with a token
/// the local user (`user_client`) minted.
fn agent_client(mux: &Arc<Mux>, user_client: u64, participant: &str) -> u64 {
    let minted =
        run(mux, user_client, json!({"cmd":"conversation-agent-token","participant":participant}))
            .unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let token = minted["token"].clone();
    run(mux, client, json!({"cmd":"conversation-bind","participant":participant,"token":token}))
        .unwrap();
    client
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn rejection(mux: &Arc<Mux>, client: u64, request: Value) -> (String, Option<String>) {
    let error = run(mux, client, request).expect_err("the request must be refused");
    (error.to_string(), response_error_code(&error))
}

fn participants() -> Value {
    json!([
        {"id":"user_local","kind":"human","display_name":"Me"},
        {"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux",
         "acp_session":"mux"}
    ])
}

fn create(mux: &Arc<Mux>, client: u64) -> String {
    let created = run(
        mux,
        client,
        json!({"cmd":"conversation-create","idempotency_key":"create-1","actor":"user_local",
               "title":"mux","participants":participants()}),
    )
    .unwrap();
    assert_eq!(created["replayed"], false);
    created["conversation"]["id"].as_str().unwrap().to_string()
}

fn send(conversation: &str, key: &str, text: &str) -> Value {
    json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":key,
           "actor":"user_local","transaction":format!("tx-{key}"),
           "op":{"kind":"message.send","client_msg_id":key,
                 "parts":[{"type":"text","text":text}]}})
}

fn changed_events(events: &crate::MuxEventReceiver) -> Vec<Value> {
    events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::Conversation(_)))
        .map(|event| subscribed_event_json(&event))
        .collect()
}

#[test]
fn local_conversations_capability_is_advertised() {
    let (mux, client) = conversation_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == LOCAL_CONVERSATIONS_CAPABILITY)
    );
    assert_eq!(LOCAL_CONVERSATIONS_CAPABILITY, "local-conversations-v1");
}

#[test]
fn conversation_create_send_snapshot_and_history_round_trip() {
    let (mux, client) = conversation_mux();
    let events = mux.subscribe();
    let conversation = create(&mux, client);
    assert!(conversation.starts_with("conv_") && conversation.len() == 31, "{conversation}");
    let created = changed_events(&events);
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["event"], "conversation-changed");
    assert_eq!(created[0]["rev"], 1);
    assert_eq!(created[0]["change"]["kind"], "conversation");
    assert_eq!(created[0]["change"]["conversation"]["owner"], "local");

    let sent = run(&mux, client, send(&conversation, "c1", "hi @mux")).unwrap();
    assert_eq!(sent["rev"], 2);
    assert_eq!(sent["seq"], 1);
    assert_eq!(sent["replayed"], false);
    assert_eq!(sent["transaction"], "tx-c1");
    assert_eq!(sent["change"]["kind"], "message");
    let message = &sent["change"]["message"];
    assert!(message["id"].as_str().unwrap().starts_with("msg_"));
    assert_eq!(message["id"].as_str().unwrap().len(), 30);
    assert_eq!(message["conversation"], conversation.as_str());
    assert_eq!(message["client_msg_id"], "c1");
    assert_eq!(message["author"], "user_local");
    assert_eq!(message["parts"], json!([{"type":"text","text":"hi @mux"}]));
    assert_eq!(message["reactions"], json!([]));
    assert!(message.get("edited_at").is_none());
    let created_at = message["created_at"].as_str().unwrap();
    assert_eq!(created_at.len(), 24, "{created_at}");
    assert!(created_at.ends_with('Z'));
    let published = changed_events(&events);
    assert_eq!(published.len(), 1);
    assert_eq!(
        published[0],
        json!({"event":"conversation-changed","conversation":conversation,"rev":2,
               "transaction":"tx-c1","change":sent["change"]})
    );

    run(&mux, client, send(&conversation, "c2", "two")).unwrap();
    let agent = agent_client(&mux, client, "agent_mux");
    let reply = run(
        &mux,
        agent,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"agent-1",
               "op":{"kind":"message.send","client_msg_id":"agent-1",
               "parts":[{"type":"work","session":"child","status":"running"}],
               "reply_to":{"message_id":message["id"],"part_index":0}}}),
    )
    .unwrap();
    assert!(reply.get("transaction").is_none());
    assert_eq!(reply["seq"], 3);
    let reacted = run(
        &mux,
        agent,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"react-1",
               "op":{"kind":"reaction.add","message_id":message["id"],
               "part_index":0,"reaction":{"tapback":"love"}}}),
    )
    .unwrap();
    assert_eq!(reacted["change"]["kind"], "message-updated");
    assert_eq!(reacted["change"]["message"]["reactions"][0]["kind"], json!({"tapback":"love"}));
    let read = run(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"read-1",
               "actor":"user_local","op":{"kind":"read_cursor.set","seq":3}}),
    )
    .unwrap();
    assert_eq!(read["change"], json!({"kind":"read-cursor","participant":"user_local","seq":3}));
    assert!(read.get("seq").is_none());

    let snapshot = run(
        &mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":2}),
    )
    .unwrap();
    let summary = &snapshot["conversation"];
    assert_eq!(summary["last_seq"], 3);
    assert_eq!(summary["rev"], 6);
    assert_eq!(summary["read_cursors"], json!({"user_local":3}));
    assert_eq!(summary["last_message"]["seq"], 3);
    assert_eq!(summary["participants"][1]["agent_class"], "mux");
    let seqs = |messages: &Value| {
        messages.as_array().unwrap().iter().map(|m| m["seq"].as_u64().unwrap()).collect::<Vec<_>>()
    };
    assert_eq!(seqs(&snapshot["messages"]), vec![2, 3]);
    assert_eq!(snapshot["messages"][1]["reply_to"]["message_id"], message["id"]);
    let history = run(
        &mux,
        client,
        json!({"cmd":"conversation-history","conversation":conversation,"before_seq":3,
               "limit":500}),
    )
    .unwrap();
    assert_eq!(seqs(&history["messages"]), vec![1, 2]);
    assert_eq!(history["messages"][0]["reactions"][0]["author"], "agent_mux");

    let listed = run(&mux, client, json!({"cmd":"conversation-list"})).unwrap();
    assert_eq!(listed["conversations"].as_array().unwrap().len(), 1);
    assert_eq!(listed["conversations"][0]["id"], conversation.as_str());
    assert_eq!(listed["conversations"][0]["last_message"]["seq"], 3);
}

#[test]
fn conversation_replay_returns_the_stored_result_and_emits_nothing() {
    let (mux, client) = conversation_mux();
    let conversation = create(&mux, client);
    let first = run(&mux, client, send(&conversation, "c1", "hi")).unwrap();
    let events = mux.subscribe();
    let replay = run(&mux, client, send(&conversation, "c1", "hi")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["rev"], first["rev"]);
    assert_eq!(replay["seq"], first["seq"]);
    assert_eq!(replay["change"], first["change"]);
    assert_eq!(replay["transaction"], "tx-c1");
    let created = run(
        &mux,
        client,
        json!({"cmd":"conversation-create","idempotency_key":"create-1","actor":"user_local",
               "title":"mux","participants":participants()}),
    )
    .unwrap();
    assert_eq!(created["replayed"], true);
    assert_eq!(created["conversation"]["id"], conversation.as_str());
    assert!(changed_events(&events).is_empty(), "a replay must not publish");
    let snapshot = run(
        &mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":500}),
    )
    .unwrap();
    assert_eq!(snapshot["conversation"]["last_seq"], 1);
    assert_eq!(snapshot["conversation"]["rev"], 2);
}

#[test]
fn conversation_rejects_carry_a_stable_reason() {
    let (mux, client) = conversation_mux();
    let conversation = create(&mux, client);
    let sent = run(&mux, client, send(&conversation, "c1", "hi")).unwrap();
    let message_id = sent["change"]["message"]["id"].clone();
    let events = mux.subscribe();
    let cases = [
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"c1",
                   "actor":"user_local","op":{"kind":"message.send","client_msg_id":"c1",
                   "parts":[{"type":"text","text":"different"}]}}),
            "idempotency_conflict",
        ),
        (
            json!({"cmd":"conversation-create","idempotency_key":"create-1",
                   "actor":"user_local","title":"other","participants":participants()}),
            "idempotency_conflict",
        ),
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"x1",
                   "actor":"user_eve","op":{"kind":"message.send","client_msg_id":"x1",
                   "parts":[{"type":"text","text":"hi"}]}}),
            "actor_mismatch",
        ),
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"x2",
                   "actor":"agent_mux","op":{"kind":"message.edit","message_id":message_id,
                   "parts":[{"type":"text","text":"mine now"}]}}),
            "actor_mismatch",
        ),
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"x3",
                   "actor":"user_local","op":{"kind":"message.retract",
                   "message_id":"msg_00000000000000000000000000"}}),
            "unknown_message",
        ),
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"x4",
                   "actor":"user_local","op":{"kind":"message.send","client_msg_id":"x4",
                   "parts":[]}}),
            "invalid_parts",
        ),
        (
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"x5",
                   "actor":"user_local","op":{"kind":"read_cursor.set","seq":2}}),
            "cursor_out_of_range",
        ),
        (
            json!({"cmd":"conversation-op","conversation":"conv_missing","idempotency_key":"x6",
                   "actor":"user_local","op":{"kind":"title.set","title":"t"}}),
            "unknown_conversation",
        ),
        (
            json!({"cmd":"conversation-snapshot","conversation":"conv_missing","tail":1}),
            "unknown_conversation",
        ),
        (
            json!({"cmd":"conversation-typing","conversation":conversation,"actor":"user_eve",
                   "on":true}),
            "actor_mismatch",
        ),
    ];
    for (request, reason) in cases {
        let (error, code) = rejection(&mux, client, request.clone());
        assert_eq!(error, reason, "{request}");
        assert_eq!(code.as_deref(), Some("conversation_rejected"), "{request}");
    }
    // A cursor regression is refused after a valid move.
    run(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"r1",
               "actor":"user_local","op":{"kind":"read_cursor.set","seq":1}}),
    )
    .unwrap();
    let (error, _) = rejection(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"r2",
               "actor":"user_local","op":{"kind":"read_cursor.set","seq":0}}),
    );
    assert_eq!(error, "cursor_regression");
    // Malformed requests are bad requests, not conversation rejects.
    for request in [
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":0}),
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":501}),
        json!({"cmd":"conversation-history","conversation":conversation,"before_seq":2,
               "limit":0}),
        json!({"cmd":"conversation-history","conversation":conversation,"before_seq":2,
               "limit":501}),
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"b1",
               "actor":"user_local","op":{"kind":"message.shout"}}),
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"b2",
               "actor":"user_local","transaction":"","op":{"kind":"title.set","title":"t"}}),
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"",
               "actor":"user_local","op":{"kind":"title.set","title":"t"}}),
        json!({"cmd":"conversation-create","idempotency_key":"create-2","actor":"user_local",
               "title":"t","participants":[{"id":"user_local"}]}),
    ] {
        let (error, code) = rejection(&mux, client, request.clone());
        assert!(error.starts_with("bad request"), "{request}: {error}");
        assert_eq!(code, None, "{request}");
    }
    let published = changed_events(&events);
    assert_eq!(published.len(), 1, "only the cursor move commits: {published:?}");
    assert_eq!(published[0]["rev"], 3);
}

#[test]
fn conversation_typing_is_broadcast_and_never_stored() {
    let (mux, client) = conversation_mux();
    let conversation = create(&mux, client);
    let agent = agent_client(&mux, client, "agent_mux");
    let events = mux.subscribe();
    let typed = run(
        &mux,
        agent,
        json!({"cmd":"conversation-typing","conversation":conversation,"on":true}),
    )
    .unwrap();
    assert_eq!(typed, json!({}));
    assert_eq!(
        changed_events(&events),
        vec![json!({"event":"conversation-typing","conversation":conversation,
                    "participant":"agent_mux","on":true})]
    );
    let snapshot = run(
        &mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":1}),
    )
    .unwrap();
    assert_eq!(snapshot["conversation"]["rev"], 1);
}

#[test]
fn conversation_commands_require_a_trusted_local_connection() {
    let (mux, _) = conversation_mux();
    let remote = mux.control_clients.register(ClientTransport::WebSocket, writer());
    for request in [
        json!({"cmd":"conversation-list"}),
        json!({"cmd":"conversation-create","idempotency_key":"k","actor":"user_local",
               "title":"t","participants":participants()}),
        json!({"cmd":"conversation-snapshot","conversation":"conv_x","tail":1}),
        json!({"cmd":"conversation-history","conversation":"conv_x","before_seq":1,"limit":1}),
        json!({"cmd":"conversation-op","conversation":"conv_x","idempotency_key":"k",
               "actor":"user_local","op":{"kind":"title.set","title":"t"}}),
        json!({"cmd":"conversation-typing","conversation":"conv_x","actor":"user_local",
               "on":true}),
    ] {
        let (error, _) = rejection(&mux, remote, request.clone());
        assert!(error.contains("trusted local connection"), "{request}: {error}");
    }
}

#[test]
fn conversation_store_file_persists_across_reopen() {
    let root = std::env::temp_dir().join(format!(
        "cmux-conversations-wire-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("conversations", crate::SurfaceOptions::default(), &root).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let conversation = create(&mux, client);
    run(&mux, client, send(&conversation, "c1", "persisted")).unwrap();
    let directory = mux.session_state_directory().unwrap();
    drop(mux);
    assert!(directory.join(crate::conversation_store::CONVERSATIONS_FILE).is_file());
    let mut store =
        crate::conversation_store::ConversationStore::open(Some(directory.as_path())).unwrap();
    let (summary, messages) = store.snapshot(&conversation, 10).unwrap();
    assert_eq!(summary.rev, 2);
    assert_eq!(summary.title, "mux");
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].client_msg_id, "c1");
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn conversation_actor_is_stamped_by_the_owner() {
    let (mux, client) = conversation_mux();
    let conversation = create(&mux, client);
    let mine = run(&mux, client, send(&conversation, "c1", "hello")).unwrap();
    let message_id = mine["change"]["message"]["id"].clone();
    assert_eq!(mine["change"]["message"]["author"], "user_local");

    let agent = agent_client(&mux, client, "agent_mux");
    let reply = run(
        &mux,
        agent,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"a1",
               "op":{"kind":"message.send","client_msg_id":"a1",
               "parts":[{"type":"text","text":"**PONG**"}]}}),
    )
    .unwrap();
    assert_eq!(reply["change"]["message"]["author"], "agent_mux");

    let edit = json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"a2",
                      "op":{"kind":"message.edit","message_id":message_id,
                      "parts":[{"type":"text","text":"mine now"}]}});
    assert_eq!(rejection(&mux, agent, edit).0, "not_author");
    let too_soon = json!({"cmd":"conversation-op","conversation":conversation,
                          "idempotency_key":"a3","op":{"kind":"message.send","client_msg_id":"a3",
                          "parts":[{"type":"text","text":"again"}]}});
    assert_eq!(rejection(&mux, agent, too_soon).0, "agent_rate");

    let mint = json!({"cmd":"conversation-agent-token","participant":"agent_other"});
    assert!(run(&mux, agent, mint).is_err(), "only the local user mints tokens");
    let stranger = mux.control_clients.register(ClientTransport::Unix, writer());
    let bad = json!({"cmd":"conversation-bind","participant":"agent_mux","token":"nope"});
    assert!(run(&mux, stranger, bad).unwrap_err().to_string().contains("not valid"));

    let ghost = agent_client(&mux, client, "agent_ghost");
    let intruder = json!({"cmd":"conversation-op","conversation":conversation,
                          "idempotency_key":"g1","op":{"kind":"message.send","client_msg_id":"g1",
                          "parts":[{"type":"text","text":"hi"}]}});
    assert_eq!(rejection(&mux, ghost, intruder).0, "not_participant");
}
