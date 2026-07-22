use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::net::SocketAddr;
use std::sync::Arc;

use bytes::Bytes;
use cmux_remote_protocol::{MUX_INPUT_V1_FEATURE, RouteId, Service, ServiceControl};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Semaphore, oneshot};

use crate::service::{ServiceError, ServiceMultiplexer, ServiceStream};
use crate::services::ServicesError;

const MAX_MUX_LINE_BYTES: usize = 16 * 1024 * 1024;
pub const DEFAULT_MAX_FORWARD_CONNECTIONS: usize = 128;

pub struct LocalPortForward {
    local_addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
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
        let task = tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            loop {
                while connections.try_join_next().is_some() {}
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
                connections.spawn(async move {
                    let _permit = permit;
                    let mut metadata = BTreeMap::new();
                    metadata.insert("route".into(), route.0.to_string());
                    let Ok(stream) = multiplexer.open(Service::TcpTunnel, metadata).await else {
                        return;
                    };
                    if await_opened(&stream).await.is_err() {
                        return;
                    }
                    let (reader, writer) = socket.into_split();
                    let _ = pump_client(Arc::new(stream), reader, writer).await;
                });
            }
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        });
        Ok(Self { local_addr, shutdown: Some(shutdown_tx), task: Some(task) })
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
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

#[cfg(unix)]
pub async fn serve_mux_bridge(
    multiplexer: Arc<ServiceMultiplexer>,
    listener: tokio::net::UnixListener,
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
    connections.abort_all();
    while connections.join_next().await.is_some() {}
}

#[derive(Debug, Default, PartialEq, Eq)]
struct ServiceOpenFeatures {
    mux_input_v1: bool,
}

struct OpenedStream {
    features: ServiceOpenFeatures,
    buffered: VecDeque<crate::service::StreamChunk>,
}

