use super::*;

impl Interface {
    /// Process fragments that still need to be sent for IPv4 packets.
    ///
    /// This function returns a boolean value indicating whether any packets were
    /// processed or emitted, and thus, whether the readiness of any socket might
    /// have changed.
    #[cfg(feature = "proto-ipv4-fragmentation")]
    pub(super) fn ipv4_egress(&mut self, device: &mut (impl Device + ?Sized)) {
        // Reset the buffer when we transmitted everything.
        if self.fragmenter.finished() {
            self.fragmenter.reset();
        }

        if self.fragmenter.is_empty() {
            return;
        }

        let pkt = &self.fragmenter;
        if pkt.packet_len > pkt.sent_bytes
            && let Some(tx_token) = device.transmit(self.inner.now)
        {
            self.inner
                .dispatch_ipv4_frag(tx_token, &mut self.fragmenter);
        }
    }
}

impl InterfaceInner {
    /// Get the next IPv4 fragment identifier.
    #[cfg(feature = "proto-ipv4-fragmentation")]
    pub(super) fn next_ipv4_frag_ident(&mut self) -> u16 {
        let ipv4_id = self.ipv4_id;
        self.ipv4_id = self.ipv4_id.wrapping_add(1);
        ipv4_id
    }

    /// Get an IPv4 source address based on a destination address.
    ///
    /// This function tries to find the first IPv4 address from the interface
    /// that is in the same subnet as the destination address. If no such
    /// address is found, the first IPv4 address from the interface is returned.
    #[allow(unused)]
    pub(crate) fn get_source_address_ipv4(&self, dst_addr: &Ipv4Address) -> Option<Ipv4Address> {
        let mut first_ipv4 = None;
        for cidr in self.ip_addrs.iter() {
            #[allow(irrefutable_let_patterns)] // if only ipv4 is enabled
            if let IpCidr::Ipv4(cidr) = cidr {
                // Return immediately if we find an address in the same subnet
                if cidr.contains_addr(dst_addr) {
                    return Some(cidr.address());
                }

                // Remember the first IPv4 address as fallback
                if first_ipv4.is_none() {
                    first_ipv4 = Some(cidr.address());
                }
            }
        }
        first_ipv4
    }

    /// Checks if an address is broadcast, taking into account ipv4 subnet-local
    /// broadcast addresses.
    pub(crate) fn is_broadcast_v4(&self, address: Ipv4Address) -> bool {
        if address.is_broadcast() {
            return true;
        }

        self.ip_addrs
            .iter()
            .filter_map(|own_cidr| match own_cidr {
                IpCidr::Ipv4(own_ip) => Some(own_ip.broadcast()?),
                #[cfg(feature = "proto-ipv6")]
                IpCidr::Ipv6(_) => None,
            })
            .any(|broadcast_address| address == broadcast_address)
    }

    /// Checks if an ipv4 address is unicast, taking into account subnet broadcast addresses
    fn is_unicast_v4(&self, address: Ipv4Address) -> bool {
        address.x_is_unicast() && !self.is_broadcast_v4(address)
    }

    /// Get the first IPv4 address of the interface.
    pub fn ipv4_addr(&self) -> Option<Ipv4Address> {
        self.ip_addrs.iter().find_map(|addr| match *addr {
            IpCidr::Ipv4(cidr) => Some(cidr.address()),
            #[allow(unreachable_patterns)]
            _ => None,
        })
    }

