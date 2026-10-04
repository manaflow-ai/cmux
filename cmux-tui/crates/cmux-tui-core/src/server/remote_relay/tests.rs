//! Policy tests of the remote relay (server-remote-conversations.md section 9,
//! for sections 2, 3, 4, 5, 7, 8 and 10). Each request goes through the frame
//! gate first and then the real dispatch and response path, as on the remote
//! entry.

use std::time::{Duration, Instant};

use super::super::*;
use super::gate::{ALLOWED_COMMANDS, COMMAND_PARAMS, Denial, check_frame};
use crate::remote_relay_state::{
    BindRefused, LinkPeer, PairingRecords, RelayLock, RelayStateError, RevocationClock,
};

const OWNER: &str = "42";

struct Records {
    owner: Option<String>,
    deleted: Mutex<Vec<String>>,
}

impl PairingRecords for Records {
    fn owner_user(&self) -> Option<String> {
        self.owner.clone()
    }
    fn delete(&self, install: &str) {
        self.deleted.lock().unwrap().push(install.to_string());
    }
}

struct TestClock(Mutex<Instant>);

impl RevocationClock for TestClock {
    fn now(&self) -> Instant {
        *self.0.lock().unwrap()
    }
}

impl TestClock {
    fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }
}

struct Fixture {
    mux: Arc<Mux>,
    local: u64,
    records: Arc<Records>,
}

fn writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

fn fixture() -> Fixture {
    let mux = Mux::new_for_test("remote-relay", crate::SurfaceOptions::default());
    let local = mux.control_clients.register(ClientTransport::Unix, writer().0);
    let records = Arc::new(Records { owner: Some(OWNER.into()), deleted: Mutex::new(Vec::new()) });
    mux.set_pairing_records(records.clone());
    Fixture { mux, local, records }
}

fn peer(install: &str, user: &str) -> LinkPeer {
    LinkPeer { install: install.into(), user: user.into(), team: "team_a".into() }
}

/// A remote connection of `install` (checked with the control plane now).
fn remote(fixture: &Fixture, install: &str, user: &str) -> u64 {
    fixture.mux.record_remote_check(install).unwrap();
    let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    fixture.mux.bind_remote_peer(client, &peer(install, user)).unwrap();
    client
}

/// One frame through the remote frame path (`handle_frame`, the path the
/// connection handler takes for every remote frame): the gate, then
/// dispatch and the response writer. Returns the response JSON.
fn send(mux: &Arc<Mux>, client: u64, frame: Value) -> Value {
    send_raw(mux, client, &frame.to_string())
}

fn send_raw(mux: &Arc<Mux>, client: u64, frame: &str) -> Value {
    let (writer, outbound) = writer();
    super::handle_frame(mux, client, frame, &writer);
    let message = outbound.try_pop().expect("a response");
    serde_json::from_str(&message).unwrap()
}

fn local(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    handle_command(mux, client, command, &writer().0).unwrap()
}

fn human(id: &str, name: &str) -> Value {
    json!({"id": id, "kind": "human", "display_name": name})
}

fn mux_agent() -> Value {
    json!({"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux",
           "acp_session":"mux"})
}

/// A local conversation, then the system path adds the device participant of
/// each install in `devices` (as pairing does).
fn create(fixture: &Fixture, key: &str, participants: Value, devices: &[&str]) -> String {
    let created = local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-create","idempotency_key":key,"title":"mux",
               "participants":participants}),
    );
    let conversation = created["conversation"]["id"].as_str().unwrap().to_string();
    for install in devices {
        let name = format!("Me ({install})");
        fixture.mux.add_remote_participant_system(&conversation, install, &name).unwrap();
    }
    conversation
}

fn op(conversation: &str, key: &str, op: Value) -> Value {
    json!({"id": 1, "cmd":"conversation-op","conversation":conversation,"idempotency_key":key,
           "op": op})
}

fn text_send(key: &str, text: &str) -> Value {
    json!({"kind":"message.send","client_msg_id":key,"parts":[{"type":"text","text":text}]})
}

fn assert_code(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(reply["error_code"], json!(code), "{reply}");
    assert_eq!(reply["error"], json!(code), "codes only, no detail: {reply}");
}

// Transport and gate (sections 2, 3, 4, 7).

#[test]
fn a_remote_connection_is_never_a_trusted_local_connection() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    assert!(!fixture.mux.control_clients.is_unix(client));
    assert!(fixture.mux.control_clients.is_remote(client));
    assert!(!fixture.mux.control_clients.is_remote(fixture.local));
}

