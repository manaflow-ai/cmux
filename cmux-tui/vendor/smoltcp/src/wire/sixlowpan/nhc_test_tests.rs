use super::*;

#[test]
fn ext_header_nh_inlined() {
    let bytes = [0xe2, 0x3a, 0x6, 0x3, 0x0, 0xff, 0x0, 0x0, 0x0];

    let packet = ExtHeaderPacket::new_checked(&bytes[..]).unwrap();
    assert_eq!(packet.next_header_size(), 1);
    assert_eq!(packet.length(), 6);
    assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
    assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
    assert_eq!(
        packet.next_header(),
        NextHeader::Uncompressed(IpProtocol::Icmpv6)
    );

    assert_eq!(packet.payload(), [0x03, 0x00, 0xff, 0x00, 0x00, 0x00]);
}

#[test]
fn ext_header_nh_elided() {
    let bytes = [0xe3, 0x06, 0x03, 0x00, 0xff, 0x00, 0x00, 0x00];

    let packet = ExtHeaderPacket::new_checked(&bytes[..]).unwrap();
    assert_eq!(packet.next_header_size(), 0);
    assert_eq!(packet.length(), 6);
    assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
    assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
    assert_eq!(packet.next_header(), NextHeader::Compressed);

    assert_eq!(packet.payload(), [0x03, 0x00, 0xff, 0x00, 0x00, 0x00]);
}

#[test]
fn ext_header_emit() {
    let ext_header = ExtHeaderRepr {
        ext_header_id: ExtHeaderId::RoutingHeader,
        next_header: NextHeader::Compressed,
        length: 6,
    };

    let len = ext_header.buffer_len();
    let mut buffer = [0u8; 127];
    let mut packet = ExtHeaderPacket::new_unchecked(&mut buffer[..len]);
    ext_header.emit(&mut packet);

    assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
    assert_eq!(packet.next_header(), NextHeader::Compressed);
    assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
}

#[test]
fn udp_nhc_fields() {
    let bytes = [0xf0, 0x16, 0x2e, 0x22, 0x3d, 0x28, 0xc4];

    let packet = UdpNhcPacket::new_checked(&bytes[..]).unwrap();
    assert_eq!(packet.dispatch_field(), DISPATCH_UDP_HEADER);
    assert_eq!(packet.checksum(), Some(0x28c4));
    assert_eq!(packet.src_port(), 5678);
    assert_eq!(packet.dst_port(), 8765);
}

#[test]
fn udp_emit() {
    let udp = UdpNhcRepr(UdpRepr {
        src_port: 0xf0b1,
        dst_port: 0xf001,
    });

    let payload = b"Hello World!";

    let src_addr = ipv6::Address::UNSPECIFIED;
    let dst_addr = ipv6::Address::UNSPECIFIED;

    let len = udp.header_len() + payload.len();
    let mut buffer = [0u8; 127];
    let mut packet = UdpNhcPacket::new_unchecked(&mut buffer[..len]);
    udp.emit(
        &mut packet,
        &src_addr,
        &dst_addr,
        payload.len(),
        |buf| buf.copy_from_slice(&payload[..]),
        &ChecksumCapabilities::default(),
    );

    assert_eq!(packet.dispatch_field(), DISPATCH_UDP_HEADER);
    assert_eq!(packet.src_port(), 0xf0b1);
    assert_eq!(packet.dst_port(), 0xf001);
    assert_eq!(packet.payload_mut(), b"Hello World!");
}
