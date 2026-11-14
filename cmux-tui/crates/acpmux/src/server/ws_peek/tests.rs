use super::*;
use tokio::io::AsyncWriteExt;

async fn pair() -> (TcpStream, TcpStream, SocketAddr) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
    let (stream, peer) = listener.accept().await.unwrap();
    (client, stream, peer)
}

#[tokio::test(start_paused = true)]
async fn a_connection_that_sends_no_request_is_closed_after_the_timeout() {
    let (_client, mut stream, peer) = pair().await;
    let started = tokio::time::Instant::now();
    assert!(matches!(request(&mut stream, peer).await, Request::Gone));
    assert!(started.elapsed() >= super::super::WS_HANDSHAKE_TIMEOUT);
}

/// A head that comes in parts is read whole, and what came after it is kept for the parser.
#[tokio::test]
async fn a_head_in_parts_is_read_whole_and_replayed_with_what_followed() {
    let (mut client, mut stream, peer) = pair().await;
    let reading = tokio::spawn(async move { (request(&mut stream, peer).await, stream) });
    client.write_all(b"GET / HTTP/1.1\r\nHost: a\r\n").await.unwrap();
    tokio::task::yield_now().await;
    client.write_all(b"Upgrade: websocket\r\n\r\nafter").await.unwrap();
    let (read, stream) = reading.await.unwrap();
    let Request::Head { head, read } = read else { panic!("no head") };
    assert_eq!(head, "GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\n\r\n");
    let mut replayed = Replayed::new(read.clone(), stream);
    let mut again = vec![0u8; read.len()];
    replayed.read_exact(&mut again).await.unwrap();
    assert_eq!(again, read, "the parser reads the head again, and what followed it");
    client.write_all(b"!").await.unwrap();
    let mut next = [0u8; 1];
    replayed.read_exact(&mut next).await.unwrap();
    assert_eq!(&next, b"!", "then the connection itself");
}

#[tokio::test]
async fn a_head_with_no_blank_line_in_the_limit_is_too_large() {
    let (mut client, mut stream, peer) = pair().await;
    let reading = tokio::spawn(async move { request(&mut stream, peer).await });
    client.write_all(&vec![b'a'; MAX_HEAD_BYTES + 1]).await.unwrap();
    assert!(matches!(reading.await.unwrap(), Request::TooLarge));
}
