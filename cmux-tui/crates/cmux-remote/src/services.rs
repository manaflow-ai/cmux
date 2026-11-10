use std::collections::BTreeMap;
use std::fmt;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{
    Lane, MUX_INPUT_V1_FEATURE, ProcessEvent, ProcessId, ProcessReplayRange, RouteId, RpcError,
    RpcErrorDetails, RpcEvent, RpcRequest, RpcResponse, Service, ServiceControl,
    TERMINAL_BYTES_VIEWER_SIZE_PRIORITY, TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED,
    WorkspaceRequest, WorkspaceResponse,
};
use cmux_tui_core::resource::TerminalPublicId;
#[cfg(unix)]
use cmux_tui_core::terminal_host::{
    CapabilityRights, CapabilityToken, ClientHello, ClientRole, HostHello, HostIncarnation,
    TerminalId,
};
#[cfg(unix)]
use cmux_tui_core::terminal_host_protocol::{
    FLAG_SMART_RENDERER, FLAG_VIEWER_SIZE_ACKS, FLAG_VIEWER_SIZE_PRIORITY, Frame, FrameDecoder,
    HEADER_LEN, MAX_FRAME_PAYLOAD, MessageKind, PROTOCOL_VERSION, encode_frame, frame_payload_len,
};
#[cfg(unix)]
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, watch};
use tokio::task::JoinSet;

use cmux_link::carrier_grant::CarrierGrant;

use crate::acpmux_bridge;
use crate::crypto::ServiceAuthority;
use crate::daemon::ServerConnection;
use crate::service::{
    EndpointRole, IncomingStream, ServiceError, ServiceMultiplexer, ServiceStream, StreamBudget,
};
use crate::workspace::{
    ClientScope, PreparedRpcResponse, ProcessSubscriptionError, WorkspaceService,
};

const MAX_RPC_MESSAGE: usize = 16 * 1024 * 1024;
#[cfg(unix)]
const MAX_RENDERER_GRANT_LINE_BYTES: usize = 64 * 1024;
const RPC_CODEC_OFFLOAD_BYTES: usize = 64 * 1024;
// A JSON control escape can expand one input byte to six output bytes. Leave
// room for field names and collection punctuation without scanning strings on
// the latency-sensitive task.
const RPC_ERROR_CODEC_OFFLOAD_BYTES: usize = RPC_CODEC_OFFLOAD_BYTES / 8;
const COPY_CHUNK: usize = 32 * 1024;
const MAX_ACTIVE_SERVICE_STREAMS: usize = 64;
const MAX_INTERACTIVE_RPC_REQUESTS: usize = 32;
const MAX_CONTROL_RPC_REQUESTS: usize = 48;
const MAX_BULK_RPC_REQUESTS: usize = 48;
const CLIENT_HANDLER_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const MAX_BUFFERED_MUX_UPLOAD_BYTES: usize = 64 * 1024 * 1024;
const MAX_BUFFERED_MUX_NON_INTERACTIVE_BYTES: usize = 56 * 1024 * 1024;
const MAX_BUFFERED_MUX_BULK_BYTES: usize = 48 * 1024 * 1024;
const MAX_BUFFERED_MUX_MESSAGES_PER_LANE: usize = 4096;
const MIN_BUFFERED_MUX_MESSAGE_BYTES: usize = 1024;
#[cfg(unix)]
const TERMINAL_BYTES_HANDSHAKE_TTL_MS: u64 = 10_000;
#[cfg(unix)]
const TERMINAL_BYTES_HANDSHAKE_TIMEOUT: std::time::Duration =
    std::time::Duration::from_millis(TERMINAL_BYTES_HANDSHAKE_TTL_MS);
#[cfg(unix)]
const _: () = assert!(MAX_BUFFERED_MUX_NON_INTERACTIVE_BYTES < MAX_BUFFERED_MUX_UPLOAD_BYTES);
const _: () = assert!(MAX_BUFFERED_MUX_BULK_BYTES < MAX_BUFFERED_MUX_NON_INTERACTIVE_BYTES);

struct RequestAdmission {
    interactive: Arc<Semaphore>,
    control: Arc<Semaphore>,
    bulk: Arc<Semaphore>,
}

#[derive(Clone)]
struct MuxUploadBudget {
    total: Arc<Semaphore>,
    non_interactive: Arc<Semaphore>,
    bulk: Arc<Semaphore>,
}

struct MuxUploadPermit {
    _bulk: Option<OwnedSemaphorePermit>,
    _non_interactive: Option<OwnedSemaphorePermit>,
    _total: OwnedSemaphorePermit,
}

impl MuxUploadBudget {
    fn new() -> Self {
        Self {
            total: Arc::new(Semaphore::new(MAX_BUFFERED_MUX_UPLOAD_BYTES)),
            non_interactive: Arc::new(Semaphore::new(MAX_BUFFERED_MUX_NON_INTERACTIVE_BYTES)),
            bulk: Arc::new(Semaphore::new(MAX_BUFFERED_MUX_BULK_BYTES)),
        }
    }

    async fn acquire(
        &self,
        lane: Lane,
        encoded_bytes: usize,
    ) -> Result<MuxUploadPermit, ServicesError> {
        let charged = encoded_bytes.max(MIN_BUFFERED_MUX_MESSAGE_BYTES);
        let lane_capacity = match lane {
            Lane::Interactive => MAX_BUFFERED_MUX_UPLOAD_BYTES,
            Lane::Control => MAX_BUFFERED_MUX_NON_INTERACTIVE_BYTES,
            Lane::Bulk | Lane::Tunnel => MAX_BUFFERED_MUX_BULK_BYTES,
        };
        if charged > lane_capacity {
            return Err(ServicesError::MessageTooLarge(encoded_bytes));
        }
        let charged =
            u32::try_from(charged).map_err(|_| ServicesError::MessageTooLarge(encoded_bytes))?;
        let bulk = if matches!(lane, Lane::Bulk | Lane::Tunnel) {
            Some(
                self.bulk
                    .clone()
                    .acquire_many_owned(charged)
                    .await
                    .expect("mux upload budget is never closed"),
            )
        } else {
            None
        };
        let non_interactive = if lane == Lane::Interactive {
            None
        } else {
            Some(
                self.non_interactive
                    .clone()
                    .acquire_many_owned(charged)
                    .await
                    .expect("mux upload budget is never closed"),
            )
        };
        let total = self
            .total
            .clone()
            .acquire_many_owned(charged)
            .await
            .expect("mux upload budget is never closed");
        Ok(MuxUploadPermit { _bulk: bulk, _non_interactive: non_interactive, _total: total })
    }
}

struct ClientCleanupGuard {
    connection: Arc<ServerConnection>,
    workspace: WorkspaceService,
    scope: ClientScope,
    armed: bool,
}

impl ClientCleanupGuard {
    fn new(
        connection: Arc<ServerConnection>,
        workspace: WorkspaceService,
        scope: ClientScope,
    ) -> Self {
        Self { connection, workspace, scope, armed: true }
    }

    async fn close_connection(&self) {
        let _ = self.connection.close().await;
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ClientCleanupGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let connection = self.connection.clone();
        let workspace = self.workspace.clone();
        let scope = self.scope.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = connection.close().await;
                workspace.close_client(&scope).await;
                workspace.finish_client_close(&scope);
            });
        }
    }
}

struct ProcessReservationCleanup {
    workspace: WorkspaceService,
    scope: ClientScope,
    process: ProcessId,
    armed: bool,
}

impl ProcessReservationCleanup {
    fn new(workspace: WorkspaceService, scope: ClientScope, process: ProcessId) -> Self {
        Self { workspace, scope, process, armed: true }
    }

    async fn release(mut self) {
        self.workspace.release_process_reservation(&self.scope, self.process).await;
        self.armed = false;
    }
}

