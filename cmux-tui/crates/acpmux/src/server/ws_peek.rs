//! The first bytes of a connection to the WebSocket listener (`serve_ws_until`): its whole
//! request head, which routes it to the upgrade or to plain HTTP. The head is read to its blank
//! line before the route is chosen: a client whose head arrives in parts (headers written one
//! by one, a slow link) once had its upgrade taken for a page request when the first part held
//! no `Upgrade` header. The upgrade then reads the same bytes again through [`Replayed`]. A
//! client that sends no whole head in `WS_HANDSHAKE_TIMEOUT` is closed; it sees that as
//! "WebSocket protocol error: Handshake not finished", so the close is logged here, as a stalled
//! upgrade and a full listener already are.

use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

/// The largest request head the listener reads (room for large localhost cookies).
pub(super) const MAX_HEAD_BYTES: usize = 32 * 1024;

/// What the first bytes of a connection were.
pub(super) enum Request {
    /// A whole head (to its blank line), and every byte read with it.
    Head { head: String, read: Vec<u8> },
    /// No blank line in [`MAX_HEAD_BYTES`].
    TooLarge,
    /// The client closed, the read failed, or no whole head came in time.
    Gone,
}

/// Read `stream`'s request head to its blank line.
pub(super) async fn request(stream: &mut TcpStream, peer: SocketAddr) -> Request {
    let read = async {
        let mut read = Vec::with_capacity(1024);
        let mut chunk = [0u8; 4096];
        loop {
            if let Some(end) = head_end(&read) {
                let head = String::from_utf8_lossy(read.get(..end).unwrap_or(&read)).into_owned();
                return Request::Head { head, read };
            }
            if read.len() >= MAX_HEAD_BYTES {
                return Request::TooLarge;
            }
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => return Request::Gone,
                Ok(n) => read.extend_from_slice(chunk.get(..n).unwrap_or(&chunk)),
            }
        }
    };
    match tokio::time::timeout(super::WS_HANDSHAKE_TIMEOUT, read).await {
        Ok(request) => request,
        Err(_) => {
            tracing::warn!(peer = %peer, error = "request_timeout", "closing a connection that sent no request");
            Request::Gone
        }
    }
}

/// The length of the head in `read`, blank line included, once it is all there.
fn head_end(read: &[u8]) -> Option<usize> {
    read.windows(4).position(|window| window == b"\r\n\r\n").map(|at| at + 4)
}

/// `stream` with the bytes [`request`] read from it first, for the upgrade's parser.
pub(super) struct Replayed {
    read: Vec<u8>,
    at: usize,
    stream: TcpStream,
}

impl Replayed {
    pub(super) fn new(read: Vec<u8>, stream: TcpStream) -> Self {
        Self { read, at: 0, stream }
    }
}

impl AsyncRead for Replayed {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if let Some(rest) = this.read.get(this.at..)
            && !rest.is_empty()
        {
            let n = rest.len().min(buf.remaining());
            if let Some(part) = rest.get(..n) {
                buf.put_slice(part);
            }
            this.at += n;
            if this.at >= this.read.len() {
                // Replayed whole: the connection keeps no copy of its head.
                this.read = Vec::new();
                this.at = 0;
            }
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for Replayed {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.stream.is_write_vectored()
    }
}

#[cfg(test)]
mod tests {
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
}
