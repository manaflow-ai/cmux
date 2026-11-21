//! The carrier role stamp binds a unix connection's signed role once; the
//! person's own frames after it cannot replace or raise it.
use super::super::*;
use crate::server::AgentStartHost;
use crate::server::agent_session_attach::Refusal;
use cmux_link::token::VmKind;

fn writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

fn mux() -> Arc<Mux> {
    let mux = Mux::new_for_test("carrier-role", crate::SurfaceOptions::default());
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    mux
}

/// One line through the connection's own frame path; its reply.
fn send(mux: &Arc<Mux>, client: u64, line: &str) -> Value {
    let (writer, outbound) = writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let transport = mux.control_clients.transport_of(client).unwrap();
    handle_connection_frame(mux, client, transport, line, &writer, &scheduler);
    serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap()
}

fn role(mux: &Mux, client: u64) -> Option<Option<VmKind>> {
    mux.control_clients.state.lock().unwrap().clients.get(&client).unwrap().native_vm_kind
}

#[test]
fn a_stamped_team_or_roleless_stream_cannot_start_on_the_callers_owner_word() {
    for (stamped, expected) in [
        (Some(VmKind::Owner), Ok(())),
        (Some(VmKind::Team), Err(Refusal::TeamVmBlocked)),
        (None, Err(Refusal::HostUnverified)),
    ] {
        let mux = mux();
        let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
        let reply = send(&mux, client, &cmux_link::carrier_role::line(stamped));
        assert_eq!(reply["ok"], json!(true), "{stamped:?}: {reply}");
        assert_eq!(reply["id"], json!(cmux_link::carrier_role::REQUEST_ID));
        assert_eq!(role(&mux, client), Some(stamped));
        // The caller's owner word never raises a signed team or missing role.
        assert_eq!(mux.agent_host_gate(client, Some("owner")), expected, "{stamped:?}");
    }
}

#[test]
fn the_persons_bytes_after_the_stamp_cannot_replace_it() {
    let mux = mux();
    let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
    assert_eq!(
        send(&mux, client, &cmux_link::carrier_role::line(Some(VmKind::Team)))["ok"],
        json!(true)
    );
    for forged in [Some(VmKind::Owner), Some(VmKind::Team), None] {
        let reply = send(&mux, client, &cmux_link::carrier_role::line(forged));
        assert_eq!(reply["ok"], json!(false), "{reply}");
        assert_eq!(reply["error_code"], json!("carrier_role.already_stamped"));
    }
    assert_eq!(role(&mux, client), Some(Some(VmKind::Team)));
    assert_eq!(mux.agent_host_gate(client, Some("owner")), Err(Refusal::TeamVmBlocked));
}

#[test]
fn an_unstamped_local_connection_keeps_the_callers_word() {
    let mux = mux();
    let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
    assert_eq!(role(&mux, client), None);
    assert_eq!(mux.agent_host_gate(client, Some("owner")), Ok(()));
    assert_eq!(mux.agent_host_gate(client, None), Err(Refusal::HostUnverified));
}

#[test]
fn a_malformed_stamp_binds_nothing() {
    let mux = mux();
    let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
    for bad in [
        r#"{"cmd":"carrier-role","id":1}"#,
        r#"{"cmd":"carrier-role","id":1,"vmk":"admin"}"#,
        r#"{"cmd":"carrier-role","id":1,"vmk":"owner","sub":"42"}"#,
    ] {
        let reply = send(&mux, client, bad);
        assert_eq!(reply["error_code"], json!("carrier_role.malformed"), "{bad}: {reply}");
    }
    assert_eq!(role(&mux, client), None);
}

#[test]
fn only_a_unix_connection_takes_a_stamp() {
    let mux = mux();
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer().0);
    let reply = send(&mux, client, &cmux_link::carrier_role::line(Some(VmKind::Owner)));
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(role(&mux, client), None);
}

/// A daemon from before the stamp answers it as an unknown command. That reply
/// lists every command the daemon knows, so the session host's read bound
/// (`cmux_link::carrier_role::MAX_REPLY_BYTES`) must leave room for it.
#[test]
fn an_unknown_commands_reply_fits_the_session_hosts_read_bound() {
    let mux = mux();
    let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
    let (writer, outbound) = writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let line = json!({"cmd":"carrier-role-before-the-stamp",
                      "id":cmux_link::carrier_role::REQUEST_ID,"vmk":"team"})
    .to_string();
    handle_connection_frame(&mux, client, ClientTransport::Unix, &line, &writer, &scheduler);
    let reply = outbound.try_pop().expect("a reply");
    let parsed: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(parsed["ok"], json!(false), "{parsed}");
    assert_eq!(parsed["id"], json!(cmux_link::carrier_role::REQUEST_ID), "{parsed}");
    assert!(reply.len() > 4096, "the reply lists the known commands: {}", reply.len());
    assert!(reply.len() * 8 < cmux_link::carrier_role::MAX_REPLY_BYTES, "{}", reply.len());
}
