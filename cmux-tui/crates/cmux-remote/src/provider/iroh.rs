use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::net::SocketAddr;
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use ::iroh::{
    Endpoint, EndpointAddr as NodeAddr, EndpointId as NodeId, RelayMode, RelayUrl, SecretKey,
};
use async_trait::async_trait;
use cmux_remote_protocol::MAX_WIRE_FRAME_BYTES;
use tokio::sync::{Mutex, OnceCell, Semaphore, mpsc, oneshot};
use tokio::task::{JoinHandle, JoinSet};

use crate::daemon::RemoteDaemon;
use crate::link::FrameLink;
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, TransportProvider,
};

/// ALPN negotiated by cmux remote sessions over Iroh.
pub const CMUX_IROH_ALPN: &[u8] = b"dev.cmux.remote/1";

/// Optional routing key containing a node ID when it is not present in the URL.
pub const ROUTING_NODE_ID: &str = "node_id";
/// Optional routing key containing one Iroh relay URL.
pub const ROUTING_RELAY_URL: &str = "relay_url";
/// Optional routing key containing comma or whitespace separated socket addresses.
pub const ROUTING_DIRECT_ADDRS: &str = "direct_addrs";

/// Load a stable carrier key or create it with owner-only permissions. Noise
/// remains the daemon identity, but a stable Iroh key keeps published route
/// hints valid across daemon restarts.
pub fn load_or_create_iroh_secret(path: &Path) -> Result<SecretKey, ProviderError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_provider_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                .map_err(io_provider_error)?;
        }
    }
    if path.exists() {
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(path).map_err(io_provider_error)?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(io_provider_error)?;
        let bytes: [u8; 32] = bytes.try_into().map_err(|bytes: Vec<u8>| {
            ProviderError::Configuration(format!(
                "Iroh secret at {} is {} bytes, expected 32",
                path.display(),
                bytes.len()
            ))
        })?;
        return Ok(SecretKey::from_bytes(&bytes));
    }
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| ProviderError::Transport(format!("randomness failed: {error}")))?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path).map_err(io_provider_error)?;
    file.write_all(&bytes).map_err(io_provider_error)?;
    file.sync_all().map_err(io_provider_error)?;
    Ok(SecretKey::from_bytes(&bytes))
}

fn io_provider_error(error: std::io::Error) -> ProviderError {
    ProviderError::Transport(error.to_string())
}

/// Parsed Iroh addressing information for one daemon.
///
/// The node ID authenticates the carrier peer. Direct addresses permit LAN or
/// publicly reachable connections, while the relay URL supplies NAT traversal
/// and a fallback path when direct QUIC cannot be established.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IrohRoute {
    node_addr: NodeAddr,
}

impl IrohRoute {
    pub fn new(node_addr: NodeAddr) -> Self {
        Self { node_addr }
    }

    pub fn from_request(request: &ConnectRequest) -> Result<Self, ProviderError> {
        if !request.endpoint.username().is_empty()
            || request.endpoint.password().is_some()
            || request.endpoint.port().is_some()
        {
            return Err(ProviderError::Configuration(
                "Iroh URLs cannot contain user information or a port".into(),
            ));
        }
        if request.endpoint.query().is_some() || request.endpoint.fragment().is_some() {
            return Err(ProviderError::Configuration(
                "Iroh routes belong in routing hints, not URL query parameters".into(),
            ));
        }

        let endpoint_node_id = node_id_from_url(&request.endpoint)?;
        let hinted_node_id = request.routing.get(ROUTING_NODE_ID).map(String::as_str);
        let encoded_node_id = match (endpoint_node_id, hinted_node_id) {
            (Some(endpoint), Some(hint)) if endpoint != hint => {
                return Err(ProviderError::Configuration(
                    "Iroh URL and routing hint contain different node IDs".into(),
                ));
            }
            (Some(endpoint), _) => endpoint,
            (None, Some(hint)) => hint,
            (None, None) => {
                return Err(ProviderError::Configuration(
                    "Iroh endpoint is missing its node ID".into(),
                ));
            }
        };
        let node_id = NodeId::from_str(encoded_node_id).map_err(|error| {
            ProviderError::Configuration(format!("invalid Iroh node ID: {error}"))
        })?;

        let relay_url = request
            .routing
            .get(ROUTING_RELAY_URL)
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                RelayUrl::from_str(value.trim()).map_err(|error| {
                    ProviderError::Configuration(format!("invalid Iroh relay URL: {error}"))
                })
            })
            .transpose()?;
        let direct_addresses = request
            .routing
            .get(ROUTING_DIRECT_ADDRS)
            .map(|value| parse_direct_addresses(value))
            .transpose()?
            .unwrap_or_default();

        let mut node_addr = NodeAddr::new(node_id);
        if let Some(relay_url) = relay_url {
            node_addr = node_addr.with_relay_url(relay_url);
        }
        node_addr =
            node_addr.with_addrs(direct_addresses.into_iter().map(::iroh::TransportAddr::Ip));
        Ok(Self::new(node_addr))
    }

    pub fn node_addr(&self) -> &NodeAddr {
        &self.node_addr
    }

    pub fn node_id(&self) -> NodeId {
        self.node_addr.id
    }

    pub fn into_node_addr(self) -> NodeAddr {
        self.node_addr
    }

    /// Encodes the complete address as non-secret [`ConnectRequest`] routing hints.
    pub fn routing_hints(&self) -> BTreeMap<String, String> {
        let mut hints = BTreeMap::from([(ROUTING_NODE_ID.into(), self.node_id().to_string())]);
        if let Some(relay_url) = self.node_addr.relay_urls().next() {
            hints.insert(ROUTING_RELAY_URL.into(), relay_url.to_string());
        }
        let direct_addresses =
            self.node_addr.ip_addrs().map(ToString::to_string).collect::<Vec<_>>().join(",");
        if !direct_addresses.is_empty() {
            hints.insert(ROUTING_DIRECT_ADDRS.into(), direct_addresses);
        }
        hints
    }
}

