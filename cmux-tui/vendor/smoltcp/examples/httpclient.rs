mod utils;

use log::debug;
use std::os::unix::io::AsRawFd;
use std::str::{self, FromStr};
use url::Url;

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
    free.push("URL");

    let mut matches = utils::parse_options(&opts, free);
    let device = utils::parse_tuntap_options(&mut matches);
    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);
    let address = IpAddress::from_str(&matches.free[0]).expect("invalid address format");
    let url = Url::parse(&matches.free[1]).expect("invalid url format");

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
    let tcp_rx_buffer = tcp::SocketBuffer::new(vec![0; 1024]);
    let tcp_tx_buffer = tcp::SocketBuffer::new(vec![0; 1024]);
    let tcp_socket = tcp::Socket::new(tcp_rx_buffer, tcp_tx_buffer);

    let mut sockets = SocketSet::new(vec![]);
    let tcp_handle = sockets.add(tcp_socket);

    enum State {
        Connect,
        Request,
        Response,
    }
    let mut state = State::Connect;

    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        let socket = sockets.get_mut::<tcp::Socket>(tcp_handle);
        let cx = iface.context();

        state = match state {
            State::Connect if !socket.is_active() => {
                debug!("connecting");
                let local_port = 49152 + rand::random::<u16>() % 16384;
                socket
                    .connect(cx, (address, url.port().unwrap_or(80)), local_port)
                    .unwrap();
                State::Request
            }
            State::Request if socket.may_send() => {
                debug!("sending request");
                let http_get = "GET ".to_owned() + url.path() + " HTTP/1.1\r\n";
                socket.send_slice(http_get.as_ref()).expect("cannot send");
                let http_host = "Host: ".to_owned() + url.host_str().unwrap() + "\r\n";
                socket.send_slice(http_host.as_ref()).expect("cannot send");
                socket
                    .send_slice(b"Connection: close\r\n")
                    .expect("cannot send");
                socket.send_slice(b"\r\n").expect("cannot send");
                State::Response
            }
            State::Response if socket.can_recv() => {
                socket
                    .recv(|data| {
                        println!("{}", str::from_utf8(data).unwrap_or("(invalid utf8)"));
                        (data.len(), ())
                    })
                    .unwrap();
                State::Response
            }
            State::Response if !socket.may_recv() => {
                debug!("received complete response");
                break;
            }
            _ => state,
        };

        phy_wait(fd, iface.poll_delay(timestamp, &sockets)).expect("wait error");
    }
}
