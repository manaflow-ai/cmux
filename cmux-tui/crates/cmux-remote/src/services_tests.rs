use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use cmux_remote_protocol::{
    ByteString, FrameFlags, ProcessEnvironment, ProcessEvent, ProcessIo, ProcessLifetime,
    ProcessSignal, RpcEvent, WorkspaceId, WorkspaceResponse,
};
use tempfile::tempdir;
#[cfg(unix)]
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::sync::oneshot;
use tokio::sync::{mpsc, watch};

use super::*;
use crate::client::WorkspaceClient;
use crate::crypto::ServiceAuthority;
use crate::service::{ServiceMultiplexer, SessionEndpoint};
use crate::session::ReceivedFrame;

pub(super) struct TestEndpoint {
    outgoing: mpsc::Sender<ReceivedFrame>,
    incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
    sequence: AtomicU64,
    generation: watch::Sender<u64>,
}

#[async_trait]
impl SessionEndpoint for TestEndpoint {
    async fn send_frame(
        &self,
        _expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        self.outgoing
            .send(ReceivedFrame { generation: 0, lane, stream, sequence, flags, payload })
            .await
            .map_err(|_| ServiceError::Closed)?;
        Ok(sequence)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        Ok(self.incoming.lock().await.recv().await)
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    async fn close_session(&self) -> Result<(), ServiceError> {
        Ok(())
    }
}

pub(super) fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
    let (left_tx, left_rx) = mpsc::channel(64);
    let (right_tx, right_rx) = mpsc::channel(64);
    let (left_generation, _) = watch::channel(0);
    let (right_generation, _) = watch::channel(0);
    (
        Arc::new(TestEndpoint {
            outgoing: left_tx,
            incoming: Mutex::new(right_rx),
            sequence: AtomicU64::new(0),
            generation: left_generation,
        }),
        Arc::new(TestEndpoint {
            outgoing: right_tx,
            incoming: Mutex::new(left_rx),
            sequence: AtomicU64::new(0),
            generation: right_generation,
        }),
    )
}

#[test]
fn service_authority_defaults_to_deny_and_legacy_access_is_explicit() {
    let denied = ServiceAuthority::default();
    let legacy = ServiceAuthority::legacy_full();

    for service in [
        Service::MuxControl,
        Service::WorkspaceRpc,
        Service::ProcessStream,
        Service::TerminalBytes,
        Service::TcpTunnel,
        Service::ComputerUse,
    ] {
        assert!(!denied.allows(service), "default authority allowed {service:?}");
        assert!(legacy.allows(service), "legacy authority denied {service:?}");
    }
    // Only an owner's carrier grant reaches a local socket, and only a
    // grant naming acpmux reaches acpmux.
    for service in [Service::LocalSocket, Service::Acpmux] {
        assert!(!denied.allows(service));
        assert!(!legacy.allows(service));
    }
}

#[tokio::test]
async fn service_authority_rejects_a_disallowed_open_before_dispatch() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let stream = client_mux.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();

    let admitted =
        DaemonServices::authorize_service(&ServiceAuthority::none(), incoming).await.unwrap();

    assert!(admitted.is_none(), "a disallowed service reached handler dispatch");
    let response = stream.receive().await.unwrap().unwrap();
    assert_eq!(
        serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
        ServiceControl::Rejected {
            code: "permission-denied".into(),
            message: "the client grant does not allow tcp-tunnel".into(),
        }
    );
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
}

#[cfg(unix)]
async fn open_with_priority(
    requested: bool,
    supports: Option<bool>,
    echoes: bool,
) -> (u32, ServiceControl) {
    let directory = tempdir().unwrap();
    let mux_path = directory.path().join("mux.sock");
    let host_path = directory.path().join("terminal.sock");
    let mux_listener = tokio::net::UnixListener::bind(&mux_path).unwrap();
    let host_listener = tokio::net::UnixListener::bind(&host_path).unwrap();
    let terminal_id = TerminalId::random().unwrap();
    let incarnation = HostIncarnation::random().unwrap();
    let token = CapabilityToken::random().unwrap();
    let token_hex = token.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect::<String>();

    let mux_server = {
        let host_path = host_path.clone();
        let terminal_id = terminal_id.to_hex();
        let incarnation = incarnation.to_hex();
        tokio::spawn(async move {
            let (socket, _) = mux_listener.accept().await.unwrap();
            let mut request = String::new();
            let mut socket = BufReader::new(socket);
            socket.read_line(&mut request).await.unwrap();
            let mut grant = serde_json::json!({
                "endpoint": host_path,
                "terminal_id": terminal_id,
                "incarnation": incarnation,
                "token": token_hex,
                "rights": CapabilityRights::RENDERER.bits(),
            });
            if let Some(supported) = supports {
                grant["supports_viewer_size_priority"] = serde_json::json!(supported);
            }
            let response = serde_json::json!({ "id": 1, "ok": true, "data": grant });
            let mut line = serde_json::to_vec(&response).unwrap();
            line.push(b'\n');
            socket.get_mut().write_all(&line).await.unwrap();
        })
    };
    let host_server = tokio::spawn(async move {
        let (mut socket, _) = host_listener.accept().await.unwrap();
        let hello = read_terminal_frame(&mut socket).await.unwrap();
        assert_eq!(hello.kind, MessageKind::ClientHello);
        let mut response = Frame::new(
            MessageKind::HostHello,
            HostHello {
                selected_version: PROTOCOL_VERSION,
                granted_rights: CapabilityRights::RENDERER,
                terminal_id,
                incarnation,
            }
            .encode(),
        );
        response.request_id = hello.request_id;
        response.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        if echoes {
            response.flags |= FLAG_VIEWER_SIZE_PRIORITY;
        }
        socket.write_all(&encode_frame(&response).unwrap()).await.unwrap();
        hello.flags
    });

    let mut metadata = BTreeMap::from([(
        "terminal".to_string(),
        "term_0123456789abcdef0123456789abcdef".to_string(),
    )]);
    if requested {
        metadata.insert(
            TERMINAL_BYTES_VIEWER_SIZE_PRIORITY.into(),
            TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED.into(),
        );
    }
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let client_stream = client_mux.open(Service::TerminalBytes, metadata).await.unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();
    let handler = tokio::spawn(DaemonServices::serve_terminal_bytes(
        Some(mux_path),
        incoming.stream,
        incoming.metadata,
    ));

    let first = client_stream.receive().await.unwrap().unwrap();
    let control = serde_json::from_slice::<ServiceControl>(&first.payload).unwrap();
    if matches!(control, ServiceControl::Opened { .. }) {
        client_stream.close().await.unwrap();
    }
    mux_server.await.unwrap();
    let hello_flags = host_server.await.unwrap();
    handler.await.unwrap().unwrap();
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
    (hello_flags, control)
}

