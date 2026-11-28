use super::*;

#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_1: Address = Address::new(192, 168, 1, 1);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_2: Address = Address::new(192, 168, 1, 2);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_3: Address = Address::new(192, 168, 1, 3);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_4: Address = Address::new(192, 168, 1, 4);
#[allow(unused)]
pub(crate) const MOCK_UNSPECIFIED: Address = Address::UNSPECIFIED;

static PACKET_BYTES: [u8; 30] = [
    0x45, 0x00, 0x00, 0x1e, 0x01, 0x02, 0x62, 0x03, 0x1a, 0x01, 0xd5, 0x6e, 0x11, 0x12, 0x13, 0x14,
    0x21, 0x22, 0x23, 0x24, 0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
];

static PAYLOAD_BYTES: [u8; 10] = [0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff];

#[test]
fn test_deconstruct() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    assert_eq!(packet.version(), 4);
    assert_eq!(packet.header_len(), 20);
    assert_eq!(packet.dscp(), 0);
    assert_eq!(packet.ecn(), 0);
    assert_eq!(packet.total_len(), 30);
    assert_eq!(packet.ident(), 0x102);
    assert!(packet.more_frags());
    assert!(packet.dont_frag());
    assert_eq!(packet.frag_offset(), 0x203 * 8);
    assert_eq!(packet.hop_limit(), 0x1a);
    assert_eq!(packet.next_header(), Protocol::Icmp);
    assert_eq!(packet.checksum(), 0xd56e);
    assert_eq!(packet.src_addr(), Address::new(0x11, 0x12, 0x13, 0x14));
    assert_eq!(packet.dst_addr(), Address::new(0x21, 0x22, 0x23, 0x24));
    assert!(packet.verify_checksum());
    assert_eq!(packet.payload(), &PAYLOAD_BYTES[..]);
}

#[test]
fn test_construct() {
    let mut bytes = vec![0xa5; 30];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_version(4);
    packet.set_header_len(20);
    packet.clear_flags();
    packet.set_dscp(0);
    packet.set_ecn(0);
    packet.set_total_len(30);
    packet.set_ident(0x102);
    packet.set_more_frags(true);
    packet.set_dont_frag(true);
    packet.set_frag_offset(0x203 * 8);
    packet.set_hop_limit(0x1a);
    packet.set_next_header(Protocol::Icmp);
    packet.set_src_addr(Address::new(0x11, 0x12, 0x13, 0x14));
    packet.set_dst_addr(Address::new(0x21, 0x22, 0x23, 0x24));
    packet.fill_checksum();
    packet.payload_mut().copy_from_slice(&PAYLOAD_BYTES[..]);
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}

#[test]
fn test_overlong() {
    let mut bytes = vec![];
    bytes.extend(&PACKET_BYTES[..]);
    bytes.push(0);

    assert_eq!(
        Packet::new_unchecked(&bytes).payload().len(),
        PAYLOAD_BYTES.len()
    );
    assert_eq!(
        Packet::new_unchecked(&mut bytes).payload_mut().len(),
        PAYLOAD_BYTES.len()
    );
}

#[test]
fn test_total_len_overflow() {
    let mut bytes = vec![];
    bytes.extend(&PACKET_BYTES[..]);
    Packet::new_unchecked(&mut bytes).set_total_len(128);

    assert_eq!(Packet::new_checked(&bytes).unwrap_err(), Error);
}

static REPR_PACKET_BYTES: [u8; 24] = [
    0x45, 0x00, 0x00, 0x18, 0x00, 0x00, 0x40, 0x00, 0x40, 0x01, 0xd2, 0x79, 0x11, 0x12, 0x13, 0x14,
    0x21, 0x22, 0x23, 0x24, 0xaa, 0x00, 0x00, 0xff,
];

static REPR_PAYLOAD_BYTES: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

const fn packet_repr() -> Repr {
    Repr {
        src_addr: Address::new(0x11, 0x12, 0x13, 0x14),
        dst_addr: Address::new(0x21, 0x22, 0x23, 0x24),
        next_header: Protocol::Icmp,
        payload_len: 4,
        hop_limit: 64,
    }
}

#[test]
fn test_parse() {
    let packet = Packet::new_unchecked(&REPR_PACKET_BYTES[..]);
    let repr = Repr::parse(&packet, &ChecksumCapabilities::default()).unwrap();
    assert_eq!(repr, packet_repr());
}

