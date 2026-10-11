//! Bounded line reads for the link's handshakes: one JSON line, read byte by
//! byte so no byte after it is consumed, under a deadline.

use std::io;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt};

/// How long a peer or caller has to send its first line.
pub(super) const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// Read one line of at most `limit` bytes (without the newline).
pub(super) async fn read_line<R: AsyncRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> io::Result<String> {
    let read = async {
        let mut line = Vec::with_capacity(128);
        loop {
            let byte = reader.read_u8().await?;
            if byte == b'\n' {
                break;
            }
            if line.len() >= limit {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "line too long"));
            }
            line.push(byte);
        }
        String::from_utf8(line).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "not UTF-8"))
    };
    tokio::time::timeout(HANDSHAKE_TIMEOUT, read)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "no line before the deadline"))?
}