#[test]
fn url_open_loopback_scheduler_resource_and_binary_frames_are_refused_before_any_router() {
    for (frame, denial) in [
        (r#"{"id":1,"cmd":"url-open","terminal_id":"t","url":"https://x"}"#, Denial::Command),
        (
            r#"{"id":1,"cmd":"loopback-open","stream":1,"host":"127.0.0.1","port":22}"#,
            Denial::Command,
        ),
        (r#"{"id":1,"cmd":"loopback-status"}"#, Denial::Command),
        (r#"{"id":1,"cmd":"scheduler.dispatch"}"#, Denial::Command),
        (
            r#"{"protocol":"cmux.protocol/2","id":"r","op":"workspace.list"}"#,
            Denial::ResourceProtocol,
        ),
        (r#"{"v":2,"op":"workspace.list"}"#, Denial::NoCommand),
        ("\u{0}\u{1}binary", Denial::NotAnObject),
        ("[1,2]", Denial::NotAnObject),
        ("not json", Denial::NotAnObject),
    ] {
        assert_eq!(check_frame(frame), Err(denial), "{frame}");
    }
}

/// Every daemon command (the spec list plus commands outside it) is refused
/// unless it is on the section 4 list, so a new command is denied by default.
/// Every serde name of the daemon's `Command` enum, from serde's own list
/// of expected variants, so a new command is in the table test at once.
fn daemon_command_names() -> Vec<String> {
    let error = serde_json::from_value::<Command>(json!({"cmd": "__no_such_command__"}))
        .err()
        .expect("an unknown command is refused")
        .to_string();
    let list = error.split("expected one of ").nth(1).expect("serde lists the variants");
    list.split(", ").map(|name| name.trim().trim_matches('`').to_string()).collect()
}

#[test]
fn only_the_section_4_commands_pass_the_gate() {
    let schema: Value =
        serde_json::from_str(include_str!("../../../../../spec/sdk-schema.json")).unwrap();
    let mut names: Vec<String> = schema["commands"].as_object().unwrap().keys().cloned().collect();
    assert!(names.len() > 100, "the spec command list looks truncated");
    let variants = daemon_command_names();
    assert!(variants.len() > 150, "the Command enum list looks truncated: {}", variants.len());
    names.extend(variants);
    names.sort();
    names.dedup();
    for extra in ["conversation-tabs", "new-conversation-tab", "loopback-open", "scheduler.run"] {
        names.push(extra.to_string());
    }
    let expected = [
        "conversation-history",
        "conversation-list",
        "conversation-op",
        "conversation-snapshot",
        "conversation-typing",
        "identify",
        "set-client-info",
        "subscribe",
    ];
    let mut passed: Vec<String> = names
        .iter()
        .filter(|name| {
            check_frame(&json!({"id": 1, "cmd": name}).to_string()) != Err(Denial::Command)
        })
        .cloned()
        .collect();
    passed.sort();
    assert_eq!(passed, expected);
    let mut allowed: Vec<&str> = ALLOWED_COMMANDS.iter().map(|(name, _)| *name).collect();
    allowed.sort();
    assert_eq!(allowed, expected);
    for refused in [
        "conversation-search",
        "conversation-tabs",
        "new-conversation-tab",
        "conversation-agent-token",
        "conversation-bind",
        "conversation-create",
        "ping",
    ] {
        assert_eq!(check_frame(&json!({"cmd": refused}).to_string()), Err(Denial::Command));
    }
}

#[test]
fn set_client_info_takes_only_conversation_capabilities_and_ignores_identity() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let loopback = json!({"id":1,"cmd":"set-client-info","capabilities":["loopback-forward"]});
    assert_code(&send(&fixture.mux, client, loopback), "remote_denied");
    let kind = json!({"id":1,"cmd":"set-client-info","kind":"native-browser"});
    assert_code(&send(&fixture.mux, client, kind), "remote_denied");
    let reply = send(
        &fixture.mux,
        client,
        json!({"id":1,"cmd":"set-client-info","name":"MacBook",
               "capabilities":["local-conversations-v1"],"user_id":"user_local",
               "display_name":"Root","device_kind":"mac","device_name":"x","device_id":"d"}),
    );
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(fixture.mux.conversation_principal(client), "remote_inst_1");
    let state = fixture.mux.control_clients.state.lock().unwrap();
    assert!(state.clients[&client].identity.is_empty(), "identity is only the stamp");
}

#[test]
fn subscribe_with_surface_or_tree_events_is_refused() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    for frame in [
        json!({"id":1,"cmd":"subscribe","surface":1}),
        json!({"id":1,"cmd":"subscribe","tree_events":"deltas"}),
    ] {
        assert_code(&send(&fixture.mux, client, frame), "remote_denied");
    }
}

#[test]
fn a_remote_identify_reveals_no_local_state() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let reply = send(&fixture.mux, client, json!({"id":1,"cmd":"identify"}));
    let data = reply["data"].as_object().unwrap();
    let mut keys: Vec<&str> = data.keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(keys, ["app", "capabilities", "protocol"], "{reply}");
    assert_eq!(data["capabilities"], json!(["local-conversations-v1"]));
    assert_eq!(data["protocol"], json!(PROTOCOL_VERSION), "{reply}");
}

#[test]
fn command_bearing_unknown_and_id_shaped_params_are_refused_on_every_method() {
    let conversation = "conv_01ARZ3NDEKTSV4RRFFQ69G5FAV";
    for (command, _) in ALLOWED_COMMANDS {
        for param in COMMAND_PARAMS {
            let frame = json!({"id": 1, "cmd": command, *param: "sh -c id"});
            assert_eq!(check_frame(&frame.to_string()), Err(Denial::CommandParam), "{frame}");
        }
        let frame = json!({"id": 1, "cmd": command, "workspace": 1});
        assert_eq!(check_frame(&frame.to_string()), Err(Denial::UnknownParam), "{frame}");
    }
    let mut send = op(conversation, "k", text_send("k", "hi"));
    send["op"]["command"] = json!("sh");
    assert_eq!(check_frame(&send.to_string()), Err(Denial::CommandParam));
    for bad in ["@1", "conv_", "mux", "conv_../x", "conv_a b"] {
        let frame = json!({"cmd":"conversation-snapshot","conversation":bad,"tail":1});
        assert_eq!(check_frame(&frame.to_string()), Err(Denial::IdShape), "{bad}");
    }
    let stamp =
        json!({"cmd":"conversation-list","link_peer":{"install":"x","user":"42","team":"t"}});
    assert_eq!(check_frame(&stamp.to_string()), Err(Denial::UnknownParam));
}

#[test]
fn only_text_parts_and_the_remote_op_kinds_pass() {
    let conversation = "conv_01ARZ3NDEKTSV4RRFFQ69G5FAV";
    let work = json!({"kind":"message.send","client_msg_id":"k",
                      "parts":[{"type":"work","session":"s","status":"running","preview":"x"}]});
    let approval = json!({"kind":"message.send","client_msg_id":"k",
                          "parts":[{"type":"approval","request":"r"}]});
    for refused in [work, approval] {
        assert_eq!(check_frame(&op(conversation, "k", refused).to_string()), Err(Denial::Part));
    }
    for kind in ["participants.add", "title.set", "approval.respond", "participants.add_system"] {
        let frame = op(conversation, "k", json!({"kind": kind}));
        assert_eq!(check_frame(&frame.to_string()), Err(Denial::OpKind), "{kind}");
    }
    let runs = json!({"kind":"message.send","client_msg_id":"k","parts":[{"type":"text",
                      "text":"hi","runs":[{"start":0,"length":2,"link":"https://x"}]}]});
    assert_eq!(check_frame(&op(conversation, "k", runs).to_string()), Ok(()));
}

#[test]
fn a_remote_connection_without_a_peer_record_is_refused_not_local_user() {
    let fixture = fixture();
    let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(fixture.mux.principal(client), None);
    for frame in [json!({"id":1,"cmd":"conversation-list"}), json!({"id":1,"cmd":"subscribe"})] {
        assert_code(&send(&fixture.mux, client, frame), "remote_denied");
    }
}

// Ownership and mapping (section 5).

#[test]
fn the_owner_device_sends_as_its_own_participant_with_remote_origin() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let conversation =
        create(&fixture, "c1", json!([human("user_local", "Me"), mux_agent()]), &["inst_1"]);
    let reply = send(&fixture.mux, client, op(&conversation, "m1", text_send("m1", "hello")));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let message = &reply["data"]["change"]["message"];
    assert_eq!(message["author"], "remote_inst_1");
    assert_eq!(message["origin"], json!({"kind":"remote","install":"inst_1"}));
    let snapshot = local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":5}),
    );
    assert_eq!(snapshot["messages"][0]["author"], "remote_inst_1");
    assert_eq!(snapshot["messages"][0]["origin"]["kind"], "remote");

    let mut as_user = op(&conversation, "m2", text_send("m2", "as you"));
    as_user["actor"] = json!("user_local");
    assert_code(&send(&fixture.mux, client, as_user), "actor_mismatch");
}

