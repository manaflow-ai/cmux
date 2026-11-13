use super::*;

#[rstest]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_any_ip_accept_arp(#[case] medium: Medium) {
    let mut buffer = [0u8; 64];
    #[allow(non_snake_case)]
    fn ETHERNET_FRAME_ARP(buffer: &mut [u8]) -> &[u8] {
        let ethernet_repr = EthernetRepr {
            src_addr: EthernetAddress::from_bytes(&[0x02, 0x02, 0x02, 0x02, 0x02, 0x03]),
            dst_addr: EthernetAddress::from_bytes(&[0x02, 0x02, 0x02, 0x02, 0x02, 0x02]),
            ethertype: EthernetProtocol::Arp,
        };
        let frame_repr = ArpRepr::EthernetIpv4 {
            operation: ArpOperation::Request,
            source_hardware_addr: EthernetAddress::from_bytes(&[
                0x02, 0x02, 0x02, 0x02, 0x02, 0x03,
            ]),
            source_protocol_addr: Ipv4Address::from_octets([192, 168, 1, 2]),
            target_hardware_addr: EthernetAddress::from_bytes(&[
                0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
            ]),
            target_protocol_addr: Ipv4Address::from_octets([192, 168, 1, 3]),
        };
        let mut frame = EthernetFrame::new_unchecked(&mut buffer[..]);
        ethernet_repr.emit(&mut frame);

        let mut frame = ArpPacket::new_unchecked(&mut buffer[ethernet_repr.buffer_len()..]);
        frame_repr.emit(&mut frame);

        &buffer[..ethernet_repr.buffer_len() + frame_repr.buffer_len()]
    }

    let (mut iface, mut sockets, _) = setup(medium);

    assert!(
        iface
            .inner
            .process_ethernet(
                &mut sockets,
                PacketMeta::default(),
                ETHERNET_FRAME_ARP(buffer.as_mut()),
                &mut iface.fragments,
            )
            .is_none()
    );

    // Accept any IP address
    iface.set_any_ip(true);

    assert!(
        iface
            .inner
            .process_ethernet(
                &mut sockets,
                PacketMeta::default(),
                ETHERNET_FRAME_ARP(buffer.as_mut()),
                &mut iface.fragments,
            )
            .is_some()
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_no_icmp_no_unicast(#[case] medium: Medium) {
    let (mut iface, mut sockets, _) = setup(medium);

    // Unknown Ipv4 Protocol
    //
    // Because the destination is the broadcast address
    // this should not trigger and Destination Unreachable
    // response. See RFC 1122 § 3.2.2.
    let repr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Unknown(0x0c),
        payload_len: 0,
        hop_limit: 0x40,
    });

    let mut bytes = vec![0u8; 54];
    repr.emit(&mut bytes, &ChecksumCapabilities::default());
    let frame = Ipv4Packet::new_unchecked(&bytes[..]);

    // Ensure that the unknown protocol frame does not trigger an
    // ICMP error response when the destination address is a
    // broadcast address

    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frame,
            &mut iface.fragments
        ),
        None
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_icmp_error_no_payload(#[case] medium: Medium) {
    static NO_BYTES: [u8; 0] = [];
    let (mut iface, mut sockets, _device) = setup(medium);

    // Unknown Ipv4 Protocol with no payload
    let repr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
        dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
        next_header: IpProtocol::Unknown(0x0c),
        payload_len: 0,
        hop_limit: 0x40,
    });

    let mut bytes = vec![0u8; 34];
    repr.emit(&mut bytes, &ChecksumCapabilities::default());
    let frame = Ipv4Packet::new_unchecked(&bytes[..]);

    // The expected Destination Unreachable response due to the
    // unknown protocol
    let icmp_repr = Icmpv4Repr::DstUnreachable {
        reason: Icmpv4DstUnreachable::ProtoUnreachable,
        header: Ipv4Repr {
            src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
            dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
            next_header: IpProtocol::Unknown(12),
            payload_len: 0,
            hop_limit: 64,
        },
        data: &NO_BYTES,
    };

    let expected_repr = Packet::new_ipv4(
        Ipv4Repr {
            src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
            dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
            next_header: IpProtocol::Icmp,
            payload_len: icmp_repr.buffer_len(),
            hop_limit: 64,
        },
        IpPayload::Icmpv4(icmp_repr),
    );

    // Ensure that the unknown protocol triggers an error response.
    // And we correctly handle no payload.

    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frame,
            &mut iface.fragments
        ),
        Some(expected_repr)
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_local_subnet_broadcasts(#[case] medium: Medium) {
    let (mut iface, _, _device) = setup(medium);
    iface.update_ip_addrs(|addrs| {
        addrs.iter_mut().next().map(|addr| {
            *addr = IpCidr::Ipv4(Ipv4Cidr::new(Ipv4Address::new(192, 168, 1, 23), 24));
        });
    });

    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 254))
    );
    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 1, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 1, 254))
    );

    iface.update_ip_addrs(|addrs| {
        addrs.iter_mut().next().map(|addr| {
            *addr = IpCidr::Ipv4(Ipv4Cidr::new(Ipv4Address::new(192, 168, 23, 24), 16));
        });
    });
    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 254))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 23, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 23, 254))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 255, 254))
    );
    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 168, 255, 255))
    );

    iface.update_ip_addrs(|addrs| {
        addrs.iter_mut().next().map(|addr| {
            *addr = IpCidr::Ipv4(Ipv4Cidr::new(Ipv4Address::new(192, 168, 23, 24), 8));
        });
    });
    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(255, 255, 255, 254))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 23, 1, 255))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 23, 1, 254))
    );
    assert!(
        !iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 255, 255, 254))
    );
    assert!(
        iface
            .inner
            .is_broadcast_v4(Ipv4Address::new(192, 255, 255, 255))
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "medium-ip", feature = "socket-udp"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "medium-ethernet", feature = "socket-udp"))]
fn test_icmp_error_port_unreachable(#[case] medium: Medium) {
    static UDP_PAYLOAD: [u8; 12] = [
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x6c, 0x64, 0x21,
    ];
    let (mut iface, mut sockets, _device) = setup(medium);

    let mut udp_bytes_unicast = vec![0u8; 20];
    let mut udp_bytes_broadcast = vec![0u8; 20];
    let mut packet_unicast = UdpPacket::new_unchecked(&mut udp_bytes_unicast);
    let mut packet_broadcast = UdpPacket::new_unchecked(&mut udp_bytes_broadcast);

    let udp_repr = UdpRepr {
        src_port: 67,
        dst_port: 68,
    };

    let ip_repr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
        dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
        next_header: IpProtocol::Udp,
        payload_len: udp_repr.header_len() + UDP_PAYLOAD.len(),
        hop_limit: 64,
    });

    // Emit the representations to a packet
    udp_repr.emit(
        &mut packet_unicast,
        &ip_repr.src_addr(),
        &ip_repr.dst_addr(),
        UDP_PAYLOAD.len(),
        |buf| buf.copy_from_slice(&UDP_PAYLOAD),
        &ChecksumCapabilities::default(),
    );

    let data = packet_unicast.into_inner();

    // The expected Destination Unreachable ICMPv4 error response due
    // to no sockets listening on the destination port.
    let icmp_repr = Icmpv4Repr::DstUnreachable {
        reason: Icmpv4DstUnreachable::PortUnreachable,
        header: Ipv4Repr {
            src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
            dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
            next_header: IpProtocol::Udp,
            payload_len: udp_repr.header_len() + UDP_PAYLOAD.len(),
            hop_limit: 64,
        },
        data,
    };
    let expected_repr = Packet::new_ipv4(
        Ipv4Repr {
            src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
            dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
            next_header: IpProtocol::Icmp,
            payload_len: icmp_repr.buffer_len(),
            hop_limit: 64,
        },
        IpPayload::Icmpv4(icmp_repr),
    );

    // Ensure that the unknown protocol triggers an error response.
    // And we correctly handle no payload.
    assert_eq!(
        iface
            .inner
            .process_udp(&mut sockets, PacketMeta::default(), false, ip_repr, data),
        Some(expected_repr)
    );

    let ip_repr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Udp,
        payload_len: udp_repr.header_len() + UDP_PAYLOAD.len(),
        hop_limit: 64,
    });

    // Emit the representations to a packet
    udp_repr.emit(
        &mut packet_broadcast,
        &ip_repr.src_addr(),
        &IpAddress::Ipv4(Ipv4Address::BROADCAST),
        UDP_PAYLOAD.len(),
        |buf| buf.copy_from_slice(&UDP_PAYLOAD),
        &ChecksumCapabilities::default(),
    );

    // Ensure that the port unreachable error does not trigger an
    // ICMP error response when the destination address is a
    // broadcast address and no socket is bound to the port.
    assert_eq!(
        iface.inner.process_udp(
            &mut sockets,
            PacketMeta::default(),
            false,
            ip_repr,
            packet_broadcast.into_inner(),
        ),
        None
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "medium-ip", feature = "auto-icmp-echo-reply"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "medium-ethernet", feature = "auto-icmp-echo-reply"))]
fn test_handle_ipv4_broadcast(#[case] medium: Medium) {
    use crate::wire::{Icmpv4Packet, Icmpv4Repr};

    let (mut iface, mut sockets, _device) = setup(medium);

    let our_ipv4_addr = iface.ipv4_addr().unwrap();
    let src_ipv4_addr = Ipv4Address::new(127, 0, 0, 2);

    // ICMPv4 echo request
    let icmpv4_data: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];
    let icmpv4_repr = Icmpv4Repr::EchoRequest {
        ident: 0x1234,
        seq_no: 0xabcd,
        data: &icmpv4_data,
    };

    // Send to IPv4 broadcast address
    let ipv4_repr = Ipv4Repr {
        src_addr: src_ipv4_addr,
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Icmp,
        hop_limit: 64,
        payload_len: icmpv4_repr.buffer_len(),
    };

    // Emit to ip frame
    let mut bytes = vec![0u8; ipv4_repr.buffer_len() + icmpv4_repr.buffer_len()];
    let frame = {
        ipv4_repr.emit(
            &mut Ipv4Packet::new_unchecked(&mut bytes[..]),
            &ChecksumCapabilities::default(),
        );
        icmpv4_repr.emit(
            &mut Icmpv4Packet::new_unchecked(&mut bytes[ipv4_repr.buffer_len()..]),
            &ChecksumCapabilities::default(),
        );
        Ipv4Packet::new_unchecked(&bytes[..])
    };

    // Expected ICMPv4 echo reply
    let expected_icmpv4_repr = Icmpv4Repr::EchoReply {
        ident: 0x1234,
        seq_no: 0xabcd,
        data: &icmpv4_data,
    };
    let expected_ipv4_repr = Ipv4Repr {
        src_addr: our_ipv4_addr,
        dst_addr: src_ipv4_addr,
        next_header: IpProtocol::Icmp,
        hop_limit: 64,
        payload_len: expected_icmpv4_repr.buffer_len(),
    };
    let expected_packet =
        Packet::new_ipv4(expected_ipv4_repr, IpPayload::Icmpv4(expected_icmpv4_repr));

    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frame,
            &mut iface.fragments
        ),
        Some(expected_packet)
    );
}