impl Drop for ProcessReservationCleanup {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let workspace = self.workspace.clone();
        let scope = self.scope.clone();
        let process = self.process;
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                workspace.release_process_reservation(&scope, process).await;
            });
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorkspaceRpcPurpose {
    Requests,
    Cancellation,
}

async fn wait_for_shutdown(shutdown: &mut watch::Receiver<bool>) {
    while !*shutdown.borrow() {
        if shutdown.changed().await.is_err() {
            break;
        }
    }
}

impl RequestAdmission {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            interactive: Arc::new(Semaphore::new(MAX_INTERACTIVE_RPC_REQUESTS)),
            control: Arc::new(Semaphore::new(MAX_CONTROL_RPC_REQUESTS)),
            bulk: Arc::new(Semaphore::new(MAX_BULK_RPC_REQUESTS)),
        })
    }

    fn for_lane(&self, lane: Lane) -> &Arc<Semaphore> {
        match lane {
            Lane::Interactive => &self.interactive,
            Lane::Control => &self.control,
            Lane::Bulk => &self.bulk,
            Lane::Tunnel => &self.bulk,
        }
    }
}

#[derive(Clone)]
pub struct DaemonServices {
    workspace: WorkspaceService,
    mux_socket: Option<PathBuf>,
    mux_upload_budget: MuxUploadBudget,
    /// The Unix sockets [`Service::LocalSocket`] may reach, fixed at start.
    local_sockets: Arc<[PathBuf]>,
    /// acpmux's carrier socket, which [`Service::Acpmux`] bridges to.
    acpmux_socket: Option<PathBuf>,
}

fn validate_renderer_host_hello(
    response: &Frame,
    request_id: u64,
    terminal_id: TerminalId,
    incarnation: HostIncarnation,
    viewer_size_priority: bool,
) -> Result<HostHello, ServicesError> {
    if response.kind != MessageKind::HostHello
        || response.request_id != request_id
        || response.flags & (FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS)
            != (FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS)
    {
        return Err(ServicesError::Remote(
            "terminal host rejected required renderer capabilities".into(),
        ));
    }
    if (response.flags & FLAG_VIEWER_SIZE_PRIORITY != 0) != viewer_size_priority {
        return Err(ServicesError::Remote(
            "terminal host viewer-size priority does not match the request".into(),
        ));
    }
    let host = HostHello::decode(&response.payload)
        .map_err(|error| ServicesError::Remote(format!("invalid terminal host hello: {error}")))?;
    if host.selected_version != PROTOCOL_VERSION
        || host.terminal_id != terminal_id
        || host.incarnation != incarnation
        || !host.granted_rights.contains(CapabilityRights::RENDERER)
    {
        return Err(ServicesError::Remote(
            "terminal host hello does not match renderer grant".into(),
        ));
    }
    Ok(host)
}

impl DaemonServices {
    pub fn new(workspace: WorkspaceService, mux_socket: Option<PathBuf>) -> Arc<Self> {
        Self::with_local_sockets(workspace, mux_socket, Vec::new())
    }

    /// [`DaemonServices::new`], and [`Service::LocalSocket`] may reach
    /// exactly `local_sockets` (absolute paths; anything else is dropped).
    /// The client's `path` must equal one entry byte for byte: nothing is
    /// resolved, so `..` or a symlink spelling never matches.
    pub fn with_local_sockets(
        workspace: WorkspaceService,
        mux_socket: Option<PathBuf>,
        local_sockets: Vec<PathBuf>,
    ) -> Arc<Self> {
        Self::with_carrier_sockets(workspace, mux_socket, local_sockets, None)
    }

    /// [`DaemonServices::with_local_sockets`], and [`Service::Acpmux`]
    /// bridges to acpmux's carrier socket `acpmux_socket` (see
    /// [`crate::acpmux_bridge`]); without one it refuses every open.
    pub fn with_carrier_sockets(
        workspace: WorkspaceService,
        mux_socket: Option<PathBuf>,
        local_sockets: Vec<PathBuf>,
        acpmux_socket: Option<PathBuf>,
    ) -> Arc<Self> {
        let local_sockets =
            local_sockets.into_iter().filter(|path| path.is_absolute()).collect::<Vec<_>>();
        Arc::new(Self {
            workspace,
            mux_socket,
            mux_upload_budget: MuxUploadBudget::new(),
            local_sockets: local_sockets.into(),
            acpmux_socket,
        })
    }

    pub async fn run(self: Arc<Self>, clients: mpsc::Receiver<Arc<ServerConnection>>) {
        let local = tokio::task::LocalSet::new();
        let (keepalive, shutdown) = watch::channel(false);
        local.run_until(self.run_local(clients, shutdown)).await;
        drop(keepalive);
    }

    /// Serve clients until the owner requests shutdown. This is intended for
    /// embedding the daemon in a foreground process whose synchronous TUI or
    /// signal loop owns lifecycle.
    pub async fn run_with_shutdown(
        self: Arc<Self>,
        clients: mpsc::Receiver<Arc<ServerConnection>>,
        shutdown: watch::Receiver<bool>,
    ) {
        let local = tokio::task::LocalSet::new();
        local.run_until(self.run_local(clients, shutdown)).await;
    }

    async fn run_local(
        self: Arc<Self>,
        mut clients: mpsc::Receiver<Arc<ServerConnection>>,
        mut shutdown: watch::Receiver<bool>,
    ) {
        let mut handlers = JoinSet::new();
        loop {
            tokio::select! {
                biased;
                _ = wait_for_shutdown(&mut shutdown) => break,
                client = clients.recv() => {
                    let Some(client) = client else { break };
                    let services = self.clone();
                    handlers.spawn_local(async move { services.serve_client(client).await });
                }
                completed = handlers.join_next(), if !handlers.is_empty() => {
                    let _ = completed;
                }
            }
        }
        self.workspace.shutdown().await;
        handlers.shutdown().await;
        self.workspace.shutdown().await;
    }