#[test]
fn test_parse_bad_version() {
    let mut bytes = vec![0; 24];
    bytes.copy_from_slice(&REPR_PACKET_BYTES[..]);
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_version(6);
    packet.fill_checksum();
    let packet = Packet::new_unchecked(&*packet.into_inner());
    assert_eq!(
        Repr::parse(&packet, &ChecksumCapabilities::default()),
        Err(Error)
    );
}

#[test]
fn test_parse_total_len_less_than_header_len() {
    let mut bytes = vec![0; 40];
    bytes[0] = 0x09;
    assert_eq!(Packet::new_checked(&mut bytes), Err(Error));
}

#[test]
fn test_parse_small_ihl() {
    let mut bytes = vec![0; 24];
    bytes.copy_from_slice(&REPR_PACKET_BYTES[..]);
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_header_len(16);

    assert_eq!(Packet::new_checked(&mut bytes), Err(Error));
}

#[test]
fn test_emit() {
    let repr = packet_repr();
    let mut bytes = vec![0xa5; repr.buffer_len() + REPR_PAYLOAD_BYTES.len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(&mut packet, &ChecksumCapabilities::default());
    packet.payload_mut().copy_from_slice(&REPR_PAYLOAD_BYTES);
    assert_eq!(&*packet.into_inner(), &REPR_PACKET_BYTES[..]);
}

#[test]
fn test_unspecified() {
    assert!(Address::UNSPECIFIED.is_unspecified());
    assert!(!Address::UNSPECIFIED.is_broadcast());
    assert!(!Address::UNSPECIFIED.is_multicast());
    assert!(!Address::UNSPECIFIED.is_link_local());
    assert!(!Address::UNSPECIFIED.is_loopback());
}

#[test]
fn test_broadcast() {
    assert!(!Address::BROADCAST.is_unspecified());
    assert!(Address::BROADCAST.is_broadcast());
    assert!(!Address::BROADCAST.is_multicast());
    assert!(!Address::BROADCAST.is_link_local());
    assert!(!Address::BROADCAST.is_loopback());
}

#[test]
fn test_cidr() {
    let cidr = Cidr::new(Address::new(192, 168, 1, 10), 24);

    let inside_subnet = [
        [192, 168, 1, 0],
        [192, 168, 1, 1],
        [192, 168, 1, 2],
        [192, 168, 1, 10],
        [192, 168, 1, 127],
        [192, 168, 1, 255],
    ];

    let outside_subnet = [
        [192, 168, 0, 0],
        [127, 0, 0, 1],
        [192, 168, 2, 0],
        [192, 168, 0, 255],
        [0, 0, 0, 0],
        [255, 255, 255, 255],
    ];

    let subnets = [
        ([192, 168, 1, 0], 32),
        ([192, 168, 1, 255], 24),
        ([192, 168, 1, 10], 30),
    ];

    let not_subnets = [
        ([192, 168, 1, 10], 23),
        ([127, 0, 0, 1], 8),
        ([192, 168, 1, 0], 0),
        ([192, 168, 0, 255], 32),
    ];

    for addr in inside_subnet.iter().map(|a| Address::from_octets(*a)) {
        assert!(cidr.contains_addr(&addr));
    }

    for addr in outside_subnet.iter().map(|a| Address::from_octets(*a)) {
        assert!(!cidr.contains_addr(&addr));
    }

    for subnet in subnets
        .iter()
        .map(|&(a, p)| Cidr::new(Address::new(a[0], a[1], a[2], a[3]), p))
    {
        assert!(cidr.contains_subnet(&subnet));
    }

    for subnet in not_subnets
        .iter()
        .map(|&(a, p)| Cidr::new(Address::new(a[0], a[1], a[2], a[3]), p))
    {
        assert!(!cidr.contains_subnet(&subnet));
    }

    let cidr_without_prefix = Cidr::new(cidr.address(), 0);
    assert!(cidr_without_prefix.contains_addr(&Address::new(127, 0, 0, 1)));
}

#[test]
fn test_cidr_from_netmask() {
    assert!(Cidr::from_netmask(Address::new(0, 0, 0, 0), Address::new(1, 0, 2, 0)).is_err());
    assert!(Cidr::from_netmask(Address::new(0, 0, 0, 0), Address::new(0, 0, 0, 0)).is_err());
    assert_eq!(
        Cidr::from_netmask(Address::new(0, 0, 0, 1), Address::new(255, 255, 255, 0)).unwrap(),
        Cidr::new(Address::new(0, 0, 0, 1), 24)
    );
    assert_eq!(
        Cidr::from_netmask(Address::new(192, 168, 0, 1), Address::new(255, 255, 0, 0)).unwrap(),
        Cidr::new(Address::new(192, 168, 0, 1), 16)
    );
    assert_eq!(
        Cidr::from_netmask(Address::new(172, 16, 0, 1), Address::new(255, 240, 0, 0)).unwrap(),
        Cidr::new(Address::new(172, 16, 0, 1), 12)
    );
    assert_eq!(
        Cidr::from_netmask(
            Address::new(255, 255, 255, 1),
            Address::new(255, 255, 255, 0)
        )
        .unwrap(),
        Cidr::new(Address::new(255, 255, 255, 1), 24)
    );
    assert_eq!(
        Cidr::from_netmask(
            Address::new(255, 255, 255, 255),
            Address::new(255, 255, 255, 255)
        )
        .unwrap(),
        Cidr::new(Address::new(255, 255, 255, 255), 32)
    );
}

#[test]
fn test_cidr_netmask() {
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 0), 0).netmask(),
        Address::new(0, 0, 0, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 1), 24).netmask(),
        Address::new(255, 255, 255, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 0), 32).netmask(),
        Address::new(255, 255, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(127, 0, 0, 0), 8).netmask(),
        Address::new(255, 0, 0, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 0, 0), 16).netmask(),
        Address::new(255, 255, 0, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 16).netmask(),
        Address::new(255, 255, 0, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 17).netmask(),
        Address::new(255, 255, 128, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(172, 16, 0, 0), 12).netmask(),
        Address::new(255, 240, 0, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 1), 24).netmask(),
        Address::new(255, 255, 255, 0)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 255), 32).netmask(),
        Address::new(255, 255, 255, 255)
    );
}

