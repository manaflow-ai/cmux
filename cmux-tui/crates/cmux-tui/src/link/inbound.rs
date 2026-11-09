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
use std::os::fd::{AsFd, AsRawFd};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::dial::{
    MAX_LINE_BYTES, RekeyReply, RekeyRequest, Service, ServiceHello, line, parse_line,
};
use cmux_link::owner_session::{IDENTIFY_REQUEST, OwnerRefused, OwnerSession, is_brain_identity};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use super::acpmux::{AcpmuxTarget, hand_to_acpmux};
use super::control::RekeyTarget;
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
    /// This link serves no `acpmux` stream.
    AcpmuxUnavailable,
    /// No live, proven acpmux listener (`acpmux::listener_record`); no byte
    /// of the stream was sent anywhere.
    AcpmuxNotLive(acpmux::listener_record::NotLive),
}

pub(super) use super::paired_streams::Revocations;

/// A paired peer names the key its link serves from now on ([`RekeyRequest`]).
/// The stream came in on the old key, which the pairing trusts, so the record
/// moves to the new one; a key another install's record holds is refused.
async fn serve_rekey<S>(
    stream: &mut S,
    install: &str,
    target: Option<&RekeyTarget>,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let target = target.ok_or(InboundRefused::EntryUnavailable)?;
    let text = read_line(stream, MAX_LINE_BYTES).await.map_err(|_| InboundRefused::BadHello)?;
    let request = parse_line::<RekeyRequest>(&text).ok_or(InboundRefused::BadHello)?;
    let refused = |why: String| RekeyReply { ok: false, error: Some(why), public_key: None };
    let (reply, changed) = match rekey_key(&request.public_key) {
        Some(key) => match target.apply(install, &key) {
            Ok(changed) => {
                // This link adopted a key too and still kept the asker on its old one: the
                // answer names the new key, and the asker moves to it now (`key_adoption.rs`).
                let ours = target.confirm(install);
                let public_key = ours.map(|ours| STANDARD.encode(ours));
                (RekeyReply { ok: true, error: None, public_key }, changed || ours.is_some())
            }
            Err(error) => (refused(error.to_string()), false),
        },
        None => (refused("invalid_key".to_owned()), false),
    };
    let _ = stream.write_all(line(&reply).as_bytes()).await;
    let _ = stream.shutdown().await;
    // After the answer: the reload closes this stream with the rest of the old key's.
    if changed {
        target.reload();
    }
    Ok(())
}

/// A rekey's key: canonical standard base64 of 32 bytes, not all zero.
pub(super) fn rekey_key(text: &str) -> Option<[u8; 32]> {
    let key: [u8; 32] = STANDARD.decode(text).ok()?.try_into().ok()?;
    (STANDARD.encode(key) == text && key != [0; 32]).then_some(key)
}
use super::paired_streams::{close_revoked, while_paired};

/// The daemon entry a link stream may reach for the session listening on
/// `session_socket`: its remote entry, never the session socket itself.
pub(super) fn daemon_entry(session_socket: &Path) -> PathBuf {
    cmux_link::entry_path::remote_entry_socket_path(session_socket)
}

/// Check `stream` from the peer with WireGuard key `peer_key` and overlay
/// source `peer_addr`, then splice it into the daemon's remote entry, or
/// (owner session, the server's owner only) into the brain daemon's
/// trusted socket that `owner` names.
#[cfg(test)]
pub(super) async fn serve_inbound<S>(
    stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    pairings: &Pairings,
    session_socket: &Path,
    owner: Option<&OwnerSession>,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    serve_inbound_watched(
        stream,
        peer_key,
        peer_addr,
        pairings,
        Some(session_socket),
        owner,
        &AcpmuxTarget::Off,
        None,
        None,
    )
    .await
}

