//! Carrier-neutral connection establishment.
//!
//! Providers only produce ordered, bounded binary links. Device identity,
//! encryption, authorization, replay, and application services remain above
//! this boundary, so a relay or a TLS terminator is never an authority.

mod dial;
#[cfg(feature = "iroh-transport")]
mod iroh;
mod iroh_config;
#[cfg(unix)]
pub mod overlay;
mod relay;
pub(crate) mod socks;
mod ssh;
mod stream;
#[cfg(unix)]
mod unix;
mod websocket;

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use url::Url;

use crate::crypto::AuthKind;
use crate::link::{FrameLink, LinkError};
use crate::observability::TransportSnapshot;

#[cfg(feature = "wireguard-transport")]
pub use dial::WireGuardDialer;
pub use dial::{DialedIo, DialedStream, Dialer, OsTcpDialer, SocksDialer, resolve_dial_target};
#[cfg(feature = "iroh-transport")]
pub use iroh::{
    IrohListener, IrohProvider, IrohProviderConfig, IrohRoute, load_or_create_iroh_secret,
};
pub use iroh_config::{
    CMUX_IROH_ALPN, IrohPathMode, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL,
};
pub use relay::{
    RelayClientConfig, RelayCredentialSource, RelayDaemonConfig, RelayDaemonRegistration,
    RelayProvider, register_relay_daemon, register_relay_daemon_with_credentials,
};
pub use ssh::{
    REMOTE_LINK_MUX_SOCKET_CAPABILITY, REMOTE_LINK_STRICT_FLAGS_CAPABILITY, SshProvider,
    SshProviderConfig,
};
pub use stream::LengthDelimitedLink;
#[cfg(unix)]
pub use unix::UnixProvider;
pub use websocket::{
    AxumWebSocketLink, DirectWebSocketProvider, TungsteniteWebSocketLink, connect_websocket,
    connect_websocket_via,
};

/// Non-authoritative facts learned from the carrier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CarrierEvidence {
    None,
    LocalPeer { uid: Option<u32>, pid: Option<u32> },
    Ssh { destination: String },
    Tls { server_name: String },
    Relay { provider: String },
    Iroh { endpoint_id: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderCapabilities {
    /// The provider can establish independent links without head-of-line
    /// blocking between them.
    pub parallel_links: bool,
    /// The provider can reconnect a lane without replacing every other lane.
    pub independent_reconnect: bool,
    /// The carrier may migrate between network paths while a link is alive.
    pub path_migration: bool,
    /// The carrier itself supplies confidentiality. Noise still runs above it.
    pub carrier_encryption: bool,
}

impl ProviderCapabilities {
    pub const STREAM: Self = Self {
        parallel_links: false,
        independent_reconnect: false,
        path_migration: false,
        carrier_encryption: false,
    };

    pub const WEBSOCKET: Self = Self {
        parallel_links: true,
        independent_reconnect: true,
        path_migration: false,
        carrier_encryption: false,
    };

    pub const MULTI_STREAM: Self = Self {
        parallel_links: true,
        independent_reconnect: true,
        path_migration: false,
        carrier_encryption: true,
    };
}

#[derive(Clone, PartialEq, Eq)]
pub struct ConnectRequest {
    pub endpoint: Url,
    pub session: SessionId,
    pub lane_policy: LanePolicy,
    /// Provider-specific, non-secret routing hints. Authentication material
    /// belongs to the Noise handshake, never this map.
    pub routing: BTreeMap<String, String>,
}

impl fmt::Debug for ConnectRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let routing_keys = self.routing.keys().map(String::as_str).collect::<Vec<_>>();
        formatter
            .debug_struct("ConnectRequest")
            .field("endpoint", &sanitized_route(&self.endpoint))
            .field("session", &self.session)
            .field("lane_policy", &self.lane_policy)
            .field("routing_keys", &routing_keys)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkRequest {
    pub lane: Lane,
    pub generation: u64,
}

/// Client authentication modes a locally configured transport provider accepts.
///
/// Device authentication includes enrolled devices and invitation enrollment.
/// Carrier authentication is restricted to transports whose local endpoint
/// verifies the peer independently, currently Unix sockets and SSH.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SupportedClientAuthModes {
    DeviceOnly,
    DeviceOrCarrier,
}

impl SupportedClientAuthModes {
    pub fn supports(self, auth: AuthKind) -> bool {
        // Keep both enums exhaustive so new modes require an explicit trust-boundary decision.
        match (self, auth) {
            (Self::DeviceOnly, AuthKind::Enrolled | AuthKind::Invitation) => true,
            (Self::DeviceOnly, AuthKind::Carrier) => false,
            (
                Self::DeviceOrCarrier,
                AuthKind::Enrolled | AuthKind::Invitation | AuthKind::Carrier,
            ) => true,
        }
    }
}

