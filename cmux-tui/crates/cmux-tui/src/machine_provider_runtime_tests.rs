use std::io::{BufRead, BufReader, ErrorKind as IoErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant as TestInstant};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::*;

static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);

struct TestProviderSocket {
    path: PathBuf,
    listener: UnixListener,
}

impl TestProviderSocket {
    fn bind() -> Self {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-provider-runtime-{}-{id}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        Self { path, listener }
    }

    fn listener(&self) -> UnixListener {
        self.listener.try_clone().unwrap()
    }
}

impl Drop for TestProviderSocket {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

struct TestStateRoot {
    path: PathBuf,
}

impl TestStateRoot {
    fn create(label: &str) -> Self {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-provider-state-{label}-{}-{id}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        let mut builder = std::fs::DirBuilder::new();
        builder.mode(0o700).create(&path).unwrap();
        Self { path }
    }
}

impl Drop for TestStateRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn connect_after_runtime_start(socket_path: &Path, state_root: &Path) -> ProviderMachineRuntime {
    ProviderMachineRuntime::connect_in_state_root(socket_path, token(), state_root).unwrap()
}

fn id(value: &str) -> protocol::OpaqueId {
    protocol::OpaqueId::new(value).unwrap()
}

fn token() -> protocol::BearerToken {
    protocol::BearerToken::new("runtime-test-token").unwrap()
}

fn cache_test_connection(
    runtime: &mut ProviderMachineRuntime,
    connection_id: &str,
    machine_id: &str,
    close_on_drop: bool,
) -> OpenConnection {
    let machine_id = id(machine_id);
    let key = key_for_id(&runtime.keys, &machine_id).expect("test machine has a stable key");
    let open = OpenConnection {
        client: runtime.client.clone(),
        connection_id: id(connection_id),
        machine_id,
    };
    let connector: MachineConnectFn =
        Arc::new(|| anyhow::bail!("test connection must be served from the ready cache"));
    runtime.connections.register(key, connector);
    runtime.connection_registry.lock().unwrap().insert(key, open.clone());
    let lease = close_on_drop.then(|| {
        Box::new(ProviderMachineConnectionLease {
            open: open.clone(),
            key,
            registry: runtime.connection_registry.clone(),
        }) as Box<dyn crate::machine_runtime::MachineConnectionLease>
    });
    runtime.connections.insert_ready(
        key,
        MachineConnection {
            session: Session::Local(Mux::new(
                format!(
                    "provider-test-connection-{}",
                    NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
                ),
                SurfaceOptions::default(),
            )),
            _lease: lease,
        },
    );
    open
}

fn install_test_connection(
    runtime: &mut ProviderMachineRuntime,
    connection_id: &str,
    machine_id: &str,
    close_on_drop: bool,
) {
    let open = cache_test_connection(runtime, connection_id, machine_id, close_on_drop);
    runtime.open = Some(open);
}

fn provider_connect(target: &str) -> MachineRequest {
    MachineRequest::Connect { target: target.into(), route: MachineConnectRoute::Provider }
}

fn local_connect(target: &str) -> MachineRequest {
    MachineRequest::Connect { target: target.into(), route: MachineConnectRoute::Local }
}

fn read_frame<T: DeserializeOwned>(reader: &mut BufReader<UnixStream>) -> T {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0, "provider client reached EOF");
    serde_json::from_str(&line).unwrap()
}

fn write_frame<T: Serialize>(stream: &mut UnixStream, frame: &T) {
    serde_json::to_writer(&mut *stream, frame).unwrap();
    stream.write_all(b"\n").unwrap();
    stream.flush().unwrap();
}

fn expect_ui_update(update: MachineUpdate) -> MachineUiState {
    match update {
        MachineUpdate::Ui(ui) => *ui,
        MachineUpdate::DurableNotice(notice) => {
            panic!("expected UI update, received durable notice {notice:?}")
        }
        MachineUpdate::ConnectionProgress { machine_id, latest } => {
            panic!("expected UI update, received progress {machine_id:?}: {latest:?}")
        }
    }
}

fn serve_initial_snapshot(
    listener: &UnixListener,
    snapshot: protocol::SnapshotResult,
) -> (UnixStream, BufReader<UnixStream>) {
    serve_initial_snapshot_with_capabilities(listener, snapshot, &[])
}

fn serve_initial_snapshot_with_capabilities(
    listener: &UnixListener,
    snapshot: protocol::SnapshotResult,
    additional_capabilities: &[&str],
) -> (UnixStream, BufReader<UnixStream>) {
    let (stream, _) = listener.accept().unwrap();
    serve_initial_snapshot_on_stream(stream, snapshot, additional_capabilities)
}

fn serve_initial_snapshot_on_stream(
    mut stream: UnixStream,
    snapshot: protocol::SnapshotResult,
    additional_capabilities: &[&str],
) -> (UnixStream, BufReader<UnixStream>) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let hello: protocol::RequestEnvelope = read_frame(&mut reader);
    let protocol::ProviderRequest::Hello(params) = hello.request else {
        panic!("first provider request was not hello");
    };
    assert_eq!(params.token.expose(), "runtime-test-token");
    let capabilities = [
        protocol::MACHINE_LIFECYCLE_CAPABILITY,
        protocol::WORKSPACE_LIFECYCLE_CAPABILITY,
        protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY,
    ]
    .into_iter()
    .chain(additional_capabilities.iter().copied());
    write_frame(
        &mut stream,
        &protocol::ResponseEnvelope::success(
            hello.id,
            protocol::HelloResult {
                provider_id: id("test-provider"),
                provider_name: "Test Provider".into(),
                negotiated_version: protocol::Version,
            },
        )
        .with_capabilities(capabilities),
    );

    let request: protocol::RequestEnvelope = read_frame(&mut reader);
    assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
    write_frame(&mut stream, &protocol::ResponseEnvelope::success(request.id, snapshot.clone()));
    serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &snapshot);
    (stream, reader)
}

fn accept_with_timeout(listener: &UnixListener) -> Option<UnixStream> {
    listener.set_nonblocking(true).unwrap();
    let deadline = TestInstant::now() + Duration::from_secs(2);
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).unwrap();
                return Some(stream);
            }
            Err(error) if error.kind() == IoErrorKind::WouldBlock => {
                if TestInstant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("accept provider connection: {error}"),
        }
    }
}

fn negotiate_durable_then_expect_disconnect(listener: &UnixListener) -> bool {
    let Some(mut stream) = accept_with_timeout(listener) else { return false };
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let hello: protocol::RequestEnvelope = read_frame(&mut reader);
    assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
    write_frame(
        &mut stream,
        &protocol::ResponseEnvelope::success(
            hello.id,
            protocol::HelloResult {
                provider_id: id("test-provider"),
                provider_name: "Test Provider".into(),
                negotiated_version: protocol::Version,
            },
        )
        .with_capabilities([protocol::DURABLE_NOTICES_CAPABILITY]),
    );

    let mut next = String::new();
    assert_eq!(
        reader.read_line(&mut next).unwrap(),
        0,
        "identity failure did not stop before durable subscription: {next}"
    );
    true
}

fn serve_initial_durable_snapshot(
    listener: &UnixListener,
    snapshot: protocol::SnapshotResult,
    replay: Option<protocol::EventEnvelope>,
) -> (UnixStream, BufReader<UnixStream>, protocol::OpaqueId) {
    let (mut stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let hello: protocol::RequestEnvelope = read_frame(&mut reader);
    let protocol::ProviderRequest::Hello(params) = hello.request else {
        panic!("first provider request was not hello");
    };
    assert_eq!(params.token.expose(), "runtime-test-token");
    write_frame(
        &mut stream,
        &protocol::ResponseEnvelope::success(
            hello.id,
            protocol::HelloResult {
                provider_id: id("test-provider"),
                provider_name: "Test Provider".into(),
                negotiated_version: protocol::Version,
            },
        )
        .with_capabilities([
            protocol::DURABLE_NOTICES_CAPABILITY,
            protocol::MACHINE_LIFECYCLE_CAPABILITY,
            protocol::WORKSPACE_LIFECYCLE_CAPABILITY,
            protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY,
        ]),
    );

    let subscribe: protocol::RequestEnvelope = read_frame(&mut reader);
    let protocol::ProviderRequest::SubscribeNotices(params) = subscribe.request else {
        panic!("durable notice subscription did not precede the initial snapshot");
    };
    if let Some(event) = replay {
        write_frame(&mut stream, &event);
    }
    write_frame(
        &mut stream,
        &protocol::ResponseEnvelope::success(
            subscribe.id,
            protocol::SubscribeNoticesResult { sequence: 0 },
        ),
    );

    let request: protocol::RequestEnvelope = read_frame(&mut reader);
    assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
    write_frame(&mut stream, &protocol::ResponseEnvelope::success(request.id, snapshot.clone()));
    serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &snapshot);
    (stream, reader, params.consumer_id)
}

fn machine_lifecycle_snapshot(
    snapshot: &protocol::SnapshotResult,
) -> protocol::MachineLifecycleSnapshotResult {
    protocol::MachineLifecycleSnapshotResult {
        revision: snapshot.revision,
        scope_id: snapshot.selected_scope_id.clone(),
        machines: snapshot
            .machines
            .iter()
            .map(|machine| protocol::MachineLifecycleDescriptor {
                id: machine.id.clone(),
                display_name: machine.display_name.clone(),
                status: protocol::MachineLifecycleStatus::Active,
                version: snapshot.revision,
                recoverable_until: None,
                capabilities: protocol::MachineLifecycleCapabilities {
                    rename: true,
                    delete: true,
                    restore: false,
                    purge: false,
                },
            })
            .collect(),
    }
}

fn serve_machine_lifecycle_snapshot(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    snapshot: &protocol::SnapshotResult,
) {
    let request: protocol::RequestEnvelope = read_frame(reader);
    assert!(matches!(
        &request.request,
        protocol::ProviderRequest::MachineLifecycleSnapshot(params)
            if params.scope_id == snapshot.selected_scope_id
    ));
    write_frame(
        stream,
        &protocol::ResponseEnvelope::success(request.id, machine_lifecycle_snapshot(snapshot)),
    );
}

fn snapshot(
    revision: u64,
    machine_name: &str,
    status: protocol::MachineStatus,
) -> protocol::SnapshotResult {
    protocol::SnapshotResult {
        revision,
        scopes: vec![protocol::ScopeDescriptor {
            id: id("personal"),
            display_name: "Personal".into(),
            kind: protocol::ScopeKind::Personal,
            can_admin: false,
        }],
        selected_scope_id: id("personal"),
        machines: vec![protocol::MachineDescriptor {
            id: id("machine-1"),
            display_name: machine_name.into(),
            subtitle: "cloud".into(),
            status,
            connectable: false,
            workspace_create: protocol::WorkspaceCreatePolicy::Session,
            platform: None,
            capabilities: Vec::new(),
        }],
        selected_machine_id: Some(id("machine-1")),
        capabilities: protocol::ProviderCapabilities {
            create_machine: true,
            connect_external_machine: false,
        },
        actions: vec![protocol::ProviderAction {
            id: id("billing"),
            label: format!("Billing revision {revision}"),
            target: protocol::ProviderActionTarget::Scope,
            destructive: false,
            fields: Vec::new(),
        }],
        notice: None,
    }
}

fn provider_managed_snapshot(revision: u64) -> protocol::SnapshotResult {
    let mut catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
    catalog.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
        default_mode: protocol::WorkspaceCreateMode::Isolated,
        modes: vec![protocol::WorkspaceCreateMode::Isolated],
    };
    catalog
}

fn active_workspace_snapshot(revision: u64) -> protocol::WorkspaceSnapshotResult {
    protocol::WorkspaceSnapshotResult {
        revision,
        machine_id: id("machine-1"),
        workspaces: vec![protocol::WorkspaceLifecycleDescriptor {
            id: id("workspace-1"),
            display_name: "Before".into(),
            mode: protocol::WorkspaceCreateMode::Isolated,
            status: protocol::WorkspaceLifecycleStatus::Active,
            version: 1,
            recoverable_until: None,
            capabilities: protocol::WorkspaceLifecycleCapabilities {
                rename: true,
                delete: true,
                restore: false,
                purge: false,
            },
        }],
    }
}

fn serve_workspace_snapshot(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    snapshot: &protocol::WorkspaceSnapshotResult,
) {
    let request: protocol::RequestEnvelope = read_frame(reader);
    assert!(matches!(
        &request.request,
        protocol::ProviderRequest::WorkspaceSnapshot(params)
            if params.machine_id == snapshot.machine_id
    ));
    write_frame(stream, &protocol::ResponseEnvelope::success(request.id, snapshot.clone()));
}

fn serve_runtime_refresh(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    catalog: &protocol::SnapshotResult,
    workspace: Option<&protocol::WorkspaceSnapshotResult>,
) {
    let refresh: protocol::RequestEnvelope = read_frame(reader);
    assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
    write_frame(stream, &protocol::ResponseEnvelope::success(refresh.id, catalog.clone()));
    serve_machine_lifecycle_snapshot(stream, reader, catalog);
    if let Some(workspace) = workspace {
        serve_workspace_snapshot(stream, reader, workspace);
    }
}

#[derive(Clone, Copy, Debug)]
enum AcceptedMutationKind {
    CreateMachine,
    RenameMachine,
    DeleteMachine,
    RestoreMachine,
    PurgeMachine,
    CreateIsolatedWorkspace,
    CreateHostWorkspace,
    RestoreWorkspace,
    PurgeWorkspace,
    InvokeAction,
}

impl AcceptedMutationKind {
    const ALL: [Self; 10] = [
        Self::CreateMachine,
        Self::RenameMachine,
        Self::DeleteMachine,
        Self::RestoreMachine,
        Self::PurgeMachine,
        Self::CreateIsolatedWorkspace,
        Self::CreateHostWorkspace,
        Self::RestoreWorkspace,
        Self::PurgeWorkspace,
        Self::InvokeAction,
    ];
}