#[cfg(unix)]
#[tokio::test]
async fn terminal_bytes_viewer_size_priority_flag_follows_request_and_host_support() {
    let renderer = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
    let opened = ServiceControl::Opened { service: Service::TerminalBytes };
    // An old mux omits the grant field; an old host record reports false.
    for (requested, supports, expected) in [
        (true, Some(true), renderer | FLAG_VIEWER_SIZE_PRIORITY),
        (true, Some(false), renderer),
        (true, None, renderer),
        (false, Some(true), renderer),
    ] {
        let echoes = expected & FLAG_VIEWER_SIZE_PRIORITY != 0;
        let (flags, control) = open_with_priority(requested, supports, echoes).await;
        assert_eq!(flags, expected, "{requested} {supports:?}");
        assert_eq!(control, opened, "{requested} {supports:?}");
    }

    let (flags, control) = open_with_priority(true, Some(true), false).await;
    assert_eq!(flags, renderer | FLAG_VIEWER_SIZE_PRIORITY);
    let ServiceControl::Rejected { code, message } = &control else {
        panic!("a missing priority echo opened the stream: {control:?}");
    };
    assert_eq!(code, "terminal-unavailable");
    assert!(message.contains("viewer-size priority"), "{message}");
}

#[cfg(unix)]
#[tokio::test]
async fn terminal_bytes_adapter_mints_smart_grant_and_proxies_cmth_byte_for_byte() {
    let directory = tempdir().unwrap();
    let mux_path = directory.path().join("mux.sock");
    let host_path = directory.path().join("terminal.sock");
    let mux_listener = tokio::net::UnixListener::bind(&mux_path).unwrap();
    let host_listener = tokio::net::UnixListener::bind(&host_path).unwrap();
    let terminal_id = TerminalId::random().unwrap();
    let terminal = "term_0123456789abcdef0123456789abcdef";
    let incarnation = HostIncarnation::random().unwrap();
    let token = CapabilityToken::random().unwrap();
    let token_hex = token.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let proxied = encode_frame(&Frame {
        version: PROTOCOL_VERSION,
        kind: MessageKind::Ready,
        flags: 0,
        request_id: 0,
        sequence: 41,
        payload: b"host-to-renderer".to_vec(),
    })
    .unwrap();
    let upload =
        encode_frame(&Frame::new(MessageKind::Input, b"renderer-to-host".to_vec())).unwrap();

    let mux_server = {
        let host_path = host_path.clone();
        let terminal_id = terminal_id.to_hex();
        let incarnation = incarnation.to_hex();
        tokio::spawn(async move {
            let (socket, _) = mux_listener.accept().await.unwrap();
            let mut request = String::new();
            let mut socket = BufReader::new(socket);
            socket.read_line(&mut request).await.unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["cmd"], "mint-terminal-renderer-by-terminal");
            assert_eq!(request["terminal"], terminal);
            let response = serde_json::json!({
                "id": 1,
                "ok": true,
                "data": {
                    "endpoint": host_path,
                    "terminal_id": terminal_id,
                    "incarnation": incarnation,
                    "token": token_hex,
                    "rights": CapabilityRights::RENDERER.bits(),
                }
            });
            socket
                .get_mut()
                .write_all(serde_json::to_string(&response).unwrap().as_bytes())
                .await
                .unwrap();
            socket.get_mut().write_all(b"\n").await.unwrap();
        })
    };

    let (upload_seen, upload_received) = oneshot::channel();
    let host_server = {
        let proxied = proxied.clone();
        let upload = upload.clone();
        tokio::spawn(async move {
            let (mut socket, _) = host_listener.accept().await.unwrap();
            let hello = read_terminal_frame(&mut socket).await.unwrap();
            assert_eq!(hello.kind, MessageKind::ClientHello);
            assert_eq!(hello.flags, FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS);
            let client = ClientHello::decode(&hello.payload).unwrap();
            assert_eq!(client.terminal_id, terminal_id);
            assert_eq!(client.token, token);
            assert_eq!(client.role, ClientRole::Renderer);
            assert_eq!(client.requested_rights, CapabilityRights::RENDERER);
            assert!(client.requested_rights.contains(CapabilityRights::RESIZE));
            let mut response = Frame::new(
                MessageKind::HostHello,
                HostHello {
                    selected_version: PROTOCOL_VERSION,
                    granted_rights: CapabilityRights::RENDERER,
                    terminal_id,
                    incarnation,
                }
                .encode(),
            );
            response.request_id = hello.request_id;
            response.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
            socket.write_all(&encode_frame(&response).unwrap()).await.unwrap();
            socket.write_all(&proxied).await.unwrap();
            let mut received = vec![0u8; upload.len()];
            socket.read_exact(&mut received).await.unwrap();
            assert_eq!(received, upload);
            let _ = upload_seen.send(());
        })
    };

    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let client_stream = client_mux
        .open(Service::TerminalBytes, BTreeMap::from([("terminal".into(), terminal.into())]))
        .await
        .unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();
    let handler = tokio::spawn(DaemonServices::serve_terminal_bytes(
        Some(mux_path),
        incoming.stream,
        incoming.metadata,
    ));

    let opened = client_stream.receive().await.unwrap().unwrap();
    assert_eq!(opened.lane, Lane::Interactive);
    assert_eq!(
        serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
        ServiceControl::Opened { service: Service::TerminalBytes }
    );
    let mut received = Vec::with_capacity(proxied.len());
    while received.len() < proxied.len() {
        let chunk = client_stream.receive().await.unwrap().unwrap();
        received.extend_from_slice(&chunk.payload);
    }
    assert_eq!(received, proxied);
    client_stream.send(Bytes::from(upload)).await.unwrap();
    upload_received.await.unwrap();
    client_stream.close().await.unwrap();

    mux_server.await.unwrap();
    host_server.await.unwrap();
    handler.await.unwrap().unwrap();
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
}