#[test]
fn a_device_edits_or_retracts_only_its_own_messages() {
    let fixture = fixture();
    let one = remote(&fixture, "inst_1", OWNER);
    let two = remote(&fixture, "inst_2", OWNER);
    let conversation =
        create(&fixture, "c1", json!([human("user_local", "Me")]), &["inst_1", "inst_2"]);
    let mine = local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"l1",
               "op":text_send("l1","local")}),
    );
    let local_id = mine["change"]["message"]["id"].as_str().unwrap().to_string();
    let other = send(&fixture.mux, two, op(&conversation, "t1", text_send("t1", "two")));
    let other_id = other["data"]["change"]["message"]["id"].as_str().unwrap().to_string();
    for target in [&local_id, &other_id] {
        let edit = json!({"kind":"message.edit","message_id":target,
                          "parts":[{"type":"text","text":"mine"}]});
        assert_code(&send(&fixture.mux, one, op(&conversation, "e", edit)), "not_author");
        let retract = json!({"kind":"message.retract","message_id":target});
        assert_code(&send(&fixture.mux, one, op(&conversation, "r", retract)), "not_author");
    }
}

#[test]
fn a_peer_that_is_not_the_owner_owns_nothing() {
    let fixture = fixture();
    let stranger = remote(&fixture, "inst_9", "7");
    let conversation = create(&fixture, "c1", json!([human("user_local", "Me")]), &["inst_9"]);
    let list = send(&fixture.mux, stranger, json!({"id":1,"cmd":"conversation-list"}));
    assert_eq!(list["data"]["conversations"], json!([]), "{list}");
    let snapshot =
        json!({"id":1,"cmd":"conversation-snapshot","conversation":conversation,"tail":1});
    assert_code(&send(&fixture.mux, stranger, snapshot), "remote_denied");
}

