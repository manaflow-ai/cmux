use super::*;
use crate::wire::pretty_print::PrettyPrinter;

#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_1: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_2: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_3: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 3);
#[allow(unused)]
pub(crate) const MOCK_IP_ADDR_4: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 4);
#[allow(unused)]
pub(crate) const MOCK_UNSPECIFIED: Address = Address::UNSPECIFIED;

const LINK_LOCAL_ADDR: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
const UNIQUE_LOCAL_ADDR: Address = Address::new(0xfd00, 0, 0, 201, 1, 1, 1, 1);
const GLOBAL_UNICAST_ADDR: Address = Address::new(0x2001, 0xdb8, 0x3, 0, 0, 0, 0, 1);

const TEST_SOL_NODE_MCAST_ADDR: Address = Address::new(0xff02, 0, 0, 0, 0, 1, 0xff01, 101);

#[test]
fn test_basic_multicast() {
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_unspecified());
    assert!(LINK_LOCAL_ALL_ROUTERS.is_multicast());
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_link_local());
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_loopback());
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_unique_local());
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_global_unicast());
    assert!(!LINK_LOCAL_ALL_ROUTERS.is_solicited_node_multicast());
    assert!(!LINK_LOCAL_ALL_NODES.is_unspecified());
    assert!(LINK_LOCAL_ALL_NODES.is_multicast());
    assert!(!LINK_LOCAL_ALL_NODES.is_link_local());
    assert!(!LINK_LOCAL_ALL_NODES.is_loopback());
    assert!(!LINK_LOCAL_ALL_NODES.is_unique_local());
    assert!(!LINK_LOCAL_ALL_NODES.is_global_unicast());
    assert!(!LINK_LOCAL_ALL_NODES.is_solicited_node_multicast());
}

#[test]
fn test_basic_link_local() {
    assert!(!LINK_LOCAL_ADDR.is_unspecified());
    assert!(!LINK_LOCAL_ADDR.is_multicast());
    assert!(LINK_LOCAL_ADDR.is_link_local());
    assert!(!LINK_LOCAL_ADDR.is_loopback());
    assert!(!LINK_LOCAL_ADDR.is_unique_local());
    assert!(!LINK_LOCAL_ADDR.is_global_unicast());
    assert!(!LINK_LOCAL_ADDR.is_solicited_node_multicast());
}

#[test]
fn test_basic_loopback() {
    assert!(!Address::LOCALHOST.is_unspecified());
    assert!(!Address::LOCALHOST.is_multicast());
    assert!(!Address::LOCALHOST.is_link_local());
    assert!(Address::LOCALHOST.is_loopback());
    assert!(!Address::LOCALHOST.is_unique_local());
    assert!(!Address::LOCALHOST.is_global_unicast());
    assert!(!Address::LOCALHOST.is_solicited_node_multicast());
}

#[test]
fn test_unique_local() {
    assert!(!UNIQUE_LOCAL_ADDR.is_unspecified());
    assert!(!UNIQUE_LOCAL_ADDR.is_multicast());
    assert!(!UNIQUE_LOCAL_ADDR.is_link_local());
    assert!(!UNIQUE_LOCAL_ADDR.is_loopback());
    assert!(UNIQUE_LOCAL_ADDR.is_unique_local());
    assert!(!UNIQUE_LOCAL_ADDR.is_global_unicast());
    assert!(!UNIQUE_LOCAL_ADDR.is_solicited_node_multicast());
}

#[test]
fn test_global_unicast() {
    assert!(!GLOBAL_UNICAST_ADDR.is_unspecified());
    assert!(!GLOBAL_UNICAST_ADDR.is_multicast());
    assert!(!GLOBAL_UNICAST_ADDR.is_link_local());
    assert!(!GLOBAL_UNICAST_ADDR.is_loopback());
    assert!(!GLOBAL_UNICAST_ADDR.is_unique_local());
    assert!(GLOBAL_UNICAST_ADDR.is_global_unicast());
    assert!(!GLOBAL_UNICAST_ADDR.is_solicited_node_multicast());
}

