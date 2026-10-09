//! Unit tests of the pacer in `pacing.rs`.
use std::net::Ipv4Addr;

use super::*;

const LOCAL: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 1);
const REMOTE: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 2);
const ACK: u8 = 0x10;

/// An IPv4 TCP packet from `src` to `dst` (checksums are not checked).
fn tcp(
    src: (Ipv4Addr, u16),
    dst: (Ipv4Addr, u16),
    seq: u32,
    ack: u32,
    flags: u8,
    payload: usize,
) -> Vec<u8> {
    let total = 20 + 20 + payload;
    let mut packet = vec![0u8; total];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(total as u16).to_be_bytes());
    packet[9] = TCP;
    packet[12..16].copy_from_slice(&src.0.octets());
    packet[16..20].copy_from_slice(&dst.0.octets());
    packet[20..22].copy_from_slice(&src.1.to_be_bytes());
    packet[22..24].copy_from_slice(&dst.1.to_be_bytes());
    packet[24..28].copy_from_slice(&seq.to_be_bytes());
    packet[28..32].copy_from_slice(&ack.to_be_bytes());
    packet[32] = 5 << 4;
    packet[33] = flags;
    packet
}

fn out(port: u16, seq: u32, payload: usize) -> Vec<u8> {
    tcp((LOCAL, port), (REMOTE, 4100), seq, 0, ACK, payload)
}

fn ack_for(port: u16, ack: u32) -> Vec<u8> {
    tcp((REMOTE, 4100), (LOCAL, port), 0, ack, ACK, 0)
}

#[test]
fn a_connection_is_paced_at_twice_its_flight_per_rtt_after_one_sample() {
    let mut pacer = Pacer::default();
    let start = Instant::now();
    pacer.push(out(50000, 0, 1160), start);
    assert!(pacer.pop(start).unwrap().is_some(), "unpaced before an RTT sample");
    let rtt = Duration::from_millis(20);
    pacer.received(&ack_for(50000, 1160), start + rtt);

    // Twenty segments queued at once leave spread out, not in one burst.
    let now = start + rtt;
    for index in 0..20u32 {
        pacer.push(out(50000, 1160 * (index + 1), 1160), now);
    }
    let mut departures = Vec::new();
    let mut clock = now;
    while pacer.queued > 0 {
        match pacer.pop(clock) {
            Ok(Some(_)) => departures.push(clock - now),
            Ok(None) => break,
            Err(at) => clock = at,
        }
    }
    assert_eq!(departures.len(), 20);
    let spread = *departures.last().unwrap();
    assert!(spread > Duration::from_millis(3), "the burst was not spread: {spread:?}");
    assert!(spread < rtt, "pacing must not slow a full window below one per RTT: {spread:?}");
}

/// A bulk upload and bulk datagrams share the bulk class by bytes, so a
/// backlog in the driver never starves the datagrams behind the upload.
#[test]
fn bulk_connections_and_bulk_datagrams_share_the_bulk_class_by_bytes() {
    let mut pacer = Pacer::default();
    let now = Instant::now();
    for index in 0..200u32 {
        pacer.push(out(50000, 1160 * index, 1160), now);
    }
    for _ in 0..100 {
        pacer.push_datagram(vec![0x45; 600], Priority::Bulk, now);
    }
    let (mut upload, mut datagrams) = (0usize, 0usize);
    for _ in 0..90 {
        let packet = pacer.pop(now).unwrap().unwrap();
        if segment(&packet).is_some() {
            upload += packet.len();
        } else {
            datagrams += packet.len();
        }
    }
    assert!(datagrams > 0, "bulk datagrams starved behind the upload");
    assert!(upload.abs_diff(datagrams) <= 1200, "upload {upload} B, datagrams {datagrams} B");

    // A class with nothing queued banks no credit: once the datagrams are
    // gone the upload takes the whole class, and new datagrams start even.
    while !pacer.bulk.is_empty() {
        pacer.pop(now).unwrap().unwrap();
    }
    for _ in 0..20 {
        assert!(segment(&pacer.pop(now).unwrap().unwrap()).is_some());
    }
    pacer.push_datagram(vec![0x45; 600], Priority::Bulk, now);
    let mut next = Vec::new();
    for _ in 0..3 {
        next.push(segment(&pacer.pop(now).unwrap().unwrap()).is_some());
    }
    assert!(next.contains(&false), "a new bulk datagram waits at most one segment: {next:?}");
}