#[test]
fn unknown_and_unowned_ids_give_byte_identical_errors() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let unowned = create(&fixture, "c1", json!([human("user_local", "Me"), mux_agent()]), &[]);
    let unknown = "conv_01ARZ3NDEKTSV4RRFFQ69G5FAV";
    let reply = |conversation: &str, frame: fn(&str) -> Value| {
        send(&fixture.mux, client, frame(conversation)).to_string()
    };
    let frames: [fn(&str) -> Value; 4] = [
        |c| json!({"id":1,"cmd":"conversation-snapshot","conversation":c,"tail":1}),
        |c| json!({"id":1,"cmd":"conversation-history","conversation":c,"before_seq":9,"limit":1}),
        |c| json!({"id":1,"cmd":"conversation-typing","conversation":c,"on":true}),
        |c| op(c, "k", text_send("k", "x")),
    ];
    for frame in frames {
        let unowned_reply = reply(&unowned, frame);
        assert_eq!(unowned_reply, reply(unknown, frame));
        assert!(unowned_reply.contains("remote_denied"), "{unowned_reply}");
    }
    let owned = create(&fixture, "c2", json!([human("user_local", "Me")]), &["inst_1"]);
    let unknown_message =
        json!({"kind":"message.retract","message_id":"msg_01ARZ3NDEKTSV4RRFFQ69G5FAV"});
    assert_code(&send(&fixture.mux, client, op(&owned, "k", unknown_message)), "remote_denied");
}

#[test]
fn the_list_holds_only_owned_conversations_as_projections() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let owned = create(&fixture, "c1", json!([human("user_local", "Me")]), &["inst_1"]);
    create(&fixture, "c2", json!([human("user_local", "Me"), mux_agent()]), &[]);
    let list = send(&fixture.mux, client, json!({"id":1,"cmd":"conversation-list"}));
    let conversations = list["data"]["conversations"].as_array().unwrap();
    assert_eq!(conversations.len(), 1, "{list}");
    assert_eq!(conversations[0]["id"], json!(owned));
}

// Redaction (section 8).

fn keys(value: &Value) -> Vec<String> {
    let mut keys: Vec<String> = value.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    keys
}

#[test]
fn remote_json_carries_only_the_section_8_fields() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let conversation = create(
        &fixture,
        "c1",
        json!([human("user_local", "Me"), mux_agent()]),
        &["inst_1", "inst_2"],
    );
    let work = json!({"kind":"message.send","client_msg_id":"w1","parts":[
        {"type":"text","text":"working"},
        {"type":"work","session":"secret-session","host":"h","status":"running",
         "preview":"TOKEN=abc"}]});
    local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"w1","op":work}),
    );
    local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"rc",
               "op":{"kind":"read_cursor.set","seq":1}}),
    );
    let snapshot = send(
        &fixture.mux,
        client,
        json!({"id":1,"cmd":"conversation-snapshot","conversation":conversation,"tail":5}),
    );
    let summary = &snapshot["data"]["conversation"];
    assert_eq!(
        keys(summary),
        ["id", "last_message", "last_seq", "participants", "rev", "title", "updated_at"]
    );
    for participant in summary["participants"].as_array().unwrap() {
        assert_eq!(keys(participant), ["display_name", "id", "kind"], "{participant}");
    }
    let message = &snapshot["data"]["messages"][0];
    assert_eq!(keys(message), ["author", "created_at", "id", "parts", "reactions", "seq"]);
    assert_eq!(message["parts"], json!([{"type":"text","text":"working"}]));
    let text = snapshot.to_string();
    for secret in ["secret-session", "TOKEN=abc", "acp_session", "read_cursors", "client_msg_id"] {
        assert!(!text.contains(secret), "{secret} leaked: {text}");
    }
}

