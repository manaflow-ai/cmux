//! cmux-wg's single-peer decrypted-packet path (`cmux_wg::fuzzing::ReceivePath`,
//! which calls the driver's own `decrypted::receive_single`): the
//! crypto-key-routing source peek, the path probe and UDP datagram parsers,
//! and the pacer's TCP segment parser with its stale-ACK rewrite.
//!
//! Input: records of `[op u8][delay ms u8][len u16 LE][len bytes]`. Bit 0 of
//! `op` sends the packet as the TCP stack would (building the connection
//! state the receive side reads), otherwise it is received; bit 1 then pops
//! what the pacer lets leave. The clock moves forward by `delay` per record.
//!
//! Checked against this file's own reading of the IP and UDP headers: the
//! source peek is the header's source address; a probe or a datagram is a
//! UDP packet (protocol 17) with the addresses and ports the classifier
//! reported, a probe goes to `PROBE_PORT` and re-encodes to its payload, a
//! datagram rebuilt from its parts parses back to them, and a packet that
//! `udp::parse` reads never reaches the TCP stack. The stale-ACK rewrite
//! keeps the length, touches only the TCP ack, window and checksum fields,
//! and keeps a valid TCP checksum valid (RFC 1624).
#![no_main]

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_transport::probe::PROBE_PORT;
use cmux_wg::fuzzing::{Decrypted, ReceivePath};
use libfuzzer_sys::fuzz_target;

const TCP: u8 = 6;
const UDP: u8 = 17;

/// The transport protocol, the source and destination addresses and the
/// header length, read from the IP header without the crate's parsers.
fn ip_header(packet: &[u8]) -> Option<(u8, IpAddr, IpAddr, usize)> {
    match packet.first()? >> 4 {
        4 if packet.len() >= 20 => {
            let source: [u8; 4] = packet.get(12..16)?.try_into().ok()?;
            let destination: [u8; 4] = packet.get(16..20)?.try_into().ok()?;
            let header = usize::from(packet.first()? & 0x0F) * 4;
            Some((*packet.get(9)?, source.into(), destination.into(), header))
        }
        6 if packet.len() >= 40 => {
            let source: [u8; 16] = packet.get(8..24)?.try_into().ok()?;
            let destination: [u8; 16] = packet.get(24..40)?.try_into().ok()?;
            Some((*packet.get(6)?, source.into(), destination.into(), 40))
        }
        _ => None,
    }
}

/// A UDP packet's source and destination, from its IP and UDP headers.
fn udp_ends(packet: &[u8]) -> (SocketAddr, SocketAddr) {
    let (protocol, source, destination, header) = ip_header(packet).expect("an IP packet");
    assert_eq!(protocol, UDP, "a probe or a datagram is UDP");
    let port = |at: usize| u16::from_be_bytes([packet[header + at], packet[header + at + 1]]);
    (SocketAddr::new(source, port(0)), SocketAddr::new(destination, port(2)))
}

/// The TCP segment and its pseudo-header words (addresses, protocol), when
/// the IP header's lengths cover exactly the packet: the case where the
/// checksum is well defined.
fn tcp_segment(packet: &[u8]) -> Option<(&[u8], Vec<u8>)> {
    match packet.first()? >> 4 {
        4 => {
            let header = usize::from(packet.first()? & 0x0F) * 4;
            let total = usize::from(u16::from_be_bytes([*packet.get(2)?, *packet.get(3)?]));
            if header < 20 || total != packet.len() || *packet.get(9)? != TCP {
                return None;
            }
            Some((packet.get(header..)?, [packet.get(12..20)?, &[0, TCP]].concat()))
        }
        6 => {
            let payload = usize::from(u16::from_be_bytes([*packet.get(4)?, *packet.get(5)?]));
            if packet.len() < 40 || 40 + payload != packet.len() || *packet.get(6)? != TCP {
                return None;
            }
            Some((packet.get(40..)?, [packet.get(8..40)?, &[0, TCP]].concat()))
        }
        _ => None,
    }
}