#[rstest]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_handle_valid_arp_request(#[case] medium: Medium) {
    let (mut iface, mut sockets, _device) = setup(medium);

    let mut eth_bytes = vec![0u8; 42];

    let local_ip_addr = Ipv4Address::new(0x7f, 0x00, 0x00, 0x01);
    let remote_ip_addr = Ipv4Address::new(0x7f, 0x00, 0x00, 0x02);
    let local_hw_addr = EthernetAddress([0x02, 0x02, 0x02, 0x02, 0x02, 0x02]);
    let remote_hw_addr = EthernetAddress([0x52, 0x54, 0x00, 0x00, 0x00, 0x00]);

    let repr = ArpRepr::EthernetIpv4 {
        operation: ArpOperation::Request,
        source_hardware_addr: remote_hw_addr,
        source_protocol_addr: remote_ip_addr,
        target_hardware_addr: EthernetAddress::default(),
        target_protocol_addr: local_ip_addr,
    };

    let mut frame = EthernetFrame::new_unchecked(&mut eth_bytes);
    frame.set_dst_addr(EthernetAddress::BROADCAST);
    frame.set_src_addr(remote_hw_addr);
    frame.set_ethertype(EthernetProtocol::Arp);
    let mut packet = ArpPacket::new_unchecked(frame.payload_mut());
    repr.emit(&mut packet);

    // Ensure an ARP Request for us triggers an ARP Reply
    assert_eq!(
        iface.inner.process_ethernet(
            &mut sockets,
            PacketMeta::default(),
            frame.into_inner(),
            &mut iface.fragments
        ),
        Some(EthernetPacket::Arp(ArpRepr::EthernetIpv4 {
            operation: ArpOperation::Reply,
            source_hardware_addr: local_hw_addr,
            source_protocol_addr: local_ip_addr,
            target_hardware_addr: remote_hw_addr,
            target_protocol_addr: remote_ip_addr
        }))
    );

    // Ensure the address of the requester was entered in the cache
    assert_eq!(
        iface.inner.lookup_hardware_addr(
            MockTxToken,
            &IpAddress::Ipv4(remote_ip_addr),
            &mut iface.fragmenter,
        ),
        Ok((HardwareAddress::Ethernet(remote_hw_addr), MockTxToken))
    );
}

