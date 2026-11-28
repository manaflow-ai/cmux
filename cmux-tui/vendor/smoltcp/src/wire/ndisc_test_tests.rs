use super::*;
use crate::phy::ChecksumCapabilities;
use crate::wire::EthernetAddress;
use crate::wire::Icmpv6Repr;

const MOCK_IP_ADDR_1: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
const MOCK_IP_ADDR_2: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);

static ROUTER_ADVERT_BYTES: [u8; 24] = [
    0x86, 0x00, 0xa9, 0xde, 0x40, 0x80, 0x03, 0x84, 0x00, 0x00, 0x03, 0x84, 0x00, 0x00, 0x03, 0x84,
    0x01, 0x01, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56,
];
static SOURCE_LINK_LAYER_OPT: [u8; 8] = [0x01, 0x01, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56];

fn create_repr<'a>() -> Icmpv6Repr<'a> {
    Icmpv6Repr::Ndisc(Repr::RouterAdvert {
        hop_limit: 64,
        flags: RouterFlags::MANAGED,
        router_lifetime: Duration::from_secs(900),
        reachable_time: Duration::from_millis(900),
        retrans_time: Duration::from_millis(900),
        lladdr: Some(EthernetAddress([0x52, 0x54, 0x00, 0x12, 0x34, 0x56]).into()),
        mtu: None,
        prefix_info: None,
    })
}

#[test]
fn test_router_advert_deconstruct() {
    let packet = Packet::new_unchecked(&ROUTER_ADVERT_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::RouterAdvert);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.current_hop_limit(), 64);
    assert_eq!(packet.router_flags(), RouterFlags::MANAGED);
    assert_eq!(packet.router_lifetime(), Duration::from_secs(900));
    assert_eq!(packet.reachable_time(), Duration::from_millis(900));
    assert_eq!(packet.retrans_time(), Duration::from_millis(900));
    assert_eq!(packet.payload(), &SOURCE_LINK_LAYER_OPT[..]);
}

#[test]
fn test_router_advert_construct() {
    let mut bytes = vec![0x0; 24];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::RouterAdvert);
    packet.set_msg_code(0);
    packet.set_current_hop_limit(64);
    packet.set_router_flags(RouterFlags::MANAGED);
    packet.set_router_lifetime(Duration::from_secs(900));
    packet.set_reachable_time(Duration::from_millis(900));
    packet.set_retrans_time(Duration::from_millis(900));
    packet
        .payload_mut()
        .copy_from_slice(&SOURCE_LINK_LAYER_OPT[..]);
    packet.fill_checksum(&MOCK_IP_ADDR_1, &MOCK_IP_ADDR_2);
    assert_eq!(&*packet.into_inner(), &ROUTER_ADVERT_BYTES[..]);
}

#[test]
fn test_router_advert_repr_parse() {
    let packet = Packet::new_unchecked(&ROUTER_ADVERT_BYTES[..]);
    assert_eq!(
        Icmpv6Repr::parse(
            &MOCK_IP_ADDR_1,
            &MOCK_IP_ADDR_2,
            &packet,
            &ChecksumCapabilities::default()
        )
        .unwrap(),
        create_repr()
    );
}

#[test]
fn test_router_advert_repr_emit() {
    let mut bytes = [0x2a; 24];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    create_repr().emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &ROUTER_ADVERT_BYTES[..]);
}

#[test]
fn test_redirect_lladdr_roundtrip() {
    // A Redirect's link-layer address is a Target LL option (type 2);
    // emit then parse must preserve it, not drop it to None.
    let lladdr = EthernetAddress([0x52, 0x54, 0x00, 0x12, 0x34, 0x56]).into();
    let repr = Icmpv6Repr::Ndisc(Repr::Redirect {
        target_addr: MOCK_IP_ADDR_1,
        dest_addr: MOCK_IP_ADDR_2,
        lladdr: Some(lladdr),
        redirected_hdr: None,
    });

    let mut bytes = vec![0u8; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    repr.emit(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &mut packet,
        &ChecksumCapabilities::default(),
    );

    let packet = Packet::new_unchecked(&bytes[..]);
    let parsed = Icmpv6Repr::parse(
        &MOCK_IP_ADDR_1,
        &MOCK_IP_ADDR_2,
        &packet,
        &ChecksumCapabilities::default(),
    )
    .unwrap();
    assert_eq!(parsed, repr);
}