#[test]
fn test_sollicited_node_multicast() {
    assert!(!TEST_SOL_NODE_MCAST_ADDR.is_unspecified());
    assert!(TEST_SOL_NODE_MCAST_ADDR.is_multicast());
    assert!(!TEST_SOL_NODE_MCAST_ADDR.is_link_local());
    assert!(!TEST_SOL_NODE_MCAST_ADDR.is_loopback());
    assert!(!TEST_SOL_NODE_MCAST_ADDR.is_unique_local());
    assert!(!TEST_SOL_NODE_MCAST_ADDR.is_global_unicast());
    assert!(TEST_SOL_NODE_MCAST_ADDR.is_solicited_node_multicast());
}

#[test]
fn test_mask() {
    let addr = Address::new(0x0123, 0x4567, 0x89ab, 0, 0, 0, 0, 1);
    assert_eq!(
        addr.mask(11),
        [0x01, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    );
    assert_eq!(
        addr.mask(15),
        [0x01, 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    );
    assert_eq!(
        addr.mask(26),
        [0x01, 0x23, 0x45, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    );
    assert_eq!(
        addr.mask(128),
        [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]
    );
    assert_eq!(
        addr.mask(127),
        [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]
    );
}

#[test]
fn test_cidr() {
    // fe80::1/56
    // 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
    // 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    let cidr = Cidr::new(LINK_LOCAL_ADDR, 56);

    let inside_subnet = [
        // fe80::2
        [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x02,
        ],
        // fe80::1122:3344:5566:7788
        [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
            0x77, 0x88,
        ],
        // fe80::ff00:0:0:0
        [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ],
        // fe80::ff
        [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0xff,
        ],
    ];

    let outside_subnet = [
        // fe80:0:0:101::1
        [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ],
        // ::1
        [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ],
        // ff02::1
        [
            0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ],
        // ff02::2
        [
            0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x02,
        ],
    ];

    let subnets = [
        // fe80::ffff:ffff:ffff:ffff/65
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff,
            ],
            65,
        ),
        // fe80::1/128
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x01,
            ],
            128,
        ),
        // fe80::1234:5678/96
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34,
                0x56, 0x78,
            ],
            96,
        ),
    ];

    let not_subnets = [
        // fe80::101:ffff:ffff:ffff:ffff/55
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff,
            ],
            55,
        ),
        // fe80::101:ffff:ffff:ffff:ffff/56
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff,
            ],
            56,
        ),
        // fe80::101:ffff:ffff:ffff:ffff/57
        (
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff,
            ],
            57,
        ),
        // ::1/128
        (
            [
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x01,
            ],
            128,
        ),
    ];

    for addr in inside_subnet.iter().map(|a| Address::from_octets(*a)) {
        assert!(cidr.contains_addr(&addr));
    }

    for addr in outside_subnet.iter().map(|a| Address::from_octets(*a)) {
        assert!(!cidr.contains_addr(&addr));
    }

    for subnet in subnets.iter().map(|&(a, p)| Cidr::new(Address::from(a), p)) {
        assert!(cidr.contains_subnet(&subnet));
    }

    for subnet in not_subnets
        .iter()
        .map(|&(a, p)| Cidr::new(Address::from(a), p))
    {
        assert!(!cidr.contains_subnet(&subnet));
    }

    let cidr_without_prefix = Cidr::new(LINK_LOCAL_ADDR, 0);
    assert!(cidr_without_prefix.contains_addr(&Address::LOCALHOST));
}