#[rstest]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_handle_other_arp_request(#[case] medium: Medium) {
    let (mut iface, mut sockets, _device) = setup(medium);

    let mut eth_bytes = vec![0u8; 42];

    let remote_ip_addr = Ipv4Address::new(0x7f, 0x00, 0x00, 0x02);
    let remote_hw_addr = EthernetAddress([0x52, 0x54, 0x00, 0x00, 0x00, 0x00]);

    let repr = ArpRepr::EthernetIpv4 {
        operation: ArpOperation::Request,
        source_hardware_addr: remote_hw_addr,
        source_protocol_addr: remote_ip_addr,
        target_hardware_addr: EthernetAddress::default(),
        target_protocol_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x03),
    };

    let mut frame = EthernetFrame::new_unchecked(&mut eth_bytes);
    frame.set_dst_addr(EthernetAddress::BROADCAST);
    frame.set_src_addr(remote_hw_addr);
    frame.set_ethertype(EthernetProtocol::Arp);
    let mut packet = ArpPacket::new_unchecked(frame.payload_mut());
    repr.emit(&mut packet);

    // Ensure an ARP Request for someone else does not trigger an ARP Reply
    assert_eq!(
        iface.inner.process_ethernet(
            &mut sockets,
            PacketMeta::default(),
            frame.into_inner(),
            &mut iface.fragments
        ),
        None
    );

    // Ensure the address of the requester was NOT entered in the cache
    assert_eq!(
        iface.inner.lookup_hardware_addr(
            MockTxToken,
            &IpAddress::Ipv4(remote_ip_addr),
            &mut iface.fragmenter,
        ),
        Err(DispatchError::NeighborPending)
    );
}

