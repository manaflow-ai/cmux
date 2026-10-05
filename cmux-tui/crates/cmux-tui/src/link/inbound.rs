//! A stream that a paired peer opened to this machine's link (overlay TCP
//! 4100). The link checks who sent it, then hands it to the session
//! daemon's remote entry with the verified identity as the first line.
//!
//! The stream goes ONLY to the remote entry (`cmux_link::entry_path`),
//! never to the session's local socket, which carries local-admin trust:
//! the entry lives in its own directory, its process must be this user and
//! signed as cmux, and it must greet with the entry banner before the link
//! writes a byte.

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::AsRawFd;
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
    /// The socket at the entry path did not greet with the entry banner.
    NotAnEntry,
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
    let hello =
        read_line(&mut stream, MAX_LINE_BYTES).await.map_err(|_| InboundRefused::BadHello)?;
    // A paired peer reaches only the daemon entry, and carries no token.
    let Some(ServiceHello { service: Service::Daemon, link_token: None, epoch: None }) =
        parse_line::<ServiceHello>(&hello)
    else {
        return Err(InboundRefused::BadHello);
    };
    // A paired peer's stream carries no control-plane check.
    hand_to_entry(stream, &record.peer(), None, session_socket).await
}

/// Splice `stream` into the session's remote entry with `peer` (and the
/// `check` the link made for this stream, only after it passed) stamped as
/// the first line, after the entry proved it is one (same user and cmux
/// code, then the entry banner).
pub(super) async fn hand_to_entry<S>(
    mut stream: S,
    peer: &cmux_link::stamp::LinkPeer,
    check: Option<cmux_link::stamp::StampCheck>,
    session_socket: &Path,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let stamp = cmux_link::stamp::encode(peer, check).map_err(|_| InboundRefused::UnknownPeer)?;
    let mut entry = tokio::net::UnixStream::connect(daemon_entry(session_socket))
        .await
        .map_err(|_| InboundRefused::EntryUnavailable)?;
    let fd = entry.as_raw_fd();
    tokio::task::spawn_blocking(move || cmux_link::caller::verify_fd(fd))
        .await
        .map_err(|_| InboundRefused::NotAnEntry)?
        .map_err(|_| InboundRefused::NotAnEntry)?;
    let banner =
        read_line(&mut entry, MAX_LINE_BYTES).await.map_err(|_| InboundRefused::NotAnEntry)?;
    if banner != cmux_link::entry_path::ENTRY_BANNER {
        return Err(InboundRefused::NotAnEntry);
    }
    write_stamp(&mut entry, &stamp).await.map_err(|_| InboundRefused::EntryUnavailable)?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut entry).await;
    Ok(())
}

async fn write_stamp(entry: &mut tokio::net::UnixStream, stamp: &str) -> io::Result<()> {
    entry.write_all(stamp.as_bytes()).await?;
    entry.write_all(b"\n").await
}
