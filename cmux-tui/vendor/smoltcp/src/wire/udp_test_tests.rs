use super::*;
#[cfg(feature = "proto-ipv4")]
use crate::wire::Ipv4Address;

#[cfg(feature = "proto-ipv4")]
const SRC_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
#[cfg(feature = "proto-ipv4")]
const DST_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 2);

#[cfg(feature = "proto-ipv4")]
static PACKET_BYTES: [u8; 12] = [
    0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x12, 0x4d, 0xaa, 0x00, 0x00, 0xff,
];

#[cfg(feature = "proto-ipv4")]
static NO_CHECKSUM_PACKET: [u8; 12] = [
    0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x00, 0x00, 0xaa, 0x00, 0x00, 0xff,
];

#[cfg(feature = "proto-ipv4")]
static PAYLOAD_BYTES: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_deconstruct() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    assert_eq!(packet.src_port(), 48896);
    assert_eq!(packet.dst_port(), 53);
    assert_eq!(packet.len(), 12);
    assert_eq!(packet.checksum(), 0x124d);
    assert_eq!(packet.payload(), &PAYLOAD_BYTES[..]);
    assert!(packet.verify_checksum(&SRC_ADDR.into(), &DST_ADDR.into()));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_construct() {
    let mut bytes = vec![0xa5; 12];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_src_port(48896);
    packet.set_dst_port(53);
    packet.set_len(12);
    packet.set_checksum(0xffff);
    packet.payload_mut().copy_from_slice(&PAYLOAD_BYTES[..]);
    packet.fill_checksum(&SRC_ADDR.into(), &DST_ADDR.into());
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}

#[test]
fn test_impossible_len() {
    let mut bytes = vec![0; 12];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_len(4);
    assert_eq!(packet.check_len(), Err(Error));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_zero_checksum() {
    let mut bytes = vec![0; 8];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_src_port(1);
    packet.set_dst_port(31881);
    packet.set_len(8);
    packet.fill_checksum(&SRC_ADDR.into(), &DST_ADDR.into());
    assert_eq!(packet.checksum(), 0xffff);
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_no_checksum() {
    let mut bytes = vec![0; 8];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_src_port(1);
    packet.set_dst_port(31881);
    packet.set_len(8);
    packet.set_checksum(0);
    assert!(packet.verify_checksum(&SRC_ADDR.into(), &DST_ADDR.into()));
}

#[cfg(feature = "proto-ipv4")]
fn packet_repr() -> Repr {
    Repr {
        src_port: 48896,
        dst_port: 53,
    }
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_parse() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    let repr = Repr::parse(
        &packet,
        &SRC_ADDR.into(),
        &DST_ADDR.into(),
        &ChecksumCapabilities::default(),
    )
    .unwrap();
    assert_eq!(repr, packet_repr());
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_emit() {
    let repr = packet_repr();
    let mut bytes = vec![0xa5; repr.header_len() + PAYLOAD_BYTES.len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(
        &mut packet,
        &SRC_ADDR.into(),
        &DST_ADDR.into(),
        PAYLOAD_BYTES.len(),
        |payload| payload.copy_from_slice(&PAYLOAD_BYTES),
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_checksum_omitted() {
    let packet = Packet::new_unchecked(&NO_CHECKSUM_PACKET[..]);
    let repr = Repr::parse(
        &packet,
        &SRC_ADDR.into(),
        &DST_ADDR.into(),
        &ChecksumCapabilities::default(),
    )
    .unwrap();
    assert_eq!(repr, packet_repr());
}
