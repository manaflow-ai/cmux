mod utils;

use log::debug;
use std::fmt::Write;
use std::os::unix::io::AsRawFd;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, Medium, wait as phy_wait};
use smoltcp::socket::{tcp, udp};
use smoltcp::time::{Duration, Instant};
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv4Address, Ipv6Address};

fn main() {
    utils::setup_logging("");

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
    let udp_rx_buffer = udp::PacketBuffer::new(
        vec![udp::PacketMetadata::EMPTY, udp::PacketMetadata::EMPTY],
        vec![0; 65535],
    );
    let udp_tx_buffer = udp::PacketBuffer::new(
        vec![udp::PacketMetadata::EMPTY, udp::PacketMetadata::EMPTY],
        vec![0; 65535],
    );
    let udp_socket = udp::Socket::new(udp_rx_buffer, udp_tx_buffer);

    let tcp1_rx_buffer = tcp::SocketBuffer::new(vec![0; 64]);
    let tcp1_tx_buffer = tcp::SocketBuffer::new(vec![0; 128]);
    let tcp1_socket = tcp::Socket::new(tcp1_rx_buffer, tcp1_tx_buffer);

    let tcp2_rx_buffer = tcp::SocketBuffer::new(vec![0; 64]);
    let tcp2_tx_buffer = tcp::SocketBuffer::new(vec![0; 128]);
    let tcp2_socket = tcp::Socket::new(tcp2_rx_buffer, tcp2_tx_buffer);

    let tcp3_rx_buffer = tcp::SocketBuffer::new(vec![0; 65535]);
    let tcp3_tx_buffer = tcp::SocketBuffer::new(vec![0; 65535]);
    let tcp3_socket = tcp::Socket::new(tcp3_rx_buffer, tcp3_tx_buffer);

    let tcp4_rx_buffer = tcp::SocketBuffer::new(vec![0; 65535]);
    let tcp4_tx_buffer = tcp::SocketBuffer::new(vec![0; 65535]);
    let tcp4_socket = tcp::Socket::new(tcp4_rx_buffer, tcp4_tx_buffer);

    let mut sockets = SocketSet::new(vec![]);
    let udp_handle = sockets.add(udp_socket);
    let tcp1_handle = sockets.add(tcp1_socket);
    let tcp2_handle = sockets.add(tcp2_socket);
    let tcp3_handle = sockets.add(tcp3_socket);
    let tcp4_handle = sockets.add(tcp4_socket);

    let mut tcp_6970_active = false;
    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        // udp:6969: respond "hello"
        let socket = sockets.get_mut::<udp::Socket>(udp_handle);
        if !socket.is_open() {
            socket.bind(6969).unwrap()
        }

        let client = match socket.recv() {
            Ok((data, endpoint)) => {
                debug!("udp:6969 recv data: {:?} from {}", data, endpoint);
                let mut data = data.to_vec();
                data.reverse();
                Some((endpoint, data))
            }
            Err(_) => None,
        };
        if let Some((endpoint, data)) = client {
            debug!("udp:6969 send data: {:?} to {}", data, endpoint,);
            socket.send_slice(&data, endpoint).unwrap();
        }

        // tcp:6969: respond "hello"
        let socket = sockets.get_mut::<tcp::Socket>(tcp1_handle);
        if !socket.is_open() {
            socket.listen(6969).unwrap();
        }

        if socket.can_send() {
            debug!("tcp:6969 send greeting");
            writeln!(socket, "hello").unwrap();
            debug!("tcp:6969 close");
            socket.close();
        }

        // tcp:6970: echo with reverse
        let socket = sockets.get_mut::<tcp::Socket>(tcp2_handle);
        if !socket.is_open() {
            socket.listen(6970).unwrap()
        }

        if socket.is_active() && !tcp_6970_active {
            debug!("tcp:6970 connected");
        } else if !socket.is_active() && tcp_6970_active {
            debug!("tcp:6970 disconnected");
        }
        tcp_6970_active = socket.is_active();

        if socket.may_recv() {
            let data = socket
                .recv(|buffer| {
                    let recvd_len = buffer.len();
                    let mut data = buffer.to_owned();
                    if !data.is_empty() {
                        debug!("tcp:6970 recv data: {:?}", data);
                        data = data.split(|&b| b == b'\n').collect::<Vec<_>>().concat();
                        data.reverse();
                        data.extend(b"\n");
                    }
                    (recvd_len, data)
                })
                .unwrap();
            if socket.can_send() && !data.is_empty() {
                debug!("tcp:6970 send data: {:?}", data);
                socket.send_slice(&data[..]).unwrap();
            }
        } else if socket.may_send() {
            debug!("tcp:6970 close");
            socket.close();
        }

        // tcp:6971: sinkhole
        let socket = sockets.get_mut::<tcp::Socket>(tcp3_handle);
        if !socket.is_open() {
            socket.listen(6971).unwrap();
            socket.set_keep_alive(Some(Duration::from_millis(1000)));
            socket.set_timeout(Some(Duration::from_millis(2000)));
        }

        if socket.may_recv() {
            socket
                .recv(|buffer| {
                    if !buffer.is_empty() {
                        debug!("tcp:6971 recv {:?} octets", buffer.len());
                    }
                    (buffer.len(), ())
                })
                .unwrap();
        } else if socket.may_send() {
            socket.close();
        }

        // tcp:6972: fountain
        let socket = sockets.get_mut::<tcp::Socket>(tcp4_handle);
        if !socket.is_open() {
            socket.listen(6972).unwrap()
        }

        if socket.may_send() {
            socket
                .send(|data| {
                    if !data.is_empty() {
                        debug!("tcp:6972 send {:?} octets", data.len());
                        for (i, b) in data.iter_mut().enumerate() {
                            *b = (i % 256) as u8;
                        }
                    }
                    (data.len(), ())
                })
                .unwrap();
        }

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
