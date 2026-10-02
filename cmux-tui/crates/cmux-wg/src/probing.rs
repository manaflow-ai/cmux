//! Path probes inside the WireGuard session (transport.md section 4).
//!
//! A probe is a tiny overlay UDP packet to [`PROBE_PORT`] carrying a
//! [`Probe`]. WireGuard encrypts and authenticates it like any packet, so it
//! needs no key of its own. The driver intercepts probes before the TCP
//! stack: a ping is answered with a pong on the path it arrived on, and a
//! pong is reported to the underlay, whose selector learns that path's RTT.
//! Probes are never activity: they run only while the session carries
//! traffic, and they do not keep it awake.

use std::net::IpAddr;

use boringtun::noise::{Tunn, TunnResult};
use cmux_transport::probe::{PROBE_LEN, PROBE_PORT};
use cmux_transport::{PathId, Probe, ProbeKind};
use tokio::time::Instant;

use crate::config::WgConfig;
use crate::underlay::Underlay;

const IPV4_HEADER: usize = 20;
const IPV6_HEADER: usize = 40;
const UDP_HEADER: usize = 8;
const UDP: u8 = 17;
const HOP_LIMIT: u8 = 64;

/// The overlay addresses probes travel between: this side's tunnel address
/// and, in the same family, the base address of the peer's first allowed
/// network. The receiver intercepts probes by port and magic before routing,
/// so the destination only has to be a plausible address of the peer.
pub(crate) fn probe_route(config: &WgConfig) -> Option<(IpAddr, IpAddr)> {
    config.addresses.iter().find_map(|local| {
        config
            .allowed_ips
            .iter()
            .find(|network| network.network_address().is_ipv4() == local.address.is_ipv4())
            .map(|network| (local.address, network.network_address()))
    })
}

fn checksum_add(mut sum: u32, bytes: &[u8]) -> u32 {
    for pair in bytes.chunks(2) {
        let word = u16::from_be_bytes([pair[0], *pair.get(1).unwrap_or(&0)]);
        sum += u32::from(word);
    }
    sum
}

fn checksum_finish(mut sum: u32) -> u16 {
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

/// An IPv4 or IPv6 packet holding one UDP datagram from and to
/// [`PROBE_PORT`], with valid header and UDP checksums.
pub(crate) fn encode(source: IpAddr, destination: IpAddr, probe: &Probe) -> Vec<u8> {
    let payload = probe.encode();
    let udp_len = UDP_HEADER + PROBE_LEN;
    let mut udp = Vec::with_capacity(udp_len);
    udp.extend_from_slice(&PROBE_PORT.to_be_bytes());
    udp.extend_from_slice(&PROBE_PORT.to_be_bytes());
    udp.extend_from_slice(&(udp_len as u16).to_be_bytes());
    udp.extend_from_slice(&[0, 0]);
    udp.extend_from_slice(&payload);
    let mut pseudo = 0u32;
    let mut packet = match (source, destination) {
        (IpAddr::V4(source), IpAddr::V4(destination)) => {
            let mut header = [0u8; IPV4_HEADER];
            header[0] = 0x45;
            header[2..4].copy_from_slice(&((IPV4_HEADER + udp_len) as u16).to_be_bytes());
            header[8] = HOP_LIMIT;
            header[9] = UDP;
            header[12..16].copy_from_slice(&source.octets());
            header[16..20].copy_from_slice(&destination.octets());
            let sum = checksum_finish(checksum_add(0, &header));
            header[10..12].copy_from_slice(&sum.to_be_bytes());
            pseudo = checksum_add(pseudo, &header[12..20]);
            header.to_vec()
        }
        (IpAddr::V6(source), IpAddr::V6(destination)) => {
            let mut header = [0u8; IPV6_HEADER];
            header[0] = 0x60;
            header[4..6].copy_from_slice(&(udp_len as u16).to_be_bytes());
            header[6] = UDP;
            header[7] = HOP_LIMIT;
            header[8..24].copy_from_slice(&source.octets());
            header[24..40].copy_from_slice(&destination.octets());
            pseudo = checksum_add(pseudo, &header[8..40]);
            header.to_vec()
        }
        _ => return Vec::new(),
    };
    pseudo += u32::from(UDP) + udp_len as u32;
    let sum = match checksum_finish(checksum_add(pseudo, &udp)) {
        0 => 0xFFFF,
        sum => sum,
    };
    udp[6..8].copy_from_slice(&sum.to_be_bytes());
    packet.extend_from_slice(&udp);
    packet
}

/// The probe in a decrypted packet, with its source and destination, or
/// `None` for every other packet (which goes to the TCP stack).
pub(crate) fn decode(packet: &[u8]) -> Option<(Probe, IpAddr, IpAddr)> {
    let (source, destination, udp): (IpAddr, IpAddr, &[u8]) = match packet.first()? >> 4 {
        4 => {
            let header_len = usize::from(packet[0] & 0x0F) * 4;
            if packet.len() < header_len.max(IPV4_HEADER) || packet[9] != UDP {
                return None;
            }
            let source: [u8; 4] = packet[12..16].try_into().ok()?;
            let destination: [u8; 4] = packet[16..20].try_into().ok()?;
            (source.into(), destination.into(), &packet[header_len..])
        }
        6 => {
            if packet.len() < IPV6_HEADER || packet[6] != UDP {
                return None;
            }
            let source: [u8; 16] = packet[8..24].try_into().ok()?;
            let destination: [u8; 16] = packet[24..40].try_into().ok()?;
            (source.into(), destination.into(), &packet[IPV6_HEADER..])
        }
        _ => return None,
    };
    if udp.len() != UDP_HEADER + PROBE_LEN || udp[2..4] != PROBE_PORT.to_be_bytes() {
        return None;
    }
    let probe = Probe::decode(&udp[UDP_HEADER..]).ok()?;
    Some((probe, source, destination))
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

    fn ones_complement_ok(bytes: &[u8], seed: u32) -> bool {
        checksum_finish(checksum_add(seed, bytes)) == 0
    }

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
        assert!(ones_complement_ok(&v4[..IPV4_HEADER], 0), "IPv4 header checksum");
        let pseudo = checksum_add(0, &v4[12..20]) + u32::from(UDP) + (v4.len() - 20) as u32;
        assert!(ones_complement_ok(&v4[IPV4_HEADER..], pseudo), "UDP checksum over IPv4");
        let v6 = encode("fd00::1".parse().unwrap(), "fd00::2".parse().unwrap(), &ping);
        let pseudo = checksum_add(0, &v6[8..40]) + u32::from(UDP) + (v6.len() - 40) as u32;
        assert!(ones_complement_ok(&v6[IPV6_HEADER..], pseudo), "UDP checksum over IPv6");
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
}