fn accepted_mutation_request(kind: AcceptedMutationKind, machine: MachineKey) -> MachineRequest {
    match kind {
        AcceptedMutationKind::CreateMachine => MachineRequest::Create,
        AcceptedMutationKind::RenameMachine => MachineRequest::RenameManagedMachine {
            machine,
            expected_version: 1,
            name: "Renamed".into(),
        },
        AcceptedMutationKind::DeleteMachine => {
            MachineRequest::DeleteManagedMachine { machine, expected_version: 1 }
        }
        AcceptedMutationKind::RestoreMachine => {
            MachineRequest::RestoreManagedMachine { machine, expected_version: 1 }
        }
        AcceptedMutationKind::PurgeMachine => {
            MachineRequest::PurgeManagedMachine { machine, expected_version: 1 }
        }
        AcceptedMutationKind::CreateIsolatedWorkspace => {
            MachineRequest::CreateManagedIsolatedWorkspace(machine)
        }
        AcceptedMutationKind::CreateHostWorkspace => {
            MachineRequest::CreateManagedHostWorkspace(machine)
        }
        AcceptedMutationKind::RestoreWorkspace => MachineRequest::RestoreManagedWorkspace {
            machine,
            workspace_id: "workspace-1".into(),
            expected_version: 1,
        },
        AcceptedMutationKind::PurgeWorkspace => MachineRequest::PurgeManagedWorkspace {
            machine,
            workspace_id: "workspace-1".into(),
            expected_version: 1,
        },
        AcceptedMutationKind::InvokeAction => MachineRequest::InvokeProviderAction {
            action_id: "billing".into(),
            values: BTreeMap::new(),
            machine_id: None,
            workspace_id: None,
        },
    }
}

/// Answers one accepted mutation and returns the `mutation_id` it carried.
fn serve_accepted_mutation(
    kind: AcceptedMutationKind,
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
) -> protocol::OpaqueId {
    let mutation: protocol::RequestEnvelope = read_frame(reader);
    let request_id = mutation.id;
    let mutation_id = sent_mutation_id(&mutation.request);
    match (kind, mutation.request) {
        (AcceptedMutationKind::CreateMachine, protocol::ProviderRequest::CreateMachine(_)) => {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::CreateMachineResult {
                        machine_id: id("created-machine"),
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                    },
                ),
            );
        }
        (AcceptedMutationKind::RenameMachine, protocol::ProviderRequest::RenameMachine(params))
            if params.display_name == "Renamed" =>
        {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::MachineMutationResult {
                        machine_id: id("machine-1"),
                        version: 2,
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                    },
                ),
            );
        }
        (AcceptedMutationKind::DeleteMachine, protocol::ProviderRequest::DeleteMachine(_))
        | (AcceptedMutationKind::RestoreMachine, protocol::ProviderRequest::RestoreMachine(_))
        | (AcceptedMutationKind::PurgeMachine, protocol::ProviderRequest::PurgeMachine(_)) => {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::MachineMutationResult {
                        machine_id: id("machine-1"),
                        version: 2,
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                    },
                ),
            );
        }
        (
            AcceptedMutationKind::CreateIsolatedWorkspace
            | AcceptedMutationKind::CreateHostWorkspace,
            protocol::ProviderRequest::CreateWorkspace(_),
        ) => {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::CreateWorkspaceResult {
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                    },
                ),
            );
        }
        (
            AcceptedMutationKind::RestoreWorkspace,
            protocol::ProviderRequest::RestoreWorkspace(_),
        )
        | (AcceptedMutationKind::PurgeWorkspace, protocol::ProviderRequest::PurgeWorkspace(_)) => {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::WorkspaceMutationResult {
                        workspace_id: id("workspace-1"),
                        version: 2,
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                    },
                ),
            );
        }
        (AcceptedMutationKind::InvokeAction, protocol::ProviderRequest::InvokeAction(_)) => {
            write_frame(
                stream,
                &protocol::ResponseEnvelope::success(
                    request_id,
                    protocol::InvokeActionResult {
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: format!("accepted {kind:?}"),
                        }),
                        url: Some("https://example.com/accepted".into()),
                        selected_scope_id: None,
                        selected_machine_id: None,
                    },
                ),
            );
        }
        (_, request) => panic!("unexpected request for {kind:?}: {request:?}"),
    }
    mutation_id
}

#[test]
fn every_accepted_provider_mutation_survives_followup_refresh_failure() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server_catalog = catalog;
    let server_workspace = workspace;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);
        for kind in AcceptedMutationKind::ALL {
            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_catalog,
                Some(&server_workspace),
            );
            serve_accepted_mutation(kind, &mut stream, &mut reader);
            let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                    failed_refresh.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: format!("refresh failed after accepted {kind:?}"),
                        retryable: true,
                    },
                ),
            );
        }
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
    let mut rejected = Vec::new();
    for kind in AcceptedMutationKind::ALL {
        if matches!(kind, AcceptedMutationKind::RenameMachine) {
            install_test_connection(&mut runtime, "open-machine", "machine-1", false);
        }
        match runtime.perform_request(accepted_mutation_request(kind, machine)) {
            Ok(result) => {
                assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
                assert!(
                    result
                        .ui
                        .notice
                        .as_deref()
                        .is_some_and(|notice| notice.contains("refresh failed after accepted")),
                    "accepted {kind:?} did not surface its refresh failure"
                );
                assert!(
                    result
                        .ui
                        .notice
                        .as_deref()
                        .is_some_and(|notice| notice.contains(&format!("accepted {kind:?}"))),
                    "accepted {kind:?} lost its provider notice"
                );
                if matches!(kind, AcceptedMutationKind::InvokeAction) {
                    assert!(
                        result.ui.notice.as_deref().is_some_and(|notice| {
                            notice.contains("https://example.com/accepted")
                        }),
                        "accepted provider action lost its URL"
                    );
                }
                if matches!(kind, AcceptedMutationKind::RenameMachine) {
                    assert_eq!(result.session_label.as_deref(), Some("Renamed"));
                }
                if matches!(kind, AcceptedMutationKind::DeleteMachine) {
                    assert!(result.replacement.is_none());
                }
                if matches!(kind, AcceptedMutationKind::CreateMachine) {
                    assert_eq!(
                        runtime
                            .accepted_selection
                            .as_ref()
                            .and_then(|selection| selection.machine_id.as_ref())
                            .map(protocol::OpaqueId::as_str),
                        Some("created-machine")
                    );
                }
            }
            Err(error) => rejected.push(format!("{kind:?}: {error}")),
        }
        runtime.open = None;
    }
    drop(runtime);
    server.join().unwrap();

    assert!(
        rejected.is_empty(),
        "durably accepted mutations were reported as failed:\n{}",
        rejected.join("\n")
    );
}

#[test]
fn accepted_create_selection_survives_workspace_refresh_failure() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let initial = provider_managed_snapshot(1);
    let initial_workspace = active_workspace_snapshot(1);
    let mut created = initial.clone();
    created.revision = 2;
    let mut created_machine = created.machines[0].clone();
    created_machine.id = id("created-machine");
    created_machine.display_name = "Created".into();
    created.machines.push(created_machine);
    let created_workspace = protocol::WorkspaceSnapshotResult {
        revision: 2,
        machine_id: id("created-machine"),
        workspaces: Vec::new(),
    };
    let server_initial = initial.clone();
    let server_created = created.clone();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_initial.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &initial_workspace);
        serve_runtime_refresh(&mut stream, &mut reader, &server_initial, Some(&initial_workspace));

        let create: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(create.request, protocol::ProviderRequest::CreateMachine(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                create.id,
                protocol::CreateMachineResult {
                    machine_id: id("created-machine"),
                    revision: 2,
                    notice: Some(protocol::ProviderNotice {
                        level: protocol::NoticeLevel::Info,
                        message: "create accepted".into(),
                    }),
                },
            ),
        );

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, server_created.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_created);
        let workspace: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &workspace.request,
            protocol::ProviderRequest::WorkspaceSnapshot(params)
                if params.machine_id == id("created-machine")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::WorkspaceSnapshotResult>::failure(
                workspace.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "created workspace refresh failed".into(),
                    retryable: true,
                },
            ),
        );

        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_created.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &initial_workspace);
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_created);
        serve_workspace_snapshot(&mut stream, &mut reader, &created_workspace);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let result = runtime.perform_request(MachineRequest::Create).unwrap();
    assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
    assert_eq!(runtime.snapshot, initial, "failed install mixed provider state");
    assert!(result.ui.notice.as_deref().is_some_and(|notice| {
        notice.contains("create accepted") && notice.contains("created workspace refresh failed")
    }));
    assert_eq!(
        runtime
            .accepted_selection
            .as_ref()
            .and_then(|selection| selection.machine_id.as_ref())
            .map(protocol::OpaqueId::as_str),
        Some("created-machine")
    );

    runtime.reconnect_control().unwrap();
    assert_eq!(runtime.snapshot.selected_machine_id, Some(id("created-machine")));
    assert_eq!(
        runtime.workspace_snapshot.as_ref().map(|snapshot| &snapshot.machine_id),
        Some(&id("created-machine"))
    );
    assert!(runtime.accepted_selection.is_none());
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn accepted_action_selection_and_messages_survive_scope_refresh_failure() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut personal = provider_managed_snapshot(1);
    personal.scopes.push(protocol::ScopeDescriptor {
        id: id("team-1"),
        display_name: "Team".into(),
        kind: protocol::ScopeKind::Team,
        can_admin: true,
    });
    let personal_workspace = active_workspace_snapshot(1);
    let mut team = personal.clone();
    team.revision = 2;
    team.selected_scope_id = id("team-1");
    team.machines[0].id = id("team-default");
    team.machines[0].display_name = "Team default".into();
    let mut selected_machine = team.machines[0].clone();
    selected_machine.id = id("team-selected");
    selected_machine.display_name = "Team selected".into();
    team.machines.push(selected_machine);
    team.selected_machine_id = Some(id("team-default"));
    let selected_workspace = protocol::WorkspaceSnapshotResult {
        revision: 2,
        machine_id: id("team-selected"),
        workspaces: Vec::new(),
    };
    let server_personal = personal.clone();
    let server_team = team.clone();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_personal.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &personal_workspace);
        serve_runtime_refresh(
            &mut stream,
            &mut reader,
            &server_personal,
            Some(&personal_workspace),
        );

        let action: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(action.request, protocol::ProviderRequest::InvokeAction(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                action.id,
                protocol::InvokeActionResult {
                    revision: 2,
                    notice: Some(protocol::ProviderNotice {
                        level: protocol::NoticeLevel::Info,
                        message: "action accepted".into(),
                    }),
                    url: Some("https://example.com/action".into()),
                    selected_scope_id: Some(id("team-1")),
                    selected_machine_id: Some(id("team-selected")),
                },
            ),
        );
        let failed_select: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &failed_select.request,
            protocol::ProviderRequest::SelectScope(params)
                if params.scope_id == id("team-1")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::SelectScopeResult>::failure(
                failed_select.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "team scope refresh failed".into(),
                    retryable: true,
                },
            ),
        );

        let select: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &select.request,
            protocol::ProviderRequest::SelectScope(params)
                if params.scope_id == id("team-1")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                select.id,
                protocol::SelectScopeResult { snapshot: server_team.clone() },
            ),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_team);
        serve_workspace_snapshot(&mut stream, &mut reader, &selected_workspace);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let result = runtime
        .perform_request(MachineRequest::InvokeProviderAction {
            action_id: "billing".into(),
            values: BTreeMap::new(),
            machine_id: None,
            workspace_id: None,
        })
        .unwrap();
    assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
    assert_eq!(runtime.snapshot, personal, "failed scope install mixed provider state");
    assert!(result.ui.notice.as_deref().is_some_and(|notice| {
        notice.contains("action accepted")
            && notice.contains("https://example.com/action")
            && notice.contains("team scope refresh failed")
    }));

    runtime.refresh().unwrap();
    assert_eq!(runtime.snapshot.selected_scope_id, id("team-1"));
    assert_eq!(runtime.snapshot.selected_machine_id, Some(id("team-selected")));
    assert_eq!(
        runtime.workspace_snapshot.as_ref().map(|snapshot| &snapshot.machine_id),
        Some(&id("team-selected"))
    );
    assert!(runtime.accepted_selection.is_none());
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn accepted_open_machine_delete_retires_session_when_refresh_fails() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = snapshot(1, "Deleted machine", protocol::MachineStatus::Running);
    let server_catalog = catalog;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);

        let delete: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(delete.request, protocol::ProviderRequest::DeleteMachine(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                delete.id,
                protocol::MachineMutationResult {
                    machine_id: id("machine-1"),
                    version: 2,
                    revision: 2,
                    notice: None,
                },
            ),
        );
        let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                failed_refresh.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "delete refresh failed".into(),
                    retryable: true,
                },
            ),
        );

        let close: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("deleted-open")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close.id,
                protocol::CloseMachineResult { revision: 3 },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
    install_test_connection(&mut runtime, "deleted-open", "machine-1", true);
    let result = runtime
        .perform_request(MachineRequest::DeleteManagedMachine { machine, expected_version: 1 })
        .unwrap();
    assert!(result.replacement.is_some());
    assert!(result.restart_updates);
    assert!(!result.ui.session_available);
    assert!(runtime.pending.as_ref().is_some_and(|pending| pending.retire_open_on_abort));

    runtime.abort_replacement();
    assert!(runtime.open.is_none(), "aborted preparation retained a deleted session");
    drop(result);
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn accepted_scope_selection_survives_lifecycle_refresh_failure() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server_catalog = catalog;
    let server_workspace = workspace;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);
        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, Some(&server_workspace));

        let select: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &select.request,
            protocol::ProviderRequest::SelectScope(params)
                if params.scope_id == id("personal")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                select.id,
                protocol::SelectScopeResult { snapshot: server_catalog },
            ),
        );
        let lifecycle: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            lifecycle.request,
            protocol::ProviderRequest::MachineLifecycleSnapshot(_)
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::MachineLifecycleSnapshotResult>::failure(
                lifecycle.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "scope lifecycle refresh failed after acceptance".into(),
                    retryable: true,
                },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let result = runtime
        .perform_request(MachineRequest::SelectProviderScope("personal".into()))
        .expect("an accepted scope selection must survive a lifecycle refresh error");
    assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
    assert!(
        result
            .ui
            .notice
            .as_deref()
            .is_some_and(|notice| notice.contains("scope lifecycle refresh failed"))
    );
    drop(runtime);
    server.join().unwrap();
}