#[rstest]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn test_arp_flush_after_update_ip(#[case] medium: Medium) {
    let (mut iface, mut sockets, _device) = setup(medium);

    let mut eth_bytes = vec![0u8; 42];

    let local_ip_addr = Ipv4Address::new(0x7f, 0x00, 0x00, 0x01);
    let remote_ip_addr = Ipv4Address::new(0x7f, 0x00, 0x00, 0x02);
    let local_hw_addr = EthernetAddress([0x02, 0x02, 0x02, 0x02, 0x02, 0x02]);
    let remote_hw_addr = EthernetAddress([0x52, 0x54, 0x00, 0x00, 0x00, 0x00]);

    let repr = ArpRepr::EthernetIpv4 {
        operation: ArpOperation::Request,
        source_hardware_addr: remote_hw_addr,
        source_protocol_addr: remote_ip_addr,
        target_hardware_addr: EthernetAddress::default(),
        target_protocol_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
    };

    let mut frame = EthernetFrame::new_unchecked(&mut eth_bytes);
    frame.set_dst_addr(EthernetAddress::BROADCAST);
    frame.set_src_addr(remote_hw_addr);
    frame.set_ethertype(EthernetProtocol::Arp);
    {
        let mut packet = ArpPacket::new_unchecked(frame.payload_mut());
        repr.emit(&mut packet);
    }

    // Ensure an ARP Request for us triggers an ARP Reply
    assert_eq!(
        iface.inner.process_ethernet(
            &mut sockets,
            PacketMeta::default(),
            frame.into_inner(),
            &mut iface.fragments
        ),
        Some(EthernetPacket::Arp(ArpRepr::EthernetIpv4 {
            operation: ArpOperation::Reply,
            source_hardware_addr: local_hw_addr,
            source_protocol_addr: local_ip_addr,
            target_hardware_addr: remote_hw_addr,
            target_protocol_addr: remote_ip_addr
        }))
    );

    // Ensure the address of the requester was entered in the cache
    assert_eq!(
        iface.inner.lookup_hardware_addr(
            MockTxToken,
            &IpAddress::Ipv4(remote_ip_addr),
            &mut iface.fragmenter,
        ),
        Ok((HardwareAddress::Ethernet(remote_hw_addr), MockTxToken))
    );

    // Update IP addrs to trigger ARP cache flush
    let local_ip_addr_new = Ipv4Address::new(0x7f, 0x00, 0x00, 0x01);
    iface.update_ip_addrs(|addrs| {
        addrs.iter_mut().next().map(|addr| {
            *addr = IpCidr::Ipv4(Ipv4Cidr::new(local_ip_addr_new, 24));
        });
    });

    // ARP cache flush after address change
    assert!(!iface.inner.has_neighbor(&IpAddress::Ipv4(remote_ip_addr)));
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(
    feature = "socket-icmp",
    feature = "medium-ip",
    feature = "auto-icmp-echo-reply",
))]
#[case(Medium::Ethernet)]
#[cfg(all(
    feature = "socket-icmp",
    feature = "medium-ethernet",
    feature = "auto-icmp-echo-reply",
))]
fn test_icmpv4_socket(#[case] medium: Medium) {
    use crate::wire::Icmpv4Packet;

    let (mut iface, mut sockets, _device) = setup(medium);

    let rx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 24]);
    let tx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 24]);

    let icmpv4_socket = icmp::Socket::new(rx_buffer, tx_buffer);

    let socket_handle = sockets.add(icmpv4_socket);

    let ident = 0x1234;
    let seq_no = 0x5432;
    let echo_data = &[0xff; 16];

    let socket = sockets.get_mut::<icmp::Socket>(socket_handle);
    // Bind to the ID 0x1234
    assert_eq!(socket.bind(icmp::Endpoint::Ident(ident)), Ok(()));

    // Ensure the ident we bound to and the ident of the packet are the same.
    let mut bytes = [0xff; 24];
    let mut packet = Icmpv4Packet::new_unchecked(&mut bytes[..]);
    let echo_repr = Icmpv4Repr::EchoRequest {
        ident,
        seq_no,
        data: echo_data,
    };
    echo_repr.emit(&mut packet, &ChecksumCapabilities::default());
    let icmp_data = &*packet.into_inner();

    let ipv4_repr = Ipv4Repr {
        src_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x02),
        dst_addr: Ipv4Address::new(0x7f, 0x00, 0x00, 0x01),
        next_header: IpProtocol::Icmp,
        payload_len: 24,
        hop_limit: 64,
    };

    // Open a socket and ensure the packet is handled due to the listening
    // socket.
    assert!(!sockets.get_mut::<icmp::Socket>(socket_handle).can_recv());

    // Confirm we still get EchoReply from `smoltcp` even with the ICMP socket listening
    let echo_reply = Icmpv4Repr::EchoReply {
        ident,
        seq_no,
        data: echo_data,
    };
    let ipv4_reply = Ipv4Repr {
        src_addr: ipv4_repr.dst_addr,
        dst_addr: ipv4_repr.src_addr,
        ..ipv4_repr
    };
    assert_eq!(
        iface
            .inner
            .process_icmpv4(&mut sockets, ipv4_repr, icmp_data),
        Some(Packet::new_ipv4(ipv4_reply, IpPayload::Icmpv4(echo_reply)))
    );

    let socket = sockets.get_mut::<icmp::Socket>(socket_handle);
    assert!(socket.can_recv());
    assert_eq!(
        socket.recv(),
        Ok((
            icmp_data,
            IpAddress::Ipv4(Ipv4Address::new(0x7f, 0x00, 0x00, 0x02))
        ))
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "multicast", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "multicast", feature = "medium-ethernet"))]
fn test_handle_igmp(#[case] medium: Medium) {
    fn recv_igmp(
        device: &mut crate::tests::TestingDevice,
        timestamp: Instant,
    ) -> Vec<(Ipv4Repr, IgmpRepr)> {
        let caps = device.capabilities();
        let checksum_caps = &caps.checksum;
        recv_all(device, timestamp)
            .iter()
            .filter_map(|frame| {
                let ipv4_packet = match caps.medium {
                    #[cfg(feature = "medium-ethernet")]
                    Medium::Ethernet => {
                        let eth_frame = EthernetFrame::new_checked(frame).ok()?;
                        Ipv4Packet::new_checked(eth_frame.payload()).ok()?
                    }
                    #[cfg(feature = "medium-ip")]
                    Medium::Ip => Ipv4Packet::new_checked(&frame[..]).ok()?,
                    #[cfg(feature = "medium-ieee802154")]
                    Medium::Ieee802154 => todo!(),
                };
                let ipv4_repr = Ipv4Repr::parse(&ipv4_packet, checksum_caps).ok()?;
                let ip_payload = ipv4_packet.payload();
                let igmp_packet = IgmpPacket::new_checked(ip_payload).ok()?;
                let igmp_repr = IgmpRepr::parse(&igmp_packet).ok()?;
                Some((ipv4_repr, igmp_repr))
            })
            .collect::<Vec<_>>()
    }

    let groups = [
        Ipv4Address::new(224, 0, 0, 22),
        Ipv4Address::new(224, 0, 0, 56),
    ];

    let (mut iface, mut sockets, mut device) = setup(medium);

    // Join multicast groups
    let timestamp = Instant::ZERO;
    for group in &groups {
        iface.join_multicast_group(*group).unwrap();
    }
    iface.poll(timestamp, &mut device, &mut sockets);

    let reports = recv_igmp(&mut device, timestamp);
    assert_eq!(reports.len(), 2);
    for (i, group_addr) in groups.iter().enumerate() {
        assert_eq!(reports[i].0.next_header, IpProtocol::Igmp);
        assert_eq!(reports[i].0.dst_addr, *group_addr);
        assert_eq!(
            reports[i].1,
            IgmpRepr::MembershipReport {
                group_addr: *group_addr,
                version: IgmpVersion::Version2,
            }
        );
    }

    // General query
    const GENERAL_QUERY_BYTES: &[u8] = &[
        0x46, 0xc0, 0x00, 0x24, 0xed, 0xb4, 0x00, 0x00, 0x01, 0x02, 0x47, 0x43, 0xac, 0x16, 0x63,
        0x04, 0xe0, 0x00, 0x00, 0x01, 0x94, 0x04, 0x00, 0x00, 0x11, 0x64, 0xec, 0x8f, 0x00, 0x00,
        0x00, 0x00, 0x02, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    ];
    device.rx_queue.push_back(GENERAL_QUERY_BYTES.to_vec());

    // Trigger processing until all packets received through the
    // loopback have been processed, including responses to
    // GENERAL_QUERY_BYTES. Therefore `recv_all()` would return 0
    // pkts that could be checked.
    iface.socket_ingress(&mut device, &mut sockets);

    // Leave multicast groups
    let timestamp = Instant::ZERO;
    for group in &groups {
        iface.leave_multicast_group(*group).unwrap();
    }
    iface.poll(timestamp, &mut device, &mut sockets);

    let leaves = recv_igmp(&mut device, timestamp);
    assert_eq!(leaves.len(), 2);
    for (i, group_addr) in groups.iter().cloned().enumerate() {
        assert_eq!(leaves[i].0.next_header, IpProtocol::Igmp);
        assert_eq!(leaves[i].0.dst_addr, IPV4_MULTICAST_ALL_ROUTERS);
        assert_eq!(leaves[i].1, IgmpRepr::LeaveGroup { group_addr });
    }
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "proto-ipv4-fragmentation", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "proto-ipv4-fragmentation", feature = "medium-ethernet"))]
fn test_packet_len(#[case] medium: Medium) {
    use crate::config::FRAGMENTATION_BUFFER_SIZE;

    let (mut iface, _, _) = setup(medium);

    struct TestTxToken {
        max_transmission_unit: usize,
    }

    impl TxToken for TestTxToken {
        fn consume<R, F>(self, len: usize, f: F) -> R
        where
            F: FnOnce(&mut [u8]) -> R,
        {
            net_debug!("TxToken get len: {}", len);
            assert!(len <= self.max_transmission_unit);
            let mut junk = [0; 1536];
            f(&mut junk[..len])
        }
    }

    iface.inner.neighbor_cache.fill(
        IpAddress::Ipv4(Ipv4Address::new(127, 0, 0, 1)),
        HardwareAddress::Ethernet(EthernetAddress::from_bytes(&[
            0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        ])),
        Instant::ZERO,
    );

    for ip_packet_len in [
        100,
        iface.inner.ip_mtu(),
        iface.inner.ip_mtu() + 1,
        FRAGMENTATION_BUFFER_SIZE,
    ] {
        net_debug!("ip_packet_len: {}", ip_packet_len);

        let mut ip_repr = Ipv4Repr {
            src_addr: Ipv4Address::new(127, 0, 0, 1),
            dst_addr: Ipv4Address::new(127, 0, 0, 1),
            next_header: IpProtocol::Udp,
            payload_len: 0,
            hop_limit: 64,
        };
        let udp_repr = UdpRepr {
            src_port: 12345,
            dst_port: 54321,
        };

        let ip_packet_payload_len = ip_packet_len - ip_repr.buffer_len();
        let udp_packet_payload_len = ip_packet_payload_len - udp_repr.header_len();
        ip_repr.payload_len = ip_packet_payload_len;

        let udp_packet_payload = vec![1; udp_packet_payload_len];
        let ip_payload = IpPayload::Udp(udp_repr, &udp_packet_payload);
        let ip_packet = Packet::new_ipv4(ip_repr, ip_payload);

        assert_eq!(
            iface.inner.dispatch_ip(
                TestTxToken {
                    max_transmission_unit: iface.inner.caps.max_transmission_unit
                },
                PacketMeta::default(),
                ip_packet,
                &mut iface.fragmenter,
            ),
            Ok(())
        );
    }
}

