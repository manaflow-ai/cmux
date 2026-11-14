mod utils;

use std::os::unix::io::AsRawFd;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, Medium, wait as phy_wait};
use smoltcp::socket::{raw, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{
    EthernetAddress, IgmpPacket, IgmpRepr, IpAddress, IpCidr, IpProtocol, IpVersion, Ipv4Address,
    Ipv4Packet, Ipv6Address,
};

const MDNS_PORT: u16 = 5353;
const MDNS_GROUP: Ipv4Address = Ipv4Address::new(224, 0, 0, 251);

fn main() {
    utils::setup_logging("warn");

    let (mut opts, mut free) = utils::create_options();
    utils::add_tuntap_options(&mut opts, &mut free);
    utils::add_middleware_options(&mut opts, &mut free);

    let mut matches = utils::parse_options(&opts, free);
    let device = utils::parse_tuntap_options(&mut matches);
    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);

    // Create interface
    let mut config = match device.capabilities().medium {
        Medium::Ethernet => {
            Config::new(EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]).into())
        }
        Medium::Ip => Config::new(smoltcp::wire::HardwareAddress::Ip),
        Medium::Ieee802154 => todo!(),
    };
    config.random_seed = rand::random();

    let mut iface = Interface::new(config, &mut device, Instant::now());
    iface.update_ip_addrs(|ip_addrs| {
        ip_addrs
            .push(IpCidr::new(IpAddress::v4(192, 168, 69, 1), 24))
            .unwrap();
        ip_addrs
            .push(IpCidr::new(IpAddress::v6(0xfdaa, 0, 0, 0, 0, 0, 0, 1), 64))
            .unwrap();
        ip_addrs
            .push(IpCidr::new(IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1), 64))
            .unwrap();
    });
    iface
        .routes_mut()
        .add_default_ipv4_route(Ipv4Address::new(192, 168, 69, 100))
        .unwrap();
    iface
        .routes_mut()
        .add_default_ipv6_route(Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0x100))
        .unwrap();

    // Create sockets
    let mut sockets = SocketSet::new(vec![]);

    // Must fit at least one IGMP packet
    let raw_rx_buffer = raw::PacketBuffer::new(vec![raw::PacketMetadata::EMPTY; 2], vec![0; 512]);
    // Will not send IGMP
    let raw_tx_buffer = raw::PacketBuffer::new(vec![], vec![]);
    let raw_socket = raw::Socket::new(
        Some(IpVersion::Ipv4),
        Some(IpProtocol::Igmp),
        raw_rx_buffer,
        raw_tx_buffer,
    );
    let raw_handle = sockets.add(raw_socket);

    // Must fit mDNS payload of at least one packet
    let udp_rx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 4], vec![0; 1024]);
    // Will not send mDNS
    let udp_tx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY], vec![0; 0]);
    let udp_socket = udp::Socket::new(udp_rx_buffer, udp_tx_buffer);
    let udp_handle = sockets.add(udp_socket);

    // Join a multicast group to receive mDNS traffic
    iface.join_multicast_group(MDNS_GROUP).unwrap();

    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        let socket = sockets.get_mut::<raw::Socket>(raw_handle);

        if socket.can_recv() {
            // For display purposes only - normally we wouldn't process incoming IGMP packets
            // in the application layer
            match socket.recv() {
                Err(e) => println!("Recv IGMP error: {e:?}"),
                Ok(buf) => {
                    Ipv4Packet::new_checked(buf)
                        .and_then(|ipv4_packet| IgmpPacket::new_checked(ipv4_packet.payload()))
                        .and_then(|igmp_packet| IgmpRepr::parse(&igmp_packet))
                        .map(|igmp_repr| println!("IGMP packet: {igmp_repr:?}"))
                        .unwrap_or_else(|e| println!("parse IGMP error: {e:?}"));
                }
            }
        }

        let socket = sockets.get_mut::<udp::Socket>(udp_handle);
        if !socket.is_open() {
            socket.bind(MDNS_PORT).unwrap()
        }

        if socket.can_recv() {
            socket
                .recv()
                .map(|(data, sender)| {
                    println!("mDNS traffic: {} UDP bytes from {}", data.len(), sender)
                })
                .unwrap_or_else(|e| println!("Recv UDP error: {e:?}"));
        }

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
