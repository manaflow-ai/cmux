//! Ultra mode over a link that loses datagrams: FEC (XOR or Reed-Solomon)
//! rebuilds them below WireGuard in both directions, and the two ends agree
//! on the mode inside the tunnel, so one end turning it on is enough.

use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::{DatagramClass, classify};
use cmux_wg::testing::{LoopbackPair, loopback_pair};
use cmux_wg::{Origin, Received, UdpUnderlay, UltraMode, Underlay, WgNet};
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
