mod utils;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::Device;
use smoltcp::phy::{Medium, wait as phy_wait};
use smoltcp::socket::dns::{self, GetQueryResultError};
use smoltcp::time::Instant;
use smoltcp::wire::{DnsQueryType, EthernetAddress, IpAddress, IpCidr, Ipv4Address, Ipv6Address};
use std::os::unix::io::AsRawFd;

fn main() {
    utils::setup_logging("warn");

    let (mut opts, mut free) = utils::create_options();
    utils::add_tuntap_options(&mut opts, &mut free);
    utils::add_middleware_options(&mut opts, &mut free);
    free.push("ADDRESS");

    let mut matches = utils::parse_options(&opts, free);
    let device = utils::parse_tuntap_options(&mut matches);
    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);
    let name = &matches.free[0];

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
    let servers = &[
        Ipv4Address::new(8, 8, 4, 4).into(),
        Ipv4Address::new(8, 8, 8, 8).into(),
    ];
    let dns_socket = dns::Socket::new(servers, vec![]);

    let mut sockets = SocketSet::new(vec![]);
    let dns_handle = sockets.add(dns_socket);

    let socket = sockets.get_mut::<dns::Socket>(dns_handle);
    let query = socket
        .start_query(iface.context(), name, DnsQueryType::A)
        .unwrap();

    loop {
        let timestamp = Instant::now();
        log::debug!("timestamp {:?}", timestamp);

        iface.poll(timestamp, &mut device, &mut sockets);

        match sockets
            .get_mut::<dns::Socket>(dns_handle)
            .get_query_result(query)
        {
            Ok(addrs) => {
                println!("Query done: {addrs:?}");
                break;
            }
            Err(GetQueryResultError::Pending) => {} // not done yet
            Err(e) => panic!("query failed: {e:?}"),
        }

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
