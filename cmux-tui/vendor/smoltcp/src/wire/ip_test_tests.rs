#![allow(unused)]

use super::*;
use crate::wire::{IpAddress, IpCidr, IpProtocol, IpRepr};
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Ipv4Address, Ipv4Repr};

#[test]
#[cfg(feature = "proto-ipv4")]
fn to_prefix_len_ipv4() {
    fn test_eq<A: Into<Address>>(prefix_len: u8, mask: A) {
        assert_eq!(Some(prefix_len), mask.into().prefix_len());
    }

    test_eq(0, Ipv4Address::new(0, 0, 0, 0));
    test_eq(1, Ipv4Address::new(128, 0, 0, 0));
    test_eq(2, Ipv4Address::new(192, 0, 0, 0));
    test_eq(3, Ipv4Address::new(224, 0, 0, 0));
    test_eq(4, Ipv4Address::new(240, 0, 0, 0));
    test_eq(5, Ipv4Address::new(248, 0, 0, 0));
    test_eq(6, Ipv4Address::new(252, 0, 0, 0));
    test_eq(7, Ipv4Address::new(254, 0, 0, 0));
    test_eq(8, Ipv4Address::new(255, 0, 0, 0));
    test_eq(9, Ipv4Address::new(255, 128, 0, 0));
    test_eq(10, Ipv4Address::new(255, 192, 0, 0));
    test_eq(11, Ipv4Address::new(255, 224, 0, 0));
    test_eq(12, Ipv4Address::new(255, 240, 0, 0));
    test_eq(13, Ipv4Address::new(255, 248, 0, 0));
    test_eq(14, Ipv4Address::new(255, 252, 0, 0));
    test_eq(15, Ipv4Address::new(255, 254, 0, 0));
    test_eq(16, Ipv4Address::new(255, 255, 0, 0));
    test_eq(17, Ipv4Address::new(255, 255, 128, 0));
    test_eq(18, Ipv4Address::new(255, 255, 192, 0));
    test_eq(19, Ipv4Address::new(255, 255, 224, 0));
    test_eq(20, Ipv4Address::new(255, 255, 240, 0));
    test_eq(21, Ipv4Address::new(255, 255, 248, 0));
    test_eq(22, Ipv4Address::new(255, 255, 252, 0));
    test_eq(23, Ipv4Address::new(255, 255, 254, 0));
    test_eq(24, Ipv4Address::new(255, 255, 255, 0));
    test_eq(25, Ipv4Address::new(255, 255, 255, 128));
    test_eq(26, Ipv4Address::new(255, 255, 255, 192));
    test_eq(27, Ipv4Address::new(255, 255, 255, 224));
    test_eq(28, Ipv4Address::new(255, 255, 255, 240));
    test_eq(29, Ipv4Address::new(255, 255, 255, 248));
    test_eq(30, Ipv4Address::new(255, 255, 255, 252));
    test_eq(31, Ipv4Address::new(255, 255, 255, 254));
    test_eq(32, Ipv4Address::new(255, 255, 255, 255));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn to_prefix_len_ipv4_error() {
    assert_eq!(
        None,
        IpAddress::from(Ipv4Address::new(255, 255, 255, 1)).prefix_len()
    );
}

#[test]
#[cfg(feature = "proto-ipv6")]
fn to_prefix_len_ipv6() {
    fn test_eq<A: Into<Address>>(prefix_len: u8, mask: A) {
        assert_eq!(Some(prefix_len), mask.into().prefix_len());
    }

    test_eq(0, Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 0));
    test_eq(
        128,
        Ipv6Address::new(
            0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
        ),
    );
}

