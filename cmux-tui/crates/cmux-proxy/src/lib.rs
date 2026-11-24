//! How cmux's own TCP connections leave a device: the phone's link
//! (`cmux-mobile-link`: signaling, the HTTP API, TURN over TLS) and the Mac's
//! and Linux client's way to a cmux Cloud machine (`cmux-remote`: the relay's
//! `relay+do` WebSocket, a direct `wss` route).
//!
//! - [`proxy`]: each connection goes through the system's proxy for its
//!   destination (manual, PAC or WPAD on iOS and macOS, as URLSession; the
//!   environment elsewhere), with `CONNECT` or SOCKS5, so a network whose only
//!   way out is its proxy still links. Loopback and tailnet addresses are
//!   never proxied.
//! - [`tls`]: TLS verifies against the OS trust store, so a network that
//!   inspects TLS with a company root an MDM profile installed still links,
//!   and [`tls::inspected`] tells such a path apart (telemetry only).
//!
//! The outer TLS is never what authenticates the far end: the WireGuard,
//! Noise or pinned-key session inside it is end to end, so a proxy that
//! re-signs the outer TLS sees ciphertext.
//!
//! Moved from `cmux-mobile-link`'s `egress` module (cmux#53160), which
//! re-exports it.

#[cfg(target_vendor = "apple")]
mod apple;
pub mod proxy;
pub mod tls;

use std::time::Duration;

use tokio::net::TcpStream;

pub use proxy::{Credentials, Hop, ProxyConfig, ProxyServer};
pub use tls::TlsTrust;

/// How one connection leaves this device.
#[derive(Debug, Clone, Default)]
pub struct Egress {
    pub proxy: ProxyConfig,
    /// Only through a proxy: a destination the settings send direct fails
    /// with [`EgressError::ProxyRequired`] (the debug "Proxy only" network,
    /// whose only way out is its proxy).
    pub require_proxy: bool,
    pub trust: TlsTrust,
}

/// Why a connection could not be made, said for a person (the dial's error).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EgressError {
    #[error("{0}")]
    Io(String),
    #[error(
        "the proxy {proxy} asks for {schemes} sign-in before it lets {target} through, and the cmux link can \
         sign in to a proxy only with a user name and password (Basic); ask your IT team to let {target} through \
         without sign-in"
    )]
    ProxyAuthUnsupported { proxy: String, target: String, schemes: String },
    #[error(
        "the proxy {proxy} asks for a user name and password, and the system's proxy settings have none"
    )]
    ProxyAuthMissing { proxy: String },
    #[error(
        "the proxy {proxy} asks for a password, and the system's proxy settings have the user name {username} \
         with no password; add the password in the proxy settings"
    )]
    ProxyAuthNoPassword { proxy: String, username: String },
    #[error("the proxy {proxy} refused the user name and password in the system's proxy settings")]
    ProxyAuthRefused { proxy: String },
    #[error("the proxy {proxy} refused to connect to {target}: {status}")]
    ProxyRefused { proxy: String, target: String, status: String },
    #[error("the system has no proxy for {target}, and Proxy only allows nothing else")]
    ProxyRequired { target: String },
}

impl EgressError {
    /// A proxy's refusal (sign-in or policy), not a network failure: trying
    /// again soon gives the same answer.
    pub fn is_proxy_refusal(&self) -> bool {
        !matches!(self, Self::Io(_))
    }

    /// The more telling of two failures (a proxy's refusal over a network
    /// error).
    fn rank(&self) -> u8 {
        match self {
            Self::Io(_) => 0,
            Self::ProxyRefused { .. } | Self::ProxyRequired { .. } => 1,
            Self::ProxyAuthMissing { .. }
            | Self::ProxyAuthNoPassword { .. }
            | Self::ProxyAuthRefused { .. }
            | Self::ProxyAuthUnsupported { .. } => 2,
        }
    }
}

/// Bound on each hop's TCP connect and proxy handshake.
const HOP_WAIT: Duration = Duration::from_secs(10);

/// How a connection went out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    Direct,
    Proxy(Hop),
}

/// A TCP stream to `host:port` (`secure`: TLS will run on it, as for an
/// `https` URL): through the first hop of the proxy settings that connects,
/// in order. The destination's name goes to the proxy unresolved (a proxy-only
/// network often resolves outside names only at its proxy).
pub async fn connect_tcp(
    host: &str,
    port: u16,
    secure: bool,
    egress: &Egress,
) -> Result<(TcpStream, Via), EgressError> {
    let mut hops = proxy::hops(host, port, secure, &egress.proxy).await;
    if egress.require_proxy {
        hops.retain(|hop| *hop != Hop::Direct);
        if hops.is_empty() {
            return Err(EgressError::ProxyRequired { target: proxy::authority(host, port) });
        }
    }
    let mut failure: Option<EgressError> = None;
    for hop in hops {
        let attempt = tokio::time::timeout(HOP_WAIT, connect_hop(&hop, host, port))
            .await
            .unwrap_or_else(|_| {
                Err(EgressError::Io(format!(
                    "{hop}: no connection to {} within {}s",
                    proxy::authority(host, port),
                    HOP_WAIT.as_secs()
                )))
            });
        match attempt {
            Ok(stream) => {
                if hop != Hop::Direct {
                    tracing::debug!(%hop, host, port, "connected through the proxy");
                }
                let via = if hop == Hop::Direct { Via::Direct } else { Via::Proxy(hop) };
                return Ok((stream, via));
            }
            Err(error) => {
                tracing::debug!(%hop, host, port, %error, "this way out did not connect; trying the next");
                if failure.as_ref().is_none_or(|kept| error.rank() >= kept.rank()) {
                    failure = Some(error);
                }
            }
        }
    }
    Err(failure.unwrap_or_else(|| {
        EgressError::Io(format!("no way out to {}", proxy::authority(host, port)))
    }))
}

async fn connect_hop(hop: &Hop, host: &str, port: u16) -> Result<TcpStream, EgressError> {
    let tcp = |host: &str, port: u16| {
        let address = proxy::authority(host, port);
        async move {
            TcpStream::connect(address.as_str())
                .await
                .map_err(|error| EgressError::Io(format!("{address}: {error}")))
        }
    };
    match hop {
        Hop::Direct => tcp(host, port).await,
        Hop::Http(server) => {
            proxy::http_connect(tcp(&server.host, server.port).await?, server, host, port).await
        }
        Hop::Socks5(server) => {
            proxy::socks5_connect(tcp(&server.host, server.port).await?, server, host, port).await
        }
    }
}

/// A TLS stream to `host:port` the way `egress` says, verified against its
/// trust for `host`.
pub async fn connect_tls(
    host: &str,
    port: u16,
    egress: &Egress,
) -> Result<(tokio_rustls::client::TlsStream<TcpStream>, Via), EgressError> {
    let (tcp, via) = connect_tcp(host, port, true, egress).await?;
    let config = tls::client_config(&egress.trust).map_err(EgressError::Io)?;
    let name = rustls::pki_types::ServerName::try_from(host.to_owned())
        .map_err(|error| EgressError::Io(format!("{host}: {error}")))?;
    let stream = tokio_rustls::TlsConnector::from(config)
        .connect(name, tcp)
        .await
        .map_err(|error| EgressError::Io(format!("TLS to {host}: {error}")))?;
    Ok((stream, via))
}