    pub(super) fn process_ipv4<'a>(
        &mut self,
        sockets: &mut SocketSet,
        meta: PacketMeta,
        source_hardware_addr: HardwareAddress,
        ipv4_packet: &Ipv4Packet<&'a [u8]>,
        frag: &'a mut FragmentsBuffer,
    ) -> Option<Packet<'a>> {
        let mut ipv4_repr = check!(Ipv4Repr::parse(ipv4_packet, &self.caps.checksum));
        if !self.is_unicast_v4(ipv4_repr.src_addr) && !ipv4_repr.src_addr.is_unspecified() {
            // Discard packets with non-unicast source addresses but allow unspecified
            net_debug!("non-unicast or unspecified source address");
            return None;
        }

        #[cfg(feature = "proto-ipv4-fragmentation")]
        let ip_payload = {
            if ipv4_packet.more_frags() || ipv4_packet.frag_offset() != 0 {
                let key = FragKey::Ipv4(ipv4_packet.get_key());

                let f = match frag.assembler.get(&key, self.now + frag.reassembly_timeout) {
                    Ok(f) => f,
                    Err(_) => {
                        net_debug!("No available packet assembler for fragmented packet");
                        return None;
                    }
                };

                if !ipv4_packet.more_frags() {
                    // This is the last fragment, so we know the total size
                    check!(f.set_total_size(
                        ipv4_packet.total_len() as usize - ipv4_packet.header_len() as usize
                            + ipv4_packet.frag_offset() as usize,
                    ));
                }

                if let Err(e) = f.add(ipv4_packet.payload(), ipv4_packet.frag_offset() as usize) {
                    net_debug!("fragmentation error: {:?}", e);
                    return None;
                }

                let payload = f.assemble()?;
                // Update the payload length, so that the raw sockets get the correct value.
                ipv4_repr.payload_len = payload.len();
                payload
            } else {
                ipv4_packet.payload()
            }
        };

        #[cfg(not(feature = "proto-ipv4-fragmentation"))]
        let ip_payload = ipv4_packet.payload();

        let ip_repr = IpRepr::Ipv4(ipv4_repr);

        #[cfg(feature = "socket-raw")]
        let handled_by_raw_socket = self.raw_socket_filter(sockets, &ip_repr, ip_payload);
        #[cfg(not(feature = "socket-raw"))]
        let handled_by_raw_socket = false;

        #[cfg(feature = "socket-dhcpv4")]
        {
            use crate::socket::dhcpv4::Socket as Dhcpv4Socket;

            if ipv4_repr.next_header == IpProtocol::Udp
                && matches!(self.caps.medium, Medium::Ethernet)
            {
                let udp_packet = check!(UdpPacket::new_checked(ip_payload));
                if let Some(dhcp_socket) = sockets
                    .items_mut()
                    .find_map(|i| Dhcpv4Socket::downcast_mut(&mut i.socket))
                {
                    // First check for source and dest ports, then do `UdpRepr::parse` if they match.
                    // This way we avoid validating the UDP checksum twice for all non-DHCP UDP packets (one here, one in `process_udp`)
                    if udp_packet.src_port() == dhcp_socket.server_port
                        && udp_packet.dst_port() == dhcp_socket.client_port
                    {
                        let udp_repr = check!(UdpRepr::parse(
                            &udp_packet,
                            &ipv4_repr.src_addr.into(),
                            &ipv4_repr.dst_addr.into(),
                            &self.caps.checksum
                        ));
                        dhcp_socket.process(self, &ipv4_repr, &udp_repr, udp_packet.payload());
                        return None;
                    }
                }
            }
        }

        if !self.has_ip_addr(ipv4_repr.dst_addr)
            && !self.has_multicast_group(ipv4_repr.dst_addr)
            && !self.is_broadcast_v4(ipv4_repr.dst_addr)
        {
            // Ignore IP packets not directed at us, or broadcast, or any of the multicast groups.

            if !ipv4_repr.dst_addr.x_is_unicast() {
                net_trace!(
                    "Rejecting IPv4 packet; {} is not a unicast address",
                    ipv4_repr.dst_addr
                );
                return None;
            }

            if self
                .routes
                .lookup(&IpAddress::Ipv4(ipv4_repr.dst_addr), self.now)
                .is_none_or(|router_addr| !self.has_ip_addr(router_addr))
            {
                net_trace!("Rejecting IPv4 packet; no matching routes");

                return None;
            }

            net_trace!("Rejecting IPv4 packet; no assigned address");
            return None;
        }

        #[cfg(feature = "medium-ethernet")]
        if self.is_unicast_v4(ipv4_repr.dst_addr) {
            self.neighbor_cache.reset_expiry_if_existing(
                IpAddress::Ipv4(ipv4_repr.src_addr),
                source_hardware_addr,
                self.now,
            );
        }

        match ipv4_repr.next_header {
            IpProtocol::Icmp => self.process_icmpv4(sockets, ipv4_repr, ip_payload),

            #[cfg(feature = "multicast")]
            IpProtocol::Igmp => self.process_igmp(ipv4_repr, ip_payload),

            #[cfg(any(feature = "socket-udp", feature = "socket-dns"))]
            IpProtocol::Udp => {
                self.process_udp(sockets, meta, handled_by_raw_socket, ip_repr, ip_payload)
            }

            #[cfg(feature = "socket-tcp")]
            IpProtocol::Tcp => {
                self.process_tcp(sockets, handled_by_raw_socket, ip_repr, ip_payload)
            }

            _ if handled_by_raw_socket => None,

            _ => {
                // Send back as much of the original payload as we can.
                let payload_len =
                    icmp_reply_payload_len(ip_payload.len(), IPV4_MIN_MTU, ipv4_repr.buffer_len());
                let icmp_reply_repr = Icmpv4Repr::DstUnreachable {
                    reason: Icmpv4DstUnreachable::ProtoUnreachable,
                    header: ipv4_repr,
                    data: &ip_payload[0..payload_len],
                };
                self.icmpv4_reply(ipv4_repr, icmp_reply_repr)
            }
        }
    }

    #[cfg(feature = "medium-ethernet")]
    pub(super) fn process_arp<'frame>(
        &mut self,
        timestamp: Instant,
        eth_frame: &EthernetFrame<&'frame [u8]>,
    ) -> Option<EthernetPacket<'frame>> {
        let arp_packet = check!(ArpPacket::new_checked(eth_frame.payload()));
        let arp_repr = check!(ArpRepr::parse(&arp_packet));

        match arp_repr {
            ArpRepr::EthernetIpv4 {
                operation,
                source_hardware_addr,
                source_protocol_addr,
                target_protocol_addr,
                ..
            } => {
                // Only process ARP packets for us.
                if !self.has_ip_addr(target_protocol_addr) {
                    return None;
                }

                // Only process REQUEST and RESPONSE.
                if let ArpOperation::Unknown(_) = operation {
                    net_debug!("arp: unknown operation code");
                    return None;
                }

                // Discard packets with non-unicast source addresses.
                if !source_protocol_addr.x_is_unicast() || !source_hardware_addr.is_unicast() {
                    net_debug!("arp: non-unicast source address");
                    return None;
                }

                if !self.in_same_network(&IpAddress::Ipv4(source_protocol_addr)) {
                    net_debug!("arp: source IP address not in same network as us");
                    return None;
                }

                // Fill the ARP cache from any ARP packet aimed at us (both request or response).
                // We fill from requests too because if someone is requesting our address they
                // are probably going to talk to us, so we avoid having to request their address
                // when we later reply to them.
                self.neighbor_cache.fill(
                    source_protocol_addr.into(),
                    source_hardware_addr.into(),
                    timestamp,
                );

                if operation == ArpOperation::Request {
                    let src_hardware_addr = self.hardware_addr.ethernet_or_panic();

                    Some(EthernetPacket::Arp(ArpRepr::EthernetIpv4 {
                        operation: ArpOperation::Reply,
                        source_hardware_addr: src_hardware_addr,
                        source_protocol_addr: target_protocol_addr,
                        target_hardware_addr: source_hardware_addr,
                        target_protocol_addr: source_protocol_addr,
                    }))
                } else {
                    None
                }
            }
        }
    }

    pub(super) fn process_icmpv4<'frame>(
        &mut self,
        _sockets: &mut SocketSet,
        ip_repr: Ipv4Repr,
        ip_payload: &'frame [u8],
    ) -> Option<Packet<'frame>> {
        let icmp_packet = check!(Icmpv4Packet::new_checked(ip_payload));
        let icmp_repr = check!(Icmpv4Repr::parse(&icmp_packet, &self.caps.checksum));

        #[cfg(feature = "socket-icmp")]
        let mut handled_by_icmp_socket = false;

        #[cfg(all(feature = "socket-icmp", feature = "proto-ipv4"))]
        for icmp_socket in _sockets
            .items_mut()
            .filter_map(|i| icmp::Socket::downcast_mut(&mut i.socket))
        {
            if icmp_socket.accepts_v4(self, &ip_repr, &icmp_repr) {
                icmp_socket.process_v4(self, &ip_repr, &icmp_repr);
                handled_by_icmp_socket = true;
            }
        }

        match icmp_repr {
            // Respond to echo requests.
            #[cfg(all(feature = "proto-ipv4", feature = "auto-icmp-echo-reply"))]
            Icmpv4Repr::EchoRequest {
                ident,
                seq_no,
                data,
            } => {
                let icmp_reply_repr = Icmpv4Repr::EchoReply {
                    ident,
                    seq_no,
                    data,
                };
                self.icmpv4_reply(ip_repr, icmp_reply_repr)
            }

            // Ignore any echo replies.
            Icmpv4Repr::EchoReply { .. } => None,

            // Don't report an error if a packet with unknown type
            // has been handled by an ICMP socket
            #[cfg(feature = "socket-icmp")]
            _ if handled_by_icmp_socket => None,

            // FIXME: do something correct here?
            // By doing nothing, this arm handles the case when auto echo replies are disabled.
            _ => None,
        }
    }

    pub(super) fn icmpv4_reply<'frame, 'icmp: 'frame>(
        &self,
        ipv4_repr: Ipv4Repr,
        icmp_repr: Icmpv4Repr<'icmp>,
    ) -> Option<Packet<'frame>> {
        if !self.is_unicast_v4(ipv4_repr.src_addr) {
            // Do not send ICMP replies to non-unicast sources
            None
        } else if self.is_unicast_v4(ipv4_repr.dst_addr) {
            // Reply as normal when src_addr and dst_addr are both unicast
            let ipv4_reply_repr = Ipv4Repr {
                src_addr: ipv4_repr.dst_addr,
                dst_addr: ipv4_repr.src_addr,
                next_header: IpProtocol::Icmp,
                payload_len: icmp_repr.buffer_len(),
                hop_limit: 64,
            };
            Some(Packet::new_ipv4(
                ipv4_reply_repr,
                IpPayload::Icmpv4(icmp_repr),
            ))
        } else if self.is_broadcast_v4(ipv4_repr.dst_addr) {
            // Only reply to broadcasts for echo replies and not other ICMP messages
            match icmp_repr {
                Icmpv4Repr::EchoReply { .. } => match self.ipv4_addr() {
                    Some(src_addr) => {
                        let ipv4_reply_repr = Ipv4Repr {
                            src_addr,
                            dst_addr: ipv4_repr.src_addr,
                            next_header: IpProtocol::Icmp,
                            payload_len: icmp_repr.buffer_len(),
                            hop_limit: 64,
                        };
                        Some(Packet::new_ipv4(
                            ipv4_reply_repr,
                            IpPayload::Icmpv4(icmp_repr),
                        ))
                    }
                    None => None,
                },
                _ => None,
            }
        } else {
            None
        }
    }

    #[cfg(feature = "proto-ipv4-fragmentation")]
    pub(super) fn dispatch_ipv4_frag<Tx: TxToken>(&mut self, tx_token: Tx, frag: &mut Fragmenter) {
        let caps = self.caps.clone();

        let max_fragment_size = caps.max_ipv4_fragment_size(frag.ipv4.repr.buffer_len());
        let payload_len = (frag.packet_len - frag.sent_bytes).min(max_fragment_size);
        let ip_len = payload_len + frag.ipv4.repr.buffer_len();

        let more_frags = (frag.packet_len - frag.sent_bytes) != payload_len;
        frag.ipv4.repr.payload_len = payload_len;
        frag.sent_bytes += payload_len;

        let mut tx_len = ip_len;
        #[cfg(feature = "medium-ethernet")]
        if matches!(caps.medium, Medium::Ethernet) {
            tx_len += EthernetFrame::<&[u8]>::header_len();
        }

        // Emit function for the Ethernet header.
        #[cfg(feature = "medium-ethernet")]
        let emit_ethernet = |repr: &IpRepr, tx_buffer: &mut [u8]| {
            let mut frame = EthernetFrame::new_unchecked(tx_buffer);

            let src_addr = self.hardware_addr.ethernet_or_panic();
            frame.set_src_addr(src_addr);
            frame.set_dst_addr(frag.ipv4.dst_hardware_addr);

            match repr.version() {
                #[cfg(feature = "proto-ipv4")]
                IpVersion::Ipv4 => frame.set_ethertype(EthernetProtocol::Ipv4),
                #[cfg(feature = "proto-ipv6")]
                IpVersion::Ipv6 => frame.set_ethertype(EthernetProtocol::Ipv6),
            }
        };

        tx_token.consume(tx_len, |mut tx_buffer| {
            #[cfg(feature = "medium-ethernet")]
            if matches!(self.caps.medium, Medium::Ethernet) {
                emit_ethernet(&IpRepr::Ipv4(frag.ipv4.repr), tx_buffer);
                tx_buffer = &mut tx_buffer[EthernetFrame::<&[u8]>::header_len()..];
            }

            let mut packet =
                Ipv4Packet::new_unchecked(&mut tx_buffer[..frag.ipv4.repr.buffer_len()]);
            frag.ipv4.repr.emit(&mut packet, &caps.checksum);
            packet.set_ident(frag.ipv4.ident);
            packet.set_more_frags(more_frags);
            packet.set_dont_frag(false);
            packet.set_frag_offset(frag.ipv4.frag_offset);

            if caps.checksum.ipv4.tx() {
                packet.fill_checksum();
            }

            tx_buffer[frag.ipv4.repr.buffer_len()..][..payload_len].copy_from_slice(
                &frag.buffer[frag.ipv4.frag_offset as usize + frag.ipv4.repr.buffer_len()..]
                    [..payload_len],
            );

            // Update the frag offset for the next fragment.
            frag.ipv4.frag_offset += payload_len as u16;
        })
    }
}
