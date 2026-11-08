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
    /// The listener the running acpmux daemon of this home recorded
    /// (`listener.json`, `acpmux::listener_handoff`), read for each stream,
    /// and only while that daemon's pid runs. Never `websocket.listen` of
    /// config.json: it outlives the daemon, and a stale port could reach an
    /// unrelated local service.
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
                let home = home.clone();
                tokio::task::spawn_blocking(move || acpmux::listener_handoff::read_live(&home))
                    .await
                    .ok()
                    .flatten()
                    .and_then(loopback)
            }
        }
    }
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
    fn only_a_loopback_listener_with_a_port_is_reached() {
        let at = |text: &str| loopback(text.parse().unwrap());
        assert_eq!(at("127.0.0.1:7788"), "127.0.0.1:7788".parse().ok());
        assert_eq!(at("0.0.0.0:7788"), "127.0.0.1:7788".parse().ok());
        assert_eq!(at("[::]:7788"), "[::1]:7788".parse().ok());
        assert_eq!(at("192.168.1.4:7788"), None);
        assert_eq!(at("127.0.0.1:0"), None);
    }

    #[tokio::test]
    async fn the_running_daemons_record_is_the_only_listener_read() {
        let home = tempfile::tempdir().unwrap();
        let target = AcpmuxTarget::Home(home.path().to_path_buf());
        // A saved `websocket.listen` alone is never read.
        std::fs::write(
            home.path().join("config.json"),
            r#"{"websocket":{"listen":"127.0.0.1:7788"}}"#,
        )
        .unwrap();
        assert_eq!(target.websocket().await, None);
        // The running daemon's record (this test process is that daemon here).
        let bound: SocketAddr = "127.0.0.1:52341".parse().unwrap();
        acpmux::listener_handoff::write(home.path(), bound).unwrap();
        assert_eq!(target.websocket().await, Some(bound));
        acpmux::listener_handoff::remove_if_owned(home.path());
        assert_eq!(target.websocket().await, None);
    }

    /// A listener that counts the bytes anyone sends it.
    async fn counting_listener() -> (SocketAddr, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let got = std::sync::Arc::new(AtomicUsize::new(0));
        let counted = got.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let counted = counted.clone();
                tokio::spawn(async move {
                    let mut buffer = [0u8; 256];
                    while let Ok(n) = socket.read(&mut buffer).await {
                        if n == 0 {
                            break;
                        }
                        counted.fetch_add(n, Ordering::SeqCst);
                    }
                });
            }
        });
        (address, got)
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_stale_record_or_a_config_port_gets_no_peer_bytes() {
        use std::sync::atomic::Ordering;
        use tokio::io::AsyncWriteExt;
        let home = tempfile::tempdir().unwrap();
        // An unrelated local service on the port config.json still names.
        let (config_port, config_got) = counting_listener().await;
        std::fs::write(
            home.path().join("config.json"),
            format!(r#"{{"websocket":{{"listen":"{config_port}"}}}}"#),
        )
        .unwrap();
        // Another one on the port a crashed daemon recorded: its pid no longer runs.
        let (stale_port, stale_got) = counting_listener().await;
        let mut ended = std::process::Command::new("true").spawn().unwrap();
        let dead = ended.id();
        ended.wait().unwrap();
        std::fs::write(
            home.path().join(acpmux::listener_handoff::FILE_NAME),
            format!(r#"{{"version":1,"listen":"{stale_port}","pid":{dead}}}"#),
        )
        .unwrap();
        let target = AcpmuxTarget::Home(home.path().to_path_buf());
        let (mut peer, link_side) = tokio::io::duplex(256);
        peer.write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n").await.unwrap();
        assert_eq!(
            hand_to_acpmux(link_side, &target).await,
            Err(InboundRefused::AcpmuxUnavailable)
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(config_got.load(Ordering::SeqCst), 0, "the config port got peer bytes");
        assert_eq!(stale_got.load(Ordering::SeqCst), 0, "the stale record's port got peer bytes");
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
