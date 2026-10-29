//! A stream whose first reads return bytes already read off it. The web listener reads a
//! connection's whole request head before it routes it (`serve_ws_with`): a peek returns
//! whatever has arrived, which may be the head's first segment only, so an upgrade
//! request whose `Upgrade` line had not arrived yet was served as a page. The WebSocket
//! handshake then reads the head again from here.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

pub(super) struct Rewind<S> {
    prefix: Vec<u8>,
    /// How much of `prefix` was read.
    at: usize,
    inner: S,
}

impl<S> Rewind<S> {
    pub(super) fn new(prefix: Vec<u8>, inner: S) -> Self {
        Self { prefix, at: 0, inner }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for Rewind<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let rest = this.prefix.get(this.at..).unwrap_or_default();
        if !rest.is_empty() {
            let n = rest.len().min(buf.remaining());
            buf.put_slice(rest.get(..n).unwrap_or_default());
            this.at += n;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Rewind<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn the_prefix_reads_first_then_the_stream() {
        let (mut client, server) = tokio::io::duplex(64);
        client.write_all(b" world").await.unwrap();
        drop(client);
        let mut rewound = Rewind::new(b"hello".to_vec(), server);
        let mut all = String::new();
        rewound.read_to_string(&mut all).await.unwrap();
        assert_eq!(all, "hello world");
    }
}
