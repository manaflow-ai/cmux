//! Unit tests of the driver internals in `net.rs`.
use smoltcp::wire::IpAddress;

use super::*;

struct TcpPeer {
    iface: Interface,
    device: VirtualDevice,
    sockets: SocketSet<'static>,
    handle: SocketHandle,
}

impl TcpPeer {
    fn new(address: IpAddress, seed: u64) -> Self {
        let mut device = VirtualDevice::new(1420);
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = seed;
        let mut iface = Interface::new(config, &mut device, SmolInstant::from_millis(0));
        iface.update_ip_addrs(|addresses| {
            addresses.push(IpCidr::new(address, 24)).unwrap();
        });
        let mut sockets = SocketSet::new(Vec::new());
        let handle = sockets.add(Driver::new_socket());
        Self { iface, device, sockets, handle }
    }

    fn socket(&self) -> &tcp::Socket<'static> {
        self.sockets.get::<tcp::Socket>(self.handle)
    }

    fn socket_mut(&mut self) -> &mut tcp::Socket<'static> {
        self.sockets.get_mut::<tcp::Socket>(self.handle)
    }

    fn poll(&mut self, now: SmolInstant) {
        self.iface.poll(now, &mut self.device, &mut self.sockets);
    }
}

/// Exchange actual TCP packets without WireGuard or wall-clock delays.
fn exchange_tcp(left: &mut TcpPeer, right: &mut TcpPeer, now: SmolInstant) {
    for _ in 0..16 {
        left.poll(now);
        right.poll(now);
        let mut transferred = false;
        while let Some(packet) = left.device.pop_tx() {
            right.device.push_rx(packet);
            transferred = true;
        }
        while let Some(packet) = right.device.pop_tx() {
            left.device.push_rx(packet);
            transferred = true;
        }
        if !transferred {
            return;
        }
    }
    panic!("TCP packet exchange did not settle");
}

fn connected_tcp_peers() -> (TcpPeer, TcpPeer) {
    let client_ip = IpAddress::Ipv4("10.200.0.1".parse().unwrap());
    let server_ip = IpAddress::Ipv4("10.200.0.2".parse().unwrap());
    let mut client = TcpPeer::new(client_ip, 1);
    let mut server = TcpPeer::new(server_ip, 2);
    server.socket_mut().listen(1337).unwrap();
    client
        .sockets
        .get_mut::<tcp::Socket>(client.handle)
        .connect(
            client.iface.context(),
            IpEndpoint::new(server_ip, 1337),
            IpEndpoint::new(client_ip, FIRST_EPHEMERAL_PORT),
        )
        .unwrap();
    exchange_tcp(&mut client, &mut server, SmolInstant::from_millis(0));
    assert_eq!(client.socket().state(), tcp::State::Established);
    assert_eq!(server.socket().state(), tcp::State::Established);
    (client, server)
}

#[test]
fn tcp_idle_healthy_peers_survive_multiple_timeouts() {
    let (mut client, mut server) = connected_tcp_peers();
    // Idle link-group lanes must stay usable even when all application
    // heartbeats and traffic travel over a different TCP connection.
    for second in 1..=180 {
        exchange_tcp(&mut client, &mut server, SmolInstant::from_secs(second));
        assert_eq!(client.socket().state(), tcp::State::Established, "client at {second}s");
        assert_eq!(server.socket().state(), tcp::State::Established, "server at {second}s");
        assert_eq!(client.socket().recv_queue(), 0, "probes must not reach the application");
        assert_eq!(server.socket().recv_queue(), 0, "probes must not reach the application");
    }

    client.socket_mut().send_slice(b"client after idle").unwrap();
    server.socket_mut().send_slice(b"server after idle").unwrap();
    exchange_tcp(&mut client, &mut server, SmolInstant::from_secs(181));
    let mut received = [0u8; 64];
    let count = client.socket_mut().recv_slice(&mut received).unwrap();
    assert_eq!(&received[..count], b"server after idle");
    let count = server.socket_mut().recv_slice(&mut received).unwrap();
    assert_eq!(&received[..count], b"client after idle");
}

#[test]
fn tcp_idle_unresponsive_peer_still_times_out() {
    let (mut client, _server) = connected_tcp_peers();
    // Stop delivering packets after the handshake, as with a dead peer.
    // Sending probes alone must not refresh the receive timeout.
    for second in 1..60 {
        client.poll(SmolInstant::from_secs(second));
        while client.device.pop_tx().is_some() {}
        assert_eq!(client.socket().state(), tcp::State::Established, "client at {second}s");
    }
    client.poll(SmolInstant::from_secs(60));
    assert_eq!(client.socket().state(), tcp::State::Closed);
}

#[tokio::test]
async fn cancelled_hub_dial_releases_the_pending_tcp_socket() {
    let pair = crate::testing::loopback_pair().await.unwrap();
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay =
        SocketPath::new(pair.client_socket, Some(pair.server_socket.local_addr().unwrap()));
    let mut driver =
        Driver::new(pair.client, Box::new(underlay), receiver, Arc::new(Notify::new())).unwrap();
    let (reply, pending) = oneshot::channel();
    driver.begin_connect(SocketAddr::new(pair.server_v6, 1337), reply);
    assert_eq!(driver.conns.len(), 1);
    assert_eq!(driver.sockets.iter().count(), 1);

    drop(pending);
    driver.process_conns();

    assert!(driver.conns.is_empty(), "a cancelled dial must not wait for TCP_TIMEOUT");
    assert_eq!(driver.sockets.iter().count(), 0);
}

#[test]
fn packet_source_reads_both_families() {
    let mut v4 = vec![0u8; 20];
    v4[0] = 0x45;
    v4[12..16].copy_from_slice(&[10, 200, 0, 2]);
    assert_eq!(packet_source(&v4), Some("10.200.0.2".parse().unwrap()));

    let mut v6 = vec![0u8; 40];
    v6[0] = 0x60;
    v6[8] = 0xfd;
    v6[9] = 0xcc;
    v6[23] = 1;
    assert_eq!(packet_source(&v6), Some("fdcc::1".parse().unwrap()));

    assert_eq!(packet_source(&[0x45; 10]), None);
    assert_eq!(packet_source(&[]), None);
}
