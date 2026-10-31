//! The first read of a connection to the WebSocket listener (`serve_ws_until`), which routes it
//! to the upgrade or to plain HTTP. A client that sends nothing in `WS_HANDSHAKE_TIMEOUT` is
//! closed; it sees that as "WebSocket protocol error: Handshake not finished", so the close is
//! logged here, as a stalled upgrade and a full listener already are.

use std::net::SocketAddr;
use tokio::net::TcpStream;

/// How many bytes of the request are in `head`, without taking them from `stream`; None when
/// the client closed, the read failed, or nothing came in time.
pub(super) async fn request(
    stream: &TcpStream,
    head: &mut [u8],
    peer: SocketAddr,
) -> Option<usize> {
    match tokio::time::timeout(super::WS_HANDSHAKE_TIMEOUT, stream.peek(head)).await {
        Ok(Ok(n)) => Some(n),
        Ok(Err(_)) => None,
        Err(_) => {
            tracing::warn!(peer = %peer, error = "request_timeout", "closing a connection that sent no request");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test(start_paused = true)]
    async fn a_connection_that_sends_no_request_is_closed_after_the_timeout() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let (stream, peer) = listener.accept().await.unwrap();
        let mut head = [0u8; 64];
        let started = tokio::time::Instant::now();
        assert_eq!(request(&stream, &mut head, peer).await, None);
        assert!(started.elapsed() >= super::super::WS_HANDSHAKE_TIMEOUT);

        client.write_all(b"GET / HTTP/1.1\r\n").await.unwrap();
        assert_eq!(request(&stream, &mut head, peer).await, Some(16));
        assert_eq!(head.get(..3), Some(&b"GET"[..]), "peeked, still there for the parser");
    }
}
