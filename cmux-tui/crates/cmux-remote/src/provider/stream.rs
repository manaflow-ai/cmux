use std::fmt;

use async_trait::async_trait;
use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex;

use crate::link::{FrameLink, LinkError};

const LENGTH_BYTES: usize = 4;

/// A binary-message link over any byte stream, used by Unix sockets, SSH
/// stdio, and direct TCP/TLS adapters. The 32-bit length is checked before a
/// payload allocation.
pub struct LengthDelimitedLink<R, W> {
    description: String,
    maximum: usize,
    reader: Mutex<R>,
    writer: Mutex<W>,
}

impl<R, W> LengthDelimitedLink<R, W> {
    pub fn new(description: impl Into<String>, maximum: usize, reader: R, writer: W) -> Self {
        Self {
            description: description.into(),
            maximum,
            reader: Mutex::new(reader),
            writer: Mutex::new(writer),
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
        let mut writer = self.writer.lock().await;
        writer.write_all(&length.to_be_bytes()).await.map_err(map_io)?;
        writer.write_all(&frame).await.map_err(map_io)?;
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
        self.writer.lock().await.shutdown().await.map_err(map_io)
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
    use super::*;

    #[tokio::test]
    async fn duplex_round_trip_and_eof() {
        let (left, right) = tokio::io::duplex(256);
        let (left_read, left_write) = tokio::io::split(left);
        let (right_read, right_write) = tokio::io::split(right);
        let left = LengthDelimitedLink::new("left", 32, left_read, left_write);
        let right = LengthDelimitedLink::new("right", 32, right_read, right_write);

        left.send(Bytes::from_static(b"input")).await.unwrap();
        assert_eq!(right.receive().await.unwrap().unwrap(), &b"input"[..]);
        left.close().await.unwrap();
        assert!(right.receive().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn rejects_length_before_allocating_payload() {
        let (mut left, right) = tokio::io::duplex(32);
        let (right_read, right_write) = tokio::io::split(right);
        let link = LengthDelimitedLink::new("right", 8, right_read, right_write);
        left.write_all(&9_u32.to_be_bytes()).await.unwrap();
        assert!(matches!(
            link.receive().await,
            Err(LinkError::FrameTooLarge { actual: 9, maximum: 8 })
        ));
    }
}