    pub async fn serve_client(
        self: &Arc<Self>,
        client: Arc<ServerConnection>,
    ) -> Result<(), ServicesError> {
        let scope = ClientScope::new(client.device_id.clone(), client.session_id);
        let mut cleanup =
            ClientCleanupGuard::new(client.clone(), self.workspace.clone(), scope.clone());
        let service_authority = client.service_authority().clone();
        let multiplexer = ServiceMultiplexer::new(client, EndpointRole::Daemon);
        let stream_slots = Arc::new(Semaphore::new(MAX_ACTIVE_SERVICE_STREAMS));
        let request_slots = RequestAdmission::new();
        let mut handlers = JoinSet::new();
        let result = loop {
            tokio::select! {
                incoming = multiplexer.accept() => {
                    let incoming = match incoming {
                        Ok(Some(incoming)) => incoming,
                        Ok(None) => break Ok(()),
                        Err(error) => break Err(error.into()),
                    };
                    let Some(incoming) = Self::authorize_service(&service_authority, incoming).await?
                    else {
                        continue;
                    };
                    let permit = match stream_slots.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => {
                            let _ = incoming
                                .stream
                                .reject(
                                    "resource-exhausted".into(),
                                    "too many active service streams for this client".into(),
                                )
                                .await;
                            continue;
                        }
                    };
                    let services = self.clone();
                    let scope = scope.clone();
                    let request_slots = request_slots.clone();
                    let grant = service_authority.grant().cloned();
                    handlers.spawn_local(async move {
                        let _permit = permit;
                        services.serve_stream(scope, request_slots, grant, incoming).await
                    });
                }
                completed = handlers.join_next(), if !handlers.is_empty() => {
                    match completed.expect("a non-empty handler set has a task") {
                        Ok(Ok(())) | Ok(Err(_)) => {}
                        Err(error) => break Err(ServicesError::RequestTask(error)),
                    }
                }
            }
        };
        multiplexer.shutdown().await;
        cleanup.close_connection().await;
        self.workspace.close_client(&scope).await;
        let drain = async {
            let mut task_error = None;
            while let Some(completed) = handlers.join_next().await {
                if let Err(error) = completed
                    && task_error.is_none()
                {
                    task_error = Some(ServicesError::RequestTask(error));
                }
            }
            task_error
        };
        let outcome = match tokio::time::timeout(CLIENT_HANDLER_DRAIN_TIMEOUT, drain).await {
            Ok(Some(error)) => Err(error),
            Ok(None) => result,
            Err(_) => {
                handlers.abort_all();
                while handlers.join_next().await.is_some() {}
                result
            }
        };
        self.workspace.close_client(&scope).await;
        self.workspace.finish_client_close(&scope);
        cleanup.disarm();
        outcome
    }

    async fn authorize_service(
        authority: &ServiceAuthority,
        incoming: IncomingStream,
    ) -> Result<Option<IncomingStream>, ServicesError> {
        if authority.allows(incoming.service) {
            return Ok(Some(incoming));
        }
        let message = if incoming.service == Service::Acpmux {
            // The bridge's own reason: no grant, or a grant without acpmux.
            acpmux_bridge::header(authority.grant().map(Arc::as_ref))
                .err()
                .unwrap_or("acpmux.not_granted")
                .to_owned()
        } else {
            let service = serde_json::to_string(&incoming.service)?;
            format!("the client grant does not allow {}", service.trim_matches('"'))
        };
        incoming.stream.reject("permission-denied".into(), message).await?;
        Ok(None)
    }

    async fn serve_stream(
        self: Arc<Self>,
        scope: ClientScope,
        request_slots: Arc<RequestAdmission>,
        grant: Option<Arc<CarrierGrant>>,
        incoming: IncomingStream,
    ) -> Result<(), ServicesError> {
        let workspace = self.workspace.clone();
        let mux_socket = self.mux_socket.clone();
        let mux_upload_budget = self.mux_upload_budget.clone();
        match incoming.service {
            Service::WorkspaceRpc => {
                Self::serve_workspace_rpc(
                    workspace,
                    scope,
                    request_slots,
                    incoming.stream,
                    incoming.metadata,
                )
                .await
            }
            Service::ProcessStream => {
                Self::serve_process_stream(workspace, scope, incoming.stream, incoming.metadata)
                    .await
            }
            Service::TerminalBytes => {
                Self::serve_terminal_bytes(mux_socket, incoming.stream, incoming.metadata).await
            }
            Service::TcpTunnel => {
                Self::serve_tcp_tunnel(workspace, incoming.stream, incoming.metadata).await
            }
            Service::LocalSocket => {
                Self::serve_local_socket(&self.local_sockets, incoming.stream, incoming.metadata)
                    .await
            }
            Service::Acpmux => {
                Self::serve_acpmux(self.acpmux_socket.as_deref(), grant.as_deref(), incoming.stream)
                    .await
            }
            Service::MuxControl => {
                Self::serve_mux_control_with_budget(
                    mux_socket,
                    grant.as_deref(),
                    incoming.stream,
                    mux_upload_budget,
                )
                .await
            }
            Service::ComputerUse => {
                incoming
                    .stream
                    .reject(
                        "unsupported".to_string(),
                        "computer-use provider is not configured".to_string(),
                    )
                    .await?;
                Ok(())
            }
        }
    }

    async fn serve_workspace_rpc(
        workspace: WorkspaceService,
        scope: ClientScope,
        request_slots: Arc<RequestAdmission>,
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let (lane, purpose) = workspace_rpc_metadata(&metadata)?;
        let stream = Arc::new(stream);
        send_opened(&stream, lane).await?;
        let messages = Arc::new(MessageStream::with_lane(stream, lane));
        let mut requests = JoinSet::new();
        loop {
            let encoded = tokio::select! {
                encoded = messages.receive() => encoded?,
                result = requests.join_next(), if !requests.is_empty() => {
                    match result.expect("a non-empty request set has a task") {
                        Ok(result) => result?,
                        Err(error) => return Err(ServicesError::RequestTask(error)),
                    }
                    continue;
                }
            };
            let Some(encoded) = encoded else { break };
            let request = decode_workspace_request(&workspace, purpose, encoded).await?;
            let request_id = request.id;
            if purpose == WorkspaceRpcPurpose::Cancellation
                && !matches!(&request.request, WorkspaceRequest::CancelRequest { .. })
            {
                let response = RpcResponse {
                    id: request_id,
                    result: Err(RpcError::new(
                        "invalid-request",
                        "the cancellation stream accepts only cancel-request messages",
                    )),
                };
                send_workspace_response(&workspace, &messages, response, false).await?;
                continue;
            }
            if matches!(&request.request, WorkspaceRequest::CancelRequest { .. }) {
                // Cancellation must remain available when ordinary work fills
                // admission. Inline handling also bounds cancellation floods.
                let response = workspace.prepare_rpc_for(scope.clone(), request).await;
                send_prepared_workspace_response(&workspace, &messages, response, false).await?;
                continue;
            }
            let permit = match request_slots.for_lane(lane).clone().try_acquire_owned() {
                Ok(permit) => permit,
                Err(_) => {
                    let response = RpcResponse {
                        id: request_id,
                        result: Err(RpcError::new(
                            "resource-exhausted",
                            "too many active workspace requests for this client",
                        )),
                    };
                    send_workspace_response(&workspace, &messages, response, false).await?;
                    continue;
                }
            };
            if !crate::workspace::request_supports_cancellation(&request.request) {
                // Mutations execute in receive order on their traffic-class
                // stream and are never aborted because a response stream ends.
                let _permit = permit;
                let response = workspace.prepare_rpc_for(scope.clone(), request).await;
                send_prepared_workspace_response(&workspace, &messages, response, true).await?;
                continue;
            }
            let workspace = workspace.clone();
            let scope = scope.clone();
            let messages = messages.clone();
            requests.spawn_local(async move {
                let _permit = permit;
                let response = workspace.prepare_rpc_for(scope, request).await;
                send_prepared_workspace_response(&workspace, &messages, response, true).await
            });
        }
        requests.abort_all();
        while let Some(result) = requests.join_next().await {
            match result {
                Ok(result) => result?,
                Err(error) if error.is_cancelled() => {}
                Err(error) => return Err(ServicesError::RequestTask(error)),
            }
        }
        Ok(())
    }

    async fn serve_process_stream(
        workspace: WorkspaceService,
        scope: ClientScope,
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let stream = Arc::new(stream);
        let (process, after, reserve) = match process_stream_metadata(&metadata) {
            Ok(metadata) => metadata,
            Err(error) => {
                stream.reject(error.code, error.message).await?;
                return Ok(());
            }
        };
        let subscription =
            workspace.subscribe_or_reserve_process(&scope, process, after, reserve).await;
        let mut subscription = match subscription {
            Ok(subscription) => subscription,
            Err(error) => {
                let RpcError { code, message, details, .. } = error;
                let Some(RpcErrorDetails::ProcessReplayGap { requested_after, range }) = details
                else {
                    stream.reject(code, message).await?;
                    return Ok(());
                };
                send_opened(&stream, Lane::Bulk).await?;
                let messages = MessageStream::with_lane(stream, Lane::Bulk);
                send_replay_gap(&messages, process, requested_after, range).await?;
                messages.close().await?;
                return Ok(());
            }
        };
        let reservation_cleanup = reserve
            .then(|| ProcessReservationCleanup::new(workspace.clone(), scope.clone(), process));
        send_opened(&stream, Lane::Bulk).await?;
        let messages = MessageStream::with_lane(stream, Lane::Bulk);
        let result = loop {
            tokio::select! {
                event = subscription.recv() => match event {
                    Ok(event) => {
                        let terminal = event.event.is_terminal();
                        messages.send(&serde_json::to_vec(&event)?).await?;
                        if terminal {
                            messages.close().await?;
                            break Ok(());
                        }
                    }
                    Err(ProcessSubscriptionError::Closed) => {
                        messages.close().await?;
                        break Ok(());
                    }
                    Err(ProcessSubscriptionError::ReplayGap {
                        requested_after,
                        range,
                        ..
                    }) => {
                        send_replay_gap(&messages, process, requested_after, range).await?;
                        messages.close().await?;
                        break Ok(());
                    }
                },
                closed = messages.receive() => match closed? {
                    None => break Ok(()),
                    Some(_) => {
                        break Err(ServicesError::Remote(
                            "process event streams are output-only".into(),
                        ));
                    }
                }
            }
        };
        if let Some(cleanup) = reservation_cleanup {
            cleanup.release().await;
        }
        result
    }

    async fn serve_tcp_tunnel(
        workspace: WorkspaceService,
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let route = RouteId(parse_u64(&metadata, "route")?);
        let socket = workspace
            .dial_route(route)
            .await
            .map_err(|error| ServicesError::Remote(error.message))?;
        let stream = Arc::new(stream);
        send_opened(&stream, Lane::Tunnel).await?;
        let (reader, writer) = socket.into_split();
        pump_stream(stream, reader, writer).await
    }

    /// A byte stream to one allowlisted Unix socket. The session already
    /// holds [`Service::LocalSocket`] (only an owner's grant carries it);
    /// the path must also be on this daemon's allowlist.
    async fn serve_local_socket(
        allowlist: &[PathBuf],
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        if allowlist.is_empty() {
            stream
                .reject("unavailable".into(), "this daemon serves no local sockets".into())
                .await?;
            return Ok(());
        }
        let Some(path) = metadata.get("path") else {
            stream.reject("invalid-argument".into(), "missing metadata path".into()).await?;
            return Ok(());
        };
        let Some(target) = allowlist.iter().find(|allowed| allowed.as_os_str() == path.as_str())
        else {
            stream
                .reject(
                    "permission-denied".into(),
                    "the path is not on this daemon's local socket allowlist".into(),
                )
                .await?;
            return Ok(());
        };
        #[cfg(unix)]
        {
            let socket = match tokio::net::UnixStream::connect(target).await {
                Ok(socket) => socket,
                Err(error) => {
                    stream
                        .reject(
                            "unavailable".into(),
                            format!("the local socket did not answer: {}", error.kind()),
                        )
                        .await?;
                    return Ok(());
                }
            };
            let stream = Arc::new(stream);
            send_opened(&stream, Lane::Tunnel).await?;
            let (reader, writer) = socket.into_split();
            pump_stream(stream, reader, writer).await
        }
        #[cfg(not(unix))]
        {
            let _ = target;
            stream.reject("unsupported".into(), "local sockets need a Unix host".into()).await?;
            Ok(())
        }
    }

    /// One acpmux connection for the person the session's carrier grant
    /// names (`crate::acpmux_bridge`). A grant the bridge refuses is
    /// refused before the socket is dialed.
    async fn serve_acpmux(
        socket: Option<&Path>,
        grant: Option<&CarrierGrant>,
        stream: ServiceStream,
    ) -> Result<(), ServicesError> {
        let header = match acpmux_bridge::header(grant) {
            Ok(header) => header,
            Err(reason) => {
                stream.reject("permission-denied".into(), reason.into()).await?;
                return Ok(());
            }
        };
        let Some(socket) = socket else {
            stream.reject("unavailable".into(), "this daemon bridges to no acpmux".into()).await?;
            return Ok(());
        };
        #[cfg(unix)]
        {
            let ws = match acpmux_bridge::connect(socket, &header).await {
                Ok(ws) => ws,
                Err(error) => {
                    stream
                        .reject(
                            "unavailable".into(),
                            format!("acpmux's carrier socket did not answer: {}", error.kind()),
                        )
                        .await?;
                    return Ok(());
                }
            };
            let stream = Arc::new(stream);
            send_opened(&stream, Lane::Tunnel).await?;
            // The stream's bytes cross a pipe so the relay reads lines from
            // it as from any reader; each side's end reaches the other.
            let (near, far) = tokio::io::duplex(2 * COPY_CHUNK);
            let (far_reader, far_writer) = tokio::io::split(far);
            let (near_reader, near_writer) = tokio::io::split(near);
            let (pumped, relayed) = tokio::join!(
                pump_stream(stream, far_reader, far_writer),
                acpmux_bridge::relay(ws, near_reader, near_writer),
            );
            relayed?;
            pumped
        }
        #[cfg(not(unix))]
        {
            let _ = (socket, header);
            stream.reject("unsupported".into(), "acpmux needs a Unix host".into()).await?;
            Ok(())
        }
    }

    #[cfg(unix)]
    async fn serve_terminal_bytes(
        mux_socket: Option<PathBuf>,
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let stream = Arc::new(stream);
        let request = match terminal_bytes_metadata(&metadata) {
            Ok(request) => request,
            Err(error) => {
                stream.reject("invalid-argument".into(), error.to_string()).await?;
                return Ok(());
            }
        };
        let Some(mux_path) = mux_socket.as_ref() else {
            stream
                .reject("unavailable".into(), "mux control socket is not configured".into())
                .await?;
            return Ok(());
        };

        let terminal = match tokio::time::timeout(
            TERMINAL_BYTES_HANDSHAKE_TIMEOUT,
            Self::negotiate_terminal_bytes(mux_path, request),
        )
        .await
        {
            Ok(Ok(terminal)) => terminal,
            Ok(Err(error)) => {
                stream.reject("terminal-unavailable".into(), error.to_string()).await?;
                return Ok(());
            }
            Err(_) => {
                stream
                    .reject("timeout".into(), "terminal renderer handshake timed out".into())
                    .await?;
                return Ok(());
            }
        };

        send_opened(&stream, Lane::Interactive).await?;
        let (reader, writer) = terminal.into_split();
        pump_stream(stream, reader, writer).await
    }

    #[cfg(unix)]
    async fn negotiate_terminal_bytes(
        mux_path: &Path,
        terminal_request: TerminalBytesRequest,
    ) -> Result<tokio::net::UnixStream, ServicesError> {
        // The control socket only brokers a one-use renderer grant. The
        // durable terminal-host owner token never crosses the remote session.
        let mut mux = connect_owned_unix_socket(mux_path).await?;
        let request = serde_json::to_vec(&serde_json::json!({
            "id": 1,
            "cmd": "mint-terminal-renderer-by-terminal",
            "terminal": terminal_request.terminal,
            "ttl_ms": TERMINAL_BYTES_HANDSHAKE_TTL_MS,
        }))?;
        mux.write_all(&request).await?;
        mux.write_all(b"\n").await?;
        mux.flush().await?;
        let mut response = String::new();
        let size = BufReader::new(mux)
            .take((MAX_RENDERER_GRANT_LINE_BYTES + 1) as u64)
            .read_line(&mut response)
            .await?;
        if size == 0 {
            return Err(ServicesError::Remote("mux closed before renderer grant".into()));
        }
        if size > MAX_RENDERER_GRANT_LINE_BYTES || !response.ends_with('\n') {
            return Err(ServicesError::Remote("renderer grant response exceeds size limit".into()));
        }
        let response: serde_json::Value = serde_json::from_str(&response)?;
        if response.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
            return Err(ServicesError::Remote(
                response
                    .get("error")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("renderer grant denied")
                    .to_string(),
            ));
        }
        let grant = response
            .get("data")
            .ok_or_else(|| ServicesError::Remote("renderer grant omitted data".into()))?;
        let endpoint = required_json_string(grant, "endpoint")?;
        let terminal_id = TerminalId::from_hex(required_json_string(grant, "terminal_id")?)
            .ok_or_else(|| {
                ServicesError::Remote("renderer grant has invalid terminal id".into())
            })?;
        let incarnation = HostIncarnation::from_hex(required_json_string(grant, "incarnation")?)
            .ok_or_else(|| {
                ServicesError::Remote("renderer grant has invalid incarnation".into())
            })?;
        let token =
            CapabilityToken::from_bytes(decode_hex_32(required_json_string(grant, "token")?)?);
        let rights = grant
            .get("rights")
            .and_then(serde_json::Value::as_u64)
            .and_then(|bits| u32::try_from(bits).ok())
            .and_then(CapabilityRights::from_bits)
            .ok_or_else(|| ServicesError::Remote("renderer grant has invalid rights".into()))?;
        if !rights.contains(CapabilityRights::RENDERER) {
            return Err(ServicesError::Remote("renderer grant lacks renderer rights".into()));
        }
        // Hosts that predate the flag reject the whole hello, so a client's
        // request falls back to the ordinary smallest-viewer stream.
        let host_supports_priority = grant
            .get("supports_viewer_size_priority")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let viewer_size_priority = terminal_request.viewer_size_priority && host_supports_priority;

        let mut terminal = connect_owned_unix_socket(endpoint).await?;
        let hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role: ClientRole::Renderer,
            requested_rights: CapabilityRights::RENDERER,
            terminal_id,
            token,
        };
        let mut hello = hello.into_frame(1);
        hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        if viewer_size_priority {
            hello.flags |= FLAG_VIEWER_SIZE_PRIORITY;
        }
        terminal
            .write_all(&encode_frame(&hello).map_err(|error| {
                ServicesError::Remote(format!("terminal hello encoding failed: {error}"))
            })?)
            .await?;
        terminal.flush().await?;
        let response = read_terminal_frame(&mut terminal).await?;
        validate_renderer_host_hello(&response, 1, terminal_id, incarnation, viewer_size_priority)?;

        Ok(terminal)
    }

    #[cfg(not(unix))]
    async fn serve_terminal_bytes(
        _mux_socket: Option<PathBuf>,
        stream: ServiceStream,
        _metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        stream
            .reject(
                "unsupported".to_string(),
                "terminal byte streams require Unix sockets".to_string(),
            )
            .await?;
        Ok(())
    }

    /// One `mux-control` stream, spliced to the session daemon's unix socket. A
    /// grant-admitted session's stream first carries the grant's signed role
    /// (`mux_carrier_role.rs`), before any of the person's bytes.
    #[cfg(unix)]
    async fn serve_mux_control_with_budget(
        mux_socket: Option<PathBuf>,
        grant: Option<&CarrierGrant>,
        stream: ServiceStream,
        upload_budget: MuxUploadBudget,
    ) -> Result<(), ServicesError> {
        let path = mux_socket.as_ref().ok_or_else(|| {
            ServicesError::Unavailable("mux control socket is not configured".into())
        })?;
        let mut socket = connect_owned_unix_socket(path).await?;
        if let Some(grant) = grant
            && let Err(refused) = crate::mux_carrier_role::stamp(&mut socket, grant.vm_kind).await
        {
            let (code, message) = match refused {
                crate::mux_carrier_role::StampRefused::NotTaken => (
                    "permission-denied",
                    "mux_control.role_not_taken: the session daemon did not take this grant's role",
                ),
                crate::mux_carrier_role::StampRefused::Unavailable => (
                    "unavailable",
                    "mux_control.role_unavailable: the session daemon did not answer the role stamp",
                ),
            };
            stream.reject(code.into(), message.into()).await?;
            return Ok(());
        }
        let stream = Arc::new(stream);
        send_opened(&stream, Lane::Interactive).await?;
        let (reader, writer) = socket.into_split();
        pump_mux_server_with_budget(stream, reader, writer, upload_budget).await
    }

    #[cfg(not(unix))]
    async fn serve_mux_control_with_budget(
        _mux_socket: Option<PathBuf>,
        _grant: Option<&CarrierGrant>,
        stream: ServiceStream,
        _upload_budget: MuxUploadBudget,
    ) -> Result<(), ServicesError> {
        stream
            .reject(
                "unsupported".to_string(),
                "mux control bridge requires Unix sockets".to_string(),
            )
            .await?;
        Ok(())
    }
}