#[test]
fn remote_events_are_projected_and_foreign_ones_dropped() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let owned = create(&fixture, "c1", json!([human("user_local", "Me")]), &["inst_1"]);
    let foreign = create(&fixture, "c2", json!([human("user_local", "Me"), mux_agent()]), &[]);
    let events = fixture.mux.subscribe();
    let commit = |conversation: &str, key: &str, op: Value| {
        local(
            &fixture.mux,
            fixture.local,
            json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":key,
                   "transaction":"tx-local","op":op}),
        );
    };
    commit(&owned, "a", text_send("a", "owned"));
    commit(&foreign, "b", text_send("b", "foreign"));
    commit(&owned, "c", json!({"kind":"read_cursor.set","seq":1}));
    fixture.mux.emit(MuxEvent::PairingResolved { request: 1 });
    let projected: Vec<Value> = events
        .try_iter()
        .filter_map(|event| super::conversations::remote_event(&fixture.mux, client, &event))
        .collect();
    assert_eq!(projected.len(), 1, "{projected:?}");
    let event = &projected[0];
    assert_eq!(keys(event), ["change", "conversation", "event", "rev"]);
    assert_eq!(event["change"]["kind"], "message");
    assert!(!event.to_string().contains("tx-local"));
    let own_cursor = json!({"kind":"read-cursor","participant":"remote_inst_1","seq":1});
    assert_eq!(super::project::change(&own_cursor, "remote_inst_1"), Some(own_cursor.clone()));
    assert_eq!(super::project::change(&own_cursor, "remote_inst_2"), None);
}

#[test]
fn error_codes_follow_the_section_8_mapping() {
    for (reason, code) in [
        (Some("unknown_conversation"), "remote_denied"),
        (Some("unknown_message"), "remote_denied"),
        (Some("not_participant"), "remote_denied"),
        (Some("actor_mismatch"), "actor_mismatch"),
        (Some("not_author"), "not_author"),
        (Some("invalid_parts"), "invalid_parts"),
        (Some("idempotency_conflict"), "idempotency_conflict"),
        (Some("cursor_regression"), "cursor_regression"),
        (Some("agent_budget"), "remote_error"),
        (None, "remote_error"),
    ] {
        assert_eq!(super::remote_error_code(reason, Some("/tmp/x 42")), code, "{reason:?}");
    }
    assert_eq!(super::remote_error_code(None, Some("remote_denied")), "remote_denied");
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let reply = send(
        &fixture.mux,
        client,
        json!({"id":1,"cmd":"conversation-snapshot","conversation":"conv_01ARZ3NDEKTSV4RRFFQ69G5FAV",
               "tail":9999}),
    );
    assert_code(&reply, "remote_error");
    assert!(reply.get("reason").is_none(), "{reply}");
}

// Revocation (section 10).

#[test]
fn offline_limits_follow_the_injected_clock() {
    let fixture = fixture();
    let clock = Arc::new(TestClock(Mutex::new(Instant::now())));
    fixture.mux.set_remote_revocation_clock(clock.clone()).unwrap();
    let existing = remote(&fixture, "inst_1", OWNER);
    clock.advance(Duration::from_secs(23 * 3600));
    assert!(
        fixture.mux.enforce_remote_limits().unwrap().is_empty(),
        "an unreachable cloud closes nothing"
    );
    clock.advance(Duration::from_secs(2 * 3600));
    let late = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(
        fixture.mux.bind_remote_peer(late, &peer("inst_1", OWNER)),
        Err(BindRefused::Policy)
    );
    assert_eq!(fixture.mux.principal(late), None, "24 h: new streams refused");
    assert!(fixture.mux.control_clients.is_remote(existing), "24 h: existing streams stay");
    assert!(fixture.mux.enforce_remote_limits().unwrap().is_empty());
    clock.advance(Duration::from_secs(48 * 3600));
    assert_eq!(fixture.mux.enforce_remote_limits().unwrap(), ["inst_1"]);
    assert!(!fixture.mux.control_clients.is_remote(existing), "72 h: existing streams closed");
}

#[test]
fn a_revoke_acts_in_one_step() {
    let fixture = fixture();
    let one = remote(&fixture, "inst_1", OWNER);
    let other = remote(&fixture, "inst_2", OWNER);
    fixture.mux.revoke_remote_install("inst_1").unwrap();
    assert!(!fixture.mux.control_clients.is_remote(one));
    assert_eq!(fixture.mux.principal(one), None);
    assert!(fixture.mux.control_clients.is_remote(other));
    assert_eq!(*fixture.records.deleted.lock().unwrap(), ["inst_1"]);
    let again = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    fixture.mux.record_remote_check("inst_1").unwrap();
    assert_eq!(
        fixture.mux.bind_remote_peer(again, &peer("inst_1", OWNER)),
        Err(BindRefused::Policy)
    );
    assert_eq!(fixture.mux.principal(again), None, "a revoke is final");
}

#[test]
fn an_install_never_checked_opens_no_stream() {
    let fixture = fixture();
    let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(
        fixture.mux.bind_remote_peer(client, &peer("inst_new", OWNER)),
        Err(BindRefused::Policy)
    );
    assert_eq!(fixture.mux.principal(client), None);
}

// Device ids and principals (section 5, lane 12 review P2-1).

