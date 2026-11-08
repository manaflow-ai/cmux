//! The link's `acpmux` service: an overlay stream from a paired peer that
//! goes to this machine's acpmux daemon, on its loopback WebSocket listener.
//!
//! The link only carries bytes, as acpmux's own WireGuard bridge does
//! (`acpmux/src/wireguard.rs`): the stream reaches that listener and nothing
//! else (never acpmux's local socket), and acpmux checks its listener token
//! and peer proof on the WebSocket upgrade. Pairing adds no trust to acpmux.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;

use super::inbound::InboundRefused;

/// How long the connect to acpmux's listener may take (it is on loopback).
const CONNECT_BOUND: Duration = Duration::from_secs(10);

/// Where an inbound `acpmux` stream goes.
#[derive(Debug, Clone)]
pub(super) enum AcpmuxTarget {
    /// This link serves no `acpmux` stream.
    #[cfg_attr(not(test), allow(dead_code))]
    Off,
    /// The listener of the acpmux daemon whose home is this directory, read
    /// for each stream, so a listener that moved port is still found: the
    /// address the running daemon recorded (`listener.json`, which a DEV
    /// build's free port goes to), else `websocket.listen` of its
    /// `config.json`.
    Home(PathBuf),
    /// A fixed listener address.
    #[cfg_attr(not(test), allow(dead_code))]
    Fixed(SocketAddr),
}

impl AcpmuxTarget {
    /// The acpmux home this user's daemon runs from (`ACPMUX_HOME`, else
    /// `~/.acpmux`).
    pub(super) fn from_acpmux_home() -> Self {
        Self::Home(acpmux::config::home())
    }

    /// The listener to connect to, if acpmux names one on loopback.
    async fn websocket(&self) -> Option<SocketAddr> {
        match self {
            Self::Off => None,
            Self::Fixed(address) => loopback(*address),
            Self::Home(home) => {
                let recorded = {
                    let home = home.clone();
                    tokio::task::spawn_blocking(move || acpmux::listener_handoff::read_live(&home))
                        .await
                        .ok()
                        .flatten()
                };
                if let Some(address) = recorded.and_then(loopback) {
                    return Some(address);
                }
                let bytes = tokio::fs::read(home.join("config.json")).await.ok()?;
                listen_address(&bytes)
            }
        }
    }
}

/// `websocket.listen` of an acpmux `config.json`, as a loopback address.
fn listen_address(config: &[u8]) -> Option<SocketAddr> {
    let config: serde_json::Value = serde_json::from_slice(config).ok()?;
    let listen = config.get("websocket")?.get("listen")?.as_str()?;
    loopback(listen.parse().ok()?)
}

/// A wildcard listener is reached on loopback; a listener only on a network
/// address is not reached at all (the link never sends a stream off this
/// machine), nor is port 0.
fn loopback(mut address: SocketAddr) -> Option<SocketAddr> {
    if address.ip().is_unspecified() {
        address.set_ip(match address.ip() {
            IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::LOCALHOST),
        });
    }
    (address.ip().is_loopback() && address.port() != 0).then_some(address)
}

/// Carry `stream` to acpmux's listener until both sides end.
pub(super) async fn hand_to_acpmux<S>(
    mut stream: S,
    target: &AcpmuxTarget,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let address = target.websocket().await.ok_or(InboundRefused::AcpmuxUnavailable)?;
    let mut local = tokio::time::timeout(CONNECT_BOUND, TcpStream::connect(address))
        .await
        .map_err(|_| InboundRefused::AcpmuxUnavailable)?
        .map_err(|_| InboundRefused::AcpmuxUnavailable)?;
    let _ = local.set_nodelay(true);
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut local).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_listener_comes_from_websocket_listen_on_loopback_only() {
        let at = |text: &str| listen_address(text.as_bytes());
        assert_eq!(
            at(r#"{"websocket":{"listen":"127.0.0.1:7788"}}"#),
            "127.0.0.1:7788".parse().ok()
        );
        assert_eq!(at(r#"{"websocket":{"listen":"0.0.0.0:7788"}}"#), "127.0.0.1:7788".parse().ok());
        assert_eq!(at(r#"{"websocket":{"listen":"[::]:7788"}}"#), "[::1]:7788".parse().ok());
        assert_eq!(at(r#"{"websocket":{"listen":"192.168.1.4:7788"}}"#), None);
        assert_eq!(at(r#"{"websocket":{"listen":"127.0.0.1:0"}}"#), None);
        assert_eq!(at(r#"{"websocket":{"listen":"localhost:7788"}}"#), None);
        assert_eq!(at(r#"{"peers":{}}"#), None);
        assert_eq!(at("not json"), None);
    }

    #[tokio::test]
    async fn the_running_daemons_recorded_port_wins_over_config_json() {
        let home = tempfile::tempdir().unwrap();
        let target = AcpmuxTarget::Home(home.path().to_path_buf());
        // A DEV build: `--listen 127.0.0.1:0` is never saved, config.json has no listener.
        std::fs::write(home.path().join("config.json"), r#"{"peers":{}}"#).unwrap();
        assert_eq!(target.websocket().await, None);
        let bound: SocketAddr = "127.0.0.1:52341".parse().unwrap();
        acpmux::listener_handoff::write(home.path(), bound).unwrap();
        assert_eq!(target.websocket().await, Some(bound));
        // A saved listener is still read when the daemon recorded none.
        acpmux::listener_handoff::remove_if_owned(home.path());
        std::fs::write(
            home.path().join("config.json"),
            r#"{"websocket":{"listen":"127.0.0.1:7788"}}"#,
        )
        .unwrap();
        assert_eq!(target.websocket().await, "127.0.0.1:7788".parse().ok());
    }

    #[tokio::test]
    async fn no_listener_refuses_the_stream() {
        let (_peer, link_side) = tokio::io::duplex(64);
        assert_eq!(
            hand_to_acpmux(link_side, &AcpmuxTarget::Off).await,
            Err(InboundRefused::AcpmuxUnavailable)
        );
        let missing = AcpmuxTarget::Home(PathBuf::from("/nonexistent/acpmux"));
        let (_peer, link_side) = tokio::io::duplex(64);
        assert_eq!(
            hand_to_acpmux(link_side, &missing).await,
            Err(InboundRefused::AcpmuxUnavailable)
        );
    }
}