/// [`serve_inbound`], where `revocations` carries every new pairing view: a
/// handshake or stream closes when the view no longer pairs its key to
/// the same identity (a peer-map update or `cmux link peer remove`).
/// Without a `session_socket` a `daemon` stream is refused; an `acpmux`
/// stream goes to `acpmux` (`super::acpmux`).
#[allow(clippy::too_many_arguments)]
pub(super) async fn serve_inbound_watched<S>(
    mut stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    pairings: &Pairings,
    session_socket: Option<&Path>,
    owner: Option<&OwnerSession>,
    acpmux: &AcpmuxTarget,
    mut revocations: Option<Revocations>,
    rekey: Option<&RekeyTarget>,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let record = pairings.by_key(&peer_key).ok_or(InboundRefused::UnknownPeer)?;
    if peer_addr.ip() != IpAddr::V6(record.overlay_address()) {
        return Err(InboundRefused::AddressMismatch);
    }
    let peer = record.peer();
    // Register before the first await: reload also waits for handshakes.
    let _open = revocations.as_ref().map(|view| view.open.enter(peer_key));
    let hello = match while_paired(
        revocations.as_mut(),
        peer_key,
        &peer,
        read_line(&mut stream, MAX_LINE_BYTES),
    )
    .await
    {
        Ok(hello) => hello.map_err(|_| InboundRefused::BadHello)?,
        Err(()) => {
            close_revoked(&mut stream).await;
            return Err(InboundRefused::UnknownPeer);
        }
    };
    // A paired peer carries no token. It reaches the daemon entry, and its
    // owner (decided here, from the key's pairing record) the owner session.
    let (served, owner_requested) = match parse_line::<ServiceHello>(&hello) {
        Some(ServiceHello { service: Service::Daemon, link_token: None, epoch: None }) => {
            let session_socket = session_socket.ok_or(InboundRefused::EntryUnavailable)?;
            // A paired peer's stream carries no control-plane check.
            (
                while_paired(
                    revocations.as_mut(),
                    peer_key,
                    &peer,
                    hand_to_entry(&mut stream, &peer, None, session_socket),
                )
                .await,
                false,
            )
        }
        Some(ServiceHello { service: Service::OwnerSession, link_token: None, epoch: None }) => (
            while_paired(
                revocations.as_mut(),
                peer_key,
                &peer,
                serve_owner_session(&mut stream, &peer, owner),
            )
            .await,
            true,
        ),
        // acpmux checks its own token on the upgrade; the link only carries it.
        Some(ServiceHello { service: Service::Acpmux, link_token: None, epoch: None }) => (
            while_paired(
                revocations.as_mut(),
                peer_key,
                &peer,
                hand_to_acpmux(&mut stream, acpmux),
            )
            .await,
            false,
        ),
        // The peer's link adopted its node key: its record moves to the key it names.
        Some(ServiceHello { service: Service::Rekey, link_token: None, epoch: None }) => (
            while_paired(
                revocations.as_mut(),
                peer_key,
                &peer,
                serve_rekey(&mut stream, &record.install, rekey),
            )
            .await,
            false,
        ),
        _ => return Err(InboundRefused::BadHello),
    };
    match served {
        Ok(result) => result,
        Err(()) => {
            close_revoked(&mut stream).await;
            Err(if owner_requested {
                InboundRefused::Owner(OwnerRefused::NotOwner)
            } else {
                InboundRefused::UnknownPeer
            })
        }
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
    probe
        .write_all(IDENTIFY_REQUEST.as_bytes())
        .await
        .map_err(|_| InboundRefused::EntryUnavailable)?;
    let reply = read_line(&mut probe, 64 * 1024)
        .await
        .map_err(|_| InboundRefused::Owner(OwnerRefused::NotABrain))?;
    if !is_brain_identity(&reply) {
        return Err(InboundRefused::Owner(OwnerRefused::NotABrain));
    }
    drop(probe);
    let mut daemon = connect_same_uid(&socket, uid).await?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut daemon).await;
    Ok(())
}

/// Connect to `socket` and require that its listener runs as `uid`.
async fn connect_same_uid(
    socket: &Path,
    uid: u32,
) -> Result<tokio::net::UnixStream, InboundRefused> {
    let stream = tokio::net::UnixStream::connect(socket)
        .await
        .map_err(|_| InboundRefused::EntryUnavailable)?;
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
    // A revocation can cancel this future while verification is running.
    // Give the blocking task its own descriptor so it cannot inspect a reused fd.
    let fd = entry.as_fd().try_clone_to_owned().map_err(|_| InboundRefused::NotAnEntry)?;
    // That copy keeps the socket open until the check returns (the macOS
    // signature check can take seconds): a cancel shuts the socket down,
    // so the entry sees the end at once.
    let mut verifying = ShutdownOnCancel(Some(
        entry.as_fd().try_clone_to_owned().map_err(|_| InboundRefused::NotAnEntry)?,
    ));
    tokio::task::spawn_blocking(move || cmux_link::caller::verify_fd(fd.as_raw_fd()))
        .await
        .map_err(|_| InboundRefused::NotAnEntry)?
        .map_err(|_| InboundRefused::NotAnEntry)?;
    verifying.finished();
    let banner =
        read_line(&mut entry, MAX_LINE_BYTES).await.map_err(|_| InboundRefused::NotAnEntry)?;
    if banner != cmux_link::entry_path::ENTRY_BANNER {
        return Err(InboundRefused::NotAnEntry);
    }
    write_stamp(&mut entry, &stamp).await.map_err(|_| InboundRefused::EntryUnavailable)?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut entry).await;
    Ok(())
}

/// Shuts a socket down for reading and writing when dropped before
/// [`Self::finished`] (a cancel or a refused check): every copy of the
/// descriptor then reads its end.
struct ShutdownOnCancel(Option<std::os::fd::OwnedFd>);

impl ShutdownOnCancel {
    fn finished(&mut self) {
        self.0 = None;
    }
}

impl Drop for ShutdownOnCancel {
    fn drop(&mut self) {
        if let Some(fd) = self.0.take() {
            let _ = std::os::unix::net::UnixStream::from(fd).shutdown(std::net::Shutdown::Both);
        }
    }
}

async fn write_stamp(entry: &mut tokio::net::UnixStream, stamp: &str) -> io::Result<()> {
    entry.write_all(stamp.as_bytes()).await?;
    entry.write_all(b"\n").await
}