fn assert_accepted_workspace_mutation_survives_refresh_error(delete: bool) {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server_catalog = catalog;
    let server_workspace = workspace;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, server_catalog.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_catalog);
        serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);

        let mutation: protocol::RequestEnvelope = read_frame(&mut reader);
        if delete {
            assert!(matches!(
                mutation.request,
                protocol::ProviderRequest::DeleteWorkspace(ref params)
                    if params.workspace_id == id("workspace-1")
            ));
        } else {
            assert!(matches!(
                mutation.request,
                protocol::ProviderRequest::RenameWorkspace(ref params)
                    if params.workspace_id == id("workspace-1")
                        && params.display_name == "After"
            ));
        }
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                mutation.id,
                protocol::WorkspaceMutationResult {
                    workspace_id: id("workspace-1"),
                    version: 2,
                    revision: 2,
                    notice: None,
                },
            ),
        );

        let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                failed_refresh.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "refresh failed after commit".into(),
                    retryable: true,
                },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
    let request = if delete {
        MachineRequest::DeleteManagedWorkspace {
            machine,
            workspace_id: "workspace-1".into(),
            expected_version: 1,
        }
    } else {
        MachineRequest::RenameManagedWorkspace {
            machine,
            workspace_id: "workspace-1".into(),
            expected_version: 1,
            name: "After".into(),
        }
    };

    let result = runtime
        .perform_request(request)
        .expect("an accepted workspace mutation must survive a refresh error");
    match (delete, result.session_mutation) {
        (false, Some(ManagedWorkspaceSessionMutation::Rename { workspace_key, name })) => {
            assert_eq!(workspace_key, "workspace-1");
            assert_eq!(name, "After");
        }
        (true, Some(ManagedWorkspaceSessionMutation::Close { workspace_key })) => {
            assert_eq!(workspace_key, "workspace-1");
        }
        _ => panic!("accepted provider mutation did not reach the nested mux"),
    }
    assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
    assert!(
        result
            .ui
            .notice
            .as_deref()
            .is_some_and(|notice| notice.contains("refresh failed after commit"))
    );
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn accepted_workspace_rename_survives_refresh_error() {
    assert_accepted_workspace_mutation_survives_refresh_error(false);
}

#[test]
fn accepted_workspace_delete_survives_refresh_error() {
    assert_accepted_workspace_mutation_survives_refresh_error(true);
}

#[test]
fn legacy_v1_provider_connects_without_receiving_lifecycle_requests() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let hello: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                hello.id,
                protocol::HelloResult {
                    provider_id: id("legacy-provider"),
                    provider_name: "Legacy Provider".into(),
                    negotiated_version: protocol::Version,
                },
            ),
        );

        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        let mut legacy_snapshot = snapshot(1, "Legacy machine", protocol::MachineStatus::Running);
        legacy_snapshot.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![protocol::WorkspaceCreateMode::Isolated],
        };
        write_frame(&mut stream, &protocol::ResponseEnvelope::success(request.id, legacy_snapshot));

        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Ok(0) => panic!("provider client disconnected during legacy fallback"),
            Ok(_) => panic!("legacy provider received an unsupported request: {unexpected}"),
            Err(error) => panic!("legacy provider read failed: {error}"),
        }
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let ui = runtime.ui_state_for_open_connection();
    assert!(ui.managed_machines().is_empty());
    assert!(ui.managed_workspaces().is_empty());

    server.join().unwrap();
}

#[test]
fn presentation_translation_preserves_provider_permissions_and_fields() {
    let snapshot = protocol::SnapshotResult {
        revision: 1,
        scopes: vec![protocol::ScopeDescriptor {
            id: id("team-1"),
            display_name: "Acme".into(),
            kind: protocol::ScopeKind::Team,
            can_admin: true,
        }],
        selected_scope_id: id("team-1"),
        machines: Vec::new(),
        selected_machine_id: None,
        capabilities: protocol::ProviderCapabilities {
            create_machine: true,
            connect_external_machine: false,
        },
        actions: vec![
            protocol::ProviderAction {
                id: id("invite"),
                label: "Invite member".into(),
                target: protocol::ProviderActionTarget::Scope,
                destructive: false,
                fields: vec![protocol::ActionField {
                    id: "email".into(),
                    kind: protocol::ActionFieldKind::Email,
                    label: "Email".into(),
                    required: true,
                    max_length: Some(254),
                    minimum: None,
                    maximum: None,
                    placeholder: Some("person@example.com".into()),
                }],
            },
            protocol::ProviderAction {
                id: id("future-action"),
                label: "Future action".into(),
                target: protocol::ProviderActionTarget::Unsupported,
                destructive: false,
                fields: Vec::new(),
            },
        ],
        notice: None,
    };

    let presentation = provider_presentation(&snapshot);
    assert!(presentation.scopes[0].can_admin);
    assert_eq!(presentation.selected_scope().unwrap().name, "Acme");
    assert_eq!(presentation.actions.len(), 1);
    assert_eq!(presentation.actions[0].fields[0].kind, ProviderActionFieldKind::Email);
}

#[test]
fn targeted_actions_are_negotiated_before_the_initial_snapshot() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut targeted = snapshot(1, "Machine", protocol::MachineStatus::Running);
    targeted.actions[0].target = protocol::ProviderActionTarget::SelectedWorkspace;
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let hello: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                hello.id,
                protocol::HelloResult {
                    provider_id: id("test-provider"),
                    provider_name: "Test Provider".into(),
                    negotiated_version: protocol::Version,
                },
            )
            .with_capabilities([
                protocol::CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY,
                protocol::DURABLE_NOTICES_CAPABILITY,
                protocol::MACHINE_LIFECYCLE_CAPABILITY,
            ]),
        );

        let negotiation: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::NegotiateClientCapabilities(params) = negotiation.request
        else {
            panic!("client capability negotiation did not immediately follow hello");
        };
        assert_eq!(
            params.capabilities.join(","),
            "provider-action-targets-v1,connection-progress-v1,machine-metadata-v1"
        );
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                negotiation.id,
                protocol::NegotiateClientCapabilitiesResult {
                    capabilities: vec![
                        protocol::PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string(),
                    ],
                },
            ),
        );

        let subscribe: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(subscribe.request, protocol::ProviderRequest::SubscribeNotices(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                subscribe.id,
                protocol::SubscribeNoticesResult { sequence: 0 },
            ),
        );

        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(request.id, targeted.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &targeted);
        finished.recv_timeout(Duration::from_secs(1)).unwrap();
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    assert_eq!(
        runtime.snapshot.actions[0].target,
        protocol::ProviderActionTarget::SelectedWorkspace
    );
    finish.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn provider_connect_footer_requires_negotiated_support() {
    let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
    snapshot.capabilities.connect_external_machine = true;
    let lifecycle = machine_lifecycle_snapshot(&snapshot);
    let keys = Arc::new(Mutex::new(KeyRegistry {
        by_id: HashMap::new(),
        by_key: HashMap::new(),
        next: 1,
    }));

    let ui = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);

    assert!(
        !ui.snapshot.capabilities.connect,
        "a snapshot bit cannot expose an operation absent from hello negotiation"
    );

    let negotiated = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, true);
    assert!(negotiated.snapshot.capabilities.connect);
}

#[test]
fn negotiated_external_connect_routes_opaque_input_to_provider_selection_path() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
    initial.capabilities.connect_external_machine = true;
    let mut enrolled = initial.clone();
    enrolled.revision = 2;
    enrolled.machines.push(protocol::MachineDescriptor {
        id: id("paired-machine"),
        display_name: "Paired mini".into(),
        subtitle: "external".into(),
        status: protocol::MachineStatus::Running,
        connectable: true,
        workspace_create: protocol::WorkspaceCreatePolicy::Session,
        platform: None,
        capabilities: Vec::new(),
    });
    enrolled.selected_machine_id = Some(id("paired-machine"));
    let server_initial = initial;
    let server_enrolled = enrolled.clone();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            server_initial.clone(),
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        serve_runtime_refresh(&mut stream, &mut reader, &server_initial, None);

        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request else {
            panic!("connect request did not use the provider protocol");
        };
        assert_eq!(params.scope_id, id("personal"));
        assert_eq!(params.specifier.expose(), "PAIR 4J7K;$(opaque)");
        assert!(params.mutation_id.as_str().starts_with("cmux-"));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                request.id,
                protocol::ConnectExternalMachineResult {
                    machine_id: id("paired-machine"),
                    revision: 2,
                    notice: Some(protocol::ProviderNotice {
                        level: protocol::NoticeLevel::Info,
                        message: "Paired machine enrolled".into(),
                    }),
                },
            ),
        );
        serve_runtime_refresh(&mut stream, &mut reader, &server_enrolled, None);
        finished.recv().unwrap();
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        Some(MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START)),
        false,
    );
    let result = controller.perform_request(provider_connect("PAIR 4J7K;$(opaque)")).unwrap();

    let paired =
        result.ui.snapshot.machines.iter().find(|machine| machine.id == "paired-machine").unwrap();
    assert_eq!(result.ui.snapshot.active, Some(paired.key));
    assert_eq!(result.ui.request, Some(MachineRequest::Switch(paired.key)));
    assert_eq!(result.ui.notice.as_deref(), Some("Paired machine enrolled"));
    assert!(
        result.ui.snapshot.machines.iter().all(|machine| !machine.id.starts_with("ssh:")),
        "provider-owned input leaked into the client-local SSH catalog"
    );

    finish.send(()).unwrap();
    controller.close();
    server.join().unwrap();
}

#[test]
fn accepted_external_connect_reconnect_keeps_provider_switch_over_local_session() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
    initial.capabilities.connect_external_machine = true;
    let mut enrolled = initial.clone();
    enrolled.revision = 2;
    enrolled.machines.push(protocol::MachineDescriptor {
        id: id("paired-machine"),
        display_name: "Paired mini".into(),
        subtitle: "external".into(),
        status: protocol::MachineStatus::Running,
        connectable: false,
        workspace_create: protocol::WorkspaceCreatePolicy::Session,
        platform: None,
        capabilities: Vec::new(),
    });
    enrolled.selected_machine_id = Some(id("paired-machine"));
    let server_initial = initial;
    let server_enrolled = enrolled;
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_initial.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_initial, None);
            let connect: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                connect.request,
                protocol::ProviderRequest::ConnectExternalMachine(_)
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    connect.id,
                    protocol::ConnectExternalMachineResult {
                        machine_id: id("paired-machine"),
                        revision: 2,
                        notice: None,
                    },
                ),
            );
            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                    refresh.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "accepted pairing refresh failed".into(),
                        retryable: true,
                    },
                ),
            );
        }

        let (_stream, _reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            server_enrolled,
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        finished.recv().unwrap();
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        Some(MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START)),
        false,
    );
    let accepted = controller.perform_request(provider_connect("PAIR 4J7K")).unwrap();
    assert_eq!(accepted.ui.request, Some(MachineRequest::ReconnectProvider));

    let reconnected = controller.perform_request(MachineRequest::ReconnectProvider).unwrap();
    let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
    assert_eq!(reconnected.ui.snapshot.active, Some(local_key));
    assert!(reconnected.ui.request.is_none());

    controller.provider.snapshot.machines[1].connectable = true;
    let provider_update = controller.provider.ui_state_for_open_connection();
    let available = controller.merge_local_ui(provider_update);
    let paired = reconnected
        .ui
        .snapshot
        .machines
        .iter()
        .find(|machine| machine.id == "paired-machine")
        .unwrap();
    assert_eq!(available.snapshot.active, Some(paired.key));
    assert_eq!(available.request, Some(MachineRequest::Switch(paired.key)));

    finish.send(()).unwrap();
    controller.close();
    server.join().unwrap();
}

#[test]
fn retryable_external_connect_error_reuses_mutation_id() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
    catalog.capabilities.connect_external_machine = true;
    let mut enrolled = catalog.clone();
    enrolled.revision = 2;
    enrolled.selected_machine_id = Some(id("machine-1"));
    enrolled.machines[0].connectable = true;
    let server_catalog = catalog;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            server_catalog.clone(),
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
        let first: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(first_params) = first.request else {
            panic!("first request was not external connect");
        };
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::ConnectExternalMachineResult>::failure(
                first.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "pairing outcome unknown".into(),
                    retryable: true,
                },
            ),
        );

        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
        let retry: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(retry_params) = retry.request else {
            panic!("retry request was not external connect");
        };
        assert_eq!(retry_params.specifier, first_params.specifier);
        assert_eq!(retry_params.mutation_id, first_params.mutation_id);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                retry.id,
                protocol::ConnectExternalMachineResult {
                    machine_id: id("machine-1"),
                    revision: 2,
                    notice: None,
                },
            ),
        );
        serve_runtime_refresh(&mut stream, &mut reader, &enrolled, None);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let Err(first) = runtime.perform_external_connect("PAIR 4J7K".into()) else {
        panic!("retryable provider error unexpectedly completed external connect");
    };
    assert!(first.to_string().contains("pairing outcome unknown"));
    let retry = runtime.perform_external_connect("PAIR 4J7K".into()).unwrap();

    assert!(retry.ui.request.is_some());
    runtime.close();
    server.join().unwrap();
}