/// Check no reply is emitted when using a raw socket
#[cfg(feature = "socket-raw")]
fn check_no_reply_raw_socket(medium: Medium, frame: &crate::wire::ipv4::Packet<&[u8]>) {
    let (mut iface, mut sockets, _) = setup(medium);

    let packets = 1;
    let rx_buffer =
        raw::PacketBuffer::new(vec![raw::PacketMetadata::EMPTY; packets], vec![0; 48 * 1]);
    let tx_buffer = raw::PacketBuffer::new(
        vec![raw::PacketMetadata::EMPTY; packets],
        vec![0; 48 * packets],
    );
    let raw_socket = raw::Socket::new(Some(IpVersion::Ipv4), None, rx_buffer, tx_buffer);
    sockets.add(raw_socket);

    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            frame,
            &mut iface.fragments
        ),
        None
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "socket-raw", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "socket-raw", feature = "medium-ethernet"))]
/// Test no reply to received UDP when using raw socket which accepts all protocols
fn test_raw_socket_no_reply_udp(#[case] medium: Medium) {
    use crate::wire::{UdpPacket, UdpRepr};

    let src_addr = Ipv4Address::new(127, 0, 0, 2);
    let dst_addr = Ipv4Address::new(127, 0, 0, 1);

    const PAYLOAD_LEN: usize = 10;

    let udp_repr = UdpRepr {
        src_port: 67,
        dst_port: 68,
    };
    let ipv4_repr = Ipv4Repr {
        src_addr,
        dst_addr,
        next_header: IpProtocol::Udp,
        hop_limit: 64,
        payload_len: udp_repr.header_len() + PAYLOAD_LEN,
    };

    // Emit to frame
    let mut bytes = vec![0u8; ipv4_repr.buffer_len() + udp_repr.header_len() + PAYLOAD_LEN];
    let frame = {
        ipv4_repr.emit(
            &mut Ipv4Packet::new_unchecked(&mut bytes),
            &ChecksumCapabilities::default(),
        );
        udp_repr.emit(
            &mut UdpPacket::new_unchecked(&mut bytes[ipv4_repr.buffer_len()..]),
            &src_addr.into(),
            &dst_addr.into(),
            PAYLOAD_LEN,
            |buf| fill_slice(buf, 0x2a),
            &ChecksumCapabilities::default(),
        );
        Ipv4Packet::new_unchecked(&bytes[..])
    };

    check_no_reply_raw_socket(medium, &frame);
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "socket-raw", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "socket-raw", feature = "medium-ethernet"))]
/// Test no reply to received TCP when using raw socket which accepts all protocols
fn test_raw_socket_no_reply_tcp(#[case] medium: Medium) {
    use crate::wire::{TcpPacket, TcpRepr};

    let src_addr = Ipv4Address::new(127, 0, 0, 2);
    let dst_addr = Ipv4Address::new(127, 0, 0, 1);

    const PAYLOAD_LEN: usize = 10;
    const PAYLOAD: [u8; PAYLOAD_LEN] = [0x2a; PAYLOAD_LEN];

    let tcp_repr = TcpRepr {
        src_port: 67,
        dst_port: 68,
        control: TcpControl::Syn,
        seq_number: TcpSeqNumber(1),
        ack_number: None,
        window_len: 10,
        window_scale: None,
        max_seg_size: None,
        sack_permitted: false,
        sack_ranges: [None, None, None],
        timestamp: None,
        payload: &PAYLOAD,
    };
    let ipv4_repr = Ipv4Repr {
        src_addr,
        dst_addr,
        next_header: IpProtocol::Tcp,
        hop_limit: 64,
        payload_len: tcp_repr.header_len() + PAYLOAD_LEN,
    };

    // Emit to frame
    let mut bytes = vec![0u8; ipv4_repr.buffer_len() + tcp_repr.header_len() + PAYLOAD_LEN];
    let frame = {
        ipv4_repr.emit(
            &mut Ipv4Packet::new_unchecked(&mut bytes),
            &ChecksumCapabilities::default(),
        );
        tcp_repr.emit(
            &mut TcpPacket::new_unchecked(&mut bytes[ipv4_repr.buffer_len()..]),
            &src_addr.into(),
            &dst_addr.into(),
            &ChecksumCapabilities::default(),
        );
        Ipv4Packet::new_unchecked(&bytes[..])
    };

    check_no_reply_raw_socket(medium, &frame);
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "socket-raw", feature = "socket-udp", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(
    feature = "socket-raw",
    feature = "socket-udp",
    feature = "medium-ethernet"
))]
fn test_raw_socket_with_udp_socket(#[case] medium: Medium) {
    use crate::socket::udp;
    use crate::wire::{IpEndpoint, IpVersion, UdpPacket, UdpRepr};

    static UDP_PAYLOAD: [u8; 5] = [0x48, 0x65, 0x6c, 0x6c, 0x6f];

    let (mut iface, mut sockets, _) = setup(medium);

    let udp_rx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY], vec![0; 15]);
    let udp_tx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY], vec![0; 15]);
    let udp_socket = udp::Socket::new(udp_rx_buffer, udp_tx_buffer);
    let udp_socket_handle = sockets.add(udp_socket);

    // Bind the socket to port 68
    let socket = sockets.get_mut::<udp::Socket>(udp_socket_handle);
    assert_eq!(socket.bind(68), Ok(()));
    assert!(!socket.can_recv());
    assert!(socket.can_send());

    let packets = 1;
    let raw_rx_buffer =
        raw::PacketBuffer::new(vec![raw::PacketMetadata::EMPTY; packets], vec![0; 48 * 1]);
    let raw_tx_buffer = raw::PacketBuffer::new(
        vec![raw::PacketMetadata::EMPTY; packets],
        vec![0; 48 * packets],
    );
    let raw_socket = raw::Socket::new(
        Some(IpVersion::Ipv4),
        Some(IpProtocol::Udp),
        raw_rx_buffer,
        raw_tx_buffer,
    );
    sockets.add(raw_socket);

    let src_addr = Ipv4Address::new(127, 0, 0, 2);
    let dst_addr = Ipv4Address::new(127, 0, 0, 1);

    let udp_repr = UdpRepr {
        src_port: 67,
        dst_port: 68,
    };
    let mut bytes = vec![0xff; udp_repr.header_len() + UDP_PAYLOAD.len()];
    let mut packet = UdpPacket::new_unchecked(&mut bytes[..]);
    udp_repr.emit(
        &mut packet,
        &src_addr.into(),
        &dst_addr.into(),
        UDP_PAYLOAD.len(),
        |buf| buf.copy_from_slice(&UDP_PAYLOAD),
        &ChecksumCapabilities::default(),
    );
    let ipv4_repr = Ipv4Repr {
        src_addr,
        dst_addr,
        next_header: IpProtocol::Udp,
        hop_limit: 64,
        payload_len: udp_repr.header_len() + UDP_PAYLOAD.len(),
    };

    // Emit to frame
    let mut bytes = vec![0u8; ipv4_repr.buffer_len() + udp_repr.header_len() + UDP_PAYLOAD.len()];
    let frame = {
        ipv4_repr.emit(
            &mut Ipv4Packet::new_unchecked(&mut bytes),
            &ChecksumCapabilities::default(),
        );
        udp_repr.emit(
            &mut UdpPacket::new_unchecked(&mut bytes[ipv4_repr.buffer_len()..]),
            &src_addr.into(),
            &dst_addr.into(),
            UDP_PAYLOAD.len(),
            |buf| buf.copy_from_slice(&UDP_PAYLOAD),
            &ChecksumCapabilities::default(),
        );
        Ipv4Packet::new_unchecked(&bytes[..])
    };

    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frame,
            &mut iface.fragments
        ),
        None
    );

    // Make sure the UDP socket can still receive in presence of a Raw socket that handles UDP
    let socket = sockets.get_mut::<udp::Socket>(udp_socket_handle);
    assert!(socket.can_recv());
    assert_eq!(
        socket.recv(),
        Ok((
            &UDP_PAYLOAD[..],
            udp::UdpMetadata {
                local_address: Some(dst_addr.into()),
                ..IpEndpoint::new(src_addr.into(), 67).into()
            }
        ))
    );
}

