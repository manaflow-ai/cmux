use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::net::SocketAddr;
use std::sync::Arc;

use bytes::Bytes;
use cmux_remote_protocol::{MUX_INPUT_V1_FEATURE, RouteId, Service, ServiceControl};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Mutex, Semaphore, oneshot, watch};

use crate::mux_codec::{MAX_MUX_DOWNLOAD_LINE_BYTES, MAX_MUX_LINE_BYTES, mux_line_payload_len};
use crate::service::{ServiceError, ServiceMultiplexer, ServiceStream};
use crate::services::ServicesError;

pub const DEFAULT_MAX_FORWARD_CONNECTIONS: usize = 128;

struct ForwardConnections {
    tasks: Mutex<tokio::task::JoinSet<()>>,
}

impl ForwardConnections {
    fn new() -> Arc<Self> {
        Arc::new(Self { tasks: Mutex::new(tokio::task::JoinSet::new()) })
    }

    async fn reap_finished(&self) {
        let mut tasks = self.tasks.lock().await;
        while tasks.try_join_next().is_some() {}
    }

    async fn shutdown(&self) {
        let mut tasks = self.tasks.lock().await;
        tasks.shutdown().await;
    }

    fn abort_all(&self) {
        if let Ok(mut tasks) = self.tasks.try_lock() {
            tasks.abort_all();
        }
    }
}

pub struct LocalPortForward {
    local_addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
    connections: Arc<ForwardConnections>,
    cancellation: watch::Sender<bool>,
}

impl LocalPortForward {
    pub async fn bind(
        multiplexer: Arc<ServiceMultiplexer>,
        route: RouteId,
        address: SocketAddr,
    ) -> Result<Self, BridgeError> {
        Self::bind_with_limit(multiplexer, route, address, DEFAULT_MAX_FORWARD_CONNECTIONS).await
    }

    pub async fn bind_with_limit(
        multiplexer: Arc<ServiceMultiplexer>,
        route: RouteId,
        address: SocketAddr,
        maximum_connections: usize,
    ) -> Result<Self, BridgeError> {
        if !address.ip().is_loopback() {
            return Err(BridgeError::UnsafeBind(address));
        }
        if maximum_connections == 0 {
            return Err(BridgeError::InvalidConnectionLimit);
        }
        let listener = tokio::net::TcpListener::bind(address).await?;
        let local_addr = listener.local_addr()?;
        let permits = Arc::new(Semaphore::new(maximum_connections));
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let connections = ForwardConnections::new();
        let task_connections = connections.clone();
        let (cancellation, _) = watch::channel(false);
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            loop {
                task_connections.reap_finished().await;
                let permit = tokio::select! {
                    _ = &mut shutdown_rx => break,
                    permit = permits.clone().acquire_owned() => {
                        let Ok(permit) = permit else { break };
                        permit
                    }
                };
                let accepted = tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => accepted,
                };
                let Ok((socket, _)) = accepted else { break };
                if configure_forward_socket(&socket).is_err() {
                    continue;
                }
                let multiplexer = multiplexer.clone();
                let mut cancellation = task_cancellation.subscribe();
                task_connections.tasks.lock().await.spawn(async move {
                    let handler = async move {
                        let _permit = permit;
                        let mut metadata = BTreeMap::new();
                        metadata.insert("route".into(), route.0.to_string());
                        let Ok(stream) = multiplexer.open(Service::TcpTunnel, metadata).await
                        else {
                            return;
                        };
                        if await_opened(&stream).await.is_err() {
                            return;
                        }
                        let (reader, writer) = socket.into_split();
                        let _ = pump_client(Arc::new(stream), reader, writer).await;
                    };
                    tokio::select! {
                        _ = cancellation.changed() => {}
                        _ = handler => {}
                    }
                });
            }
            task_connections.shutdown().await;
        });
        Ok(Self {
            local_addr,
            shutdown: Some(shutdown_tx),
            task: Some(task),
            connections,
            cancellation,
        })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn webview_url(&self, scheme: &str) -> Result<String, BridgeError> {
        if !matches!(scheme, "http" | "https") {
            return Err(BridgeError::InvalidScheme(scheme.into()));
        }
        Ok(format!("{scheme}://{}", self.local_addr))
    }

    pub async fn shutdown(mut self) {
        self.cancellation.send_replace(true);
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}

