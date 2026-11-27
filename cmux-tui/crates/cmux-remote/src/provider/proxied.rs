//! How the client's own TCP connections to a relay or a `wss` route leave this
//! machine: through the system's proxy when the system says so for that
//! destination (`cmux-proxy`: CFNetwork with PAC and WPAD on macOS, the
//! `https_proxy` family elsewhere), else directly, exactly as before.
//!
//! The direct path costs what it did: a loopback, link-local or tailnet host
//! never asks; a cached answer is read at once; an uncached one is asked
//! while the direct connect already runs, and the direct socket is used as
//! soon as the answer says direct. Only an answer that names a proxy drops
//! the direct attempt and tunnels through the proxy (`CONNECT`, or SOCKS5),
//! falling back in the order the system gave (a PAC file's `PROXY a; DIRECT`).
//!
//! The outer TLS and the proxy are never what authenticates the daemon: the
//! Noise session inside is end to end and pinned, so a proxy that inspects TLS
//! sees only ciphertext. [`OuterPath`] keeps what the path looked like for
//! telemetry (`proxy`, `tls_inspected` on the transport snapshot).

use std::io;
use std::sync::{Arc, Mutex, PoisonError};

use cmux_proxy::{Egress, Hop, ProxyConfig, Via};
use rustls::pki_types::CertificateDer;
use tokio::net::TcpStream;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use crate::observability::OuterPathSnapshot;

/// A TCP stream to `host:port` (`secure`: TLS runs on it), through the proxy
/// `config` names for it, else `direct` (the caller's hedged connect).
pub(crate) async fn connect<F>(
    host: &str,
    port: u16,
    secure: bool,
    config: &ProxyConfig,
    direct: F,
) -> io::Result<(TcpStream, Via)>
where
    F: Future<Output = io::Result<TcpStream>>,
{
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    let known = match config {
        ProxyConfig::Direct => Some(vec![Hop::Direct]),
        ProxyConfig::System if cmux_proxy::proxy::never_proxied(bare) => Some(vec![Hop::Direct]),
        ProxyConfig::System => cmux_proxy::proxy::cached_hops(bare, port, secure),
        ProxyConfig::Fixed(hops) if hops.is_empty() => Some(vec![Hop::Direct]),
        ProxyConfig::Fixed(hops) => Some(hops.clone()),
    };
    let mut direct = std::pin::pin!(direct);
    let hops = match known {
        Some(hops) => hops,
        None => {
            // Ask beside the direct connect: the answer is usually "direct", and then the
            // socket is already on its way.
            let mut lookup = std::pin::pin!(cmux_proxy::proxy::hops(bare, port, secure, config));
            let mut early: Option<io::Result<TcpStream>> = None;
            let hops = loop {
                tokio::select! {
                    hops = &mut lookup => break hops,
                    result = &mut direct, if early.is_none() => early = Some(result),
                }
            };
            if hops == [Hop::Direct] {
                let stream = match early {
                    Some(result) => result?,
                    None => direct.await?,
                };
                return Ok((stream, Via::Direct));
            }
            hops
        }
    };
    if hops == [Hop::Direct] {
        return Ok((direct.await?, Via::Direct));
    }
    let egress = Egress { proxy: ProxyConfig::Fixed(hops), ..Egress::default() };
    let (stream, via) = cmux_proxy::connect_tcp(bare, port, secure, &egress)
        .await
        .map_err(|error| io::Error::other(error.to_string()))?;
    let _ = stream.set_nodelay(true);
    Ok((stream, via))
}

/// What the last outer connection of a provider looked like: through which
/// proxy, and the server's chain (judged for inspection only when a snapshot
/// asks, so the connect pays nothing for it). Clones share it.
#[derive(Clone, Default)]
pub(crate) struct OuterPath(Arc<Mutex<Option<Observed>>>);

struct Observed {
    host: String,
    proxy: Option<String>,
    chain: Vec<CertificateDer<'static>>,
}

impl OuterPath {
    /// Keep how `socket` to `host` went out.
    pub(crate) fn record(
        &self,
        host: &str,
        via: &Via,
        socket: &WebSocketStream<MaybeTlsStream<TcpStream>>,
    ) {
        let chain = match socket.get_ref() {
            MaybeTlsStream::Rustls(tls) => tls
                .get_ref()
                .1
                .peer_certificates()
                .map(|chain| chain.iter().map(|c| c.clone().into_owned()).collect())
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        let proxy = match via {
            Via::Direct => None,
            Via::Proxy(hop) => Some(hop.to_string()),
        };
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Observed { host: host.to_owned(), proxy, chain });
    }

    /// The last connection's path, `None` before the first.
    pub(crate) fn snapshot(&self) -> Option<OuterPathSnapshot> {
        let observed = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        let observed = observed.as_ref()?;
        Some(OuterPathSnapshot {
            proxy: observed.proxy.clone(),
            tls_inspected: cmux_proxy::tls::chain_inspected(&observed.host, &observed.chain),
        })
    }
}