fn node_id_from_url(endpoint: &url::Url) -> Result<Option<&str>, ProviderError> {
    if let Some(host) = endpoint.host_str() {
        if !matches!(endpoint.path(), "" | "/") {
            return Err(ProviderError::Configuration(
                "Iroh URL cannot contain a path when the node ID is the host".into(),
            ));
        }
        return Ok(Some(host));
    }

    let path = endpoint.path().trim_matches('/');
    if path.is_empty() {
        Ok(None)
    } else if path.contains('/') {
        Err(ProviderError::Configuration("Iroh URL path must contain only a node ID".into()))
    } else {
        Ok(Some(path))
    }
}

fn parse_direct_addresses(encoded: &str) -> Result<Vec<SocketAddr>, ProviderError> {
    let encoded = encoded.trim();
    if encoded.is_empty() {
        return Ok(Vec::new());
    }
    let values = if encoded.starts_with('[') {
        serde_json::from_str::<Vec<String>>(encoded).map_err(|error| {
            ProviderError::Configuration(format!(
                "Iroh direct addresses are not a valid JSON string array: {error}"
            ))
        })?
    } else {
        encoded
            .split(|character: char| character == ',' || character.is_whitespace())
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .collect()
    };

    values
        .into_iter()
        .map(|value| {
            value.parse::<SocketAddr>().map_err(|error| {
                ProviderError::Configuration(format!(
                    "invalid Iroh direct address {value:?}: {error}"
                ))
            })
        })
        .collect()
}

#[derive(Debug, Clone)]
pub struct IrohProviderConfig {
    /// Stable Iroh carrier identity. Noise identity remains authoritative.
    pub secret_key: Option<SecretKey>,
    /// Relay infrastructure used for hole punching and fallback forwarding.
    pub relay_mode: RelayMode,
    /// Publish and resolve routes through the n0 discovery service.
    pub discovery_n0: bool,
    pub alpn: Vec<u8>,
    pub maximum_frame_bytes: usize,
}

impl Default for IrohProviderConfig {
    fn default() -> Self {
        Self {
            secret_key: None,
            relay_mode: RelayMode::Default,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: MAX_WIRE_FRAME_BYTES,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct IrohListenerLimits {
    maximum_connections: usize,
    maximum_pending_streams: usize,
    maximum_pending_streams_per_connection: usize,
    connection_handshake_timeout: Duration,
    first_stream_timeout: Duration,
    unauthenticated_timeout: Duration,
    pre_auth_timeout: Duration,
}

impl Default for IrohListenerLimits {
    fn default() -> Self {
        Self {
            maximum_connections: 64,
            maximum_pending_streams: 64,
            maximum_pending_streams_per_connection: 8,
            connection_handshake_timeout: Duration::from_secs(10),
            first_stream_timeout: Duration::from_secs(15),
            unauthenticated_timeout: Duration::from_secs(5 * 60),
            pre_auth_timeout: Duration::from_secs(5 * 60),
        }
    }
}

impl IrohListenerLimits {
    fn validate(self) -> Result<Self, ProviderError> {
        if self.maximum_connections == 0
            || self.maximum_pending_streams == 0
            || self.maximum_pending_streams_per_connection == 0
            || self.connection_handshake_timeout.is_zero()
            || self.first_stream_timeout.is_zero()
            || self.unauthenticated_timeout.is_zero()
            || self.pre_auth_timeout.is_zero()
        {
            return Err(ProviderError::Configuration(
                "Iroh listener limits and deadlines must be positive".into(),
            ));
        }
        Ok(self)
    }
}

struct IrohAdmission {
    limits: IrohListenerLimits,
    connections: Arc<Semaphore>,
    pending_streams: Arc<Semaphore>,
}

impl IrohAdmission {
    fn new(limits: IrohListenerLimits) -> Self {
        Self {
            limits,
            connections: Arc::new(Semaphore::new(limits.maximum_connections)),
            pending_streams: Arc::new(Semaphore::new(limits.maximum_pending_streams)),
        }
    }
}

pub struct IrohProvider {
    config: IrohProviderConfig,
    endpoint: OnceCell<Endpoint>,
}

impl fmt::Debug for IrohProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IrohProvider")
            .field("config", &self.config)
            .field("initialized", &self.endpoint.get().is_some())
            .finish()
    }
}

impl IrohProvider {
    pub fn new(config: IrohProviderConfig) -> Result<Self, ProviderError> {
        validate_config(&config)?;
        Ok(Self { config, endpoint: OnceCell::new() })
    }

    async fn endpoint(&self) -> Result<&Endpoint, ProviderError> {
        self.endpoint.get_or_try_init(|| bind_endpoint(&self.config)).await
    }

    pub async fn local_node_id(&self) -> Result<NodeId, ProviderError> {
        Ok(self.endpoint().await?.id())
    }

    pub async fn local_node_addr(&self) -> Result<NodeAddr, ProviderError> {
        Ok(self.endpoint().await?.addr())
    }