/// Validated `terminal-bytes-v1` open metadata.
struct TerminalBytesRequest {
    terminal: TerminalPublicId,
    viewer_size_priority: bool,
}

fn terminal_bytes_metadata(
    metadata: &BTreeMap<String, String>,
) -> Result<TerminalBytesRequest, ServicesError> {
    if metadata.keys().any(|key| key != "terminal" && key != TERMINAL_BYTES_VIEWER_SIZE_PRIORITY) {
        return Err(ServicesError::Metadata(
            "terminal byte stream metadata only supports terminal and viewer_size_priority".into(),
        ));
    }
    let viewer_size_priority = match metadata.get(TERMINAL_BYTES_VIEWER_SIZE_PRIORITY) {
        None => false,
        Some(value) if value == TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED => true,
        Some(_) => {
            return Err(ServicesError::Metadata(
                "terminal byte stream viewer_size_priority must be preferred".into(),
            ));
        }
    };
    let terminal = TerminalPublicId::parse(
        metadata
            .get("terminal")
            .ok_or_else(|| {
                ServicesError::Metadata("terminal byte stream requires terminal".into())
            })?
            .clone(),
    )
    .map_err(|_| ServicesError::Metadata("terminal byte stream terminal is invalid".into()))?;
    Ok(TerminalBytesRequest { terminal, viewer_size_priority })
}