#[cfg(feature = "proto-ipv4-fragmentation")]
use crate::phy::IPV4_FRAGMENT_PAYLOAD_ALIGNMENT;
#[rstest]
#[case(Medium::Ip)]
#[cfg(all(
    feature = "socket-raw",
    feature = "proto-ipv4-fragmentation",
    feature = "medium-ip"
))]
#[case(Medium::Ethernet)]
#[cfg(all(
    feature = "socket-raw",
    feature = "proto-ipv4-fragmentation",
    feature = "medium-ethernet"
))]
fn test_raw_socket_tx_fragmentation(#[case] medium: Medium) {
    use std::panic::AssertUnwindSafe;

    let (mut iface, mut sockets, device) = setup(medium);
    let mtu = device.capabilities().max_transmission_unit;
    let unaligned_length = mtu - IPV4_HEADER_LEN;
    // This check ensures a valid test in which we actually do adjust for alignment.
    let mtu = if unaligned_length.is_multiple_of(IPV4_FRAGMENT_PAYLOAD_ALIGNMENT) {
        mtu + IPV4_FRAGMENT_PAYLOAD_ALIGNMENT / 2
    } else {
        mtu
    };

    let packets = 5;
    let rx_buffer = raw::PacketBuffer::new(
        vec![raw::PacketMetadata::EMPTY; packets],
        vec![0; mtu * packets],
    );
    let tx_buffer = raw::PacketBuffer::new(
        vec![raw::PacketMetadata::EMPTY; packets],
        vec![0; mtu * packets],
    );
    let socket = raw::Socket::new(
        Some(IpVersion::Ipv4),
        Some(IpProtocol::Udp),
        rx_buffer,
        tx_buffer,
    );
    let _handle = sockets.add(socket);

    let tx_packet_sizes = vec![
        mtu * 3 / 4, // Smaller than MTU
        mtu * 5 / 4, // Larger than MTU, requires fragmentation
        mtu * 9 / 4, // Much larger, requires two fragments
    ];

    // Define test token for capturing the fragments.
    struct TestFragmentTxToken {}

    impl TxToken for TestFragmentTxToken {
        fn consume<R, F>(self, len: usize, f: F) -> R
        where
            F: FnOnce(&mut [u8]) -> R,
        {
            // Buffer is something arbitrarily large.
            // We cannot capture the dynamic packet_size calculation here.
            let mut buffer = [0; 2048];
            let result = f(&mut buffer[..len]);
            // Verify the payload size is aligned.
            let payload_size = len - IPV4_HEADER_LEN;
            assert!(payload_size.is_multiple_of(IPV4_FRAGMENT_PAYLOAD_ALIGNMENT));
            result
        }
    }

    for packet_size in tx_packet_sizes {
        let payload_len = packet_size - IPV4_HEADER_LEN;
        let payload = vec![0u8; payload_len];

        let ip_repr = Ipv4Repr {
            src_addr: Ipv4Address::new(192, 168, 1, 3),
            dst_addr: Ipv4Address::BROADCAST,
            next_header: IpProtocol::Unknown(92),
            hop_limit: 64,
            payload_len,
        };
        let ip_payload = IpPayload::Raw(&payload);
        let packet = Packet::new_ipv4(ip_repr, ip_payload);

        // This should not panic for any payload size
        let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
            if packet_size > mtu && medium == Medium::Ip {
                iface.inner.dispatch_ip(
                    TestFragmentTxToken {},
                    PacketMeta::default(),
                    packet,
                    &mut iface.fragmenter,
                )
            } else {
                iface.inner.dispatch_ip(
                    MockTxToken {},
                    PacketMeta::default(),
                    packet,
                    &mut iface.fragmenter,
                )
            }
        }));

        // All transmissions should succeed without panicking
        assert!(result.is_ok(), "Failed for packet size: {}", packet_size,);

        // Perform payload size checks if fragmentation is required.
        // It is sufficient to test only the simpler IP test case.
        if packet_size <= mtu || medium != Medium::Ip {
            continue;
        }

        // Verify that the fragment offset is correct.
        let unaligned_length = mtu - IPV4_HEADER_LEN;
        let remainder = unaligned_length % IPV4_FRAGMENT_PAYLOAD_ALIGNMENT;
        let expected_fragment_offset = mtu - IPV4_HEADER_LEN - remainder;
        let frag_offset = iface.fragmenter.ipv4.frag_offset;
        assert_eq!(frag_offset as usize, expected_fragment_offset);

        // Check subsequent fragment sizes if applicable.
        if packet_size / mtu == 2 {
            // Two fragments are left. The intermediate fragment must be aligned.
            iface
                .inner
                .dispatch_ipv4_frag(TestFragmentTxToken {}, &mut iface.fragmenter);
        }
        // Process the final fragment. It is the remainder of the data and does not have to be aligned.
        iface
            .inner
            .dispatch_ipv4_frag(MockTxToken {}, &mut iface.fragmenter);

        // The fragment offset should be the complete payload length once transmission is complete.
        let frag_offset = iface.fragmenter.ipv4.frag_offset;
        assert_eq!(frag_offset as usize, payload_len);
    }
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(
    feature = "socket-raw",
    feature = "proto-ipv4-fragmentation",
    feature = "medium-ip"
))]
#[case(Medium::Ethernet)]
#[cfg(all(
    feature = "socket-raw",
    feature = "proto-ipv4-fragmentation",
    feature = "medium-ethernet"
))]
fn test_raw_socket_rx_fragmentation(#[case] medium: Medium) {
    use crate::wire::{IpProtocol, IpVersion, Ipv4Address, Ipv4Packet, Ipv4Repr};

    let (mut iface, mut sockets, _device) = setup(medium);

    // Raw socket bound to IPv4 and a custom protocol.
    let packets = 1;
    let rx_buffer = raw::PacketBuffer::new(vec![raw::PacketMetadata::EMPTY; packets], vec![0; 64]);
    let tx_buffer = raw::PacketBuffer::new(vec![raw::PacketMetadata::EMPTY; packets], vec![0; 64]);
    let raw_socket = raw::Socket::new(
        Some(IpVersion::Ipv4),
        Some(IpProtocol::Unknown(99)),
        rx_buffer,
        tx_buffer,
    );
    let handle = sockets.add(raw_socket);

    // Build two IPv4 fragments that together form one packet.
    let src_addr = Ipv4Address::new(127, 0, 0, 2);
    let dst_addr = Ipv4Address::new(127, 0, 0, 1);
    let proto = IpProtocol::Unknown(99);
    let ident: u16 = 0x1234;

    let total_payload_len = 30usize;
    let first_payload_len = 24usize; // must be a multiple of 8
    let last_payload_len = total_payload_len - first_payload_len;

    // Helper to build one fragment as on-the-wire bytes
    let build_fragment = |payload_len: usize,
                          more_frags: bool,
                          frag_offset_octets: u16,
                          payload_byte: u8|
     -> Vec<u8> {
        let repr = Ipv4Repr {
            src_addr,
            dst_addr,
            next_header: proto,
            hop_limit: 64,
            payload_len,
        };
        let header_len = repr.buffer_len();
        let mut bytes = vec![0u8; header_len + payload_len];
        {
            let mut pkt = Ipv4Packet::new_unchecked(&mut bytes[..]);
            repr.emit(&mut pkt, &ChecksumCapabilities::default());
            pkt.set_ident(ident);
            pkt.set_dont_frag(false);
            pkt.set_more_frags(more_frags);
            pkt.set_frag_offset(frag_offset_octets);
            // Recompute checksum after changing fragmentation fields.
            pkt.fill_checksum();
        }
        // Fill payload with a simple pattern for validation
        for b in &mut bytes[header_len..] {
            *b = payload_byte;
        }
        bytes
    };

    let frag1_bytes = build_fragment(first_payload_len, true, 0, 0xAA);
    let frag2_bytes = build_fragment(last_payload_len, false, first_payload_len as u16, 0xBB);

    let frag1 = Ipv4Packet::new_unchecked(&frag1_bytes[..]);
    let frag2 = Ipv4Packet::new_unchecked(&frag2_bytes[..]);

    // First fragment alone should not be delivered to the raw socket.
    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frag1,
            &mut iface.fragments
        ),
        None
    );
    {
        let socket = sockets.get_mut::<raw::Socket>(handle);
        assert!(!socket.can_recv());
    }

    // After the last fragment, the reassembled packet should be delivered.
    assert_eq!(
        iface.inner.process_ipv4(
            &mut sockets,
            PacketMeta::default(),
            HardwareAddress::default(),
            &frag2,
            &mut iface.fragments
        ),
        None
    );

    // Validate the raw socket received one defragmented packet with correct payload.
    let socket = sockets.get_mut::<raw::Socket>(handle);
    assert!(socket.can_recv());
    let data = socket.recv().expect("raw socket should have a packet");
    let packet = Ipv4Packet::new_unchecked(data);
    let repr = Ipv4Repr::parse(&packet, &ChecksumCapabilities::default()).unwrap();
    assert_eq!(repr.src_addr, src_addr);
    assert_eq!(repr.dst_addr, dst_addr);
    assert_eq!(repr.next_header, proto);
    assert_eq!(repr.payload_len, total_payload_len);

    let payload = packet.payload();
    assert_eq!(payload.len(), total_payload_len);
    assert!(payload[..first_payload_len].iter().all(|&b| b == 0xAA));
    assert!(payload[first_payload_len..].iter().all(|&b| b == 0xBB));
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(all(feature = "socket-udp", feature = "medium-ip"))]
#[case(Medium::Ethernet)]
#[cfg(all(feature = "socket-udp", feature = "medium-ethernet"))]
fn test_icmp_reply_size(#[case] medium: Medium) {
    use crate::wire::IPV4_MIN_MTU as MIN_MTU;
    const MAX_PAYLOAD_LEN: usize = 528;

    let (mut iface, mut sockets, _device) = setup(medium);

    let src_addr = Ipv4Address::new(192, 168, 1, 1);
    let dst_addr = Ipv4Address::new(192, 168, 1, 2);

    // UDP packet that if not tructated will cause a icmp port unreachable reply
    // to exceed the minimum mtu bytes in length.
    let udp_repr = UdpRepr {
        src_port: 67,
        dst_port: 68,
    };
    let mut bytes = vec![0xff; udp_repr.header_len() + MAX_PAYLOAD_LEN];
    let mut packet = UdpPacket::new_unchecked(&mut bytes[..]);
    udp_repr.emit(
        &mut packet,
        &src_addr.into(),
        &dst_addr.into(),
        MAX_PAYLOAD_LEN,
        |buf| fill_slice(buf, 0x2a),
        &ChecksumCapabilities::default(),
    );

    let ip_repr = Ipv4Repr {
        src_addr,
        dst_addr,
        next_header: IpProtocol::Udp,
        hop_limit: 64,
        payload_len: udp_repr.header_len() + MAX_PAYLOAD_LEN,
    };
    let payload = packet.into_inner();

    let expected_icmp_repr = Icmpv4Repr::DstUnreachable {
        reason: Icmpv4DstUnreachable::PortUnreachable,
        header: ip_repr,
        data: &payload[..MAX_PAYLOAD_LEN],
    };

    let expected_ip_repr = Ipv4Repr {
        src_addr: dst_addr,
        dst_addr: src_addr,
        next_header: IpProtocol::Icmp,
        hop_limit: 64,
        payload_len: expected_icmp_repr.buffer_len(),
    };

    assert_eq!(
        expected_ip_repr.buffer_len() + expected_icmp_repr.buffer_len(),
        MIN_MTU
    );

    assert_eq!(
        iface.inner.process_udp(
            &mut sockets,
            PacketMeta::default(),
            false,
            ip_repr.into(),
            payload,
        ),
        Some(Packet::new_ipv4(
            expected_ip_repr,
            IpPayload::Icmpv4(expected_icmp_repr)
        ))
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn get_source_address(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);

    const OWN_UNIQUE_LOCAL_ADDR1: Ipv4Address = Ipv4Address::new(172, 18, 1, 2);
    const OWN_UNIQUE_LOCAL_ADDR2: Ipv4Address = Ipv4Address::new(172, 24, 24, 14);

    // List of addresses of the interface:
    //   172.18.1.2/24
    //   172.24.24.14/24
    iface.update_ip_addrs(|addrs| {
        addrs.clear();

        addrs
            .push(IpCidr::Ipv4(Ipv4Cidr::new(OWN_UNIQUE_LOCAL_ADDR1, 24)))
            .unwrap();
        addrs
            .push(IpCidr::Ipv4(Ipv4Cidr::new(OWN_UNIQUE_LOCAL_ADDR2, 24)))
            .unwrap();
    });

    // List of addresses we test:
    //   172.18.1.254 -> 172.18.1.2
    //   172.24.24.12 -> 172.24.24.14
    //   172.24.23.254 -> 172.18.1.2
    const UNIQUE_LOCAL_ADDR1: Ipv4Address = Ipv4Address::new(172, 18, 1, 254);
    const UNIQUE_LOCAL_ADDR2: Ipv4Address = Ipv4Address::new(172, 24, 24, 12);
    const UNIQUE_LOCAL_ADDR3: Ipv4Address = Ipv4Address::new(172, 24, 23, 254);

    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR1),
        Some(OWN_UNIQUE_LOCAL_ADDR1)
    );

    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR2),
        Some(OWN_UNIQUE_LOCAL_ADDR2)
    );
    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR3),
        Some(OWN_UNIQUE_LOCAL_ADDR1)
    );
}