    /// Gracefully closes the shared endpoint and all groups created by this provider.
    pub async fn close(&self) {
        if let Some(endpoint) = self.endpoint.get() {
            endpoint.close().await;
        }
    }
}

fn validate_config(config: &IrohProviderConfig) -> Result<(), ProviderError> {
    if config.alpn.is_empty() || config.alpn.len() > u8::MAX as usize {
        return Err(ProviderError::Configuration(
            "Iroh ALPN must contain between 1 and 255 bytes".into(),
        ));
    }
    if config.maximum_frame_bytes == 0 || config.maximum_frame_bytes > u32::MAX as usize {
        return Err(ProviderError::Configuration(format!(
            "Iroh maximum frame size must be between 1 and {} bytes",
            u32::MAX
        )));
    }
    Ok(())
}

async fn bind_endpoint(config: &IrohProviderConfig) -> Result<Endpoint, ProviderError> {
    use ::iroh::endpoint::presets;

    let builder = if config.discovery_n0 {
        Endpoint::builder(presets::N0)
    } else {
        Endpoint::builder(presets::Minimal)
    };
    let mut builder =
        builder.alpns(vec![config.alpn.clone()]).relay_mode(config.relay_mode.clone());
    if let Some(secret_key) = config.secret_key.clone() {
        builder = builder.secret_key(secret_key);
    }
    builder
        .bind()
        .await
        .map_err(|error| ProviderError::Transport(format!("could not bind Iroh endpoint: {error}")))
}

async fn connect_iroh_connection(
    endpoint: &Endpoint,
    node_addr: &NodeAddr,
    alpn: &[u8],
) -> Result<::iroh::endpoint::Connection, ProviderError> {
    let remote_node_id = node_addr.id;
    let connection = endpoint.connect(node_addr.clone(), alpn).await.map_err(|error| {
        ProviderError::Transport(format!(
            "could not connect to Iroh node {remote_node_id}: {error}"
        ))
    })?;
    let authenticated_node_id = connection.remote_id();
    if authenticated_node_id != remote_node_id {
        connection.close(1_u8.into(), b"unexpected Iroh peer identity");
        return Err(ProviderError::Transport(format!(
            "Iroh authenticated {authenticated_node_id}, expected {remote_node_id}"
        )));
    }
    Ok(connection)
}

#[async_trait]
impl TransportProvider for IrohProvider {
    fn name(&self) -> &'static str {
        "iroh"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["iroh"]
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        if !self.schemes().contains(&request.endpoint.scheme()) {
            return Err(ProviderError::UnsupportedScheme(request.endpoint.scheme().into()));
        }
        let route = IrohRoute::from_request(&request)?;
        let remote_node_id = route.node_id();
        let node_addr = route.into_node_addr();
        let endpoint = self.endpoint().await?.clone();
        let connection = connect_iroh_connection(&endpoint, &node_addr, &self.config.alpn).await?;

        Ok(Arc::new(IrohLinkGroup {
            connection: Mutex::new(connection),
            endpoint,
            node_addr,
            alpn: self.config.alpn.clone(),
            description: format!("iroh://{remote_node_id}"),
            evidence: CarrierEvidence::Iroh { endpoint_id: remote_node_id.to_string() },
            maximum_frame_bytes: self.config.maximum_frame_bytes,
            closed: AtomicBool::new(false),
        }))
    }
}

/// Daemon-side Iroh endpoint.
///
/// Iroh authenticates and encrypts the carrier, but every accepted stream is
/// still passed through [`RemoteDaemon::accept`] so the cmux Noise identity and
/// enrollment database remain authoritative.
pub struct IrohListener {
    endpoint: Endpoint,
    admission: Arc<IrohAdmission>,
    relay_enabled: bool,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl fmt::Debug for IrohListener {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IrohListener")
            .field("node_id", &self.endpoint.id())
            .field("closed", &self.endpoint.is_closed())
            .field("relay_enabled", &self.relay_enabled)
            .field("limits", &self.admission.limits)
            .finish_non_exhaustive()
    }
}

impl IrohListener {
    pub async fn bind(
        daemon: Arc<RemoteDaemon>,
        config: IrohProviderConfig,
    ) -> Result<Self, ProviderError> {
        Self::bind_with_limits(daemon, config, IrohListenerLimits::default()).await
    }

    async fn bind_with_limits(
        daemon: Arc<RemoteDaemon>,
        config: IrohProviderConfig,
        limits: IrohListenerLimits,
    ) -> Result<Self, ProviderError> {
        validate_config(&config)?;
        let admission = Arc::new(IrohAdmission::new(limits.validate()?));
        let relay_enabled = !matches!(&config.relay_mode, RelayMode::Disabled);
        let endpoint = bind_endpoint(&config).await?;
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(run_iroh_listener(
            endpoint.clone(),
            daemon,
            config.alpn,
            config.maximum_frame_bytes,
            admission.clone(),
            shutdown_rx,
        ));
        Ok(Self {
            endpoint,
            admission,
            relay_enabled,
            shutdown: Some(shutdown_tx),
            task: Some(task),
        })
    }

    pub fn node_id(&self) -> NodeId {
        self.endpoint.id()
    }

    /// Returns current direct addresses and the selected relay fallback.
    ///
    /// Iroh 1.x binds local sockets before it finishes selecting a home relay.
    /// Route advertisement waits up to the existing carrier handshake deadline
    /// for that relay, then falls back to the available direct addresses so an
    /// offline LAN daemon can still start.
    pub async fn node_addr(&self) -> Result<NodeAddr, ProviderError> {
        if self.relay_enabled && self.endpoint.addr().relay_urls().next().is_none() {
            let _ = tokio::time::timeout(
                self.admission.limits.connection_handshake_timeout,
                self.endpoint.online(),
            )
            .await;
        }
        Ok(self.endpoint.addr())
    }

