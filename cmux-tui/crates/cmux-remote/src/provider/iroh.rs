use std::collections::BTreeMap;
use std::fmt;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::SocketAddr;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use ::iroh::{
    Endpoint, EndpointAddr as NodeAddr, EndpointId as NodeId, RelayMode, RelayUrl, SecretKey,
};
use async_trait::async_trait;
use cmux_remote_protocol::MAX_WIRE_FRAME_BYTES;
use tokio::sync::{Mutex, OnceCell, OwnedSemaphorePermit, Semaphore, mpsc, oneshot, watch};
use tokio::task::{JoinHandle, JoinSet};

use crate::crypto::SECURE_FRAME_OVERHEAD_BYTES;
use crate::daemon::{InboundLink, NetworkPeer, RemoteDaemon};
use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CMUX_IROH_ALPN, CarrierEvidence, ConnectRequest, IrohPathMode, LengthDelimitedLink, LinkGroup,
    LinkRequest, ProviderCapabilities, ProviderError, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID,
    ROUTING_RELAY_URL, SupportedClientAuthModes, TransportProvider, sanitized_route,
};
use crate::secure_directory::{DirectoryAccess, ensure_secure_directory};

const AUTO_RELAY_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(2);

/// Load a stable carrier key or create it with owner-only permissions. Noise
/// remains the daemon identity, but a stable Iroh key keeps published route
/// hints valid across daemon restarts.
pub fn load_or_create_iroh_secret(path: &Path) -> Result<SecretKey, ProviderError> {
    if let Some(parent) = path.parent() {
        ensure_secure_directory(parent, DirectoryAccess::ManagedOwnerOnly)
            .map_err(io_provider_error)?;
    }
    if path.exists() {
        let bytes = crate::secret_file::read_owner_only(path, 32).map_err(io_provider_error)?;
        let bytes: [u8; 32] = bytes.as_slice().try_into().map_err(|_| {
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
#[derive(Clone, PartialEq, Eq)]
pub struct IrohRoute {
    node_addr: NodeAddr,
}

impl fmt::Debug for IrohRoute {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IrohRoute")
            .field("node_id", &self.node_id())
            .field("relay_configured", &self.node_addr.relay_urls().next().is_some())
            .field("direct_address_count", &self.node_addr.ip_addrs().count())
            .finish()
    }
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
        let node_id = NodeId::from_str(encoded_node_id)
            .map_err(|_| ProviderError::Configuration("invalid Iroh node ID".into()))?;

        let relay_url = request
            .routing
            .get(ROUTING_RELAY_URL)
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                RelayUrl::from_str(value.trim())
                    .map_err(|_| ProviderError::Configuration("invalid Iroh relay URL".into()))
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
        serde_json::from_str::<Vec<String>>(encoded).map_err(|_| {
            ProviderError::Configuration(
                "Iroh direct addresses are not a valid JSON string array".into(),
            )
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
            value
                .parse::<SocketAddr>()
                .map_err(|_| ProviderError::Configuration("invalid Iroh direct address".into()))
        })
        .collect()
}

#[derive(Clone)]
pub struct IrohProviderConfig {
    /// Stable Iroh carrier identity. Noise identity remains authoritative.
    pub secret_key: Option<SecretKey>,
    /// Relay infrastructure used for hole punching and fallback forwarding.
    pub relay_mode: RelayMode,
    /// Allowed network paths for this endpoint.
    pub path_mode: IrohPathMode,
    /// Publish and resolve routes through the n0 discovery service.
    pub discovery_n0: bool,
    pub alpn: Vec<u8>,
    pub maximum_frame_bytes: usize,
}

impl fmt::Debug for IrohProviderConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let relay_mode = match &self.relay_mode {
            RelayMode::Disabled => "disabled",
            RelayMode::Default => "default",
            RelayMode::Staging => "staging",
            RelayMode::Custom(_) => "custom",
        };
        formatter
            .debug_struct("IrohProviderConfig")
            .field("secret_key", &self.secret_key.as_ref().map(|_| "[REDACTED]"))
            .field("relay_mode", &relay_mode)
            .field("path_mode", &self.path_mode)
            .field("discovery_n0", &self.discovery_n0)
            .field("alpn", &self.alpn)
            .field("maximum_frame_bytes", &self.maximum_frame_bytes)
            .finish()
    }
}

impl Default for IrohProviderConfig {
    fn default() -> Self {
        Self {
            secret_key: None,
            relay_mode: RelayMode::Default,
            path_mode: IrohPathMode::Auto,
            discovery_n0: false,
            alpn: CMUX_IROH_ALPN.to_vec(),
            maximum_frame_bytes: MAX_WIRE_FRAME_BYTES + SECURE_FRAME_OVERHEAD_BYTES,
        }
    }
}

impl IrohProviderConfig {
    /// Applies a path policy and aligns built-in relay configuration with it.
    pub fn with_path_mode(mut self, path_mode: IrohPathMode) -> Self {
        self.path_mode = path_mode;
        if path_mode == IrohPathMode::DirectOnly {
            self.relay_mode = RelayMode::Disabled;
        }
        self
    }
}

#[derive(Debug, Clone, Copy)]
struct IrohListenerLimits {
    maximum_connections: usize,
    maximum_connection_overflow: usize,
    maximum_pending_streams: usize,
    maximum_pending_stream_overflow: usize,
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
            maximum_connection_overflow: 8,
            maximum_pending_streams: 64,
            maximum_pending_stream_overflow: 8,
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
    connection_overflow: Arc<Semaphore>,
    pending_streams: Arc<Semaphore>,
    pending_stream_overflow: Arc<Semaphore>,
}

impl IrohAdmission {
    fn new(limits: IrohListenerLimits) -> Self {
        Self {
            limits,
            connections: Arc::new(Semaphore::new(limits.maximum_connections)),
            connection_overflow: Arc::new(Semaphore::new(limits.maximum_connection_overflow)),
            pending_streams: Arc::new(Semaphore::new(limits.maximum_pending_streams)),
            pending_stream_overflow: Arc::new(Semaphore::new(
                limits.maximum_pending_stream_overflow,
            )),
        }
    }
}

enum PreAuthAdmission {
    Ready(OwnedSemaphorePermit),
    Queued(OwnedSemaphorePermit),
}

impl PreAuthAdmission {
    async fn acquire(self, capacity: Arc<Semaphore>) -> OwnedSemaphorePermit {
        match self {
            Self::Ready(permit) => permit,
            Self::Queued(overflow) => {
                let permit = capacity
                    .acquire_owned()
                    .await
                    .expect("Iroh pre-auth admission semaphore is never closed");
                drop(overflow);
                permit
            }
        }
    }

    async fn acquire_until_authenticated(
        self,
        capacity: Arc<Semaphore>,
        mut authenticated: watch::Receiver<bool>,
    ) -> Option<OwnedSemaphorePermit> {
        if *authenticated.borrow() {
            return None;
        }
        match self {
            Self::Ready(permit) => Some(permit),
            Self::Queued(overflow) => {
                tokio::select! {
                    biased;
                    _ = authenticated.changed() => {
                        drop(overflow);
                        None
                    }
                    permit = capacity.acquire_owned() => {
                        let permit =
                            permit.expect("Iroh pre-auth admission semaphore is never closed");
                        drop(overflow);
                        Some(permit)
                    }
                }
            }
        }
    }
}

fn try_pre_auth_admission(
    capacity: &Arc<Semaphore>,
    overflow: &Arc<Semaphore>,
) -> Option<PreAuthAdmission> {
    match capacity.clone().try_acquire_owned() {
        Ok(permit) => Some(PreAuthAdmission::Ready(permit)),
        Err(_) => overflow.clone().try_acquire_owned().ok().map(PreAuthAdmission::Queued),
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
    match config.path_mode {
        IrohPathMode::DirectOnly if !matches!(&config.relay_mode, RelayMode::Disabled) => {
            return Err(ProviderError::Configuration(
                "Iroh direct-only path mode requires relays to be disabled".into(),
            ));
        }
        IrohPathMode::RelayOnly if matches!(&config.relay_mode, RelayMode::Disabled) => {
            return Err(ProviderError::Configuration(
                "Iroh relay-only path mode requires an enabled relay configuration".into(),
            ));
        }
        _ => {}
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
    if config.path_mode == IrohPathMode::RelayOnly {
        builder = builder.clear_ip_transports();
    }
    if let Some(secret_key) = config.secret_key.clone() {
        builder = builder.secret_key(secret_key);
    }
    builder
        .bind()
        .await
        .map_err(|_| ProviderError::Transport("could not bind Iroh endpoint".into()))
}

async fn connect_iroh_connection(
    endpoint: &Endpoint,
    node_addr: &NodeAddr,
    alpn: &[u8],
) -> Result<::iroh::endpoint::Connection, ProviderError> {
    let remote_node_id = node_addr.id;
    let connection = endpoint
        .connect(node_addr.clone(), alpn)
        .await
        .map_err(|_| iroh_connect_error(remote_node_id))?;
    let authenticated_node_id = connection.remote_id();
    if authenticated_node_id != remote_node_id {
        connection.close(1_u8.into(), b"unexpected Iroh peer identity");
        return Err(ProviderError::Transport(format!(
            "Iroh authenticated {authenticated_node_id}, expected {remote_node_id}"
        )));
    }
    Ok(connection)
}

fn initial_iroh_dial_addr(path_mode: IrohPathMode, node_addr: &NodeAddr) -> NodeAddr {
    if path_mode != IrohPathMode::Auto
        || node_addr.relay_urls().next().is_none()
        || node_addr.ip_addrs().next().is_none()
    {
        return node_addr.clone();
    }

    let mut relay_bootstrap = node_addr.clone();
    relay_bootstrap.addrs.retain(|addr| matches!(addr, ::iroh::TransportAddr::Relay(_)));
    relay_bootstrap
}

async fn connect_iroh_for_path_mode(
    endpoint: &Endpoint,
    node_addr: &NodeAddr,
    alpn: &[u8],
    path_mode: IrohPathMode,
) -> Result<::iroh::endpoint::Connection, ProviderError> {
    let dial_addr = initial_iroh_dial_addr(path_mode, node_addr);
    let relay_assisted = dial_addr.ip_addrs().next().is_none()
        && node_addr.ip_addrs().next().is_some()
        && dial_addr.relay_urls().next().is_some();
    if !relay_assisted {
        return connect_iroh_connection(endpoint, &dial_addr, alpn).await;
    }

    // A relay-first handshake avoids letting an explicitly advertised but
    // blackholed IP path starve Iroh's relay. Once connected, Iroh discovers
    // and promotes a working direct path on the same QUIC connection. A LAN
    // without relay access still falls back to the complete address set.
    match tokio::time::timeout(
        AUTO_RELAY_BOOTSTRAP_TIMEOUT,
        connect_iroh_connection(endpoint, &dial_addr, alpn),
    )
    .await
    {
        Ok(Ok(connection)) => Ok(connection),
        Ok(Err(_)) | Err(_) => connect_iroh_connection(endpoint, node_addr, alpn).await,
    }
}

fn iroh_connect_error(remote_node_id: NodeId) -> ProviderError {
    ProviderError::Link(LinkError::Transport(format!(
        "could not connect to Iroh node {remote_node_id}"
    )))
}

#[async_trait]
impl TransportProvider for IrohProvider {
    fn name(&self) -> &'static str {
        "iroh"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["iroh"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOnly
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        if !self.schemes().contains(&request.endpoint.scheme()) {
            return Err(ProviderError::UnsupportedScheme(request.endpoint.scheme().into()));
        }
        let route = IrohRoute::from_request(&request)?;
        match self.config.path_mode {
            IrohPathMode::DirectOnly if route.node_addr().ip_addrs().next().is_none() => {
                return Err(ProviderError::Configuration(
                    "Iroh direct-only path mode requires at least one direct address".into(),
                ));
            }
            IrohPathMode::RelayOnly if route.node_addr().relay_urls().next().is_none() => {
                return Err(ProviderError::Configuration(
                    "Iroh relay-only path mode requires a relay URL".into(),
                ));
            }
            _ => {}
        }
        let remote_node_id = route.node_id();
        let node_addr = route.into_node_addr();
        let endpoint = self.endpoint().await?.clone();
        let connection = connect_iroh_for_path_mode(
            &endpoint,
            &node_addr,
            &self.config.alpn,
            self.config.path_mode,
        )
        .await?;
        let description = format!("iroh://{remote_node_id}");
        let transport = iroh_transport_snapshot(&description, &connection);

        Ok(Arc::new(IrohLinkGroup {
            connection: Mutex::new(connection),
            transport: StdMutex::new(transport),
            endpoint,
            node_addr,
            alpn: self.config.alpn.clone(),
            path_mode: self.config.path_mode,
            description,
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
                let Some(connection_admission) = try_pre_auth_admission(
                    &admission.connections,
                    &admission.connection_overflow,
                ) else {
                    incoming.refuse();
                    continue;
                };
                let daemon = daemon.clone();
                let alpn = alpn.clone();
                let admission = admission.clone();
                connections.spawn(async move {
                    let Ok(Ok(connection)) = tokio::time::timeout(
                        admission.limits.connection_handshake_timeout,
                        async move { incoming.await },
                    ).await else {
                        return;
                    };
                    let first_stream_deadline =
                        tokio::time::Instant::now() + admission.limits.first_stream_timeout;
                    let Ok(connection_permit) = tokio::time::timeout_at(
                        first_stream_deadline,
                        connection_admission.acquire(admission.connections.clone()),
                    ).await else {
                        connection.close(9_u8.into(), b"cmux connection admission timed out");
                        return;
                    };
                    serve_iroh_connection(
                        connection,
                        daemon,
                        alpn,
                        maximum_frame_bytes,
                        admission,
                        connection_permit,
                        first_stream_deadline,
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
    connection_permit: OwnedSemaphorePermit,
    first_stream_deadline: tokio::time::Instant,
) {
    if connection.alpn() != alpn.as_slice() {
        connection.close(2_u8.into(), b"unexpected cmux ALPN");
        return;
    }
    let remote_node_id = connection.remote_id();

    let mut next_stream_id = 0_u64;
    let mut links = JoinSet::new();
    let (accept_results_tx, mut accept_results_rx) =
        mpsc::channel(admission.limits.maximum_pending_streams_per_connection);
    let (authenticated_tx, authenticated_rx) = watch::channel(false);
    let per_connection =
        Arc::new(Semaphore::new(admission.limits.maximum_pending_streams_per_connection));
    let first_stream_deadline = tokio::time::sleep_until(first_stream_deadline);
    let unauthenticated_deadline = tokio::time::sleep(admission.limits.unauthenticated_timeout);
    tokio::pin!(first_stream_deadline);
    tokio::pin!(unauthenticated_deadline);
    let mut authenticated = false;
    let _connection_permit = connection_permit;
    loop {
        tokio::select! {
            biased;
            completed = links.join_next(), if !links.is_empty() => {
                let _ = completed;
            }
            result = accept_results_rx.recv() => {
                match result {
                    Some(IrohAcceptResult::Succeeded) => {
                        if !authenticated {
                            authenticated = true;
                            authenticated_tx.send_replace(true);
                        }
                    }
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
                let stream_admission = if authenticated {
                    None
                } else {
                    let Some(stream_admission) = try_pre_auth_admission(
                        &admission.pending_streams,
                        &admission.pending_stream_overflow,
                    ) else {
                        let _ = sender.reset(6_u8.into());
                        let _ = receiver.stop(6_u8.into());
                        connection.close(6_u8.into(), b"cmux pre-auth capacity exhausted");
                        break;
                    };
                    Some(stream_admission)
                };
                let stream_id = next_stream_id;
                next_stream_id = next_stream_id.saturating_add(1);
                let daemon = daemon.clone();
                let description = format!("iroh-daemon://{remote_node_id}/{stream_id}");
                let pre_auth_timeout = admission.limits.pre_auth_timeout;
                let accept_results = accept_results_tx.clone();
                let pending_streams = admission.pending_streams.clone();
                let authenticated = authenticated_rx.clone();
                links.spawn(async move {
                    let global_permit = match stream_admission {
                        Some(stream_admission) => {
                            stream_admission
                                .acquire_until_authenticated(pending_streams, authenticated)
                                .await
                        }
                        None => None,
                    };
                    let permits = (per_connection_permit, global_permit);
                    let link = LengthDelimitedLink::new(
                        description,
                        maximum_frame_bytes,
                        receiver,
                        sender,
                    );
                    let inbound = InboundLink::network(Box::new(link), NetworkPeer::Iroh);
                    let result = tokio::time::timeout(
                        pre_auth_timeout,
                        daemon.accept(inbound),
                    ).await;
                    let result = match result {
                        Ok(Ok(())) => IrohAcceptResult::Succeeded,
                        Ok(Err(_)) | Err(_) => IrohAcceptResult::Failed,
                    };
                    // Bound completed accept results so a connection cannot retain an
                    // unbounded number of task results. A closed receiver means teardown.
                    let _ = accept_results.send(result).await;
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
    transport: StdMutex<TransportSnapshot>,
    endpoint: Endpoint,
    node_addr: NodeAddr,
    alpn: Vec<u8>,
    path_mode: IrohPathMode,
    description: String,
    evidence: CarrierEvidence,
    maximum_frame_bytes: usize,
    closed: AtomicBool,
}

fn iroh_transport_snapshot(
    description: &str,
    connection: &::iroh::endpoint::Connection,
) -> TransportSnapshot {
    let paths = connection.paths();
    let selected_path =
        paths.iter().find(|path| path.is_selected()).map(|path| TransportPathSnapshot {
            kind: if path.is_relay() {
                TransportPathKind::Relay
            } else if path.is_ip() {
                TransportPathKind::Direct
            } else {
                TransportPathKind::Unknown
            },
            remote: Some(sanitized_iroh_remote(path.remote_addr())),
            rtt_micros: Some(path.rtt().as_micros().min(u64::MAX as u128) as u64),
        });
    TransportSnapshot { provider: "iroh".into(), route: description.into(), selected_path }
}

fn sanitized_iroh_remote(remote: &::iroh::TransportAddr) -> String {
    match remote {
        ::iroh::TransportAddr::Relay(url) => format!("relay:{}", sanitized_route(url)),
        ::iroh::TransportAddr::Ip(address) => format!("ip:{address}"),
        ::iroh::TransportAddr::Custom(_) => "custom".into(),
        _ => "unknown".into(),
    }
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

    async fn transport_snapshot(&self) -> TransportSnapshot {
        if let Ok(connection) = self.connection.try_lock() {
            let snapshot = iroh_transport_snapshot(&self.description, &connection);
            *self.transport.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                snapshot.clone();
            snapshot
        } else {
            self.transport.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
        }
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
                    let replacement = connect_iroh_for_path_mode(
                        &self.endpoint,
                        &self.node_addr,
                        &self.alpn,
                        self.path_mode,
                    )
                    .await
                    .map_err(|reconnect_error| {
                        ProviderError::Transport(format!(
                            "Iroh stream open failed ({open_error}); reconnect failed: {reconnect_error}"
                        ))
                    })?;
                    *connection = replacement;
                    *self.transport.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                        iroh_transport_snapshot(&self.description, &connection);
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