#[cfg(unix)]
fn required_json_string<'a>(
    value: &'a serde_json::Value,
    key: &str,
) -> Result<&'a str, ServicesError> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| ServicesError::Remote(format!("renderer grant omitted {key}")))
}

#[cfg(unix)]
fn decode_hex_32(value: &str) -> Result<[u8; 32], ServicesError> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ServicesError::Remote("renderer grant has invalid token".into()));
    }
    let mut output = [0u8; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let nibble = |byte: u8| match byte {
            b'0'..=b'9' => Some(byte - b'0'),
            b'a'..=b'f' => Some(byte - b'a' + 10),
            b'A'..=b'F' => Some(byte - b'A' + 10),
            _ => None,
        };
        output[index] = (nibble(pair[0])
            .ok_or_else(|| ServicesError::Remote("renderer grant has invalid token".into()))?
            << 4)
            | nibble(pair[1])
                .ok_or_else(|| ServicesError::Remote("renderer grant has invalid token".into()))?;
    }
    Ok(output)
}

#[cfg(unix)]
async fn read_terminal_frame(stream: &mut tokio::net::UnixStream) -> Result<Frame, ServicesError> {
    let mut encoded = vec![0u8; HEADER_LEN];
    stream.read_exact(&mut encoded).await?;
    let payload_len = frame_payload_len(&encoded, MAX_FRAME_PAYLOAD)
        .map_err(|error| ServicesError::Remote(format!("invalid terminal host frame: {error}")))?;
    encoded.resize(HEADER_LEN + payload_len, 0);
    stream.read_exact(&mut encoded[HEADER_LEN..]).await?;
    let mut frames = FrameDecoder::new(MAX_FRAME_PAYLOAD)
        .push(&encoded)
        .map_err(|error| ServicesError::Remote(format!("invalid terminal host frame: {error}")))?;
    if frames.len() != 1 {
        return Err(ServicesError::Remote("terminal host handshake frame was incomplete".into()));
    }
    Ok(frames.remove(0))
}