#[cfg(unix)]
async fn assert_terminal_bytes_open_rejected(
    mux_socket: Option<PathBuf>,
    metadata: BTreeMap<String, String>,
    expected_code: &str,
    expected_message: &str,
) {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let client_stream =
        client.open(Service::TerminalBytes, metadata).await.expect("open terminal byte stream");
    let incoming = daemon
        .accept()
        .await
        .expect("accept terminal byte stream")
        .expect("terminal byte stream was not delivered");
    let handler = tokio::spawn(DaemonServices::serve_terminal_bytes(
        mux_socket,
        incoming.stream,
        incoming.metadata,
    ));

    let response = tokio::time::timeout(std::time::Duration::from_secs(2), client_stream.receive())
        .await
        .expect("terminal byte rejection timed out")
        .expect("terminal byte rejection became a transport error")
        .expect("terminal byte stream closed without a rejection");
    assert_eq!(response.lane, Lane::Control);
    assert_eq!(
        serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
        ServiceControl::Rejected { code: expected_code.into(), message: expected_message.into() }
    );
    handler
        .await
        .expect("terminal byte handler panicked")
        .expect("terminal byte handler returned an error after rejecting the open");
    client.shutdown().await;
    daemon.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn terminal_bytes_pre_open_failures_are_explicitly_rejected() {
    assert_terminal_bytes_open_rejected(
        None,
        BTreeMap::new(),
        "invalid-argument",
        "invalid service metadata: terminal byte stream requires terminal",
    )
    .await;
    assert_terminal_bytes_open_rejected(
        None,
        BTreeMap::from([("terminal".into(), "term_0123456789abcdef0123456789abcdef".into())]),
        "unavailable",
        "mux control socket is not configured",
    )
    .await;
}

async fn assert_process_stream_open_rejected(
    workspace: WorkspaceService,
    scope: ClientScope,
    metadata: BTreeMap<String, String>,
    expected_code: &str,
    expected_message: &str,
) {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let client_stream =
        client.open(Service::ProcessStream, metadata).await.expect("open process stream");
    let incoming = daemon
        .accept()
        .await
        .expect("accept process stream")
        .expect("process stream was not delivered");
    let handler = tokio::spawn(DaemonServices::serve_process_stream(
        workspace,
        scope,
        incoming.stream,
        incoming.metadata,
    ));

    let response = tokio::time::timeout(std::time::Duration::from_secs(2), client_stream.receive())
        .await
        .expect("process-stream rejection timed out")
        .expect("process-stream rejection became a transport error")
        .expect("process stream closed without a rejection");
    assert_eq!(response.lane, Lane::Control);
    assert_eq!(
        serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
        ServiceControl::Rejected { code: expected_code.into(), message: expected_message.into() }
    );
    handler
        .await
        .expect("process-stream handler panicked")
        .expect("process-stream handler returned an error after rejecting the open");
    client.shutdown().await;
    daemon.shutdown().await;
}

#[tokio::test]
async fn process_stream_metadata_failure_is_rejected_before_open() {
    assert_process_stream_open_rejected(
        WorkspaceService::new(),
        ClientScope::new("metadata-rejection", cmux_remote_protocol::SessionId([13; 16])),
        BTreeMap::new(),
        "invalid-argument",
        "missing process",
    )
    .await;
}

#[tokio::test]
async fn process_stream_unknown_process_and_invalid_cursor_keep_rpc_errors() {
    let workspace = WorkspaceService::new();
    let scope = ClientScope::new("rpc-rejections", cmux_remote_protocol::SessionId([14; 16]));
    let unknown = ProcessId::from_u128(0x8000_0000_0030_0000);
    assert_process_stream_open_rejected(
        workspace.clone(),
        scope.clone(),
        BTreeMap::from([("process".into(), unknown.to_string()), ("after".into(), "0".into())]),
        "unknown-process",
        &format!("unknown process {unknown}"),
    )
    .await;

    let reserved = ProcessId::from_u128(0x8000_0000_0030_0001);
    assert_process_stream_open_rejected(
        workspace,
        scope,
        BTreeMap::from([
            ("process".into(), reserved.to_string()),
            ("after".into(), "1".into()),
            ("reserve".into(), "true".into()),
        ]),
        "invalid-replay-cursor",
        "a pre-spawn process stream must start after sequence zero",
    )
    .await;
}

#[tokio::test]
async fn process_stream_duplicate_reservation_is_rejected_before_open() {
    let workspace = WorkspaceService::new();
    let scope =
        ClientScope::new("duplicate-reservation", cmux_remote_protocol::SessionId([15; 16]));
    let process = ProcessId::from_u128(0x8000_0000_0030_0002);
    workspace
        .subscribe_or_reserve_process(&scope, process, 0, true)
        .await
        .expect("seed process reservation");

    assert_process_stream_open_rejected(
        workspace.clone(),
        scope.clone(),
        BTreeMap::from([
            ("process".into(), process.to_string()),
            ("after".into(), "0".into()),
            ("reserve".into(), "true".into()),
        ]),
        "duplicate-process-id",
        &format!("process handle {process} is already reserved"),
    )
    .await;
    workspace.release_process_reservation(&scope, process).await;
}

#[tokio::test]
async fn process_stream_reservation_capacity_is_rejected_before_open() {
    const RESERVATION_LIMIT: u128 = 256;

    let workspace = WorkspaceService::new();
    let scope = ClientScope::new("reservation-capacity", cmux_remote_protocol::SessionId([16; 16]));
    let base = 0x8000_0000_0040_0000;
    for index in 0..RESERVATION_LIMIT {
        workspace
            .subscribe_or_reserve_process(&scope, ProcessId::from_u128(base + index), 0, true)
            .await
            .expect("seed process reservation capacity");
    }
    let rejected = ProcessId::from_u128(base + RESERVATION_LIMIT);
    assert_process_stream_open_rejected(
        workspace.clone(),
        scope.clone(),
        BTreeMap::from([
            ("process".into(), rejected.to_string()),
            ("after".into(), "0".into()),
            ("reserve".into(), "true".into()),
        ]),
        "resource-exhausted",
        "pending process reservation limit of 256 reached",
    )
    .await;
    for index in 0..RESERVATION_LIMIT {
        workspace.release_process_reservation(&scope, ProcessId::from_u128(base + index)).await;
    }
}

#[tokio::test]
async fn workspace_client_preserves_process_stream_rejection_code() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let daemon = daemon_multiplexer.clone();
    let unknown = ProcessId::from_u128(0x8000_0000_0050_0000);
    let server = tokio::spawn(async move {
        let mut rpc_streams = Vec::new();
        for _ in 0..5 {
            let incoming = daemon
                .accept()
                .await
                .expect("accept workspace RPC stream")
                .expect("workspace RPC stream was not delivered");
            assert_eq!(incoming.service, Service::WorkspaceRpc);
            let lane = match incoming.metadata.get("lane").map(String::as_str) {
                Some("interactive") => Lane::Interactive,
                Some("bulk") => Lane::Bulk,
                Some("control") | None => Lane::Control,
                lane => panic!("unexpected workspace RPC lane {lane:?}"),
            };
            send_opened(&incoming.stream, lane).await.expect("acknowledge workspace RPC stream");
            rpc_streams.push(incoming.stream);
        }

        let incoming = daemon
            .accept()
            .await
            .expect("accept process stream")
            .expect("process stream was not delivered");
        assert_eq!(incoming.service, Service::ProcessStream);
        let result = DaemonServices::serve_process_stream(
            WorkspaceService::new(),
            ClientScope::new(
                "workspace-client-rejection",
                cmux_remote_protocol::SessionId([17; 16]),
            ),
            incoming.stream,
            incoming.metadata,
        )
        .await;
        drop(rpc_streams);
        result
    });

    let client = WorkspaceClient::connect(client_multiplexer.clone())
        .await
        .expect("connect workspace client");
    let error = match client.process_events(unknown, 0).await {
        Err(error) => error,
        Ok(_) => panic!("unknown process stream should be rejected"),
    };
    assert_eq!(error.code, "unknown-process");
    assert_eq!(error.message, format!("unknown process {unknown}"));
    server
        .await
        .expect("process-stream server panicked")
        .expect("process-stream server returned an error after rejecting the open");

    drop(client);
    client_multiplexer.shutdown().await;
    daemon_multiplexer.shutdown().await;
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn blocked_process_input_does_not_delay_process_signal() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let directory = tempdir().unwrap();
            let workspace = WorkspaceService::new();
            let services = DaemonServices::new(workspace.clone(), None);
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let server = tokio::task::spawn_local({
                let services = services.clone();
                let daemon_multiplexer = daemon_multiplexer.clone();
                async move {
                    let scope = ClientScope::new(
                        "process-control-test",
                        cmux_remote_protocol::SessionId([8; 16]),
                    );
                    let request_slots = RequestAdmission::new();
                    while let Some(incoming) = daemon_multiplexer.accept().await.unwrap() {
                        let services = services.clone();
                        let scope = scope.clone();
                        let request_slots = request_slots.clone();
                        tokio::task::spawn_local(async move {
                            let _ =
                                services.serve_stream(scope, request_slots, None, incoming).await;
                        });
                    }
                }
            });
            let client = WorkspaceClient::connect(client_multiplexer.clone()).await.unwrap();
            let opened = client
                .request(WorkspaceRequest::OpenWorkspace {
                    root: directory.path().to_string_lossy().into_owned(),
                })
                .await
                .unwrap();
            let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                panic!("open-workspace returned the wrong response")
            };
            let started = client
                .request(WorkspaceRequest::SpawnProcess {
                    workspace: WorkspaceId(workspace_id.0),
                    argv: vec!["/bin/sleep".into(), "30".into()],
                    cwd: None,
                    env: BTreeMap::new(),
                    io: ProcessIo::Pipes { stdin: true },
                    lifetime: ProcessLifetime::Workspace,
                    operation: None,
                    timeout_ms: None,
                    retained_output_bytes: None,
                    environment: ProcessEnvironment::Inherit,
                })
                .await
                .unwrap();
            let WorkspaceResponse::ProcessStarted { process, .. } = started else {
                panic!("spawn-process returned the wrong response")
            };

            let data = ByteString::from_bytes(&vec![b'x'; 32 * 1024]);
            let mut blocked_write = None;
            for write_id in 1..=64 {
                let pending = client
                    .begin_request(WorkspaceRequest::WriteProcess {
                        process,
                        write_id,
                        data: data.clone(),
                        eof: false,
                    })
                    .await
                    .unwrap();
                let mut write = tokio::spawn(async move { pending.receive().await });
                match tokio::time::timeout(std::time::Duration::from_secs(1), &mut write).await {
                    Ok(Ok(Ok(WorkspaceResponse::ProcessWriteAccepted { .. }))) => {}
                    Err(_) => {
                        blocked_write = Some(write);
                        break;
                    }
                    response => panic!("unexpected process-write response: {response:?}"),
                }
            }
            let blocked_write =
                blocked_write.expect("process stdin did not fill during the regression test");

            let signal = tokio::time::timeout(
                std::time::Duration::from_secs(2),
                client.request(WorkspaceRequest::SignalProcess {
                    process,
                    signal: ProcessSignal::Kill,
                }),
            )
            .await;
            if !matches!(&signal, Ok(Ok(WorkspaceResponse::ProcessSignaled { .. }))) {
                let _ = workspace
                    .handle_request(WorkspaceRequest::SignalProcess {
                        process,
                        signal: ProcessSignal::Kill,
                    })
                    .await;
            }
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                workspace.handle_request(WorkspaceRequest::WaitProcess { process }),
            )
            .await
            .expect("the regression-test process did not exit")
            .expect("waiting for the regression-test process failed");
            blocked_write.abort();
            let _ = blocked_write.await;

            let events = client
                .process_events(process, 0)
                .await
                .expect("opening the process event stream failed");
            let exit = tokio::time::timeout(std::time::Duration::from_secs(2), events.receive())
                .await
                .expect("process exit replay was delayed")
                .expect("process exit replay failed")
                .expect("process event stream closed before replaying exit");
            assert!(matches!(exit.event, ProcessEvent::Exit { .. }));

            drop(client);
            client_multiplexer.shutdown().await;
            daemon_multiplexer.shutdown().await;
            server.abort();
            let _ = server.await;

            assert!(
                matches!(
                    signal,
                    Ok(Ok(WorkspaceResponse::ProcessSignaled {
                        process: signaled,
                        signal: ProcessSignal::Kill,
                    })) if signaled == process
                ),
                "process signal stalled behind a blocked stdin write: {signal:?}"
            );
        })
        .await;
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn dropped_wait_requests_release_control_admission() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let directory = tempdir().unwrap();
            let workspace = WorkspaceService::new();
            let services = DaemonServices::new(workspace.clone(), None);
            let request_slots = RequestAdmission::new();
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let server = tokio::task::spawn_local({
                let services = services.clone();
                let daemon_multiplexer = daemon_multiplexer.clone();
                let request_slots = request_slots.clone();
                async move {
                    let scope = ClientScope::new(
                        "dropped-wait-test",
                        cmux_remote_protocol::SessionId([32; 16]),
                    );
                    while let Some(incoming) = daemon_multiplexer.accept().await.unwrap() {
                        let services = services.clone();
                        let scope = scope.clone();
                        let request_slots = request_slots.clone();
                        tokio::task::spawn_local(async move {
                            let _ =
                                services.serve_stream(scope, request_slots, None, incoming).await;
                        });
                    }
                }
            });
            let client = WorkspaceClient::connect(client_multiplexer.clone()).await.unwrap();
            let opened = client
                .request(WorkspaceRequest::OpenWorkspace {
                    root: directory.path().to_string_lossy().into_owned(),
                })
                .await
                .unwrap();
            let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                panic!("open-workspace returned the wrong response")
            };
            let started = client
                .request(WorkspaceRequest::SpawnProcess {
                    workspace: workspace_id,
                    argv: vec!["/bin/sleep".into(), "30".into()],
                    cwd: None,
                    env: BTreeMap::new(),
                    io: ProcessIo::Pipes { stdin: false },
                    lifetime: ProcessLifetime::Workspace,
                    operation: None,
                    timeout_ms: None,
                    retained_output_bytes: None,
                    environment: ProcessEnvironment::Inherit,
                })
                .await
                .unwrap();
            let WorkspaceResponse::ProcessStarted { process, .. } = started else {
                panic!("spawn-process returned the wrong response")
            };

            let mut pending = Vec::with_capacity(MAX_CONTROL_RPC_REQUESTS);
            for _ in 0..MAX_CONTROL_RPC_REQUESTS {
                pending.push(
                    client.begin_request(WorkspaceRequest::WaitProcess { process }).await.unwrap(),
                );
            }
            let admission_filled = tokio::time::timeout(std::time::Duration::from_secs(2), async {
                while request_slots.control.available_permits() != 0 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .is_ok();
            drop(pending);
            let admission_recovered =
                tokio::time::timeout(std::time::Duration::from_secs(2), async {
                    while request_slots.control.available_permits() != MAX_CONTROL_RPC_REQUESTS {
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .is_ok();
            let capabilities_succeeded = if admission_recovered {
                matches!(
                    tokio::time::timeout(
                        std::time::Duration::from_secs(1),
                        client.request(WorkspaceRequest::Capabilities),
                    )
                    .await,
                    Ok(Ok(WorkspaceResponse::Capabilities { .. }))
                )
            } else {
                false
            };

            workspace
                .handle_request(WorkspaceRequest::SignalProcess {
                    process,
                    signal: ProcessSignal::Kill,
                })
                .await
                .unwrap();
            workspace.handle_request(WorkspaceRequest::WaitProcess { process }).await.unwrap();
            drop(client);
            client_multiplexer.shutdown().await;
            daemon_multiplexer.shutdown().await;
            server.abort();
            let _ = server.await;

            assert!(admission_filled, "48 wait requests never filled control admission");
            assert!(
                admission_recovered,
                "dropping transmitted wait requests left server work and admission active"
            );
            assert!(
                capabilities_succeeded,
                "control RPC stayed unavailable after dropped waits were canceled"
            );
        })
        .await;
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn predeclared_process_stream_never_silently_loses_immediate_large_output() {
    tokio::task::LocalSet::new()
        .run_until(async {
            const OUTPUT_BYTES: usize = 8 * 1024 * 1024;

            let directory = tempdir().unwrap();
            let workspace = WorkspaceService::new();
            let services = DaemonServices::new(workspace, None);
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let server = tokio::task::spawn_local({
                let services = services.clone();
                let daemon_multiplexer = daemon_multiplexer.clone();
                async move {
                    let scope = ClientScope::new(
                        "large-output-test",
                        cmux_remote_protocol::SessionId([9; 16]),
                    );
                    let request_slots = RequestAdmission::new();
                    while let Some(incoming) = daemon_multiplexer.accept().await.unwrap() {
                        let services = services.clone();
                        let scope = scope.clone();
                        let request_slots = request_slots.clone();
                        tokio::task::spawn_local(async move {
                            let _ =
                                services.serve_stream(scope, request_slots, None, incoming).await;
                        });
                    }
                }
            });
            let client = WorkspaceClient::connect(client_multiplexer.clone()).await.unwrap();
            let opened = client
                .request(WorkspaceRequest::OpenWorkspace {
                    root: directory.path().to_string_lossy().into_owned(),
                })
                .await
                .unwrap();
            let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                panic!("open-workspace returned the wrong response")
            };

            let process = client.allocate_process_handle();
            let spawned = client
                .spawn_process_with_events(
                    process,
                    WorkspaceRequest::SpawnProcess {
                        workspace: workspace_id,
                        argv: vec![
                            "/bin/sh".into(),
                            "-c".into(),
                            "dd if=/dev/zero bs=1048576 count=8 2>/dev/null".into(),
                        ],
                        cwd: None,
                        env: BTreeMap::new(),
                        io: ProcessIo::Pipes { stdin: false },
                        lifetime: ProcessLifetime::Workspace,
                        operation: None,
                        timeout_ms: None,
                        retained_output_bytes: None,
                        environment: ProcessEnvironment::Inherit,
                    },
                )
                .await
                .unwrap();

            let mut received = 0usize;
            let mut structured_loss = None;
            loop {
                let event = tokio::time::timeout(
                    std::time::Duration::from_secs(15),
                    spawned.events.receive(),
                )
                .await
                .expect("large process output stream stalled")
                .expect("large process output stream failed")
                .expect("large process output stream closed without a terminal event");
                match event.event {
                    ProcessEvent::Stdout { data, .. } => {
                        let bytes = data.decode().unwrap();
                        assert!(bytes.iter().all(|byte| *byte == 0));
                        received += bytes.len();
                    }
                    ProcessEvent::OutputTruncated { reason, .. } => {
                        structured_loss = Some(format!("output-truncated:{reason:?}"));
                    }
                    ProcessEvent::ReplayGap { requested_after, range, .. } => {
                        structured_loss = Some(format!("replay-gap:{requested_after}:{range:?}"));
                        break;
                    }
                    ProcessEvent::Exit { .. } => break,
                    ProcessEvent::Stderr { .. } => {}
                }
            }
            assert!(
                received == OUTPUT_BYTES || structured_loss.is_some(),
                "received {received} of {OUTPUT_BYTES} bytes without structured loss metadata"
            );

            drop(client);
            client_multiplexer.shutdown().await;
            daemon_multiplexer.shutdown().await;
            server.abort();
            let _ = server.await;
        })
        .await;
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn reconnect_process_stream_reports_a_structured_replay_gap() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let directory = tempdir().unwrap();
            let workspace = WorkspaceService::new();
            let services = DaemonServices::new(workspace, None);
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let server = tokio::task::spawn_local({
                let services = services.clone();
                let daemon_multiplexer = daemon_multiplexer.clone();
                async move {
                    let scope = ClientScope::new(
                        "replay-gap-test",
                        cmux_remote_protocol::SessionId([10; 16]),
                    );
                    let request_slots = RequestAdmission::new();
                    while let Some(incoming) = daemon_multiplexer.accept().await.unwrap() {
                        let services = services.clone();
                        let scope = scope.clone();
                        let request_slots = request_slots.clone();
                        tokio::task::spawn_local(async move {
                            let _ =
                                services.serve_stream(scope, request_slots, None, incoming).await;
                        });
                    }
                }
            });
            let client = WorkspaceClient::connect(client_multiplexer.clone()).await.unwrap();
            let opened = client
                .request(WorkspaceRequest::OpenWorkspace {
                    root: directory.path().to_string_lossy().into_owned(),
                })
                .await
                .unwrap();
            let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                panic!("open-workspace returned the wrong response")
            };
            let started = client
                .request(WorkspaceRequest::SpawnProcess {
                    workspace: workspace_id,
                    argv: vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        "dd if=/dev/zero bs=65536 count=2 2>/dev/null".into(),
                    ],
                    cwd: None,
                    env: BTreeMap::new(),
                    io: ProcessIo::Pipes { stdin: false },
                    lifetime: ProcessLifetime::Workspace,
                    operation: None,
                    timeout_ms: None,
                    retained_output_bytes: Some(1),
                    environment: ProcessEnvironment::Inherit,
                })
                .await
                .unwrap();
            let WorkspaceResponse::ProcessStarted { process, .. } = started else {
                panic!("spawn-process returned the wrong response")
            };
            client.request(WorkspaceRequest::WaitProcess { process }).await.unwrap();

            let events = client.process_events(process, 0).await.unwrap();
            let gap =
                events.receive().await.unwrap().expect("replay-gap stream closed without metadata");
            assert!(matches!(
                gap.event,
                ProcessEvent::ReplayGap {
                    process: gap_process,
                    requested_after: 0,
                    range: ProcessReplayRange {
                        first_available: Some(first),
                        ..
                    },
                } if gap_process == process && first > 1
            ));

            drop(client);
            client_multiplexer.shutdown().await;
            daemon_multiplexer.shutdown().await;
            server.abort();
            let _ = server.await;
        })
        .await;
}