fn configure_forward_socket(socket: &tokio::net::TcpStream) -> std::io::Result<()> {
    socket.set_nodelay(true)
}

impl Drop for LocalPortForward {
    fn drop(&mut self) {
        self.cancellation.send_replace(true);
        self.connections.abort_all();
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        // A dropped JoinHandle detaches the accept loop. Abort it after the
        // shared cancellation signal and child-task abort request so Drop does
        // not leave either owner or tunnel handlers running indefinitely.
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

#[cfg(unix)]
pub async fn serve_mux_bridge(
    multiplexer: Arc<ServiceMultiplexer>,
    listener: &tokio::net::UnixListener,
    mut shutdown: oneshot::Receiver<()>,
) {
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = &mut shutdown => break,
            completed = connections.join_next(), if !connections.is_empty() => {
                let _ = completed;
            }
            accepted = listener.accept() => {
                let Ok((socket, _)) = accepted else { break };
                let multiplexer = multiplexer.clone();
                connections.spawn(async move {
                    let Ok(stream) = multiplexer.open(Service::MuxControl, BTreeMap::new()).await else { return };
                    let Ok(opened) = await_opened(&stream).await else { return };
                    let (reader, writer) = socket.into_split();
                    let _ = pump_mux_client_buffered(
                        Arc::new(stream),
                        reader,
                        writer,
                        opened.features.mux_input_v1,
                        opened.buffered,
                    )
                    .await;
                });
            }
        }
    }
    connections.shutdown().await;
}

/// A mux control stream the daemon has opened: its `cmux.protocol/2` lines
/// are ready to carry. A caller that reports success before it carries them
/// (`cmux carrier dial`) opens it first, so a daemon that refuses the
/// service is a failure, not a stream that ends at once.
pub struct OpenedMuxControl {
    stream: ServiceStream,
    opened: OpenedStream,
}

impl OpenedMuxControl {
    /// Opens a mux control stream and waits for the daemon's answer.
    pub async fn open(multiplexer: &Arc<ServiceMultiplexer>) -> Result<Self, BridgeError> {
        let stream = multiplexer.open(Service::MuxControl, BTreeMap::new()).await?;
        match await_opened(&stream).await {
            Ok(opened) => Ok(Self { stream, opened }),
            Err(error) => {
                let _ = stream.close().await;
                Err(error)
            }
        }
    }

    /// Close the stream without carrying it (a dial that carries another
    /// service on the same session).
    pub async fn close(self) {
        let _ = self.stream.close().await;
    }