#[test]
fn test_cidr_broadcast() {
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 0), 0).broadcast().unwrap(),
        Address::new(255, 255, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 1), 24).broadcast().unwrap(),
        Address::new(0, 0, 0, 255)
    );
    assert_eq!(Cidr::new(Address::new(0, 0, 0, 0), 32).broadcast(), None);
    assert_eq!(
        Cidr::new(Address::new(127, 0, 0, 0), 8)
            .broadcast()
            .unwrap(),
        Address::new(127, 255, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 0, 0), 16)
            .broadcast()
            .unwrap(),
        Address::new(192, 168, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 16)
            .broadcast()
            .unwrap(),
        Address::new(192, 168, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 17)
            .broadcast()
            .unwrap(),
        Address::new(192, 168, 127, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(172, 16, 0, 1), 12)
            .broadcast()
            .unwrap(),
        Address::new(172, 31, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 1), 24)
            .broadcast()
            .unwrap(),
        Address::new(255, 255, 255, 255)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 254), 31).broadcast(),
        None
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 255), 32).broadcast(),
        None
    );
}

#[test]
fn test_cidr_network() {
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 0), 0).network(),
        Cidr::new(Address::new(0, 0, 0, 0), 0)
    );
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 1), 24).network(),
        Cidr::new(Address::new(0, 0, 0, 0), 24)
    );
    assert_eq!(
        Cidr::new(Address::new(0, 0, 0, 0), 32).network(),
        Cidr::new(Address::new(0, 0, 0, 0), 32)
    );
    assert_eq!(
        Cidr::new(Address::new(127, 0, 0, 0), 8).network(),
        Cidr::new(Address::new(127, 0, 0, 0), 8)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 0, 0), 16).network(),
        Cidr::new(Address::new(192, 168, 0, 0), 16)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 16).network(),
        Cidr::new(Address::new(192, 168, 0, 0), 16)
    );
    assert_eq!(
        Cidr::new(Address::new(192, 168, 1, 1), 17).network(),
        Cidr::new(Address::new(192, 168, 0, 0), 17)
    );
    assert_eq!(
        Cidr::new(Address::new(172, 16, 0, 1), 12).network(),
        Cidr::new(Address::new(172, 16, 0, 0), 12)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 1), 24).network(),
        Cidr::new(Address::new(255, 255, 255, 0), 24)
    );
    assert_eq!(
        Cidr::new(Address::new(255, 255, 255, 255), 32).network(),
        Cidr::new(Address::new(255, 255, 255, 255), 32)
    );
}