#[rstest]
#[case(Medium::Ip)]
#[cfg(feature = "medium-ip")]
#[case(Medium::Ethernet)]
#[cfg(feature = "medium-ethernet")]
fn get_source_address_empty_interface(#[case] medium: Medium) {
    let (mut iface, _, _) = setup(medium);

    iface.update_ip_addrs(|ips| ips.clear());

    // List of addresses we test:
    //   172.18.1.254 -> None
    //   172.24.24.12 -> None
    //   172.24.23.254 -> None
    const UNIQUE_LOCAL_ADDR1: Ipv4Address = Ipv4Address::new(172, 18, 1, 254);
    const UNIQUE_LOCAL_ADDR2: Ipv4Address = Ipv4Address::new(172, 24, 24, 12);
    const UNIQUE_LOCAL_ADDR3: Ipv4Address = Ipv4Address::new(172, 24, 23, 254);

    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR1),
        None
    );
    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR2),
        None
    );
    assert_eq!(
        iface.inner.get_source_address_ipv4(&UNIQUE_LOCAL_ADDR3),
        None
    );
}

use crate::wire::ipv4::HEADER_LEN;
#[rstest]
#[cfg(all(feature = "medium-ip", feature = "proto-ipv4-fragmentation",))]
fn test_ipv4_fragment_size() {
    let (_, _, device) = setup(Medium::Ip);
    let caps = device.capabilities();
    for i in 0..IPV4_FRAGMENT_PAYLOAD_ALIGNMENT {
        assert!(
            caps.max_ipv4_fragment_size(HEADER_LEN + i)
                .is_multiple_of(IPV4_FRAGMENT_PAYLOAD_ALIGNMENT)
        );
    }
}
