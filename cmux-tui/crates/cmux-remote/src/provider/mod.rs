//! Carrier-neutral connection establishment.
//!
//! Providers only produce ordered, bounded binary links. Device identity,
//! encryption, authorization, replay, and application services remain above
//! this boundary, so a relay or a TLS terminator is never an authority.

#[cfg(feature = "iroh-transport")]
mod iroh;
mod relay;
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

use crate::link::{FrameLink, LinkError};

#[cfg(feature = "iroh-transport")]
pub use iroh::{
    CMUX_IROH_ALPN, IrohListener, IrohProvider, IrohProviderConfig, IrohRoute,
    ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL, load_or_create_iroh_secret,
};
pub use relay::{
    RelayClientConfig, RelayCredentialSource, RelayDaemonConfig, RelayDaemonRegistration,
    RelayProvider, register_relay_daemon, register_relay_daemon_with_credentials,
};
pub use ssh::{SshProvider, SshProviderConfig};
pub use stream::LengthDelimitedLink;
#[cfg(unix)]
pub use unix::UnixProvider;
pub use websocket::{
    AxumWebSocketLink, DirectWebSocketProvider, TungsteniteWebSocketLink, connect_websocket,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectRequest {
    pub endpoint: Url,
    pub session: SessionId,
    pub lane_policy: LanePolicy,
    /// Provider-specific, non-secret routing hints. Authentication material
    /// belongs to the Noise handshake, never this map.
    pub routing: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkRequest {
    pub lane: Lane,
    pub generation: u64,
}

/// One logical connection to a daemon. A group can open one carrier link for
/// every lane, or map all lanes to the same carrier when policy/capability
/// requires it.
#[async_trait]
pub trait LinkGroup: Send + Sync {
    fn description(&self) -> &str;
    fn capabilities(&self) -> ProviderCapabilities;
    fn evidence(&self) -> &CarrierEvidence;
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError>;
    async fn close(&self) -> Result<(), ProviderError>;
}

#[async_trait]
pub trait TransportProvider: Send + Sync {
    fn name(&self) -> &'static str;
    fn schemes(&self) -> &'static [&'static str];
    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError>;
}

#[derive(Default)]
pub struct ProviderRegistry {
    providers: Vec<Arc<dyn TransportProvider>>,
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

    pub async fn connect(
        &self,
        request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let scheme = request.endpoint.scheme();
        let Some(provider) = self.providers.iter().find(|item| item.schemes().contains(&scheme))
        else {
            return Err(ProviderError::UnsupportedScheme(scheme.into()));
        };
        provider.connect(request).await
    }
}

/// Resolve logical lanes onto physical links. `Auto` protects keystrokes from
/// bulk traffic while avoiding four handshakes on carriers that cannot benefit.
pub fn lane_bindings(policy: LanePolicy, capabilities: ProviderCapabilities) -> Vec<Vec<Lane>> {
    if policy == LanePolicy::Single || !capabilities.parallel_links {
        return vec![Lane::ALL.to_vec()];
    }
    if policy == LanePolicy::Isolated {
        return Lane::ALL.into_iter().map(|lane| vec![lane]).collect();
    }
    vec![vec![Lane::Interactive], vec![Lane::Control], vec![Lane::Tunnel, Lane::Bulk]]
}

#[derive(Debug)]
pub enum ProviderError {
    UnsupportedScheme(String),
    Configuration(String),
    Link(LinkError),
    Transport(String),
}

impl fmt::Display for ProviderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedScheme(scheme) => {
                write!(formatter, "no transport provider handles scheme {scheme:?}")
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_separates_keystrokes_and_bulk() {
        let groups = lane_bindings(LanePolicy::Auto, ProviderCapabilities::WEBSOCKET);
        assert_eq!(groups[0], [Lane::Interactive]);
        assert_eq!(groups[1], [Lane::Control]);
        assert!(
            !groups
                .iter()
                .any(|group| { group.contains(&Lane::Interactive) && group.contains(&Lane::Bulk) })
        );
        assert!(
            !groups
                .iter()
                .any(|group| { group.contains(&Lane::Control) && group.contains(&Lane::Tunnel) })
        );
    }

    #[test]
    fn stream_provider_collapses_isolated_policy() {
        assert_eq!(
            lane_bindings(LanePolicy::Isolated, ProviderCapabilities::STREAM),
            vec![Lane::ALL.to_vec()]
        );
    }
}
