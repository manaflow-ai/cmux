use super::*;
use crate::wire::{IpProtocol, Ipv6Address, Ipv6Repr};

const MOCK_IP_ADDR_1: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
const MOCK_IP_ADDR_2: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);

static ECHO_PACKET_BYTES: [u8; 12] = [
    0x80, 0x00, 0x19, 0xb3, 0x12, 0x34, 0xab, 0xcd, 0xaa, 0x00, 0x00, 0xff,
];

static ECHO_PACKET_PAYLOAD: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

static PKT_TOO_BIG_BYTES: [u8; 60] = [
    0x02, 0x00, 0x0f, 0xc9, 0x00, 0x00, 0x05, 0xdc, 0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40,
    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x12, 0x4d, 0xaa, 0x00, 0x00, 0xff,
];

static PKT_TOO_BIG_IP_PAYLOAD: [u8; 52] = [
    0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x12, 0x4d,
    0xaa, 0x00, 0x00, 0xff,
];

static PKT_TOO_BIG_UDP_PAYLOAD: [u8; 12] = [
    0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x12, 0x4d, 0xaa, 0x00, 0x00, 0xff,
];

fn echo_packet_repr() -> Repr<'static> {
    Repr::EchoRequest {
        ident: 0x1234,
        seq_no: 0xabcd,
        data: &ECHO_PACKET_PAYLOAD,
    }
}

fn too_big_packet_repr() -> Repr<'static> {
    Repr::PktTooBig {
        mtu: 1500,
        header: Ipv6Repr {
            src_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            dst_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2),
            next_header: IpProtocol::Udp,
            payload_len: 12,
            hop_limit: 0x40,
        },
        data: &PKT_TOO_BIG_UDP_PAYLOAD,
    }
}

#[test]
fn test_echo_deconstruct() {
    let packet = Packet::new_unchecked(&ECHO_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::EchoRequest);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.checksum(), 0x19b3);
    assert_eq!(packet.echo_ident(), 0x1234);
    assert_eq!(packet.echo_seq_no(), 0xabcd);
    assert_eq!(packet.payload(), &ECHO_PACKET_PAYLOAD[..]);
    assert!(packet.verify_checksum(&MOCK_IP_ADDR_1, &MOCK_IP_ADDR_2));
    assert!(!packet.msg_type().is_error());
}

#[test]
fn test_echo_construct() {
    let mut bytes = vec![0xa5; 12];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::EchoRequest);
    packet.set_msg_code(0);
    packet.set_echo_ident(0x1234);
    packet.set_echo_seq_no(0xabcd);
    packet
        .payload_mut()
        .copy_from_slice(&ECHO_PACKET_PAYLOAD[..]);
    packet.fill_checksum(&MOCK_IP_ADDR_1, &MOCK_IP_ADDR_2);
    assert_eq!(&*packet.into_inner(), &ECHO_PACKET_BYTES[..]);
}

#[test]
fn test_echo_repr_parse() {
    let packet = Packet::new_unchecked(&ECHO_PACKET_BYTES[..]);
    let repr = Repr::parse(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &packet,
        &ChecksumCapabilities::default(),
    )
    .unwrap();
    assert_eq!(repr, echo_packet_repr());
}

#[test]
fn test_echo_emit() {
    let repr = echo_packet_repr();
    let mut bytes = vec![0xa5; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &ECHO_PACKET_BYTES[..]);
}

#[test]
fn test_too_big_deconstruct() {
    let packet = Packet::new_unchecked(&PKT_TOO_BIG_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::PktTooBig);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.checksum(), 0x0fc9);
    assert_eq!(packet.pkt_too_big_mtu(), 1500);
    assert_eq!(packet.payload(), &PKT_TOO_BIG_IP_PAYLOAD[..]);
    assert!(packet.verify_checksum(&MOCK_IP_ADDR_1, &MOCK_IP_ADDR_2));
    assert!(packet.msg_type().is_error());
}

#[test]
fn test_too_big_construct() {
    let mut bytes = vec![0xa5; 60];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::PktTooBig);
    packet.set_msg_code(0);
    packet.set_pkt_too_big_mtu(1500);
    packet
        .payload_mut()
        .copy_from_slice(&PKT_TOO_BIG_IP_PAYLOAD[..]);
    packet.fill_checksum(&MOCK_IP_ADDR_1, &MOCK_IP_ADDR_2);
    assert_eq!(&*packet.into_inner(), &PKT_TOO_BIG_BYTES[..]);
}

#[test]
fn test_too_big_repr_parse() {
    let packet = Packet::new_unchecked(&PKT_TOO_BIG_BYTES[..]);
    let repr = Repr::parse(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &packet,
        &ChecksumCapabilities::default(),
    )
    .unwrap();
    assert_eq!(repr, too_big_packet_repr());
}

#[test]
fn test_too_big_emit() {
    let repr = too_big_packet_repr();
    let mut bytes = vec![0xa5; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &PKT_TOO_BIG_BYTES[..]);
}

#[test]
fn test_buffer_length_is_truncated_to_mtu() {
    let repr = Repr::PktTooBig {
        mtu: 1280,
        header: Ipv6Repr {
            src_addr: Ipv6Address::UNSPECIFIED,
            dst_addr: Ipv6Address::UNSPECIFIED,
            next_header: IpProtocol::Tcp,
            hop_limit: 64,
            payload_len: 1280,
        },
        data: &vec![0; 9999],
    };
    assert_eq!(repr.buffer_len(), 1280 - IPV6_HEADER_LEN);
}

#[test]
fn test_mtu_truncated_payload_roundtrip() {
    let ip_packet_repr = Ipv6Repr {
        src_addr: Ipv6Address::UNSPECIFIED,
        dst_addr: Ipv6Address::UNSPECIFIED,
        next_header: IpProtocol::Tcp,
        hop_limit: 64,
        payload_len: IPV6_MIN_MTU - IPV6_HEADER_LEN,
    };
    let mut ip_packet = Ipv6Packet::new_unchecked(vec![0; IPV6_MIN_MTU]);
    ip_packet_repr.emit(&mut ip_packet);

    let repr1 = Repr::PktTooBig {
        mtu: IPV6_MIN_MTU as u32,
        header: ip_packet_repr,
        data: &ip_packet.as_ref()[IPV6_HEADER_LEN..],
    };
    // this is needed to make sure roundtrip gives the same value
    // it is not needed for ensuring the correct bytes get emitted
    let repr1 = Repr::PktTooBig {
        mtu: IPV6_MIN_MTU as u32,
        header: ip_packet_repr,
        data: &ip_packet.as_ref()[IPV6_HEADER_LEN..repr1.buffer_len() - field::UNUSED.end],
    };
    let mut data = vec![0; MAX_ERROR_PACKET_LEN];
    let mut packet = Packet::new_unchecked(&mut data);
    repr1.emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );

    let packet = Packet::new_unchecked(&data);
    let repr2 = Repr::parse(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &packet,
        &ChecksumCapabilities::default(),
    )
    .unwrap();

    assert_eq!(repr1, repr2);
}

#[test]
fn test_truncated_payload_ipv6_header_parse_fails() {
    let repr = too_big_packet_repr();
    let mut bytes = vec![0xa5; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    let packet = Packet::new_unchecked(&bytes[..field::HEADER_END + IPV6_HEADER_LEN - 1]);
    assert!(
        Repr::parse(
            &MOCK_IP_ADDR_1,
            &MOCK_IP_ADDR_2,
            &packet,
            &ChecksumCapabilities::ignored(),
        )
        .is_err()
    );
}
