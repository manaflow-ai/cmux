//! 6lowpan benchmark example
//!
//! This example runs a simple TCP throughput benchmark using the 6lowpan implementation in smoltcp
//! It is designed to run using the Linux ieee802154/6lowpan support,
//! using mac802154_hwsim.
//!
//! mac802154_hwsim allows you to create multiple "virtual" radios and specify
//! which is in range with which. This is very useful for testing without
//! needing real hardware. By default it creates two interfaces `wpan0` and
//! `wpan1` that are in range with each other. You can customize this with
//! the `wpan-hwsim` tool.
//!
//! We'll configure Linux to speak 6lowpan on `wpan0`, and leave `wpan1`
//! unconfigured so smoltcp can use it with a raw socket.
//!
//!
//!
//!
//!
//! # Setup
//!    
//!     modprobe mac802154_hwsim
//!
//!     ip link set wpan0 down
//!     ip link set wpan1 down
//!     iwpan dev wpan0 set pan_id 0xbeef
//!     iwpan dev wpan1 set pan_id 0xbeef
//!     ip link add link wpan0 name lowpan0 type lowpan
//!     ip link set wpan0 up
//!     ip link set wpan1 up
//!     ip link set lowpan0 up
//!
//!
//! # Running
//!
//! Compile with `cargo build --release --example sixlowpan_benchmark`
//! Run it with `sudo ./target/release/examples/sixlowpan_benchmark [reader|writer]`.
//!
//! # Teardown
//!
//!     rmmod mac802154_hwsim
//!

mod utils;

use std::os::unix::io::AsRawFd;
use std::str;

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, Medium, RawSocket, wait as phy_wait};
use smoltcp::socket::tcp;
use smoltcp::wire::{EthernetAddress, Ieee802154Address, Ieee802154Pan, IpAddress, IpCidr};

//For benchmark
use smoltcp::time::{Duration, Instant};
use std::cmp;
use std::io::{Read, Write};
use std::net::SocketAddrV6;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use std::fs;

fn if_nametoindex(ifname: &str) -> u32 {
    let contents = fs::read_to_string(format!("/sys/devices/virtual/net/{ifname}/ifindex"))
        .expect("couldn't read interface from \"/sys/devices/virtual/net\"")
        .replace('\n', "");
    contents.parse::<u32>().unwrap()
}

const AMOUNT: usize = 100_000_000;

enum Client {
    Reader,
    Writer,
}

fn client(kind: Client) {
    let port: u16 = match kind {
        Client::Reader => 1234,
        Client::Writer => 1235,
    };

    let scope_id = if_nametoindex("lowpan0");

    let socket_addr = SocketAddrV6::new(
        "fe80:0:0:0:180b:4242:4242:4242".parse().unwrap(),
        port,
        0,
        scope_id,
    );

    let mut stream = TcpStream::connect(socket_addr).expect("failed to connect TLKAGMKA");
    let mut buffer = vec![0; 1_000_000];

    let start = Instant::now();

    let mut processed = 0;
    while processed < AMOUNT {
        let length = cmp::min(buffer.len(), AMOUNT - processed);
        let result = match kind {
            Client::Reader => stream.read(&mut buffer[..length]),
            Client::Writer => stream.write(&buffer[..length]),
        };
        match result {
            Ok(0) => break,
            Ok(result) => {
                // print!("(P:{})", result);
                processed += result
            }
            Err(err) => panic!("cannot process: {err}"),
        }
    }

    let end = Instant::now();

    let elapsed = (end - start).total_millis() as f64 / 1000.0;

    println!("throughput: {:.3} Gbps", AMOUNT as f64 / elapsed / 0.125e9);

    CLIENT_DONE.store(true, Ordering::SeqCst);
}

static CLIENT_DONE: AtomicBool = AtomicBool::new(false);

fn main() {
    #[cfg(feature = "log")]
    utils::setup_logging("info");

    let (mut opts, mut free) = utils::create_options();
    utils::add_middleware_options(&mut opts, &mut free);
    free.push("MODE");

    let mut matches = utils::parse_options(&opts, free);

    let device = RawSocket::new("wpan1", Medium::Ieee802154).unwrap();

    let fd = device.as_raw_fd();
    let mut device =
        utils::parse_middleware_options(&mut matches, device, /*loopback=*/ false);

    let mode = match matches.free[0].as_ref() {
        "reader" => Client::Reader,
        "writer" => Client::Writer,
        _ => panic!("invalid mode"),
    };

    // Create interface
    let mut config = match device.capabilities().medium {
        Medium::Ethernet => {
            Config::new(EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]).into())
        }
        Medium::Ip => Config::new(smoltcp::wire::HardwareAddress::Ip),
        Medium::Ieee802154 => Config::new(
            Ieee802154Address::Extended([0x1a, 0x0b, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42]).into(),
        ),
    };
    config.random_seed = rand::random();
    config.pan_id = Some(Ieee802154Pan(0xbeef));

    let mut iface = Interface::new(config, &mut device, Instant::now());
    iface.update_ip_addrs(|ip_addrs| {
        ip_addrs
            .push(IpCidr::new(
                IpAddress::v6(0xfe80, 0, 0, 0, 0x180b, 0x4242, 0x4242, 0x4242),
                64,
            ))
            .unwrap();
    });

    let tcp1_rx_buffer = tcp::SocketBuffer::new(vec![0; 4096]);
    let tcp1_tx_buffer = tcp::SocketBuffer::new(vec![0; 4096]);
    let tcp1_socket = tcp::Socket::new(tcp1_rx_buffer, tcp1_tx_buffer);

    let tcp2_rx_buffer = tcp::SocketBuffer::new(vec![0; 4096]);
    let tcp2_tx_buffer = tcp::SocketBuffer::new(vec![0; 4096]);
    let tcp2_socket = tcp::Socket::new(tcp2_rx_buffer, tcp2_tx_buffer);

    let mut sockets = SocketSet::new(vec![]);
    let tcp1_handle = sockets.add(tcp1_socket);
    let tcp2_handle = sockets.add(tcp2_socket);

    let default_timeout = Some(Duration::from_millis(1000));

    thread::spawn(move || client(mode));
    let mut processed = 0;

    while !CLIENT_DONE.load(Ordering::SeqCst) {
        let timestamp = Instant::now();
        iface.poll(timestamp, &mut device, &mut sockets);

        // tcp:1234: emit data
        let socket = sockets.get_mut::<tcp::Socket>(tcp1_handle);
        if !socket.is_open() {
            socket.listen(1234).unwrap();
        }

        if socket.can_send() && processed < AMOUNT {
            let length = socket
                .send(|buffer| {
                    let length = cmp::min(buffer.len(), AMOUNT - processed);
                    (length, length)
                })
                .unwrap();
            processed += length;
        }

        // tcp:1235: sink data
        let socket = sockets.get_mut::<tcp::Socket>(tcp2_handle);
        if !socket.is_open() {
            socket.listen(1235).unwrap();
        }

        if socket.can_recv() && processed < AMOUNT {
            let length = socket
                .recv(|buffer| {
                    let length = cmp::min(buffer.len(), AMOUNT - processed);
                    (length, length)
                })
                .unwrap();
            processed += length;
        }

        match iface.poll_at(timestamp, &sockets) {
            Some(poll_at) if timestamp < poll_at => {
                phy_wait(fd, Some(poll_at - timestamp)).expect("wait error");
            }
            Some(_) => (),
            None => {
                phy_wait(fd, default_timeout).expect("wait error");
            }
        }
    }
}
