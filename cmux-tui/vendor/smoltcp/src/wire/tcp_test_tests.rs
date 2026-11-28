use super::*;
#[cfg(feature = "proto-ipv4")]
use crate::wire::Ipv4Address;

#[cfg(feature = "proto-ipv4")]
const SRC_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
#[cfg(feature = "proto-ipv4")]
const DST_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 2);

#[cfg(feature = "proto-ipv4")]
static PACKET_BYTES: [u8; 28] = [
    0xbf, 0x00, 0x00, 0x50, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x60, 0x35, 0x01, 0x23,
    0x01, 0xb6, 0x02, 0x01, 0x03, 0x03, 0x0c, 0x01, 0xaa, 0x00, 0x00, 0xff,
];

#[cfg(feature = "proto-ipv4")]
static OPTION_BYTES: [u8; 4] = [0x03, 0x03, 0x0c, 0x01];

#[cfg(feature = "proto-ipv4")]
static PAYLOAD_BYTES: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_deconstruct() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
    assert_eq!(packet.src_port(), 48896);
    assert_eq!(packet.dst_port(), 80);
    assert_eq!(packet.seq_number(), SeqNumber(0x01234567));
    assert_eq!(packet.ack_number(), SeqNumber(0x89abcdefu32 as i32));
    assert_eq!(packet.header_len(), 24);
    assert!(packet.fin());
    assert!(!packet.syn());
    assert!(packet.rst());
    assert!(!packet.psh());
    assert!(packet.ack());
    assert!(packet.urg());
    assert_eq!(packet.window_len(), 0x0123);
    assert_eq!(packet.urgent_at(), 0x0201);
    assert_eq!(packet.checksum(), 0x01b6);
    assert_eq!(packet.options(), &OPTION_BYTES[..]);
    assert_eq!(packet.payload(), &PAYLOAD_BYTES[..]);
    assert!(packet.verify_checksum(&SRC_ADDR.into(), &DST_ADDR.into()));
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_construct() {
    let mut bytes = vec![0xa5; PACKET_BYTES.len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_src_port(48896);
    packet.set_dst_port(80);
    packet.set_seq_number(SeqNumber(0x01234567));
    packet.set_ack_number(SeqNumber(0x89abcdefu32 as i32));
    packet.set_header_len(24);
    packet.clear_flags();
    packet.set_fin(true);
    packet.set_syn(false);
    packet.set_rst(true);
    packet.set_psh(false);
    packet.set_ack(true);
    packet.set_urg(true);
    packet.set_window_len(0x0123);
    packet.set_urgent_at(0x0201);
    packet.set_checksum(0xEEEE);
    packet.options_mut().copy_from_slice(&OPTION_BYTES[..]);
    packet.payload_mut().copy_from_slice(&PAYLOAD_BYTES[..]);
    packet.fill_checksum(&SRC_ADDR.into(), &DST_ADDR.into());
    assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_truncated() {
    let packet = Packet::new_unchecked(&PACKET_BYTES[..23]);
    assert_eq!(packet.check_len(), Err(Error));
}

#[test]
fn test_impossible_len() {
    let mut bytes = vec![0; 20];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_header_len(10);
    assert_eq!(packet.check_len(), Err(Error));
}

#[cfg(feature = "proto-ipv4")]
static SYN_PACKET_BYTES: [u8; 24] = [
    0xbf, 0x00, 0x00, 0x50, 0x01, 0x23, 0x45, 0x67, 0x00, 0x00, 0x00, 0x00, 0x50, 0x02, 0x01, 0x23,
    0x7a, 0x8d, 0x00, 0x00, 0xaa, 0x00, 0x00, 0xff,
];

#[cfg(feature = "proto-ipv4")]
fn packet_repr() -> Repr<'static> {
    Repr {
        src_port: 48896,
        dst_port: 80,
        seq_number: SeqNumber(0x01234567),
        ack_number: None,
        window_len: 0x0123,
        window_scale: None,
        control: Control::Syn,
        max_seg_size: None,
        sack_permitted: false,
        sack_ranges: [None, None, None],
        timestamp: None,
        payload: &PAYLOAD_BYTES,
    }
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_parse() {
    let packet = Packet::new_unchecked(&SYN_PACKET_BYTES[..]);
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
    let mut bytes = vec![0xa5; repr.buffer_len()];
    let mut packet = Packet::new_unchecked(&mut bytes);
    repr.emit(
        &mut packet,
        &SRC_ADDR.into(),
        &DST_ADDR.into(),
        &ChecksumCapabilities::default(),
    );
    assert_eq!(&*packet.into_inner(), &SYN_PACKET_BYTES[..]);
}

#[test]
#[cfg(feature = "proto-ipv4")]
fn test_header_len_multiple_of_4() {
    let mut repr = packet_repr();
    repr.window_scale = Some(0); // This TCP Option needs 3 bytes.
    assert_eq!(repr.header_len() % 4, 0); // Should e.g. be 28 instead of 27.
}

macro_rules! assert_option_parses {
    ($opt:expr, $data:expr) => {{
        assert_eq!(TcpOption::parse($data), Ok((&[][..], $opt)));
        let buffer = &mut [0; 40][..$opt.buffer_len()];
        assert_eq!($opt.emit(buffer), &mut []);
        assert_eq!(&*buffer, $data);
    }};
}

#[test]
fn test_tcp_options() {
    assert_option_parses!(TcpOption::EndOfList, &[0x00]);
    assert_option_parses!(TcpOption::NoOperation, &[0x01]);
    assert_option_parses!(TcpOption::MaxSegmentSize(1500), &[0x02, 0x04, 0x05, 0xdc]);
    assert_option_parses!(TcpOption::WindowScale(12), &[0x03, 0x03, 0x0c]);
    assert_option_parses!(TcpOption::SackPermitted, &[0x4, 0x02]);
    assert_option_parses!(
        TcpOption::SackRange([Some((500, 1500)), None, None]),
        &[0x05, 0x0a, 0x00, 0x00, 0x01, 0xf4, 0x00, 0x00, 0x05, 0xdc]
    );
    assert_option_parses!(
        TcpOption::SackRange([Some((875, 1225)), Some((1500, 2500)), None]),
        &[
            0x05, 0x12, 0x00, 0x00, 0x03, 0x6b, 0x00, 0x00, 0x04, 0xc9, 0x00, 0x00, 0x05, 0xdc,
            0x00, 0x00, 0x09, 0xc4
        ]
    );
    assert_option_parses!(
        TcpOption::SackRange([
            Some((875000, 1225000)),
            Some((1500000, 2500000)),
            Some((876543210, 876654320))
        ]),
        &[
            0x05, 0x1a, 0x00, 0x0d, 0x59, 0xf8, 0x00, 0x12, 0xb1, 0x28, 0x00, 0x16, 0xe3, 0x60,
            0x00, 0x26, 0x25, 0xa0, 0x34, 0x3e, 0xfc, 0xea, 0x34, 0x40, 0xae, 0xf0
        ]
    );
    assert_option_parses!(
        TcpOption::TimeStamp {
            tsval: 5000000,
            tsecr: 7000000
        },
        &[
            0x08, // data length
            0x0a, // type
            0x00, 0x4c, 0x4b, 0x40, //tsval
            0x00, 0x6a, 0xcf, 0xc0 //tsecr
        ]
    );
    assert_option_parses!(
        TcpOption::Unknown {
            kind: 12,
            data: &[1, 2, 3][..]
        },
        &[0x0c, 0x05, 0x01, 0x02, 0x03]
    )
}

#[test]
fn test_malformed_tcp_options() {
    assert_eq!(TcpOption::parse(&[]), Err(Error));
    assert_eq!(TcpOption::parse(&[0xc]), Err(Error));
    assert_eq!(TcpOption::parse(&[0xc, 0x05, 0x01, 0x02]), Err(Error));
    assert_eq!(TcpOption::parse(&[0xc, 0x01]), Err(Error));
    assert_eq!(TcpOption::parse(&[0x2, 0x02]), Err(Error));
    assert_eq!(TcpOption::parse(&[0x3, 0x02]), Err(Error));
}

#[test]
fn test_tcp_options_summary() {
    let mut bytes = vec![0; 32];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_header_len(32);
    // MSS=1460 (4b: 02 04 05 b4), WS=7 (3b: 03 03 07), SACK_PERM (2b: 04 02), NOP (1b: 01), END (1b: 00)
    let options_bytes: [u8; 12] = [
        0x02, 0x04, 0x05, 0xb4, 0x03, 0x03, 0x07, 0x04, 0x02, 0x01, 0x00, 0x00,
    ];
    packet.options_mut()[..12].copy_from_slice(&options_bytes);

    let summary = packet.options_summary().unwrap();
    assert_eq!(summary.max_segment_size, Some(1460));
    assert_eq!(summary.window_scale, Some(7));
    assert!(summary.sack_permitted);
    assert_eq!(summary.sack_ranges, [None, None, None]);
}
