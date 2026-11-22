mod utils;

use log::debug;
use std::os::unix::io::AsRawFd;
use std::str::{self, FromStr};

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, Medium, wait as phy_wait};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv4Address, Ipv6Address};

fn main() {
    utils::setup_logging("");

    let (mut opts, mut free) = utils::create_options();
    utils::add_tuntap_options(&mut opts, &mut free);
    utils::add_middleware_options(&mut opts, &mut free);
    free.push("ADDRESS");
    free.push("PORT");

    let mut matches = utils::parse_options(&opts, free);
    let device = utils::parse_tuntap_options(&mut matches);

    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);
    let address = IpAddress::from_str(&matches.free[0]).expect("invalid address format");
    let port = u16::from_str(&matches.free[1]).expect("invalid port format");

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
    let tcp_rx_buffer = tcp::SocketBuffer::new(vec![0; 1500]);
    let tcp_tx_buffer = tcp::SocketBuffer::new(vec![0; 1500]);
    let tcp_socket = tcp::Socket::new(tcp_rx_buffer, tcp_tx_buffer);
    let mut sockets = SocketSet::new(vec![]);
    let tcp_handle = sockets.add(tcp_socket);

    let socket = sockets.get_mut::<tcp::Socket>(tcp_handle);
    socket
        .connect(iface.context(), (address, port), 49500)
        .unwrap();

    let mut tcp_active = false;
    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        let socket = sockets.get_mut::<tcp::Socket>(tcp_handle);
        if socket.is_active() && !tcp_active {
            debug!("connected");
        } else if !socket.is_active() && tcp_active {
            debug!("disconnected");
            break;
        }
        tcp_active = socket.is_active();

        if socket.may_recv() {
            let data = socket
                .recv(|data| {
                    let mut data = data.to_owned();
                    if !data.is_empty() {
                        debug!(
                            "recv data: {:?}",
                            str::from_utf8(data.as_ref()).unwrap_or("(invalid utf8)")
                        );
                        data = data.split(|&b| b == b'\n').collect::<Vec<_>>().concat();
                        data.reverse();
                        data.extend(b"\n");
                    }
                    (data.len(), data)
                })
                .unwrap();
            if socket.can_send() && !data.is_empty() {
                debug!(
                    "send data: {:?}",
                    str::from_utf8(data.as_ref()).unwrap_or("(invalid utf8)")
                );
                socket.send_slice(&data[..]).unwrap();
            }
        } else if socket.may_send() {
            debug!("close");
            socket.close();
        }

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
