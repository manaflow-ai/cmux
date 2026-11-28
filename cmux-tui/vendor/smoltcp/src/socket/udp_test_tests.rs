use super::*;
use crate::wire::{IpRepr, UdpRepr};

use crate::phy::Medium;
use crate::tests::setup;
use rstest::*;

fn buffer(packets: usize) -> PacketBuffer<'static> {
    PacketBuffer::new(
        (0..packets)
            .map(|_| PacketMetadata::EMPTY)
            .collect::<Vec<_>>(),
        vec![0; 16 * packets],
    )
}

fn socket(rx_buffer: PacketBuffer<'static>, tx_buffer: PacketBuffer<'static>) -> Socket<'static> {
    Socket::new(rx_buffer, tx_buffer)
}

const LOCAL_PORT: u16 = 53;
const REMOTE_PORT: u16 = 49500;

cfg_if::cfg_if! {
    if #[cfg(feature = "proto-ipv4")] {
        use crate::wire::Ipv4Address as IpvXAddress;
        use crate::wire::Ipv4Repr as IpvXRepr;
        use IpRepr::Ipv4 as IpReprIpvX;

        const LOCAL_ADDR: IpvXAddress = IpvXAddress::new(192, 168, 1, 1);
        const REMOTE_ADDR: IpvXAddress = IpvXAddress::new(192, 168, 1, 2);
        const OTHER_ADDR: IpvXAddress = IpvXAddress::new(192, 168, 1, 3);

        const LOCAL_END: IpEndpoint = IpEndpoint {
            addr: IpAddress::Ipv4(LOCAL_ADDR),
            port: LOCAL_PORT,
        };
        const REMOTE_END: IpEndpoint = IpEndpoint {
            addr: IpAddress::Ipv4(REMOTE_ADDR),
            port: REMOTE_PORT,
        };
    } else {
        use crate::wire::Ipv6Address as IpvXAddress;
        use crate::wire::Ipv6Repr as IpvXRepr;
        use IpRepr::Ipv6 as IpReprIpvX;

        const LOCAL_ADDR: IpvXAddress = IpvXAddress::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
        const REMOTE_ADDR: IpvXAddress = IpvXAddress::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);
        const OTHER_ADDR: IpvXAddress = IpvXAddress::new(0xfe80, 0, 0, 0, 0, 0, 0, 3);

        const LOCAL_END: IpEndpoint = IpEndpoint {
            addr: IpAddress::Ipv6(LOCAL_ADDR),
            port: LOCAL_PORT,
        };
        const REMOTE_END: IpEndpoint = IpEndpoint {
            addr: IpAddress::Ipv6(REMOTE_ADDR),
            port: REMOTE_PORT,
        };
    }
}

fn remote_metadata_with_local() -> UdpMetadata {
    // Would be great as a const once we have const `.into()`.
    UdpMetadata {
        local_address: Some(LOCAL_ADDR.into()),
        ..REMOTE_END.into()
    }
}

pub const LOCAL_IP_REPR: IpRepr = IpReprIpvX(IpvXRepr {
    src_addr: LOCAL_ADDR,
    dst_addr: REMOTE_ADDR,
    next_header: IpProtocol::Udp,
    payload_len: 8 + 6,
    hop_limit: 64,
});

pub const REMOTE_IP_REPR: IpRepr = IpReprIpvX(IpvXRepr {
    src_addr: REMOTE_ADDR,
    dst_addr: LOCAL_ADDR,
    next_header: IpProtocol::Udp,
    payload_len: 8 + 6,
    hop_limit: 64,
});

pub const BAD_IP_REPR: IpRepr = IpReprIpvX(IpvXRepr {
    src_addr: REMOTE_ADDR,
    dst_addr: OTHER_ADDR,
    next_header: IpProtocol::Udp,
    payload_len: 8 + 6,
    hop_limit: 64,
});

const LOCAL_UDP_REPR: UdpRepr = UdpRepr {
    src_port: LOCAL_PORT,
    dst_port: REMOTE_PORT,
};

const REMOTE_UDP_REPR: UdpRepr = UdpRepr {
    src_port: REMOTE_PORT,
    dst_port: LOCAL_PORT,
};

const PAYLOAD: &[u8] = b"abcdef";

#[test]
fn test_bind_unaddressable() {
    let mut socket = socket(buffer(0), buffer(0));
    assert_eq!(socket.bind(0), Err(BindError::Unaddressable));
}