#[test]
fn selecting_provider_scope_cancels_ambiguous_external_connect() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut personal = snapshot(1, "Existing", protocol::MachineStatus::Running);
    personal.scopes.push(protocol::ScopeDescriptor {
        id: id("team-1"),
        display_name: "Team".into(),
        kind: protocol::ScopeKind::Team,
        can_admin: true,
    });
    let mut team = personal.clone();
    team.revision = 2;
    team.selected_scope_id = id("team-1");
    let server_personal = personal.clone();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_personal.clone());
        serve_runtime_refresh(&mut stream, &mut reader, &server_personal, None);

        let select: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &select.request,
            protocol::ProviderRequest::SelectScope(params)
                if params.scope_id == id("team-1")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                select.id,
                protocol::SelectScopeResult { snapshot: team.clone() },
            ),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &team);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    runtime.pending_external_connect = Some(PendingExternalConnect {
        scope_id: personal.selected_scope_id,
        specifier: protocol::ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
    });

    runtime.perform_request(MachineRequest::SelectProviderScope("team-1".into())).unwrap();

    assert!(
        runtime.pending_external_connect.is_none(),
        "an accepted scope selection must cancel the old scope's ambiguous connect"
    );
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn capability_revocation_fails_the_presented_provider_route_closed() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
    initial.capabilities.connect_external_machine = true;
    let mut revoked = initial.clone();
    revoked.revision = 2;
    revoked.capabilities.connect_external_machine = false;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            initial,
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        serve_runtime_refresh(&mut stream, &mut reader, &revoked, None);
        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Ok(0) => {}
            Ok(_) => panic!("revoked provider received connect input: {unexpected}"),
            Err(error) => panic!("provider read failed: {error}"),
        }
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );
    let Err(error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
        panic!("revoked provider unexpectedly handled external connect");
    };

    assert_eq!(
        error.to_string(),
        localization::catalog().sidebar.machine_provider_external_connect_unsupported
    );
    controller.close();
    server.join().unwrap();
}

#[test]
fn ambiguous_protocol_failure_reuses_external_connect_mutation_id_after_reconnect() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
    catalog.capabilities.connect_external_machine = true;
    let mut enrolled = catalog.clone();
    enrolled.revision = 2;
    enrolled.machines[0].connectable = true;
    let server_catalog = catalog;
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let first_mutation_id = {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_catalog.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request else {
                panic!("first request was not external connect");
            };
            assert_eq!(params.specifier.expose(), "PAIR 4J7K");
            stream.write_all(b"{\"invalid\":}\n").unwrap();
            stream.flush().unwrap();
            params.mutation_id
        };

        let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            server_catalog.clone(),
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request else {
            panic!("retry request was not external connect");
        };
        assert_eq!(params.specifier.expose(), "PAIR 4J7K");
        assert_eq!(params.mutation_id, first_mutation_id);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                request.id,
                protocol::ConnectExternalMachineResult {
                    machine_id: id("machine-1"),
                    revision: enrolled.revision,
                    notice: None,
                },
            ),
        );
        serve_runtime_refresh(&mut stream, &mut reader, &enrolled, None);
        finished.recv().unwrap();
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );
    let Err(first_error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
        panic!("invalid provider response unexpectedly completed external connect");
    };
    assert!(first_error.to_string().contains("protocol error"));
    for unrelated in ["PAIR 9ZZZ", "not a valid local machine"] {
        let Err(error) = controller.perform_request(provider_connect(unrelated)) else {
            panic!("unrelated input discarded an ambiguous external connect");
        };
        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.machine_provider_external_connect_ambiguous
        );
    }
    let Err(retry_while_disconnected) = controller.perform_request(provider_connect("PAIR 4J7K"))
    else {
        panic!("ambiguous connect retry was rerouted while its provider was disconnected");
    };
    assert_eq!(
        retry_while_disconnected.to_string(),
        localization::catalog().sidebar.machine_provider_disconnected
    );
    controller.provider.reconnect_control().unwrap();
    let result = controller.perform_request(provider_connect("PAIR 4J7K")).unwrap();

    let connected =
        result.ui.snapshot.machines.iter().find(|machine| machine.id == "machine-1").unwrap();
    assert_eq!(result.ui.request, Some(MachineRequest::Switch(connected.key)));
    finish.send(()).unwrap();
    controller.close();
    server.join().unwrap();
}

#[test]
fn ambiguous_external_connect_does_not_fall_back_after_capability_revocation() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut supported = snapshot(1, "Existing", protocol::MachineStatus::Running);
    supported.capabilities.connect_external_machine = true;
    let mut revoked = supported.clone();
    revoked.revision = 2;
    revoked.capabilities.connect_external_machine = false;
    let server = thread::spawn(move || {
        {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                supported.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &supported, None);
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                request.request,
                protocol::ProviderRequest::ConnectExternalMachine(_)
            ));
        }

        let (stream, mut reader) =
            serve_initial_snapshot_with_capabilities(&listener, revoked, &[]);
        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Ok(0) => {}
            Ok(_) => panic!("ambiguous retry was rerouted after capability loss: {unexpected}"),
            Err(error) => panic!("provider read failed: {error}"),
        }
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );
    assert!(controller.perform_request(provider_connect("PAIR 4J7K")).is_err());
    controller.provider.reconnect_control().unwrap();

    let Err(error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
        panic!("ambiguous retry fell back after capability revocation");
    };
    assert_eq!(
        error.to_string(),
        localization::catalog().sidebar.machine_provider_external_connect_ambiguous
    );

    controller.close();
    server.join().unwrap();
}

#[test]
fn unnegotiated_external_connect_preserves_client_local_validation() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
    catalog.capabilities.connect_external_machine = true;
    let server_catalog = catalog;
    let server = thread::spawn(move || {
        let (stream, mut reader) = serve_initial_snapshot(&listener, server_catalog);
        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Ok(0) => {}
            Ok(_) => panic!("unnegotiated provider received local SSH input: {unexpected}"),
            Err(error) => panic!("provider read failed: {error}"),
        }
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );
    let Err(error) = controller.perform_request(local_connect("PAIR 4J7K")) else {
        panic!("unnegotiated provider unexpectedly handled local connect input");
    };

    assert_eq!(error.to_string(), "machine address must be a host or user@host without whitespace");
    controller.close();
    server.join().unwrap();
}

#[test]
fn disconnected_provider_external_connect_never_reaches_local_ssh() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (disconnect, disconnect_now) = mpsc::channel();
    let server = thread::spawn(move || {
        let (_stream, _reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            snapshot(1, "Existing", protocol::MachineStatus::Running),
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        disconnect_now.recv().unwrap();
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    disconnect.send(()).unwrap();
    server.join().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while provider.client.is_live() && std::time::Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(!provider.client.is_live(), "provider reader did not observe disconnect");
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );

    let Err(error) = controller.perform_request(provider_connect("ABCD-EFGH")) else {
        panic!("disconnected provider unexpectedly completed external connect");
    };

    assert_eq!(error.to_string(), localization::catalog().sidebar.machine_provider_disconnected);
    controller.close();
}

#[test]
fn provider_disconnect_during_external_connect_refresh_fails_closed() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            snapshot(1, "Existing", protocol::MachineStatus::Running),
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        drop(stream);
    });

    let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let mut controller = ProviderMachineController::for_test(
        provider,
        MachineRuntime::external(Vec::new(), true),
        None,
        false,
    );
    let Err(error) = controller.perform_request(provider_connect("ABCD-EFGH")) else {
        panic!("refresh-disconnected provider unexpectedly handled external connect");
    };

    assert_eq!(error.to_string(), localization::catalog().sidebar.machine_provider_disconnected);
    controller.close();
    server.join().unwrap();
}

#[test]
fn local_overlay_appends_disjoint_machines_and_owns_active_session() {
    let snapshot = snapshot(1, "Cloud machine", protocol::MachineStatus::Running);
    let lifecycle = machine_lifecycle_snapshot(&snapshot);
    let keys = Arc::new(Mutex::new(KeyRegistry {
        by_id: HashMap::new(),
        by_key: HashMap::new(),
        next: 1,
    }));
    let mut provider = machine_ui_state(&snapshot, &lifecycle, None, &keys, false, false);
    let provider_key = provider.snapshot.active.unwrap();
    provider.request = Some(MachineRequest::Switch(provider_key));
    let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
    let mut local = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: local_key,
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            status: MachineStatus::Running,
            platform: None,
            capabilities: Vec::new(),
        }],
        active: Some(local_key),
        capabilities: MachineCapabilities { create: false, connect: true },
    });
    local.set_client_renamable_machines([local_key]);

    let merged = merge_local_machine_ui(provider, &local, Some(local_key));

    assert_eq!(merged.snapshot.machines.len(), 2);
    assert_ne!(provider_key, local_key);
    assert_eq!(merged.snapshot.active, Some(local_key));
    assert_eq!(merged.selected().map(|machine| machine.key), Some(local_key));
    assert!(merged.snapshot.capabilities.connect);
    assert!(merged.session_available);
    assert!(merged.request.is_none(), "provider selection must not evict a local session");
    assert!(merged.provider.is_some(), "provider presentation remains available");
}

#[test]
fn local_overlay_keeps_provider_reconnect_requests_without_losing_session() {
    let mut provider = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    provider.request = Some(MachineRequest::ReconnectProvider);
    let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
    let mut local = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: local_key,
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            status: MachineStatus::Running,
            platform: None,
            capabilities: Vec::new(),
        }],
        active: Some(local_key),
        capabilities: MachineCapabilities::default(),
    });
    local.set_client_renamable_machines([local_key]);

    let merged = merge_local_machine_ui(provider, &local, Some(local_key));

    assert!(matches!(merged.request, Some(MachineRequest::ReconnectProvider)));
    assert!(merged.session_available);
}

#[test]
fn provider_reconnect_replacement_commits_as_provider_active() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (_first_stream, _first_reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Before reconnect", protocol::MachineStatus::Running),
        );
        let mut disconnected = snapshot(2, "After reconnect", protocol::MachineStatus::Sleeping);
        disconnected.machines.clear();
        disconnected.selected_machine_id = None;
        let (_second_stream, _second_reader) = serve_initial_snapshot(&listener, disconnected);
        // Hold both provider streams open until the client is done. No
        // fixed bound: on a loaded host the reconnect alone took 2.9 s,
        // and a test that fails drops `finish`, which ends this wait.
        let _ = finished.recv();
    });
    let connector = Arc::new(UnixProviderConnector::new(socket.path.clone(), token()));
    let state_root = TestStateRoot::create("provider-reconnect");
    let mut controller = ProviderMachineController::connect_with(
        connector,
        Vec::new(),
        false,
        Some(state_root.path.clone()),
    )
    .unwrap();

    let result = controller.perform_request(MachineRequest::ReconnectProvider).unwrap();
    assert!(result.replacement.is_some());
    let committed = controller.commit_replacement(true);

    controller.abort_replacement();
    controller.close();
    finish.send(()).unwrap();
    server.join().unwrap();
    assert!(committed.is_ok(), "provider replacement did not commit: {committed:?}");
    assert_eq!(controller.active_local, None);
}

#[test]
fn reconnect_open_failure_preserves_snapshot_notice() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (_first_stream, _first_reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Before reconnect", protocol::MachineStatus::Running),
        );
        let mut reconnected =
            snapshot(2, "Still provisioning", protocol::MachineStatus::Connecting);
        reconnected.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "provider maintenance".into(),
        });
        let (_second_stream, _second_reader) = serve_initial_snapshot(&listener, reconnected);
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let result = runtime.perform_request(MachineRequest::ReconnectProvider).unwrap();
    let notice = result.ui.notice.as_deref().unwrap();

    finish.send(()).unwrap();
    assert!(notice.contains("provider maintenance"));
    assert!(notice.contains(localization::catalog().sidebar.machine_reconnect_failed));
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn deleting_open_managed_machine_restarts_updates_for_replacement() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let initial = snapshot(1, "Before delete", protocol::MachineStatus::Running);
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, initial);

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let refreshed = snapshot(2, "Before delete", protocol::MachineStatus::Running);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

        let delete: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &delete.request,
            protocol::ProviderRequest::DeleteMachine(params)
                if params.machine_id == id("machine-1") && params.expected_version == 1
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                delete.id,
                protocol::MachineMutationResult {
                    machine_id: id("machine-1"),
                    version: 2,
                    revision: 3,
                    notice: None,
                },
            ),
        );

        let post_delete: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(post_delete.request, protocol::ProviderRequest::Snapshot(_)));
        let mut deleted = snapshot(3, "Deleted", protocol::MachineStatus::Stopped);
        deleted.machines.clear();
        deleted.selected_machine_id = None;
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(post_delete.id, deleted.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &deleted);

        let close: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("deleted-open")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close.id,
                protocol::CloseMachineResult { revision: 4 },
            ),
        );
    });
    let connector = Arc::new(UnixProviderConnector::new(socket.path.clone(), token()));
    let state_root = TestStateRoot::create("provider-delete");
    let mut controller = ProviderMachineController::connect_with(
        connector,
        Vec::new(),
        false,
        Some(state_root.path.clone()),
    )
    .unwrap();
    let machine = key_for_id(&controller.provider.keys, &id("machine-1")).unwrap();
    install_test_connection(&mut controller.provider, "deleted-open", "machine-1", true);

    let result = controller
        .perform_request(MachineRequest::DeleteManagedMachine { machine, expected_version: 1 })
        .unwrap();

    assert!(result.replacement.is_some());
    assert!(result.restart_updates, "replacement retained the deleted machine update stream");
    controller.abort_replacement();
    drop(result);
    controller.close();
    server.join().unwrap();
}

