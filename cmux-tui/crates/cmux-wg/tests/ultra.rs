//! Ultra mode over a link that loses datagrams: FEC (XOR or Reed-Solomon)
//! rebuilds them below WireGuard in both directions, and the two ends agree
//! on the mode inside the tunnel, so one end turning it on is enough.

use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::{DatagramClass, classify};
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::testing::{LoopbackPair, config_pair, loopback_pair};
use cmux_wg::{
    Origin, Priority, Received, SocketPath, UdpUnderlay, UltraMode, Underlay, WgError, WgNet,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const TIMEOUT: Duration = Duration::from_secs(20);

/// A UDP path that drops every `every`-th WireGuard data datagram it sends
/// (never, for 0), and never a parity or handshake datagram.
struct Lossy {
    inner: UdpUnderlay,
    every: u64,
    seen: u64,
}

impl Underlay for Lossy {
    fn send(&mut self, datagram: &[u8]) {
        if classify(datagram) == DatagramClass::WireGuardData {
            self.seen += 1;
            if self.every > 0 && self.seen.is_multiple_of(self.every) {
                return;
            }
        }
        self.inner.send(datagram);
    }
    fn flush(&mut self) {
        self.inner.flush();
    }
    fn backlogged(&self) -> bool {
        self.inner.backlogged()
    }
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_flush(cx)
    }
    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        self.inner.poll_recv(cx, buffer)
    }
    fn authenticated(&mut self, origin: Origin) {
        self.inner.authenticated(origin);
    }
    fn has_peer(&self) -> bool {
        self.inner.has_peer()
    }
    fn peer_hint(&self) -> Option<SocketAddr> {
        self.inner.peer_hint()
    }
}

/// A tunnel whose client and server paths drop every `client_every`-th and
/// `server_every`-th data datagram they send.
async fn pair(
    (client_mode, client_every): (UltraMode, u64),
    (server_mode, server_every): (UltraMode, u64),
) -> (WgNet, WgNet, SocketAddr) {
    let LoopbackPair { client, server, client_socket, server_socket, server_v4, .. } =
        loopback_pair().await.unwrap();
    let server_addr = server_socket.local_addr().unwrap();
    let lossy =
        |socket, peer, every| Lossy { inner: UdpUnderlay::new(socket, peer), every, seen: 0 };
    let server =
        WgNet::start_with_ultra(server, lossy(server_socket, None, server_every), server_mode)
            .unwrap();
    let client = WgNet::start_with_ultra(
        client,
        lossy(client_socket, Some(server_addr), client_every),
        client_mode,
    )
    .unwrap();
    (client, server, SocketAddr::new(server_v4, 7000))
}

