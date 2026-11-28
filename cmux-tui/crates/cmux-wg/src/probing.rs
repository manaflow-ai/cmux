//! Path probes inside the WireGuard session (transport.md section 4).
//!
//! A probe is a tiny overlay UDP packet to [`PROBE_PORT`] carrying a
//! [`Probe`]. WireGuard encrypts and authenticates it like any packet, so it
//! needs no key of its own. The driver intercepts probes before the TCP
//! stack: a ping is answered with a pong on the path it arrived on, and a
//! pong is reported to the underlay, whose selector learns that path's RTT.
//! Probes are never activity: they run only while the session carries
//! traffic, and they do not keep it awake.

use std::net::{IpAddr, SocketAddr};

use boringtun::noise::{Tunn, TunnResult};
use cmux_transport::probe::{PROBE_LEN, PROBE_PORT};
use cmux_transport::{PathId, Probe, ProbeKind};
use tokio::time::Instant;

use crate::config::WgConfig;
use crate::udp;
use crate::underlay::Underlay;

/// The overlay addresses probes travel between: this side's tunnel address
/// and, in the same family, the base address of the peer's first allowed
/// network. The receiver intercepts probes by port and magic before routing,
/// so the destination only has to be a plausible address of the peer.
pub(crate) fn probe_route(config: &WgConfig) -> Option<(IpAddr, IpAddr)> {
    config.addresses.iter().find_map(|local| {
        let peer = config.peer_address_for(local.address).or_else(|| {
            config
                .allowed_ips
                .iter()
                .find(|network| network.network_address().is_ipv4() == local.address.is_ipv4())
                .map(|network| network.network_address())
        })?;
        Some((local.address, peer))
    })
}

/// An IPv4 or IPv6 packet holding one UDP datagram from and to
/// [`PROBE_PORT`], with valid header and UDP checksums.
pub(crate) fn encode(source: IpAddr, destination: IpAddr, probe: &Probe) -> Vec<u8> {
    let from = SocketAddr::new(source, PROBE_PORT);
    let to = SocketAddr::new(destination, PROBE_PORT);
    udp::packet(from, to, &probe.encode())
}

/// The probe in a decrypted packet, with its source and destination, or
/// `None` for every other packet (which goes to the TCP stack).
pub(crate) fn decode(packet: &[u8]) -> Option<(Probe, IpAddr, IpAddr)> {
    let (source, destination, payload) = udp::parse(packet)?;
    if destination.port() != PROBE_PORT || payload.len() != PROBE_LEN {
        return None;
    }
    let probe = Probe::decode(payload).ok()?;
    Some((probe, source.ip(), destination.ip()))
}

/// Encrypt one probe packet and send it on `path` only.
fn send_probe(
    tunn: &mut Tunn,
    underlay: &mut dyn Underlay,
    scratch: &mut [u8],
    path: PathId,
    packet: &[u8],
) {
    if let TunnResult::WriteToNetwork(encrypted) = tunn.encapsulate(packet, scratch) {
        underlay.send_on(path, encrypted);
    }
}

/// Send the pings the underlay wants now. Returns when it next wants one.
/// Nothing is sent before the first handshake: a probe must not be what
/// starts a session.
pub(crate) fn send_due(
    tunn: &mut Tunn,
    underlay: &mut dyn Underlay,
    scratch: &mut [u8],
    route: Option<(IpAddr, IpAddr)>,
    now: Instant,
) -> Option<Instant> {
    let (local, remote) = route?;
    tunn.time_since_last_handshake()?;
    let due = underlay.poll_probes(now);
    for (path, id) in due.pings {
        let packet = encode(local, remote, &Probe { kind: ProbeKind::Ping, id, path });
        send_probe(tunn, underlay, scratch, path, &packet);
    }
    due.next
}

/// Answer a ping on the path it arrived on, or report a pong.
pub(crate) fn receive(
    tunn: &mut Tunn,
    underlay: &mut dyn Underlay,
    scratch: &mut [u8],
    (probe, source, destination): (Probe, IpAddr, IpAddr),
    arrived_on: PathId,
) {
    match probe.pong() {
        Some(pong) => {
            let packet = encode(destination, source, &pong);
            send_probe(tunn, underlay, scratch, arrived_on, &packet);
        }
        None => underlay.on_pong(probe.path, probe.id, Instant::now()),
    }
}