/// Where the pacer reads the TCP header, whatever the IP lengths say.
fn tcp_offset(packet: &[u8]) -> Option<usize> {
    match packet.first()? >> 4 {
        4 => Some(usize::from(packet.first()? & 0x0F) * 4),
        6 => Some(40),
        _ => None,
    }
}

fn ones_sum(mut sum: u32, bytes: &[u8]) -> u32 {
    let (pairs, remainder) = bytes.as_chunks::<2>();
    for pair in pairs {
        sum += u32::from(u16::from_be_bytes(*pair));
    }
    if let [last] = remainder {
        sum += u32::from(*last) << 8;
    }
    sum
}

/// Whether the TCP checksum of `packet` verifies.
fn tcp_checksum_valid(packet: &[u8]) -> Option<bool> {
    let (segment, pseudo) = tcp_segment(packet)?;
    if segment.len() < 20 || segment.len() > usize::from(u16::MAX) {
        return None;
    }
    let length = (segment.len() as u16).to_be_bytes();
    let mut sum = ones_sum(ones_sum(ones_sum(0, &pseudo), &length), segment);
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    Some(sum == 0xFFFF)
}

fn check_receive(path: &mut ReceivePath, packet: &[u8], at: Duration) {
    if let Some(source) = ReceivePath::source(packet) {
        assert_eq!(ip_header(packet).map(|(_, from, _, _)| from), Some(source));
    }
    let udp = ReceivePath::parse_udp(packet);
    if let Some((source, destination, payload)) = udp {
        let rebuilt = ReceivePath::udp_packet(source, destination, payload);
        assert_eq!(ReceivePath::parse_udp(&rebuilt), Some((source, destination, payload)));
    }
    let to_stack = match path.receive(packet, at) {
        Decrypted::Probe(probe, source, destination) => {
            let (from, to) = udp_ends(packet);
            assert_eq!(to.port(), PROBE_PORT);
            assert_eq!((from.ip(), to.ip()), (source, destination));
            let (_, _, payload) = udp.expect("a probe is a UDP datagram");
            assert_eq!(probe.encode().as_slice(), payload);
            return;
        }
        Decrypted::Datagram(source, destination, payload) => {
            assert_eq!(udp_ends(packet), (source, destination));
            assert_eq!(udp, Some((source, destination, payload)));
            return;
        }
        Decrypted::Stack { packet: to_stack, .. } => to_stack,
    };
    assert!(udp.is_none(), "a UDP datagram reached the TCP stack");
    assert_eq!(to_stack.len(), packet.len());
    if to_stack.as_slice() == packet {
        return;
    }
    let tcp = tcp_offset(packet).expect("only a TCP segment is rewritten");
    for (index, (before, after)) in packet.iter().zip(&to_stack).enumerate() {
        let field = index.checked_sub(tcp);
        let rewritable = matches!(field, Some(8..=11 | 14..=17));
        assert!(before == after || rewritable, "byte {index} changed outside ack/window/checksum");
    }
    if tcp_checksum_valid(packet) == Some(true) {
        assert_eq!(tcp_checksum_valid(&to_stack), Some(true));
    }
}

fuzz_target!(|data: &[u8]| {
    let mut path = ReceivePath::new();
    let mut at = Duration::ZERO;
    let mut rest = data;
    while let Some(([op, delay, l0, l1], tail)) = rest.split_first_chunk::<4>() {
        let len = usize::from(u16::from_le_bytes([*l0, *l1])).min(tail.len());
        let (packet, next) = tail.split_at(len);
        rest = next;
        at += Duration::from_millis(u64::from(*delay));
        if op & 1 == 1 {
            path.send(packet.to_vec(), at);
        } else {
            check_receive(&mut path, packet, at);
        }
        if op & 2 == 2 {
            path.pop(at);
        }
    }
});
