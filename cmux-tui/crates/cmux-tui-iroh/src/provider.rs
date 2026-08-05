use std::collections::HashMap;
use std::os::unix::fs::{FileTypeExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_tui_machine_protocol::{
    BearerToken, CloseMachineResult, HelloResult, MachineDescriptor, MachineStatus, OpaqueId,
    OpenMachineResult, Protocol, ProviderCapabilities, ProviderError, ProviderErrorCode,
    ProviderRequest, RequestEnvelope, ResponseEnvelope, ScopeDescriptor, ScopeKind, SnapshotResult,
    TransportDescriptor, TransportHandshake, TransportHandshakeResult, TransportRole, Version,
    WorkspaceCreatePolicy,
};
use serde::Serialize;
use subtle::ConstantTimeEq as _;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::broker::{Binding, Platform, unix_time};
use crate::grant::{verify_grant_pair, verify_pair_grant};
use crate::transport::{
    EndpointRuntime, bridge_unix_and_iroh, is_stream_closed, read_json_line, send_admission,
    write_bounded_json_line,
};

const CONTROL_FRAME_BYTES: usize = 1024 * 1024;
const TRANSPORT_HANDSHAKE_BYTES: usize = 64 * 1024;
const TICKET_LIFETIME: Duration = Duration::from_secs(30);
const MAX_PROVIDER_CONNECTIONS: usize = 64;
const MAX_PROVIDER_TICKETS: usize = 128;
const PROVIDER_ID: &str = "cmux-iroh-account";
const SCOPE_ID: &str = "cmux-account";

pub async fn serve(
    runtime: Arc<EndpointRuntime>,
    socket_path: PathBuf,
    shutdown: CancellationToken,
) -> Result<()> {
    let listener = bind_owner_socket(&socket_path)?;
    let state = Arc::new(ProviderState::new(Arc::clone(&runtime)));
    let mut connections = JoinSet::new();
    let refresh_shutdown = shutdown.child_token();
    let refresh_runtime = Arc::clone(&runtime);
    let mut refresh =
        tokio::spawn(
            async move { refresh_runtime.refresh_until_cancelled(refresh_shutdown).await },
        );
    let mut refresh_finished = false;
    let mut serve_result = Ok(());
    loop {
        tokio::select! {
            _ = shutdown.cancelled() => break,
            result = &mut refresh => {
                refresh_finished = true;
                serve_result = match result {
                    Ok(result) => result,
                    Err(error) => Err(anyhow::anyhow!("relay refresh task failed: {error}")),
                };
                break;
            }
            completed = connections.join_next(), if !connections.is_empty() => {
                match completed {
                    Some(Ok(Err(error))) => {
                        eprintln!("cmux-tui-iroh: provider request denied or closed: {error:#}");
                    }
                    Some(Err(error)) => {
                        eprintln!("cmux-tui-iroh: provider connection task failed: {error}");
                    }
                    _ => {}
                }
            }
            accepted = listener.accept() => {
                // Break instead of returning so the cleanup below still runs
                // (cancel connections, remove the socket file, close iroh).
                let stream = match accepted {
                    Ok((stream, _)) => stream,
                    Err(error) => {
                        serve_result =
                            Err(anyhow::Error::new(error)
                                .context("cannot accept provider connection"));
                        break;
                    }
                };
                if connections.len() >= MAX_PROVIDER_CONNECTIONS {
                    drop(stream);
                    continue;
                }
                let state = Arc::clone(&state);
                connections.spawn(async move { handle_connection(state, stream).await });
            }
        }
    }
    shutdown.cancel();
    state.invalidate_all().await;
    connections.shutdown().await;
    if !refresh_finished {
        let _ = refresh.await;
    }
    drop(listener);
    if socket_path.exists() {
        let _ = std::fs::remove_file(&socket_path);
    }
    runtime.close().await;
    serve_result
}

struct ProviderState {
    runtime: Arc<EndpointRuntime>,
    mutable: Mutex<ProviderMutable>,
}

struct ProviderMutable {
    generation: Option<String>,
    tickets: HashMap<String, Ticket>,
    connections: HashMap<Uuid, CancellationToken>,
}

struct Ticket {
    generation: String,
    connection_id: Uuid,
    expires_at: i64,
    remote: Binding,
    grant: String,
}

impl ProviderState {
    fn new(runtime: Arc<EndpointRuntime>) -> Self {
        Self {
            runtime,
            mutable: Mutex::new(ProviderMutable {
                generation: None,
                tickets: HashMap::new(),
                connections: HashMap::new(),
            }),
        }
    }

    async fn begin_generation(&self, token: &str) {
        let mut state = self.mutable.lock().await;
        for cancellation in state.connections.values() {
            cancellation.cancel();
        }
        state.connections.clear();
        state.tickets.clear();
        state.generation = Some(token.to_string());
    }

    async fn end_generation(&self, token: &str) {
        let mut state = self.mutable.lock().await;
        if state.generation.as_deref().is_some_and(|current| secret_eq(current, token)) {
            for cancellation in state.connections.values() {
                cancellation.cancel();
            }
            state.connections.clear();
            state.tickets.clear();
            state.generation = None;
        }
    }

    async fn generation_is_current(&self, token: &str) -> bool {
        self.mutable
            .lock()
            .await
            .generation
            .as_deref()
            .is_some_and(|current| secret_eq(current, token))
    }

    async fn insert_ticket(&self, value: String, ticket: Ticket) -> Result<()> {
        let mut state = self.mutable.lock().await;
        ensure!(
            state
                .generation
                .as_deref()
                .is_some_and(|current| secret_eq(current, &ticket.generation)),
            "provider generation was replaced"
        );
        state.tickets.retain(|_, ticket| ticket.expires_at > now_lossy());
        ensure!(state.tickets.len() < MAX_PROVIDER_TICKETS, "provider ticket capacity exhausted");
        state.tickets.insert(value, ticket);
        Ok(())
    }

    async fn consume_ticket(&self, generation: &str, value: &str) -> Result<Ticket> {
        let mut state = self.mutable.lock().await;
        ensure!(
            state.generation.as_deref().is_some_and(|current| secret_eq(current, generation)),
            "provider generation is not current"
        );
        let key = state
            .tickets
            .keys()
            .find(|candidate| secret_eq(candidate, value))
            .cloned()
            .context("transport ticket is invalid or already used")?;
        let ticket = state.tickets.remove(&key).expect("ticket key came from map");
        ensure!(ticket.expires_at > unix_time()? as i64, "transport ticket expired");
        ensure!(secret_eq(&ticket.generation, generation), "transport ticket generation changed");
        Ok(ticket)
    }

    async fn register_connection(&self, id: Uuid, cancellation: CancellationToken) {
        self.mutable.lock().await.connections.insert(id, cancellation);
    }

    async fn remove_connection(&self, id: Uuid) {
        self.mutable.lock().await.connections.remove(&id);
    }

    async fn close_connection(&self, id: Uuid) {
        let mut state = self.mutable.lock().await;
        state.tickets.retain(|_, ticket| ticket.connection_id != id);
        if let Some(cancellation) = state.connections.remove(&id) {
            cancellation.cancel();
        }
    }

    async fn invalidate_all(&self) {
        let mut state = self.mutable.lock().await;
        for cancellation in state.connections.values() {
            cancellation.cancel();
        }
        state.connections.clear();
        state.tickets.clear();
        state.generation = None;
    }
}

type LocalReader = tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>;
type LocalWriter = tokio::net::unix::OwnedWriteHalf;

async fn handle_connection(state: Arc<ProviderState>, stream: UnixStream) -> Result<()> {
    // One buffered reader per connection for its whole lifetime; bytes after
    // any newline stay available to later reads and to the transport bridge.
    let (read_half, write_half) = stream.into_split();
    let mut reader = tokio::io::BufReader::new(read_half);
    let first: serde_json::Value = read_json_line(&mut reader, CONTROL_FRAME_BYTES).await?;
    if first.get("role").is_some() {
        let handshake: TransportHandshake =
            serde_json::from_value(first).context("transport handshake is invalid")?;
        handle_transport(state, reader, write_half, handshake).await
    } else {
        let hello: RequestEnvelope =
            serde_json::from_value(first).context("provider hello is invalid")?;
        handle_control(state, reader, write_half, hello).await
    }
}

async fn handle_control(
    state: Arc<ProviderState>,
    mut reader: LocalReader,
    mut writer: LocalWriter,
    hello: RequestEnvelope,
) -> Result<()> {
    let ProviderRequest::Hello(params) = hello.request else {
        bail!("first provider request must be hello");
    };
    ensure!(params.client.supported_versions.contains(&1), "client does not support provider v1");
    let generation = params.token.expose().to_string();
    state.begin_generation(&generation).await;
    write_response(
        &mut writer,
        ResponseEnvelope::success(
            hello.id,
            HelloResult {
                provider_id: opaque(PROVIDER_ID)?,
                provider_name: "cmux iroh account".into(),
                negotiated_version: Version,
            },
        ),
    )
    .await?;

    let result = control_loop(&state, &generation, &mut reader, &mut writer).await;
    state.end_generation(&generation).await;
    result
}

async fn control_loop(
    state: &Arc<ProviderState>,
    generation: &str,
    reader: &mut LocalReader,
    stream: &mut LocalWriter,
) -> Result<()> {
    loop {
        let request: RequestEnvelope = match read_json_line(reader, CONTROL_FRAME_BYTES).await {
            Ok(request) => request,
            Err(error) if is_closed_stream_error(&error) => return Ok(()),
            Err(error) => return Err(error),
        };
        ensure!(state.generation_is_current(generation).await, "provider generation was replaced");
        let id = request.id;
        match request.request {
            ProviderRequest::Snapshot(_) => match snapshot(&state.runtime).await {
                Ok(snapshot) => {
                    write_response(stream, ResponseEnvelope::success(id, snapshot)).await?;
                }
                Err(_) => {
                    write_response(
                        stream,
                        ResponseEnvelope::<SnapshotResult>::failure(
                            id,
                            provider_error(
                                ProviderErrorCode::Unavailable,
                                "broker discovery failed",
                                true,
                            ),
                        ),
                    )
                    .await?;
                }
            },
            ProviderRequest::OpenMachine(params) => {
                match open_machine(state, generation, params.machine_id.as_str()).await {
                    Ok(opened) => {
                        write_response(stream, ResponseEnvelope::success(id, opened)).await?;
                    }
                    Err(_) => {
                        write_response(
                            stream,
                            ResponseEnvelope::<OpenMachineResult>::failure(
                                id,
                                provider_error(
                                    ProviderErrorCode::Unavailable,
                                    "machine connection could not be opened",
                                    true,
                                ),
                            ),
                        )
                        .await?;
                    }
                }
            }
            ProviderRequest::CloseMachine(params) => {
                let parsed = Uuid::parse_str(params.connection_id.as_str());
                match parsed {
                    Ok(connection_id) => {
                        state.close_connection(connection_id).await;
                        // Never fabricate a revision: the close itself is
                        // idempotent, so a retry after this retryable failure
                        // reads the authoritative revision.
                        match state.runtime.fresh_discovery().await {
                            Ok(snapshot) => {
                                write_response(
                                    stream,
                                    ResponseEnvelope::success(
                                        id,
                                        CloseMachineResult { revision: snapshot.revision },
                                    ),
                                )
                                .await?;
                            }
                            Err(_) => {
                                write_response(
                                    stream,
                                    ResponseEnvelope::<CloseMachineResult>::failure(
                                        id,
                                        provider_error(
                                            ProviderErrorCode::Unavailable,
                                            "broker discovery failed after close",
                                            true,
                                        ),
                                    ),
                                )
                                .await?;
                            }
                        }
                    }
                    Err(_) => {
                        write_response(
                            stream,
                            ResponseEnvelope::<CloseMachineResult>::failure(
                                id,
                                provider_error(
                                    ProviderErrorCode::InvalidInput,
                                    "connection ID is invalid",
                                    false,
                                ),
                            ),
                        )
                        .await?;
                    }
                }
            }
            ProviderRequest::Hello(_) => {
                write_response(
                    stream,
                    ResponseEnvelope::<HelloResult>::failure(
                        id,
                        provider_error(
                            ProviderErrorCode::Conflict,
                            "hello already completed",
                            false,
                        ),
                    ),
                )
                .await?;
            }
            _ => {
                write_response(
                    stream,
                    ResponseEnvelope::<serde_json::Value>::failure(
                        id,
                        provider_error(
                            ProviderErrorCode::InvalidInput,
                            "provider method is unsupported",
                            false,
                        ),
                    ),
                )
                .await?;
            }
        }
    }
}

async fn snapshot(runtime: &EndpointRuntime) -> Result<SnapshotResult> {
    let snapshot = runtime.fresh_discovery().await?;
    let machines = snapshot
        .bindings
        .into_iter()
        .filter(|binding| {
            binding.platform == Platform::Linux
                && binding.pairing_enabled
                && binding.device_id != runtime.binding.device_id
        })
        .map(machine_descriptor)
        .collect::<Result<Vec<_>>>()?;
    Ok(SnapshotResult {
        revision: snapshot.revision,
        scopes: vec![ScopeDescriptor {
            id: opaque(SCOPE_ID)?,
            display_name: "cmux account".into(),
            kind: ScopeKind::Personal,
            can_admin: false,
        }],
        selected_scope_id: opaque(SCOPE_ID)?,
        machines,
        selected_machine_id: None,
        capabilities: ProviderCapabilities::default(),
        actions: Vec::new(),
        notice: None,
    })
}

async fn open_machine(
    state: &Arc<ProviderState>,
    generation: &str,
    machine_id: &str,
) -> Result<OpenMachineResult> {
    let target_id = Uuid::parse_str(machine_id).context("machine ID is invalid")?;
    let snapshot = state.runtime.fresh_discovery().await?;
    let initiator = snapshot
        .bindings
        .iter()
        .find(|binding| binding.binding_id == state.runtime.binding.binding_id)
        .context("initiator binding is unavailable")?;
    let acceptor = snapshot
        .bindings
        .iter()
        .find(|binding| binding.binding_id == target_id)
        .context("machine binding is unavailable")?;
    ensure!(acceptor.platform == Platform::Linux, "machine is not a TUI server");
    ensure!(acceptor.pairing_enabled, "machine pairing is disabled");
    ensure!(acceptor.device_id != initiator.device_id, "machine uses the initiator device");
    let grant = state
        .runtime
        .broker
        .issue_pair_grant(&state.runtime.credential, initiator.binding_id, acceptor.binding_id)
        .await?;
    let now = unix_time()? as i64;
    let claims = verify_pair_grant(&grant.grant, &snapshot.grant_verification_keys, now)?;
    verify_grant_pair(&claims, initiator, acceptor)?;

    let ticket_value = random_bearer(32)?;
    let expires_at = now + TICKET_LIFETIME.as_secs() as i64;
    let connection_id = Uuid::new_v4();
    state
        .insert_ticket(
            ticket_value.clone(),
            Ticket {
                generation: generation.to_string(),
                connection_id,
                expires_at,
                remote: acceptor.clone(),
                grant: grant.grant,
            },
        )
        .await?;
    Ok(OpenMachineResult {
        connection_id: opaque(&connection_id.to_string())?,
        transport: TransportDescriptor::ProviderStream {
            ticket: BearerToken::new(ticket_value)
                .map_err(|_| anyhow::anyhow!("generated ticket is invalid"))?,
            expires_at: OffsetDateTime::from_unix_timestamp(expires_at)?.format(&Rfc3339)?,
        },
        workspace_mirror_authority: None,
    })
}

async fn handle_transport(
    state: Arc<ProviderState>,
    local_reader: LocalReader,
    local_writer: LocalWriter,
    handshake: TransportHandshake,
) -> Result<()> {
    ensure!(handshake.protocol == Protocol, "transport protocol is invalid");
    ensure!(handshake.version == Version, "transport version is invalid");
    ensure!(handshake.role == TransportRole::Transport, "transport role is invalid");
    let generation = handshake.token.expose().to_string();
    let ticket = state.consume_ticket(&generation, handshake.ticket.expose()).await?;
    // Register the cancellation token before dialing so a concurrent
    // CloseMachine can abort the setup instead of missing the map entry
    // while the dial and admission are still in flight.
    let connection_id = ticket.connection_id;
    let cancellation = CancellationToken::new();
    state.register_connection(connection_id, cancellation.clone()).await;
    let result = run_transport(&state, ticket, local_reader, local_writer, cancellation).await;
    state.remove_connection(connection_id).await;
    result
}

async fn run_transport(
    state: &Arc<ProviderState>,
    ticket: Ticket,
    local_reader: LocalReader,
    mut local_writer: LocalWriter,
    cancellation: CancellationToken,
) -> Result<()> {
    let connection = tokio::select! {
        _ = cancellation.cancelled() => bail!("machine connection was closed during dial"),
        connection = state.runtime.dial(&ticket.remote.endpoint_id) => connection?,
    };
    let (mut sender, receiver) = connection.open_bi().await.context("cannot open iroh stream")?;
    let mut receiver = tokio::io::BufReader::new(receiver);
    send_admission(&mut sender, &mut receiver, &ticket.grant).await?;
    if cancellation.is_cancelled() {
        connection.close(0_u8.into(), b"provider transport closed");
        bail!("machine connection was closed during setup");
    }
    write_bounded_json_line(
        &mut local_writer,
        &TransportHandshakeResult { accepted: true },
        TRANSPORT_HANDSHAKE_BYTES,
    )
    .await?;

    eprintln!(
        "cmux-tui-iroh: connected machine={} peer={} path=relay address_source=endpoint_id+verified_catalog",
        ticket.remote.binding_id,
        connection.remote_id().fmt_short(),
    );
    let result =
        bridge_unix_and_iroh(local_reader, local_writer, sender, receiver, cancellation).await;
    connection.close(0_u8.into(), b"provider transport closed");
    result
}

fn machine_descriptor(binding: Binding) -> Result<MachineDescriptor> {
    let endpoint_prefix = &binding.endpoint_id[..10];
    Ok(MachineDescriptor {
        id: opaque(&binding.binding_id.to_string())?,
        display_name: binding.display_name.unwrap_or_else(|| format!("cmux-tui {endpoint_prefix}")),
        subtitle: format!("Endpoint {endpoint_prefix}"),
        status: MachineStatus::Running,
        connectable: binding.pairing_enabled,
        workspace_create: WorkspaceCreatePolicy::Session,
    })
}

async fn write_response<T: Serialize>(
    stream: &mut LocalWriter,
    response: ResponseEnvelope<T>,
) -> Result<()> {
    write_bounded_json_line(stream, &response, CONTROL_FRAME_BYTES).await
}

fn provider_error(code: ProviderErrorCode, message: &str, retryable: bool) -> ProviderError {
    ProviderError { code, message: message.to_string(), retryable }
}

fn opaque(value: &str) -> Result<OpaqueId> {
    OpaqueId::new(value).map_err(|_| anyhow::anyhow!("provider identifier is invalid"))
}

fn random_bearer(bytes: usize) -> Result<String> {
    let mut value = vec![0_u8; bytes];
    getrandom::fill(&mut value).context("cannot generate provider ticket")?;
    Ok(URL_SAFE_NO_PAD.encode(value))
}

fn secret_eq(left: &str, right: &str) -> bool {
    left.len() == right.len() && bool::from(left.as_bytes().ct_eq(right.as_bytes()))
}

fn now_lossy() -> i64 {
    unix_time().ok().and_then(|value| i64::try_from(value).ok()).unwrap_or(i64::MAX)
}

fn is_closed_stream_error(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause.downcast_ref::<std::io::Error>().is_some_and(|error| {
            matches!(
                error.kind(),
                std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionReset
            )
        })
    }) || is_stream_closed(error)
}

fn bind_owner_socket(path: &Path) -> Result<UnixListener> {
    let parent = path.parent().context("provider socket has no parent")?;
    ensure_secure_directory(parent, DirectoryAccess::ManagedOwnerOnly)
        .with_context(|| format!("cannot secure provider socket directory {}", parent.display()))?;
    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            bail!("provider socket {} is already active", path.display());
        }
        let metadata = std::fs::symlink_metadata(path)?;
        ensure!(metadata.file_type().is_socket(), "stale provider path is not a socket");
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() },
            "stale provider socket has wrong owner"
        );
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)
        .with_context(|| format!("cannot bind provider socket {}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}