    /// Carry one local `cmux.protocol/2` line stream (`reader`, `writer`):
    /// the same bytes the Mac's bridge socket carries, for a caller that has
    /// the stream on its own pipes. Returns when either side ends.
    pub async fn bridge<R, W>(self, reader: R, writer: W) -> Result<(), BridgeError>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        pump_mux_client_buffered(
            Arc::new(self.stream),
            reader,
            writer,
            self.opened.features.mux_input_v1,
            self.opened.buffered,
        )
        .await
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ServiceOpenFeatures {
    pub(crate) mux_input_v1: bool,
}

pub(crate) struct OpenedStream {
    pub(crate) features: ServiceOpenFeatures,
    pub(crate) buffered: VecDeque<crate::service::StreamChunk>,
}

pub(crate) async fn await_opened(stream: &ServiceStream) -> Result<OpenedStream, BridgeError> {
    if stream.service() != Service::MuxControl {
        let chunk = stream.receive().await?.ok_or(BridgeError::Rejected("stream closed".into()))?;
        return Ok(OpenedStream {
            features: decode_opened(&chunk.payload, stream.service())?,
            buffered: VecDeque::new(),
        });
    }

    let mut seen = 0_u8;
    let mut features = None;
    let mut buffered = VecDeque::new();
    while seen != 0b111 {
        let chunk = stream
            .receive()
            .await?
            .ok_or(BridgeError::Rejected("stream closed before every mux lane was ready".into()))?;
        let marker =
            serde_json::from_slice::<serde_json::Value>(&chunk.payload).ok().and_then(|value| {
                value.get("type").and_then(serde_json::Value::as_str).map(str::to_owned)
            });
        if matches!(marker.as_deref(), Some("opened") | Some("rejected")) {
            let current = decode_opened(&chunk.payload, stream.service())?;
            if let Some(expected) = &features
                && expected != &current
            {
                return Err(BridgeError::Rejected(
                    "mux lanes advertised inconsistent open features".into(),
                ));
            }
            features = Some(current);
            seen |= match chunk.lane {
                cmux_remote_protocol::Lane::Interactive => 0b001,
                cmux_remote_protocol::Lane::Control => 0b010,
                cmux_remote_protocol::Lane::Bulk => 0b100,
                cmux_remote_protocol::Lane::Tunnel => {
                    return Err(BridgeError::Rejected(
                        "mux open marker arrived on the tunnel lane".into(),
                    ));
                }
            };
        } else {
            buffered.push_back(chunk);
        }
    }
    Ok(OpenedStream {
        features: features.expect("three observed markers include one feature set"),
        buffered,
    })
}

fn decode_opened(payload: &[u8], expected: Service) -> Result<ServiceOpenFeatures, BridgeError> {
    let value = serde_json::from_slice::<serde_json::Value>(payload)?;
    let mux_input_v1 =
        value.get("features").and_then(serde_json::Value::as_array).is_some_and(|features| {
            features.iter().any(|feature| feature.as_str() == Some(MUX_INPUT_V1_FEATURE))
        });
    match serde_json::from_value::<ServiceControl>(value)? {
        ServiceControl::Opened { service } if service == expected => {
            Ok(ServiceOpenFeatures { mux_input_v1 })
        }
        ServiceControl::Rejected { message, .. } => Err(BridgeError::Rejected(message)),
        _ => Err(BridgeError::Rejected("invalid service-open response".into())),
    }
}

async fn pump_client<R, W>(
    remote: Arc<ServiceStream>,
    mut local_reader: R,
    mut local_writer: W,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let failure_remote = remote.clone();
    let upload = {
        let remote = remote.clone();
        async move {
            let mut buffer = vec![0_u8; 32 * 1024];
            loop {
                let size = local_reader.read(&mut buffer).await?;
                if size == 0 {
                    remote.close().await?;
                    break;
                }
                remote.send(Bytes::copy_from_slice(&buffer[..size])).await?;
            }
            Ok::<_, BridgeError>(())
        }
    };
    let download = async move {
        while let Some(chunk) = remote.receive().await? {
            local_writer.write_all(&chunk.payload).await?;
            if chunk.finished || chunk.reset {
                break;
            }
        }
        local_writer.shutdown().await?;
        Ok::<_, BridgeError>(())
    };
    let transfer = async {
        tokio::try_join!(upload, download)?;
        Ok::<_, BridgeError>(())
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

async fn pump_mux_client_buffered<R, W>(
    remote: Arc<ServiceStream>,
    local_reader: R,
    mut local_writer: W,
    mux_input_v1: bool,
    mut initial: VecDeque<crate::service::StreamChunk>,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    use tokio::io::{AsyncWriteExt, BufReader};
    let upload = {
        let remote = remote.clone();
        async move {
            let mut reader = BufReader::new(local_reader);
            let mut line = Vec::new();
            let mut message = 1_u64;
            loop {
                let size = crate::mux_codec::read_bounded_line(&mut reader, &mut line).await?;
                if size == 0 {
                    remote.close().await?;
                    break;
                }
                if mux_line_payload_len(&line) > MAX_MUX_LINE_BYTES.saturating_sub(1) {
                    return Err(BridgeError::MuxLineTooLarge(line.len()));
                }
                if mux_input_v1 && let Some(input) = crate::mux_input::encode_local_line(&line)? {
                    remote.send_on(cmux_remote_protocol::Lane::Interactive, input).await?;
                } else {
                    let lane = crate::mux_lanes::classify_client_line(&line);
                    for packet in crate::mux_codec::encode_line(message, &line)? {
                        remote.send_on(lane, packet).await?;
                    }
                }
                message = message.checked_add(1).ok_or(BridgeError::MuxMessageIdsExhausted)?;
            }
            Ok::<_, BridgeError>(())
        }
    };
    let download = async move {
        let mut assembler = crate::mux_codec::MuxLineAssembler::<
            Option<crate::service::StreamBudget>,
        >::with_maximum(MAX_MUX_DOWNLOAD_LINE_BYTES);
        loop {
            let chunk = if let Some(chunk) = initial.pop_front() {
                Some(chunk)
            } else {
                remote.receive().await?
            };
            let Some(mut chunk) = chunk else { break };
            if !chunk.payload.is_empty() {
                let budget = chunk.take_budget();
                if let Some(line) = assembler.push_retaining(chunk.lane, chunk.payload, budget)? {
                    local_writer.write_all(line.payload()).await?;
                }
            }
            if chunk.finished || chunk.reset {
                break;
            }
        }
        local_writer.shutdown().await?;
        Ok::<_, BridgeError>(())
    };
    tokio::pin!(upload);
    tokio::pin!(download);
    tokio::select! {
        result = &mut upload => result?,
        result = &mut download => result?,
    }
    Ok(())
}

/// A Cloud machine's desktop socket (`cmux-agent-rd.socket`, the `cmux.rd/1`
/// host on the agent display): the one path a Cloud daemon allows for
/// [`Service::LocalSocket`].
pub const CLOUD_DESKTOP_SOCKET: &str = "/run/cmux-rd/desktop.sock";

/// Opens [`Service::LocalSocket`] to `path` and waits for the daemon's
/// answer: the opened stream, or [`BridgeError::Rejected`] with the daemon's
/// reason (not the owner's session, a path off its allowlist, no allowlist,
/// or the socket did not answer).
pub async fn open_local_socket(
    multiplexer: &Arc<ServiceMultiplexer>,
    path: &str,
) -> Result<Arc<ServiceStream>, BridgeError> {
    let metadata = BTreeMap::from([("path".to_owned(), path.to_owned())]);
    let stream = multiplexer.open(Service::LocalSocket, metadata).await?;
    if let Err(error) = await_opened(&stream).await {
        let _ = stream.close().await;
        return Err(error);
    }
    Ok(Arc::new(stream))
}

/// Copies raw bytes both ways between an opened stream (from
/// [`open_local_socket`]) and `reader` / `writer` until either side ends.
pub async fn bridge_raw_stream<R, W>(
    stream: Arc<ServiceStream>,
    reader: R,
    writer: W,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    pump_client(stream, reader, writer).await
}

/// Opens one [`Service::TcpTunnel`] stream to `route` and copies bytes
/// between it and `reader` / `writer`, the way an ssh `ProxyCommand` needs:
/// EOF on `reader` half-closes the stream and the remote side keeps sending,
/// and the call returns once the remote closes, without waiting for more
/// local input. Every chunk is flushed, so a buffered `writer` (stdout)
/// never holds a protocol message back. A remote reset is an error.
pub async fn dial_tcp_route<R, W>(
    multiplexer: &Arc<ServiceMultiplexer>,
    route: RouteId,
    mut local_reader: R,
    mut local_writer: W,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let metadata = BTreeMap::from([("route".to_owned(), route.0.to_string())]);
    let stream = multiplexer.open(Service::TcpTunnel, metadata).await?;
    if let Err(error) = await_opened(&stream).await {
        let _ = stream.close().await;
        return Err(error);
    }
    let remote = Arc::new(stream);
    let upload = {
        let remote = remote.clone();
        async move {
            let mut buffer = vec![0_u8; 32 * 1024];
            loop {
                let size = local_reader.read(&mut buffer).await?;
                let Some(bytes) = buffer.get(..size).filter(|bytes| !bytes.is_empty()) else {
                    remote.close().await?;
                    break;
                };
                remote.send(Bytes::copy_from_slice(bytes)).await?;
            }
            Ok::<_, BridgeError>(())
        }
    };
    let download = {
        let remote = remote.clone();
        async move {
            while let Some(chunk) = remote.receive().await? {
                if !chunk.payload.is_empty() {
                    local_writer.write_all(&chunk.payload).await?;
                    local_writer.flush().await?;
                }
                if chunk.reset {
                    return Err(BridgeError::Rejected("the remote reset the connection".into()));
                }
                if chunk.finished {
                    break;
                }
            }
            local_writer.shutdown().await?;
            Ok::<_, BridgeError>(())
        }
    };
    tokio::pin!(upload);
    tokio::pin!(download);
    let failure = remote.wait_for_failure();
    tokio::pin!(failure);
    // Stops when the remote closes or fails; local EOF only ends the upload.
    let mut uploading = true;
    loop {
        tokio::select! {
            biased;
            error = &mut failure => return Err(error.into()),
            result = &mut download => return result,
            result = &mut upload, if uploading => {
                result?;
                uploading = false;
            }
        }
    }
}

#[derive(Debug)]
pub enum BridgeError {
    Service(ServiceError),
    Services(ServicesError),
    Io(std::io::Error),
    Json(serde_json::Error),
    UnsafeBind(SocketAddr),
    InvalidConnectionLimit,
    InvalidScheme(String),
    Rejected(String),
    MuxLineTooLarge(usize),
    MuxCodec(crate::mux_codec::MuxCodecError),
    MuxInput(crate::mux_input::MuxInputError),
    MuxMessageIdsExhausted,
}

impl fmt::Display for BridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Service(error) => error.fmt(formatter),
            Self::Services(error) => error.fmt(formatter),
            Self::Io(error) => error.fmt(formatter),
            Self::Json(error) => error.fmt(formatter),
            Self::UnsafeBind(address) => {
                write!(formatter, "local forward must bind loopback, got {address}")
            }
            Self::InvalidConnectionLimit => {
                formatter.write_str("local forward connection limit must be positive")
            }
            Self::InvalidScheme(scheme) => {
                write!(formatter, "unsupported WebView scheme {scheme:?}")
            }
            Self::Rejected(message) => {
                write!(formatter, "remote service rejected the stream: {message}")
            }
            Self::MuxLineTooLarge(size) => {
                write!(formatter, "mux control line is too large: {size}")
            }
            Self::MuxCodec(error) => error.fmt(formatter),
            Self::MuxInput(error) => error.fmt(formatter),
            Self::MuxMessageIdsExhausted => {
                formatter.write_str("mux control message identifiers exhausted")
            }
        }
    }
}

impl std::error::Error for BridgeError {}

impl From<ServiceError> for BridgeError {
    fn from(error: ServiceError) -> Self {
        Self::Service(error)
    }
}

impl From<ServicesError> for BridgeError {
    fn from(error: ServicesError) -> Self {
        Self::Services(error)
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<crate::mux_codec::MuxCodecError> for BridgeError {
    fn from(error: crate::mux_codec::MuxCodecError) -> Self {
        Self::MuxCodec(error)
    }
}

impl From<crate::mux_input::MuxInputError> for BridgeError {
    fn from(error: crate::mux_input::MuxInputError) -> Self {
        Self::MuxInput(error)
    }
}

#[cfg(test)]
mod tests;