/// One logical connection to a daemon. A group can open one carrier link for
/// every lane, or map all lanes to the same carrier when policy/capability
/// requires it.
#[async_trait]
pub trait LinkGroup: Send + Sync {
    fn description(&self) -> &str;
    fn capabilities(&self) -> ProviderCapabilities;
    fn evidence(&self) -> &CarrierEvidence;
    async fn transport_snapshot(&self) -> TransportSnapshot {
        TransportSnapshot::unknown()
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError>;
    async fn close(&self) -> Result<(), ProviderError>;
}

/// Returns an endpoint label safe for diagnostics and user-facing status.
///
/// The original URL remains available to the provider for dialing, while the
/// label omits userinfo and capability-bearing URL components.
pub fn sanitized_route(endpoint: &Url) -> String {
    let mut route = endpoint.clone();
    let _ = route.set_username("");
    let _ = route.set_password(None);
    // Network route paths can themselves be bearer capabilities. Diagnostics
    // need only the selected scheme and authority, never an application path.
    route.set_path("");
    route.set_query(None);
    route.set_fragment(None);
    route.to_string()
}

/// Returns a safe diagnostic label for a serialized route.
///
/// Invalid route strings are intentionally not echoed because parse failures
/// can otherwise expose an entire credential-bearing input.
pub fn sanitized_route_text(route: &str) -> String {
    Url::parse(route)
        .map(|endpoint| sanitized_route(&endpoint))
        .unwrap_or_else(|_| "<invalid route>".into())
}

#[async_trait]
pub trait TransportProvider: Send + Sync {
    fn name(&self) -> &'static str;
    fn schemes(&self) -> &'static [&'static str];
    fn supported_client_auth(&self) -> SupportedClientAuthModes;
    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError>;
}

#[derive(Clone, Default)]
pub struct ProviderRegistry {
    providers: Vec<Arc<dyn TransportProvider>>,
}

impl fmt::Debug for ProviderRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let providers = self
            .providers
            .iter()
            .map(|provider| (provider.name(), provider.schemes(), provider.supported_client_auth()))
            .collect::<Vec<_>>();
        formatter.debug_struct("ProviderRegistry").field("providers", &providers).finish()
    }
}

impl ProviderRegistry {
    pub fn register(&mut self, provider: Arc<dyn TransportProvider>) -> Result<(), ProviderError> {
        for scheme in provider.schemes() {
            if self.providers.iter().any(|current| current.schemes().contains(scheme)) {
                return Err(ProviderError::Configuration(format!(
                    "transport scheme {scheme:?} is already registered"
                )));
            }
        }
        self.providers.push(provider);
        Ok(())
    }

    pub fn supported_client_auth(
        &self,
        scheme: &str,
    ) -> Result<SupportedClientAuthModes, ProviderError> {
        Ok(self.provider(scheme)?.supported_client_auth())
    }

    pub async fn connect(
        &self,
        request: ConnectRequest,
        auth: AuthKind,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let scheme = request.endpoint.scheme().to_owned();
        let provider = self.provider(&scheme)?;
        if !provider.supported_client_auth().supports(auth) {
            return Err(ProviderError::UnsupportedClientAuth { scheme, auth });
        }
        provider.connect(request).await
    }

    fn provider(&self, scheme: &str) -> Result<&Arc<dyn TransportProvider>, ProviderError> {
        self.providers
            .iter()
            .find(|provider| provider.schemes().contains(&scheme))
            .ok_or_else(|| ProviderError::UnsupportedScheme(scheme.into()))
    }
}

/// Resolve logical lanes onto physical links. `Auto` protects keystrokes from
/// bulk traffic while avoiding four handshakes on carriers that cannot benefit.
pub fn lane_bindings(policy: LanePolicy, capabilities: ProviderCapabilities) -> Vec<Vec<Lane>> {
    if policy == LanePolicy::Single || !capabilities.parallel_links {
        return vec![Lane::ALL.to_vec()];
    }
    if policy == LanePolicy::Isolated {
        let mut lanes = Lane::ALL;
        lanes.sort_by_key(|lane| lane.priority());
        return lanes.into_iter().map(|lane| vec![lane]).collect();
    }
    vec![vec![Lane::Interactive], vec![Lane::Control], vec![Lane::Tunnel, Lane::Bulk]]
}

#[derive(Debug)]
pub enum ProviderError {
    UnsupportedScheme(String),
    UnsupportedClientAuth { scheme: String, auth: AuthKind },
    Configuration(String),
    Link(LinkError),
    Transport(String),
}

impl ProviderError {
    /// Distinguishes a live route whose daemon port is not listening from a
    /// provider shutdown. Callers can use the supported daemon recovery path
    /// without treating a refused port as VM destruction.
    pub fn is_connection_refused(&self) -> bool {
        matches!(self, Self::Link(LinkError::Transport(message)) if message.to_ascii_lowercase().contains("connection refused"))
    }

    /// Whether a provider failed because its current carrier path disappeared
    /// or could not be established. Configuration, authentication, and
    /// protocol failures remain terminal.
    pub fn is_retryable_carrier_failure(&self) -> bool {
        matches!(self, Self::Link(LinkError::Closed | LinkError::Transport(_)))
    }
}

impl fmt::Display for ProviderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedScheme(scheme) => {
                write!(formatter, "no transport provider handles scheme {scheme:?}")
            }
            Self::UnsupportedClientAuth { scheme, auth } => {
                let auth = match auth {
                    AuthKind::Enrolled => "enrolled-device",
                    AuthKind::Invitation => "invitation",
                    AuthKind::Carrier => "carrier",
                };
                write!(
                    formatter,
                    "transport scheme {scheme:?} does not support {auth} client authentication"
                )
            }
            Self::Configuration(message) => {
                write!(formatter, "invalid transport configuration: {message}")
            }
            Self::Link(error) => error.fmt(formatter),
            Self::Transport(message) => write!(formatter, "transport provider failed: {message}"),
        }
    }
}

impl std::error::Error for ProviderError {}

impl From<LinkError> for ProviderError {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}