#[tokio::test]
async fn canceled_reserved_process_streams_do_not_exhaust_the_same_session() {
    const RESERVATION_LIMIT: u128 = 256;

    let workspace = WorkspaceService::new();
    let scope =
        ClientScope::new("canceled-process-stream-test", cmux_remote_protocol::SessionId([12; 16]));
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);

    for index in 0..RESERVATION_LIMIT {
        let process = ProcessId::from_u128(0x8000_0000_0010_0000 + index);
        let client_stream = client
            .open(
                Service::ProcessStream,
                BTreeMap::from([
                    ("process".into(), process.to_string()),
                    ("after".into(), "0".into()),
                    ("reserve".into(), "true".into()),
                ]),
            )
            .await
            .unwrap();
        let incoming = daemon.accept().await.unwrap().unwrap();
        let handler = tokio::spawn(DaemonServices::serve_process_stream(
            workspace.clone(),
            scope.clone(),
            incoming.stream,
            incoming.metadata,
        ));
        let opened = client_stream.receive().await.unwrap().unwrap();
        assert!(matches!(
            serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
            ServiceControl::Opened { service: Service::ProcessStream }
        ));
        handler.abort();
        let _ = handler.await;
        drop(client_stream);
    }

    let fresh_reservations = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let mut reservations = Vec::with_capacity(RESERVATION_LIMIT as usize);
        for index in 0..RESERVATION_LIMIT {
            let process = ProcessId::from_u128(0x8000_0000_0020_0000 + index);
            loop {
                match workspace.subscribe_or_reserve_process(&scope, process, 0, true).await {
                    Ok(subscription) => {
                        reservations.push((process, subscription));
                        break;
                    }
                    Err(error) if error.code == "resource-exhausted" => {
                        tokio::task::yield_now().await;
                    }
                    Err(error) => {
                        panic!("fresh process reservation failed unexpectedly: {error}")
                    }
                }
            }
        }
        reservations
    })
    .await
    .expect("canceled opens leaked at least one reservation slot");
    assert_eq!(fresh_reservations.len(), RESERVATION_LIMIT as usize);
    for (process, _) in fresh_reservations {
        workspace.release_process_reservation(&scope, process).await;
    }
    client.shutdown().await;
    daemon.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn completed_process_event_stream_uses_bulk_lane_then_finishes() {
    let directory = tempdir().unwrap();
    let workspace = WorkspaceService::new();
    let opened = workspace
        .handle_rpc(RpcRequest {
            id: cmux_remote_protocol::RequestId::from_u128(1),
            timeout_ms: None,
            request: WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_string_lossy().into_owned(),
            },
        })
        .await
        .result
        .unwrap();
    let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else { panic!() };
    let started = workspace
        .handle_rpc(RpcRequest {
            id: cmux_remote_protocol::RequestId::from_u128(2),
            timeout_ms: None,
            request: WorkspaceRequest::SpawnProcess {
                workspace: WorkspaceId(workspace_id.0),
                argv: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
                cwd: None,
                env: BTreeMap::new(),
                io: ProcessIo::Pipes { stdin: false },
                lifetime: ProcessLifetime::Workspace,
                operation: None,
                timeout_ms: None,
                retained_output_bytes: None,
                environment: ProcessEnvironment::Inherit,
            },
        })
        .await
        .result
        .unwrap();
    let WorkspaceResponse::ProcessStarted { process, .. } = started else { panic!() };
    workspace
        .handle_rpc(RpcRequest {
            id: cmux_remote_protocol::RequestId::from_u128(3),
            timeout_ms: None,
            request: WorkspaceRequest::WaitProcess { process },
        })
        .await
        .result
        .unwrap();

    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let client_stream = client
        .open(
            Service::ProcessStream,
            BTreeMap::from([("process".into(), process.to_string()), ("after".into(), "0".into())]),
        )
        .await
        .unwrap();
    let incoming = daemon.accept().await.unwrap().unwrap();
    let handler = tokio::spawn(DaemonServices::serve_process_stream(
        workspace,
        ClientScope::new(
            "completed-process-stream-test",
            cmux_remote_protocol::SessionId([11; 16]),
        ),
        incoming.stream,
        incoming.metadata,
    ));
    let opened = client_stream.receive().await.unwrap().unwrap();
    assert_eq!(opened.lane, Lane::Bulk);
    assert!(matches!(
        serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
        ServiceControl::Opened { service: Service::ProcessStream }
    ));
    let messages = MessageStream::with_lane(Arc::new(client_stream), Lane::Bulk);
    let event: RpcEvent =
        serde_json::from_slice(&messages.receive().await.unwrap().unwrap()).unwrap();
    assert!(matches!(event.event, ProcessEvent::Exit { .. }));
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(1), messages.receive())
            .await
            .expect("completed process stream should send FIN")
            .unwrap()
            .is_none()
    );
    tokio::time::timeout(std::time::Duration::from_secs(1), handler)
        .await
        .expect("completed process stream handler should release its slot")
        .unwrap()
        .unwrap();
}