#[test]
fn test_from_eui_64() {
    #[cfg(feature = "medium-ethernet")]
    use crate::wire::EthernetAddress;
    #[cfg(feature = "medium-ieee802154")]
    use crate::wire::Ieee802154Address;
    let tests: std::vec::Vec<(HardwareAddress, Address)> = vec![
        #[cfg(feature = "medium-ethernet")]
        (
            HardwareAddress::Ethernet(EthernetAddress::from_bytes(&[
                0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
            ])),
            Address::new(0x2001, 0xdb8, 0x3, 0x0, 0xa8bb, 0xccff, 0xfedd, 0xeeff),
        ),
        #[cfg(feature = "medium-ieee802154")]
        (
            HardwareAddress::Ieee802154(Ieee802154Address::from_bytes(&[
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            ])),
            Address::new(0x2001, 0xdb8, 0x3, 0x0, 0x0211, 0x2233, 0x4455, 0x6677),
        ),
    ];

    let prefix = Cidr::new(GLOBAL_UNICAST_ADDR.mask(64).into(), 64);
    let wrong_prefix = Cidr::new(GLOBAL_UNICAST_ADDR.mask(72).into(), 72);

    for (hardware, result) in tests {
        let generated = Address::from_link_prefix(&prefix, hardware).unwrap();
        assert!(prefix.contains_addr(&generated));
        assert_eq!(generated, result);
        assert!(Address::from_link_prefix(&wrong_prefix, hardware).is_none());

        let generated = Cidr::from_link_prefix(&prefix, hardware).unwrap();
        assert!(prefix.contains_subnet(&generated));
        assert_eq!(generated.address(), result);
        assert!(Cidr::from_link_prefix(&wrong_prefix, hardware).is_none());
    }
}

