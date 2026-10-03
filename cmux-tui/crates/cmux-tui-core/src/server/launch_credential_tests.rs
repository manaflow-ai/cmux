//! Wire tests for the actor stamp (plans/cmux-next/identity.md section 3):
//! the dispatcher reads `credential` from the request envelope, refuses a bad
//! one before any owner runs, and accepts it only on the local socket.

use super::*;

fn send(mux: &Arc<Mux>, transport: ClientTransport, envelope: Value) -> Value {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    handle_resource_connection_message(mux, client, &envelope.to_string(), &writer);
    let deadline = Instant::now() + Duration::from_secs(10);
    let reply = loop {
        if let Some(line) = outbound.try_pop()
            && let Ok(value) = serde_json::from_str::<Value>(&line)
            && value["type"] == "response"
        {
            break value;
        }
        assert!(Instant::now() < deadline, "no response");
        std::thread::sleep(Duration::from_millis(5));
    };
    disconnect_client(mux, client, false);
    reply
}

fn rename(key: &str, workspace: &str, credential: Option<&str>) -> Value {
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("req-{key}"),
        "operation":"workspace.rename",
        "params":{"machine":"current","session":"current","workspace":workspace,"name":key},
        "idempotency_key":key,
    });
    if let Some(credential) = credential {
        envelope["credential"] = json!(credential);
    }
    envelope
}

fn actor_of(mux: &Mux, key: &str) -> Option<String> {
    mux.workspace_registry
        .lock()
        .unwrap()
        .read_state(|connection| {
            Ok(connection.query_row(
                "SELECT actor_json FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get::<_, Option<String>>(0),
            )?)
        })
        .unwrap()
}

#[test]
fn a_terminal_credential_on_the_local_socket_stamps_the_terminal() {
    let mux = Mux::new_for_test("launch-credential-wire", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    let workspace =
        crate::resource_api::public_session_snapshot(&mux).unwrap()["workspaces"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();

    let reply =
        send(&mux, ClientTransport::Unix, rename("by-agent", &workspace, Some(&credential)));
    assert_eq!(reply["ok"], true, "{reply}");
    let actor: cmux_local_auth::Actor =
        serde_json::from_str(&actor_of(&mux, "by-agent").unwrap()).unwrap();
    assert_eq!(actor.kind, cmux_local_auth::ActorKind::Terminal);
    assert_eq!(actor.id, terminal.as_str());

    let reply = send(&mux, ClientTransport::Unix, rename("by-user", &workspace, None));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(actor_of(&mux, "by-user"), Some(cmux_local_auth::Actor::local_user().to_json()));
    mux.shutdown();
}

#[test]
fn a_bad_credential_or_a_remote_one_is_refused_before_any_write() {
    let mux = Mux::new_for_test("launch-credential-refuse", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    let workspace =
        crate::resource_api::public_session_snapshot(&mux).unwrap()["workspaces"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();
    let mut tampered = credential.clone();
    tampered.pop();
    tampered.push(if credential.ends_with('A') { 'B' } else { 'A' });

    let reply = send(&mux, ClientTransport::Unix, rename("tampered", &workspace, Some(&tampered)));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "validation.invalid");
    assert_eq!(reply["error"]["details"]["field"], "credential");
    assert_eq!(actor_of_missing(&mux, "tampered"), None);

    let reply =
        send(&mux, ClientTransport::WebSocket, rename("remote", &workspace, Some(&credential)));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(actor_of_missing(&mux, "remote"), None);
    mux.shutdown();
}

fn actor_of_missing(mux: &Mux, key: &str) -> Option<i64> {
    mux.workspace_registry
        .lock()
        .unwrap()
        .read_state(|connection| {
            use rusqlite::OptionalExtension;
            Ok(connection
                .query_row(
                    "SELECT 1 FROM resource_mutations WHERE idempotency_key = ?1",
                    [key],
                    |row| row.get::<_, i64>(0),
                )
                .optional()?)
        })
        .unwrap()
}