#[test]
fn local_overlay_switches_to_a_real_client_local_mux() {
    let provider_socket = TestProviderSocket::bind();
    let listener = provider_socket.listener();
    let (provider_stop, provider_stopped) = mpsc::channel();
    let provider_server = thread::spawn(move || {
        let _control = serve_initial_snapshot(
            &listener,
            snapshot(1, "Cloud machine", protocol::MachineStatus::Running),
        );
        provider_stopped.recv_timeout(Duration::from_secs(2)).unwrap();
    });
    let local_socket = std::env::temp_dir().join(format!(
        "cmux-local-overlay-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&local_socket);
    let local_listener = UnixListener::bind(&local_socket).unwrap();
    let (local_stop, local_stopped) = mpsc::channel();
    let local_server = thread::spawn(move || {
        let (stream, _) = local_listener.accept().unwrap();
        let mut peer = BufReader::new(stream);
        for expected_command in ["identify", "set-client-info", "subscribe"] {
            let mut line = String::new();
            peer.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], expected_command);
            let data = if expected_command == "identify" {
                json!({
                    "app": "cmux-tui",
                    "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
                    "capabilities": ["browser-pointer-frame-guard-v1"],
                })
            } else {
                Value::Null
            };
            writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": true, "data": data}))
                .unwrap();
        }
        local_stopped.recv_timeout(Duration::from_secs(2)).unwrap();
    });
    let local = MachineRuntime::external(
        vec![
            MachineConfig {
                id: "mini".into(),
                name: "Mini".into(),
                subtitle: "local".into(),
                target: crate::config::MachineTargetConfig::Unix { socket: local_socket.clone() },
            },
            MachineConfig {
                id: "offline".into(),
                name: "Offline".into(),
                subtitle: "local".into(),
                target: crate::config::MachineTargetConfig::Unix {
                    socket: local_socket.with_extension("missing"),
                },
            },
        ],
        true,
    );
    let local_snapshot = local.snapshot_with_active(None);
    let local_key = local_snapshot.machines[0].key;
    let offline_key = local_snapshot.machines[1].key;
    let mut controller = ProviderMachineController::for_test(
        ProviderMachineRuntime::connect(&provider_socket.path, token()).unwrap(),
        local,
        None,
        true,
    );

    let result = controller.perform_request(MachineRequest::Switch(local_key)).unwrap();

    assert!(result.replacement.is_some());
    assert!(result.restart_updates);
    assert_eq!(result.ui.snapshot.active, Some(local_key));
    assert!(result.ui.session_available);
    assert_eq!(controller.active_local, None, "candidate is not active before commit");
    assert!(
        controller.pending_provider_switch,
        "an uncommitted local candidate cannot cancel the pairing handoff"
    );
    controller.commit_replacement(true).unwrap();
    assert_eq!(controller.active_local, Some(local_key));
    assert!(
        !controller.pending_provider_switch,
        "the committed local selection supersedes the automatic pairing handoff"
    );
    let renamed = controller
        .perform_request(MachineRequest::RenameClientMachine {
            machine: local_key,
            name: "Renamed mini".into(),
        })
        .unwrap();
    assert!(renamed.restart_updates);
    assert_eq!(renamed.session_label.as_deref(), Some("Renamed mini"));
    assert_eq!(
        renamed
            .ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.key == local_key)
            .map(|machine| machine.name.as_str()),
        Some("Renamed mini")
    );
    let failed = controller.perform_request(MachineRequest::Switch(offline_key));
    assert!(failed.is_err());
    assert_eq!(
        controller.active_local,
        Some(local_key),
        "a failed candidate must not evict the active session"
    );
    local_stop.send(()).unwrap();
    drop(result);
    controller.close();
    provider_stop.send(()).unwrap();
    provider_server.join().unwrap();
    local_server.join().unwrap();
    let _ = std::fs::remove_file(local_socket);
}

#[test]
fn workspace_policy_translation_preserves_provider_order_and_default() {
    let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
    snapshot.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
        default_mode: protocol::WorkspaceCreateMode::Isolated,
        modes: vec![protocol::WorkspaceCreateMode::Host, protocol::WorkspaceCreateMode::Isolated],
    };
    let keys = Arc::new(Mutex::new(KeyRegistry {
        by_id: HashMap::new(),
        by_key: HashMap::new(),
        next: 1,
    }));

    let machine_lifecycle = machine_lifecycle_snapshot(&snapshot);
    let ui = machine_ui_state(&snapshot, &machine_lifecycle, None, &keys, true, false);

    assert_eq!(
        ui.workspace_creation_policy(),
        Some(WorkspaceCreationPolicy::ProviderOwned {
            default_mode: WorkspaceCreationMode::Isolated,
            modes: vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
        })
    );
}

#[test]
fn workspace_snapshot_translation_preserves_stable_identity_and_capabilities() {
    let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
    snapshot.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
        default_mode: protocol::WorkspaceCreateMode::Isolated,
        modes: vec![protocol::WorkspaceCreateMode::Isolated],
    };
    let lifecycle = protocol::WorkspaceSnapshotResult {
        revision: 9,
        machine_id: id("machine-1"),
        workspaces: vec![protocol::WorkspaceLifecycleDescriptor {
            id: id("workspace-uuid"),
            display_name: "recover me".into(),
            mode: protocol::WorkspaceCreateMode::Host,
            status: protocol::WorkspaceLifecycleStatus::Recoverable,
            version: 12,
            recoverable_until: Some("2030-01-02T03:04:05Z".into()),
            capabilities: protocol::WorkspaceLifecycleCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        }],
    };
    let keys = Arc::new(Mutex::new(KeyRegistry {
        by_id: HashMap::new(),
        by_key: HashMap::new(),
        next: 1,
    }));

    let machine_lifecycle = machine_lifecycle_snapshot(&snapshot);
    let ui = machine_ui_state(&snapshot, &machine_lifecycle, Some(&lifecycle), &keys, true, false);

    assert_eq!(
        ui.managed_workspaces(),
        &[ManagedWorkspaceDescriptor {
            id: "workspace-uuid".into(),
            name: "recover me".into(),
            mode: WorkspaceCreationMode::Host,
            status: ManagedWorkspaceStatus::Recoverable,
            version: 12,
            recoverable_until: Some("2030-01-02T03:04:05Z".into()),
            capabilities: ManagedWorkspaceCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        }]
    );
}

#[test]
fn machine_lifecycle_translation_keeps_tombstone_identity_version_and_capabilities() {
    let snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
    let mut lifecycle = machine_lifecycle_snapshot(&snapshot);
    lifecycle.machines.push(protocol::MachineLifecycleDescriptor {
        id: id("deleted-machine-uuid"),
        display_name: "quiet-forest".into(),
        status: protocol::MachineLifecycleStatus::Recoverable,
        version: 12,
        recoverable_until: Some("2030-01-02T03:04:05Z".into()),
        capabilities: protocol::MachineLifecycleCapabilities {
            rename: false,
            delete: false,
            restore: true,
            purge: true,
        },
    });
    let keys = Arc::new(Mutex::new(KeyRegistry {
        by_id: HashMap::new(),
        by_key: HashMap::new(),
        next: 1,
    }));

    let first = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);
    let tombstone_key = first.snapshot.machines[1].key;
    assert_eq!(first.snapshot.machines[1].id, "deleted-machine-uuid");
    assert_eq!(
        first.managed_machine(tombstone_key),
        Some(&ManagedMachineDescriptor {
            key: tombstone_key,
            id: "deleted-machine-uuid".into(),
            name: "quiet-forest".into(),
            status: ManagedMachineStatus::Recoverable,
            version: 12,
            recoverable_until: Some("2030-01-02T03:04:05Z".into()),
            capabilities: ManagedMachineCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        })
    );

    lifecycle.machines[1].display_name = "renamed tombstone".into();
    lifecycle.machines[1].version = 13;
    let refreshed = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);
    assert_eq!(refreshed.snapshot.machines[1].key, tombstone_key);
    assert_eq!(refreshed.managed_machine(tombstone_key).unwrap().version, 13);
}

#[test]
fn switching_to_a_lifecycle_tombstone_disables_the_placeholder_session() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
    let mut lifecycle = machine_lifecycle_snapshot(&catalog);
    lifecycle.machines.push(protocol::MachineLifecycleDescriptor {
        id: id("deleted-machine-uuid"),
        display_name: "quiet-forest".into(),
        status: protocol::MachineLifecycleStatus::Recoverable,
        version: 12,
        recoverable_until: Some("2030-01-02T03:04:05Z".into()),
        capabilities: protocol::MachineLifecycleCapabilities {
            rename: false,
            delete: false,
            restore: true,
            purge: true,
        },
    });
    let server_catalog = catalog;
    let server_lifecycle = lifecycle.clone();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(&mut stream, &protocol::ResponseEnvelope::success(refresh.id, server_catalog));

        let lifecycle_request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            lifecycle_request.request,
            protocol::ProviderRequest::MachineLifecycleSnapshot(_)
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(lifecycle_request.id, server_lifecycle),
        );
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    runtime.machine_lifecycle_snapshot = lifecycle;
    runtime.reconcile_keys();
    let tombstone_key = key_for_id(&runtime.keys, &id("deleted-machine-uuid")).unwrap();

    let result = runtime.perform_request(MachineRequest::Switch(tombstone_key)).unwrap();

    assert!(result.replacement.is_some());
    assert_eq!(result.ui.snapshot.active, Some(tombstone_key));
    assert!(!result.ui.session_available);
    assert!(runtime.open.is_none());
    finish.send(()).unwrap();
    drop(result);
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn mutation_nonce_is_cryptographically_unique_and_pid_independent() {
    let first = random_mutation_nonce().unwrap();
    let second = random_mutation_nonce().unwrap();
    assert_eq!(first.len(), 32);
    assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert_ne!(first, second);
    assert!(!first.contains(&std::process::id().to_string()));
}

#[test]
fn healthy_provider_waits_for_a_selected_provisioning_machine() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (_stream, _reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Provisioning", protocol::MachineStatus::Connecting),
        );
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let ui = runtime.ui_state_for_open_connection();
    assert!(!ui.session_available);
    assert!(ui.request.is_none());

    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn non_switch_provider_action_preserves_the_open_machine_transport() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Machine", protocol::MachineStatus::Running),
        );

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

        let select: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &select.request,
            protocol::ProviderRequest::SelectScope(params)
                if params.scope_id == id("personal")
        ));
        let mut selected = snapshot(3, "Machine", protocol::MachineStatus::Running);
        selected.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Info,
            message: "scope selected".into(),
        });
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                select.id,
                protocol::SelectScopeResult { snapshot: selected.clone() },
            ),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &selected);

        // The close must be the first request after the non-switch action
        // and is emitted only when the runtime is dropped below.
        let close: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("keep-open")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close.id,
                protocol::CloseMachineResult { revision: 4 },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    install_test_connection(&mut runtime, "keep-open", "machine-1", true);

    let result =
        runtime.perform_request(MachineRequest::SelectProviderScope("personal".into())).unwrap();

    assert!(result.replacement.is_none());
    assert!(result.ui.session_available);
    assert_eq!(result.ui.notice.as_deref(), Some("scope selected"));
    assert_eq!(runtime.open.as_ref().map(|open| open.connection_id.as_str()), Some("keep-open"));
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn action_selected_scope_loads_the_selected_scope_snapshot() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let mut personal = snapshot(1, "Personal machine", protocol::MachineStatus::Running);
    personal.scopes.push(protocol::ScopeDescriptor {
        id: id("team-1"),
        display_name: "Team".into(),
        kind: protocol::ScopeKind::Team,
        can_admin: true,
    });
    let mut team = personal.clone();
    team.revision = 3;
    team.selected_scope_id = id("team-1");
    team.machines[0].id = id("team-machine");
    team.machines[0].display_name = "Team machine".into();
    team.selected_machine_id = Some(id("team-machine"));

    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, personal.clone());

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let mut refreshed_personal = personal.clone();
        refreshed_personal.revision = 2;
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed_personal.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed_personal);

        let action: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &action.request,
            protocol::ProviderRequest::InvokeAction(params)
                if params.action_id == id("billing")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                action.id,
                protocol::InvokeActionResult {
                    revision: 3,
                    notice: None,
                    url: None,
                    selected_scope_id: Some(id("team-1")),
                    selected_machine_id: Some(id("team-machine")),
                },
            ),
        );

        let selection: protocol::RequestEnvelope = read_frame(&mut reader);
        match selection.request {
            protocol::ProviderRequest::SelectScope(params) => {
                assert_eq!(params.scope_id, id("team-1"));
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::success(
                        selection.id,
                        protocol::SelectScopeResult { snapshot: team.clone() },
                    ),
                );
                serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &team);
            }
            protocol::ProviderRequest::Snapshot(_) => {
                // A provider may return the action-selected scope without mutating its
                // process-global selection. Refreshing here therefore returns the old scope.
                let mut old_scope = personal.clone();
                old_scope.revision = 3;
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::success(selection.id, old_scope.clone()),
                );
                serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &old_scope);
            }
            request => panic!("unexpected request after provider action: {request:?}"),
        }

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let mut old_scope = personal;
        old_scope.revision = 4;
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, old_scope.clone()),
        );

        let selection: protocol::RequestEnvelope = read_frame(&mut reader);
        match selection.request {
            protocol::ProviderRequest::SelectScope(params) => {
                assert_eq!(params.scope_id, id("team-1"));
                let mut updated_team = team;
                updated_team.revision = 4;
                updated_team.machines[0].display_name = "Updated team machine".into();
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::success(
                        selection.id,
                        protocol::SelectScopeResult { snapshot: updated_team.clone() },
                    ),
                );
                serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &updated_team);
            }
            protocol::ProviderRequest::MachineLifecycleSnapshot(params) => {
                assert_eq!(params.scope_id, id("personal"));
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::success(
                        selection.id,
                        machine_lifecycle_snapshot(&old_scope),
                    ),
                );
            }
            request => panic!("unexpected subscription reconciliation request: {request:?}"),
        }
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let result = runtime
        .perform_request(MachineRequest::InvokeProviderAction {
            action_id: "billing".into(),
            values: BTreeMap::new(),
            machine_id: None,
            workspace_id: None,
        })
        .unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    finish.send(()).unwrap();
    server.join().unwrap();

    assert_eq!(runtime.snapshot.selected_scope_id, id("team-1"));
    assert_eq!(runtime.snapshot.selected_machine_id, Some(id("team-machine")));
    assert_eq!(runtime.snapshot.machines[0].id, id("team-machine"));
    assert_eq!(runtime.machine_lifecycle_snapshot.scope_id, id("team-1"));
    assert_eq!(result.ui.snapshot.machines[0].id, "team-machine");
    assert_eq!(update.provider.as_ref().unwrap().selected_scope_id, "team-1");
    assert_eq!(update.snapshot.machines[0].name, "Updated team machine");
}

