use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, ServerConnection, serve_direct_websocket};
use cmux_remote::identity::{AuthDatabase, DeviceRecord};
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::{DaemonServices, MessageStream, ServicesError};
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    ByteString, FilePrecondition, Lane, LanePolicy, OperationId, ProcessEnvironment, ProcessId,
    ProcessIo, ProcessLifetime, ProcessSignal, RemoteCapability, RequestId, RpcRequest,
    RpcResponse, Service, ServiceControl, SessionId, WorkspaceId, WorkspaceRequest,
    WorkspaceResponse,
};
use tempfile::tempdir;
use tokio::sync::mpsc;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const TEST_TIMEOUT: Duration = Duration::from_secs(30);
const STEP_TIMEOUT: Duration = Duration::from_secs(5);

async fn approve_invitation(auth: Arc<AuthDatabase>, invitation_id: String) -> DeviceRecord {
    tokio::time::timeout(STEP_TIMEOUT, async {
        loop {
            if auth
                .pending_enrollments()
                .await
                .iter()
                .any(|pending| pending.invitation_id == invitation_id)
            {
                return auth.approve(&invitation_id).await.unwrap();
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("client did not request enrollment")
}

async fn connect_client(
    provider: &DirectWebSocketProvider,
    endpoint: &Url,
    daemon_public_key: [u8; 32],
    identity: StaticIdentity,
    auth: ClientAuthMode,
    device_name: &str,
    session: SessionId,
) -> Arc<ClientConnection> {
    let group = provider
        .connect(ConnectRequest {
            endpoint: endpoint.clone(),
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(daemon_public_key),
            auth,
            device_name: device_name.into(),
            session,
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..ReconnectPolicy::default() },
        },
    )
    .await
    .unwrap()
}

async fn accept_and_serve(
    accepted: &mut mpsc::Receiver<Arc<ServerConnection>>,
    services: Arc<DaemonServices>,
) -> (String, tokio::task::JoinHandle<Result<(), ServicesError>>) {
    let connection = tokio::time::timeout(STEP_TIMEOUT, accepted.recv())
        .await
        .expect("daemon did not publish the authenticated client")
        .expect("daemon stopped accepting clients");
    let device_id = connection.device_id.clone();
    let task = tokio::task::spawn_local(async move { services.serve_client(connection).await });
    (device_id, task)
}

async fn open_rpc_channel(
    multiplexer: &Arc<ServiceMultiplexer>,
    cancellation: bool,
) -> MessageStream {
    let mut metadata = BTreeMap::from([("lane".into(), "control".into())]);
    if cancellation {
        metadata.insert("purpose".into(), "cancellation".into());
    }
    let stream = multiplexer.open(Service::WorkspaceRpc, metadata).await.unwrap();
    let opened = stream
        .receive()
        .await
        .unwrap()
        .expect("workspace RPC stream closed before its acknowledgement");
    assert_eq!(opened.lane, Lane::Control);
    assert!(matches!(
        serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
        ServiceControl::Opened { service: Service::WorkspaceRpc }
    ));
    MessageStream::with_lane(Arc::new(stream), Lane::Control)
}

async fn send_rpc(channel: &MessageStream, id: RequestId, request: WorkspaceRequest) {
    channel
        .send(&serde_json::to_vec(&RpcRequest { id, timeout_ms: None, request }).unwrap())
        .await
        .unwrap();
}

async fn receive_rpc(channel: &MessageStream) -> RpcResponse {
    let encoded = tokio::time::timeout(STEP_TIMEOUT, channel.receive())
        .await
        .expect("workspace RPC response timed out")
        .unwrap()
        .expect("workspace RPC stream closed before its response");
    serde_json::from_slice(&encoded).unwrap()
}

async fn list_workspaces(client: &WorkspaceClient) -> Vec<(WorkspaceId, String)> {
    let response = client.request(WorkspaceRequest::ListWorkspaces).await.unwrap();
    let WorkspaceResponse::Workspaces { workspaces } = response else {
        panic!("list-workspaces returned the wrong response: {response:?}")
    };
    workspaces
}

async fn spawn_process(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    lifetime: ProcessLifetime,
    operation: Option<OperationId>,
) -> ProcessId {
    let process = client.allocate_process_handle();
    let response = client
        .request(WorkspaceRequest::SpawnProcessWithHandle {
            process,
            workspace: workspace.clone(),
            argv: vec!["/bin/sleep".into(), "30".into()],
            cwd: None,
            env: BTreeMap::new(),
            io: ProcessIo::Pipes { stdin: false },
            lifetime,
            operation,
            timeout_ms: None,
            retained_output_bytes: None,
            environment: ProcessEnvironment::Inherit,
            output_drain_idle_timeout_ms: None,
            output_drain_total_timeout_ms: None,
        })
        .await
        .unwrap();
    let WorkspaceResponse::ProcessStarted { process: started, .. } = response else {
        panic!("spawn-process returned the wrong response: {response:?}")
    };
    assert_eq!(started, process);
    process
}

async fn finish_operation(client: &WorkspaceClient, operation: &OperationId) {
    assert_eq!(
        client
            .request(WorkspaceRequest::FinishOperation { operation: operation.clone() })
            .await
            .unwrap(),
        WorkspaceResponse::OperationFinished {
            operation: operation.clone(),
            processes_signaled: 1,
        }
    );
}

async fn wait_for_process_exit(client: &WorkspaceClient, process: ProcessId) {
    let response = tokio::time::timeout(
        STEP_TIMEOUT,
        client.request(WorkspaceRequest::WaitProcess { process }),
    )
    .await
    .expect("process did not exit")
    .unwrap();
    assert!(matches!(
        response,
        WorkspaceResponse::ProcessExit {
            process: exited,
            ..
        } if exited == process
    ));
}

async fn assert_process_running(client: &WorkspaceClient, process: ProcessId) {
    let error = client
        .request_with_timeout(WorkspaceRequest::WaitProcess { process }, Duration::from_millis(100))
        .await
        .expect_err("process exited unexpectedly");
    assert_eq!(error.code, "deadline-exceeded");
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn authenticated_clients_share_daemon_authority_but_keep_lifecycle_scoped() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(TEST_TIMEOUT, async {
                let auth_state = tempdir().unwrap();
                let workspace_root = tempdir().unwrap();
                let auth =
                    AuthDatabase::load_or_create(auth_state.path(), "multi-client-e2e", false)
                        .unwrap();
                let (daemon, mut accepted) =
                    RemoteDaemon::new(auth.clone(), SessionLimits::default());
                let websocket = serve_direct_websocket(
                    daemon.clone(),
                    "127.0.0.1:0".parse().unwrap(),
                    MAXIMUM_FRAME_BYTES,
                    false,
                )
                .await
                .unwrap();
                let endpoint =
                    Url::parse(&format!("ws://{}/v1/link", websocket.local_addr())).unwrap();
                let provider = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES);
                let identity_a = StaticIdentity::generate().unwrap();
                let identity_b = StaticIdentity::generate().unwrap();
                let invitation_a =
                    auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
                let invitation_b =
                    auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
                let approval_a =
                    tokio::spawn(approve_invitation(auth.clone(), invitation_a.id.clone()));
                let approval_b =
                    tokio::spawn(approve_invitation(auth.clone(), invitation_b.id.clone()));
                let daemon_public_key = auth.identity().public_key();
                let (client_a, client_b) = tokio::join!(
                    connect_client(
                        &provider,
                        &endpoint,
                        daemon_public_key,
                        identity_a.clone(),
                        ClientAuthMode::Invitation {
                            id: invitation_a.id.clone(),
                            secret: Zeroizing::new(invitation_a.secret_bytes().unwrap()),
                        },
                        "multi-client-a",
                        SessionId([0xa1; 16]),
                    ),
                    connect_client(
                        &provider,
                        &endpoint,
                        daemon_public_key,
                        identity_b.clone(),
                        ClientAuthMode::Invitation {
                            id: invitation_b.id.clone(),
                            secret: Zeroizing::new(invitation_b.secret_bytes().unwrap()),
                        },
                        "multi-client-b",
                        SessionId([0xb1; 16]),
                    ),
                );
                let record_a = approval_a.await.unwrap();
                let record_b = approval_b.await.unwrap();
                assert_ne!(record_a.id, record_b.id);
                assert_eq!(record_a.id, identity_a.fingerprint());
                assert_eq!(record_b.id, identity_b.fingerprint());
                let devices = auth.list_devices().await;
                assert_eq!(devices.len(), 2);
                assert!(devices.iter().all(|device| device.revoked_at_unix.is_none()));

                let workspace_service = WorkspaceService::new();
                let services = DaemonServices::new(workspace_service, None);
                let (first_id, first_task) =
                    accept_and_serve(&mut accepted, services.clone()).await;
                let (second_id, second_task) =
                    accept_and_serve(&mut accepted, services.clone()).await;
                let (service_a, service_b) = if first_id == record_a.id {
                    assert_eq!(second_id, record_b.id);
                    (first_task, second_task)
                } else {
                    assert_eq!(first_id, record_b.id);
                    assert_eq!(second_id, record_a.id);
                    (second_task, first_task)
                };

                let multiplexer_a = ServiceMultiplexer::new(client_a.clone(), EndpointRole::Client);
                let multiplexer_b = ServiceMultiplexer::new(client_b.clone(), EndpointRole::Client);
                let workspace_a = WorkspaceClient::connect(multiplexer_a.clone()).await.unwrap();
                let workspace_b = WorkspaceClient::connect(multiplexer_b.clone()).await.unwrap();

                let opened_a = workspace_a
                    .request(WorkspaceRequest::OpenWorkspace {
                        root: workspace_root.path().to_string_lossy().into_owned(),
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::Workspace { id: workspace_id, root: canonical_root } =
                    opened_a
                else {
                    panic!("open-workspace returned the wrong response: {opened_a:?}")
                };
                let opened_b = workspace_b
                    .request(WorkspaceRequest::OpenWorkspace {
                        root: workspace_root.path().to_string_lossy().into_owned(),
                    })
                    .await
                    .unwrap();
                assert_eq!(
                    opened_b,
                    WorkspaceResponse::Workspace {
                        id: workspace_id.clone(),
                        root: canonical_root.clone(),
                    }
                );
                let catalog_a = list_workspaces(&workspace_a).await;
                let catalog_b = list_workspaces(&workspace_b).await;
                assert_eq!(catalog_a, catalog_b);
                assert_eq!(catalog_a, vec![(workspace_id.clone(), canonical_root.clone())]);

                assert!(matches!(
                    workspace_a
                        .request(WorkspaceRequest::WriteFile {
                            workspace: workspace_id.clone(),
                            path: "shared.txt".into(),
                            data: ByteString::from_bytes(b"one daemon user\n"),
                            precondition: FilePrecondition::Missing,
                            create_parents: false,
                        })
                        .await
                        .unwrap(),
                    WorkspaceResponse::Written { bytes: 16, .. }
                ));
                let shared_file = workspace_b
                    .request(WorkspaceRequest::ReadFile {
                        workspace: workspace_id.clone(),
                        path: "shared.txt".into(),
                        offset: 0,
                        limit: 1024,
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::File { data, eof: true, .. } = shared_file else {
                    panic!("read-file returned the wrong response: {shared_file:?}")
                };
                assert_eq!(data.decode().unwrap(), b"one daemon user\n");

                let shared_operation = OperationId("same-operation-id".into());
                let operation_process_a = spawn_process(
                    &workspace_a,
                    &workspace_id,
                    ProcessLifetime::Operation,
                    Some(shared_operation.clone()),
                )
                .await;
                let operation_process_b = spawn_process(
                    &workspace_b,
                    &workspace_id,
                    ProcessLifetime::Operation,
                    Some(shared_operation.clone()),
                )
                .await;
                assert_ne!(operation_process_a, operation_process_b);

                let requests_a = open_rpc_channel(&multiplexer_a, false).await;
                let cancellations_a = open_rpc_channel(&multiplexer_a, true).await;
                let requests_b = open_rpc_channel(&multiplexer_b, false).await;
                let shared_request = RequestId::from_u128(700);
                let barrier_request = RequestId::from_u128(701);
                send_rpc(
                    &requests_a,
                    shared_request,
                    WorkspaceRequest::WaitProcess { process: operation_process_a },
                )
                .await;
                send_rpc(
                    &requests_b,
                    shared_request,
                    WorkspaceRequest::WaitProcess { process: operation_process_b },
                )
                .await;
                send_rpc(&requests_a, barrier_request, WorkspaceRequest::Capabilities).await;
                send_rpc(&requests_b, barrier_request, WorkspaceRequest::Capabilities).await;
                for barrier in [receive_rpc(&requests_a).await, receive_rpc(&requests_b).await] {
                    assert_eq!(barrier.id, barrier_request);
                    let WorkspaceResponse::Capabilities { capabilities } = barrier.result.unwrap()
                    else {
                        panic!("capabilities returned the wrong response")
                    };
                    assert!(capabilities.contains(&RemoteCapability::ProcessHandlesV2));
                }

                send_rpc(
                    &cancellations_a,
                    RequestId::from_u128(702),
                    WorkspaceRequest::CancelRequest { request: shared_request },
                )
                .await;
                let cancellation = receive_rpc(&cancellations_a).await;
                assert_eq!(
                    cancellation.result.unwrap(),
                    WorkspaceResponse::RequestCanceled { request: shared_request, accepted: true }
                );
                let canceled = receive_rpc(&requests_a).await;
                assert_eq!(canceled.id, shared_request);
                assert_eq!(canceled.result.unwrap_err().code, "canceled");
                assert!(
                    tokio::time::timeout(Duration::from_millis(100), requests_b.receive())
                        .await
                        .is_err(),
                    "canceling client A's request canceled client B's identical request ID"
                );

                finish_operation(&workspace_a, &shared_operation).await;
                wait_for_process_exit(&workspace_a, operation_process_a).await;
                assert!(
                    tokio::time::timeout(Duration::from_millis(100), requests_b.receive())
                        .await
                        .is_err(),
                    "finishing client A's operation terminated client B's process"
                );
                finish_operation(&workspace_b, &shared_operation).await;
                let process_b_exit = receive_rpc(&requests_b).await;
                assert_eq!(process_b_exit.id, shared_request);
                assert!(matches!(
                    process_b_exit.result.unwrap(),
                    WorkspaceResponse::ProcessExit {
                        process,
                        ..
                    } if process == operation_process_b
                ));
                requests_a.close().await.unwrap();
                cancellations_a.close().await.unwrap();
                requests_b.close().await.unwrap();

                let disconnect_process_a =
                    spawn_process(&workspace_a, &workspace_id, ProcessLifetime::Workspace, None)
                        .await;
                let surviving_process_b =
                    spawn_process(&workspace_b, &workspace_id, ProcessLifetime::Workspace, None)
                        .await;
                drop(workspace_a);
                multiplexer_a.shutdown().await;
                assert!(daemon.disconnect(&record_a.id, client_a.session_id()).await.unwrap());
                let _ = client_a.close().await;
                wait_for_process_exit(&workspace_b, disconnect_process_a).await;
                assert_process_running(&workspace_b, surviving_process_b).await;
                assert_eq!(list_workspaces(&workspace_b).await, catalog_b);
                service_a.abort();
                let _ = service_a.await;

                let reconnected_a = connect_client(
                    &provider,
                    &endpoint,
                    daemon_public_key,
                    identity_a.clone(),
                    ClientAuthMode::Enrolled,
                    "multi-client-a",
                    SessionId([0xa2; 16]),
                )
                .await;
                let (reconnected_id, revoked_service) =
                    accept_and_serve(&mut accepted, services.clone()).await;
                assert_eq!(reconnected_id, record_a.id);
                let reconnected_multiplexer =
                    ServiceMultiplexer::new(reconnected_a.clone(), EndpointRole::Client);
                let reconnected_workspace =
                    WorkspaceClient::connect(reconnected_multiplexer.clone()).await.unwrap();
                assert_eq!(
                    reconnected_workspace
                        .request(WorkspaceRequest::OpenWorkspace {
                            root: workspace_root.path().to_string_lossy().into_owned(),
                        })
                        .await
                        .unwrap(),
                    WorkspaceResponse::Workspace { id: workspace_id.clone(), root: canonical_root }
                );
                let revoked_process = spawn_process(
                    &reconnected_workspace,
                    &workspace_id,
                    ProcessLifetime::Workspace,
                    None,
                )
                .await;

                drop(reconnected_workspace);
                reconnected_multiplexer.shutdown().await;
                auth.revoke(&record_a.id).await.unwrap();
                wait_for_process_exit(&workspace_b, revoked_process).await;
                assert_process_running(&workspace_b, surviving_process_b).await;
                assert_eq!(list_workspaces(&workspace_b).await, catalog_b);
                assert!(!auth.device_is_active(&record_a.id).await);
                assert!(auth.device_is_active(&record_b.id).await);
                let devices = auth.list_devices().await;
                assert!(
                    devices
                        .iter()
                        .find(|device| device.id == record_a.id)
                        .unwrap()
                        .revoked_at_unix
                        .is_some()
                );
                assert!(
                    devices
                        .iter()
                        .find(|device| device.id == record_b.id)
                        .unwrap()
                        .revoked_at_unix
                        .is_none()
                );
                let remaining = daemon.connections().await;
                assert_eq!(remaining.len(), 1);
                assert_eq!(remaining[0].device_id, record_b.id);

                let _ = reconnected_a.close().await;
                revoked_service.abort();
                let _ = revoked_service.await;
                workspace_b
                    .request(WorkspaceRequest::SignalProcess {
                        process: surviving_process_b,
                        signal: ProcessSignal::Kill,
                    })
                    .await
                    .unwrap();
                wait_for_process_exit(&workspace_b, surviving_process_b).await;
                assert!(matches!(
                    workspace_b
                        .request(WorkspaceRequest::CloseWorkspace { workspace: workspace_id })
                        .await
                        .unwrap(),
                    WorkspaceResponse::WorkspaceClosed { .. }
                ));
                drop(workspace_b);
                multiplexer_b.shutdown().await;
                client_b.close().await.unwrap();
                service_b.abort();
                let _ = service_b.await;
                websocket.shutdown().await.unwrap();
            })
            .await
            .expect("multi-client E2E timed out");
        })
        .await;
}
