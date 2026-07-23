use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{
    Lane, MUX_INPUT_V1_FEATURE, ProcessEvent, ProcessId, ProcessReplayRange, RouteId, RpcError,
    RpcErrorDetails, RpcEvent, RpcRequest, RpcResponse, Service, ServiceControl, WorkspaceRequest,
    WorkspaceResponse,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Mutex, Semaphore, mpsc, watch};
use tokio::task::JoinSet;

use crate::daemon::ServerConnection;
use crate::service::{
    EndpointRole, IncomingStream, ServiceError, ServiceMultiplexer, ServiceStream, StreamBudget,
};
use crate::workspace::{ClientScope, ProcessSubscriptionError, WorkspaceService};

const MAX_RPC_MESSAGE: usize = 16 * 1024 * 1024;
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

struct RequestAdmission {
    interactive: Arc<Semaphore>,
    control: Arc<Semaphore>,
    bulk: Arc<Semaphore>,
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
}

impl DaemonServices {
    pub fn new(workspace: WorkspaceService, mux_socket: Option<PathBuf>) -> Arc<Self> {
        Arc::new(Self { workspace, mux_socket })
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
            Service::TcpTunnel => {
                Self::serve_tcp_tunnel(workspace, incoming.stream, incoming.metadata).await
            }
            Service::MuxControl => Self::serve_mux_control(mux_socket, incoming.stream).await,
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
                let response = workspace.handle_rpc_for(scope.clone(), request).await;
                send_workspace_response(&workspace, &messages, response, false).await?;
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
                let response = workspace.handle_rpc_for(scope.clone(), request).await;
                send_workspace_response(&workspace, &messages, response, true).await?;
                continue;
            }
            let workspace = workspace.clone();
            let scope = scope.clone();
            let messages = messages.clone();
            requests.spawn_local(async move {
                let _permit = permit;
                let response = workspace.handle_rpc_for(scope, request).await;
                send_workspace_response(&workspace, &messages, response, true).await
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
        let process = parse_process_id(&metadata, "process")?;
        let after = metadata
            .get("after")
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| ServicesError::Metadata("after must be an unsigned integer".into()))?
            .unwrap_or(0);
        let reserve = match metadata.get("reserve").map(String::as_str) {
            None | Some("false") => false,
            Some("true") => true,
            Some(_) => {
                return Err(ServicesError::Metadata("reserve must be true or false".into()));
            }
        };
        let subscription =
            workspace.subscribe_or_reserve_process(&scope, process, after, reserve).await;
        let stream = Arc::new(stream);
        let mut subscription = match subscription {
            Ok(subscription) => subscription,
            Err(error) => {
                let RpcError { message, details, .. } = error;
                let Some(RpcErrorDetails::ProcessReplayGap { requested_after, range }) = details
                else {
                    return Err(ServicesError::Remote(message));
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
    async fn serve_mux_control(
        mux_socket: Option<PathBuf>,
        stream: ServiceStream,
    ) -> Result<(), ServicesError> {
        let path = mux_socket.as_ref().ok_or_else(|| {
            ServicesError::Unavailable("mux control socket is not configured".into())
        })?;
        let socket = tokio::net::UnixStream::connect(path).await?;
        let stream = Arc::new(stream);
        send_opened(&stream, Lane::Interactive).await?;
        let (reader, writer) = socket.into_split();
        pump_mux_server(stream, reader, writer).await
    }

    #[cfg(not(unix))]
    async fn serve_mux_control(
        _mux_socket: Option<PathBuf>,
        stream: ServiceStream,
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
        EncodedWorkspaceResponse::Message(encoded) => messages.send(&encoded).await,
        EncodedWorkspaceResponse::TooLarge => {
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
            | WorkspaceResponse::ProcessEvents { .. },
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
            Service::MuxControl | Service::ComputerUse => Lane::Interactive,
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
        local_writer.shutdown().await?;
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

pub(crate) async fn pump_mux_server<R, W>(
    remote: Arc<ServiceStream>,
    local_reader: R,
    mut local_writer: W,
) -> Result<(), ServicesError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    use tokio::io::{AsyncBufReadExt, BufReader};

    let tracker = Arc::new(crate::mux_lanes::MuxLaneTracker::default());
    let upload = {
        let remote = remote.clone();
        let tracker = tracker.clone();
        async move {
            let mut reader = BufReader::new(local_reader);
            let mut line = Vec::new();
            let mut message = 1_u64;
            loop {
                line.clear();
                let size = reader.read_until(b'\n', &mut line).await?;
                if size == 0 {
                    remote.close().await?;
                    break;
                }
                let Some(lane) = tracker.classify_server_line(&line) else {
                    continue;
                };
                for packet in crate::mux_codec::encode_line(message, &line)? {
                    remote.send_on(lane, packet).await?;
                }
                message = message.checked_add(1).ok_or(ServicesError::MessageIdsExhausted)?;
            }
            Ok::<_, ServicesError>(())
        }
    };
    let download = async move {
        let mut assembler = crate::mux_codec::MuxLineAssembler::default();
        while let Some(chunk) = remote.receive().await? {
            if !chunk.payload.is_empty() {
                if let Some(input) = crate::mux_input::decode_packet(&chunk.payload)? {
                    tracker.suppress_response(input.request);
                    local_writer.write_all(&input.into_local_line()?).await?;
                } else if let Some((lane, line)) = assembler.push(chunk.lane, chunk.payload)? {
                    tracker.observe_request(&line, lane);
                    local_writer.write_all(&line).await?;
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

fn parse_process_id(
    metadata: &BTreeMap<String, String>,
    key: &str,
) -> Result<ProcessId, ServicesError> {
    let value =
        metadata.get(key).ok_or_else(|| ServicesError::Metadata(format!("missing {key}")))?;
    ProcessId::parse_str(value)
        .map_err(|_| ServicesError::Metadata(format!("{key} must be a UUID")))
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
    use std::sync::atomic::{AtomicU64, Ordering};
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
    use tokio::sync::{mpsc, watch};

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
        let error = client
            .process_events(unknown, 0)
            .await
            .expect_err("unknown process stream should be rejected");
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
            id: cmux_remote_protocol::RequestId(5),
            timeout_ms: None,
            request: WorkspaceRequest::CancelRequest {
                request: cmux_remote_protocol::RequestId(4),
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
                id: cmux_remote_protocol::RequestId(71),
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
            id: cmux_remote_protocol::RequestId(72),
            result: Err(RpcError::new("invalid-data", "\u{1}".repeat(RPC_CODEC_OFFLOAD_BYTES / 4))),
        };

        assert!(workspace_response_needs_codec(&response));
    }

    #[tokio::test]
    async fn oversized_error_response_returns_same_id_error() {
        assert_oversized_response_falls_back(
            RpcResponse {
                id: cmux_remote_protocol::RequestId(72),
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
            id: cmux_remote_protocol::RequestId(expected_id.0 + 1),
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
                    id: cmux_remote_protocol::RequestId(41),
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
    async fn canceled_reserved_process_streams_do_not_exhaust_the_same_session() {
        const RESERVATION_LIMIT: u64 = 256;

        let workspace = WorkspaceService::new();
        let scope = ClientScope::new(
            "canceled-process-stream-test",
            cmux_remote_protocol::SessionId([12; 16]),
        );
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);

        for index in 0..RESERVATION_LIMIT {
            let process = ProcessId::from_u128(0x8000_0000_0010_0000 + u128::from(index));
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

        let final_process = ProcessId::from_u128(0x8000_0000_0020_0000);
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match workspace.subscribe_or_reserve_process(&scope, final_process, 0, true).await {
                    Ok(_) => {
                        workspace.release_process_reservation(&scope, final_process).await;
                        break;
                    }
                    Err(error) if error.code == "resource-exhausted" => {
                        tokio::task::yield_now().await;
                    }
                    Err(error) => panic!("canceled opens leaked reservation state: {error}"),
                }
            }
        })
        .await
        .expect("canceled opens leaked reservation capacity");
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
                id: cmux_remote_protocol::RequestId(1),
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
                id: cmux_remote_protocol::RequestId(2),
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
                id: cmux_remote_protocol::RequestId(3),
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