#[test]
fn persistent_snapshot_notice_is_not_repeated_by_refresh() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
    catalog.notice = Some(protocol::ProviderNotice {
        level: protocol::NoticeLevel::Warning,
        message: "scheduled maintenance".into(),
    });
    let server_catalog = catalog;
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        let mut second = server_catalog.clone();
        second.revision = 2;
        serve_runtime_refresh(&mut stream, &mut reader, &second, None);
        let mut third = server_catalog;
        third.revision = 3;
        serve_runtime_refresh(&mut stream, &mut reader, &third, None);
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    runtime.refresh().unwrap();
    runtime.refresh().unwrap();
    let ui = runtime.ui_state_for_open_connection();

    finish.send(()).unwrap();
    assert_eq!(ui.notice.as_deref(), Some("scheduled maintenance"));
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn failed_candidate_open_preserves_the_current_machine_transport() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "First", protocol::MachineStatus::Running);
    catalog.machines[0].connectable = true;
    catalog.machines.push(protocol::MachineDescriptor {
        id: id("machine-2"),
        display_name: "Second".into(),
        subtitle: "cloud".into(),
        status: protocol::MachineStatus::Running,
        connectable: true,
        workspace_create: protocol::WorkspaceCreatePolicy::Session,
        platform: None,
        capabilities: Vec::new(),
    });
    let server_catalog = catalog.clone();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, server_catalog.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_catalog);

        let open: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            &open.request,
            protocol::ProviderRequest::OpenMachine(params)
                if params.machine_id == id("machine-2")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::OpenMachineResult>::failure(
                open.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "candidate refused".into(),
                    retryable: true,
                },
            ),
        );

        let close: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("keep-first-open")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close.id,
                protocol::CloseMachineResult { revision: 2 },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    install_test_connection(&mut runtime, "keep-first-open", "machine-1", true);
    let second = key_for_id(&runtime.keys, &id("machine-2")).unwrap();

    let Err(error) = runtime.perform_request(MachineRequest::Switch(second)) else {
        panic!("candidate open unexpectedly succeeded");
    };

    assert!(error.to_string().contains("candidate refused"));
    assert_eq!(runtime.snapshot.selected_machine_id, Some(id("machine-1")));
    assert_eq!(
        runtime.open.as_ref().map(|open| open.connection_id.as_str()),
        Some("keep-first-open")
    );
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn rejected_candidate_authority_preserves_the_current_transport_and_selection() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "First", protocol::MachineStatus::Running);
    catalog.machines.push(protocol::MachineDescriptor {
        id: id("machine-2"),
        display_name: "Second".into(),
        subtitle: "cloud".into(),
        status: protocol::MachineStatus::Running,
        connectable: true,
        workspace_create: protocol::WorkspaceCreatePolicy::Session,
        platform: None,
        capabilities: Vec::new(),
    });
    let server_catalog = catalog.clone();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());

        let close_candidate: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close_candidate.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("reject-second")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close_candidate.id,
                protocol::CloseMachineResult { revision: 2 },
            ),
        );

        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let mut refreshed = server_catalog;
        refreshed.revision = 2;
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

        let close_current: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(
            close_current.request,
            protocol::ProviderRequest::CloseMachine(params)
                if params.connection_id == id("keep-first-open")
        ));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                close_current.id,
                protocol::CloseMachineResult { revision: 3 },
            ),
        );
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    install_test_connection(&mut runtime, "keep-first-open", "machine-1", true);
    let rollback = ProviderSelectionRollback {
        selected_machine_id: runtime.snapshot.selected_machine_id.clone(),
        workspace_snapshot: runtime.workspace_snapshot.clone(),
    };
    runtime.snapshot.selected_machine_id = Some(id("machine-2"));
    runtime.snapshot.machines[1].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
        default_mode: protocol::WorkspaceCreateMode::Isolated,
        modes: vec![protocol::WorkspaceCreateMode::Isolated],
    };
    let candidate_open = cache_test_connection(&mut runtime, "reject-second", "machine-2", true);
    runtime.stage_connection(Some(candidate_open), Some(rollback)).unwrap();
    let candidate = crate::session::test_remote_session_without_provider_authority();
    let candidate_ui = runtime.ui_state(true);

    let error = crate::machine::validate_machine_session(&candidate, &candidate_ui).unwrap_err();
    runtime.abort_replacement();

    assert!(error.to_string().contains("did not supply workspace mirror authority"));
    assert_eq!(runtime.snapshot.selected_machine_id, Some(id("machine-1")));
    assert_eq!(
        runtime.open.as_ref().map(|open| open.connection_id.as_str()),
        Some("keep-first-open")
    );
    runtime.refresh().expect("provider control connection remains usable");
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn durable_notice_bypasses_a_blocked_authoritative_refresh() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (refresh_started, wait_for_refresh) = mpsc::channel();
    let (release_refresh, refresh_release) = mpsc::channel();
    let replay = protocol::EventEnvelope::with_delivery(
        protocol::ProviderEvent::Notice(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "Usage reached 80%".into(),
        }),
        protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
    );
    let server = thread::spawn(move || {
        let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let (mut stream, mut reader, _) =
            serve_initial_durable_snapshot(&listener, catalog.clone(), Some(replay));
        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        refresh_started.send(()).unwrap();
        refresh_release.recv().unwrap();
        write_frame(&mut stream, &protocol::ResponseEnvelope::success(refresh.id, catalog.clone()));
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &catalog);
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    wait_for_refresh.recv_timeout(Duration::from_secs(2)).unwrap();

    let update = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let MachineUpdate::DurableNotice(notice) = update else {
        panic!("blocked refresh reached the app before the durable notice");
    };
    assert_eq!(notice.delivery.notice_id, "usage-80");
    assert_eq!(notice.delivery.sequence, 1);
    assert_eq!(notice.level, DurableNoticeLevel::Warning);
    assert_eq!(notice.message, "Usage reached 80%");

    release_refresh.send(()).unwrap();
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn snapshot_change_burst_does_not_disconnect_or_starve_durable_notice() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (refresh_started, wait_for_refresh) = mpsc::channel();
    let (release_refresh, refresh_release) = mpsc::channel();
    let server = thread::spawn(move || {
        let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let (mut stream, mut reader, _) = serve_initial_durable_snapshot(&listener, catalog, None);
        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        refresh_started.send(()).unwrap();

        let last_revision = PROVIDER_REFRESH_QUEUE_CAPACITY as u64 + 2;
        for revision in 2..=last_revision {
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                    protocol::SnapshotChangedEvent { revision },
                )),
            );
        }
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::with_delivery(
                protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                    level: protocol::NoticeLevel::Warning,
                    message: "Usage reached 80%".into(),
                }),
                protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
            ),
        );

        refresh_release.recv().unwrap();
        let refreshed = snapshot(last_revision, "Machine", protocol::MachineStatus::Running);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    wait_for_refresh.recv_timeout(Duration::from_secs(2)).unwrap();

    let received = receiver.recv_timeout(Duration::from_secs(2));
    release_refresh.send(()).unwrap();
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    drop(runtime);
    server.join().unwrap();

    let MachineUpdate::DurableNotice(notice) = received.expect(
        "redundant snapshot invalidations must coalesce instead of disconnecting the provider",
    ) else {
        panic!("snapshot invalidation burst disconnected before the durable notice");
    };
    assert_eq!(notice.delivery.notice_id, "usage-80");
    assert_eq!(notice.delivery.sequence, 1);
}

#[test]
fn initial_durable_replay_suppresses_the_legacy_snapshot_notice() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let replay = protocol::EventEnvelope::with_delivery(
        protocol::ProviderEvent::Notice(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "Usage reached 80%".into(),
        }),
        protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
    );
    let server = thread::spawn(move || {
        let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        catalog.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "Usage reached 80%".into(),
        });
        let (_stream, _reader, _) =
            serve_initial_durable_snapshot(&listener, catalog, Some(replay));
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    assert!(
        runtime.ui_state_for_open_connection().notice.is_none(),
        "the durable replay and legacy snapshot notice would be shown twice"
    );
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    let MachineUpdate::DurableNotice(notice) =
        receiver.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected the retained durable notice");
    };
    assert_eq!(notice.delivery.notice_id, "usage-80");

    stop.store(true, Ordering::Release);
    drop(receiver);
    // Close the provider stream first: the refresh worker may still wait
    // on a request this test's server never answers, and the stream's EOF
    // ends that wait at once instead of after the 30 s request timeout.
    finish.send(()).unwrap();
    worker.join().unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn initial_current_warning_remains_visible_without_a_durable_replay() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        catalog.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "Usage reached 50%".into(),
        });
        let (_stream, _reader, _) = serve_initial_durable_snapshot(&listener, catalog, None);
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    assert_eq!(runtime.ui_state_for_open_connection().notice.as_deref(), Some("Usage reached 50%"));
    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn durable_provider_suppresses_later_legacy_snapshot_warning_updates() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (trigger, triggered) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let (mut stream, mut reader, _) = serve_initial_durable_snapshot(&listener, catalog, None);
        triggered.recv().unwrap();
        let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::with_delivery(
                protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                    level: protocol::NoticeLevel::Warning,
                    message: "Usage reached 80%".into(),
                }),
                protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
            ),
        );
        let mut refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
        refreshed.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "Usage reached 80%".into(),
        });
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
        finished.recv().unwrap();
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    trigger.send(()).unwrap();
    let mut saw_durable = false;
    let mut saw_refresh = false;
    for _ in 0..2 {
        match receiver.recv_timeout(Duration::from_secs(2)).unwrap() {
            MachineUpdate::DurableNotice(notice) => {
                assert_eq!(notice.delivery.notice_id, "usage-80");
                saw_durable = true;
            }
            MachineUpdate::Ui(ui) => {
                assert!(
                    ui.notice.is_none(),
                    "legacy snapshot warning duplicated the durable event"
                );
                saw_refresh = true;
            }
            MachineUpdate::ConnectionProgress { machine_id, latest } => {
                panic!("unexpected progress {machine_id:?}: {latest:?}")
            }
        }
    }
    assert!(saw_durable && saw_refresh);

    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn reconnect_reuses_the_process_stable_notice_consumer_id() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (consumers, consumer_ids) = mpsc::channel();
    let (reconnect, reconnect_now) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        for revision in [1, 2] {
            let catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
            let (stream, reader, consumer_id) =
                serve_initial_durable_snapshot(&listener, catalog, None);
            consumers.send(consumer_id).unwrap();
            if revision == 2 {
                finished.recv().unwrap();
            } else {
                reconnect_now.recv().unwrap();
            }
            drop(reader);
            drop(stream);
        }
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let first = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
    reconnect.send(()).unwrap();
    runtime.reconnect_control().unwrap();
    let second = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();

    assert_eq!(first, second);
    assert_eq!(Some(&first), runtime.notice_identity.acquired_consumer_id());
    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn legacy_provider_does_not_require_notice_identity_state() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let state = TestStateRoot::create("legacy-without-identity");
    let identity_parent = crate::provider_notice_identity::identity_parent(&state.path);
    std::fs::DirBuilder::new().mode(0o755).create(&identity_parent).unwrap();
    std::fs::set_permissions(&identity_parent, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (release, release_connection) = mpsc::channel();
    let server = thread::spawn(move || {
        let Some(stream) = accept_with_timeout(&listener) else { return false };
        let (stream, reader) = serve_initial_snapshot_on_stream(
            stream,
            snapshot(1, "Legacy", protocol::MachineStatus::Running),
            &[],
        );
        release_connection.recv_timeout(Duration::from_secs(2)).unwrap();
        drop(reader);
        drop(stream);
        true
    });

    let runtime = ProviderMachineRuntime::connect_in_state_root(&socket.path, token(), &state.path);
    release.send(()).unwrap();
    assert!(
        server.join().unwrap(),
        "legacy provider was not contacted before identity state was accessed"
    );
    let runtime = runtime.expect("legacy provider should not require durable identity state");
    assert_eq!(runtime.ui_state(false).snapshot.machines[0].name, "Legacy");
}

#[test]
fn legacy_provider_connects_without_a_resolvable_state_root() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (release, release_connection) = mpsc::channel();
    let server = thread::spawn(move || {
        let Some(stream) = accept_with_timeout(&listener) else { return false };
        let (stream, reader) = serve_initial_snapshot_on_stream(
            stream,
            snapshot(1, "Legacy", protocol::MachineStatus::Running),
            &[],
        );
        release_connection.recv_timeout(Duration::from_secs(2)).unwrap();
        drop(reader);
        drop(stream);
        true
    });

    let runtime = ProviderMachineRuntime::connect_without_state_root(&socket.path, token());
    release.send(()).unwrap();
    assert!(
        server.join().unwrap(),
        "legacy provider was not contacted before the missing state root was required"
    );
    let runtime = runtime.expect("legacy provider should not require a durable state root");
    assert_eq!(runtime.ui_state(false).snapshot.machines[0].name, "Legacy");
}

#[test]
fn unavailable_notice_identity_preserves_localized_context_after_durable_handshake() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let state = TestStateRoot::create("unavailable-identity");
    let identity_parent = crate::provider_notice_identity::identity_parent(&state.path);
    std::fs::DirBuilder::new().mode(0o755).create(&identity_parent).unwrap();
    std::fs::set_permissions(&identity_parent, std::fs::Permissions::from_mode(0o755)).unwrap();
    let server = thread::spawn(move || negotiate_durable_then_expect_disconnect(&listener));

    let error = ProviderMachineRuntime::connect_in_state_root(&socket.path, token(), &state.path)
        .err()
        .expect("permissive identity state unexpectedly connected");
    assert!(
        server.join().unwrap(),
        "durable capability was not negotiated before identity state was accessed"
    );
    assert_eq!(
        error.to_string(),
        localization::catalog().sidebar.provider_notice_identity_unavailable
    );
    assert!(
        format!("{error:?}").contains("provider notice identity directory must not be accessible")
    );
}

