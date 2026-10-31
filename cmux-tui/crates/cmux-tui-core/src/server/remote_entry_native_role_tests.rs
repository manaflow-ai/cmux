//! Native ownership is authenticated per connection, never supplied by a frame.
use super::*;
use crate::server::agent_session_attach::Refusal;
use crate::server::agent_session_start::AgentStartHost;
use cmux_link::stamp::{LinkPeer, StampCheck};
use cmux_link::token::VmKind;

fn native_stamp(role: Option<VmKind>) -> String {
    let issued_at_ms =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    cmux_link::stamp::encode(
        &LinkPeer { install: "inst_1".into(), user: "42".into(), team: "team_a".into() },
        Some(StampCheck::NativeLinkToken { issued_at_ms, vm_kind: role }),
    )
    .unwrap()
}

#[test]
fn native_stamp_binds_role_and_request_owner_cannot_elevate_it() {
    for role in [None, Some(VmKind::Team), Some(VmKind::Owner)] {
        let entry = entry_with(true, Arc::new(AdmitAll), Some(true));
        entry
            .mux
            .control_clients
            .agent_sessions
            .starts
            .set_host(Arc::new(|| AgentStartHost::OwnerCloud));
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &native_stamp(role));
        // Even a frame claiming a different identity/role cannot replace the
        // role the private entry bound before the connection's first frame.
        send(
            &mut stream,
            r#"{"id":1,"cmd":"set-client-info","vm_kind":"owner","native_vm_kind":"owner","identity":{"vm_kind":"owner"}}"#,
        );
        let _ = response(&mut reader);
        let clients = remote_clients(&entry.mux);
        assert_eq!(clients.len(), 1);
        let client = *clients.first().unwrap();
        let expected = match role {
            Some(VmKind::Owner) => Ok(()),
            Some(VmKind::Team) => Err(Refusal::TeamVmBlocked),
            None => Err(Refusal::HostUnverified),
        };
        assert_eq!(entry.mux.agent_host_gate(client, Some("owner")), expected);
        assert_eq!(entry.mux.agent_host_gate(client, None), expected);
        assert_eq!(
            entry
                .mux
                .control_clients
                .state
                .lock()
                .unwrap()
                .clients
                .get(&client)
                .unwrap()
                .native_vm_kind,
            Some(role),
        );
        // Removing guest-local Cloud markers cannot promote a signed team or
        // missing-role token either. A real signed owner still needs a host
        // that permits ownership; team-host evidence always wins.
        entry
            .mux
            .control_clients
            .agent_sessions
            .starts
            .set_host(Arc::new(|| AgentStartHost::Allowed));
        assert_eq!(entry.mux.agent_host_gate(client, Some("owner")), expected);
        entry
            .mux
            .control_clients
            .agent_sessions
            .starts
            .set_host(Arc::new(|| AgentStartHost::TeamVm));
        assert!(entry.mux.agent_host_gate(client, Some("owner")).is_err());
    }
}

#[test]
fn native_stamp_without_a_configured_verifier_cannot_bind() {
    let entry = entry(true, Arc::new(AdmitAll));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert!(closed(&mut reader));
    assert!(remote_clients(&entry.mux).is_empty());
}

#[test]
fn legacy_entry_and_local_connections_keep_the_existing_host_gate() {
    let entry = entry(true, Arc::new(DenyAllGate));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, STAMP);
    send(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(response(&mut reader)["error_code"], json!(REMOTE_DENIED));
    let legacy = *remote_clients(&entry.mux).first().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let local = entry.mux.control_clients.register(ClientTransport::Unix, writer);
    for client in [local, legacy] {
        entry
            .mux
            .control_clients
            .agent_sessions
            .starts
            .set_host(Arc::new(|| AgentStartHost::Allowed));
        assert_eq!(entry.mux.agent_host_gate(client, None), Ok(()));
        assert_eq!(entry.mux.agent_host_gate(client, Some("team")), Err(Refusal::HostUnverified));
        entry
            .mux
            .control_clients
            .agent_sessions
            .starts
            .set_host(Arc::new(|| AgentStartHost::OwnerCloud));
        assert_eq!(entry.mux.agent_host_gate(client, None), Err(Refusal::HostUnverified));
        assert_eq!(entry.mux.agent_host_gate(client, Some("owner")), Ok(()));
    }
    assert_eq!(entry.mux.agent_host_gate(u64::MAX, Some("owner")), Err(Refusal::HostUnverified));
}