#[test]
fn test_scope() {
    use super::*;
    assert_eq!(
        Address::new(0xff01, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::InterfaceLocal
    );
    assert_eq!(
        Address::new(0xff02, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::LinkLocal
    );
    assert_eq!(
        Address::new(0xff03, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::Unknown
    );
    assert_eq!(
        Address::new(0xff04, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::AdminLocal
    );
    assert_eq!(
        Address::new(0xff05, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::SiteLocal
    );
    assert_eq!(
        Address::new(0xff08, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::OrganizationLocal
    );
    assert_eq!(
        Address::new(0xff0e, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
        MulticastScope::Global
    );

    assert_eq!(
        LINK_LOCAL_ALL_NODES.x_multicast_scope(),
        MulticastScope::LinkLocal
    );

    // For source address selection, unicast addresses also have a scope:
    assert_eq!(
        LINK_LOCAL_ADDR.x_multicast_scope(),
        MulticastScope::LinkLocal
    );
    assert_eq!(
        GLOBAL_UNICAST_ADDR.x_multicast_scope(),
        MulticastScope::Global
    );
    assert_eq!(
        UNIQUE_LOCAL_ADDR.x_multicast_scope(),
        MulticastScope::Global
    );
}

static REPR_PACKET_BYTES: [u8; 52] = [
    0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x0c, 0x02, 0x4e,
    0xff, 0xff, 0xff, 0xff,
];
static REPR_PAYLOAD_BYTES: [u8; 12] = [
    0x00, 0x01, 0x00, 0x02, 0x00, 0x0c, 0x02, 0x4e, 0xff, 0xff, 0xff, 0xff,
];

const fn packet_repr() -> Repr {
    Repr {
        src_addr: Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
        dst_addr: LINK_LOCAL_ALL_NODES,
        next_header: Protocol::Udp,
        payload_len: 12,
        hop_limit: 64,
    }
}

#[test]
fn test_packet_deconstruction() {
    let packet = Packet::new_unchecked(&REPR_PACKET_BYTES[..]);
    assert_eq!(packet.check_len(), Ok(()));
    assert_eq!(packet.version(), 6);
    assert_eq!(packet.traffic_class(), 0);
    assert_eq!(packet.flow_label(), 0);
    assert_eq!(packet.total_len(), 0x34);
    assert_eq!(packet.payload_len() as usize, REPR_PAYLOAD_BYTES.len());
    assert_eq!(packet.next_header(), Protocol::Udp);
    assert_eq!(packet.hop_limit(), 0x40);
    assert_eq!(packet.src_addr(), Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1));
    assert_eq!(packet.dst_addr(), LINK_LOCAL_ALL_NODES);
    assert_eq!(packet.payload(), &REPR_PAYLOAD_BYTES[..]);
}

#[test]
fn test_packet_construction() {
    let mut bytes = [0xff; 52];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    // Version, Traffic Class, and Flow Label are not
    // byte aligned. make sure the setters and getters
    // do not interfere with each other.
    packet.set_version(6);
    assert_eq!(packet.version(), 6);
    packet.set_traffic_class(0x99);
    assert_eq!(packet.version(), 6);
    assert_eq!(packet.traffic_class(), 0x99);
    packet.set_flow_label(0x54321);
    assert_eq!(packet.traffic_class(), 0x99);
    assert_eq!(packet.flow_label(), 0x54321);
    packet.set_payload_len(0xc);
    packet.set_next_header(Protocol::Udp);
    packet.set_hop_limit(0xfe);
    packet.set_src_addr(LINK_LOCAL_ALL_ROUTERS);
    packet.set_dst_addr(LINK_LOCAL_ALL_NODES);
    packet
        .payload_mut()
        .copy_from_slice(&REPR_PAYLOAD_BYTES[..]);
    let mut expected_bytes = [
        0x69, 0x95, 0x43, 0x21, 0x00, 0x0c, 0x11, 0xfe, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];
    let start = expected_bytes.len() - REPR_PAYLOAD_BYTES.len();
    expected_bytes[start..].copy_from_slice(&REPR_PAYLOAD_BYTES[..]);
    assert_eq!(packet.check_len(), Ok(()));
    assert_eq!(&*packet.into_inner(), &expected_bytes[..]);
}

#[test]
fn test_overlong() {
    let mut bytes = vec![];
    bytes.extend(&REPR_PACKET_BYTES[..]);
    bytes.push(0);

    assert_eq!(
        Packet::new_unchecked(&bytes).payload().len(),
        REPR_PAYLOAD_BYTES.len()
    );
    assert_eq!(
        Packet::new_unchecked(&mut bytes).payload_mut().len(),
        REPR_PAYLOAD_BYTES.len()
    );
}

#[test]
fn test_total_len_overflow() {
    let mut bytes = vec![];
    bytes.extend(&REPR_PACKET_BYTES[..]);
    Packet::new_unchecked(&mut bytes).set_payload_len(0x80);

    assert_eq!(Packet::new_checked(&bytes).unwrap_err(), Error);
}

#[test]
fn test_repr_parse_valid() {
    let packet = Packet::new_unchecked(&REPR_PACKET_BYTES[..]);
    let repr = Repr::parse(&packet).unwrap();
    assert_eq!(repr, packet_repr());
}

#[test]
fn test_repr_parse_bad_version() {
    let mut bytes = [0; 40];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    packet.set_version(4);
    packet.set_payload_len(0);
    let packet = Packet::new_unchecked(&*packet.into_inner());
    assert_eq!(Repr::parse(&packet), Err(Error));
}

#[test]
fn test_repr_parse_smaller_than_header() {
    let mut bytes = [0; 40];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    packet.set_version(6);
    packet.set_payload_len(39);
    let packet = Packet::new_unchecked(&*packet.into_inner());
    assert_eq!(Repr::parse(&packet), Err(Error));
}

#[test]
fn test_repr_parse_smaller_than_payload() {
    let mut bytes = [0; 40];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    packet.set_version(6);
    packet.set_payload_len(1);
    let packet = Packet::new_unchecked(&*packet.into_inner());
    assert_eq!(Repr::parse(&packet), Err(Error));
}

#[test]
fn test_basic_repr_emit() {
    let repr = packet_repr();
    let mut bytes = vec![0xff; repr.buffer_len() + REPR_PAYLOAD_BYTES.len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(&mut packet);
    packet.payload_mut().copy_from_slice(&REPR_PAYLOAD_BYTES);
    assert_eq!(&*packet.into_inner(), &REPR_PACKET_BYTES[..]);
}

#[test]
fn test_pretty_print() {
    assert_eq!(
        format!(
            "{}",
            PrettyPrinter::<Packet<&'static [u8]>>::new("\n", &&REPR_PACKET_BYTES[..])
        ),
        "\nIPv6 src=fe80::1 dst=ff02::1 nxt_hdr=UDP hop_limit=64\n \\ UDP src=1 dst=2 len=4"
    );
}