#[test]
fn missing_notice_identity_root_uses_localized_error_after_durable_handshake() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || negotiate_durable_then_expect_disconnect(&listener));

    let error = ProviderMachineRuntime::connect_without_state_root(&socket.path, token())
        .err()
        .expect("missing identity root unexpectedly connected");
    assert!(
        server.join().unwrap(),
        "durable capability was not negotiated before the missing state root was required"
    );
    assert_eq!(
        error.to_string(),
        localization::catalog().sidebar.provider_notice_identity_unavailable
    );
    assert!(format!("{error:?}").contains("cannot determine durable state directory"));
}

#[test]
fn runtime_identity_lease_blocks_a_second_cursor_and_reuses_it_after_release() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let first_root = TestStateRoot::create("first");
    let second_root = TestStateRoot::create("second");
    let (consumers, consumer_ids) = mpsc::channel();
    let (release, release_connection) = mpsc::channel();
    let server = thread::spawn(move || {
        let first_catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let (first_stream, first_reader, first_consumer_id) =
            serve_initial_durable_snapshot(&listener, first_catalog, None);
        consumers.send(first_consumer_id).unwrap();

        let (mut blocked_stream, _) = listener.accept().unwrap();
        let mut blocked_reader = BufReader::new(blocked_stream.try_clone().unwrap());
        let hello: protocol::RequestEnvelope = read_frame(&mut blocked_reader);
        assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
        write_frame(
            &mut blocked_stream,
            &protocol::ResponseEnvelope::success(
                hello.id,
                protocol::HelloResult {
                    provider_id: id("test-provider"),
                    provider_name: "Test Provider".into(),
                    negotiated_version: protocol::Version,
                },
            )
            .with_capabilities([protocol::DURABLE_NOTICES_CAPABILITY]),
        );
        let mut blocked_request = String::new();
        assert_eq!(
            blocked_reader.read_line(&mut blocked_request).unwrap(),
            0,
            "competing runtime subscribed with the leased identity: {blocked_request}"
        );
        drop(blocked_reader);
        drop(blocked_stream);

        release_connection.recv().unwrap();
        drop(first_reader);
        drop(first_stream);

        for revision in [2, 3] {
            let catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
            let (stream, reader, consumer_id) =
                serve_initial_durable_snapshot(&listener, catalog, None);
            consumers.send(consumer_id).unwrap();
            release_connection.recv().unwrap();
            drop(reader);
            drop(stream);
        }
    });

    let first = connect_after_runtime_start(&socket.path, &first_root.path);
    let first_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();

    let blocked_socket = socket.path.clone();
    let blocked_root = first_root.path.clone();
    let (blocked_result, blocked_outcome) = mpsc::channel();
    let blocked = thread::spawn(move || {
        let result =
            ProviderMachineRuntime::connect_in_state_root(blocked_socket, token(), &blocked_root);
        blocked_result
            .send(match result {
                Ok(runtime) => {
                    drop(runtime);
                    Ok(())
                }
                Err(error) => Err(error.to_string()),
            })
            .unwrap();
    });
    let blocked_error = blocked_outcome
        .recv_timeout(Duration::from_secs(2))
        .expect("second runtime did not fail before subscribing")
        .expect_err("second runtime unexpectedly acquired the shared notice cursor");
    assert_eq!(blocked_error, localization::catalog().sidebar.provider_connection_already_running);
    blocked.join().unwrap();
    assert!(consumer_ids.try_recv().is_err());

    let first_ui = first.ui_state(false);
    assert_eq!(first_ui.snapshot.machines[0].name, "Machine");
    drop(first);
    release.send(()).unwrap();

    let restarted = connect_after_runtime_start(&socket.path, &first_root.path);
    let restarted_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
    drop(restarted);
    release.send(()).unwrap();

    let separate = connect_after_runtime_start(&socket.path, &second_root.path);
    let separate_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
    drop(separate);
    release.send(()).unwrap();

    assert_eq!(restarted_id, first_id);
    assert_ne!(separate_id, first_id);
    server.join().unwrap();
}

#[test]
fn snapshot_event_replaces_dynamic_ui_with_stable_machine_key() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (trigger, triggered) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "First name", protocol::MachineStatus::Running),
        );
        triggered.recv().unwrap();
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                protocol::SnapshotChangedEvent { revision: 2 },
            )),
        );
        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::Snapshot(params) = request.request else {
            panic!("snapshot event did not trigger a snapshot request");
        };
        assert_eq!(params.known_revision, Some(1));
        let refreshed = snapshot(2, "Renamed machine", protocol::MachineStatus::Sleeping);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(request.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
        finished.recv().unwrap();
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let original_key = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    trigger.send(()).unwrap();

    let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
    assert_eq!(update.snapshot.active, Some(original_key));
    assert_eq!(update.snapshot.machines[0].key, original_key);
    assert_eq!(update.snapshot.machines[0].name, "Renamed machine");
    assert_eq!(update.snapshot.machines[0].status, MachineStatus::Sleeping);
    assert_eq!(update.provider.as_ref().unwrap().actions[0].label, "Billing revision 2");
    assert!(!update.session_available);
    assert!(update.request.is_none());

    stop.store(true, Ordering::Release);
    drop(receiver);
    // Close the provider stream first: the refresh worker may still wait
    // on a request this test's server never answers, and the stream's EOF
    // ends that wait at once instead of after the 30 s request timeout.
    finish.send(()).unwrap();
    worker.join().unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn subscription_refreshes_after_an_event_published_before_registration() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (publish, published) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Before subscription", protocol::MachineStatus::Running),
        );
        published.recv().unwrap();
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                protocol::SnapshotChangedEvent { revision: 2 },
            )),
        );

        // Synchronize with the control reader after the unobserved event.
        // This response is deliberately stale and is not installed by the runtime.
        let synchronize: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(synchronize.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                synchronize.id,
                snapshot(1, "Before subscription", protocol::MachineStatus::Running),
            ),
        );

        let mut line = String::new();
        if reader.read_line(&mut line).unwrap() == 0 {
            return;
        }
        let refresh: protocol::RequestEnvelope = serde_json::from_str(&line).unwrap();
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        let refreshed = snapshot(2, "After subscription", protocol::MachineStatus::Sleeping);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    publish.send(()).unwrap();
    let ignored = runtime.client.snapshot(Some(1)).unwrap();
    assert_eq!(ignored.revision, 1);

    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    let received = receiver.recv_timeout(Duration::from_secs(2));
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    drop(runtime);
    server.join().unwrap();

    let update =
        expect_ui_update(received.expect(
            "subscription must perform an authoritative refresh after registering for events",
        ));
    assert_eq!(update.snapshot.machines[0].name, "After subscription");
    assert_eq!(update.snapshot.machines[0].status, MachineStatus::Sleeping);
}

#[test]
fn provider_update_failure_uses_selected_locale() {
    const CHILD_ENV: &str = "CMUX_PROVIDER_UPDATE_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("machine_provider_runtime::tests::provider_update_failure_uses_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese provider failure child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (trigger, triggered) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Machine", protocol::MachineStatus::Running),
        );
        triggered.recv().unwrap();
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                protocol::SnapshotChangedEvent { revision: 2 },
            )),
        );
        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                request.id,
                protocol::ProviderError {
                    code: protocol::ProviderErrorCode::Unavailable,
                    message: "catalog unavailable".into(),
                    retryable: true,
                },
            ),
        );
        finished.recv().unwrap();
    });

    let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    trigger.send(()).unwrap();
    let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();
    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();

    let notice = update.notice.unwrap();
    assert!(
        notice.starts_with("マシンプロバイダーの更新に失敗しました: "),
        "provider failure did not use the selected Japanese locale: {notice}"
    );
}

#[test]
fn provider_connection_state_errors_use_selected_locale() {
    const CHILD_ENV: &str = "CMUX_PROVIDER_CONNECTION_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg(
                "machine_provider_runtime::tests::provider_connection_state_errors_use_selected_locale",
            )
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese provider connection child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let _control = serve_initial_snapshot(
            &listener,
            snapshot(1, "Machine", protocol::MachineStatus::Running),
        );
        finished.recv().unwrap();
    });
    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();

    let error = runtime.open_selected().err().expect("machine is not connectable");
    assert_eq!(error.to_string(), "選択したマシンは接続準備ができていません");
    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

#[test]
fn provider_runtime_user_notices_are_catalog_backed() {
    let sources = [
        include_str!("machine_provider_runtime.rs"),
        include_str!("machine_provider_runtime/projection.rs"),
        include_str!("machine_provider_runtime/updates.rs"),
    ];
    for hardcoded in [
        concat!("Open ", "{url}"),
        concat!("Machine provider ", "update failed: {error}"),
        concat!("Machine provider lifecycle ", "update failed: {error}"),
        concat!("Machine provider workspace ", "update failed: {error}"),
        concat!("Could not reconnect ", "machine: {error}"),
        concat!("this machine provider cannot connect ", "external machines"),
        concat!("is not ready ", "to connect"),
        concat!("cannot authorize managed workspace mirrors; ", "upgrade the machine provider"),
        concat!("returned an invalid managed workspace ", "authority binding"),
    ] {
        assert!(
            !sources.iter().any(|source| source.contains(hardcoded)),
            "provider notice bypasses the localization catalog: {hardcoded}"
        );
    }
}

#[test]
fn stale_connection_closed_event_preserves_the_current_connection() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (trigger, triggered) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Machine", protocol::MachineStatus::Running),
        );
        triggered.recv().unwrap();
        write_frame(
            &mut stream,
            &protocol::EventEnvelope::new(protocol::ProviderEvent::ConnectionClosed(
                protocol::ConnectionClosedEvent {
                    connection_id: id("old-connection"),
                    machine_id: id("machine-1"),
                    reason: "old connection closed late".into(),
                },
            )),
        );
        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        let refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(request.id, refreshed.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    install_test_connection(&mut runtime, "current-connection", "machine-1", false);
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    trigger.send(()).unwrap();

    let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
    stop.store(true, Ordering::Release);
    drop(receiver);
    // Close the provider stream first: the refresh worker may still wait
    // on a request this test's server never answers, and the stream's EOF
    // ends that wait at once instead of after the 30 s request timeout.
    finish.send(()).unwrap();
    worker.join().unwrap();
    runtime.open = None;
    drop(runtime);
    server.join().unwrap();

    assert!(update.session_available);
    assert!(update.request.is_none());
    assert_ne!(update.notice.as_deref(), Some("old connection closed late"));
}

#[test]
fn provider_eof_requests_and_completes_a_fresh_authenticated_connection() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let (disconnect, disconnect_now) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (first_stream, first_reader) = serve_initial_snapshot(
            &listener,
            snapshot(1, "Before restart", protocol::MachineStatus::Running),
        );
        disconnect_now.recv().unwrap();
        drop(first_reader);
        drop(first_stream);

        let (_second_stream, _second_reader) = serve_initial_snapshot(
            &listener,
            snapshot(2, "After restart", protocol::MachineStatus::Sleeping),
        );
        finished.recv().unwrap();
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let updates = runtime.subscribe_ui_updates().unwrap();
    let (receiver, stop, worker) = updates.into_parts();
    disconnect.send(()).unwrap();

    let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
    assert_eq!(update.request, Some(MachineRequest::ReconnectProvider));
    assert_eq!(
        update.notice.as_deref(),
        Some(localization::catalog().sidebar.machine_provider_disconnected)
    );
    stop.store(true, Ordering::Release);
    drop(receiver);
    worker.join().unwrap();

    runtime.perform_request(MachineRequest::ReconnectProvider).unwrap();
    assert_eq!(runtime.snapshot.revision, 2);
    let ui = runtime.ui_state(false);
    assert_eq!(ui.snapshot.machines[0].name, "After restart");
    assert_eq!(ui.snapshot.machines[0].status, MachineStatus::Sleeping);

    finish.send(()).unwrap();
    drop(runtime);
    server.join().unwrap();
}

fn sent_mutation_id(request: &protocol::ProviderRequest) -> protocol::OpaqueId {
    let mut request = request.clone();
    request_mutation_id_mut(&mut request).expect("request carries a mutation id").clone()
}

fn fail_followup_refresh(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    kind: AcceptedMutationKind,
) {
    let failed_refresh: protocol::RequestEnvelope = read_frame(reader);
    assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
    write_frame(
        stream,
        &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
            failed_refresh.id,
            protocol::ProviderError {
                code: protocol::ProviderErrorCode::Unavailable,
                message: format!("refresh failed after accepted {kind:?}"),
                retryable: true,
            },
        ),
    );
}

/// A mutation whose answer outran its bound may still commit on the
/// provider. Its retry must replay the same mutation_id, so a slow create
/// makes one machine, not two. Success then settles the id.
#[test]
fn every_timed_out_provider_mutation_replays_its_mutation_id_on_retry() {
    use crate::machine_provider_client::ProviderRequestDeadlines;

    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server_catalog = catalog;
    let server_workspace = workspace;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, server_catalog.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);
        let mut first_create_id = None;
        for kind in AcceptedMutationKind::ALL {
            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_catalog,
                Some(&server_workspace),
            );
            // The provider is still working: no answer before the bound.
            let unanswered: protocol::RequestEnvelope = read_frame(&mut reader);
            let first_id = sent_mutation_id(&unanswered.request);

            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_catalog,
                Some(&server_workspace),
            );
            let retry_id = serve_accepted_mutation(kind, &mut stream, &mut reader);
            assert_eq!(retry_id, first_id, "{kind:?} retry minted a new mutation_id");
            if matches!(kind, AcceptedMutationKind::CreateMachine) {
                first_create_id = Some(first_id);
            }
            fail_followup_refresh(&mut stream, &mut reader, kind);
        }

        // The answered create settled its id; a new create is a new machine.
        serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, Some(&server_workspace));
        let next_create_id =
            serve_accepted_mutation(AcceptedMutationKind::CreateMachine, &mut stream, &mut reader);
        assert_ne!(Some(next_create_id), first_create_id);
        fail_followup_refresh(&mut stream, &mut reader, AcceptedMutationKind::CreateMachine);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let bound = Duration::from_millis(500);
    runtime.client.set_request_deadlines(ProviderRequestDeadlines {
        control: bound,
        create: bound,
        open: bound,
    });
    let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
    for kind in AcceptedMutationKind::ALL {
        let Err(first) = runtime.perform_request(accepted_mutation_request(kind, machine)) else {
            panic!("{kind:?} completed although the provider never answered");
        };
        assert!(
            matches!(
                first.downcast_ref::<ProviderClientError>(),
                Some(ProviderClientError::Timeout)
            ),
            "{kind:?} failed with {first:#} instead of a timeout"
        );
        if let Err(error) = runtime.perform_request(accepted_mutation_request(kind, machine)) {
            panic!("{kind:?} retry failed: {error:#}");
        }
        runtime.open = None;
    }
    runtime.perform_request(MachineRequest::Create).unwrap();
    drop(runtime);
    server.join().unwrap();
}

