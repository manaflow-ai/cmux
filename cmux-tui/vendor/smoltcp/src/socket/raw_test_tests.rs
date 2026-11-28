use crate::phy::Medium;
use crate::tests::setup;
use rstest::*;

use super::*;
use crate::wire::IpRepr;
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Ipv4Address, Ipv4Repr};
#[cfg(feature = "proto-ipv6")]
use crate::wire::{Ipv6Address, Ipv6Repr};

fn buffer(packets: usize) -> PacketBuffer<'static> {
    PacketBuffer::new(vec![PacketMetadata::EMPTY; packets], vec![0; 48 * packets])
}

#[cfg(feature = "proto-ipv4")]
mod ipv4_locals {
    use super::*;

    pub fn socket(
        rx_buffer: PacketBuffer<'static>,
        tx_buffer: PacketBuffer<'static>,
    ) -> Socket<'static> {
        Socket::new(
            Some(IpVersion::Ipv4),
            Some(IpProtocol::Unknown(IP_PROTO)),
            rx_buffer,
            tx_buffer,
        )
    }

    pub const IP_PROTO: u8 = 63;
    pub const HEADER_REPR: IpRepr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: Ipv4Address::new(10, 0, 0, 1),
        dst_addr: Ipv4Address::new(10, 0, 0, 2),
        next_header: IpProtocol::Unknown(IP_PROTO),
        payload_len: 4,
        hop_limit: 64,
    });
    pub const PACKET_BYTES: [u8; 24] = [
        0x45, 0x00, 0x00, 0x18, 0x00, 0x00, 0x40, 0x00, 0x40, 0x3f, 0x00, 0x00, 0x0a, 0x00, 0x00,
        0x01, 0x0a, 0x00, 0x00, 0x02, 0xaa, 0x00, 0x00, 0xff,
    ];
    pub const PACKET_PAYLOAD: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];
}

#[cfg(feature = "proto-ipv6")]
mod ipv6_locals {
    use super::*;

    pub fn socket(
        rx_buffer: PacketBuffer<'static>,
        tx_buffer: PacketBuffer<'static>,
    ) -> Socket<'static> {
        Socket::new(
            Some(IpVersion::Ipv6),
            Some(IpProtocol::Unknown(IP_PROTO)),
            rx_buffer,
            tx_buffer,
        )
    }

    pub const IP_PROTO: u8 = 63;
    pub const HEADER_REPR: IpRepr = IpRepr::Ipv6(Ipv6Repr {
        src_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
        dst_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2),
        next_header: IpProtocol::Unknown(IP_PROTO),
        payload_len: 4,
        hop_limit: 64,
    });

    pub const PACKET_BYTES: [u8; 44] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x04, 0x3f, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xaa, 0x00, 0x00, 0xff,
    ];

    pub const PACKET_PAYLOAD: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];
}

