use super::*;
use std::os::unix::net::UnixStream;

#[test]
fn socket_departure_receipts_bound_storage_and_preserve_success_metadata() {
    let (mut stream, _peer_stream) = UnixStream::pair().unwrap();
    let peer = UdpSocket::bind("127.0.0.1:0").unwrap();
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let mut reader = FrameReader::default();
    let mut carrier = SocketCarrier::new(
        &mut stream,
        &mut reader,
        None,
        DatagramOut::Udp { sock: socket, peer: peer.local_addr().unwrap() },
    );
    let header = DatagramHeader {
        flags: 0,
        kind: cmux_rd_proto::DatagramKind::Video,
        stream: 9,
        frame: 20,
        index: 0,
        count: 1,
        fec_count: 0,
        transport_seq: 200,
    };
    let packet = header.encode();
    let before = crate::clock::now_ns() / 1000;
    for _ in 0..MAX_DEPARTURE_RECEIPTS + 2 {
        carrier.send_datagram(&packet).unwrap();
    }
    let after = crate::clock::now_ns() / 1000;
    assert_eq!(carrier.departure_overflows(), 2);
    let mut receipts = Vec::new();
    carrier.drain_departures(&mut receipts);
    assert_eq!(receipts.len(), MAX_DEPARTURE_RECEIPTS);
    assert!(receipts.iter().all(|r| r.header == header
        && r.wire_bytes == packet.len()
        && (before..=after).contains(&r.departed_us)));
    // An oversized UDP send fails, and cannot be counted as a departure.
    let mut oversized = packet.to_vec();
    oversized.resize(65_536, 0);
    assert!(carrier.send_datagram(&oversized).is_err());
    receipts.clear();
    carrier.drain_departures(&mut receipts);
    assert!(receipts.is_empty());

    let input = DatagramHeader { kind: cmux_rd_proto::DatagramKind::Input, ..header }.encode();
    carrier.send_datagram(&input).unwrap();
    receipts.clear();
    carrier.drain_departures(&mut receipts);
    assert!(receipts.is_empty(), "control/input datagrams never become media receipts");
}
