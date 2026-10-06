//! Unit tests of the pacer in `pacing.rs`.
use std::net::Ipv4Addr;

use super::*;

const LOCAL: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 1);
const REMOTE: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 2);
const SYN: u8 = 0x02;
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
fn segments_parse_with_syn_and_payload_lengths() {
    let syn = tcp((LOCAL, 50000), (REMOTE, 4100), 7, 0, SYN, 0);
    let parsed = segment(&syn).unwrap();
    assert_eq!(parsed.len, 1, "SYN occupies one sequence number");
    assert_eq!(parsed.ack, None);
    let data = out(50000, 100, 1160);
    let parsed = segment(&data).unwrap();
    assert_eq!((parsed.seq, parsed.len, parsed.source.1), (100, 1160, 50000));
    assert_eq!(segment(&[0x45; 10]), None);
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

#[test]
fn the_shortest_queue_goes_first() {
    let mut pacer = Pacer::default();
    let now = Instant::now();
    for index in 0..50u32 {
        pacer.push(out(50000, 1160 * index, 1160), now);
    }
    pacer.push(out(50001, 0, 1), now);
    let first = pacer.pop(now).unwrap().unwrap();
    assert_eq!(segment(&first).unwrap().source.1, 50001, "the keystroke leaves first");
}

#[test]
fn a_retransmission_is_not_timed() {
    let mut connection = Connection::new(Instant::now());
    let start = Instant::now();
    let first = segment(&out(50000, 0, 1000)).unwrap();
    connection.sent(&first, 1040, start);
    connection.sent(&first, 1040, start + Duration::from_millis(500));
    connection.acked(1000, start + Duration::from_millis(510));
    assert_eq!(connection.srtt, None, "an ambiguous ACK gives no sample");
}

#[test]
fn other_packets_leave_first_and_unpaced() {
    let mut pacer = Pacer::default();
    let now = Instant::now();
    pacer.push(out(50000, 0, 1160), now);
    pacer.push(vec![0x45; 28], now);
    let first = pacer.pop(now).unwrap().unwrap();
    assert_eq!(first, vec![0x45; 28]);
}

#[test]
fn classes_leave_in_strict_priority() {
    let mut pacer = Pacer::default();
    let now = Instant::now();
    // A bulk connection (more than INTERACTIVE_QUEUE segments, unpaced
    // before its first RTT sample).
    for index in 0..6u32 {
        pacer.push(out(50000, 1160 * index, 1160), now);
    }
    let datagram = |byte: u8| vec![0x45, byte];
    pacer.push_datagram(datagram(3), Priority::Bulk, now);
    pacer.push_datagram(datagram(2), Priority::Media, now);
    pacer.push_datagram(datagram(1), Priority::Interactive, now);
    let mut order = Vec::new();
    while let Ok(Some(packet)) = pacer.pop(now) {
        order.push(if segment(&packet).is_some() { 0 } else { packet[1] });
    }
    // The bulk class is shared by bytes: after one segment the connection is
    // ahead, so the bulk datagram goes next.
    assert_eq!(order, vec![1, 2, 0, 3, 0, 0, 0, 0, 0], "interactive, media, then bulk shared");
}

#[test]
fn stale_media_never_leaves() {
    let mut pacer = Pacer::default();
    let start = Instant::now();
    pacer.push_datagram(vec![0x45, 1], Priority::Media, start);
    let late = start + MEDIA_MAX_AGE + Duration::from_millis(1);
    assert_eq!(pacer.pop(late), Ok(None));
    assert!(!pacer.has_queued());
}

#[test]
fn a_datagram_flood_never_blocks_the_tcp_stack() {
    let mut pacer = Pacer::default();
    let now = Instant::now();
    for _ in 0..10_000 {
        pacer.push_datagram(vec![0x45, 9], Priority::Bulk, now);
        pacer.push_datagram(vec![0x45, 8], Priority::Media, now);
    }
    assert!(pacer.has_room(), "datagrams do not count toward the stack's limit");
    assert_eq!(pacer.bulk.len(), MAX_DATAGRAMS);
    assert_eq!(pacer.media.len(), MAX_DATAGRAMS);
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