#[test]
#[cfg(feature = "proto-ipv6")]
fn to_prefix_len_ipv6_error() {
    assert_eq!(
        None,
        IpAddress::from(Ipv6Address::new(
            0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0, 1
        ))
        .prefix_len()
    );
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_ipv4_packet() {
    let ipv4_packet_bytes: [u8; 20] = [
        0x45, 0x00, 0x00, 0x14, 0x00, 0x01, 0x40, 0x00, 0x40, 0x01, 0xd2, 0x7c, 0x11, 0x12, 0x13,
        0x14, 0x21, 0x22, 0x23, 0x24,
    ];

    let expected = Ipv4Repr {
        src_addr: crate::wire::ipv4::Address::new(0x11, 0x12, 0x13, 0x14),
        dst_addr: crate::wire::ipv4::Address::new(0x21, 0x22, 0x23, 0x24),
        next_header: Protocol::Icmp,
        payload_len: 0,
        hop_limit: 64,
    };

    let packet = Packet::new_unchecked(&ipv4_packet_bytes[..]);
    let ip_repr = IpRepr::parse(&packet, &ChecksumCapabilities::default()).unwrap();
    assert_eq!(ip_repr.version(), Version::Ipv4);
    let IpRepr::Ipv4(ipv4_repr) = ip_repr else {
        panic!("expected Ipv4Repr");
    };
    assert_eq!(ipv4_repr, expected);
    assert_eq!(packet.into_inner(), ipv4_packet_bytes);
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_ipv4_packet_error() {
    let ipv4_packet_bytes: [u8; 29] = [
        0x45, 0x00, 0x00, 0x1e, 0x01, 0x02, 0x62, 0x03, 0x1a, 0x01, 0xd5, 0x6e, 0x11, 0x12, 0x13,
        0x14, 0x21, 0x22, 0x23, 0x24, 0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    let packet = Packet::new_unchecked(&ipv4_packet_bytes[..]);
    let ip_repr_result = IpRepr::parse(&packet, &ChecksumCapabilities::default());
    assert!(ip_repr_result.is_err());
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_ipv6_packet() {
    let ipv6_packet_bytes: [u8; 52] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00,
        0x0c, 0x02, 0x4e, 0xff, 0xff, 0xff, 0xff,
    ];

    let expected = Ipv6Repr {
        src_addr: crate::wire::ipv6::Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
        dst_addr: crate::wire::ipv6::Address::new(0xff02, 0, 0, 0, 0, 0, 0, 1),
        next_header: Protocol::Udp,
        payload_len: 12,
        hop_limit: 64,
    };

    let packet = Packet::new_unchecked(&ipv6_packet_bytes[..]);
    let ip_repr = IpRepr::parse(&packet, &ChecksumCapabilities::default()).unwrap();
    assert_eq!(ip_repr.version(), Version::Ipv6);
    let IpRepr::Ipv6(ipv6_repr) = ip_repr else {
        panic!("expected Ipv6Repr");
    };
    assert_eq!(ipv6_repr, expected);
    assert_eq!(packet.into_inner(), ipv6_packet_bytes);
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_ipv6_packet_error() {
    let ipv6_packet_bytes: [u8; 51] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00,
        0x0c, 0x02, 0x4e, 0xff, 0xff, 0xff,
    ];

    let packet = Packet::new_unchecked(&ipv6_packet_bytes[..]);
    let ip_repr_result = IpRepr::parse(&packet, &ChecksumCapabilities::default());
    assert!(ip_repr_result.is_err());
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_packet_too_short() {
    // Test empty packet where no version can be parsed
    let ip_packet = [0u8; 0];
    let packet_result = Packet::new_checked(&ip_packet[..]);
    assert!(packet_result.is_err());
}

#[test]
#[cfg(all(feature = "proto-ipv4", feature = "proto-ipv6"))]
fn parse_packet_invalid_version() {
    let packet_bytes: [u8; 1] = [0xFF];
    let packet = Packet::new_unchecked(&packet_bytes[..]);
    let ip_repr_result = IpRepr::parse(&packet, &ChecksumCapabilities::default());
    assert!(ip_repr_result.is_err());
}
