use super::*;

static PACKET_BYTES1: [u8; 24] = [
    0x32, 0x04, 0x00, 0x00, 0x81, 0x79, 0xb7, 0x05, 0x00, 0x00, 0x00, 0x01, 0x27, 0xcf, 0xc0, 0xa5,
    0xe4, 0x3d, 0x69, 0xb3, 0x72, 0x8e, 0xc5, 0xb0,
];

static PACKET_BYTES2: [u8; 24] = [
    0x32, 0x04, 0x00, 0x00, 0xba, 0x8b, 0xd0, 0x60, 0x00, 0x00, 0x00, 0x01, 0xaf, 0xd2, 0xe7, 0xa1,
    0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
];

#[test]
fn test_deconstruct() {
    let packet = Packet::new_unchecked(&PACKET_BYTES1[..]);
    assert_eq!(packet.next_header(), IpProtocol::IpSecEsp);
    assert_eq!(packet.payload_len(), 4);
    assert_eq!(packet.security_parameters_index(), 0x8179b705);
    assert_eq!(packet.sequence_number(), 1);
    assert_eq!(
        packet.integrity_check_value(),
        &[
            0x27, 0xcf, 0xc0, 0xa5, 0xe4, 0x3d, 0x69, 0xb3, 0x72, 0x8e, 0xc5, 0xb0
        ]
    );
}

#[test]
fn test_construct() {
    let mut bytes = vec![0xa5; 24];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_next_header(IpProtocol::IpSecEsp);
    packet.set_payload_len(4);
    packet.clear_reserved();
    packet.set_security_parameters_index(0xba8bd060);
    packet.set_sequence_number(1);
    const ICV: [u8; 12] = [
        0xaf, 0xd2, 0xe7, 0xa1, 0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
    ];
    packet.integrity_check_value_mut().copy_from_slice(&ICV);
    assert_eq!(bytes, PACKET_BYTES2);
}
#[test]
fn test_check_len() {
    assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..10]), Err(_)));
    assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..22]), Err(_)));
    assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..]), Ok(_)));

    // payload_len == 0: reversed ICV range must be rejected, not panic.
    let reversed = [
        0x3b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    ];
    assert!(matches!(Packet::new_checked(&reversed[..]), Err(_)));
    assert!(matches!(
        Repr::parse(&Packet::new_unchecked(&reversed[..])),
        Err(_)
    ));
}

fn packet_repr<'a>() -> Repr<'a> {
    Repr {
        next_header: IpProtocol::IpSecEsp,
        security_parameters_index: 0xba8bd060,
        sequence_number: 1,
        integrity_check_value: &[
            0xaf, 0xd2, 0xe7, 0xa1, 0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
        ],
    }
}

#[test]
fn test_parse() {
    let packet = Packet::new_unchecked(&PACKET_BYTES2[..]);
    assert_eq!(Repr::parse(&packet).unwrap(), packet_repr());
}

#[test]
fn test_emit() {
    let mut bytes = vec![0x17; 24];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet_repr().emit(&mut packet);
    assert_eq!(bytes, PACKET_BYTES2);
}

#[test]
fn test_buffer_len() {
    let header = Packet::new_unchecked(&PACKET_BYTES1[..]);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(repr.buffer_len(), PACKET_BYTES1.len());
}
