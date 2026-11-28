//! The dial's `carrier.first_byte` line: the time from the dial's start to the first byte the
//! machine sent back through the bridge, the Mac's end-to-end connect (RFD 0223 row 2: start, dial
//! and the first answer). A paused machine's resume is inside it: the relay holds the lane until
//! the machine runs ([`super::contract::phases_line`]'s `parked_ms`).
//!
//! `carrier.first_byte machine=<vm_id> service=<mux|desktop|acpmux> ms=<since the dial's start>`,
//! appended once per dial to the connect log ([`super::route_log`]), never to stderr, so the
//! reply line contract does not change. [`super::connect_stats`] reads it back.

use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use tokio::io::AsyncWrite;

/// The first-byte line.
pub(super) fn line(machine: &str, service: &str, elapsed: Duration) -> String {
    format!("carrier.first_byte machine={machine} service={service} ms={}\n", elapsed.as_millis())
}

/// `inner`, calling `on_first(since)` once, when the first non-empty write to it succeeds.
pub(super) struct FirstByte<W, F> {
    inner: W,
    since: Instant,
    on_first: Option<F>,
}

impl<W, F: FnOnce(Duration)> FirstByte<W, F> {
    pub(super) fn new(inner: W, since: Instant, on_first: F) -> Self {
        Self { inner, since, on_first: Some(on_first) }
    }
}

impl<W: AsyncWrite + Unpin, F: FnOnce(Duration) + Unpin> AsyncWrite for FirstByte<W, F> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();
        let polled = Pin::new(&mut this.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = &polled
            && *n > 0
            && let Some(on_first) = this.on_first.take()
        {
            on_first(this.since.elapsed());
        }
        polled
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
impl<W, F> FirstByte<W, F> {
    pub(super) fn into_inner(self) -> W {
        self.inner
    }
}