async fn decode_workspace_request(
    workspace: &WorkspaceService,
    purpose: WorkspaceRpcPurpose,
    encoded: Bytes,
) -> Result<RpcRequest, ServicesError> {
    if purpose == WorkspaceRpcPurpose::Cancellation {
        if encoded.len() >= RPC_CODEC_OFFLOAD_BYTES {
            return Err(ServicesError::MessageTooLarge(encoded.len()));
        }
        return Ok(serde_json::from_slice(&encoded)?);
    }
    if encoded.len() < RPC_CODEC_OFFLOAD_BYTES {
        return Ok(serde_json::from_slice(&encoded)?);
    }
    workspace
        .run_codec("RPC request decode", move || {
            serde_json::from_slice(&encoded)
                .map_err(|error| RpcError::new("invalid-json", error.to_string()))
        })
        .await
        .map_err(|error| ServicesError::Remote(error.message))
}

async fn send_workspace_response(
    workspace: &WorkspaceService,
    messages: &MessageStream,
    response: RpcResponse,
    allow_offload: bool,
) -> Result<(), ServicesError> {
    send_prepared_workspace_response(
        workspace,
        messages,
        PreparedRpcResponse::plain(response),
        allow_offload,
    )
    .await
}

async fn send_prepared_workspace_response(
    workspace: &WorkspaceService,
    messages: &MessageStream,
    mut prepared: PreparedRpcResponse,
    allow_offload: bool,
) -> Result<(), ServicesError> {
    let response = prepared.take_response();
    let response_id = response.id;
    let retryable_if_too_large = workspace_response_too_large_is_retryable(&response);
    let encoded = if allow_offload && workspace_response_needs_codec(&response) {
        workspace
            .run_codec("RPC response encode", move || {
                encode_workspace_response(&response)
                    .map_err(|error| RpcError::new("internal", format!("encode response: {error}")))
            })
            .await
            .map_err(|error| ServicesError::Remote(error.message))?
    } else {
        encode_workspace_response(&response)?
    };
    match encoded {
        EncodedWorkspaceResponse::Message(encoded) => {
            messages.send(&encoded).await?;
            prepared.commit_delivery();
            Ok(())
        }
        EncodedWorkspaceResponse::TooLarge => {
            // The client did not receive the requested page. Dropping the
            // delivery guard restores its input cursor before the fallback is
            // sent, regardless of whether that send succeeds.
            drop(prepared);
            let mut error = RpcError::new(
                "resource-exhausted",
                "RPC response exceeds the maximum message size",
            );
            error.retryable = retryable_if_too_large;
            let fallback = RpcResponse { id: response_id, result: Err(error) };
            let encoded = serde_json::to_vec(&fallback)?;
            debug_assert!(encoded.len() <= MAX_RPC_MESSAGE);
            messages.send(&encoded).await
        }
    }
}

enum EncodedWorkspaceResponse {
    Message(Vec<u8>),
    TooLarge,
}

struct BoundedJsonWriter {
    encoded: Vec<u8>,
    exceeded_limit: bool,
}

impl BoundedJsonWriter {
    fn new() -> Self {
        Self { encoded: Vec::new(), exceeded_limit: false }
    }
}

impl std::io::Write for BoundedJsonWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > MAX_RPC_MESSAGE.saturating_sub(self.encoded.len()) {
            self.exceeded_limit = true;
            return Err(std::io::Error::other("RPC response exceeds the maximum message size"));
        }
        self.encoded.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn encode_workspace_response(
    response: &RpcResponse,
) -> Result<EncodedWorkspaceResponse, serde_json::Error> {
    let mut writer = BoundedJsonWriter::new();
    match serde_json::to_writer(&mut writer, response) {
        Ok(()) => Ok(EncodedWorkspaceResponse::Message(writer.encoded)),
        Err(_) if writer.exceeded_limit => Ok(EncodedWorkspaceResponse::TooLarge),
        Err(error) => Err(error),
    }
}

fn workspace_response_needs_codec(response: &RpcResponse) -> bool {
    match &response.result {
        Ok(WorkspaceResponse::File { data, .. }) | Ok(WorkspaceResponse::Diff { data, .. }) => {
            data.encoded().len() >= RPC_CODEC_OFFLOAD_BYTES
        }
        Ok(
            WorkspaceResponse::Workspaces { .. }
            | WorkspaceResponse::Directory { .. }
            | WorkspaceResponse::Search { .. }
            | WorkspaceResponse::Patch { .. }
            | WorkspaceResponse::GitStatus { .. }
            | WorkspaceResponse::StructuredDiff { .. }
            | WorkspaceResponse::ProcessEvents { .. }
            | WorkspaceResponse::Processes { .. }
            | WorkspaceResponse::ProcessTerminalSnapshot { .. },
        ) => true,
        Err(error) => rpc_error_needs_codec(error),
        _ => false,
    }
}

fn workspace_response_too_large_is_retryable(response: &RpcResponse) -> bool {
    matches!(
        &response.result,
        Ok(WorkspaceResponse::File { .. }
            | WorkspaceResponse::Directory { .. }
            | WorkspaceResponse::Search { .. }
            | WorkspaceResponse::Diff { .. }
            | WorkspaceResponse::StructuredDiff { .. }
            | WorkspaceResponse::ProcessEvents { .. })
    ) || matches!(&response.result, Err(error) if error.retryable)
}

fn rpc_error_needs_codec(error: &RpcError) -> bool {
    let mut bytes = error.code.len().saturating_add(error.message.len());
    if let Some(RpcErrorDetails::PatchRollback { failed_paths }) = &error.details {
        bytes = failed_paths
            .iter()
            .fold(bytes, |bytes, path| bytes.saturating_add(path.len()).saturating_add(8));
    }
    bytes >= RPC_ERROR_CODEC_OFFLOAD_BYTES
}

pub struct MessageStream {
    stream: Arc<ServiceStream>,
    lane: Lane,
    read: Mutex<MessageReadState>,
    write: Mutex<()>,
}

struct MessageReadState {
    buffer: BytesMut,
    budgets: Vec<StreamBudget>,
    finished: bool,
}

impl MessageStream {
    pub fn new(stream: Arc<ServiceStream>) -> Self {
        let lane = match stream.service() {
            Service::MuxControl | Service::TerminalBytes | Service::ComputerUse => {
                Lane::Interactive
            }
            Service::ProcessStream => Lane::Bulk,
            Service::WorkspaceRpc => Lane::Control,
            Service::TcpTunnel | Service::LocalSocket | Service::Acpmux => Lane::Tunnel,
        };
        Self::with_lane(stream, lane)
    }

    pub fn with_lane(stream: Arc<ServiceStream>, lane: Lane) -> Self {
        Self {
            stream,
            lane,
            read: Mutex::new(MessageReadState {
                buffer: BytesMut::new(),
                budgets: Vec::new(),
                finished: false,
            }),
            write: Mutex::new(()),
        }
    }

    pub async fn send(&self, message: &[u8]) -> Result<(), ServicesError> {
        let _guard = self.write.lock().await;
        if message.len() > MAX_RPC_MESSAGE {
            return Err(ServicesError::MessageTooLarge(message.len()));
        }
        let mut encoded = BytesMut::with_capacity(4 + message.len());
        encoded.put_u32(message.len() as u32);
        encoded.extend_from_slice(message);
        self.stream.send_on(self.lane, encoded.freeze()).await?;
        Ok(())
    }

