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

/// A peer that reaches the session through a remote bridge must not decide
/// who else may pair (identity.md section 3, the remote bridge rule).
#[test]
fn a_bridged_connection_cannot_see_or_decide_pairing_requests() {
    let mux = Mux::new_for_test("connection-origin-pairing", crate::SurfaceOptions::default());
    let (challenge, _decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let pairing = format!("pairing_{:032x}", challenge.id);
    let list = json!({
        "protocol":"cmux.protocol/2","type":"request","id":"list","operation":"pairing_request.list",
        "params":{"machine":"current","session":"current"},
    })
    .to_string();
    let resolve = json!({
        "protocol":"cmux.protocol/2","type":"request","id":"resolve",
        "operation":"pairing_request.resolve",
        "params":{"machine":"current","session":"current","pairing_request":pairing,"decision":"accept"},
        "idempotency_key":"resolve-bridged",
    })
    .to_string();
    let respond =
        json!({"id":7,"cmd":"pairing-response","request":challenge.id,"approve":true}).to_string();

    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let bridged = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let _ = line(&mux, bridged, &writer, &outbound, &mark);
    for request in [&list, &resolve, &respond] {
        let reply = line(&mux, bridged, &writer, &outbound, request);
        assert_eq!(reply["ok"], false, "{request} -> {reply}");
    }
    disconnect_client(&mux, bridged, false);

    // The request is still pending, and a local connection still sees it.
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let local = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let reply = line(&mux, local, &writer, &outbound, &list);
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(reply.to_string().contains(&pairing), "{reply}");
    disconnect_client(&mux, local, false);
    mux.shutdown();
}

/// A pending handoff must not make the session answer the mark like a
/// daemon from before the mark (the bridge would then go on unmarked), and a
/// bridged connection must not start a handoff at all.
#[test]
fn the_mark_holds_during_a_pending_handoff_and_a_bridge_cannot_start_one() {
    let mux = Mux::new_for_test("connection-origin-handoff", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let bridged = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let _ = line(&mux, bridged, &writer, &outbound, &mark);
    assert!(mux.begin_daemon_handoff(bridged, DaemonHandoffRequest::unfenced(false)).is_err());

    // A bridge connection registered just before a local requester starts a
    // handoff sends its mark while the handoff is pending: still marked.
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let late = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer_for_origin());
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
    assert!(mux.daemon_handoff_in_progress());
    let reply = line(&mux, late, &writer, &outbound, &mark);
    assert_eq!(remote_bridge_mark_reply(&reply.to_string()), RemoteBridgeMarkReply::Accepted);
    assert!(!mux.control_clients.is_local_principal(late));
    // Cancelling the handoff does not clear the mark.
    mux.cancel_daemon_handoff(requester);
    assert!(!mux.control_clients.is_local_principal(late));
    mux.shutdown();
}

fn test_writer_for_origin() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

/// A bridged peer gets the remote journal view: metadata only, like any
/// other remote client (decision 1 of the 3b-1 review).
#[test]
fn a_bridged_connection_gets_the_redacted_journal() {
    let mux = Mux::new_for_test("connection-origin-journal", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let bridged = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let _ = line(&mux, bridged, &writer, &outbound, &mark);
    let message = json!({
        "protocol":"cmux.protocol/2","type":"request","id":"journal-bridged",
        "operation":"session.journal.subscribe",
        "params":{
            "machine":"current","session":"current",
            "stream_id":"stream_44444444444444448444444444444444",
            "start":"beginning",
            "filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"},
        },
    });
    let request = crate::resource_router::parse_resource_request(&message.to_string()).unwrap();
    let refused = prepare_session_journal_stream(&mux, bridged, &writer, &request)
        .err()
        .expect("a bridged peer cannot ask for the sensitive journal");
    assert!(format!("{refused:?}").contains("metadata"), "{refused:?}");
    mux.shutdown();
}

/// A bridged peer can neither find nor replace the browser provider, so it
/// cannot intercept browser automation (decision 2 of the 3b-1 review).
#[test]
fn a_bridged_connection_cannot_touch_the_browser_provider() {
    let mux = Mux::new_for_test("connection-origin-browser", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let bridged = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mark = String::from_utf8(remote_bridge_mark_line()).unwrap();
    let _ = line(&mux, bridged, &writer, &outbound, &mark);
    let get = json!({"id":3,"cmd":"get-browser-provider"}).to_string();
    let unregister = json!({"id":4,"cmd":"unregister-browser-provider"}).to_string();
    for request in [&get, &unregister] {
        let reply = line(&mux, bridged, &writer, &outbound, request);
        assert_eq!(reply["ok"], false, "{request} -> {reply}");
    }
    disconnect_client(&mux, bridged, false);

    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let local = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let reply = line(&mux, local, &writer, &outbound, &get);
    assert_eq!(reply["ok"], true, "{reply}");
    disconnect_client(&mux, local, false);
    mux.shutdown();
}