#[test]
fn pairing_adds_the_device_to_the_owners_conversations() {
    let fixture = fixture();
    let mine = create(&fixture, "c1", json!([human("user_local", "Me"), mux_agent()]), &[]);
    let second = create(&fixture, "c2", json!([human("user_local", "Me")]), &[]);
    assert_eq!(fixture.mux.pair_remote_install("inst_1", "Me (MacBook)").unwrap(), 2);
    assert_eq!(fixture.mux.pair_remote_install("inst_1", "Me (MacBook)").unwrap(), 0);
    let participants = |conversation: &str| {
        let snapshot = local(
            &fixture.mux,
            fixture.local,
            json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":1}),
        );
        snapshot["conversation"]["participants"].clone()
    };
    let device = participants(&mine)
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "remote_inst_1")
        .cloned();
    let device = device.expect("the device joined the owner's conversation");
    assert_eq!(device["kind"], "human");
    assert_eq!(device["person"], "user_local");
    assert!(participants(&second).to_string().contains("remote_inst_1"));
}

#[test]
fn no_client_creates_or_impersonates_a_device_participant() {
    let fixture = fixture();
    let device =
        json!({"id":"remote_inst_1","kind":"human","display_name":"x","person":"user_local"});
    let create = json!({"cmd":"conversation-create","idempotency_key":"k","title":"t",
                        "participants":[human("user_local", "Me"), device]});
    let command: Command = serde_json::from_value(create).unwrap();
    let error = handle_command(&fixture.mux, fixture.local, command, &writer().0).unwrap_err();
    assert_eq!(error.to_string(), "invalid_participant");
    let conversation = create_plain(&fixture);
    let add = json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"a",
                     "op":{"kind":"participants.add","participant":device}});
    let command: Command = serde_json::from_value(add).unwrap();
    let error = handle_command(&fixture.mux, fixture.local, command, &writer().0).unwrap_err();
    assert_eq!(error.to_string(), "invalid_participant");
    for request in [
        json!({"cmd":"conversation-agent-token","participant":"remote_inst_1"}),
        json!({"cmd":"conversation-bind","participant":"remote_inst_1","token":"t"}),
        json!({"cmd":"conversation-agent-token","participant":"user_local"}),
    ] {
        let command: Command = serde_json::from_value(request.clone()).unwrap();
        assert!(
            handle_command(&fixture.mux, fixture.local, command, &writer().0).is_err(),
            "{request}"
        );
    }
}

fn create_plain(fixture: &Fixture) -> String {
    create(fixture, "plain", json!([human("user_local", "Me"), mux_agent()]), &[])
}

#[test]
fn a_remote_connection_never_falls_back_to_the_local_user() {
    let fixture = fixture();
    let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    fixture.mux.bind_conversation_principal(client, "remote_inst_1".into());
    assert_eq!(fixture.mux.principal(client), None);
    assert_ne!(fixture.mux.conversation_principal(client), "user_local");
    fixture.mux.unbind_conversation_principal(client);
    assert_ne!(fixture.mux.conversation_principal(client), "user_local");
    let websocket = fixture.mux.control_clients.register(ClientTransport::WebSocket, writer().0);
    assert_ne!(fixture.mux.conversation_principal(websocket), "user_local");
}

// Security review round 1 (P2-1, P2-2, P3-1, P3-2, P3-6).

/// P2-1: a device reaction to a local message does not make that message
/// remote; only the device's own message is.
#[test]
fn a_device_reaction_keeps_the_local_message_origin() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let conversation = create(&fixture, "c1", json!([human("user_local", "Me")]), &["inst_1"]);
    let mine = local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"l1",
               "op":text_send("l1","local")}),
    );
    let local_id = mine["change"]["message"]["id"].as_str().unwrap().to_string();
    for (key, kind) in [("r1", "reaction.add"), ("r2", "reaction.remove")] {
        let reaction = json!({"kind": kind,"message_id":local_id,"part_index":0,
                              "reaction":{"tapback":"like"}});
        let reply = send(&fixture.mux, client, op(&conversation, key, reaction));
        assert_eq!(reply["ok"], json!(true), "{reply}");
    }
    let snapshot = local(
        &fixture.mux,
        fixture.local,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":5}),
    );
    assert!(snapshot["messages"][0].get("origin").is_none(), "{snapshot}");
}

/// P2-2: every frame rechecks the revocation policy, so a revoked install
/// is refused even while its stream is still open; a refused bind records
/// nothing and tells the connection loop to close.
#[test]
fn a_revoked_install_is_refused_on_its_next_frame() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let list = json!({"id":1,"cmd":"conversation-list"});
    assert_eq!(send(&fixture.mux, client, list.clone())["ok"], json!(true));
    fixture.mux.remote_relay().revocation.lock().unwrap().record_revoked("inst_1");
    assert_code(&send(&fixture.mux, client, list), "remote_denied");
    let late = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(
        fixture.mux.bind_remote_peer(late, &peer("inst_1", OWNER)),
        Err(BindRefused::Policy)
    );
    assert!(fixture.mux.remote_relay().peer(late).is_none());
}

