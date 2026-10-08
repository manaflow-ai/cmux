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

/// A close runs as an effect from its stored receipt, so the actor is
/// stored with the receipt and survives a daemon restart.
#[test]
fn a_close_records_the_actor_of_its_connection() {
    let mux = mux("actor-close");
    let plain = connect(&mux);
    let created = send(&mux, &plain, &create("close-create"));
    let workspace = created["result"]["value"]["workspace_id"].clone();
    assert!(workspace.is_string(), "{created}");
    let close = v2(
        "workspace.close",
        json!({"machine": "current", "session": "current", "workspace": workspace}),
        Some("close-it"),
        None,
    );
    let closed = send(&mux, &plain, &close);
    assert_eq!(closed["ok"], true, "{closed}");
    // A close is recorded by its effect receipt, not in resource_mutations.
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM resource_effect_receipts WHERE idempotency_key = 'close-it'";
    let actor = registry.connection.query_row(sql, [], |row| row.get::<_, String>(0));
    assert_eq!(actor.ok().as_deref(), Some("user:user_local"));
}

#[test]
fn a_link_peer_is_its_install_and_a_bare_remote_connection_is_remote() {
    let mux = mux("actor-link");
    mux.record_remote_check("inst_7").unwrap();
    let linked = connect(&mux);
    let peer = crate::remote_relay_state::LinkPeer {
        install: "inst_7".into(),
        user: "user_7".into(),
        team: "team_7".into(),
    };
    mux.bind_remote_peer(linked.client, &peer).unwrap();
    assert_eq!(origin_gate::connection_actor(&mux, linked.client).wire(), "peer:link:inst_7");
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let bare = mux.control_clients.register(ClientTransport::Remote, writer);
    assert_eq!(origin_gate::connection_actor(&mux, bare).wire(), "peer:remote");
}

/// A creation that makes a terminal reserves the workspace and terminal in
/// its stored intent; the rows it commits are the caller's, never the daemon's.
#[test]
fn rows_a_creation_reserves_are_the_callers() {
    let mux = mux("actor-reservation");
    let plain = connect(&mux);
    let params = json!({"machine": "current", "session": "current", "initial_content": "terminal"});
    let created = send(&mux, &plain, &v2("workspace.create", params, Some("reserve-1"), None));
    assert_eq!(created["ok"], true, "{created}");
    let registry = mux.workspace_registry.lock().unwrap();
    let sql =
        "SELECT idempotency_key, actor FROM resource_mutations WHERE actor != 'user:user_local'";
    let mut statement = registry.connection.prepare(sql).unwrap();
    let others = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(others.is_empty(), "rows of this creation with another actor: {others:?}");
}

#[test]
fn a_replayed_close_keeps_the_first_receipt_actor() {
    let mux = mux("actor-receipt-replay");
    let plain = connect(&mux);
    let app = verified_app(&mux, "token:30.1");
    let created = send(&mux, &plain, &create("replay-create"));
    let workspace = created["result"]["value"]["workspace_id"].clone();
    let close = v2(
        "workspace.close",
        json!({"machine": "current", "session": "current", "workspace": workspace}),
        Some("replay-close"),
        None,
    );
    assert_eq!(send(&mux, &plain, &close)["ok"], true);
    let replay = send(&mux, &app, &close);
    assert_eq!(replay["ok"], true, "{replay}");
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM resource_effect_receipts WHERE idempotency_key = 'replay-close'";
    let actor = registry.connection.query_row(sql, [], |row| row.get::<_, String>(0));
    assert_eq!(actor.ok().as_deref(), Some("user:user_local"));
}

/// The actor of the newest effect receipt: a legacy `new-workspace` makes a
/// terminal, so it runs as an effectful creation with a receipt.
fn newest_legacy_actor(mux: &Arc<Mux>) -> Option<String> {
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM resource_effect_receipts ORDER BY rowid DESC LIMIT 1";
    registry.connection.query_row(sql, [], |row| row.get::<_, String>(0)).ok()
}

/// A legacy line's reply: the dispatcher may answer on another thread.
fn send_legacy(mux: &Arc<Mux>, conn: &Conn, request: &Value) -> Value {
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(message) = conn.outbound.try_pop() {
            let reply: Value = serde_json::from_str(&message).unwrap();
            if reply["id"] == request["id"] {
                return reply;
            }
            continue;
        }
        assert!(std::time::Instant::now() < deadline, "no reply to {request}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

/// Legacy control commands (`new-workspace`, `rename-workspace`, `close-surface`
/// and the other topology ops) record the actor of their connection, never
/// the daemon (P8 landing 3a).
#[test]
fn a_legacy_topology_command_records_its_connection_actor() {
    let mux = mux("actor-legacy");
    let plain = connect(&mux);
    let reply = send_legacy(&mux, &plain, &json!({"id": 1, "cmd": "new-workspace", "name": "a"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(newest_legacy_actor(&mux).as_deref(), Some("user:user_local"));
    let websocket = connect_websocket(&mux);
    let reply = send_legacy(&mux, &websocket, &json!({"id": 2, "cmd": "new-workspace", "name": "b"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(newest_legacy_actor(&mux).as_deref(), Some("peer:websocket"));
}
