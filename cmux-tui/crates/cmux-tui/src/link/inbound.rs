//! A stream that a paired peer opened to this machine's link (overlay TCP
//! 4100). The link checks who sent it, then hands it to the session
//! daemon's remote entry with the verified identity as the first line.
//!
//! The stream goes ONLY to the remote entry (`cmux_link::entry_path`),
//! never to the session's local socket, which carries local-admin trust.

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

use cmux_link::dial::{MAX_LINE_BYTES, Service, ServiceHello, parse_line};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use super::lines::read_line;

/// Why an inbound stream was closed without reaching the daemon.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum InboundRefused {
    /// The WireGuard key is not a paired peer.
    UnknownPeer,
    /// The stream's source is not the overlay address of the key's install.
    AddressMismatch,
    /// The first line is not a service hello for a known service.
    BadHello,
    /// The daemon's remote entry is not listening.
    EntryUnavailable,
}

/// The daemon entry a link stream may reach for the session listening on
/// `session_socket`: its remote entry, never the session socket itself.
pub(super) fn daemon_entry(session_socket: &Path) -> PathBuf {
    cmux_link::entry_path::remote_entry_socket_path(session_socket)
}

/// Check `stream` from the peer with WireGuard key `peer_key` and overlay
/// source `peer_addr`, then splice it into the daemon's remote entry.
pub(super) async fn serve_inbound<S>(
    mut stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    pairings: &Pairings,
    session_socket: &Path,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let record = pairings.by_key(&peer_key).ok_or(InboundRefused::UnknownPeer)?;
    if peer_addr.ip() != IpAddr::V6(record.overlay_address()) {
        return Err(InboundRefused::AddressMismatch);
    }
    let hello = read_line(&mut stream, MAX_LINE_BYTES).await.map_err(|_| InboundRefused::BadHello)?;
    let Some(ServiceHello { service: Service::Daemon }) = parse_line::<ServiceHello>(&hello) else {
        return Err(InboundRefused::BadHello);
    };
    let stamp = cmux_link::stamp::encode(&record.peer()).map_err(|_| InboundRefused::UnknownPeer)?;
    let mut entry = tokio::net::UnixStream::connect(daemon_entry(session_socket))
        .await
        .map_err(|_| InboundRefused::EntryUnavailable)?;
    write_stamp(&mut entry, &stamp).await.map_err(|_| InboundRefused::EntryUnavailable)?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut entry).await;
    Ok(())
}

async fn write_stamp(entry: &mut tokio::net::UnixStream, stamp: &str) -> io::Result<()> {
    entry.write_all(stamp.as_bytes()).await?;
    entry.write_all(b"\n").await
}
