use std::collections::BTreeMap;
use std::fmt;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::Arc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{
    Lane, MUX_INPUT_V1_FEATURE, ProcessEvent, ProcessId, ProcessReplayRange, RouteId, RpcError,
    RpcErrorDetails, RpcEvent, RpcRequest, RpcResponse, Service, ServiceControl, WorkspaceRequest,
    WorkspaceResponse,
};
use cmux_tui_core::resource::TerminalPublicId;
#[cfg(unix)]
use cmux_tui_core::terminal_host::{
    CapabilityRights, CapabilityToken, ClientHello, ClientRole, HostHello, HostIncarnation,
    TerminalId,
};
#[cfg(unix)]
use cmux_tui_core::terminal_host_protocol::{
    FLAG_SMART_RENDERER, FLAG_VIEWER_SIZE_ACKS, Frame, FrameDecoder, HEADER_LEN, MAX_FRAME_PAYLOAD,
    MessageKind, PROTOCOL_VERSION, encode_frame, frame_payload_len,
};
#[cfg(unix)]
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, watch};
use tokio::task::JoinSet;

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
}

fn validate_renderer_host_hello(
    response: &Frame,
    request_id: u64,
    terminal_id: TerminalId,
    incarnation: HostIncarnation,
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
        Arc::new(Self { workspace, mux_socket, mux_upload_budget: MuxUploadBudget::new() })
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
        handlers.abort_all();
        while handlers.join_next().await.is_some() {}
        self.workspace.shutdown().await;
    }

    pub async fn serve_client(
        self: &Arc<Self>,
        client: Arc<ServerConnection>,
    ) -> Result<(), ServicesError> {
        let scope = ClientScope::new(client.device_id.clone(), client.session_id);
        let mut cleanup =
            ClientCleanupGuard::new(client.clone(), self.workspace.clone(), scope.clone());
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
                    handlers.spawn_local(async move {
                        let _permit = permit;
                        services.serve_stream(scope, request_slots, incoming).await
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

    async fn serve_stream(
        self: Arc<Self>,
        scope: ClientScope,
        request_slots: Arc<RequestAdmission>,
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
            Service::MuxControl => {
                Self::serve_mux_control_with_budget(mux_socket, incoming.stream, mux_upload_budget)
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

    #[cfg(unix)]
    async fn serve_terminal_bytes(
        mux_socket: Option<PathBuf>,
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let stream = Arc::new(stream);
        let terminal_id = match terminal_bytes_metadata(&metadata) {
            Ok(terminal_id) => terminal_id,
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
            Self::negotiate_terminal_bytes(mux_path, terminal_id),
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
        mux_path: &std::path::Path,
        terminal_public_id: TerminalPublicId,
    ) -> Result<tokio::net::UnixStream, ServicesError> {
        // The control socket only brokers a one-use renderer grant. The
        // durable terminal-host owner token never crosses the remote session.
        let mut mux = tokio::net::UnixStream::connect(mux_path).await?;
        let request = serde_json::to_vec(&serde_json::json!({
            "id": 1,
            "cmd": "mint-terminal-renderer-by-terminal",
            "terminal": terminal_public_id,
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

        let mut terminal = tokio::net::UnixStream::connect(endpoint).await?;
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
        terminal
            .write_all(&encode_frame(&hello).map_err(|error| {
                ServicesError::Remote(format!("terminal hello encoding failed: {error}"))
            })?)
            .await?;
        terminal.flush().await?;
        let response = read_terminal_frame(&mut terminal).await?;
        validate_renderer_host_hello(&response, 1, terminal_id, incarnation)?;

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

    #[cfg(all(unix, test))]
    async fn serve_mux_control(
        mux_socket: Option<PathBuf>,
        stream: ServiceStream,
    ) -> Result<(), ServicesError> {
        Self::serve_mux_control_with_budget(mux_socket, stream, MuxUploadBudget::new()).await
    }

    #[cfg(unix)]
    async fn serve_mux_control_with_budget(
        mux_socket: Option<PathBuf>,
        stream: ServiceStream,
        upload_budget: MuxUploadBudget,
    ) -> Result<(), ServicesError> {
        let path = mux_socket.as_ref().ok_or_else(|| {
            ServicesError::Unavailable("mux control socket is not configured".into())
        })?;
        let socket = tokio::net::UnixStream::connect(path).await?;
        let stream = Arc::new(stream);
        send_opened(&stream, Lane::Interactive).await?;
        let (reader, writer) = socket.into_split();
        pump_mux_server_with_budget(stream, reader, writer, upload_budget).await
    }

    #[cfg(all(not(unix), test))]
    async fn serve_mux_control(
        _mux_socket: Option<PathBuf>,
        stream: ServiceStream,
    ) -> Result<(), ServicesError> {
        Self::serve_mux_control_with_budget(None, stream, MuxUploadBudget::new()).await
    }

    #[cfg(not(unix))]
    async fn serve_mux_control_with_budget(
        _mux_socket: Option<PathBuf>,
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

fn terminal_bytes_metadata(
    metadata: &BTreeMap<String, String>,
) -> Result<TerminalPublicId, ServicesError> {
    if metadata.keys().any(|key| key != "terminal") {
        return Err(ServicesError::Metadata(
            "terminal byte stream metadata only supports terminal".into(),
        ));
    }
    TerminalPublicId::parse(
        metadata
            .get("terminal")
            .ok_or_else(|| {
                ServicesError::Metadata("terminal byte stream requires terminal".into())
            })?
            .clone(),
    )
    .map_err(|_| ServicesError::Metadata("terminal byte stream terminal is invalid".into()))
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
            Service::TcpTunnel => Lane::Tunnel,
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
        let size = crate::mux_codec::read_bounded_line(&mut reader, &mut line).await?;
        if size == 0 {
            return Ok(());
        }
        if line.len() > crate::mux_codec::MAX_MUX_LINE_BYTES {
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
        let packets = crate::mux_codec::encode_line(message, &line)?;
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

#[cfg(test)]
pub(crate) async fn pump_mux_server<R, W>(
    remote: Arc<ServiceStream>,
    local_reader: R,
    local_writer: W,
) -> Result<(), ServicesError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    pump_mux_server_with_budget(remote, local_reader, local_writer, MuxUploadBudget::new()).await
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
        let mut assembler = crate::mux_codec::MuxLineAssembler::<Option<StreamBudget>>::default();
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    #[cfg(unix)]
    use std::sync::{Condvar, Mutex as StdMutex};

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
    use tokio::sync::{Notify, mpsc, watch};

    use super::*;
    use crate::client::WorkspaceClient;
    use crate::service::{ServiceMultiplexer, SessionEndpoint};
    use crate::session::ReceivedFrame;

    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
        sequence: AtomicU64,
        generation: watch::Sender<u64>,
    }

    #[cfg(unix)]
    struct BackpressuredMuxEndpoint {
        generation: watch::Sender<u64>,
        bulk_active: AtomicBool,
        bulk_released: AtomicBool,
        control_frames: AtomicUsize,
        activity_changed: Notify,
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

    fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
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

    #[cfg(unix)]
    impl BackpressuredMuxEndpoint {
        fn new() -> Arc<Self> {
            let (generation, _) = watch::channel(0);
            Arc::new(Self {
                generation,
                bulk_active: AtomicBool::new(false),
                bulk_released: AtomicBool::new(false),
                control_frames: AtomicUsize::new(0),
                activity_changed: Notify::new(),
            })
        }

        async fn wait_for_bulk(&self) {
            tokio::time::timeout(std::time::Duration::from_secs(1), async {
                loop {
                    let notified = self.activity_changed.notified();
                    if self.bulk_active.load(Ordering::Acquire) {
                        break;
                    }
                    notified.await;
                }
            })
            .await
            .expect("render event never reached the backpressured Bulk lane");
        }

        async fn wait_for_control(&self) {
            loop {
                let notified = self.activity_changed.notified();
                if self.control_frames.load(Ordering::Acquire) != 0 {
                    break;
                }
                notified.await;
            }
        }

        fn release_bulk(&self) {
            self.bulk_released.store(true, Ordering::Release);
            self.activity_changed.notify_waiters();
        }
    }

    #[cfg(unix)]
    #[async_trait]
    impl SessionEndpoint for BackpressuredMuxEndpoint {
        async fn send_frame(
            &self,
            _expected_generation: Option<u64>,
            lane: Lane,
            _stream: u64,
            _payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            if flags.contains(FrameFlags::OPEN) {
                return Ok(1);
            }
            match lane {
                Lane::Bulk => {
                    self.bulk_active.store(true, Ordering::Release);
                    self.activity_changed.notify_waiters();
                    loop {
                        let notified = self.activity_changed.notified();
                        if self.bulk_released.load(Ordering::Acquire) {
                            break;
                        }
                        notified.await;
                    }
                }
                Lane::Control => {
                    self.control_frames.fetch_add(1, Ordering::AcqRel);
                    self.activity_changed.notify_waiters();
                }
                Lane::Interactive | Lane::Tunnel => {}
            }
            Ok(1)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            std::future::pending().await
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), ServiceError> {
            Ok(())
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn mux_server_drains_control_while_bulk_lane_is_backpressured() {
        let endpoint = BackpressuredMuxEndpoint::new();
        let multiplexer = ServiceMultiplexer::new(endpoint.clone(), EndpointRole::Daemon);
        let stream =
            Arc::new(multiplexer.open(Service::MuxControl, BTreeMap::new()).await.unwrap());
        let (bridge, mut fake_core) = tokio::io::duplex(64 * 1024);
        let (reader, writer) = tokio::io::split(bridge);
        let pump = tokio::spawn(pump_mux_server(stream, reader, writer));

        fake_core
            .write_all(
                concat!(
                    "{\"event\":\"render-delta\",\"surface\":1}\n",
                    "{\"id\":91,\"ok\":true}\n",
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        endpoint.wait_for_bulk().await;
        let control = tokio::time::timeout(
            std::time::Duration::from_millis(100),
            endpoint.wait_for_control(),
        )
        .await;
        endpoint.release_bulk();
        pump.abort();
        let _ = pump.await;

        control.expect(
            "mux socket reader stopped behind Bulk backpressure before dispatching Control",
        );
        multiplexer.shutdown().await;
    }

    #[cfg(unix)]
    #[derive(Default)]
    struct BlockingGateState {
        released: bool,
        forced_timeout: bool,
    }

    #[cfg(unix)]
    struct BlockingGate {
        state: StdMutex<BlockingGateState>,
        changed: Condvar,
    }

    #[cfg(unix)]
    impl BlockingGate {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                state: StdMutex::new(BlockingGateState::default()),
                changed: Condvar::new(),
            })
        }

        fn block_with_watchdog(&self) {
            let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let (mut state, timeout) = self
                .changed
                .wait_timeout_while(state, std::time::Duration::from_secs(10), |state| {
                    !state.released
                })
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if timeout.timed_out() && !state.released {
                state.released = true;
                state.forced_timeout = true;
            }
        }

        fn release(&self) {
            let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state.released = true;
            drop(state);
            self.changed.notify_all();
        }

        fn forced_timeout(&self) -> bool {
            self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner).forced_timeout
        }
    }

    #[cfg(unix)]
    struct ReleaseOnDrop(Arc<BlockingGate>);

    #[cfg(unix)]
    impl Drop for ReleaseOnDrop {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    #[test]
    fn workspace_rpc_metadata_binds_cancellation_to_control() {
        assert_eq!(
            workspace_rpc_metadata(&BTreeMap::new()).unwrap(),
            (Lane::Control, WorkspaceRpcPurpose::Requests)
        );
        assert_eq!(
            workspace_rpc_metadata(&BTreeMap::from([
                ("lane".into(), "control".into()),
                ("purpose".into(), "cancellation".into()),
            ]))
            .unwrap(),
            (Lane::Control, WorkspaceRpcPurpose::Cancellation)
        );
        assert!(
            workspace_rpc_metadata(&BTreeMap::from([
                ("lane".into(), "bulk".into()),
                ("purpose".into(), "cancellation".into()),
            ]))
            .is_err()
        );
    }

    #[test]
    fn terminal_bytes_metadata_requires_a_stable_terminal_id() {
        const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
        assert!(matches!(
            terminal_bytes_metadata(&BTreeMap::new()),
            Err(ServicesError::Metadata(_))
        ));
        assert!(matches!(
            terminal_bytes_metadata(&BTreeMap::from([("terminal".into(), "pane-a".into())])),
            Err(ServicesError::Metadata(_))
        ));
        assert!(matches!(
            terminal_bytes_metadata(&BTreeMap::from([
                ("terminal".into(), TERMINAL.into()),
                ("after".into(), "3".into()),
            ])),
            Err(ServicesError::Metadata(_))
        ));
        assert!(
            terminal_bytes_metadata(&BTreeMap::from([("terminal".into(), TERMINAL.into())]))
                .is_ok()
        );
        assert!(matches!(
            terminal_bytes_metadata(&BTreeMap::from([("surface".into(), "9".into())])),
            Err(ServicesError::Metadata(_))
        ));
    }

    #[test]
    fn renderer_host_hello_requires_acknowledgements_and_exact_grant_identity() {
        let terminal_id = TerminalId::random().unwrap();
        let incarnation = HostIncarnation::random().unwrap();
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
        response.request_id = 7;
        response.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        let host = validate_renderer_host_hello(&response, 7, terminal_id, incarnation).unwrap();
        assert_eq!(host.granted_rights, CapabilityRights::RENDERER);
        assert!(host.granted_rights.contains(CapabilityRights::RESIZE));

        response.flags = FLAG_SMART_RENDERER;
        assert!(
            validate_renderer_host_hello(&response, 7, terminal_id, incarnation)
                .unwrap_err()
                .to_string()
                .contains("required renderer capabilities")
        );

        response.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        assert!(
            validate_renderer_host_hello(
                &response,
                7,
                terminal_id,
                HostIncarnation::random().unwrap(),
            )
            .unwrap_err()
            .to_string()
            .contains("does not match renderer grant")
        );
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
        let token_hex =
            token.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect::<String>();
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

        let response =
            tokio::time::timeout(std::time::Duration::from_secs(2), client_stream.receive())
                .await
                .expect("terminal byte rejection timed out")
                .expect("terminal byte rejection became a transport error")
                .expect("terminal byte stream closed without a rejection");
        assert_eq!(response.lane, Lane::Control);
        assert_eq!(
            serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
            ServiceControl::Rejected {
                code: expected_code.into(),
                message: expected_message.into(),
            }
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

        let response =
            tokio::time::timeout(std::time::Duration::from_secs(2), client_stream.receive())
                .await
                .expect("process-stream rejection timed out")
                .expect("process-stream rejection became a transport error")
                .expect("process stream closed without a rejection");
        assert_eq!(response.lane, Lane::Control);
        assert_eq!(
            serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
            ServiceControl::Rejected {
                code: expected_code.into(),
                message: expected_message.into(),
            }
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
    async fn failed_response_send_keeps_paginated_cursor_retryable() {
        let directory = tempdir().unwrap();
        for name in ["a.txt", "b.txt", "c.txt"] {
            std::fs::write(directory.path().join(name), name).unwrap();
        }
        let workspace = WorkspaceService::new();
        let scope = ClientScope::new("failed-page-send", cmux_remote_protocol::SessionId([15; 16]));
        let opened = workspace
            .handle_rpc_for(
                scope.clone(),
                RpcRequest {
                    id: cmux_remote_protocol::RequestId::from_u128(1),
                    timeout_ms: None,
                    request: WorkspaceRequest::OpenWorkspace {
                        root: directory.path().to_string_lossy().into_owned(),
                    },
                },
            )
            .await;
        let WorkspaceResponse::Workspace { id, .. } = opened.result.unwrap() else { panic!() };
        let first = workspace
            .handle_rpc_for(
                scope.clone(),
                RpcRequest {
                    id: cmux_remote_protocol::RequestId::from_u128(2),
                    timeout_ms: None,
                    request: WorkspaceRequest::ListDirectory {
                        workspace: id.clone(),
                        path: String::new(),
                        include_hidden: false,
                        limit: 1,
                        cursor: None,
                    },
                },
            )
            .await;
        let WorkspaceResponse::Directory { next_cursor: Some(cursor), .. } = first.result.unwrap()
        else {
            panic!()
        };
        let prepared = workspace
            .prepare_rpc_for(
                scope.clone(),
                RpcRequest {
                    id: cmux_remote_protocol::RequestId::from_u128(3),
                    timeout_ms: None,
                    request: WorkspaceRequest::ListDirectory {
                        workspace: id.clone(),
                        path: String::new(),
                        include_hidden: false,
                        limit: 1,
                        cursor: Some(cursor.clone()),
                    },
                },
            )
            .await;

        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let _client_stream = client
            .open(Service::WorkspaceRpc, BTreeMap::new())
            .await
            .expect("open workspace RPC stream");
        let incoming = daemon
            .accept()
            .await
            .expect("accept workspace RPC stream")
            .expect("workspace RPC stream was delivered");
        incoming.stream.close().await.expect("close test response stream");
        let messages = MessageStream::with_lane(Arc::new(incoming.stream), Lane::Control);
        let send_error = send_prepared_workspace_response(&workspace, &messages, prepared, false)
            .await
            .expect_err("closed response stream should reject the page");
        assert!(matches!(send_error, ServicesError::Service(ServiceError::Closed)));

        let retried = workspace
            .handle_rpc_for(
                scope,
                RpcRequest {
                    id: cmux_remote_protocol::RequestId::from_u128(4),
                    timeout_ms: None,
                    request: WorkspaceRequest::ListDirectory {
                        workspace: id,
                        path: String::new(),
                        include_hidden: false,
                        limit: 1,
                        cursor: Some(cursor),
                    },
                },
            )
            .await;
        let WorkspaceResponse::Directory { entries, .. } = retried.result.unwrap() else {
            panic!()
        };
        assert_eq!(entries[0].name, "b.txt");

        client.shutdown().await;
        daemon.shutdown().await;
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
        let scope =
            ClientScope::new("reservation-capacity", cmux_remote_protocol::SessionId([16; 16]));
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
                send_opened(&incoming.stream, lane)
                    .await
                    .expect("acknowledge workspace RPC stream");
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

    #[tokio::test]
    async fn cancellation_rpc_codec_stays_inline_and_bounded() {
        let workspace = WorkspaceService::new();
        let request = RpcRequest {
            id: cmux_remote_protocol::RequestId::from_u128(5),
            timeout_ms: None,
            request: WorkspaceRequest::CancelRequest {
                request: cmux_remote_protocol::RequestId::from_u128(4),
            },
        };
        let decoded = decode_workspace_request(
            &workspace,
            WorkspaceRpcPurpose::Cancellation,
            Bytes::from(serde_json::to_vec(&request).unwrap()),
        )
        .await
        .unwrap();
        assert_eq!(decoded.id, request.id);
        assert!(matches!(decoded.request, WorkspaceRequest::CancelRequest { .. }));

        let error = decode_workspace_request(
            &workspace,
            WorkspaceRpcPurpose::Cancellation,
            Bytes::from(vec![b' '; RPC_CODEC_OFFLOAD_BYTES]),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, ServicesError::MessageTooLarge(RPC_CODEC_OFFLOAD_BYTES)));
    }

    #[tokio::test]
    async fn oversized_escaped_workspace_response_returns_same_id_error() {
        let escaped = "\u{1}".repeat(1024 * 1024);
        let matches = (0..3)
            .map(|index| cmux_remote_protocol::SearchMatch {
                path: format!("file-{index}.txt"),
                line: 1,
                column: 1,
                text: escaped.clone(),
                before: Vec::new(),
                after: Vec::new(),
            })
            .collect();
        assert_oversized_response_falls_back(
            RpcResponse {
                id: cmux_remote_protocol::RequestId::from_u128(71),
                result: Ok(WorkspaceResponse::Search {
                    matches,
                    truncated: true,
                    next_cursor: Some(cmux_remote_protocol::PageCursor("next".into())),
                }),
            },
            true,
            true,
        )
        .await;
    }

    #[test]
    fn escaped_rpc_errors_use_codec_offload() {
        let response = RpcResponse {
            id: cmux_remote_protocol::RequestId::from_u128(72),
            result: Err(RpcError::new("invalid-data", "\u{1}".repeat(RPC_CODEC_OFFLOAD_BYTES / 4))),
        };

        assert!(workspace_response_needs_codec(&response));
    }

    #[tokio::test]
    async fn oversized_error_response_returns_same_id_error() {
        assert_oversized_response_falls_back(
            RpcResponse {
                id: cmux_remote_protocol::RequestId::from_u128(72),
                result: Err(RpcError::new("invalid-data", "\u{1}".repeat(3 * 1024 * 1024))),
            },
            true,
            false,
        )
        .await;
    }

    async fn assert_oversized_response_falls_back(
        response: RpcResponse,
        allow_offload: bool,
        expected_retryable: bool,
    ) {
        let expected_id = response.id;
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream =
            client.open(Service::WorkspaceRpc, BTreeMap::new()).await.expect("open RPC stream");
        let incoming = daemon
            .accept()
            .await
            .expect("accept RPC stream")
            .expect("RPC stream was not delivered");
        let outbound = MessageStream::with_lane(Arc::new(incoming.stream), Lane::Bulk);
        let inbound = MessageStream::with_lane(Arc::new(client_stream), Lane::Bulk);
        let workspace = WorkspaceService::new();

        send_workspace_response(&workspace, &outbound, response, allow_offload)
            .await
            .expect("oversized response should be replaced with a bounded error");
        let encoded = tokio::time::timeout(std::time::Duration::from_secs(2), inbound.receive())
            .await
            .expect("bounded fallback response timed out")
            .expect("bounded fallback response failed")
            .expect("bounded fallback response stream closed");
        assert!(encoded.len() <= MAX_RPC_MESSAGE);
        let fallback: RpcResponse =
            serde_json::from_slice(&encoded).expect("decode bounded fallback response");
        assert_eq!(fallback.id, expected_id);
        let error = fallback.result.expect_err("oversized response should return an RPC error");
        assert_eq!(error.code, "resource-exhausted");
        assert_eq!(error.retryable, expected_retryable);

        let next = RpcResponse {
            id: cmux_remote_protocol::RequestId::from_u128(0xfeed),
            result: Ok(WorkspaceResponse::Closed),
        };
        send_workspace_response(&workspace, &outbound, next.clone(), false)
            .await
            .expect("RPC stream should remain usable after the fallback");
        let encoded = inbound
            .receive()
            .await
            .expect("receive response after fallback")
            .expect("RPC stream closed after fallback");
        assert_eq!(
            serde_json::from_slice::<RpcResponse>(&encoded)
                .expect("decode response after fallback"),
            next
        );

        client.shutdown().await;
        daemon.shutdown().await;
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
                let client_multiplexer =
                    ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
                let daemon_multiplexer =
                    ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
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
                                let _ = services.serve_stream(scope, request_slots, incoming).await;
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
                    match tokio::time::timeout(std::time::Duration::from_secs(1), &mut write).await
                    {
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
                let exit =
                    tokio::time::timeout(std::time::Duration::from_secs(2), events.receive())
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
                let client_multiplexer =
                    ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
                let daemon_multiplexer =
                    ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
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
                                let _ = services.serve_stream(scope, request_slots, incoming).await;
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
                        client
                            .begin_request(WorkspaceRequest::WaitProcess { process })
                            .await
                            .unwrap(),
                    );
                }
                let admission_filled =
                    tokio::time::timeout(std::time::Duration::from_secs(2), async {
                        while request_slots.control.available_permits() != 0 {
                            tokio::task::yield_now().await;
                        }
                    })
                    .await
                    .is_ok();
                drop(pending);
                let admission_recovered =
                    tokio::time::timeout(std::time::Duration::from_secs(2), async {
                        while request_slots.control.available_permits() != MAX_CONTROL_RPC_REQUESTS
                        {
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
                let client_multiplexer =
                    ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
                let daemon_multiplexer =
                    ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
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
                                let _ = services.serve_stream(scope, request_slots, incoming).await;
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
                            structured_loss =
                                Some(format!("replay-gap:{requested_after}:{range:?}"));
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
                let client_multiplexer =
                    ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
                let daemon_multiplexer =
                    ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
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
                                let _ = services.serve_stream(scope, request_slots, incoming).await;
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
                let gap = events
                    .receive()
                    .await
                    .unwrap()
                    .expect("replay-gap stream closed without metadata");
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

    #[cfg(unix)]
    #[tokio::test(flavor = "current_thread")]
    async fn blocked_workspace_cpu_does_not_delay_mux_control_round_trip() {
        tokio::task::LocalSet::new()
            .run_until(async {
                let directory = tempdir().unwrap();
                tokio::fs::write(directory.path().join("entry.txt"), b"contents").await.unwrap();

                let gate = BlockingGate::new();
                let _release_on_drop = ReleaseOnDrop(gate.clone());
                let (entered_tx, entered_rx) = oneshot::channel();
                let entered_tx = Arc::new(StdMutex::new(Some(entered_tx)));
                let hook = {
                    let gate = gate.clone();
                    let entered_tx = entered_tx.clone();
                    Arc::new(move || {
                        let Some(entered_tx) = entered_tx
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .take()
                        else {
                            return;
                        };
                        let _ = entered_tx.send(());
                        gate.block_with_watchdog();
                    })
                };
                let workspace = WorkspaceService::with_blocking_hook(1, hook);
                let opened = workspace
                    .handle_request(WorkspaceRequest::OpenWorkspace {
                        root: directory.path().to_string_lossy().into_owned(),
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                    panic!()
                };

                let (client_endpoint, daemon_endpoint) = endpoint_pair();
                let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
                let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
                let workspace_stream = client
                    .open(Service::WorkspaceRpc, BTreeMap::from([("lane".into(), "bulk".into())]))
                    .await
                    .unwrap();
                let incoming = daemon.accept().await.unwrap().unwrap();
                let workspace_handler =
                    tokio::task::spawn_local(DaemonServices::serve_workspace_rpc(
                        workspace.clone(),
                        ClientScope::new("latency-test", cmux_remote_protocol::SessionId([7; 16])),
                        RequestAdmission::new(),
                        incoming.stream,
                        incoming.metadata,
                    ));
                let opened = workspace_stream.receive().await.unwrap().unwrap();
                assert!(matches!(
                    serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
                    ServiceControl::Opened { service: Service::WorkspaceRpc }
                ));
                let workspace_messages =
                    MessageStream::with_lane(Arc::new(workspace_stream), Lane::Bulk);
                let list = RpcRequest {
                    id: cmux_remote_protocol::RequestId::from_u128(41),
                    timeout_ms: None,
                    request: WorkspaceRequest::ListDirectory {
                        workspace: workspace_id,
                        path: String::new(),
                        include_hidden: true,
                        limit: 32,
                        cursor: None,
                    },
                };
                workspace_messages.send(&serde_json::to_vec(&list).unwrap()).await.unwrap();
                tokio::time::timeout(std::time::Duration::from_secs(2), entered_rx)
                    .await
                    .expect("directory worker did not enter the blocking pool")
                    .unwrap();

                let socket_directory = tempdir().unwrap();
                let socket_path = socket_directory.path().join("mux.sock");
                let listener = tokio::net::UnixListener::bind(&socket_path).unwrap();
                let mux_stream = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
                let incoming = daemon.accept().await.unwrap().unwrap();
                let mux_handler = tokio::task::spawn_local(DaemonServices::serve_mux_control(
                    Some(socket_path),
                    incoming.stream,
                ));

                let mux_round_trip =
                    tokio::time::timeout(std::time::Duration::from_secs(2), async {
                        let (fake_core, _) = listener.accept().await.unwrap();
                        for _ in 0..3 {
                            let opened = mux_stream.receive().await.unwrap().unwrap();
                            assert!(matches!(
                                serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
                                ServiceControl::Opened { service: Service::MuxControl }
                            ));
                        }

                        let request = b"{\"id\":91,\"cmd\":\"ping\"}\n";
                        for packet in crate::mux_codec::encode_line(1, request).unwrap() {
                            mux_stream.send_on(Lane::Interactive, packet).await.unwrap();
                        }
                        let mut fake_core = BufReader::new(fake_core);
                        let mut command = String::new();
                        fake_core.read_line(&mut command).await.unwrap();
                        assert_eq!(command.as_bytes(), request);
                        fake_core.get_mut().write_all(b"{\"id\":91,\"ok\":true}\n").await.unwrap();

                        let mut assembler = crate::mux_codec::MuxLineAssembler::default();
                        loop {
                            let chunk = mux_stream.receive().await.unwrap().unwrap();
                            if let Some((_lane, response)) =
                                assembler.push(chunk.lane, chunk.payload).unwrap()
                            {
                                break response;
                            }
                        }
                    })
                    .await;
                gate.release();
                let response = mux_round_trip
                    .expect("mux-control round trip stalled behind a blocked workspace CPU worker");
                assert_eq!(
                    serde_json::from_slice::<serde_json::Value>(&response).unwrap(),
                    serde_json::json!({"id": 91, "ok": true})
                );
                assert!(!gate.forced_timeout(), "workspace CPU hook blocked the LocalSet thread");

                let response: RpcResponse = serde_json::from_slice(
                    &tokio::time::timeout(
                        std::time::Duration::from_secs(2),
                        workspace_messages.receive(),
                    )
                    .await
                    .expect("directory response did not resume after releasing its worker")
                    .unwrap()
                    .unwrap(),
                )
                .unwrap();
                assert!(matches!(response.result, Ok(WorkspaceResponse::Directory { .. })));

                workspace_handler.abort();
                mux_handler.abort();
                let _ = workspace_handler.await;
                let _ = mux_handler.await;
                client.shutdown().await;
                daemon.shutdown().await;
            })
            .await;
    }

    #[tokio::test]
    async fn partial_bulk_message_retains_composite_budget_reserves() {
        const KIB: usize = 1024;

        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new_with_incoming_budget(
            client_endpoint,
            EndpointRole::Client,
            8 * KIB,
        );
        let bulk = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let bulk_id = bulk.id();
        let additional_bulk = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let control = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let interactive = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let bulk_messages = MessageStream::with_lane(Arc::new(bulk), Lane::Bulk);

        let mut partial_message = BytesMut::with_capacity(5 * KIB);
        partial_message.extend_from_slice(&0_u32.to_be_bytes());
        partial_message.extend_from_slice(&(7_u32 * KIB as u32).to_be_bytes());
        partial_message.resize(5 * KIB, b'b');
        daemon_endpoint
            .send_frame(None, Lane::Bulk, bulk_id, partial_message.freeze(), FrameFlags::empty())
            .await
            .unwrap();

        assert!(bulk_messages.receive().await.unwrap().unwrap().is_empty());
        {
            let state = bulk_messages.read.lock().await;
            assert_eq!(state.buffer.len(), 5 * KIB - size_of::<u32>());
            assert_eq!(state.budgets.len(), 1);
        }

        daemon_endpoint
            .send_frame(
                None,
                Lane::Bulk,
                additional_bulk.id(),
                Bytes::from_static(b"bulk-overflow"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();
        daemon_endpoint
            .send_frame(
                None,
                Lane::Control,
                control.id(),
                Bytes::from_static(b"control-marker"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();
        daemon_endpoint
            .send_frame(
                None,
                Lane::Interactive,
                interactive.id(),
                Bytes::from_static(b"interactive-marker"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let interactive_result =
            tokio::time::timeout(std::time::Duration::from_secs(1), interactive.receive())
                .await
                .expect("reader stalled before applying the retained priority reserves");
        let additional_bulk_result = additional_bulk.receive().await;
        let control_result = control.receive().await;
        let additional_bulk_was_reset = matches!(
            &additional_bulk_result,
            Err(ServiceError::Reset(message)) if message.contains("byte budget")
        );
        let control_was_delivered = matches!(
            &control_result,
            Ok(Some(chunk))
                if chunk.lane == Lane::Control
                    && chunk.payload == b"control-marker".as_slice()
        );
        let interactive_was_delivered = matches!(
            &interactive_result,
            Ok(Some(chunk))
                if chunk.lane == Lane::Interactive
                    && chunk.payload == b"interactive-marker".as_slice()
        );
        assert!(
            additional_bulk_was_reset && control_was_delivered && interactive_was_delivered,
            "partial-message priority reserve violation: \
             additional_bulk={additional_bulk_result:?}, control={control_result:?}, \
             interactive={interactive_result:?}"
        );
        assert_eq!(bulk_messages.read.lock().await.budgets.len(), 1);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn partial_mux_server_line_retains_budget_until_local_write_finishes() {
        let line = vec![b'm'; cmux_remote_protocol::MAX_FRAME_PAYLOAD];
        let packets = crate::mux_codec::encode_line(1, &line).unwrap();
        assert_eq!(packets.len(), 2);
        let incoming_budget =
            packets.iter().map(|packet| packet.len().max(MIN_BUFFERED_MUX_MESSAGE_BYTES)).sum();
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new_with_incoming_budget(
            daemon_endpoint,
            EndpointRole::Daemon,
            incoming_budget,
        );
        let mux = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let incoming_mux = daemon.accept().await.unwrap().unwrap();
        let additional = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let additional_incoming = daemon.accept().await.unwrap().unwrap();
        let (pump_socket, mut local_core) = tokio::io::duplex(1);
        let (reader, writer) = tokio::io::split(pump_socket);
        let pump = tokio::spawn(pump_mux_server(Arc::new(incoming_mux.stream), reader, writer));

        for packet in packets {
            mux.send_on(Lane::Interactive, packet).await.unwrap();
        }
        let mut first_byte = [0_u8; 1];
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            local_core.read_exact(&mut first_byte),
        )
        .await
        .expect("assembled mux line never reached the blocked local writer")
        .unwrap();
        additional
            .send_on(Lane::Interactive, Bytes::from_static(b"budget-overflow"))
            .await
            .unwrap();

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            additional_incoming.stream.receive(),
        )
        .await
        .expect("additional mux stream did not resolve");
        assert!(
            matches!(result, Err(ServiceError::Reset(ref message)) if message.contains("byte budget")),
            "partial mux line released its incoming budget before the local write: {result:?}"
        );

        pump.abort();
        let _ = pump.await;
        client.shutdown().await;
        daemon.shutdown().await;
    }

    #[tokio::test]
    async fn canceled_reserved_process_streams_do_not_exhaust_the_same_session() {
        const RESERVATION_LIMIT: u128 = 256;

        let workspace = WorkspaceService::new();
        let scope = ClientScope::new(
            "canceled-process-stream-test",
            cmux_remote_protocol::SessionId([12; 16]),
        );
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
                BTreeMap::from([
                    ("process".into(), process.to_string()),
                    ("after".into(), "0".into()),
                ]),
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
}
