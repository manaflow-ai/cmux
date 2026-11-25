//! A tunnel on one UDP path, run as a [`Multipath`] with one path, so the
//! one-path case reports path events from the same selector code as the
//! multipath case (transport.md 12a) and needs no second event source.

use cmux_transport::{PathKind, SelectorConfig};
use tokio::net::UdpSocket;

use crate::multipath::{Multipath, MultipathControl};
use crate::probe_schedule::ProbeConfig;
use crate::underlay::{SocketPath, UdpUnderlay};
use crate::{WgConfig, WgError, WgNet};

/// The smallest send buffer [`WgNet::start_single_path`] sets: on macOS a
/// UDP socket's send buffer also caps the datagram size.
pub const MIN_SEND_BUFFER: usize = 16 * 1024;

/// The largest UDP payload the tunnel sends for an MTU: one WireGuard data
/// message (16-byte header, the packet padded to 16 bytes, 16-byte tag).
fn largest_underlay_datagram(mtu: u16) -> usize {
    usize::from(mtu).next_multiple_of(16) + 32
}

/// A fresh UDP socket aimed at the configured endpoint, in its family, with
/// the kernel's default send buffer or `send_buffer` bytes. A requested
/// buffer grows to at least one full datagram of the configured MTU: on
/// macOS the send buffer caps the datagram size, and a smaller one would
/// refuse every full packet with EMSGSIZE.
pub(crate) async fn new_socket_path(
    config: &WgConfig,
    send_buffer: Option<usize>,
) -> Result<UdpUnderlay, WgError> {
    let endpoint = config
        .endpoint
        .as_ref()
        .ok_or_else(|| WgError::EndpointUnresolved("<none configured>".into()))?;
    let candidates =
        endpoint.resolve().await.map_err(|_| WgError::EndpointUnresolved(endpoint.host.clone()))?;
    let peer =
        *candidates.first().ok_or_else(|| WgError::EndpointUnresolved(endpoint.host.clone()))?;
    let bind = if peer.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let socket = UdpSocket::bind(bind).await?;
    #[cfg(unix)]
    if let Some(bytes) = send_buffer {
        set_send_buffer(&socket, bytes.max(largest_underlay_datagram(config.mtu)))?;
    }
    // Elsewhere the kernel's default stays.
    #[cfg(not(unix))]
    let _ = send_buffer;
    Ok(SocketPath::new(socket, Some(peer)))
}

/// Set the socket's send buffer to `bytes` (at least [`MIN_SEND_BUFFER`]).
/// A small one keeps the kernel's queue short, so a backlog forms in the
/// driver's priority queues, where media still overtakes bulk: a full buffer
/// answers `WouldBlock`, the underlay keeps the datagram, and the driver
/// sends nothing more until the socket is writable again. This is how Linux
/// queues UDP (measured, fs round 6). macOS keeps no UDP datagrams in the
/// socket buffer (there it only caps the datagram size, and a full interface
/// answers ENOBUFS), so a small buffer changes little there.
#[cfg(unix)]
fn set_send_buffer(socket: &UdpSocket, bytes: usize) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let size = libc::c_int::try_from(bytes.max(MIN_SEND_BUFFER)).unwrap_or(libc::c_int::MAX);
    // SAFETY: the descriptor is open for the borrow of `socket`, and the
    // option value points at a live `c_int` of the length passed.
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&raw const size).cast(),
            size_of_val(&size) as libc::socklen_t,
        )
    };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

impl WgNet {
    /// Start the tunnel on a fresh UDP socket aimed at the configured
    /// endpoint, as [`WgNet::start_with_new_socket`] does, but under a
    /// one-path [`Multipath`] of `kind`. The returned control reports path
    /// events.
    ///
    /// Probes run only when `probes` is set: they need a peer that answers
    /// them (a cmux endpoint, named by `PeerAddress =`). Without probes the
    /// path is never measured and events report no current path, only
    /// `max_datagram`. When the socket fails for good, the session ends, as
    /// with a plain socket.
    ///
    /// `send_buffer` sets the socket's send buffer in bytes (at least
    /// [`MIN_SEND_BUFFER`] and one full datagram of the MTU); `None` keeps
    /// the kernel's default. A small one
    /// moves the backlog of a saturated uplink out of the kernel and into
    /// the driver's priority queues.
    pub async fn start_single_path(
        config: WgConfig,
        kind: PathKind,
        probes: Option<ProbeConfig>,
        send_buffer: Option<usize>,
    ) -> Result<(Self, MultipathControl), WgError> {
        let path = new_socket_path(&config, send_buffer).await?;
        Self::start_single_path_on(config, kind, probes, path)
    }

    /// [`WgNet::start_single_path`] on a caller-built path (tests, or a
    /// socket the caller bound).
    pub fn start_single_path_on(
        config: WgConfig,
        kind: PathKind,
        probes: Option<ProbeConfig>,
        path: impl crate::Underlay,
    ) -> Result<(Self, MultipathControl), WgError> {
        let selector = SelectorConfig::default();
        let (underlay, control) = match probes {
            Some(probes) => Multipath::with_probes(selector, probes),
            None => Multipath::new(selector),
        };
        control.add_path(kind, path);
        let net = Self::start_with_underlay(config, underlay.with_fixed_paths())?;
        Ok((net, control))
    }
}
