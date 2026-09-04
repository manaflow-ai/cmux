//! Two in-process WireGuard peers over loopback UDP: no root, no interface.

use std::future::Future;
use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::{LoopbackPair, loopback_pair};
use cmux_wg::{WgError, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;

const TIMEOUT: Duration = Duration::from_secs(10);

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(TIMEOUT, future).await.expect("timed out")
}

/// Accept connections forever and echo every byte back.
async fn spawn_echo(server: &WgNet, port: u16) -> tokio::task::JoinHandle<()> {
    let mut listener = server.listen(port).await.expect("listen");
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 16 * 1024];
                loop {
                    match stream.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(count) => {
                            if stream.write_all(&buffer[..count]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = stream.shutdown().await;
            });
        }
    })
}

async fn round_trip(stream: &mut WgStream, payload: &[u8]) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let write = async {
        writer.write_all(payload).await.expect("write");
    };
    let read = async {
        let mut received = vec![0u8; payload.len()];
        reader.read_exact(&mut received).await.expect("read");
        assert_eq!(received, payload);
    };
    within(async { tokio::join!(write, read) }).await;
}

fn payload(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index % 251) as u8).collect()
}

#[tokio::test]
async fn tcp_echo_through_the_tunnel_in_both_families() {
    let LoopbackPair { client, server, client_socket, server_socket, server_v4, server_v6, .. } =
        loopback_pair().await.unwrap();
    let server = WgNet::start(server, server_socket).await.unwrap();
    let client = WgNet::start(client, client_socket).await.unwrap();
    let _echo = spawn_echo(&server, 1337).await;

    let mut v4 = within(client.connect(SocketAddr::new(server_v4, 1337))).await.unwrap();
    assert_eq!(v4.peer_addr(), SocketAddr::new(server_v4, 1337));
    round_trip(&mut v4, b"hello").await;
    round_trip(&mut v4, &payload(1200)).await;
    round_trip(&mut v4, &payload(64 * 1024)).await;

    let mut v6 = within(client.connect(SocketAddr::new(server_v6, 1337))).await.unwrap();
    round_trip(&mut v6, &payload(1200)).await;
    round_trip(&mut v6, &payload(64 * 1024)).await;

    assert!(client.time_since_last_handshake().await.unwrap().is_some());
    assert!(server.time_since_last_handshake().await.unwrap().is_some());

    within(v4.shutdown()).await.unwrap();
    let mut end = [0u8; 1];
    assert_eq!(within(v4.read(&mut end)).await.unwrap(), 0, "echo peer closes after our FIN");
    drop(v6);
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test]
async fn a_restarted_client_handshakes_again() {
    let LoopbackPair { client, server, client_socket, server_socket, server_v4, .. } =
        loopback_pair().await.unwrap();
    let server = WgNet::start(server, server_socket).await.unwrap();
    let _echo = spawn_echo(&server, 2222).await;

    let first = WgNet::start(client.clone(), client_socket).await.unwrap();
    let mut stream = within(first.connect(SocketAddr::new(server_v4, 2222))).await.unwrap();
    round_trip(&mut stream, b"first session").await;
    drop(stream);
    first.shutdown().await;

    // A new socket means a new source port: the server must accept the fresh
    // handshake and roam to the new endpoint.
    let second_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let second = WgNet::start(client, second_socket).await.unwrap();
    let mut stream = within(second.connect(SocketAddr::new(server_v4, 2222))).await.unwrap();
    round_trip(&mut stream, &payload(4096)).await;
    second.shutdown().await;
    server.shutdown().await;
}

#[tokio::test]
async fn a_closed_port_is_refused_and_routes_are_reported() {
    let LoopbackPair { client, server, client_socket, server_socket, server_v4, .. } =
        loopback_pair().await.unwrap();
    let server = WgNet::start(server, server_socket).await.unwrap();
    let client = WgNet::start(client, client_socket).await.unwrap();

    assert!(client.routes_contain("10.200.0.77".parse().unwrap()));
    assert!(client.routes_contain("fdcc::9".parse().unwrap()));
    assert!(!client.routes_contain("10.201.0.1".parse().unwrap()));
    assert_eq!(client.routes().len(), 2);

    let error = within(client.connect(SocketAddr::new(server_v4, 4444))).await.unwrap_err();
    assert!(matches!(error, WgError::ConnectionRefused(_)), "{error}");

    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test]
async fn outbound_connect_rejects_target_outside_allowed_ips() {
    let LoopbackPair { client, server, client_socket, server_socket, .. } =
        loopback_pair().await.unwrap();
    let server = WgNet::start(server, server_socket).await.unwrap();
    let client = WgNet::start(client, client_socket).await.unwrap();
    let target = SocketAddr::new("10.201.0.1".parse().unwrap(), 1337);

    let error = within(client.connect(target)).await.unwrap_err();
    assert!(
        matches!(error, WgError::RouteNotAllowed(address) if address == target.ip()),
        "{error}"
    );

    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test]
async fn dropping_the_tunnel_ends_its_streams() {
    let LoopbackPair { client, server, client_socket, server_socket, server_v4, .. } =
        loopback_pair().await.unwrap();
    let server = WgNet::start(server, server_socket).await.unwrap();
    let client = WgNet::start(client, client_socket).await.unwrap();
    let _echo = spawn_echo(&server, 3333).await;

    let mut stream = within(client.connect(SocketAddr::new(server_v4, 3333))).await.unwrap();
    round_trip(&mut stream, b"alive").await;
    drop(client);

    let mut end = [0u8; 8];
    let read = within(stream.read(&mut end)).await;
    assert!(matches!(read, Ok(0) | Err(_)), "stream should end after its tunnel is dropped");
    server.shutdown().await;
}
