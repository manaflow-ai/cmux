use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{
    Lane, MUX_INPUT_V1_FEATURE, ProcessEvent, ProcessId, RouteId, RpcError, RpcRequest,
    RpcResponse, Service, ServiceControl, WorkspaceRequest, WorkspaceResponse,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, watch};
use tokio::task::JoinSet;

use crate::daemon::ServerConnection;
use crate::service::{
    EndpointRole, IncomingStream, ServiceError, ServiceMultiplexer, ServiceStream,
};
use crate::workspace::{ClientScope, WorkspaceService};

const MAX_RPC_MESSAGE: usize = 16 * 1024 * 1024;
const RPC_CODEC_OFFLOAD_BYTES: usize = 64 * 1024;
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
                Self::serve_process_stream(workspace, incoming.stream, incoming.metadata).await
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
        stream: ServiceStream,
        metadata: BTreeMap<String, String>,
    ) -> Result<(), ServicesError> {
        let process = parse_u64(&metadata, "process")?;
        let after = metadata
            .get("after")
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| ServicesError::Metadata("after must be an unsigned integer".into()))?
            .unwrap_or(0);
        let mut subscription = workspace
            .subscribe_process(ProcessId(process), after)
            .await
            .map_err(|error| ServicesError::Remote(error.message))?;
        let stream = Arc::new(stream);
        send_opened(&stream, Lane::Interactive).await?;
        let messages = MessageStream::new(stream);
        loop {
            tokio::select! {
                event = subscription.recv() => match event {
                    Ok(event) => {
                        let exited = matches!(&event.event, ProcessEvent::Exit { .. });
                        messages.send(&serde_json::to_vec(&event)?).await?;
                        if exited {
                            messages.close().await?;
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        messages.close().await?;
                        break;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        return Err(ServicesError::Remote(format!(
                            "process output exceeded retained replay after {skipped} events"
                        )));
                    }
                },
                closed = messages.receive() => match closed? {
                    None => break,
                    Some(_) => {
                        return Err(ServicesError::Remote(
                            "process event streams are output-only".into(),
                        ));
                    }
                }
            }
        }
        Ok(())
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
    let encoded = if allow_offload && workspace_response_needs_codec(&response) {
        workspace
            .run_codec("RPC response encode", move || {
                serde_json::to_vec(&response)
                    .map_err(|error| RpcError::new("internal", format!("encode response: {error}")))
            })
            .await
            .map_err(|error| ServicesError::Remote(error.message))?
    } else {
        serde_json::to_vec(&response)?
    };
    messages.send(&encoded).await
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
        _ => false,
    }
}

pub struct MessageStream {
    stream: Arc<ServiceStream>,
    lane: Lane,
    read: Mutex<MessageReadState>,
    write: Mutex<()>,
}

struct MessageReadState {
    buffer: BytesMut,
    budgets: Vec<OwnedSemaphorePermit>,
    finished: bool,
}

impl MessageStream {
    pub fn new(stream: Arc<ServiceStream>) -> Self {
        let lane = match stream.service() {
            Service::MuxControl | Service::ProcessStream | Service::ComputerUse => {
                Lane::Interactive
            }
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
        FrameFlags, ProcessEnvironment, ProcessEvent, ProcessIo, ProcessLifetime, RpcEvent,
        WorkspaceId, WorkspaceResponse,
    };
    use tempfile::tempdir;
    #[cfg(unix)]
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    #[cfg(unix)]
    use tokio::sync::oneshot;
    use tokio::sync::{mpsc, watch};

    use super::*;
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

    #[cfg(unix)]
    #[tokio::test]
    async fn completed_process_event_stream_sends_exit_then_finishes() {
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
                    ("process".into(), process.0.to_string()),
                    ("after".into(), "0".into()),
                ]),
            )
            .await
            .unwrap();
        let incoming = daemon.accept().await.unwrap().unwrap();
        let handler = tokio::spawn(DaemonServices::serve_process_stream(
            workspace,
            incoming.stream,
            incoming.metadata,
        ));
        let opened = client_stream.receive().await.unwrap().unwrap();
        assert!(matches!(
            serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
            ServiceControl::Opened { service: Service::ProcessStream }
        ));
        let messages = MessageStream::new(Arc::new(client_stream));
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