/// A reconnect's READY snapshot is large and the bytes printed right after it
/// are small. Both must reach the app in host order: output tagged with the
/// new generation that overtakes its READY is wiped when the READY lands.
#[tokio::test]
#[cfg(unix)]
async fn mux_control_delivers_a_large_snapshot_before_the_output_after_it() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let screen = "A".repeat(768 * 1024);
    let snapshot = serde_json::json!({
        "event": "snapshot", "surface": 1, "phase": "ready", "generation": 2,
        "offset": 9, "version": 1, "cols": 80, "rows": 24, "data": screen,
    });
    let output = serde_json::json!({
        "event": "output", "surface": 1, "data": "aGk=", "generation": 2, "offset": 9,
    });
    let fake = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut lines = Vec::new();
        for event in [&snapshot, &output] {
            lines.extend(serde_json::to_vec(event).unwrap());
            lines.push(b'\n');
        }
        socket.write_all(&lines).await.unwrap();
        // Held open until the test is done reading.
        std::future::pending::<()>().await;
    });
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let stream = client_mux.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();
    let serve = tokio::spawn(DaemonServices::serve_mux_control_with_budget(
        Some(path),
        None,
        incoming.stream,
        MuxUploadBudget::new(),
    ));

    let opened = stream.receive().await.unwrap().unwrap();
    let opened: serde_json::Value = serde_json::from_slice(&opened.payload).unwrap();
    assert_eq!(opened["type"], "opened", "{opened}");
    let read = async {
        let mut assembler = crate::mux_codec::MuxLineAssembler::<()>::default();
        let mut events = Vec::new();
        while events.len() < 2 {
            let chunk = stream.receive().await.unwrap().expect("stream ended early");
            // Empty frames carry flow control, not mux packets.
            if chunk.payload.is_empty() {
                continue;
            }
            if let Some(line) = assembler.push_retaining(chunk.lane, chunk.payload, ()).unwrap() {
                let value: serde_json::Value = serde_json::from_slice(line.payload()).unwrap();
                events.push((value["event"].as_str().unwrap().to_owned(), line.lane()));
            }
        }
        events
    };
    let events = acpmux_bridge::tests::within(read).await;
    let expected = [("snapshot".to_owned(), Lane::Bulk), ("output".to_owned(), Lane::Bulk)];
    assert_eq!(events, expected);
    serve.abort();
    fake.abort();
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
}
