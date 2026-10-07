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
use cmux_link::owner_session::{IDENTIFY_REQUEST, OwnerRefused, OwnerSession, is_brain_identity};
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
    /// An owner session that the link refused (who, or which socket).
    Owner(OwnerRefused),
}

/// The daemon entry a link stream may reach for the session listening on
/// `session_socket`: its remote entry, never the session socket itself.
pub(super) fn daemon_entry(session_socket: &Path) -> PathBuf {
    cmux_link::entry_path::remote_entry_socket_path(session_socket)
}

/// Check `stream` from the peer with WireGuard key `peer_key` and overlay
/// source `peer_addr`, then splice it into the daemon's remote entry, or
/// (owner session, the server's owner only) into the brain daemon's
/// trusted socket that `owner` names.
pub(super) async fn serve_inbound<S>(
    mut stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    pairings: &Pairings,
    session_socket: &Path,
    owner: Option<&OwnerSession>,
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
    // A paired peer carries no token. It reaches the daemon entry, and its
    // owner (decided here, from the key's pairing record) the owner session.
    match parse_line::<ServiceHello>(&hello) {
        Some(ServiceHello { service: Service::Daemon, link_token: None, epoch: None }) => {
            // A paired peer's stream carries no control-plane check.
            hand_to_entry(stream, &record.peer(), None, session_socket).await
        }
        Some(ServiceHello { service: Service::OwnerSession, link_token: None, epoch: None }) => {
            serve_owner_session(stream, &record.peer(), owner).await
        }
        _ => Err(InboundRefused::BadHello),
    }
}

/// The owner session: only the configured owner, only to the configured
/// brain socket after its checks (same uid as this link, inside the brain
/// home, not a symlink, answers `identify` as a brain daemon). The stream
/// gets no stamp: it is the owner's trusted local session.
async fn serve_owner_session<S>(
    mut stream: S,
    peer: &cmux_link::stamp::LinkPeer,
    owner: Option<&OwnerSession>,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let owner = owner.ok_or(InboundRefused::Owner(OwnerRefused::NotConfigured))?;
    owner.authorize(peer).map_err(InboundRefused::Owner)?;
    let uid = cmux_tui_core::platform::effective_uid();
    let socket = owner.check_socket(uid).map_err(InboundRefused::Owner)?;
    let mut probe = connect_same_uid(&socket, uid).await?;
    probe.write_all(IDENTIFY_REQUEST.as_bytes()).await.map_err(|_| InboundRefused::EntryUnavailable)?;
    let reply = read_line(&mut probe, 64 * 1024).await.map_err(|_| InboundRefused::Owner(OwnerRefused::NotABrain))?;
    if !is_brain_identity(&reply) {
        return Err(InboundRefused::Owner(OwnerRefused::NotABrain));
    }
    drop(probe);
    let mut daemon = connect_same_uid(&socket, uid).await?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut daemon).await;
    Ok(())
}

/// Connect to `socket` and require that its listener runs as `uid`.
async fn connect_same_uid(socket: &Path, uid: u32) -> Result<tokio::net::UnixStream, InboundRefused> {
    let stream = tokio::net::UnixStream::connect(socket).await.map_err(|_| InboundRefused::EntryUnavailable)?;
    match stream.peer_cred() {
        Ok(credentials) if credentials.uid() == uid => Ok(stream),
        _ => Err(InboundRefused::Owner(OwnerRefused::WrongOwner)),
    }
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
