//! Machine snapshot delivery and metadata negotiation over the actual control transport.

use super::tests::{
    TestSocket, accept_hello_with_capabilities, client_descriptor, id, read_test_frame, token,
    write_test_frame,
};
use super::*;
use cmux_tui_machine_protocol::{
    MachineDescriptor, MachinePlatform, MachineStatus, ProviderCapabilities, WorkspaceCreatePolicy,
};
use std::thread;

/// The peer deliberately sends metadata even without negotiation. The client must
/// preserve only the contract accepted on this exact control connection.
fn read_metadata_from_peer(negotiate: Option<bool>) -> (Vec<String>, SnapshotResult) {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (offered_tx, offered_rx) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let capabilities = if negotiate.is_some() {
            vec![CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY]
        } else {
            Vec::new()
        };
        accept_hello_with_capabilities(&mut stream, &mut reader, "provider-secret", &capabilities);
        let mut offered = Vec::new();
        if let Some(accept) = negotiate {
            let request: RequestEnvelope = read_test_frame(&mut reader);
            let ProviderRequest::NegotiateClientCapabilities(params) = request.request else {
                panic!("expected negotiation")
            };
            offered = params.capabilities;
            let accepted = offered
                .iter()
                .filter(|capability| accept && capability.as_str() == "machine-metadata-v1")
                .cloned()
                .collect();
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(
                    request.id,
                    NegotiateClientCapabilitiesResult { capabilities: accepted },
                ),
            );
        }
        offered_tx.send(offered).unwrap();
        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
        let snapshot = SnapshotResult {
            revision: 1,
            scopes: Vec::new(),
            selected_scope_id: id("personal"),
            selected_machine_id: None,
            machines: vec![MachineDescriptor {
                id: id("server-1"),
                display_name: "Server".into(),
                subtitle: String::new(),
                status: MachineStatus::Running,
                connectable: true,
                workspace_create: WorkspaceCreatePolicy::Session,
                platform: Some(MachinePlatform {
                    os: Some("linux".into()),
                    arch: Some("aarch64".into()),
                }),
                capabilities: vec!["terminal".into()],
            }],
            capabilities: ProviderCapabilities {
                create_machine: false,
                connect_external_machine: false,
            },
            actions: Vec::new(),
            notice: None,
        };
        write_test_frame(&mut stream, &ResponseEnvelope::success(request.id, snapshot));
        finished.recv().unwrap();
    });
    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .unwrap();
    let result = provider.snapshot(None);
    let offered = offered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    finish.send(()).unwrap();
    drop(provider);
    server.join().unwrap();
    (offered, result.unwrap())
}

#[test]
fn cmux_next_machine_metadata_client_offers_and_retains_the_negotiated_fields() {
    let (offered, snapshot) = read_metadata_from_peer(Some(true));
    assert!(offered.iter().any(|value| value == "machine-metadata-v1"));
    assert_eq!(snapshot.machines[0].platform.as_ref().unwrap().os.as_deref(), Some("linux"));
    assert_eq!(snapshot.machines[0].capabilities, ["terminal"]);
}

#[test]
fn cmux_next_machine_metadata_client_keeps_unsolicited_legacy_metadata_unknown() {
    let (offered, snapshot) = read_metadata_from_peer(None);
    assert!(offered.is_empty());
    assert!(snapshot.machines[0].platform.is_none());
    assert!(snapshot.machines[0].capabilities.is_empty());
}

#[test]
fn cmux_next_machine_metadata_client_keeps_declined_metadata_unknown() {
    let (_, snapshot) = read_metadata_from_peer(Some(false));
    assert!(snapshot.machines[0].platform.is_none());
    assert!(snapshot.machines[0].capabilities.is_empty());
}

#[test]
fn a_full_snapshot_queue_coalesces_without_unsubscribing() {
    let socket = TestSocket::bind();
    let provider = ProviderClient::connect(&socket.path).expect("connect provider client");
    let (sender, receiver) = mpsc::sync_channel(1);
    provider.inner.snapshot_subscribers.lock().unwrap().push(sender);

    provider.inner.publish_snapshot_revision(1);
    provider.inner.publish_snapshot_revision(2);
    assert_eq!(receiver.recv().unwrap(), 1);

    provider.inner.publish_snapshot_revision(3);
    assert_eq!(receiver.recv().unwrap(), 3);
    assert_eq!(provider.inner.snapshot_subscribers.lock().unwrap().len(), 1);
}
