//! IPv4 and IPv6 packets that carry one UDP datagram, built and parsed by
//! the driver itself (the TCP stack has no UDP sockets): path probes and the
//! datagram service.

use std::net::{IpAddr, SocketAddr};

pub(crate) const IPV4_HEADER: usize = 20;
pub(crate) const IPV6_HEADER: usize = 40;
pub(crate) const UDP_HEADER: usize = 8;
const UDP: u8 = 17;
const HOP_LIMIT: u8 = 64;

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

/// An IPv4 or IPv6 packet holding one UDP datagram, with valid header and
/// UDP checksums. Empty when the two addresses are of different families.
pub(crate) fn packet(source: SocketAddr, destination: SocketAddr, payload: &[u8]) -> Vec<u8> {
    let udp_len = UDP_HEADER + payload.len();
    let mut udp = Vec::with_capacity(udp_len);
    udp.extend_from_slice(&source.port().to_be_bytes());
    udp.extend_from_slice(&destination.port().to_be_bytes());
    udp.extend_from_slice(&(udp_len as u16).to_be_bytes());
    udp.extend_from_slice(&[0, 0]);
    udp.extend_from_slice(payload);
    let mut pseudo = 0u32;
    let mut packet = match (source.ip(), destination.ip()) {
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

/// The source, destination and payload of a UDP datagram in a decrypted
/// IPv4 or IPv6 packet, or `None` for any other packet.
pub(crate) fn parse(packet: &[u8]) -> Option<(SocketAddr, SocketAddr, &[u8])> {
    let (source, destination, udp): (IpAddr, IpAddr, &[u8]) = match packet.first()? >> 4 {
        4 => {
            let header_len = usize::from(packet[0] & 0x0F) * 4;
            if header_len < IPV4_HEADER || packet.len() < header_len || packet[9] != UDP {
                return None;
            }
            // Fragments (more-fragments set, or a non-zero offset) are not
            // whole datagrams: this stack never reassembles them.
            if u16::from_be_bytes([packet[6], packet[7]]) & 0x3FFF != 0 {
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
    if udp.len() < UDP_HEADER {
        return None;
    }
    let length = usize::from(u16::from_be_bytes([udp[4], udp[5]]));
    if length < UDP_HEADER || length > udp.len() {
        return None;
    }
    let source_port = u16::from_be_bytes([udp[0], udp[1]]);
    let destination_port = u16::from_be_bytes([udp[2], udp[3]]);
    Some((
        SocketAddr::new(source, source_port),
        SocketAddr::new(destination, destination_port),
        &udp[UDP_HEADER..length],
    ))
}

#[cfg(test)]
pub(crate) fn checksum_ok(bytes: &[u8], seed: u32) -> bool {
    checksum_finish(checksum_add(seed, bytes)) == 0
}

#[cfg(test)]
pub(crate) fn sum(bytes: &[u8]) -> u32 {
    checksum_add(0, bytes)
}
