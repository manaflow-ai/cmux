mod utils;

use byteorder::{ByteOrder, NetworkEndian};
use smoltcp::iface::{Interface, SocketSet};
use std::cmp;
use std::collections::HashMap;
use std::os::unix::io::AsRawFd;
use std::str::FromStr;

use smoltcp::iface::Config;
use smoltcp::phy::Device;
use smoltcp::phy::wait as phy_wait;
use smoltcp::socket::icmp;
use smoltcp::wire::{
    EthernetAddress, Icmpv4Packet, Icmpv4Repr, Icmpv6Packet, Icmpv6Repr, IpAddress, IpCidr,
    Ipv4Address, Ipv6Address,
};
use smoltcp::{
    phy::Medium,
    time::{Duration, Instant},
};

macro_rules! send_icmp_ping {
    ( $repr_type:ident, $packet_type:ident, $ident:expr, $seq_no:expr,
      $echo_payload:expr, $socket:expr, $remote_addr:expr ) => {{
        let icmp_repr = $repr_type::EchoRequest {
            ident: $ident,
            seq_no: $seq_no,
            data: &$echo_payload,
        };

        let icmp_payload = $socket.send(icmp_repr.buffer_len(), $remote_addr).unwrap();

        let icmp_packet = $packet_type::new_unchecked(icmp_payload);
        (icmp_repr, icmp_packet)
    }};
}

macro_rules! get_icmp_pong {
    ( $repr_type:ident, $repr:expr, $payload:expr, $waiting_queue:expr, $remote_addr:expr,
      $timestamp:expr, $received:expr ) => {{
        if let $repr_type::EchoReply { seq_no, data, .. } = $repr {
            if let Some(_) = $waiting_queue.get(&seq_no) {
                let packet_timestamp_ms = NetworkEndian::read_i64(data);
                println!(
                    "{} bytes from {}: icmp_seq={}, time={}ms",
                    data.len(),
                    $remote_addr,
                    seq_no,
                    $timestamp.total_millis() - packet_timestamp_ms
                );
                $waiting_queue.remove(&seq_no);
                $received += 1;
            }
        }
    }};
}

fn main() {
    utils::setup_logging("warn");

    let (mut opts, mut free) = utils::create_options();
    utils::add_tuntap_options(&mut opts, &mut free);
    utils::add_middleware_options(&mut opts, &mut free);
    opts.optopt(
        "c",
        "count",
        "Amount of echo request packets to send (default: 4)",
        "COUNT",
    );
    opts.optopt(
        "i",
        "interval",
        "Interval between successive packets sent (seconds) (default: 1)",
        "INTERVAL",
    );
    opts.optopt(
        "",
        "timeout",
        "Maximum wait duration for an echo response packet (seconds) (default: 5)",
        "TIMEOUT",
    );
    free.push("ADDRESS");

    let mut matches = utils::parse_options(&opts, free);
    let device = utils::parse_tuntap_options(&mut matches);
    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);
    let device_caps = device.capabilities();
    let remote_addr = IpAddress::from_str(&matches.free[0]).expect("invalid address format");
    let count = matches
        .opt_str("count")
        .map(|s| usize::from_str(&s).unwrap())
        .unwrap_or(4);
    let interval = matches
        .opt_str("interval")
        .map(|s| Duration::from_secs(u64::from_str(&s).unwrap()))
        .unwrap_or_else(|| Duration::from_secs(1));
    let timeout = Duration::from_secs(
        matches
            .opt_str("timeout")
            .map(|s| u64::from_str(&s).unwrap())
            .unwrap_or(5),
    );

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
    let icmp_rx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 256]);
    let icmp_tx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 256]);
    let icmp_socket = icmp::Socket::new(icmp_rx_buffer, icmp_tx_buffer);
    let mut sockets = SocketSet::new(vec![]);
    let icmp_handle = sockets.add(icmp_socket);

    let mut send_at = Instant::from_millis(0);
    let mut seq_no = 0;
    let mut received = 0;
    let mut echo_payload = [0xffu8; 40];
    let mut waiting_queue = HashMap::new();
    let ident = 0x22b;

    loop {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        let timestamp = Instant::now();
        let socket = sockets.get_mut::<icmp::Socket>(icmp_handle);
        if !socket.is_open() {
            socket.bind(icmp::Endpoint::Ident(ident)).unwrap();
            send_at = timestamp;
        }

        if socket.can_send() && seq_no < count as u16 && send_at <= timestamp {
            NetworkEndian::write_i64(&mut echo_payload, timestamp.total_millis());

            match remote_addr {
                IpAddress::Ipv4(_) => {
                    let (icmp_repr, mut icmp_packet) = send_icmp_ping!(
                        Icmpv4Repr,
                        Icmpv4Packet,
                        ident,
                        seq_no,
                        echo_payload,
                        socket,
                        remote_addr
                    );
                    icmp_repr.emit(&mut icmp_packet, &device_caps.checksum);
                }
                IpAddress::Ipv6(address) => {
                    let (icmp_repr, mut icmp_packet) = send_icmp_ping!(
                        Icmpv6Repr,
                        Icmpv6Packet,
                        ident,
                        seq_no,
                        echo_payload,
                        socket,
                        remote_addr
                    );
                    icmp_repr.emit(
                        &iface.get_source_address_ipv6(&address),
                        &address,
                        &mut icmp_packet,
                        &device_caps.checksum,
                    );
                }
            }

            waiting_queue.insert(seq_no, timestamp);
            seq_no += 1;
            send_at += interval;
        }

        if socket.can_recv() {
            let (payload, _) = socket.recv().unwrap();

            match remote_addr {
                IpAddress::Ipv4(_) => {
                    let icmp_packet = Icmpv4Packet::new_checked(&payload).unwrap();
                    let icmp_repr = Icmpv4Repr::parse(&icmp_packet, &device_caps.checksum).unwrap();
                    get_icmp_pong!(
                        Icmpv4Repr,
                        icmp_repr,
                        payload,
                        waiting_queue,
                        remote_addr,
                        timestamp,
                        received
                    );
                }
                IpAddress::Ipv6(address) => {
                    let icmp_packet = Icmpv6Packet::new_checked(&payload).unwrap();
                    let icmp_repr = Icmpv6Repr::parse(
                        &address,
                        &iface.get_source_address_ipv6(&address),
                        &icmp_packet,
                        &device_caps.checksum,
                    )
                    .unwrap();
                    get_icmp_pong!(
                        Icmpv6Repr,
                        icmp_repr,
                        payload,
                        waiting_queue,
                        remote_addr,
                        timestamp,
                        received
                    );
                }
            }
        }

        waiting_queue.retain(|seq, from| {
            if timestamp - *from < timeout {
                true
            } else {
                println!("From {remote_addr} icmp_seq={seq} timeout");
                false
            }
        });

        if seq_no == count as u16 && waiting_queue.is_empty() {
            break;
        }

        let timestamp = Instant::now();
        match iface.poll_at(timestamp, &sockets) {
            Some(poll_at) if timestamp < poll_at => {
                let resume_at = cmp::min(poll_at, send_at);
                phy_wait(fd, Some(resume_at - timestamp)).expect("wait error");
            }
            Some(_) => (),
            None => {
                phy_wait(fd, Some(send_at - timestamp)).expect("wait error");
            }
        }
    }

    println!("--- {remote_addr} ping statistics ---");
    println!(
        "{} packets transmitted, {} received, {:.0}% packet loss",
        seq_no,
        received,
        100.0 * (seq_no - received) as f64 / seq_no as f64
    );
}