    pub async fn receive(&self) -> Result<Option<Bytes>, ServicesError> {
        let mut state = self.read.lock().await;
        loop {
            if state.buffer.len() >= 4 {
                let size = u32::from_be_bytes(state.buffer[..4].try_into().unwrap()) as usize;
                if size > MAX_RPC_MESSAGE {
                    state.buffer.clear();
                    state.budgets.clear();
                    state.finished = true;
                    return Err(ServicesError::MessageTooLarge(size));
                }
                if state.buffer.len() >= 4 + size {
                    state.buffer.advance(4);
                    let message = state.buffer.split_to(size).freeze();
                    if state.buffer.is_empty() {
                        state.budgets.clear();
                    }
                    return Ok(Some(message));
                }
            }
            if state.finished {
                if state.buffer.is_empty() {
                    return Ok(None);
                }
                state.buffer.clear();
                state.budgets.clear();
                return Err(ServicesError::TruncatedMessage);
            }
            let received = self.stream.receive().await;
            let Some(mut chunk) = (match received {
                Ok(chunk) => chunk,
                Err(error) => {
                    state.buffer.clear();
                    state.budgets.clear();
                    state.finished = true;
                    return Err(error.into());
                }
            }) else {
                state.finished = true;
                continue;
            };
            if chunk.lane != self.lane {
                state.buffer.clear();
                state.budgets.clear();
                state.finished = true;
                return Err(ServicesError::UnexpectedLane {
                    expected: self.lane,
                    actual: chunk.lane,
                });
            }
            if chunk.reset {
                state.buffer.clear();
                state.budgets.clear();
                state.finished = true;
                return Err(ServicesError::Remote("stream was reset".into()));
            }
            state.buffer.extend_from_slice(&chunk.payload);
            if let Some(budget) = chunk.take_budget() {
                state.budgets.push(budget);
            }
            state.finished = chunk.finished;
        }
    }

    pub async fn close(&self) -> Result<(), ServicesError> {
        self.stream.close_on(self.lane).await?;
        Ok(())
    }
}

async fn send_opened(stream: &ServiceStream, lane: Lane) -> Result<(), ServicesError> {
    let payload = if stream.service() == Service::MuxControl {
        serde_json::to_vec(&serde_json::json!({
            "type": "opened",
            "service": stream.service(),
            "features": [MUX_INPUT_V1_FEATURE],
        }))?
    } else {
        serde_json::to_vec(&ServiceControl::Opened { service: stream.service() })?
    };
    // Open acknowledgement and the first service payload share one ordered
    // lane, so isolated carriers cannot deliver data ahead of `Opened`.
    if stream.service() == Service::MuxControl {
        for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
            stream.send_on(lane, Bytes::from(payload.clone())).await?;
        }
    } else {
        stream.send_on(lane, Bytes::from(payload)).await?;
    }
    Ok(())
}

async fn send_replay_gap(
    messages: &MessageStream,
    process: ProcessId,
    requested_after: u64,
    range: ProcessReplayRange,
) -> Result<(), ServicesError> {
    let event = RpcEvent {
        sequence: range.last_produced,
        event: ProcessEvent::ReplayGap { process, requested_after, range },
    };
    messages.send(&serde_json::to_vec(&event)?).await
}

async fn pump_stream<R, W>(
    remote: Arc<ServiceStream>,
    mut local_reader: R,
    mut local_writer: W,
) -> Result<(), ServicesError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let failure_remote = remote.clone();
    let upload = {
        let remote = remote.clone();
        async move {
            let mut buffer = vec![0_u8; COPY_CHUNK];
            loop {
                let size = local_reader.read(&mut buffer).await?;
                if size == 0 {
                    remote.close().await?;
                    return Ok::<_, ServicesError>(());
                }
                remote.send(Bytes::copy_from_slice(&buffer[..size])).await?;
            }
        }
    };
    let download = async move {
        while let Some(chunk) = remote.receive().await? {
            if !chunk.payload.is_empty() {
                local_writer.write_all(&chunk.payload).await?;
            }
            if chunk.finished || chunk.reset {
                break;
            }
        }
        if let Err(error) = local_writer.shutdown().await {
            // The local peer may close immediately after consuming the last
            // upload byte while the remote FIN is crossing the proxy. That is
            // a clean bidirectional shutdown, not a transport failure.
            if !matches!(
                error.kind(),
                ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::NotConnected
            ) {
                return Err(error.into());
            }
        }
        Ok::<_, ServicesError>(())
    };
    let transfer = async {
        tokio::try_join!(upload, download)?;
        Ok::<_, ServicesError>(())
    };
    tokio::pin!(transfer);
    let failure = failure_remote.wait_for_failure();
    tokio::pin!(failure);
    tokio::select! {
        biased;
        error = &mut failure => Err(error.into()),
        result = &mut transfer => result,
    }
}

struct MuxUploadMessage {
    packets: Vec<Bytes>,
    _permit: MuxUploadPermit,
}

async fn read_mux_uploads<R>(
    local_reader: R,
    tracker: Arc<crate::mux_lanes::MuxLaneTracker>,
    upload_budget: MuxUploadBudget,
    interactive: mpsc::Sender<MuxUploadMessage>,
    control: mpsc::Sender<MuxUploadMessage>,
    bulk: mpsc::Sender<MuxUploadMessage>,
) -> Result<(), ServicesError>
where
    R: AsyncRead + Unpin,
{
    use tokio::io::BufReader;

    let mut reader = BufReader::new(local_reader);
    let mut line = Vec::new();
    let mut message = 1_u64;
    loop {
        let size = crate::mux_codec::read_bounded_line_with_limit(
            &mut reader,
            &mut line,
            crate::mux_codec::MAX_MUX_DOWNLOAD_LINE_BYTES,
        )
        .await?;
        if size == 0 {
            return Ok(());
        }
        if crate::mux_codec::mux_line_payload_len(&line)
            > crate::mux_codec::MAX_MUX_DOWNLOAD_LINE_BYTES.saturating_sub(1)
        {
            return Err(crate::mux_codec::MuxCodecError::LineTooLarge(line.len()).into());
        }
        let Some(lane) = tracker.classify_server_line(&line) else {
            continue;
        };
        if lane == Lane::Tunnel {
            return Err(ServicesError::UnexpectedLane {
                expected: Lane::Bulk,
                actual: Lane::Tunnel,
            });
        }
        let packets = crate::mux_codec::encode_line_with_limit(
            message,
            &line,
            crate::mux_codec::MAX_MUX_DOWNLOAD_LINE_BYTES,
        )?;
        let encoded_bytes =
            packets.iter().try_fold(0_usize, |total, packet| total.checked_add(packet.len()));
        let Some(encoded_bytes) = encoded_bytes else {
            return Err(ServicesError::MessageTooLarge(usize::MAX));
        };
        let upload = MuxUploadMessage {
            packets,
            _permit: upload_budget.acquire(lane, encoded_bytes).await?,
        };
        let sender = match lane {
            Lane::Interactive => &interactive,
            Lane::Control => &control,
            Lane::Bulk => &bulk,
            Lane::Tunnel => unreachable!("Tunnel was rejected above"),
        };
        sender
            .send(upload)
            .await
            .map_err(|_| ServicesError::Remote(format!("{lane:?} mux upload queue closed")))?;
        message = message.checked_add(1).ok_or(ServicesError::MessageIdsExhausted)?;
    }
}

async fn send_mux_uploads(
    remote: Arc<ServiceStream>,
    lane: Lane,
    mut uploads: mpsc::Receiver<MuxUploadMessage>,
) -> Result<(), ServicesError> {
    while let Some(upload) = uploads.recv().await {
        for packet in upload.packets {
            remote.send_on(lane, packet).await?;
        }
    }
    Ok(())
}