/// P2-2: a revoke and a bind of the same install never leave a served
/// stream behind, whichever runs first.
#[test]
fn a_revoke_racing_a_bind_leaves_no_served_stream() {
    for _ in 0..200 {
        let fixture = fixture();
        fixture.mux.record_remote_check("inst_1").unwrap();
        let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
        let binder = {
            let mux = fixture.mux.clone();
            std::thread::spawn(move || mux.bind_remote_peer(client, &peer("inst_1", OWNER)))
        };
        fixture.mux.revoke_remote_install("inst_1").unwrap();
        let bound = binder.join().unwrap();
        let served = fixture.mux.remote_relay().peer(client).is_some()
            && fixture.mux.control_clients.is_remote(client);
        assert!(!served, "bound={bound:?}: a revoked install kept a served stream");
    }
}

/// P3-1: a peer record makes a client remote even when its transport says
/// otherwise.
#[test]
fn a_peer_record_makes_a_client_remote() {
    let fixture = fixture();
    let client = fixture.mux.control_clients.register(ClientTransport::Unix, writer().0);
    fixture.mux.remote_relay().peers.lock().unwrap().insert(client, peer("inst_1", OWNER));
    let identify = send(&fixture.mux, client, json!({"id":1,"cmd":"identify"}));
    assert!(identify["data"].get("pid").is_none(), "{identify}");
    let command: Command = serde_json::from_value(json!({"cmd":"ping"})).unwrap();
    assert!(handle_command(&fixture.mux, client, command, &writer().0).is_err());
}

/// P3-2: no local error path answers a remote frame with text.
#[test]
fn remote_refusals_are_codes_only_on_every_path() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let bad_type = r#"{"id":4,"cmd":"conversation-snapshot","conversation":"conv_01ARZ3NDEKTSV4RRFFQ69G5FAV","tail":"x"}"#;
    for (frame, code) in [
        (r#"{"id":1,"cmd":"url-open","terminal_id":"t","url":"https://x"}"#, "remote_denied"),
        (r#"{"id":2,"cmd":"vt-state","surface":1}"#, "remote_denied"),
        (r#"{"id":3,"cmd":"shutdown-daemon"}"#, "remote_denied"),
        (bad_type, "remote_error"),
        ("not json", "remote_denied"),
    ] {
        let reply = send_raw(&fixture.mux, client, frame);
        assert_code(&reply, code);
        assert_eq!(keys(&reply).len(), if reply.get("id").is_some() { 4 } else { 3 }, "{reply}");
    }
}

/// P3-6: pairing joins every conversation or none.
#[test]
fn a_pairing_that_cannot_join_every_conversation_joins_none() {
    let fixture = fixture();
    let mut full = vec![human("user_local", "Me")];
    for index in 1..cmux_conversation::MAX_PARTICIPANTS {
        full.push(json!({"id": format!("agent_{index}"), "kind":"agent","display_name":"a"}));
    }
    let crowded = create(&fixture, "c1", Value::Array(full), &[]);
    let open = create(&fixture, "c2", json!([human("user_local", "Me")]), &[]);
    assert!(fixture.mux.pair_remote_install("inst_1", "Me (MacBook)").is_err());
    for conversation in [&crowded, &open] {
        let snapshot = local(
            &fixture.mux,
            fixture.local,
            json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":1}),
        );
        assert!(!snapshot.to_string().contains("remote_inst_1"), "{snapshot}");
    }
}

// Landing condition (round 3): an unregistered id fails closed, and a
// remote-entry connection keeps the remote path after its record is gone.

/// One frame through the connection path with the connection's own
/// transport value.
fn connection_frame(mux: &Arc<Mux>, client: u64, transport: ClientTransport, frame: &str) -> Value {
    let (writer, outbound) = writer();
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new(Arc::new(
        ServerSurfaceOperationAdmission::default(),
    )));
    handle_connection_frame(mux, client, transport, frame, &writer, &scheduler);
    let message = outbound.try_pop().expect("a response");
    serde_json::from_str(&message).unwrap()
}

#[test]
fn an_unregistered_client_id_fails_closed() {
    let fixture = fixture();
    let stray = 987_654;
    assert!(fixture.mux.control_clients.transport_of(stray).is_none());
    for request in [json!({"cmd":"ping"}), json!({"cmd":"list-workspaces"})] {
        let command: Command = serde_json::from_value(request.clone()).unwrap();
        let error = handle_command(&fixture.mux, stray, command, &writer().0).unwrap_err();
        assert_eq!(error.to_string(), "remote_denied", "{request}");
    }
    assert_ne!(fixture.mux.conversation_principal(stray), "user_local");
    for transport in [ClientTransport::Unix, ClientTransport::WebSocket] {
        let reply = connection_frame(&fixture.mux, stray, transport, r#"{"id":1,"cmd":"ping"}"#);
        assert_code(&reply, "remote_denied");
        let list = connection_frame(
            &fixture.mux,
            stray,
            transport,
            r#"{"id":2,"cmd":"conversation-list"}"#,
        );
        assert_code(&list, "remote_denied");
    }
}

#[test]
fn a_remote_entry_connection_keeps_the_remote_path_after_disconnect() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    assert!(disconnect_client(&fixture.mux, client, false));
    assert!(fixture.mux.control_clients.transport_of(client).is_none());
    let frame = r#"{"id":1,"cmd":"url-open","terminal_id":"t","url":"https://x"}"#;
    let reply = connection_frame(&fixture.mux, client, ClientTransport::Remote, frame);
    assert_code(&reply, "remote_denied");
    let bad = r#"{"id":2,"cmd":"conversation-snapshot","conversation":"conv_01ARZ3NDEKTSV4RRFFQ69G5FAV","tail":"x"}"#;
    assert_code(
        &connection_frame(&fixture.mux, client, ClientTransport::Remote, bad),
        "remote_error",
    );
}

// Poisoned relay locks (lane 10 lock slice): every admission, binding and
// revocation step fails closed and returns a typed error.

/// Poisons `mutex`: a panic while it is held.
fn poison<T>(mutex: &Mutex<T>) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _held = mutex.lock().unwrap();
        panic!("poisons the lock for a fail-closed test");
    }));
    assert!(mutex.is_poisoned());
}

