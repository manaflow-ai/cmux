mod utils;

use std::os::unix::io::AsRawFd;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, Medium, wait as phy_wait};
use smoltcp::socket::udp;
use smoltcp::time::{Duration, Instant};
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv6Address};

const LOCAL_ADDR: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0x0, 0, 0, 0x01);

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
    config.slaac = true;

    let mut iface = Interface::new(config, &mut device, Instant::now());
    iface.update_ip_addrs(|ip_addrs| {
        ip_addrs
            .push(IpCidr::new(IpAddress::from(LOCAL_ADDR), 64))
            .unwrap();
    });

    let mut sockets = SocketSet::new(vec![]);
    let udp_rx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 4], vec![0; 1024]);
    let udp_tx_buffer = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY], vec![0; 0]);
    let udp_socket = udp::Socket::new(udp_rx_buffer, udp_tx_buffer);
    let _udp_handle = sockets.add(udp_socket);

    let mut last_print = Instant::now();
    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);
        let mut delay = iface.poll_delay(timestamp, &sockets);
        if delay.is_none() || delay.is_some_and(|d| d > Duration::from_millis(1000)) {
            delay = Some(Duration::from_millis(1000));
        }

        phy_wait(fd, delay).expect("wait error");

        let timestamp = Instant::now();
        if timestamp > last_print + Duration::from_secs(1) {
            last_print = timestamp;
            println!();
            println!("Addresses:");
            for addr in iface.ip_addrs() {
                println!("  - {addr}");
            }
            println!("Routes:");
            iface.routes_mut().update(|routes| {
                for route in routes {
                    println!("  - {} via {}", route.cidr, route.via_router);
                }
            });
        }
    }
}
