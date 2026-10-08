//! P8 slice 3 (plans/cmux-next/identity.md section 3): the daemon stamps
//! every durable v2 mutation with the actor of its connection, and a caller
//! can never set or change it.

use super::*;

fn create(key: &str) -> Value {
    v2(
        "workspace.create",
        json!({"machine": "current", "session": "current", "initial_content": "empty"}),
        Some(key),
        None,
    )
}

/// The `resource_mutations.actor` of `key`, read from the session store.
fn stored_actor(mux: &Arc<Mux>, key: &str) -> Option<String> {
    mux.workspace_registry.lock().unwrap().resource_mutation_actor_for_test(key).unwrap()
}

fn mutation_count(mux: &Arc<Mux>) -> u64 {
    mux.workspace_registry.lock().unwrap().resource_mutation_count_for_test().unwrap()
}

#[test]
fn a_mutation_records_the_actor_of_its_connection() {
    let mux = mux("actor-connection");
    let plain = connect(&mux);
    let app = verified_app(&mux, "token:20.1");
    assert_eq!(send(&mux, &plain, &create("actor-plain"))["ok"], true);
    assert_eq!(send(&mux, &app, &create("actor-app"))["ok"], true);
    assert_eq!(stored_actor(&mux, "actor-plain").as_deref(), Some("user:user_local"));
    assert_eq!(stored_actor(&mux, "actor-app").as_deref(), Some("frontend:signed_app"));
    // A page relay is never the frontend.
    let relay = relay(&mux, "token:20.1");
    let reply = send(&mux, &relay, &create("actor-relay"));
    assert_eq!(stored_actor(&mux, "actor-relay"), None, "a page relay mutation committed: {reply}");
}

#[test]
fn a_caller_cannot_forge_the_actor() {
    let mux = mux("actor-forged");
    let plain = connect(&mux);
    let before = mutation_count(&mux);
    let forged = json!({"kind": "frontend", "id": "inst_forged"});
    // An `actor` envelope member.
    let mut envelope = create("forged-envelope");
    envelope["actor"] = forged.clone();
    let reply = send(&mux, &plain, &envelope);
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
    // An `actor` param.
    let mut params = create("forged-param");
    params["params"]["actor"] = forged;
    let reply = send(&mux, &plain, &params);
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
    // An origin claim cannot raise a plain connection to the user's app.
    let mut claimed = create("forged-claim");
    claimed["origin"] = json!({"claim": "user"});
    assert_forbidden(&send(&mux, &plain, &claimed));
    assert_eq!(mutation_count(&mux), before, "a forged request committed");
    // The same connection without the forgery is the local user.
    assert_eq!(send(&mux, &plain, &create("honest"))["ok"], true);
    assert_eq!(stored_actor(&mux, "honest").as_deref(), Some("user:user_local"));
}

#[test]
fn a_replay_keeps_the_first_actor() {
    let mux = mux("actor-replay");
    let app = verified_app(&mux, "token:21.1");
    let plain = connect(&mux);
    let first = send(&mux, &app, &create("replayed"));
    assert_eq!(first["ok"], true, "{first}");
    let replay = send(&mux, &plain, &create("replayed"));
    assert_eq!(replay["ok"], true, "{replay}");
    assert_eq!(stored_actor(&mux, "replayed").as_deref(), Some("frontend:signed_app"));
}

/// A WebSocket connection (another machine: token or pairing auth).
fn connect_websocket(mux: &Arc<Mux>) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

#[test]
fn a_websocket_connection_is_a_peer_never_the_local_user() {
    let mux = mux("actor-websocket");
    let websocket = connect_websocket(&mux);
    let reply = send(&mux, &websocket, &create("actor-websocket"));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(stored_actor(&mux, "actor-websocket").as_deref(), Some("peer:websocket"));
    let actor = origin_gate::connection_actor(&mux, websocket.client);
    assert_eq!(actor.wire(), "peer:websocket");
}

#[test]
fn a_connection_with_no_record_is_never_the_local_user() {
    let mux = mux("actor-unregistered");
    let gone = connect(&mux);
    assert!(mux.control_clients.remove(gone.client).is_some());
    let actor = origin_gate::connection_actor(&mux, gone.client);
    assert_eq!(actor.wire(), "peer:unregistered");
}
