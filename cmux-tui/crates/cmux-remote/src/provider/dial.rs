//! How a direct route's bytes reach the wire.
//!
//! A route names the daemon (`ws://[fd7a::10]:1337/v1/link`); it says nothing
//! about how this client reaches that address. Usually the operating system
//! does, over its own TCP stack and whatever interfaces it has. A cmux Cloud
//! machine sits on a private network with no public port, so a client without
//! a system WireGuard interface needs another carrier: an in-process tunnel
//! (`cmux-wg`) whose TCP stack lives in this process.
//!
//! The [`Dialer`] is that seam. It produces a byte stream for a host and port;
//! TLS, the WebSocket upgrade, and the cmux Noise handshake run above it
//! unchanged. The route the control plane hands out is the same either way.

use std::fmt;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use async_trait::async_trait;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;

use crate::link::LinkError;

/// A connected, ordered byte stream to the dialed host.
pub type DialedStream = Box<dyn AsyncRead + AsyncWrite + Send + Sync + Unpin>;

/// Produces a byte stream to `host:port`. Implementations own the carrier only.
#[async_trait]
pub trait Dialer: Send + Sync + fmt::Debug {
    fn name(&self) -> &'static str;
    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError>;
}

/// Resolve a URL host (an IP literal, a bracketed IPv6 literal, or a name) to
/// socket addresses without touching the network for literals.
pub async fn resolve_dial_target(host: &str, port: u16) -> Result<Vec<SocketAddr>, LinkError> {
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    if let Ok(address) = bare.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(address, port)]);
    }
    let addresses = tokio::net::lookup_host((bare, port))
        .await
        .map_err(|error| LinkError::Transport(format!("resolve {bare}: {error}")))?
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        return Err(LinkError::Transport(format!("{bare} resolved to no addresses")));
    }
    Ok(addresses)
}

/// The operating system's TCP stack. Tries every resolved address in order,
/// with Nagle disabled because the link carries keystrokes.
#[derive(Debug, Clone, Copy, Default)]
pub struct OsTcpDialer;

#[async_trait]
impl Dialer for OsTcpDialer {
    fn name(&self) -> &'static str {
        "tcp"
    }

    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError> {
        let addresses = resolve_dial_target(host, port).await?;
        let mut last_error = None;
        for address in addresses {
            match TcpStream::connect(address).await {
                Ok(stream) => {
                    let _ = stream.set_nodelay(true);
                    return Ok(Box::new(stream));
                }
                Err(error) => last_error = Some(error),
            }
        }
        Err(LinkError::Transport(match last_error {
            Some(error) => format!("connect {host}:{port}: {error}"),
            None => format!("connect {host}:{port}: no addresses"),
        }))
    }
}

/// An in-process WireGuard tunnel for addresses inside its routes; everything
/// else goes to the fallback dialer.
#[cfg(feature = "wireguard-transport")]
pub struct WireGuardDialer {
    net: Arc<cmux_wg::WgNet>,
    fallback: Arc<dyn Dialer>,
}

#[cfg(feature = "wireguard-transport")]
impl WireGuardDialer {
    /// Tunnel addresses go through `net`; others use the operating system.
    pub fn new(net: Arc<cmux_wg::WgNet>) -> Self {
        Self::with_fallback(net, Arc::new(OsTcpDialer))
    }

    pub fn with_fallback(net: Arc<cmux_wg::WgNet>, fallback: Arc<dyn Dialer>) -> Self {
        Self { net, fallback }
    }

    pub fn net(&self) -> &Arc<cmux_wg::WgNet> {
        &self.net
    }
}

#[cfg(feature = "wireguard-transport")]
impl fmt::Debug for WireGuardDialer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WireGuardDialer")
            .field("routes", &self.net.routes())
            .field("fallback", &self.fallback)
            .finish()
    }
}

#[cfg(feature = "wireguard-transport")]
#[async_trait]
impl Dialer for WireGuardDialer {
    fn name(&self) -> &'static str {
        "wireguard"
    }

    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError> {
        let addresses = resolve_dial_target(host, port).await?;
        if let Some(address) =
            addresses.iter().copied().find(|address| self.net.routes_contain(address.ip()))
        {
            let stream = self.net.connect(address).await.map_err(|error| {
                LinkError::Transport(format!("wireguard connect {address}: {error}"))
            })?;
            return Ok(Box::new(stream));
        }
        self.fallback.dial(host, port).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn literals_resolve_without_dns() {
        assert_eq!(
            resolve_dial_target("[fd7a::10]", 1337).await.unwrap(),
            vec!["[fd7a::10]:1337".parse::<SocketAddr>().unwrap()]
        );
        assert_eq!(
            resolve_dial_target("10.100.0.10", 1337).await.unwrap(),
            vec!["10.100.0.10:1337".parse::<SocketAddr>().unwrap()]
        );
    }
}
