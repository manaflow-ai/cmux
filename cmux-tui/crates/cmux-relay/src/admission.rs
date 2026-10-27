use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use axum::serve::Listener;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Instant, Sleep};

use crate::config::RelayConfig;

const ACCEPT_RETRY_INITIAL: Duration = Duration::from_millis(50);
const ACCEPT_RETRY_MAX: Duration = Duration::from_secs(1);

/// Applies resource and time bounds before a connection reaches HTTP parsing.
pub struct AdmissionListener {
    inner: TcpListener,
    permits: std::sync::Arc<Semaphore>,
    header_timeout: Duration,
    keepalive_timeout: Duration,
    maximum_header_bytes: usize,
}

impl AdmissionListener {
    pub(crate) fn new(inner: TcpListener, config: &RelayConfig) -> Self {
        Self {
            inner,
            permits: std::sync::Arc::new(Semaphore::new(config.max_http_connections)),
            header_timeout: config.http_header_timeout,
            keepalive_timeout: config.http_keepalive_timeout,
            maximum_header_bytes: config.max_http_header_bytes,
        }
    }
}

impl Listener for AdmissionListener {
    type Io = AdmissionStream;
    type Addr = std::net::SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        let mut retry_attempt = 0u32;
        loop {
            // The semaphore is private and nothing closes it, so acquire
            // fails only if that changes; then this listener admits no one.
            let Ok(permit) = self.permits.clone().acquire_owned().await else {
                eprintln!("cmux-relay: admission semaphore closed; accepting no connections");
                return std::future::pending().await;
            };
            match self.inner.accept().await {
                Ok((stream, address)) => {
                    let _ = stream.set_nodelay(true);
                    return (
                        AdmissionStream::new(
                            stream,
                            permit,
                            self.header_timeout,
                            self.keepalive_timeout,
                            self.maximum_header_bytes,
                        ),
                        address,
                    );
                }
                Err(_) => {
                    // Back off every listener failure, including per-connection aborts. A
                    // peer can cause those errors repeatedly, so an immediate retry would
                    // let it turn the accept task into a CPU spin. The sleep future is
                    // cancellation-safe: dropping the listener drops this future.
                    tokio::time::sleep(accept_retry_delay(retry_attempt)).await;
                    retry_attempt = retry_attempt.saturating_add(1);
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.inner.local_addr()
    }
}

fn accept_retry_delay(attempt: u32) -> Duration {
    let shift = attempt.min(6);
    let multiplier = 1u32 << shift;
    ACCEPT_RETRY_INITIAL.checked_mul(multiplier).unwrap_or(ACCEPT_RETRY_MAX).min(ACCEPT_RETRY_MAX)
}

/// A connection under the listener's bounds; `S` is the socket (a TCP stream
/// in the relay, any stream in tests).
pub struct AdmissionStream<S = TcpStream> {
    inner: S,
    _permit: OwnedSemaphorePermit,
    deadline: Pin<Box<Sleep>>,
    idle_deadline: Option<Instant>,
    keepalive_timeout: Duration,
    maximum_header_bytes: usize,
    header_bytes: usize,
    delimiter_bytes: u8,
    header_complete: bool,
}

impl<S> AdmissionStream<S> {
    fn new(
        inner: S,
        permit: OwnedSemaphorePermit,
        header_timeout: Duration,
        keepalive_timeout: Duration,
        maximum_header_bytes: usize,
    ) -> Self {
        Self {
            inner,
            _permit: permit,
            deadline: Box::pin(tokio::time::sleep(header_timeout)),
            idle_deadline: None,
            keepalive_timeout,
            maximum_header_bytes,
            header_bytes: 0,
            delimiter_bytes: 0,
            header_complete: false,
        }
    }

    fn observe_read(&mut self, bytes: &[u8]) -> io::Result<()> {
        if self.header_complete || bytes.is_empty() {
            if !bytes.is_empty() {
                self.record_activity();
            }
            return Ok(());
        }
        for &byte in bytes {
            self.header_bytes = self.header_bytes.checked_add(1).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "HTTP header byte count overflowed")
            })?;
            if self.header_bytes > self.maximum_header_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "HTTP headers exceeded the relay byte limit",
                ));
            }
            self.delimiter_bytes = match (self.delimiter_bytes, byte) {
                (0, b'\r') => 1,
                (1, b'\n') => 2,
                (1, b'\r') => 1,
                (2, b'\r') => 3,
                (3, b'\n') => 4,
                (_, b'\r') => 1,
                _ => 0,
            };
            if self.delimiter_bytes == 4 {
                self.header_complete = true;
                self.record_activity();
                break;
            }
        }
        Ok(())
    }

    fn record_activity(&mut self) {
        let idle_deadline = Instant::now() + self.keepalive_timeout;
        self.idle_deadline = Some(idle_deadline);
        self.deadline.as_mut().reset(idle_deadline);
    }

    fn poll_deadline(&mut self, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.deadline.as_mut().poll(context) {
            Poll::Ready(()) => {
                if let Some(idle_deadline) = self.idle_deadline
                    && Instant::now() < idle_deadline
                {
                    self.deadline.as_mut().reset(idle_deadline);
                    let _ = self.deadline.as_mut().poll(context);
                    return Poll::Pending;
                }
                Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    if self.header_complete {
                        "relay connection exceeded its keepalive deadline"
                    } else {
                        "relay HTTP headers were not completed before the deadline"
                    },
                )))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for AdmissionStream<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let previous_length = buffer.filled().len();
        match Pin::new(&mut self.inner).poll_read(context, buffer) {
            Poll::Ready(Ok(())) => {
                let Some(bytes) = buffer.filled().get(previous_length..) else {
                    return Poll::Ready(Err(io::Error::other(
                        "the inner stream shrank the read buffer",
                    )));
                };
                Poll::Ready(self.observe_read(bytes))
            }
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => self.poll_deadline(context),
        }
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for AdmissionStream<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        match Pin::new(&mut self.inner).poll_write(context, buffer) {
            Poll::Ready(Ok(written)) => {
                if written != 0 && self.header_complete {
                    self.record_activity();
                }
                Poll::Ready(Ok(written))
            }
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => match self.poll_deadline(context) {
                Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
                Poll::Ready(Ok(())) | Poll::Pending => Poll::Pending,
            },
        }
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        match Pin::new(&mut self.inner).poll_flush(context) {
            Poll::Pending => self.poll_deadline(context),
            ready => ready,
        }
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.inner).poll_shutdown(context)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn raw_connection_admission_is_bounded() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let listener = TcpListener::from_std(listener).unwrap();
        let config = RelayConfig { allow_open: true, ..RelayConfig::default() };
        let admission = AdmissionListener::new(listener, &config);
        assert_eq!(admission.permits.available_permits(), config.max_http_connections);
    }

    /// A socket that reports success but takes back what the buffer held.
    struct RewindsTheBuffer;

    impl AsyncRead for RewindsTheBuffer {
        fn poll_read(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            buffer.set_filled(0);
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn a_socket_that_shrinks_the_read_buffer_is_a_read_error() {
        let permit = std::sync::Arc::new(Semaphore::new(1)).acquire_owned().await.unwrap();
        let timeout = Duration::from_secs(5);
        let mut stream = AdmissionStream::new(RewindsTheBuffer, permit, timeout, timeout, 1024);
        let mut storage = [0u8; 16];
        let mut buffer = ReadBuf::new(&mut storage);
        buffer.put_slice(b"GET ");
        // At the base, slicing `filled()[4..]` of an empty buffer panicked here.
        let result =
            std::future::poll_fn(|context| Pin::new(&mut stream).poll_read(context, &mut buffer))
                .await;
        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert_eq!(error.to_string(), "the inner stream shrank the read buffer");
    }
}
