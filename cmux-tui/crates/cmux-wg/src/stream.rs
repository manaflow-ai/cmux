//! One TCP connection through the tunnel, as the caller sees it.
//!
//! A stream is two bounded channels and a wake signal. The driver copies
//! between them and the smoltcp socket on every service pass.

use std::fmt;
use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Notify, mpsc};
use tokio_util::sync::PollSender;

/// Largest single write a stream accepts before splitting it.
const MAX_WRITE_CHUNK_BYTES: usize = 64 * 1024;

pub(crate) enum Outbound {
    Data(Bytes),
    Shutdown,
}

/// One TCP connection through the tunnel, usable wherever a `TcpStream` is.
pub struct WgStream {
    pub(crate) local: SocketAddr,
    pub(crate) remote: SocketAddr,
    pub(crate) inbound: mpsc::Receiver<Bytes>,
    pub(crate) leftover: Bytes,
    pub(crate) outbound: PollSender<Outbound>,
    pub(crate) wake: Arc<Notify>,
    pub(crate) shutdown_sent: bool,
    /// Set by the driver before it drops a connection whose end the owner
    /// must see as an error (a mesh peer was removed), not as EOF.
    pub(crate) reset: Arc<AtomicBool>,
}

impl fmt::Debug for WgStream {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WgStream")
            .field("local", &self.local)
            .field("remote", &self.remote)
            .finish_non_exhaustive()
    }
}

impl WgStream {
    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }

    pub fn peer_addr(&self) -> SocketAddr {
        self.remote
    }
}

fn broken_pipe() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "tunnel connection is closed")
}

impl AsyncRead for WgStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = &mut *self;
        if this.leftover.is_empty() {
            match this.inbound.poll_recv(cx) {
                Poll::Ready(Some(bytes)) => this.leftover = bytes,
                Poll::Ready(None) if this.reset.load(Ordering::Acquire) => {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::ConnectionReset,
                        "the tunnel peer of this connection was removed",
                    )));
                }
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Pending => return Poll::Pending,
            }
        }
        let count = this.leftover.len().min(buf.remaining());
        buf.put_slice(&this.leftover.split_to(count));
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for WgStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = &mut *self;
        if this.shutdown_sent {
            return Poll::Ready(Err(broken_pipe()));
        }
        match this.outbound.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let count = data.len().min(MAX_WRITE_CHUNK_BYTES);
                this.outbound
                    .send_item(Outbound::Data(Bytes::copy_from_slice(&data[..count])))
                    .map_err(|_| broken_pipe())?;
                this.wake.notify_one();
                Poll::Ready(Ok(count))
            }
            Poll::Ready(Err(_)) => Poll::Ready(Err(broken_pipe())),
            Poll::Pending => Poll::Pending,
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Writes are handed to the driver synchronously; there is no local
        // buffer left to flush. Delivery is TCP's job.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = &mut *self;
        if this.shutdown_sent {
            return Poll::Ready(Ok(()));
        }
        match this.outbound.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let _ = this.outbound.send_item(Outbound::Shutdown);
                this.shutdown_sent = true;
                this.wake.notify_one();
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(_)) => {
                this.shutdown_sent = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}
