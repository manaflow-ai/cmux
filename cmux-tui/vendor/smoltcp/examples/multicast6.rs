mod utils;

use std::os::unix::io::AsRawFd;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::wait as phy_wait;
use smoltcp::phy::{Device, Medium};
use smoltcp::socket::udp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv6Address};

// Note: If testing with a tap interface in linux, you may need to specify the
// interface index when addressing. E.g.,
//
// ```
// ncat -u ff02::1234%tap0 8123
// ```
//
// will send packets to the multicast group we join below on tap0.

const PORT: u16 = 8123;
const GROUP: Ipv6Address = Ipv6Address::new(0xff02, 0, 0, 0, 0, 0, 0, 0x1234);
const LOCAL_ADDR: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0x101);
const ROUTER_ADDR: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0x100);

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
    let ethernet_addr = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x02]);
    let mut config = match device.capabilities().medium {
        Medium::Ethernet => Config::new(ethernet_addr.into()),
        Medium::Ip => Config::new(smoltcp::wire::HardwareAddress::Ip),
        Medium::Ieee802154 => todo!(),
    };
    config.random_seed = rand::random();

    let mut iface = Interface::new(config, &mut device, Instant::now());
    iface.update_ip_addrs(|ip_addrs| {
        ip_addrs
            .push(IpCidr::new(IpAddress::from(LOCAL_ADDR), 64))
            .unwrap();
    });
    iface
        .routes_mut()
        .add_default_ipv6_route(ROUTER_ADDR)
        .unwrap();

    // Create sockets
    let mut sockets = SocketSet::new(vec![]);
    let udp_rx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 4], vec![0; 1024]);
    let udp_tx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY], vec![0; 0]);
    let udp_socket = udp::Socket::new(udp_rx_buffer, udp_tx_buffer);
    let udp_handle = sockets.add(udp_socket);

    // Join a multicast group
    iface.join_multicast_group(GROUP).unwrap();

    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        let socket = sockets.get_mut::<udp::Socket>(udp_handle);
        if !socket.is_open() {
            socket.bind(PORT).unwrap()
        }

        if socket.can_recv() {
            socket
                .recv()
                .map(|(data, sender)| println!("traffic: {} UDP bytes from {}", data.len(), sender))
                .unwrap_or_else(|e| println!("Recv UDP error: {:?}", e));
        }

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