fn create_in_scope(scope: usize) -> protocol::ProviderRequest {
    protocol::ProviderRequest::CreateMachine(protocol::CreateMachineParams {
        scope_id: id(&format!("scope-{scope}")),
        mutation_id: unassigned_mutation_id().unwrap(),
    })
}

fn answer_create(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    machine: &str,
) -> (protocol::OpaqueId, protocol::OpaqueId) {
    let create: protocol::RequestEnvelope = read_frame(reader);
    let protocol::ProviderRequest::CreateMachine(params) = create.request else {
        panic!("expected a create, got {:?}", create.request);
    };
    write_frame(
        stream,
        &protocol::ResponseEnvelope::success(
            create.id,
            protocol::CreateMachineResult { machine_id: id(machine), revision: 2, notice: None },
        ),
    );
    (params.scope_id, params.mutation_id)
}

/// A full ledger of unanswered creates never forgets one: the next new create
/// is refused before it reaches the provider, and a retry of the oldest still
/// replays its mutation_id, so it cannot make a second machine. Its answer
/// frees one slot for the refused create.
#[test]
fn a_full_unsettled_ledger_refuses_new_creates_and_still_replays_the_oldest() {
    use crate::machine_provider_client::ProviderRequestDeadlines;

    let pending = MAX_UNSETTLED_MUTATIONS;
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, catalog);
        serve_workspace_snapshot(&mut stream, &mut reader, &workspace);
        // Every create stays unanswered past its bound.
        let mut sent = Vec::new();
        for scope in 0..pending {
            let create: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::CreateMachine(params) = create.request else {
                panic!("expected create {scope}, got {:?}", create.request);
            };
            assert_eq!(params.scope_id, id(&format!("scope-{scope}")));
            sent.push(params.mutation_id);
        }
        let unique: HashSet<_> = sent.iter().collect();
        assert_eq!(unique.len(), pending, "each distinct create mints its own id");

        // The refused create never arrives: the next frame is the oldest's retry.
        let (scope, retry_id) = answer_create(&mut stream, &mut reader, "machine-0");
        assert_eq!(scope, id("scope-0"), "the refused create reached the provider");
        assert_eq!(retry_id, sent[0], "the oldest create's retry minted a new mutation_id");

        // The settled slot admits the create that was refused.
        let (scope, admitted_id) = answer_create(&mut stream, &mut reader, "machine-new");
        assert_eq!(scope, id(&format!("scope-{pending}")));
        assert!(!sent.contains(&admitted_id), "a new create needs a new mutation_id");
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let bound = Duration::from_millis(20);
    runtime.client.set_request_deadlines(ProviderRequestDeadlines {
        control: Duration::from_secs(5),
        create: bound,
        open: Duration::from_secs(5),
    });
    for scope in 0..pending {
        let error = runtime
            .send_mutation::<protocol::CreateMachineResult>(create_in_scope(scope))
            .expect_err("the provider never answers these creates");
        assert!(
            matches!(
                error.downcast_ref::<ProviderClientError>(),
                Some(ProviderClientError::Timeout)
            ),
            "create {scope} failed with {error:#} instead of a timeout"
        );
    }

    for _ in 0..2 {
        let refused = runtime
            .send_mutation::<protocol::CreateMachineResult>(create_in_scope(pending))
            .expect_err("a new create past the ledger's capacity must be refused");
        let full = refused
            .downcast_ref::<UnsettledMutationsFull>()
            .unwrap_or_else(|| panic!("refused with {refused:#} instead of a full ledger"));
        assert_eq!(full.pending, pending);
        assert!(refused.to_string().contains("still waiting for an answer"));
    }
    assert_eq!(runtime.unsettled_mutations.entries.len(), pending);

    runtime.client.set_request_deadlines(ProviderRequestDeadlines::PRODUCTION);
    let created: protocol::CreateMachineResult =
        runtime.send_mutation(create_in_scope(0)).expect("the oldest create's retry");
    assert_eq!(created.machine_id, id("machine-0"));
    assert_eq!(runtime.unsettled_mutations.entries.len(), pending - 1);

    let created: protocol::CreateMachineResult =
        runtime.send_mutation(create_in_scope(pending)).expect("a freed slot admits a new create");
    assert_eq!(created.machine_id, id("machine-new"));
    assert_eq!(runtime.unsettled_mutations.entries.len(), pending - 1);

    drop(runtime);
    server.join().unwrap();
}

/// A mutation refused before its frame was written left nothing on the
/// provider, so it must not hold a ledger slot. Forty refused connects in
/// forty scopes would otherwise fill all 32 slots and block every create.
#[test]
fn mutations_refused_before_sending_leave_no_slot_and_a_create_still_goes_through() {
    const REFUSED: usize = 40;
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server = thread::spawn(move || {
        // The provider does not advertise external connect.
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, catalog);
        serve_workspace_snapshot(&mut stream, &mut reader, &workspace);
        // No connect frame arrives: the first frame after them is the create.
        let (scope, _) = answer_create(&mut stream, &mut reader, "machine-real");
        assert_eq!(scope, id("scope-real"), "a refused connect reached the provider");
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    for attempt in 0..REFUSED {
        let connect = protocol::ProviderRequest::ConnectExternalMachine(
            protocol::ConnectExternalMachineParams {
                scope_id: id(&format!("stale-scope-{attempt}")),
                specifier: protocol::ExternalMachineSpecifier::new(format!("PAIR {attempt}"))
                    .unwrap(),
                mutation_id: unassigned_mutation_id().unwrap(),
            },
        );
        let error = runtime
            .send_mutation::<protocol::ConnectExternalMachineResult>(connect)
            .expect_err("an unadvertised capability is refused locally");
        assert!(
            matches!(
                error.downcast_ref::<ProviderClientError>(),
                Some(ProviderClientError::UnsupportedCapability(_))
            ),
            "attempt {attempt} failed with {error:#}"
        );
        assert!(runtime.unsettled_mutations.entries.is_empty(), "attempt {attempt} kept a slot");
    }

    let created: protocol::CreateMachineResult = runtime
        .send_mutation(protocol::ProviderRequest::CreateMachine(protocol::CreateMachineParams {
            scope_id: id("scope-real"),
            mutation_id: unassigned_mutation_id().unwrap(),
        }))
        .expect("a real create after the refused connects");
    assert_eq!(created.machine_id, id("machine-real"));
    assert!(runtime.unsettled_mutations.entries.is_empty());
    drop(runtime);
    server.join().unwrap();
}

/// An external connect goes through the one ledger: its unanswered attempt
/// takes a slot (so 31 more fill the ledger and refuse a new create) and its
/// retry replays the id the first attempt sent.
#[test]
fn an_unanswered_external_connect_holds_a_ledger_slot_and_its_retry_replays_its_id() {
    use crate::machine_provider_client::ProviderRequestDeadlines;

    let others = MAX_UNSETTLED_MUTATIONS - 1;
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
    catalog.capabilities.connect_external_machine = true;
    let mut enrolled = catalog.clone();
    enrolled.revision = 2;
    enrolled.selected_machine_id = Some(id("machine-1"));
    enrolled.machines[0].connectable = true;
    let server_catalog = catalog;
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
            &listener,
            server_catalog,
            &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );
        let first: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(first_params) = first.request else {
            panic!("first request was not external connect: {:?}", first.request);
        };
        for scope in 0..others {
            let create: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(
                matches!(create.request, protocol::ProviderRequest::CreateMachine(_)),
                "create {scope} was {:?}",
                create.request
            );
        }
        // Neither refused request arrives; the next frame is the retry.
        let retry: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::ConnectExternalMachine(retry_params) = retry.request else {
            panic!("retry request was not external connect: {:?}", retry.request);
        };
        assert_eq!(retry_params.specifier, first_params.specifier);
        assert_eq!(retry_params.mutation_id, first_params.mutation_id, "the retry minted a new id");
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                retry.id,
                protocol::ConnectExternalMachineResult {
                    machine_id: id("machine-1"),
                    revision: 2,
                    notice: None,
                },
            ),
        );
        serve_runtime_refresh(&mut stream, &mut reader, &enrolled, None);
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let bound = Duration::from_millis(20);
    runtime.client.set_request_deadlines(ProviderRequestDeadlines {
        control: bound,
        create: bound,
        open: bound,
    });
    let Err(first) = runtime.connect_external_after_refresh("PAIR 4J7K".into()) else {
        panic!("an unanswered connect completed");
    };
    assert!(
        matches!(first.downcast_ref::<ProviderClientError>(), Some(ProviderClientError::Timeout)),
        "the connect failed with {first:#} instead of a timeout"
    );
    assert_eq!(runtime.unsettled_mutations.entries.len(), 1, "the connect took no slot");
    assert!(runtime.pending_external_connect.is_some());

    for scope in 0..others {
        runtime
            .send_mutation::<protocol::CreateMachineResult>(create_in_scope(scope))
            .expect_err("the provider never answers these creates");
    }
    let refused = runtime
        .send_mutation::<protocol::CreateMachineResult>(create_in_scope(others))
        .expect_err("the connect's slot fills the ledger");
    assert!(refused.downcast_ref::<UnsettledMutationsFull>().is_some(), "{refused:#}");
    let Err(refused) = runtime.connect_external_after_refresh("PAIR OTHER".into()) else {
        panic!("a new connect must be refused by the full ledger too");
    };
    assert!(refused.downcast_ref::<UnsettledMutationsFull>().is_some(), "{refused:#}");
    assert!(
        runtime.pending_external_connect.is_some(),
        "a refused connect cleared the ambiguous one"
    );

    runtime.client.set_request_deadlines(ProviderRequestDeadlines::PRODUCTION);
    runtime.connect_external_after_refresh("PAIR 4J7K".into()).expect("the connect's retry");
    assert!(runtime.pending_external_connect.is_none());
    assert_eq!(runtime.unsettled_mutations.entries.len(), others);
    runtime.close();
    server.join().unwrap();
}

/// The `.mutate(` calls in `source` outside `send_mutation`'s body, as
/// 1-based line numbers. Comment lines are ignored.
fn provider_mutate_calls_outside_send_mutation(source: &str) -> Vec<usize> {
    let allowed = source.find("fn send_mutation").and_then(|start| {
        let open = start + source[start..].find('{')?;
        let mut depth = 0usize;
        for (offset, byte) in source[open..].bytes().enumerate() {
            match byte {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(open..open + offset);
                    }
                }
                _ => {}
            }
        }
        None
    });
    let mut offset = 0;
    let mut hits = Vec::new();
    for (index, line) in source.split_inclusive('\n').enumerate() {
        let calls = line.contains(".mutate(") || line.contains(".mutate::<");
        let comment = line.trim_start().starts_with("//");
        let inside = allowed.as_ref().is_some_and(|range| range.contains(&offset));
        if calls && !comment && !inside {
            hits.push(index + 1);
        }
        offset += line.len();
    }
    hits
}

fn crate_sources(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            crate_sources(&path, found);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
}

/// Detector for the bypass class: a provider mutation sent anywhere but
/// `send_mutation` skips the replay ledger and its cap. Test files may call
/// the client directly; production code may not.
#[test]
fn every_provider_mutate_call_goes_through_send_mutation() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut sources = Vec::new();
    crate_sources(&root, &mut sources);
    let mut bypasses = Vec::new();
    let mut scanned = 0;
    for path in sources {
        if path.file_name().is_some_and(|name| name.to_string_lossy().ends_with("_tests.rs")) {
            continue;
        }
        let source = std::fs::read_to_string(&path).unwrap();
        if !source.contains("ProviderClient") && !source.contains("machine_provider_client") {
            continue;
        }
        scanned += 1;
        for line in provider_mutate_calls_outside_send_mutation(&source) {
            bypasses.push(format!("{}:{line}", path.display()));
        }
    }
    assert!(scanned > 1, "the scan found no machine-provider sources under {}", root.display());
    assert!(
        bypasses.is_empty(),
        "these provider mutations bypass send_mutation, so a retry can mint a new mutation_id \
         and the ledger cap does not count them; route them through send_mutation:\n{}",
        bypasses.join("\n")
    );
}

#[test]
fn the_mutate_bypass_detector_flags_a_call_outside_send_mutation() {
    let fixture = r#"
impl ProviderMachineRuntime {
    /// Only `self.client.mutate(request)` may send.
    fn send_mutation<T>(&mut self, request: protocol::ProviderRequest) -> anyhow::Result<T> {
        if true { let _ = 1; }
        Ok(self.client.mutate(request)?)
    }

    fn connect_directly(&mut self) -> anyhow::Result<()> {
        // self.client.mutate(request) in a comment is fine
        let _: protocol::ConnectExternalMachineResult = self.client.mutate(request)?;
        let _ = self
            .client
            .mutate::<protocol::CreateMachineResult>(create)?;
        Ok(())
    }
}
"#;
    assert_eq!(provider_mutate_calls_outside_send_mutation(fixture), vec![11, 14]);
}
