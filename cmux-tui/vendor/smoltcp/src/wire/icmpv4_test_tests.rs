use super::*;

static ECHO_PACKET_BYTES: [u8; 12] = [
    0x08, 0x00, 0x8e, 0xfe, 0x12, 0x34, 0xab, 0xcd, 0xaa, 0x00, 0x00, 0xff,
];

static ECHO_DATA_BYTES: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

#[test]
fn test_echo_deconstruct() {
    let packet = Packet::new_unchecked(&ECHO_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::EchoRequest);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.checksum(), 0x8efe);
    assert_eq!(packet.echo_ident(), 0x1234);
    assert_eq!(packet.echo_seq_no(), 0xabcd);
    assert_eq!(packet.data(), &ECHO_DATA_BYTES[..]);
    assert!(packet.verify_checksum());
}

#[test]
fn test_echo_construct() {
    let mut bytes = vec![0xa5; 12];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::EchoRequest);
    packet.set_msg_code(0);
    packet.set_echo_ident(0x1234);
    packet.set_echo_seq_no(0xabcd);
    packet.data_mut().copy_from_slice(&ECHO_DATA_BYTES[..]);
    packet.fill_checksum();
    assert_eq!(&packet.into_inner()[..], &ECHO_PACKET_BYTES[..]);
}

fn echo_packet_repr() -> Repr<'static> {
    Repr::EchoRequest {
        ident: 0x1234,
        seq_no: 0xabcd,
        data: &ECHO_DATA_BYTES,
    }
}

#[test]
fn test_echo_parse() {
    let packet = Packet::new_unchecked(&ECHO_PACKET_BYTES[..]);
    let repr = Repr::parse(&packet, &ChecksumCapabilities::default()).unwrap();
    assert_eq!(repr, echo_packet_repr());
}

#[test]
fn test_echo_emit() {
    let repr = echo_packet_repr();
    let mut bytes = vec![0xa5; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(&mut packet, &ChecksumCapabilities::default());
    assert_eq!(&packet.into_inner()[..], &ECHO_PACKET_BYTES[..]);
}

#[test]
fn test_check_len() {
    let bytes = [0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    assert_eq!(Packet::new_checked(&[]), Err(Error));
    assert_eq!(Packet::new_checked(&bytes[..4]), Err(Error));
    assert!(Packet::new_checked(&bytes[..]).is_ok());
}