    pub async fn route(&self) -> Result<IrohRoute, ProviderError> {
        self.node_addr().await.map(IrohRoute::new)
    }

    pub async fn shutdown(mut self) -> Result<(), ProviderError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.take().expect("Iroh listener task is present").await.map_err(|error| {
            ProviderError::Transport(format!("Iroh listener task failed: {error}"))
        })
    }
}

impl Drop for IrohListener {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

async fn run_iroh_listener(
    endpoint: Endpoint,
    daemon: Arc<RemoteDaemon>,
    alpn: Vec<u8>,
    maximum_frame_bytes: usize,
    admission: Arc<IrohAdmission>,
    mut shutdown: oneshot::Receiver<()>,
) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = &mut shutdown => break,
            completed = connections.join_next(), if !connections.is_empty() => {
                let _ = completed;
            }
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                let Ok(connection_permit) = admission.connections.clone().try_acquire_owned()
                else {
                    incoming.refuse();
                    continue;
                };
                let daemon = daemon.clone();
                let alpn = alpn.clone();
                let admission = admission.clone();
                connections.spawn(async move {
                    let _connection_permit = connection_permit;
                    let Ok(Ok(connection)) = tokio::time::timeout(
                        admission.limits.connection_handshake_timeout,
                        async move { incoming.await },
                    ).await else {
                        return;
                    };
                    serve_iroh_connection(
                        connection,
                        daemon,
                        alpn,
                        maximum_frame_bytes,
                        admission,
                    ).await;
                });
            }
        }
    }

    endpoint.close().await;
    connections.shutdown().await;
}

async fn serve_iroh_connection(
    connection: ::iroh::endpoint::Connection,
    daemon: Arc<RemoteDaemon>,
    alpn: Vec<u8>,
    maximum_frame_bytes: usize,
    admission: Arc<IrohAdmission>,
) {
    if connection.alpn() != alpn.as_slice() {
        connection.close(2_u8.into(), b"unexpected cmux ALPN");
        return;
    }
    let remote_node_id = connection.remote_id();

    let mut next_stream_id = 0_u64;
    let mut links = JoinSet::new();
    let (accept_results_tx, mut accept_results_rx) = mpsc::unbounded_channel();
    let per_connection =
        Arc::new(Semaphore::new(admission.limits.maximum_pending_streams_per_connection));
    let first_stream_deadline = tokio::time::sleep(admission.limits.first_stream_timeout);
    let unauthenticated_deadline = tokio::time::sleep(admission.limits.unauthenticated_timeout);
    tokio::pin!(first_stream_deadline);
    tokio::pin!(unauthenticated_deadline);
    let mut authenticated = false;
    loop {
        tokio::select! {
            biased;
            completed = links.join_next(), if !links.is_empty() => {
                let _ = completed;
            }
            result = accept_results_rx.recv() => {
                match result {
                    Some(IrohAcceptResult::Succeeded) => authenticated = true,
                    Some(IrohAcceptResult::Failed) if !authenticated => {
                        connection.close(7_u8.into(), b"first cmux authentication failed");
                        break;
                    }
                    Some(IrohAcceptResult::Failed) => {}
                    None => break,
                }
            }
            _ = &mut first_stream_deadline, if next_stream_id == 0 => {
                connection.close(4_u8.into(), b"first cmux stream timed out");
                break;
            }
            _ = &mut unauthenticated_deadline, if !authenticated => {
                connection.close(8_u8.into(), b"cmux authentication timed out");
                break;
            }
            accepted = connection.accept_bi() => {
                let Ok((mut sender, mut receiver)) = accepted else { break };
                let Ok(per_connection_permit) = per_connection.clone().try_acquire_owned()
                else {
                    let _ = sender.reset(5_u8.into());
                    let _ = receiver.stop(5_u8.into());
                    connection.close(5_u8.into(), b"too many pending cmux streams");
                    break;
                };
                let Ok(global_permit) = admission.pending_streams.clone().try_acquire_owned()
                else {
                    let _ = sender.reset(6_u8.into());
                    let _ = receiver.stop(6_u8.into());
                    connection.close(6_u8.into(), b"cmux pre-auth capacity exhausted");
                    break;
                };
                let stream_id = next_stream_id;
                next_stream_id = next_stream_id.saturating_add(1);
                let daemon = daemon.clone();
                let description = format!("iroh-daemon://{remote_node_id}/{stream_id}");
                let pre_auth_timeout = admission.limits.pre_auth_timeout;
                let accept_results = accept_results_tx.clone();
                links.spawn(async move {
                    let permits = (per_connection_permit, global_permit);
                    let link = LengthDelimitedLink::new(
                        description,
                        maximum_frame_bytes,
                        receiver,
                        sender,
                    );
                    let result = tokio::time::timeout(
                        pre_auth_timeout,
                        daemon.accept(Box::new(link)),
                    ).await;
                    let result = match result {
                        Ok(Ok(())) => IrohAcceptResult::Succeeded,
                        Ok(Err(_)) | Err(_) => IrohAcceptResult::Failed,
                    };
                    let _ = accept_results.send(result);
                    drop(permits);
                });
            }
        }
    }
    links.shutdown().await;
}

#[derive(Debug, Clone, Copy)]
enum IrohAcceptResult {
    Succeeded,
    Failed,
}

struct IrohLinkGroup {
    connection: Mutex<::iroh::endpoint::Connection>,
    endpoint: Endpoint,
    node_addr: NodeAddr,
    alpn: Vec<u8>,
    description: String,
    evidence: CarrierEvidence,
    maximum_frame_bytes: usize,
    closed: AtomicBool,
}

