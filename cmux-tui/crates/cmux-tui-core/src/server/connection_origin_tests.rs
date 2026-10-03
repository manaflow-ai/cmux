use super::super::*;
use super::*;

/// Send one line as `client` through the normal per-line router and return
/// the first reply line that carries `id`.
fn line(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    outbound: &BoundedOutbound,
    message: &str,
) -> Value {
    let scheduler = Arc::new(ConnectionSurfaceScheduler::new_inner(
        mux.surface_operation_admission.clone(),
        None,
    ));
    assert!(handle_connection_message(mux, client, message, writer, &scheduler));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(line) = outbound.try_pop()
            && let Ok(value) = serde_json::from_str::<Value>(&line)
            && (value.get("ok").is_some() || value["type"] == "response")
        {
            return value;
        }
        assert!(Instant::now() < deadline, "no reply to {message}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn rename(key: &str, workspace: &str, credential: &str) -> String {
    json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("req-{key}"),
        "operation":"workspace.rename",
        "params":{"machine":"current","session":"current","workspace":workspace,"name":key},
        "idempotency_key":key,
        "credential":credential,
    })
    .to_string()
}

#[test]
fn a_bridged_connection_never_presents_a_launch_credential() {
    let mux = Mux::new_for_test("connection-origin", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    let workspace =
        crate::resource_api::public_session_snapshot(&mux).unwrap()["workspaces"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();

    // The bridge's own line 1: recorded and acknowledged with the reply the
    // bridge accepts.
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let bridged = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert!(mux.control_clients.is_local_principal(bridged));
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let ack = line(&mux, bridged, &writer, &outbound, &mark);
    assert_eq!(remote_bridge_mark_reply(&ack.to_string()), RemoteBridgeMarkReply::Accepted);
    assert!(!mux.control_clients.is_local_principal(bridged));
    // The transport is still Unix for every other gate.
    assert!(mux.control_clients.is_unix(bridged));

    // A peer's credential through the bridge is refused before any write.
    let reply = line(&mux, bridged, &writer, &outbound, &rename("peer", &workspace, &credential));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["details"]["field"], "credential");
    assert_eq!(reply["error"]["details"]["reason"], "credential_not_local");

    // Nothing the peer sends clears the mark: a second mark keeps it.
    let _ = line(&mux, bridged, &writer, &outbound, &mark);
    assert!(!mux.control_clients.is_local_principal(bridged));
    disconnect_client(&mux, bridged, false);

    // The same credential from an unmarked local connection still works.
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let local = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let reply = line(&mux, local, &writer, &outbound, &rename("local", &workspace, &credential));
    assert_eq!(reply["ok"], true, "{reply}");
    disconnect_client(&mux, local, false);
    mux.shutdown();
}

#[test]
fn the_bridge_reads_each_reply_kind() {
    assert_eq!(
        remote_bridge_mark_reply(r#"{"id":0,"ok":true,"data":{"origin":"remote_bridge"}}"#),
        RemoteBridgeMarkReply::Accepted
    );
    // The reply of a daemon from before the mark (serde's unknown variant).
    assert_eq!(
        remote_bridge_mark_reply(
            r#"{"id":0,"ok":false,"error":"bad request: unknown variant `connection-origin`, expected one of `identify`"}"#
        ),
        RemoteBridgeMarkReply::UnknownToDaemon
    );
    // The real pre-mark path: the v1 parser does not know the command, and
    // `send_bad_request` reports it with this text.
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let error = serde_json::from_str::<Request>(&mark).err().expect("v1 does not parse the mark");
    let old_reply = json!({"id":0,"ok":false,"error":format!("bad request: {error}")}).to_string();
    assert_eq!(remote_bridge_mark_reply(&old_reply), RemoteBridgeMarkReply::UnknownToDaemon);
    for refused in [
        r#"{"id":0,"ok":false,"error":"daemon shutdown is in progress; request was not executed"}"#,
        r#"{"id":1,"ok":true,"data":{"origin":"remote_bridge"}}"#,
        r#"{"id":0,"ok":true,"data":{"origin":"local"}}"#,
        "not json",
        "",
    ] {
        assert_eq!(remote_bridge_mark_reply(refused), RemoteBridgeMarkReply::Refused, "{refused}");
    }
    assert!(is_remote_bridge_mark(&String::from_utf8(remote_bridge_mark_line()).unwrap()));
    assert!(!is_remote_bridge_mark(r#"{"id":0,"cmd":"connection-origin","origin":"local"}"#));
}
