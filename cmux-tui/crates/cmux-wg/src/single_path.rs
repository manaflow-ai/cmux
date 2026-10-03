//! A tunnel on one UDP path, run as a [`Multipath`] with one path, so the
//! one-path case reports path events from the same selector code as the
//! multipath case (transport.md 12a) and needs no second event source.

use cmux_transport::{PathKind, SelectorConfig};
use tokio::net::UdpSocket;

use crate::multipath::{Multipath, MultipathControl};
use crate::probe_schedule::ProbeConfig;
use crate::underlay::{SocketPath, UdpUnderlay};
use crate::{WgConfig, WgError, WgNet};

/// A fresh UDP socket aimed at the configured endpoint, in its family.
pub(crate) async fn new_socket_path(config: &WgConfig) -> Result<UdpUnderlay, WgError> {
    let endpoint = config
        .endpoint
        .as_ref()
        .ok_or_else(|| WgError::EndpointUnresolved("<none configured>".into()))?;
    let candidates =
        endpoint.resolve().await.map_err(|_| WgError::EndpointUnresolved(endpoint.host.clone()))?;
    let peer = *candidates
        .first()
        .ok_or_else(|| WgError::EndpointUnresolved(endpoint.host.clone()))?;
    let bind = if peer.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let socket = UdpSocket::bind(bind).await?;
    Ok(SocketPath::new(socket, Some(peer)))
}

impl WgNet {
    /// Start the tunnel on a fresh UDP socket aimed at the configured
    /// endpoint, as [`WgNet::start_with_new_socket`] does, but under a
    /// one-path [`Multipath`] of `kind`. The returned control reports path
    /// events.
    ///
    /// Probes run only when `probes` is set: they need a peer that answers
    /// them (a cmux endpoint, named by `PeerAddress =`). Without probes the
    /// path is never measured and events report no current path, only
    /// `max_datagram`. When the socket fails for good, the session ends, as
    /// with a plain socket.
    pub async fn start_single_path(
        config: WgConfig,
        kind: PathKind,
        probes: Option<ProbeConfig>,
    ) -> Result<(Self, MultipathControl), WgError> {
        let path = new_socket_path(&config).await?;
        Self::start_on_one_path(config, kind, probes, path)
    }

    /// [`WgNet::start_single_path`] on a caller-built path (tests, or a
    /// socket the caller bound).
    pub fn start_on_one_path(
        config: WgConfig,
        kind: PathKind,
        probes: Option<ProbeConfig>,
        path: impl crate::Underlay,
    ) -> Result<(Self, MultipathControl), WgError> {
        let selector = SelectorConfig::default();
        let (underlay, control) = match probes {
            Some(probes) => Multipath::with_probes(selector, probes),
            None => Multipath::new(selector),
        };
        control.add_path(kind, path);
        let net = Self::start_with_underlay(config, underlay)?;
        Ok((net, control))
    }
}