impl fmt::Debug for IrohLinkGroup {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IrohLinkGroup")
            .field("description", &self.description)
            .field("maximum_frame_bytes", &self.maximum_frame_bytes)
            .field("closed", &self.closed.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl LinkGroup for IrohLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            parallel_links: true,
            independent_reconnect: true,
            path_migration: true,
            carrier_encryption: true,
        }
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("Iroh connection group is closed".into()));
        }
        let (sender, receiver) = {
            let mut connection = self.connection.lock().await;
            if self.closed.load(Ordering::Acquire) {
                return Err(ProviderError::Transport("Iroh connection group is closed".into()));
            }
            match connection.open_bi().await {
                Ok(streams) => streams,
                Err(open_error) => {
                    if self.closed.load(Ordering::Acquire) {
                        return Err(ProviderError::Transport(
                            "Iroh connection group is closed".into(),
                        ));
                    }
                    let replacement = connect_iroh_connection(
                        &self.endpoint,
                        &self.node_addr,
                        &self.alpn,
                    )
                    .await
                    .map_err(|reconnect_error| {
                        ProviderError::Transport(format!(
                            "Iroh stream open failed ({open_error}); reconnect failed: {reconnect_error}"
                        ))
                    })?;
                    *connection = replacement;
                    connection.open_bi().await.map_err(|error| {
                        ProviderError::Transport(format!(
                            "could not open Iroh stream after reconnect: {error}"
                        ))
                    })?
                }
            }
        };
        Ok(Box::new(LengthDelimitedLink::new(
            format!("{}:{}:{}", self.description, request.lane, request.generation),
            self.maximum_frame_bytes,
            receiver,
            sender,
        )))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        if !self.closed.swap(true, Ordering::AcqRel) {
            self.connection.lock().await.close(0_u8.into(), b"cmux Iroh link group closed");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::net::{IpAddr, Ipv4Addr};
    use std::time::Duration;

    use bytes::Bytes;
    use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
    use tokio::io::AsyncWriteExt;
    use url::Url;
    use zeroize::Zeroizing;

    use super::*;
    use crate::connection::{ClientConnection, ClientConnectionConfig};
    use crate::crypto::{ClientAuthMode, StaticIdentity};
    use crate::daemon::RemoteDaemon;
    use crate::identity::AuthDatabase;
    use crate::link::LinkError;
    use crate::session::SessionLimits;

    fn secret(byte: u8) -> SecretKey {
        SecretKey::from_bytes(&[byte; 32])
    }

    fn request(node_id: NodeId, routing: BTreeMap<String, String>) -> ConnectRequest {
        ConnectRequest {
            endpoint: Url::parse(&format!("iroh://{node_id}")).unwrap(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Isolated,
            routing,
        }
    }

    fn local_config(secret_key: SecretKey) -> IrohProviderConfig {
        IrohProviderConfig {
            secret_key: Some(secret_key),
            relay_mode: RelayMode::Disabled,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: MAX_WIRE_FRAME_BYTES,
        }
    }

    async fn connect_test_client(
        listener: &IrohListener,
        secret_key: SecretKey,
    ) -> (Endpoint, ::iroh::endpoint::Connection) {
        let endpoint = bind_endpoint(&local_config(secret_key)).await.unwrap();
        let route = listener.route().await.unwrap();
        let connection =
            connect_iroh_connection(&endpoint, route.node_addr(), CMUX_IROH_ALPN).await.unwrap();
        (endpoint, connection)
    }

    async fn wait_for_available_permits(semaphore: &Semaphore, expected: usize) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if semaphore.available_permits() == expected {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[test]
    fn parses_relay_and_direct_address_hints() {
        let node_id = secret(7).public();
        let routing = BTreeMap::from([
            (ROUTING_DIRECT_ADDRS.into(), r#"["127.0.0.1:4010","[::1]:4011"]"#.into()),
            (ROUTING_RELAY_URL.into(), "https://relay.example.test".into()),
        ]);
        let route = IrohRoute::from_request(&request(node_id, routing)).unwrap();
        assert_eq!(route.node_id(), node_id);
        assert_eq!(route.node_addr().ip_addrs().count(), 2);
        assert_eq!(
            route.node_addr().relay_urls().next(),
            Some(&RelayUrl::from_str("https://relay.example.test").unwrap())
        );
    }

    #[test]
    fn rejects_conflicting_node_ids_and_invalid_addresses() {
        let first = secret(8).public();
        let second = secret(9).public();
        let conflicting =
            request(first, BTreeMap::from([(ROUTING_NODE_ID.into(), second.to_string())]));
        assert!(matches!(
            IrohRoute::from_request(&conflicting),
            Err(ProviderError::Configuration(_))
        ));

        let invalid =
            request(first, BTreeMap::from([(ROUTING_DIRECT_ADDRS.into(), "not-a-socket".into())]));
        assert!(matches!(IrohRoute::from_request(&invalid), Err(ProviderError::Configuration(_))));
    }

    #[tokio::test]
    async fn direct_local_connection_uses_independent_bounded_streams() {
        let server_key = secret(10);
        let client_key = secret(11);
        let server = Endpoint::builder(::iroh::endpoint::presets::Minimal)
            .secret_key(server_key.clone())
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .unwrap();
        let server_socket = server
            .bound_sockets()
            .into_iter()
            .find(SocketAddr::is_ipv4)
            .expect("Iroh binds an IPv4 socket");
        let direct = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), server_socket.port());
        let (responses_read_tx, responses_read_rx) = oneshot::channel();

        let server_task = tokio::spawn({
            let server = server.clone();
            let expected_client = client_key.public();
            async move {
                let incoming = server.accept().await.expect("server endpoint closed");
                let connection = incoming.await.unwrap();
                assert_eq!(connection.remote_id(), expected_client);
                for expected in [b"interactive".as_slice(), b"bulk".as_slice()] {
                    let (sender, receiver) = connection.accept_bi().await.unwrap();
                    let link = LengthDelimitedLink::new("server", 32, receiver, sender);
                    let received = link.receive().await.unwrap().unwrap();
                    assert_eq!(received, expected);
                    link.send(received).await.unwrap();
                    link.close().await.unwrap();
                }
                let _ = responses_read_rx.await;
            }
        });

        let provider = IrohProvider::new(IrohProviderConfig {
            secret_key: Some(client_key),
            relay_mode: RelayMode::Disabled,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: 32,
        })
        .unwrap();
        let group = provider
            .connect(request(
                server_key.public(),
                BTreeMap::from([(ROUTING_DIRECT_ADDRS.into(), direct.to_string())]),
            ))
            .await
            .unwrap();

        assert_eq!(
            group.evidence(),
            &CarrierEvidence::Iroh { endpoint_id: server_key.public().to_string() }
        );
        assert!(group.capabilities().path_migration);

        let interactive =
            group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await.unwrap();
        interactive.send(Bytes::from_static(b"interactive")).await.unwrap();
        assert_eq!(interactive.receive().await.unwrap().unwrap(), &b"interactive"[..]);

        let bulk = group.open(LinkRequest { lane: Lane::Bulk, generation: 2 }).await.unwrap();
        assert!(matches!(
            bulk.send(Bytes::from(vec![0; 33])).await,
            Err(LinkError::FrameTooLarge { actual: 33, maximum: 32 })
        ));
        bulk.send(Bytes::from_static(b"bulk")).await.unwrap();
        assert_eq!(bulk.receive().await.unwrap().unwrap(), &b"bulk"[..]);
        let _ = responses_read_tx.send(());

        interactive.close().await.unwrap();
        bulk.close().await.unwrap();
        group.close().await.unwrap();
        assert!(matches!(
            group.open(LinkRequest { lane: Lane::Control, generation: 3 }).await,
            Err(ProviderError::Transport(_))
        ));

        tokio::time::timeout(Duration::from_secs(10), server_task).await.unwrap().unwrap();
        provider.close().await;
        server.close().await;
    }

    #[tokio::test]
    async fn concurrent_opens_share_one_reconnected_quic_connection() {
        let server_key = secret(21);
        let client_key = secret(22);
        let server = Endpoint::builder(::iroh::endpoint::presets::Minimal)
            .secret_key(server_key.clone())
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .unwrap();
        let server_socket = server
            .bound_sockets()
            .into_iter()
            .find(SocketAddr::is_ipv4)
            .expect("Iroh binds an IPv4 socket");
        let direct = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), server_socket.port());
        let (first_read_tx, first_read_rx) = oneshot::channel();
        let (first_closed_tx, first_closed_rx) = oneshot::channel();
        let (responses_read_tx, responses_read_rx) = oneshot::channel();

        let server_task = tokio::spawn({
            let server = server.clone();
            async move {
                let incoming = server.accept().await.expect("server endpoint closed");
                let first_connection = incoming.await.unwrap();
                let (sender, receiver) = first_connection.accept_bi().await.unwrap();
                let first = LengthDelimitedLink::new("first-server", 32, receiver, sender);
                let received = first.receive().await.unwrap().unwrap();
                first.send(received).await.unwrap();
                first.close().await.unwrap();
                let _ = first_read_rx.await;
                first_connection.close(10_u8.into(), b"test reconnect");
                let _ = first_closed_tx.send(());

                let incoming = server.accept().await.expect("server endpoint closed");
                let replacement = incoming.await.unwrap();
                for _ in 0..2 {
                    let (sender, receiver) = replacement.accept_bi().await.unwrap();
                    let link = LengthDelimitedLink::new("replacement-server", 32, receiver, sender);
                    let received = link.receive().await.unwrap().unwrap();
                    link.send(received).await.unwrap();
                    link.close().await.unwrap();
                }
                let _ = responses_read_rx.await;
            }
        });

        let config = IrohProviderConfig {
            secret_key: Some(client_key),
            relay_mode: RelayMode::Disabled,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: 32,
        };
        let endpoint = bind_endpoint(&config).await.unwrap();
        let node_addr = NodeAddr::new(server_key.public()).with_ip_addr(direct);
        let connection =
            connect_iroh_connection(&endpoint, &node_addr, CMUX_IROH_ALPN).await.unwrap();
        let observed_connection = connection.clone();
        let group = IrohLinkGroup {
            connection: Mutex::new(connection),
            endpoint: endpoint.clone(),
            node_addr,
            alpn: CMUX_IROH_ALPN.to_vec(),
            description: format!("iroh://{}", server_key.public()),
            evidence: CarrierEvidence::Iroh { endpoint_id: server_key.public().to_string() },
            maximum_frame_bytes: 32,
            closed: AtomicBool::new(false),
        };

        let first = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await.unwrap();
        first.send(Bytes::from_static(b"first")).await.unwrap();
        assert_eq!(first.receive().await.unwrap().unwrap(), &b"first"[..]);
        let _ = first_read_tx.send(());
        first.close().await.unwrap();
        first_closed_rx.await.unwrap();
        let _ = tokio::time::timeout(Duration::from_secs(5), observed_connection.closed())
            .await
            .unwrap();

        let (interactive, bulk) = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(
                group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }),
                group.open(LinkRequest { lane: Lane::Bulk, generation: 1 }),
            )
        })
        .await
        .unwrap();
        let interactive = interactive.unwrap();
        let bulk = bulk.unwrap();
        interactive.send(Bytes::from_static(b"interactive")).await.unwrap();
        bulk.send(Bytes::from_static(b"bulk")).await.unwrap();
        assert_eq!(interactive.receive().await.unwrap().unwrap(), &b"interactive"[..]);
        assert_eq!(bulk.receive().await.unwrap().unwrap(), &b"bulk"[..]);
        let _ = responses_read_tx.send(());

        interactive.close().await.unwrap();
        bulk.close().await.unwrap();
        group.close().await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), server_task).await.unwrap().unwrap();
        endpoint.close().await;
        server.close().await;
    }

    #[tokio::test]
    async fn listener_closes_streamless_connections_at_the_idle_deadline() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            first_stream_timeout: Duration::from_millis(100),
            connection_handshake_timeout: Duration::from_secs(1),
            pre_auth_timeout: Duration::from_secs(1),
            ..IrohListenerLimits::default()
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(31)), limits).await.unwrap();
        let (client, connection) = connect_test_client(&listener, secret(32)).await;

        let _ = tokio::time::timeout(Duration::from_secs(2), connection.closed())
            .await
            .expect("streamless Iroh connection should be closed at its deadline");
        wait_for_available_permits(&listener.admission.connections, limits.maximum_connections)
            .await;

        listener.shutdown().await.unwrap();
        client.close().await;
    }

    #[tokio::test]
    async fn listener_refuses_connections_before_spawning_past_the_global_cap() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            maximum_connections: 1,
            first_stream_timeout: Duration::from_secs(5),
            connection_handshake_timeout: Duration::from_secs(1),
            pre_auth_timeout: Duration::from_secs(1),
            ..IrohListenerLimits::default()
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(33)), limits).await.unwrap();
        let (first_client, first_connection) = connect_test_client(&listener, secret(34)).await;
        wait_for_available_permits(&listener.admission.connections, 0).await;

        let second_client = bind_endpoint(&local_config(secret(35))).await.unwrap();
        let route = listener.route().await.unwrap();
        let second = tokio::time::timeout(
            Duration::from_secs(5),
            connect_iroh_connection(&second_client, route.node_addr(), CMUX_IROH_ALPN),
        )
        .await
        .expect("excess Iroh connection should be refused promptly");
        assert!(second.is_err());
        assert!(first_connection.close_reason().is_none());

        first_connection.close(0_u8.into(), b"test complete");
        listener.shutdown().await.unwrap();
        first_client.close().await;
        second_client.close().await;
    }

    #[tokio::test]
    async fn listener_bounds_pending_streams_per_connection_and_globally() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            maximum_connections: 2,
            maximum_pending_streams: 2,
            maximum_pending_streams_per_connection: 1,
            first_stream_timeout: Duration::from_secs(5),
            connection_handshake_timeout: Duration::from_secs(1),
            unauthenticated_timeout: Duration::from_secs(5),
            pre_auth_timeout: Duration::from_secs(5),
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(36)), limits).await.unwrap();
        let (client, connection) = connect_test_client(&listener, secret(37)).await;

        let (mut first_sender, first_receiver) = connection.open_bi().await.unwrap();
        first_sender.write_all(b"x").await.unwrap();
        first_sender.flush().await.unwrap();
        let first_stream = (first_sender, first_receiver);
        wait_for_available_permits(&listener.admission.pending_streams, 1).await;

        let (mut excess_sender, excess_receiver) = connection.open_bi().await.unwrap();
        excess_sender.write_all(b"x").await.unwrap();
        let excess_stream = (excess_sender, excess_receiver);
        let _ = tokio::time::timeout(Duration::from_secs(5), connection.closed())
            .await
            .expect("per-connection stream excess should close its carrier");
        drop((first_stream, excess_stream));
        wait_for_available_permits(&listener.admission.pending_streams, 2).await;

        listener.shutdown().await.unwrap();
        client.close().await;

        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            maximum_connections: 2,
            maximum_pending_streams: 1,
            maximum_pending_streams_per_connection: 2,
            first_stream_timeout: Duration::from_secs(5),
            connection_handshake_timeout: Duration::from_secs(1),
            unauthenticated_timeout: Duration::from_secs(5),
            pre_auth_timeout: Duration::from_secs(5),
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(38)), limits).await.unwrap();
        let (first_client, first_connection) = connect_test_client(&listener, secret(39)).await;
        let (second_client, second_connection) = connect_test_client(&listener, secret(40)).await;

        let (mut first_sender, first_receiver) = first_connection.open_bi().await.unwrap();
        first_sender.write_all(b"x").await.unwrap();
        first_sender.flush().await.unwrap();
        let first_stream = (first_sender, first_receiver);
        wait_for_available_permits(&listener.admission.pending_streams, 0).await;

        let (mut excess_sender, excess_receiver) = second_connection.open_bi().await.unwrap();
        excess_sender.write_all(b"x").await.unwrap();
        let excess_stream = (excess_sender, excess_receiver);
        let _ = tokio::time::timeout(Duration::from_secs(5), second_connection.closed())
            .await
            .expect("global stream excess should close its carrier");
        assert!(first_connection.close_reason().is_none());
        drop((first_stream, excess_stream));
        first_connection.close(0_u8.into(), b"test complete");

        listener.shutdown().await.unwrap();
        first_client.close().await;
        second_client.close().await;
    }

    #[tokio::test]
    async fn listener_keeps_the_unauthenticated_deadline_after_the_first_stream() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            maximum_connections: 1,
            maximum_pending_streams: 1,
            maximum_pending_streams_per_connection: 1,
            first_stream_timeout: Duration::from_secs(5),
            connection_handshake_timeout: Duration::from_secs(1),
            unauthenticated_timeout: Duration::from_millis(100),
            pre_auth_timeout: Duration::from_secs(5),
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(41)), limits).await.unwrap();
        let (client, connection) = connect_test_client(&listener, secret(42)).await;

        let (mut sender, receiver) = connection.open_bi().await.unwrap();
        sender.write_all(b"x").await.unwrap();
        sender.flush().await.unwrap();
        let stream = (sender, receiver);
        wait_for_available_permits(&listener.admission.pending_streams, 0).await;
        let _ = tokio::time::timeout(Duration::from_secs(2), connection.closed())
            .await
            .expect("one stalled stream must not lift the unauthenticated deadline");
        wait_for_available_permits(&listener.admission.pending_streams, 1).await;
        wait_for_available_permits(&listener.admission.connections, 1).await;
        drop(stream);

        listener.shutdown().await.unwrap();
        client.close().await;
    }

    #[tokio::test]
    async fn listener_closes_the_carrier_when_first_authentication_fails() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let limits = IrohListenerLimits {
            maximum_connections: 1,
            maximum_pending_streams: 1,
            maximum_pending_streams_per_connection: 1,
            first_stream_timeout: Duration::from_secs(5),
            connection_handshake_timeout: Duration::from_secs(1),
            unauthenticated_timeout: Duration::from_secs(5),
            pre_auth_timeout: Duration::from_secs(5),
        };
        let listener =
            IrohListener::bind_with_limits(daemon, local_config(secret(43)), limits).await.unwrap();
        let (client, connection) = connect_test_client(&listener, secret(44)).await;

        let (sender, receiver) = connection.open_bi().await.unwrap();
        let invalid = LengthDelimitedLink::new(
            "invalid-client-handshake",
            MAX_WIRE_FRAME_BYTES,
            receiver,
            sender,
        );
        invalid.send(Bytes::from_static(b"not a Noise prelude")).await.unwrap();
        let _ = tokio::time::timeout(Duration::from_secs(2), connection.closed())
            .await
            .expect("failed first authentication should close its Iroh carrier");
        wait_for_available_permits(&listener.admission.pending_streams, 1).await;
        wait_for_available_permits(&listener.admission.connections, 1).await;

        listener.shutdown().await.unwrap();
        client.close().await;
    }

    #[tokio::test]
    async fn listener_registers_isolated_lanes_with_remote_daemon() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(temp.path(), "test-daemon", false).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let server_key = secret(12);
        let listener = IrohListener::bind(
            daemon,
            IrohProviderConfig {
                secret_key: Some(server_key.clone()),
                relay_mode: RelayMode::Disabled,
                discovery_n0: false,
                alpn: CMUX_IROH_ALPN.to_vec(),
                maximum_frame_bytes: MAX_WIRE_FRAME_BYTES,
            },
        )
        .await
        .unwrap();
        let route = listener.route().await.unwrap();
        assert_eq!(route.node_id(), server_key.public());
        assert!(!route.node_addr().ip_addrs().collect::<Vec<_>>().is_empty());

        let invitation = auth
            .create_invitation(Duration::from_secs(60), vec![format!("iroh://{}", route.node_id())])
            .await
            .unwrap();
        let provider = IrohProvider::new(IrohProviderConfig {
            secret_key: Some(secret(13)),
            relay_mode: RelayMode::Disabled,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: MAX_WIRE_FRAME_BYTES,
        })
        .unwrap();
        let session = SessionId([14; 16]);
        let group = provider
            .connect(ConnectRequest {
                endpoint: Url::parse(&format!("iroh://{}", route.node_id())).unwrap(),
                session,
                lane_policy: LanePolicy::Isolated,
                routing: route.routing_hints(),
            })
            .await
            .unwrap();
        let client_identity = StaticIdentity::generate().unwrap();
        let connect = tokio::spawn(ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: client_identity,
                expected_daemon: Some(auth.identity().public_key()),
                auth: ClientAuthMode::Invitation {
                    id: invitation.id.clone(),
                    secret: Zeroizing::new(invitation.secret_bytes().unwrap()),
                },
                device_name: "iroh-test-client".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: crate::connection::ReconnectPolicy::default(),
            },
        ));

        let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
        assert_eq!(pending.len(), 1);
        auth.approve(&pending[0].invitation_id).await.unwrap();
        let client =
            tokio::time::timeout(Duration::from_secs(10), connect).await.unwrap().unwrap().unwrap();
        let server_connection = tokio::time::timeout(Duration::from_secs(10), accepted.recv())
            .await
            .unwrap()
            .expect("daemon acceptance channel remains open");
        assert_eq!(server_connection.session_id, session);

        client
            .send(
                Lane::Interactive,
                41,
                Bytes::from_static(b"client-to-daemon"),
                FrameFlags::RELIABLE,
            )
            .await
            .unwrap();
        let received = tokio::time::timeout(Duration::from_secs(5), server_connection.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(received.lane, Lane::Interactive);
        assert_eq!(received.payload, &b"client-to-daemon"[..]);

        server_connection
            .send(Lane::Bulk, 42, Bytes::from_static(b"daemon-to-client"), FrameFlags::RELIABLE)
            .await
            .unwrap();
        let received = tokio::time::timeout(Duration::from_secs(5), client.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(received.lane, Lane::Bulk);
        assert_eq!(received.payload, &b"daemon-to-client"[..]);

        client.close().await.unwrap();
        let _ = server_connection.close().await;
        listener.shutdown().await.unwrap();
        provider.close().await;
    }
}