const POISONED_REVOCATION: RelayStateError = RelayStateError::Poisoned(RelayLock::Revocation);
const POISONED_PEERS: RelayStateError = RelayStateError::Poisoned(RelayLock::Peers);

#[test]
fn a_poisoned_revocation_lock_records_no_check_and_binds_no_stream() {
    let fixture = fixture();
    poison(&fixture.mux.remote_relay().revocation);
    assert_eq!(fixture.mux.record_remote_check("inst_1"), Err(POISONED_REVOCATION));
    let client = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(
        fixture.mux.bind_remote_peer(client, &peer("inst_1", OWNER)),
        Err(BindRefused::State(POISONED_REVOCATION))
    );
    assert_eq!(fixture.mux.principal(client), None);
    let clock = Arc::new(TestClock(Mutex::new(Instant::now())));
    assert_eq!(fixture.mux.set_remote_revocation_clock(clock), Err(POISONED_REVOCATION));
}

#[test]
fn a_poisoned_revocation_lock_refuses_the_next_frame_of_an_open_stream() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    let list = json!({"id":1,"cmd":"conversation-list"});
    assert_eq!(send(&fixture.mux, client, list.clone())["ok"], json!(true));
    poison(&fixture.mux.remote_relay().revocation);
    assert_code(&send(&fixture.mux, client, list), "remote_denied");
}

#[test]
fn a_poisoned_pairing_lock_denies_the_owner_scope() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    poison(&fixture.mux.remote_relay().pairing);
    assert_code(
        &send(&fixture.mux, client, json!({"id":1,"cmd":"conversation-list"})),
        "remote_denied",
    );
}

/// A poisoned peers lock cannot say which clients have a peer record, so
/// no client gets a principal from it and none is trusted as local.
#[test]
fn a_poisoned_peers_lock_gives_no_principal_and_no_local_trust() {
    let fixture = fixture();
    let client = remote(&fixture, "inst_1", OWNER);
    poison(&fixture.mux.remote_relay().peers);
    assert_eq!(fixture.mux.principal(client), None);
    assert!(fixture.mux.is_remote_client(fixture.local));
    assert_eq!(fixture.mux.principal(fixture.local), None);
    let late = fixture.mux.control_clients.register(ClientTransport::Remote, writer().0);
    assert_eq!(
        fixture.mux.bind_remote_peer(late, &peer("inst_1", OWNER)),
        Err(BindRefused::State(POISONED_PEERS))
    );
}

#[test]
fn a_poisoned_registry_lock_trusts_no_client_as_local() {
    let fixture = fixture();
    poison(&fixture.mux.control_clients.state);
    assert!(fixture.mux.control_clients.transport_of(fixture.local).is_none());
    assert!(fixture.mux.is_remote_client(fixture.local));
}

/// A revoke that meets a poisoned lock cannot tell the install's streams
/// apart, so it closes every remote stream, and still deletes the record.
#[test]
fn a_revoke_on_a_poisoned_lock_closes_every_remote_stream() {
    let fixture = fixture();
    let one = remote(&fixture, "inst_1", OWNER);
    let other = remote(&fixture, "inst_2", OWNER);
    poison(&fixture.mux.remote_relay().peers);
    assert_eq!(fixture.mux.revoke_remote_install("inst_1"), Err(POISONED_PEERS));
    assert!(!fixture.mux.control_clients.is_remote(one));
    assert!(!fixture.mux.control_clients.is_remote(other));
    assert!(matches!(
        fixture.mux.control_clients.transport_of(fixture.local),
        Some(ClientTransport::Unix)
    ));
    assert_eq!(*fixture.records.deleted.lock().unwrap(), ["inst_1"]);
}

#[test]
fn the_offline_limits_on_a_poisoned_lock_close_every_remote_stream() {
    let fixture = fixture();
    let one = remote(&fixture, "inst_1", OWNER);
    poison(&fixture.mux.remote_relay().revocation);
    assert_eq!(fixture.mux.enforce_remote_limits(), Err(POISONED_REVOCATION));
    assert!(!fixture.mux.control_clients.is_remote(one));
}