/// Send `len` bytes to an echo server and read them back.
async fn echo(client: &WgNet, server: &WgNet, target: SocketAddr, len: usize) {
    let mut listener = server.listen(target.port()).await.unwrap();
    tokio::spawn(async move {
        let mut stream = listener.accept().await.unwrap();
        let mut buffer = vec![0u8; 16 * 1024];
        loop {
            match stream.read(&mut buffer).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stream.write_all(&buffer[..n]).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
    let stream = tokio::time::timeout(TIMEOUT, client.connect(target)).await.unwrap().unwrap();
    let (mut reader, mut writer) = tokio::io::split(stream);
    let payload: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
    let expected = payload.clone();
    let write = async move { writer.write_all(&payload).await.unwrap() };
    let read = async move {
        let mut got = vec![0u8; len];
        reader.read_exact(&mut got).await.unwrap();
        assert!(got == expected, "echo came back intact");
    };
    tokio::time::timeout(TIMEOUT, async { tokio::join!(write, read) }).await.unwrap();
}

#[tokio::test]
async fn fec_on_both_ends_rebuilds_lost_datagrams_both_ways() {
    let fec = UltraMode::Fec { group: 8, parity: 2 };
    let (client, server, target) = pair((fec, 9), (fec, 9)).await;
    echo(&client, &server, target, 512 * 1024).await;
    let (client, server) = (client.ultra_stats(), server.ultra_stats());
    assert!(client.parity_sent > 0, "client sends parity: {client:?}");
    assert!(server.recovered > 0, "server rebuilds what the link dropped: {server:?}");
    assert!(server.parity_sent > 0, "server sends parity: {server:?}");
    assert!(client.recovered > 0, "client rebuilds the echo's losses: {client:?}");
}

#[tokio::test]
async fn reed_solomon_rebuilds_a_fifth_of_the_datagrams_lost_both_ways() {
    // Every 5th data datagram is lost each way: more than XOR parity's one
    // loss per subgroup can be counted on to cover.
    let rs = UltraMode::Rs { group: 8, parity: 4 };
    let (client, server, target) = pair((rs, 5), (rs, 5)).await;
    echo(&client, &server, target, 512 * 1024).await;
    let (client, server) = (client.ultra_stats(), server.ultra_stats());
    assert!(client.parity_sent > 0 && server.parity_sent > 0, "{client:?} {server:?}");
    assert!(server.recovered > 0, "server rebuilds what the link dropped: {server:?}");
    assert!(client.recovered > 0, "client rebuilds the echo's losses: {client:?}");
}

#[tokio::test]
async fn ultra_on_one_end_is_agreed_for_both_directions() {
    // Only the client turned it on (an app setting); both directions lose
    // datagrams. The hello inside the tunnel makes the server send parity
    // too, so the client rebuilds the echo's losses.
    let rs = UltraMode::Rs { group: 4, parity: 4 };
    let (client, server, target) = pair((rs, 9), (UltraMode::Off, 9)).await;
    echo(&client, &server, target, 512 * 1024).await;
    let (client, server) = (client.ultra_stats(), server.ultra_stats());
    assert!(server.recovered > 0, "server rebuilds from the client's parity: {server:?}");
    assert!(server.parity_sent > 0, "server agreed to the client's mode: {server:?}");
    assert!(client.recovered > 0, "client rebuilds the server's losses: {client:?}");
}

#[tokio::test]
async fn the_stronger_mode_wins_the_agreement() {
    // XOR on the client, Reed-Solomon on the server: both send Reed-Solomon,
    // and a fifth of the data lost each way is rebuilt.
    let fec = UltraMode::Fec { group: 8, parity: 2 };
    let rs = UltraMode::Rs { group: 4, parity: 4 };
    let (client, server, target) = pair((fec, 5), (rs, 5)).await;
    echo(&client, &server, target, 512 * 1024).await;
    let (client, server) = (client.ultra_stats(), server.ultra_stats());
    assert!(client.recovered > 0 && server.recovered > 0, "{client:?} {server:?}");
}

#[tokio::test]
async fn duplication_is_agreed_too() {
    // The client asked for copies; the server, started off, sends them too.
    let (client, server, target) =
        pair((UltraMode::Duplicate { copies: 2 }, 9), (UltraMode::Off, 9)).await;
    echo(&client, &server, target, 256 * 1024).await;
    assert!(client.ultra_stats().copies_sent > 0);
    assert!(server.ultra_stats().copies_sent > 0, "the server agreed to copies");
}

/// Remote desktop's overlay port (transport.md: service `remote-desktop`).
const REMOTE_DESKTOP: u16 = 4103;

/// A peer from before the in-tunnel hello, with remote desktop bound on
/// 4103: it hands every datagram to 4103 to remote desktop, and drops
/// what goes to the control port 4102 unless it is a probe. The first
/// hellos went to 4103, so it would have read them as media. Now they go
/// to 4102: remote desktop gets exactly what the viewer sent, through every
/// hello retry, and the upgraded side gives up and keeps its own mode. A
/// payload on 4103 that looks like a version-1 hello is media to the
/// upgraded side too.
#[tokio::test(start_paused = true)]
async fn an_older_peer_with_remote_desktop_on_4103_never_gets_a_hello() {
    let (client_addr, server_addr): (SocketAddr, SocketAddr) =
        ("192.0.2.120:51820".parse().unwrap(), "192.0.2.121:51820".parse().unwrap());
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(client_addr, server_addr, link);
    let configs = config_pair(server_addr);
    let rs = UltraMode::Rs { group: 4, parity: 4 };
    let client_path = SocketPath::new(sim.bind(client_addr).unwrap(), Some(server_addr));
    let client = WgNet::start_with_ultra(configs.client.clone(), client_path, rs).unwrap();
    let server_path = SocketPath::new(sim.bind(server_addr).unwrap(), None);
    let older =
        WgNet::start_without_hello(configs.server.clone(), server_path, UltraMode::Off).unwrap();
    let mut desktop = older.bind_datagram(REMOTE_DESKTOP).await.unwrap();
    let mut viewer = client.bind_datagram(REMOTE_DESKTOP).await.unwrap();
    for net in [&client, &older] {
        let control = net.bind_datagram(4102).await;
        assert!(matches!(control, Err(WgError::ListenerBusy(4102))), "the control port is owned");
    }

    // Input every 250 ms for 10 s: past every hello retry (0.25 + 0.5 + 1
    // + 2 s after the first).
    let peer = SocketAddr::new(configs.server_v6, REMOTE_DESKTOP);
    let mut sent = Vec::new();
    for i in 0..40u8 {
        let payload = vec![i; 100];
        viewer.send_to(&payload, peer, Priority::Interactive).await.unwrap();
        sent.push(payload);
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let mut got = Vec::new();
    while let Ok(Some((payload, _))) =
        tokio::time::timeout(Duration::from_secs(2), desktop.recv_from()).await
    {
        got.push(payload);
    }
    got.sort();
    assert_eq!(got, sent, "remote desktop got the viewer's datagrams and nothing else");

    let old_hello = [b'C', b'M', b'X', b'U', 1, 0, 3, 4, 4];
    let viewer_addr = SocketAddr::new(configs.client_v6, REMOTE_DESKTOP);
    desktop.send_to(&old_hello, viewer_addr, Priority::Interactive).await.unwrap();
    let (payload, _) = tokio::time::timeout(TIMEOUT, viewer.recv_from()).await.unwrap().unwrap();
    assert_eq!(payload, old_hello, "remote desktop's payload is not taken as a hello");

    let (client_stats, older_stats) = (client.ultra_stats(), older.ultra_stats());
    assert!(client_stats.parity_sent > 0, "the upgraded side keeps its own mode");
    assert_eq!(older_stats.parity_sent, 0, "the older peer keeps its own: {older_stats:?}");
    client.shutdown().await;
    older.shutdown().await;
}
