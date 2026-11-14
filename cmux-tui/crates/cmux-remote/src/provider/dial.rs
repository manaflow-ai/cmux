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
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};
use zeroize::Zeroizing;

use crate::link::LinkError;
use crate::provider::socks;

/// The bounds a dialed carrier must satisfy. Blanket-implemented, so any
/// Tokio stream qualifies; the trait exists only because a trait object can
/// name one non-auto trait.
pub trait DialedIo: AsyncRead + AsyncWrite + Send + Sync + Unpin {}

impl<T: AsyncRead + AsyncWrite + Send + Sync + Unpin + ?Sized> DialedIo for T {}

/// A connected, ordered byte stream to the dialed host.
pub type DialedStream = Box<dyn DialedIo>;

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

/// How long one resolved address may take to accept a TCP connect before the
/// next address is tried. A name that resolves to an address that black-holes
/// SYNs (an IPv6 address on a network with no IPv6 route, a stale record)
/// otherwise held the dial for the kernel's whole SYN retry window (over two
/// minutes on Linux) before the next address was tried. The last address has
/// no bound of its own here. The whole dial stays
/// under the caller's own deadline ([`crate::provider::DIRECT_DIAL_TIMEOUT`]
/// for a direct WebSocket).
pub const PER_ADDRESS_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Await one address's connect: within [`PER_ADDRESS_CONNECT_TIMEOUT`] when
/// another address follows it, or unbounded here for the last one, which has
/// the rest of the caller's deadline (a cold tunnel's first WireGuard
/// handshake retries at 5 s, so the only address must not be cut at 5 s).
/// `Err(())` means the bound passed.
async fn bounded_unless_last<T>(last: bool, connect: impl Future<Output = T>) -> Result<T, ()> {
    if last {
        Ok(connect.await)
    } else {
        tokio::time::timeout(PER_ADDRESS_CONNECT_TIMEOUT, connect).await.map_err(|_| ())
    }
}

/// The operating system's TCP stack. Tries every resolved address in order,
/// each but the last within [`PER_ADDRESS_CONNECT_TIMEOUT`], with Nagle
/// disabled because the link carries keystrokes.
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
        let last = addresses.len().saturating_sub(1);
        for (index, address) in addresses.into_iter().enumerate() {
            match bounded_unless_last(index == last, TcpStream::connect(address)).await {
                Ok(Ok(stream)) => {
                    let _ = stream.set_nodelay(true);
                    return Ok(Box::new(stream));
                }
                Ok(Err(error)) => last_error = Some(error.to_string()),
                Err(_) => {
                    last_error = Some(format!(
                        "{address} did not accept within {} s",
                        PER_ADDRESS_CONNECT_TIMEOUT.as_secs()
                    ));
                }
            }
        }
        Err(LinkError::Transport(match last_error {
            Some(error) => format!("connect {host}:{port}: {error}"),
            None => format!("connect {host}:{port}: no addresses"),
        }))
    }
}

/// The secret a hub's clients present. The hub's starter (the cmux app) makes
/// one per launch and hands it to the hub (`wg hub --client-token-stdin`) and to
/// each sidecar (`remote connect --wireguard-hub-token-stdin`) on stdin.
#[derive(Clone)]
pub struct HubClientToken(Zeroizing<String>);

impl HubClientToken {
    /// 32 random bytes, hex encoded.
    pub fn generate() -> io::Result<Self> {
        let mut bytes = Zeroizing::new([0u8; 32]);
        getrandom::fill(bytes.as_mut()).map_err(|error| io::Error::other(error.to_string()))?;
        let mut text = Zeroizing::new(String::with_capacity(64));
        for byte in bytes.iter() {
            use std::fmt::Write as _;
            let _ = write!(text, "{byte:02x}");
        }
        Ok(Self(text))
    }

    /// A token received from the hub's starter. Empty or longer than SOCKS5's
    /// 255-byte password field is refused.
    pub fn new(text: impl Into<String>) -> Option<Self> {
        let text = Zeroizing::new(text.into());
        (!text.is_empty() && text.len() <= 255).then_some(Self(text))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl fmt::Debug for HubClientToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("HubClientToken(..)")
    }
}

/// SOCKS5 CONNECT through a hub process on a Unix socket
/// (`cmux-tui wg hub`). Used by sidecars that share one WireGuard tunnel: the
/// hub owns the key, the sidecar owns nothing but this path. Names are
/// resolved here and sent as literal addresses, because the hub dials
/// literals only.
pub struct SocksDialer {
    path: PathBuf,
    token: Option<HubClientToken>,
}

impl SocksDialer {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into(), token: None }
    }

    /// Present `token` to a hub started with one (`wg hub --client-token-stdin`; the hub's
    /// starter, the cmux app, makes the token and hands it to each sidecar on stdin).
    pub fn with_token(mut self, token: HubClientToken) -> Self {
        self.token = Some(token);
        self
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl fmt::Debug for SocksDialer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("SocksDialer").field("path", &self.path).finish()
    }
}

#[async_trait]
impl Dialer for SocksDialer {
    fn name(&self) -> &'static str {
        "socks-hub"
    }

    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError> {
        let addresses = resolve_dial_target(host, port).await?;
        let mut last_error = None;
        let last = addresses.len().saturating_sub(1);
        for (index, address) in addresses.into_iter().enumerate() {
            let mut stream = UnixStream::connect(&self.path).await.map_err(|error| {
                LinkError::Transport(format!(
                    "wireguard hub {} is not reachable: {error}",
                    self.path.display()
                ))
            })?;
            let token = self.token.as_ref().map(HubClientToken::as_bytes);
            // The hub dials `address` inside its tunnel before it answers the CONNECT, so the
            // answer is bounded like a direct TCP connect to that address.
            match bounded_unless_last(
                index == last,
                socks::client_connect(&mut stream, address, token),
            )
            .await
            {
                Ok(Ok(())) => return Ok(Box::new(stream)),
                Ok(Err(error)) => last_error = Some(error.to_string()),
                Err(_) => {
                    last_error = Some(format!(
                        "CONNECT to {address} was not answered within {} s",
                        PER_ADDRESS_CONNECT_TIMEOUT.as_secs()
                    ));
                }
            }
        }
        Err(LinkError::Transport(match last_error {
            Some(error) => format!("wireguard hub {}: {error}", self.path.display()),
            None => format!("wireguard hub {}: no addresses for {host}", self.path.display()),
        }))
    }
}

/// An in-process WireGuard tunnel that rejects addresses outside its routes.
#[cfg(feature = "wireguard-transport")]
pub struct WireGuardDialer {
    net: Arc<cmux_wg::WgNet>,
}

#[cfg(feature = "wireguard-transport")]
impl WireGuardDialer {
    /// Every address must be inside `net`'s configured routes.
    pub fn new(net: Arc<cmux_wg::WgNet>) -> Self {
        Self { net }
    }

    pub fn net(&self) -> &Arc<cmux_wg::WgNet> {
        &self.net
    }
}

#[cfg(feature = "wireguard-transport")]
impl fmt::Debug for WireGuardDialer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("WireGuardDialer").field("routes", &self.net.routes()).finish()
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
        let address = addresses
            .into_iter()
            .find(|address| self.net.routes_contain(address.ip()))
            .ok_or_else(|| {
            LinkError::Transport(format!(
                "{host}:{port} is outside the configured WireGuard routes"
            ))
        })?;
        let stream = self.net.connect(address).await.map_err(|error| {
            LinkError::Transport(format!("wireguard connect {address}: {error}"))
        })?;
        Ok(Box::new(stream))
    }
}