async fn pump_mux_server_with_budget<R, W>(
    remote: Arc<ServiceStream>,
    local_reader: R,
    mut local_writer: W,
    upload_budget: MuxUploadBudget,
) -> Result<(), ServicesError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (interactive_tx, interactive_rx) = mpsc::channel(MAX_BUFFERED_MUX_MESSAGES_PER_LANE);
    let (control_tx, control_rx) = mpsc::channel(MAX_BUFFERED_MUX_MESSAGES_PER_LANE);
    let (bulk_tx, bulk_rx) = mpsc::channel(MAX_BUFFERED_MUX_MESSAGES_PER_LANE);

    let tracker = Arc::new(crate::mux_lanes::MuxLaneTracker::default());
    let upload = {
        let remote = remote.clone();
        let tracker = tracker.clone();
        async move {
            let read = read_mux_uploads(
                local_reader,
                tracker,
                upload_budget,
                interactive_tx,
                control_tx,
                bulk_tx,
            );
            let send_interactive =
                send_mux_uploads(remote.clone(), Lane::Interactive, interactive_rx);
            let send_control = send_mux_uploads(remote.clone(), Lane::Control, control_rx);
            let send_bulk = send_mux_uploads(remote.clone(), Lane::Bulk, bulk_rx);
            tokio::try_join!(read, send_interactive, send_control, send_bulk)?;
            remote.close().await?;
            Ok::<_, ServicesError>(())
        }
    };
    let download = async move {
        let mut assembler =
            crate::mux_codec::MuxLineAssembler::<Option<StreamBudget>>::with_maximum(
                crate::mux_codec::MAX_MUX_UPLOAD_LINE_BYTES,
            );
        while let Some(mut chunk) = remote.receive().await? {
            if !chunk.payload.is_empty() {
                if let Some(input) = crate::mux_input::decode_packet(&chunk.payload)? {
                    tracker.suppress_response(input.request);
                    local_writer.write_all(&input.into_local_line()?).await?;
                } else {
                    let budget = chunk.take_budget();
                    if let Some(line) =
                        assembler.push_retaining(chunk.lane, chunk.payload, budget)?
                    {
                        tracker.observe_request(line.payload(), line.lane());
                        local_writer.write_all(line.payload()).await?;
                    }
                }
            }
            if chunk.finished || chunk.reset {
                break;
            }
        }
        local_writer.shutdown().await?;
        Ok::<_, ServicesError>(())
    };
    tokio::pin!(upload);
    tokio::pin!(download);
    tokio::select! {
        result = &mut upload => result?,
        result = &mut download => result?,
    }
    Ok(())
}

fn parse_u64(metadata: &BTreeMap<String, String>, key: &str) -> Result<u64, ServicesError> {
    metadata
        .get(key)
        .ok_or_else(|| ServicesError::Metadata(format!("missing {key}")))?
        .parse()
        .map_err(|_| ServicesError::Metadata(format!("{key} must be an unsigned integer")))
}

fn process_stream_metadata(
    metadata: &BTreeMap<String, String>,
) -> Result<(ProcessId, u64, bool), RpcError> {
    let process = metadata
        .get("process")
        .ok_or_else(|| RpcError::new("invalid-argument", "missing process"))
        .and_then(|value| {
            ProcessId::parse_str(value)
                .map_err(|_| RpcError::new("invalid-argument", "process must be a UUID"))
        })?;
    let after = metadata
        .get("after")
        .map(|value| value.parse::<u64>())
        .transpose()
        .map_err(|_| RpcError::new("invalid-argument", "after must be an unsigned integer"))?
        .unwrap_or(0);
    let reserve = match metadata.get("reserve").map(String::as_str) {
        None | Some("false") => false,
        Some("true") => true,
        Some(_) => {
            return Err(RpcError::new("invalid-argument", "reserve must be true or false"));
        }
    };
    Ok((process, after, reserve))
}

fn workspace_rpc_metadata(
    metadata: &BTreeMap<String, String>,
) -> Result<(Lane, WorkspaceRpcPurpose), ServicesError> {
    if metadata.keys().any(|key| key != "lane" && key != "purpose") {
        return Err(ServicesError::Metadata(
            "workspace RPC metadata only supports lane and purpose".into(),
        ));
    }
    let lane = match metadata.get("lane").map(String::as_str).unwrap_or("control") {
        "interactive" => Lane::Interactive,
        "control" => Lane::Control,
        "bulk" => Lane::Bulk,
        lane => Err(ServicesError::Metadata(format!("unsupported workspace RPC lane {lane:?}")))?,
    };
    let purpose = match metadata.get("purpose").map(String::as_str).unwrap_or("requests") {
        "requests" => WorkspaceRpcPurpose::Requests,
        "cancellation" if lane == Lane::Control => WorkspaceRpcPurpose::Cancellation,
        "cancellation" => {
            return Err(ServicesError::Metadata(
                "the cancellation purpose requires the control lane".into(),
            ));
        }
        purpose => {
            return Err(ServicesError::Metadata(format!(
                "unsupported workspace RPC purpose {purpose:?}"
            )));
        }
    };
    Ok((lane, purpose))
}

/// Connect to a local mux or terminal-host socket. Both run as this daemon's
/// user, so refuse any other listener before a request or token is written.
#[cfg(unix)]
async fn connect_owned_unix_socket(
    path: impl AsRef<Path>,
) -> Result<tokio::net::UnixStream, ServicesError> {
    let stream = tokio::net::UnixStream::connect(path).await?;
    crate::admin::verify_unix_peer_owner(&stream)
        .map_err(|error| ServicesError::Unavailable(error.to_string()))?;
    Ok(stream)
}

#[derive(Debug)]
pub enum ServicesError {
    Service(ServiceError),
    Json(serde_json::Error),
    Io(std::io::Error),
    Metadata(String),
    Remote(String),
    Unavailable(String),
    MessageTooLarge(usize),
    TruncatedMessage,
    MuxCodec(crate::mux_codec::MuxCodecError),
    MuxInput(crate::mux_input::MuxInputError),
    MessageIdsExhausted,
    RequestTask(tokio::task::JoinError),
    UnexpectedLane { expected: Lane, actual: Lane },
}

impl fmt::Display for ServicesError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Service(error) => error.fmt(formatter),
            Self::Json(error) => write!(formatter, "service JSON failed: {error}"),
            Self::Io(error) => write!(formatter, "service I/O failed: {error}"),
            Self::Metadata(message) => write!(formatter, "invalid service metadata: {message}"),
            Self::Remote(message) => write!(formatter, "remote service failed: {message}"),
            Self::Unavailable(message) => write!(formatter, "service unavailable: {message}"),
            Self::MessageTooLarge(size) => {
                write!(formatter, "service message is too large: {size}")
            }
            Self::TruncatedMessage => {
                formatter.write_str("service message ended before its declared length")
            }
            Self::MuxCodec(error) => error.fmt(formatter),
            Self::MuxInput(error) => error.fmt(formatter),
            Self::MessageIdsExhausted => {
                formatter.write_str("service message identifiers exhausted")
            }
            Self::RequestTask(error) => write!(formatter, "workspace request task failed: {error}"),
            Self::UnexpectedLane { expected, actual } => {
                write!(formatter, "service message used {actual:?} instead of {expected:?}")
            }
        }
    }
}

impl std::error::Error for ServicesError {}

impl From<ServiceError> for ServicesError {
    fn from(error: ServiceError) -> Self {
        Self::Service(error)
    }
}

impl From<serde_json::Error> for ServicesError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<std::io::Error> for ServicesError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<crate::mux_codec::MuxCodecError> for ServicesError {
    fn from(error: crate::mux_codec::MuxCodecError) -> Self {
        Self::MuxCodec(error)
    }
}

impl From<crate::mux_input::MuxInputError> for ServicesError {
    fn from(error: crate::mux_input::MuxInputError) -> Self {
        Self::MuxInput(error)
    }
}

#[cfg(all(test, unix))]
#[path = "acpmux_service_tests.rs"]
mod acpmux_service_tests;

#[cfg(all(test, unix))]
#[path = "mux_control_role_tests.rs"]
mod mux_control_role_tests;

#[cfg(test)]
#[path = "services_tests.rs"]
mod tests;
