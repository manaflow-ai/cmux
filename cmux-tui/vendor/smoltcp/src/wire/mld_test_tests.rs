use super::*;
use crate::phy::ChecksumCapabilities;
use crate::wire::icmpv6::Message;
use crate::wire::{IPV6_LINK_LOCAL_ALL_NODES, IPV6_LINK_LOCAL_ALL_ROUTERS, Icmpv6Repr};

static QUERY_PACKET_BYTES: [u8; 44] = [
    0x82, 0x00, 0x73, 0x74, 0x04, 0x00, 0x00, 0x00, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x0a, 0x12, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
];

static QUERY_PACKET_PAYLOAD: [u8; 16] = [
    0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
];

static REPORT_PACKET_BYTES: [u8; 44] = [
    0x8f, 0x00, 0x73, 0x85, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
];

static REPORT_PACKET_PAYLOAD: [u8; 36] = [
    0x01, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02,
];

fn create_repr<'a>(ty: Message) -> Icmpv6Repr<'a> {
    match ty {
        Message::MldQuery => Icmpv6Repr::Mld(Repr::Query {
            max_resp_code: 0x400,
            mcast_addr: IPV6_LINK_LOCAL_ALL_NODES,
            s_flag: true,
            qrv: 0x02,
            qqic: 0x12,
            num_srcs: 0x01,
            data: &QUERY_PACKET_PAYLOAD,
        }),
        Message::MldReport => Icmpv6Repr::Mld(Repr::Report {
            nr_mcast_addr_rcrds: 1,
            data: &REPORT_PACKET_PAYLOAD,
        }),
        _ => {
            panic!("Message type must be a MLDv2 message type");
        }
    }
}

#[test]
fn test_query_deconstruct() {
    let packet = Packet::new_unchecked(&QUERY_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::MldQuery);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.checksum(), 0x7374);
    assert_eq!(packet.max_resp_code(), 0x0400);
    assert_eq!(packet.mcast_addr(), IPV6_LINK_LOCAL_ALL_NODES);
    assert!(packet.s_flag());
    assert_eq!(packet.qrv(), 0x02);
    assert_eq!(packet.qqic(), 0x12);
    assert_eq!(packet.num_srcs(), 0x01);
    assert_eq!(
        Ipv6Address::from_octets(packet.payload().try_into().unwrap()),
        IPV6_LINK_LOCAL_ALL_ROUTERS
    );
}

#[test]
fn test_query_construct() {
    let mut bytes = [0xff; 44];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    packet.set_msg_type(Message::MldQuery);
    packet.set_msg_code(0);
    packet.set_max_resp_code(0x0400);
    packet.set_mcast_addr(IPV6_LINK_LOCAL_ALL_NODES);
    packet.set_s_flag();
    packet.set_qrv(0x02);
    packet.set_qqic(0x12);
    packet.set_num_srcs(0x01);
    packet
        .payload_mut()
        .copy_from_slice(&IPV6_LINK_LOCAL_ALL_ROUTERS.octets());
    packet.clear_reserved();
    packet.fill_checksum(&IPV6_LINK_LOCAL_ALL_NODES, &IPV6_LINK_LOCAL_ALL_ROUTERS);
    assert_eq!(&*packet.into_inner(), &QUERY_PACKET_BYTES[..]);
}

#[test]
fn test_record_deconstruct() {
    let packet = Packet::new_unchecked(&REPORT_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::MldReport);
    assert_eq!(packet.msg_code(), 0);
    assert_eq!(packet.checksum(), 0x7385);
    assert_eq!(packet.nr_mcast_addr_rcrds(), 0x01);
    let addr_rcrd = AddressRecord::new_unchecked(packet.payload());
    assert_eq!(addr_rcrd.record_type(), RecordType::ModeIsInclude);
    assert_eq!(addr_rcrd.aux_data_len(), 0x00);
    assert_eq!(addr_rcrd.num_srcs(), 0x01);
    assert_eq!(addr_rcrd.mcast_addr(), IPV6_LINK_LOCAL_ALL_NODES);
    assert_eq!(
        Ipv6Address::from_octets(addr_rcrd.payload().try_into().unwrap()),
        IPV6_LINK_LOCAL_ALL_ROUTERS
    );
}

#[test]
fn test_record_construct() {
    let mut bytes = [0xff; 44];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    packet.set_msg_type(Message::MldReport);
    packet.set_msg_code(0);
    packet.clear_reserved();
    packet.set_nr_mcast_addr_rcrds(1);
    {
        let mut addr_rcrd = AddressRecord::new_unchecked(packet.payload_mut());
        addr_rcrd.set_record_type(RecordType::ModeIsInclude);
        addr_rcrd.set_aux_data_len(0);
        addr_rcrd.set_num_srcs(1);
        addr_rcrd.set_mcast_addr(IPV6_LINK_LOCAL_ALL_NODES);
        addr_rcrd
            .payload_mut()
            .copy_from_slice(&IPV6_LINK_LOCAL_ALL_ROUTERS.octets());
    }
    packet.fill_checksum(&IPV6_LINK_LOCAL_ALL_NODES, &IPV6_LINK_LOCAL_ALL_ROUTERS);
    assert_eq!(&*packet.into_inner(), &REPORT_PACKET_BYTES[..]);
}

#[test]
fn test_query_repr_parse() {
    let packet = Packet::new_unchecked(&QUERY_PACKET_BYTES[..]);
    let repr = Icmpv6Repr::parse(
        &IPV6_LINK_LOCAL_ALL_NODES,
        &IPV6_LINK_LOCAL_ALL_ROUTERS,
        &packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(repr, Ok(create_repr(Message::MldQuery)));
}

#[test]
fn test_report_repr_parse() {
    let packet = Packet::new_unchecked(&REPORT_PACKET_BYTES[..]);
    let repr = Icmpv6Repr::parse(
        &IPV6_LINK_LOCAL_ALL_NODES,
        &IPV6_LINK_LOCAL_ALL_ROUTERS,
        &packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(repr, Ok(create_repr(Message::MldReport)));
}

#[test]
fn test_query_repr_emit() {
    let mut bytes = [0x2a; 44];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    let repr = create_repr(Message::MldQuery);
    repr.emit(
        &IPV6_LINK_LOCAL_ALL_NODES,
        &IPV6_LINK_LOCAL_ALL_ROUTERS,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &QUERY_PACKET_BYTES[..]);
}

#[test]
fn test_report_repr_emit() {
    let mut bytes = [0x2a; 44];
    let mut packet = Packet::new_unchecked(&mut bytes[..]);
    let repr = create_repr(Message::MldReport);
    repr.emit(
        &IPV6_LINK_LOCAL_ALL_NODES,
        &IPV6_LINK_LOCAL_ALL_ROUTERS,
        &mut packet,
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &REPORT_PACKET_BYTES[..]);
}
