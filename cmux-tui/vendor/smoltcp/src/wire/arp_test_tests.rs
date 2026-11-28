use super::*;

static PACKET_BYTES: [u8; 28] = [
    0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x21, 0x22,
    0x23, 0x24, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x41, 0x42, 0x43, 0x44,
];

#[test]
fn test_deconstruct() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    assert_eq!(packet.hardware_type(), Hardware::Ethernet);
    assert_eq!(packet.protocol_type(), Protocol::Ipv4);
    assert_eq!(packet.hardware_len(), 6);
    assert_eq!(packet.protocol_len(), 4);
    assert_eq!(packet.operation(), Operation::Request);
    assert_eq!(
        packet.source_hardware_addr(),
        &[0x11, 0x12, 0x13, 0x14, 0x15, 0x16]
    );
    assert_eq!(packet.source_protocol_addr(), &[0x21, 0x22, 0x23, 0x24]);
    assert_eq!(
        packet.target_hardware_addr(),
        &[0x31, 0x32, 0x33, 0x34, 0x35, 0x36]
    );
    assert_eq!(packet.target_protocol_addr(), &[0x41, 0x42, 0x43, 0x44]);
}

#[test]
fn test_construct() {
    let mut bytes = vec![0xa5; 28];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_hardware_type(Hardware::Ethernet);
    packet.set_protocol_type(Protocol::Ipv4);
    packet.set_hardware_len(6);
    packet.set_protocol_len(4);
    packet.set_operation(Operation::Request);
    packet.set_source_hardware_addr(&[0x11, 0x12, 0x13, 0x14, 0x15, 0x16]);
    packet.set_source_protocol_addr(&[0x21, 0x22, 0x23, 0x24]);
    packet.set_target_hardware_addr(&[0x31, 0x32, 0x33, 0x34, 0x35, 0x36]);
    packet.set_target_protocol_addr(&[0x41, 0x42, 0x43, 0x44]);
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}

fn packet_repr() -> Repr {
    Repr::EthernetIpv4 {
        operation: Operation::Request,
        source_hardware_addr: EthernetAddress::from_bytes(&[0x11, 0x12, 0x13, 0x14, 0x15, 0x16]),
        source_protocol_addr: Ipv4Address::from_octets([0x21, 0x22, 0x23, 0x24]),
        target_hardware_addr: EthernetAddress::from_bytes(&[0x31, 0x32, 0x33, 0x34, 0x35, 0x36]),
        target_protocol_addr: Ipv4Address::from_octets([0x41, 0x42, 0x43, 0x44]),
    }
}

#[test]
fn test_parse() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    let repr = Repr::parse(&packet).unwrap();
    assert_eq!(repr, packet_repr());
}

#[test]
fn test_emit() {
    let mut bytes = vec![0xa5; 28];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet_repr().emit(&mut packet);
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}
