//! `chief.profile.adopt` on the request path every connection takes
//! (`handle_connection_message`: the origin gate, then the Chief registry):
//! only the owner's own Unix connection adopts. The person's page WebSocket,
//! the host's page relay (even with the person's gesture), a paired device and
//! a bound agent are refused with `origin.forbidden`, and nothing is written.

use serde_json::{Value, json};

use crate::request_origin::params_sha256;
use crate::server::origin_gate::{
    set_page, set_peer_key_for_test, set_role_for_test, set_scoped_page, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<Mux>, transport: ClientTransport) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

fn send(mux: &Arc<Mux>, conn: &Conn, request: &Value) -> Value {
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let message = conn.outbound.try_pop().expect("a synchronous reply");
    serde_json::from_str(&message).unwrap()
}

/// A v1 command on `conn`'s client (its data).
fn command(mux: &Arc<Mux>, conn: &Conn, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    handle_command(mux, conn.client, command, &conn.writer).unwrap()
}

fn params(fields: Value) -> Value {
    let mut params = json!({"machine": "current", "session": "current"});
    for (key, value) in fields.as_object().unwrap() {
        params[key] = value.clone();
    }
    params
}

fn v2(operation: &str, params: &Value, key: Option<&str>, origin: Option<Value>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

fn forbidden(reply: &Value) -> String {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default().to_owned()
}

fn chief_ids(mux: &Arc<Mux>, owner: &Conn) -> Vec<String> {
    let listed = send(mux, owner, &v2("chief.profile.list", &params(json!({})), None, None));
    assert_eq!(listed["ok"], true, "{listed}");
    listed["result"]["chiefs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn only_the_owners_own_unix_connection_adopts_an_agent() {
    let mux = Mux::new_for_test("chief-adopt-callers".to_owned(), crate::SurfaceOptions::default());
    let owner = connect(&mux, ClientTransport::Unix);
    let created = command(
        &mux,
        &owner,
        json!({"cmd": "conversation-create", "idempotency_key": "dm-release", "actor": "user_local",
                "title": "Release Chief", "participants": [
                    {"id": "user_local", "kind": "human", "display_name": "Me"},
                    {"id": "agent_release", "kind": "agent", "display_name": "Release Chief",
                     "agent_class": "mux", "acp_session": "release"}]}),
    );
    assert!(created["conversation"]["id"].is_string(), "{created}");
    let adopt = params(json!({"participant_id": "agent_release", "role": "Release trains"}));

    // The person's page WebSocket (the Channels page, page-bound credential).
    let page = connect(&mux, ClientTransport::WebSocket);
    set_scoped_page(&mux, page.client, "home-channels".to_owned());
    let reason =
        forbidden(&send(&mux, &page, &v2("chief.profile.adopt", &adopt, Some("p1"), None)));
    assert!(matches!(reason.as_str(), "page_not_allowed" | "chief_adopt_owner_only"), "{reason}");
    // The daemon's own credential on a WebSocket with no page: still a page path.
    let socket = connect(&mux, ClientTransport::WebSocket);
    assert_eq!(
        forbidden(&send(&mux, &socket, &v2("chief.profile.adopt", &adopt, Some("w1"), None))),
        "chief_adopt_owner_only"
    );

    // The host's page relay, even with the person's gesture for exactly this request.
    let app = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, app.client, "main");
    set_peer_key_for_test(&mux, app.client, "token:20.1");
    set_verified_app_for_test(&mux, app.client, true);
    let relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, relay.client, "page_relay");
    set_peer_key_for_test(&mux, relay.client, "token:20.1");
    set_page(&mux, relay.client, "home-channels".to_owned());
    let issued = send(
        &mux,
        &app,
        &v2(
            "origin.confirmation.issue",
            &json!({"machine": "current", "session": "current", "operation": "chief.profile.adopt",
                    "params_sha256": params_sha256(&adopt),
                    "relay_connection_id": relay.client.to_string()}),
            None,
            None,
        ),
    );
    let gesture = issued["result"]["token"]
        .as_str()
        .map(|token| json!({"claim": "user", "confirmation": token}));
    let relayed = send(&mux, &relay, &v2("chief.profile.adopt", &adopt, Some("r1"), gesture));
    assert_eq!(relayed["error"]["code"], "origin.forbidden", "{relayed}");

    // A paired device (a pairing-store credential).
    let paired = connect(&mux, ClientTransport::WebSocket);
    mux.control_clients.mark_person(paired.client);
    assert_eq!(
        forbidden(&send(&mux, &paired, &v2("chief.profile.adopt", &adopt, Some("d1"), None))),
        "chief_registry_caller"
    );

    // A bound agent on a Unix connection: the agent itself, and a live Chief.
    let token = command(
        &mux,
        &owner,
        json!({"cmd": "conversation-agent-token", "participant": "agent_release"}),
    )["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let agent = connect(&mux, ClientTransport::Unix);
    command(
        &mux,
        &agent,
        json!({"cmd": "conversation-bind", "participant": "agent_release", "token": token}),
    );
    assert_eq!(
        forbidden(&send(&mux, &agent, &v2("chief.profile.adopt", &adopt, Some("a1"), None))),
        "chief_registry_caller"
    );

    // Nothing was written by any of them.
    assert_eq!(chief_ids(&mux, &owner), vec!["agent_mux".to_owned()]);

    // The agent's session is still bound: two processes never speak as one
    // participant, so the adopt waits until that session is gone.
    let bound = send(&mux, &owner, &v2("chief.profile.adopt", &adopt, Some("o0"), None));
    assert_eq!(bound["error"]["code"], "operation.failed", "{bound}");
    assert_eq!(bound["error"]["details"]["reason"], "participant_bound", "{bound}");
    assert_eq!(chief_ids(&mux, &owner), vec!["agent_mux".to_owned()]);
    mux.unbind_conversation_participant("agent_release");

    // The owner's own terminal adopts it.
    let adopted = send(&mux, &owner, &v2("chief.profile.adopt", &adopt, Some("o1"), None));
    assert_eq!(adopted["ok"], true, "{adopted}");
    assert_eq!(adopted["result"]["value"]["id"], "agent_release");
    assert_eq!(chief_ids(&mux, &owner), vec!["agent_mux".to_owned(), "agent_release".to_owned()]);

    // The credential issued before the adopt is revoked: the old session cannot come back.
    let old = connect(&mux, ClientTransport::Unix);
    let command_result = |conn: &Conn, request: Value| {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&mux, conn.client, command, &conn.writer)
    };
    assert!(
        command_result(
            &old,
            json!({"cmd": "conversation-bind", "participant": "agent_release", "token": token})
        )
        .is_err(),
        "a pre-adopt credential bound"
    );

    // With no brain supervisor, only the person's own terminal mints the
    // adopted Chief's new credential: never a page relay, a WebSocket page, a
    // paired or remote device, or an agent.
    let mint = json!({"cmd": "conversation-agent-token", "participant": "agent_release"});
    let relay_mint = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, relay_mint.client, "page_relay");
    set_page(&mux, relay_mint.client, "home-channels".to_owned());
    let page_mint = connect(&mux, ClientTransport::WebSocket);
    set_scoped_page(&mux, page_mint.client, "home-channels".to_owned());
    let device_mint = connect(&mux, ClientTransport::Remote);
    let paired_mint = connect(&mux, ClientTransport::WebSocket);
    mux.control_clients.mark_person(paired_mint.client);
    let other_token = command(
        &mux,
        &owner,
        json!({"cmd": "conversation-create", "idempotency_key": "dm-helper", "actor": "user_local",
               "title": "Helper", "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Me"},
                   {"id": "agent_helper", "kind": "agent", "display_name": "Helper",
                    "agent_class": "mux"}]}),
    );
    assert!(other_token["conversation"]["id"].is_string());
    let helper_token = command(
        &mux,
        &owner,
        json!({"cmd": "conversation-agent-token", "participant": "agent_helper"}),
    )["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let agent_mint = connect(&mux, ClientTransport::Unix);
    command(
        &mux,
        &agent_mint,
        json!({"cmd": "conversation-bind", "participant": "agent_helper", "token": helper_token}),
    );
    for (who, conn) in [
        ("page relay", &relay_mint),
        ("page websocket", &page_mint),
        ("remote device", &device_mint),
        ("paired device", &paired_mint),
        ("agent", &agent_mint),
    ] {
        assert!(command_result(conn, mint.clone()).is_err(), "{who} minted a Chief credential");
    }
    let fresh = command(&mux, &owner, mint)["token"].as_str().unwrap().to_owned();
    let chief = connect(&mux, ClientTransport::Unix);
    let bound = command(
        &mux,
        &chief,
        json!({"cmd": "conversation-bind", "participant": "agent_release", "token": fresh}),
    );
    assert_eq!(bound["participant"], "agent_release", "{bound}");
}