macro_rules! reusable_ip_specific_tests {
    ($module:ident, $socket:path, $hdr:path, $packet:path, $payload:path) => {
        mod $module {
            use super::*;

            #[test]
            fn test_send_truncated() {
                let mut socket = $socket(buffer(0), buffer(1));
                assert_eq!(socket.send_slice(&[0; 56][..]), Err(SendError::BufferFull));
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
                let mut cx = iface.context();
                let mut socket = $socket(buffer(0), buffer(1));

                assert!(socket.can_send());
                assert_eq!(
                    socket.dispatch(&mut cx, |_, _| unreachable!()),
                    Ok::<_, ()>(())
                );

                assert_eq!(socket.send_slice(&$packet[..]), Ok(()));
                assert_eq!(socket.send_slice(b""), Err(SendError::BufferFull));
                assert!(!socket.can_send());

                assert_eq!(
                    socket.dispatch(&mut cx, |_, (ip_repr, ip_payload)| {
                        assert_eq!(ip_repr, $hdr);
                        assert_eq!(ip_payload, &$payload);
                        Err(())
                    }),
                    Err(())
                );
                assert!(!socket.can_send());

                assert_eq!(
                    socket.dispatch(&mut cx, |_, (ip_repr, ip_payload)| {
                        assert_eq!(ip_repr, $hdr);
                        assert_eq!(ip_payload, &$payload);
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
            fn test_recv_truncated_slice(#[case] medium: Medium) {
                let (mut iface, _, _) = setup(medium);
                let mut cx = iface.context();
                let mut socket = $socket(buffer(1), buffer(0));

                assert!(socket.accepts(&$hdr));
                socket.process(&mut cx, &$hdr, &$payload);

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
            fn test_recv_truncated_packet(#[case] medium: Medium) {
                let (mut iface, _, _) = setup(medium);
                let mut cx = iface.context();
                let mut socket = $socket(buffer(1), buffer(0));

                let mut buffer = vec![0; 128];
                buffer[..$packet.len()].copy_from_slice(&$packet[..]);

                assert!(socket.accepts(&$hdr));
                socket.process(&mut cx, &$hdr, &buffer);
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
                let mut cx = iface.context();
                let mut socket = $socket(buffer(1), buffer(0));

                assert!(socket.accepts(&$hdr));
                socket.process(&mut cx, &$hdr, &$payload);

                let mut slice = [0; 4];
                assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Truncated));
                assert_eq!(socket.recv_slice(&mut slice[..]), Err(RecvError::Truncated));
                assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Exhausted));
            }
        }
    };
}

#[cfg(feature = "proto-ipv4")]
reusable_ip_specific_tests!(
    ipv4,
    ipv4_locals::socket,
    ipv4_locals::HEADER_REPR,
    ipv4_locals::PACKET_BYTES,
    ipv4_locals::PACKET_PAYLOAD
);

#[cfg(feature = "proto-ipv6")]
reusable_ip_specific_tests!(
    ipv6,
    ipv6_locals::socket,
    ipv6_locals::HEADER_REPR,
    ipv6_locals::PACKET_BYTES,
    ipv6_locals::PACKET_PAYLOAD
);

#[rstest]
#[case::ip(Medium::Ip)]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_send_illegal(#[case] medium: Medium) {
    #[cfg(feature = "proto-ipv4")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv4_locals::socket(buffer(0), buffer(2));

        let mut wrong_version = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut wrong_version).set_version(6);

        assert_eq!(socket.send_slice(&wrong_version[..]), Ok(()));
        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

        let mut wrong_protocol = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut wrong_protocol).set_next_header(IpProtocol::Tcp);

        assert_eq!(socket.send_slice(&wrong_protocol[..]), Ok(()));
        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv6_locals::socket(buffer(0), buffer(2));

        let mut wrong_version = ipv6_locals::PACKET_BYTES;
        Ipv6Packet::new_unchecked(&mut wrong_version[..]).set_version(4);

        assert_eq!(socket.send_slice(&wrong_version[..]), Ok(()));
        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

        let mut wrong_protocol = ipv6_locals::PACKET_BYTES;
        Ipv6Packet::new_unchecked(&mut wrong_protocol[..]).set_next_header(IpProtocol::Tcp);

        assert_eq!(socket.send_slice(&wrong_protocol[..]), Ok(()));
        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));
    }
}

#[rstest]
#[case::ip(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_recv_process(#[case] medium: Medium) {
    #[cfg(feature = "proto-ipv4")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv4_locals::socket(buffer(1), buffer(0));
        assert!(!socket.can_recv());

        let mut cksumd_packet = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut cksumd_packet).fill_checksum();

        assert_eq!(socket.recv(), Err(RecvError::Exhausted));
        assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
        socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
        assert!(socket.can_recv());

        assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
        socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
        assert_eq!(socket.recv(), Ok(&cksumd_packet[..]));
        assert!(!socket.can_recv());
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv6_locals::socket(buffer(1), buffer(0));
        assert!(!socket.can_recv());

        assert_eq!(socket.recv(), Err(RecvError::Exhausted));
        assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
        socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
        assert!(socket.can_recv());

        assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
        socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
        assert_eq!(socket.recv(), Ok(&ipv6_locals::PACKET_BYTES[..]));
        assert!(!socket.can_recv());
    }
}

#[rstest]
#[case::ip(Medium::Ip)]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_peek_process(#[case] medium: Medium) {
    #[cfg(feature = "proto-ipv4")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv4_locals::socket(buffer(1), buffer(0));

        let mut cksumd_packet = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut cksumd_packet).fill_checksum();

        assert_eq!(socket.peek(), Err(RecvError::Exhausted));
        assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
        socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);

        assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
        socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
        assert_eq!(socket.peek(), Ok(&cksumd_packet[..]));
        assert_eq!(socket.recv(), Ok(&cksumd_packet[..]));
        assert_eq!(socket.peek(), Err(RecvError::Exhausted));
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();
        let mut socket = ipv6_locals::socket(buffer(1), buffer(0));

        assert_eq!(socket.peek(), Err(RecvError::Exhausted));
        assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
        socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);

        assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
        socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
        assert_eq!(socket.peek(), Ok(&ipv6_locals::PACKET_BYTES[..]));
        assert_eq!(socket.recv(), Ok(&ipv6_locals::PACKET_BYTES[..]));
        assert_eq!(socket.peek(), Err(RecvError::Exhausted));
    }
}

