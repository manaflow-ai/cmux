use std::fmt;

use async_trait::async_trait;
use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

use crate::link::{FrameLink, LinkError};

const LENGTH_BYTES: usize = 4;
/// Reads are buffered so frames already on the stream (a burst of echoes or
/// acks) cost one read, not two each (the length, then the payload). A
/// payload larger than this is read straight into its frame.
const READ_BUFFER_BYTES: usize = 64 * 1024;

/// A binary-message link over any byte stream, used by Unix sockets, SSH
/// stdio, and direct TCP/TLS adapters. The 32-bit length is checked before a
/// payload allocation.
pub struct LengthDelimitedLink<R, W> {
    description: String,
    maximum: usize,
    reader: Mutex<BufReader<R>>,
    writer: Mutex<Option<W>>,
}

impl<R: AsyncRead, W> LengthDelimitedLink<R, W> {
    pub fn new(description: impl Into<String>, maximum: usize, reader: R, writer: W) -> Self {
        Self {
            description: description.into(),
            maximum,
            reader: Mutex::new(BufReader::with_capacity(READ_BUFFER_BYTES, reader)),
            writer: Mutex::new(Some(writer)),
        }
    }
}

impl<R, W> fmt::Debug for LengthDelimitedLink<R, W> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LengthDelimitedLink")
            .field("description", &self.description)
            .field("maximum", &self.maximum)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl<R, W> FrameLink for LengthDelimitedLink<R, W>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if frame.len() > self.maximum {
            return Err(LinkError::FrameTooLarge { actual: frame.len(), maximum: self.maximum });
        }
        let length = u32::try_from(frame.len()).map_err(|_| LinkError::FrameTooLarge {
            actual: frame.len(),
            maximum: u32::MAX as usize,
        })?;
        // The length and the payload in one write: written apart, a no-delay
        // TCP socket or a QUIC stream sends the 4-byte length as a segment or
        // packet of its own ahead of every frame (every keystroke and echo).
        let mut wire = Vec::with_capacity(LENGTH_BYTES + frame.len());
        wire.extend_from_slice(&length.to_be_bytes());
        wire.extend_from_slice(&frame);
        let mut writer = self.writer.lock().await;
        let writer = writer.as_mut().ok_or(LinkError::Closed)?;
        writer.write_all(&wire).await.map_err(map_io)?;
        writer.flush().await.map_err(map_io)
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let mut reader = self.reader.lock().await;
        let mut length = [0_u8; LENGTH_BYTES];
        match reader.read_exact(&mut length).await {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(error) => return Err(map_io(error)),
        }
        let length = u32::from_be_bytes(length) as usize;
        if length > self.maximum {
            return Err(LinkError::FrameTooLarge { actual: length, maximum: self.maximum });
        }
        let mut frame = vec![0_u8; length];
        reader.read_exact(&mut frame).await.map_err(map_io)?;
        Ok(Some(Bytes::from(frame)))
    }

    async fn close(&self) -> Result<(), LinkError> {
        let writer = self.writer.lock().await.take();
        match writer {
            Some(mut writer) => writer.shutdown().await.map_err(map_io),
            None => Ok(()),
        }
    }
}

fn map_io(error: std::io::Error) -> LinkError {
    if matches!(
        error.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::UnexpectedEof
    ) {
        LinkError::Closed
    } else {
        LinkError::Transport(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::pin::Pin;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::{Context, Poll};

    use super::*;

    /// A writer that counts the writes it gets, each one a separate send
    /// (a segment on a no-delay TCP socket, a packet on a QUIC stream).
    struct CountingWriter {
        writes: Arc<AtomicUsize>,
        bytes: Vec<u8>,
    }

    impl AsyncWrite for CountingWriter {
        fn poll_write(
            mut self: Pin<&mut Self>,
            _: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            self.writes.fetch_add(1, Ordering::Relaxed);
            self.bytes.extend_from_slice(buf);
            Poll::Ready(Ok(buf.len()))
        }

        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    /// A reader over bytes already there that counts the reads it serves.
    struct CountingReader {
        reads: Arc<AtomicUsize>,
        data: io::Cursor<Vec<u8>>,
    }

    impl AsyncRead for CountingReader {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            Pin::new(&mut self.data).poll_read(cx, buf)
        }
    }

    fn framed(frames: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for frame in frames {
            out.extend_from_slice(&(frame.len() as u32).to_be_bytes());
            out.extend_from_slice(frame);
        }
        out
    }

    /// A keystroke's frame goes out in one write: its length and payload as
    /// two writes put a 4-byte segment or packet on the wire ahead of every
    /// frame of the phone's link.
    #[tokio::test]
    async fn a_frame_is_one_write() {
        let writes = Arc::new(AtomicUsize::new(0));
        let writer = CountingWriter { writes: writes.clone(), bytes: Vec::new() };
        let reader = io::Cursor::new(Vec::new());
        let link = LengthDelimitedLink::new("test", 1 << 20, reader, writer);
        for key in [b"a".as_slice(), b"bc", b"\r"] {
            link.send(Bytes::copy_from_slice(key)).await.unwrap();
        }
        assert_eq!(writes.load(Ordering::Relaxed), 3, "one write per frame");
        let guard = link.writer.lock().await;
        let written = &guard.as_ref().unwrap().bytes;
        assert_eq!(written, &framed(&[b"a", b"bc", b"\r"]));
    }

    /// A burst of small frames already on the stream (echoes, acks) costs
    /// one read, not a read for each length and each payload.
    #[tokio::test]
    async fn queued_small_frames_are_read_in_one_read() {
        let payloads: Vec<Vec<u8>> = (0..32u8).map(|n| vec![n; 3]).collect();
        let refs: Vec<&[u8]> = payloads.iter().map(Vec::as_slice).collect();
        let reads = Arc::new(AtomicUsize::new(0));
        let reader = CountingReader { reads: reads.clone(), data: io::Cursor::new(framed(&refs)) };
        let link = LengthDelimitedLink::new("test", 1 << 20, reader, tokio::io::sink());
        for payload in &payloads {
            let frame = link.receive().await.unwrap().unwrap();
            assert_eq!(frame.as_ref(), payload.as_slice());
        }
        assert!(
            reads.load(Ordering::Relaxed) <= 2,
            "{} reads for {} queued frames",
            reads.load(Ordering::Relaxed),
            payloads.len()
        );
        assert!(link.receive().await.unwrap().is_none());
    }

    /// A frame larger than the read buffer still arrives whole.
    #[tokio::test]
    async fn a_large_frame_arrives_whole() {
        let big = vec![7u8; 3 * 64 * 1024 + 5];
        let reads = Arc::new(AtomicUsize::new(0));
        let reader = CountingReader { reads, data: io::Cursor::new(framed(&[&big, b"x"])) };
        let link = LengthDelimitedLink::new("test", 1 << 20, reader, tokio::io::sink());
        assert_eq!(link.receive().await.unwrap().unwrap().as_ref(), big.as_slice());
        assert_eq!(link.receive().await.unwrap().unwrap().as_ref(), b"x");
    }
}