async fn await_opened(stream: &ServiceStream) -> Result<OpenedStream, BridgeError> {
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

#[cfg(test)]
async fn pump_mux_client<R, W>(
    remote: Arc<ServiceStream>,
    local_reader: R,
    local_writer: W,
    mux_input_v1: bool,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    pump_mux_client_buffered(remote, local_reader, local_writer, mux_input_v1, VecDeque::new())
        .await
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
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let upload = {
        let remote = remote.clone();
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
                if line.len() > MAX_MUX_LINE_BYTES {
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
        let mut assembler = crate::mux_codec::MuxLineAssembler::default();
        loop {
            let chunk = if let Some(chunk) = initial.pop_front() {
                Some(chunk)
            } else {
                remote.receive().await?
            };
            let Some(chunk) = chunk else { break };
            if !chunk.payload.is_empty()
                && let Some((_, line)) = assembler.push(chunk.lane, chunk.payload)?
            {
                local_writer.write_all(&line).await?;
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
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use async_trait::async_trait;
    use cmux_remote_protocol::{FrameFlags, Lane};
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, split};
    use tokio::sync::{Mutex, mpsc, watch};

    use super::*;
    use crate::service::{EndpointRole, SessionEndpoint};
    use crate::session::ReceivedFrame;

    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
        sequence: AtomicU64,
        generation: watch::Sender<u64>,
        sent: Mutex<Vec<ReceivedFrame>>,
    }

    impl TestEndpoint {
        fn advance_generation(&self, generation: u64) {
            self.generation.send_replace(generation);
        }
    }

    #[async_trait]
    impl SessionEndpoint for TestEndpoint {
        async fn send_frame(
            &self,
            expected_generation: Option<u64>,
            lane: Lane,
            stream: u64,
            payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            let generation = *self.generation.borrow();
            if let Some(expected) = expected_generation
                && expected != generation
            {
                return Err(ServiceError::GenerationChanged { expected, actual: generation });
            }
            let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
            let frame = ReceivedFrame { generation, lane, stream, sequence, flags, payload };
            self.sent.lock().await.push(frame.clone());
            self.outgoing
                .send(frame)
                .await
                .map_err(|_| ServiceError::Transport("test endpoint closed".into()))?;
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
        let (left_tx, left_rx) = mpsc::channel(32);
        let (right_tx, right_rx) = mpsc::channel(32);
        let (left_generation, _) = watch::channel(0);
        let (right_generation, _) = watch::channel(0);
        (
            Arc::new(TestEndpoint {
                outgoing: left_tx,
                incoming: Mutex::new(right_rx),
                sequence: AtomicU64::new(0),
                generation: left_generation,
                sent: Mutex::new(Vec::new()),
            }),
            Arc::new(TestEndpoint {
                outgoing: right_tx,
                incoming: Mutex::new(left_rx),
                sequence: AtomicU64::new(0),
                generation: right_generation,
                sent: Mutex::new(Vec::new()),
            }),
        )
    }

    #[test]
    fn mux_input_requires_an_explicit_backward_compatible_feature() {
        assert_eq!(
            decode_opened(br#"{"type":"opened","service":"mux-control"}"#, Service::MuxControl)
                .unwrap(),
            ServiceOpenFeatures { mux_input_v1: false }
        );
        assert_eq!(
            decode_opened(
                br#"{"type":"opened","service":"mux-control","features":["mux-input-v1"]}"#,
                Service::MuxControl,
            )
            .unwrap(),
            ServiceOpenFeatures { mux_input_v1: true }
        );
    }

    #[tokio::test]
    async fn mux_open_barrier_buffers_data_from_a_ready_lane_until_all_lanes_are_ready() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        let marker = Bytes::from(
            serde_json::to_vec(&serde_json::json!({
                "type": "opened",
                "service": Service::MuxControl,
                "features": [MUX_INPUT_V1_FEATURE],
            }))
            .unwrap(),
        );

        let opened = await_opened(&client_stream);
        let send = async {
            daemon_stream.send_on(Lane::Bulk, marker.clone()).await.unwrap();
            daemon_stream
                .send_on(Lane::Bulk, Bytes::from_static(b"buffered-after-bulk-ready"))
                .await
                .unwrap();
            daemon_stream.send_on(Lane::Control, marker.clone()).await.unwrap();
            daemon_stream.send_on(Lane::Interactive, marker).await.unwrap();
        };
        let (opened, ()) = tokio::join!(opened, send);
        let opened = opened.unwrap();

        assert!(opened.features.mux_input_v1);
        assert_eq!(opened.buffered.len(), 1);
        assert_eq!(opened.buffered[0].lane, Lane::Bulk);
        assert_eq!(opened.buffered[0].payload, b"buffered-after-bulk-ready".as_slice());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn mux_bridge_shutdown_aborts_and_joins_blocked_socket_tasks() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let (client_endpoint, _daemon_endpoint) = endpoint_pair();
        let multiplexer = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let server = tokio::spawn(serve_mux_bridge(multiplexer, listener, shutdown_rx));
        let mut socket = tokio::net::UnixStream::connect(path).await.unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if client_endpoint
                    .sent
                    .lock()
                    .await
                    .iter()
                    .any(|frame| frame.flags.contains(FrameFlags::OPEN))
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        shutdown_tx.send(()).unwrap();
        server.await.unwrap();

        let mut byte = [0_u8; 1];
        assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn generation_change_drops_local_and_target_tunnel_sockets() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint.clone(), EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        let (client_pump_socket, mut local_socket) = tokio::io::duplex(1024);
        let (client_reader, client_writer) = split(client_pump_socket);
        let client_pump =
            tokio::spawn(pump_client(Arc::new(client_stream), client_reader, client_writer));
        let (daemon_pump_socket, mut target_socket) = tokio::io::duplex(1024);
        let (daemon_reader, daemon_writer) = split(daemon_pump_socket);
        let daemon_pump =
            tokio::spawn(pump_client(Arc::new(daemon_stream), daemon_reader, daemon_writer));

        client_endpoint.advance_generation(1);
        daemon_endpoint.advance_generation(1);
        for pump in [client_pump, daemon_pump] {
            let error = tokio::time::timeout(std::time::Duration::from_secs(1), pump)
                .await
                .expect("tunnel socket pump survived reconnect")
                .unwrap()
                .unwrap_err();
            assert!(matches!(
                error,
                BridgeError::Service(ServiceError::GenerationChanged { expected: 0, actual: 1 })
            ));
        }

        let mut byte = [0_u8; 1];
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(1), local_socket.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(1), target_socket.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn reset_after_remote_fin_cancels_the_still_blocked_upload() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint.clone(), EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let stream_id = client_stream.id();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        let (pump_socket, mut local_socket) = tokio::io::duplex(1024);
        let (reader, writer) = split(pump_socket);
        let pump = tokio::spawn(pump_client(Arc::new(client_stream), reader, writer));

        daemon_stream.close().await.unwrap();
        let mut byte = [0_u8; 1];
        assert_eq!(local_socket.read(&mut byte).await.unwrap(), 0);
        daemon_endpoint
            .send_frame(Some(0), Lane::Tunnel, stream_id, Bytes::new(), FrameFlags::RESET)
            .await
            .unwrap();

        let error = tokio::time::timeout(std::time::Duration::from_secs(1), pump)
            .await
            .expect("upload survived RESET after FIN")
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, BridgeError::Service(ServiceError::Reset(_))));
    }

    #[tokio::test]
    async fn generation_change_after_remote_fin_cancels_the_still_blocked_upload() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        let (pump_socket, mut local_socket) = tokio::io::duplex(1024);
        let (reader, writer) = split(pump_socket);
        let pump = tokio::spawn(pump_client(Arc::new(client_stream), reader, writer));

        daemon_stream.close().await.unwrap();
        let mut byte = [0_u8; 1];
        assert_eq!(local_socket.read(&mut byte).await.unwrap(), 0);
        client_endpoint.advance_generation(1);

        let error = tokio::time::timeout(std::time::Duration::from_secs(1), pump)
            .await
            .expect("upload survived generation change after FIN")
            .unwrap()
            .unwrap_err();
        assert!(matches!(
            error,
            BridgeError::Service(ServiceError::GenerationChanged { expected: 0, actual: 1 })
        ));
    }

    #[tokio::test]
    async fn compact_input_preserves_mux_order_and_suppresses_local_responses() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let stream_id = client_stream.id();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        let (client_bridge, mut local_tui) = tokio::io::duplex(16 * 1024);
        let (client_reader, client_writer) = split(client_bridge);
        let client_pump = tokio::spawn(pump_mux_client(
            Arc::new(client_stream),
            client_reader,
            client_writer,
            true,
        ));
        let (daemon_bridge, fake_core) = tokio::io::duplex(16 * 1024);
        let (daemon_reader, daemon_writer) = split(daemon_bridge);
        let daemon_pump = tokio::spawn(crate::services::pump_mux_server(
            Arc::new(daemon_stream),
            daemon_reader,
            daemon_writer,
        ));

        local_tui
            .write_all(
                concat!(
                    "{\"id\":1,\"cmd\":\"send\",\"surface\":7,",
                    "\"bytes\":\"YQ==\",\"no_reply\":true}\n",
                    "{\"id\":2,\"cmd\":\"close-surface\",\"surface\":9}\n",
                    "{\"id\":3,\"cmd\":\"send\",\"surface\":7,",
                    "\"bytes\":\"Yg==\",\"no_reply\":true}\n",
                )
                .as_bytes(),
            )
            .await
            .unwrap();

        let mut fake_core = BufReader::new(fake_core);
        let mut commands = Vec::new();
        for _ in 0..3 {
            let mut line = String::new();
            tokio::time::timeout(std::time::Duration::from_secs(1), fake_core.read_line(&mut line))
                .await
                .expect("ordered mux command timed out")
                .unwrap();
            commands.push(serde_json::from_str::<serde_json::Value>(&line).unwrap());
        }
        assert_eq!(
            commands[0],
            serde_json::json!({
                "id": 1,
                "cmd": "send",
                "surface": 7,
                "bytes": "YQ==",
            })
        );
        assert_eq!(commands[1]["id"], 2);
        assert_eq!(commands[1]["cmd"], "close-surface");
        assert_eq!(
            commands[2],
            serde_json::json!({
                "id": 3,
                "cmd": "send",
                "surface": 7,
                "bytes": "Yg==",
            })
        );

        fake_core
            .get_mut()
            .write_all(b"{\"id\":1,\"ok\":true}\n{\"id\":2,\"ok\":true}\n{\"id\":3,\"ok\":true}\n")
            .await
            .unwrap();
        let mut local_tui = BufReader::new(local_tui);
        let mut response = String::new();
        tokio::time::timeout(std::time::Duration::from_secs(1), local_tui.read_line(&mut response))
            .await
            .expect("control response timed out")
            .unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&response).unwrap()["id"], 2);
        response.clear();
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(50),
                local_tui.read_line(&mut response),
            )
            .await
            .is_err(),
            "one-way input response leaked back to the local mux client"
        );

        let sent = client_endpoint.sent.lock().await;
        let compact = sent
            .iter()
            .filter(|frame| {
                frame.stream == stream_id
                    && crate::mux_input::decode_packet(&frame.payload).ok().flatten().is_some()
            })
            .collect::<Vec<_>>();
        assert_eq!(compact.len(), 2);
        assert!(compact.iter().all(|frame| frame.lane == Lane::Interactive));
        let mutation = sent.iter().find(|frame| {
            frame.stream == stream_id
                && crate::mux_codec::MuxLineAssembler::default()
                    .push(frame.lane, frame.payload.clone())
                    .ok()
                    .flatten()
                    .is_some_and(|(_, line)| {
                        line.windows(13).any(|bytes| bytes == b"close-surface")
                    })
        });
        assert!(mutation.is_some_and(|frame| frame.lane == Lane::Interactive));

        client_pump.abort();
        daemon_pump.abort();
    }

    #[tokio::test]
    async fn forward_connection_limit_defers_additional_tunnel_opens() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let forward = LocalPortForward::bind_with_limit(
            client,
            RouteId(11),
            "127.0.0.1:0".parse().unwrap(),
            1,
        )
        .await
        .unwrap();

        let first_socket = tokio::net::TcpStream::connect(forward.local_addr()).await.unwrap();
        let first = tokio::time::timeout(std::time::Duration::from_secs(1), daemon.accept())
            .await
            .expect("first tunnel was not admitted")
            .unwrap()
            .unwrap();
        assert_eq!(first.service, Service::TcpTunnel);

        let second_socket = tokio::net::TcpStream::connect(forward.local_addr()).await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), daemon.accept())
                .await
                .is_err(),
            "second tunnel exceeded its forward's connection limit"
        );

        first.stream.reject("test".into(), "release admission permit".into()).await.unwrap();
        let second = tokio::time::timeout(std::time::Duration::from_secs(1), daemon.accept())
            .await
            .expect("second tunnel was not admitted after permit release")
            .unwrap()
            .unwrap();
        second.stream.reject("test".into(), "done".into()).await.unwrap();

        drop(first_socket);
        drop(second_socket);
        forward.shutdown().await;
    }

    #[tokio::test]
    async fn forward_rejects_zero_connection_limit() {
        let (client_endpoint, _) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let result = LocalPortForward::bind_with_limit(
            client,
            RouteId(1),
            "127.0.0.1:0".parse().unwrap(),
            0,
        )
        .await;
        let Err(error) = result else { panic!("zero connection limit was accepted") };
        assert!(matches!(error, BridgeError::InvalidConnectionLimit));
    }

    #[tokio::test]
    async fn accepted_forward_socket_disables_nagle() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client = tokio::spawn(tokio::net::TcpStream::connect(listener.local_addr().unwrap()));
        let (server, _) = listener.accept().await.unwrap();
        configure_forward_socket(&server).unwrap();
        assert!(server.nodelay().unwrap());
        client.await.unwrap().unwrap();
    }
}
