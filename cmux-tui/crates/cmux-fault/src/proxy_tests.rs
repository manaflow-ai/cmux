use super::{Partition, Proxy};
use crate::trace::Trace;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

async fn echo_server() -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0_u8; 1024];
                while let Ok(n) = socket.read(&mut buffer).await {
                    if n == 0 || socket.write_all(&buffer[..n]).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    addr
}

async fn echo(stream: &mut TcpStream, within: Duration) -> Option<Vec<u8>> {
    stream.write_all(b"ping").await.ok()?;
    let mut answer = [0_u8; 4];
    match tokio::time::timeout(within, stream.read_exact(&mut answer)).await {
        Ok(Ok(_)) => Some(answer.to_vec()),
        _ => None,
    }
}

#[tokio::test]
async fn the_proxy_passes_blackholes_heals_and_cuts() {
    let trace = Trace::new();
    let proxy = Proxy::start(echo_server().await, &trace).await.unwrap();
    let mut client = TcpStream::connect(proxy.addr()).await.unwrap();
    assert_eq!(echo(&mut client, Duration::from_secs(5)).await.as_deref(), Some(&b"ping"[..]));

    proxy.set(Partition::Blackhole);
    assert_eq!(echo(&mut client, Duration::from_millis(200)).await, None);
    proxy.set(Partition::Pass);
    // The held ping, then this one.
    let mut held = [0_u8; 8];
    client.write_all(b"ping").await.unwrap();
    client.read_exact(&mut held).await.unwrap();
    assert_eq!(&held, b"pingping");

    proxy.set(Partition::Delay(Duration::from_millis(150)));
    let started = std::time::Instant::now();
    assert!(echo(&mut client, Duration::from_secs(5)).await.is_some());
    assert!(started.elapsed() >= Duration::from_millis(300), "{:?}", started.elapsed());
    proxy.set(Partition::Pass);

    proxy.cut();
    let mut rest = Vec::new();
    let closed = tokio::time::timeout(Duration::from_secs(5), client.read_to_end(&mut rest));
    assert!(closed.await.is_ok(), "a cut connection stayed open");

    proxy.set(Partition::Drop);
    let mut refused = TcpStream::connect(proxy.addr()).await.unwrap();
    assert_eq!(echo(&mut refused, Duration::from_millis(300)).await, None);
    assert_eq!(proxy.accepted(), 1);
}
