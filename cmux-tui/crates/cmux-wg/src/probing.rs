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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::udp::{IPV4_HEADER, IPV6_HEADER, checksum_ok, sum};

    const UDP: u8 = 17;

    #[test]
    fn probes_round_trip_in_both_families() {
        let ping = Probe { kind: ProbeKind::Ping, id: 42, path: PathId(3) };
        for (source, destination) in [
            ("10.200.0.1".parse().unwrap(), "10.200.0.0".parse().unwrap()),
            ("fdcc::1".parse().unwrap(), "fdcc::".parse().unwrap()),
        ] {
            let packet = encode(source, destination, &ping);
            assert_eq!(decode(&packet), Some((ping, source, destination)));
        }
    }

    #[test]
    fn checksums_verify() {
        let ping = Probe { kind: ProbeKind::Pong, id: 7, path: PathId(1) };
        let v4 = encode("10.0.0.1".parse().unwrap(), "10.0.0.2".parse().unwrap(), &ping);
        assert!(checksum_ok(&v4[..IPV4_HEADER], 0), "IPv4 header checksum");
        let pseudo = sum(&v4[12..20]) + u32::from(UDP) + (v4.len() - 20) as u32;
        assert!(checksum_ok(&v4[IPV4_HEADER..], pseudo), "UDP checksum over IPv4");
        let v6 = encode("fd00::1".parse().unwrap(), "fd00::2".parse().unwrap(), &ping);
        let pseudo = sum(&v6[8..40]) + u32::from(UDP) + (v6.len() - 40) as u32;
        assert!(checksum_ok(&v6[IPV6_HEADER..], pseudo), "UDP checksum over IPv6");
    }

    #[test]
    fn other_packets_are_not_probes() {
        let ping = Probe { kind: ProbeKind::Ping, id: 1, path: PathId(0) };
        let mut packet = encode("10.0.0.1".parse().unwrap(), "10.0.0.2".parse().unwrap(), &ping);
        packet[IPV4_HEADER + 3] ^= 1; // another destination port
        assert_eq!(decode(&packet), None);
        packet[IPV4_HEADER + 3] ^= 1;
        packet[9] = 6; // TCP
        assert_eq!(decode(&packet), None);
        assert_eq!(decode(&[]), None);
        assert_eq!(decode(&[0x45; 10]), None);
    }

    #[test]
    fn probes_go_to_the_peer_address_when_the_config_names_one() {
        let pair = crate::testing::config_pair("127.0.0.1:51820".parse().unwrap());
        assert_eq!(probe_route(&pair.client), Some((pair.client_v4, pair.server_v4)));
        let mut unnamed = pair.client.clone();
        unnamed.peer_addresses.clear();
        let base: IpAddr = "10.200.0.0".parse().unwrap();
        assert_eq!(probe_route(&unnamed), Some((pair.client_v4, base)), "the network base");
    }
}