#[test]
fn test_doesnt_accept_wrong_proto() {
    #[cfg(feature = "proto-ipv4")]
    {
        let socket = Socket::new(
            Some(IpVersion::Ipv4),
            Some(IpProtocol::Unknown(ipv4_locals::IP_PROTO + 1)),
            buffer(1),
            buffer(1),
        );
        assert!(!socket.accepts(&ipv4_locals::HEADER_REPR));
        #[cfg(feature = "proto-ipv6")]
        assert!(!socket.accepts(&ipv6_locals::HEADER_REPR));
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let socket = Socket::new(
            Some(IpVersion::Ipv6),
            Some(IpProtocol::Unknown(ipv6_locals::IP_PROTO + 1)),
            buffer(1),
            buffer(1),
        );
        assert!(!socket.accepts(&ipv6_locals::HEADER_REPR));
        #[cfg(feature = "proto-ipv4")]
        assert!(!socket.accepts(&ipv4_locals::HEADER_REPR));
    }
}

fn check_dispatch(socket: &mut Socket<'_>, cx: &mut Context) {
    // Check dispatch returns Ok(()) and calls the emit closure
    let mut emitted = false;
    assert_eq!(
        socket.dispatch(cx, |_, _| {
            emitted = true;
            Ok(())
        }),
        Ok::<_, ()>(())
    );
    assert!(emitted);
}

#[rstest]
#[case::ip(Medium::Ip)]
#[case::ethernet(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
#[case::ieee802154(Medium::Ieee802154)]
#[cfg(feature = "medium-ieee802154")]
fn test_unfiltered_sends_all(#[case] medium: Medium) {
    // Test a single unfiltered socket can send packets with different IP versions and next
    // headers
    let mut socket = Socket::new(None, None, buffer(0), buffer(2));
    #[cfg(feature = "proto-ipv4")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut udp_packet = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut udp_packet).set_next_header(IpProtocol::Udp);

        assert_eq!(socket.send_slice(&udp_packet), Ok(()));
        check_dispatch(&mut socket, cx);

        let mut tcp_packet = ipv4_locals::PACKET_BYTES;
        Ipv4Packet::new_unchecked(&mut tcp_packet).set_next_header(IpProtocol::Tcp);

        assert_eq!(socket.send_slice(&tcp_packet[..]), Ok(()));
        check_dispatch(&mut socket, cx);
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut udp_packet = ipv6_locals::PACKET_BYTES;
        Ipv6Packet::new_unchecked(&mut udp_packet).set_next_header(IpProtocol::Udp);

        assert_eq!(socket.send_slice(&ipv6_locals::PACKET_BYTES), Ok(()));
        check_dispatch(&mut socket, cx);

        let mut tcp_packet = ipv6_locals::PACKET_BYTES;
        Ipv6Packet::new_unchecked(&mut tcp_packet).set_next_header(IpProtocol::Tcp);

        assert_eq!(socket.send_slice(&tcp_packet[..]), Ok(()));
        check_dispatch(&mut socket, cx);
    }
}

#[rstest]
#[case::proto(IpProtocol::Icmp)]
#[case::proto(IpProtocol::Tcp)]
#[case::proto(IpProtocol::Udp)]
fn test_unfiltered_accepts_all(#[case] proto: IpProtocol) {
    // Test an unfiltered socket can accept packets with different IP versions and next headers
    let socket = Socket::new(None, None, buffer(0), buffer(0));
    #[cfg(feature = "proto-ipv4")]
    {
        let header_repr = IpRepr::Ipv4(Ipv4Repr {
            src_addr: Ipv4Address::new(10, 0, 0, 1),
            dst_addr: Ipv4Address::new(10, 0, 0, 2),
            next_header: proto,
            payload_len: 4,
            hop_limit: 64,
        });
        assert!(socket.accepts(&header_repr));
    }
    #[cfg(feature = "proto-ipv6")]
    {
        let header_repr = IpRepr::Ipv6(Ipv6Repr {
            src_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            dst_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2),
            next_header: proto,
            payload_len: 4,
            hop_limit: 64,
        });
        assert!(socket.accepts(&header_repr));
    }
}