#[test]
fn test_bind_twice() {
    let mut socket = socket(buffer(0), buffer(0));
    assert_eq!(socket.bind(1), Ok(()));
    assert_eq!(socket.bind(2), Err(BindError::InvalidState));
}

#[test]
#[should_panic(expected = "the time-to-live value of a packet must not be zero")]
fn test_set_hop_limit_zero() {
    let mut s = socket(buffer(0), buffer(1));
    s.set_hop_limit(Some(0));
}

#[test]
fn test_send_unaddressable() {
    let mut socket = socket(buffer(0), buffer(1));

    assert_eq!(
        socket.send_slice(b"abcdef", REMOTE_END),
        Err(SendError::Unaddressable)
    );
    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));
    assert_eq!(
        socket.send_slice(
            b"abcdef",
            IpEndpoint {
                addr: IpvXAddress::UNSPECIFIED.into(),
                ..REMOTE_END
            }
        ),
        Err(SendError::Unaddressable)
    );
    assert_eq!(
        socket.send_slice(
            b"abcdef",
            IpEndpoint {
                port: 0,
                ..REMOTE_END
            }
        ),
        Err(SendError::Unaddressable)
    );
    assert_eq!(socket.send_slice(b"abcdef", REMOTE_END), Ok(()));
}

#[test]
fn test_send_with_source() {
    let mut socket = socket(buffer(0), buffer(1));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));
    assert_eq!(
        socket.send_slice(b"abcdef", remote_metadata_with_local()),
        Ok(())
    );
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_send_dispatch(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();
    let mut socket = socket(buffer(0), buffer(1));

    assert_eq!(socket.bind(LOCAL_END), Ok(()));

    assert!(socket.can_send());
    assert_eq!(
        socket.dispatch(cx, |_, _, _| unreachable!()),
        Ok::<_, ()>(())
    );

    assert_eq!(socket.send_slice(b"abcdef", REMOTE_END), Ok(()));
    assert_eq!(
        socket.send_slice(b"123456", REMOTE_END),
        Err(SendError::BufferFull)
    );
    assert!(!socket.can_send());

    assert_eq!(
        socket.dispatch(cx, |_, _, (ip_repr, udp_repr, payload)| {
            assert_eq!(ip_repr, LOCAL_IP_REPR);
            assert_eq!(udp_repr, LOCAL_UDP_REPR);
            assert_eq!(payload, PAYLOAD);
            Err(())
        }),
        Err(())
    );
    assert!(!socket.can_send());

    assert_eq!(
        socket.dispatch(cx, |_, _, (ip_repr, udp_repr, payload)| {
            assert_eq!(ip_repr, LOCAL_IP_REPR);
            assert_eq!(udp_repr, LOCAL_UDP_REPR);
            assert_eq!(payload, PAYLOAD);
            Ok::<_, ()>(())
        }),
        Ok(())
    );
    assert!(socket.can_send());
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_recv_process(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut socket = socket(buffer(1), buffer(0));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    assert!(!socket.can_recv());
    assert_eq!(socket.recv(), Err(RecvError::Exhausted));

    assert!(socket.accepts(cx, &REMOTE_IP_REPR, &REMOTE_UDP_REPR));
    socket.process(
        cx,
        PacketMeta::default(),
        &REMOTE_IP_REPR,
        &REMOTE_UDP_REPR,
        PAYLOAD,
    );
    assert!(socket.can_recv());

    assert!(socket.accepts(cx, &REMOTE_IP_REPR, &REMOTE_UDP_REPR));
    socket.process(
        cx,
        PacketMeta::default(),
        &REMOTE_IP_REPR,
        &REMOTE_UDP_REPR,
        PAYLOAD,
    );

    assert_eq!(
        socket.recv(),
        Ok((&b"abcdef"[..], remote_metadata_with_local()))
    );
    assert!(!socket.can_recv());
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_peek_process(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut socket = socket(buffer(1), buffer(0));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    assert_eq!(socket.peek(), Err(RecvError::Exhausted));

    socket.process(
        cx,
        PacketMeta::default(),
        &REMOTE_IP_REPR,
        &REMOTE_UDP_REPR,
        PAYLOAD,
    );
    assert_eq!(
        socket.peek(),
        Ok((&b"abcdef"[..], &remote_metadata_with_local(),))
    );
    assert_eq!(
        socket.recv(),
        Ok((&b"abcdef"[..], remote_metadata_with_local(),))
    );
    assert_eq!(socket.peek(), Err(RecvError::Exhausted));
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_recv_truncated_slice(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut socket = socket(buffer(1), buffer(0));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    assert!(socket.accepts(cx, &REMOTE_IP_REPR, &REMOTE_UDP_REPR));
    socket.process(
        cx,
        PacketMeta::default(),
        &REMOTE_IP_REPR,
        &REMOTE_UDP_REPR,
        PAYLOAD,
    );

    let mut slice = [0; 4];
    assert_eq!(socket.recv_slice(&mut slice[..]), Err(RecvError::Truncated));
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_peek_truncated_slice(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut socket = socket(buffer(1), buffer(0));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    socket.process(
        cx,
        PacketMeta::default(),
        &REMOTE_IP_REPR,
        &REMOTE_UDP_REPR,
        PAYLOAD,
    );

    let mut slice = [0; 4];
    assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Truncated));
    assert_eq!(socket.recv_slice(&mut slice[..]), Err(RecvError::Truncated));
    assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Exhausted));
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_set_hop_limit(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut s = socket(buffer(0), buffer(1));

    assert_eq!(s.bind(LOCAL_END), Ok(()));

    s.set_hop_limit(Some(0x2a));
    assert_eq!(s.send_slice(b"abcdef", REMOTE_END), Ok(()));
    assert_eq!(
        s.dispatch(cx, |_, _, (ip_repr, _, _)| {
            assert_eq!(
                ip_repr,
                IpReprIpvX(IpvXRepr {
                    src_addr: LOCAL_ADDR,
                    dst_addr: REMOTE_ADDR,
                    next_header: IpProtocol::Udp,
                    payload_len: 8 + 6,
                    hop_limit: 0x2a,
                })
            );
            Ok::<_, ()>(())
        }),
        Ok(())
    );
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_doesnt_accept_wrong_port(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut socket = socket(buffer(1), buffer(0));

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    let mut udp_repr = REMOTE_UDP_REPR;
    assert!(socket.accepts(cx, &REMOTE_IP_REPR, &udp_repr));
    udp_repr.dst_port += 1;
    assert!(!socket.accepts(cx, &REMOTE_IP_REPR, &udp_repr));
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_doesnt_accept_wrong_ip(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    let mut port_bound_socket = socket(buffer(1), buffer(0));
    assert_eq!(port_bound_socket.bind(LOCAL_PORT), Ok(()));
    assert!(port_bound_socket.accepts(cx, &BAD_IP_REPR, &REMOTE_UDP_REPR));

    let mut ip_bound_socket = socket(buffer(1), buffer(0));
    assert_eq!(ip_bound_socket.bind(LOCAL_END), Ok(()));
    assert!(!ip_bound_socket.accepts(cx, &BAD_IP_REPR, &REMOTE_UDP_REPR));
}

#[test]
fn test_send_large_packet() {
    // buffer(4) creates a payload buffer of size 16*4
    let mut socket = socket(buffer(0), buffer(4));
    assert_eq!(socket.bind(LOCAL_END), Ok(()));

    let too_large = b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefx";
    assert_eq!(
        socket.send_slice(too_large, REMOTE_END),
        Err(SendError::BufferFull)
    );
    assert_eq!(socket.send_slice(&too_large[..16 * 4], REMOTE_END), Ok(()));
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_process_empty_payload(#[case] medium: Medium) {
    let meta = Box::leak(Box::new([PacketMetadata::EMPTY]));
    let recv_buffer = PacketBuffer::new(&mut meta[..], vec![]);
    let mut socket = socket(recv_buffer, buffer(0));

    let (mut iface, _, _) = setup(medium);
    let cx = iface.context();

    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    let repr = UdpRepr {
        src_port: REMOTE_PORT,
        dst_port: LOCAL_PORT,
    };
    socket.process(cx, PacketMeta::default(), &REMOTE_IP_REPR, &repr, &[]);
    assert_eq!(socket.recv(), Ok((&[][..], remote_metadata_with_local())));
}

#[test]
fn test_closing() {
    let meta = Box::leak(Box::new([PacketMetadata::EMPTY]));
    let recv_buffer = PacketBuffer::new(&mut meta[..], vec![]);
    let mut socket = socket(recv_buffer, buffer(0));
    assert_eq!(socket.bind(LOCAL_PORT), Ok(()));

    assert!(socket.is_open());
    socket.close();
    assert!(!socket.is_open());
}
