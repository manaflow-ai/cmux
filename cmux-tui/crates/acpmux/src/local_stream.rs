//! The daemon socket's stream, one type per platform, so the client, the
//! `acpmux stdio` relay and the server's connection code are the same on
//! every platform.
//!
//! Unix: a tokio unix stream (unchanged). Windows: `cmux::local_socket` (AF_UNIX
//! with its same-user checks: a client refuses a socket file another user
//! owns, the daemon refuses a peer of another user or a sandboxed one). That
//! API blocks, so each connection is bridged into tokio: two threads copy
//! between the socket and two in-memory pipes, one per direction, so each
//! half closes on its own as a unix stream's owned halves do.

use std::io;
use std::path::Path;

#[cfg(unix)]
pub type Stream = tokio::net::UnixStream;
#[cfg(unix)]
pub type ReadHalf = tokio::net::unix::OwnedReadHalf;
#[cfg(unix)]
pub type WriteHalf = tokio::net::unix::OwnedWriteHalf;

/// A bridged connection: what this process reads, and what it writes.
#[cfg(windows)]
pub struct Stream {
    read: ReadHalf,
    write: WriteHalf,
}
/// The inbound pipe; dropping it ends the bridge's socket reads.
#[cfg(windows)]
pub type ReadHalf = tokio::io::DuplexStream;
/// The outbound pipe; dropping it half-closes the socket (end of file for
/// the peer), as dropping a unix stream's owned write half does.
#[cfg(windows)]
pub type WriteHalf = tokio::io::DuplexStream;

/// Connects to the daemon socket at `path`.
#[cfg(unix)]
pub async fn connect(path: &Path) -> io::Result<Stream> {
    tokio::net::UnixStream::connect(path).await
}

/// Connects to the daemon socket at `path`; refuses a socket file whose
/// owner is not our user.
#[cfg(windows)]
pub async fn connect(path: &Path) -> io::Result<Stream> {
    let path = path.to_owned();
    let stream = tokio::task::spawn_blocking(move || cmux::local_socket::connect_same_user(&path))
        .await
        .map_err(io::Error::other)??;
    bridge(stream)
}

/// The read and write halves of a connected stream.
#[cfg(unix)]
pub fn split(stream: Stream) -> (ReadHalf, WriteHalf) {
    stream.into_split()
}

/// The read and write halves of a connected stream.
#[cfg(windows)]
pub fn split(stream: Stream) -> (ReadHalf, WriteHalf) {
    (stream.read, stream.write)
}

/// Bytes the bridge copies at a time, and the duplex buffer per direction.
#[cfg(windows)]
const BRIDGE_BUFFER: usize = 64 * 1024;

/// Bridges a connected blocking socket into tokio: the read half reads end
/// of file when the peer stops sending; dropping the write half ends this
/// side's sending (a write shutdown, so the peer reads end of file).
#[cfg(windows)]
pub(crate) fn bridge(socket: cmux::local_socket::Stream) -> io::Result<Stream> {
    use std::io::{Read, Write};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (read, mut inbound) = tokio::io::duplex(BRIDGE_BUFFER);
    let (write, mut outbound) = tokio::io::duplex(BRIDGE_BUFFER);
    let mut reader = socket.try_clone()?;
    let mut writer = socket;
    let runtime = tokio::runtime::Handle::current();
    let reads = runtime.clone();
    std::thread::Builder::new().name("acpmux-socket-read".into()).spawn(move || {
        let mut buf = vec![0u8; BRIDGE_BUFFER];
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            // Fails once this process dropped its read half.
            if reads.block_on(inbound.write_all(&buf[..n])).is_err() {
                break;
            }
        }
        // Dropping `inbound`: the read half reads end of file.
    })?;
    std::thread::Builder::new().name("acpmux-socket-write".into()).spawn(move || {
        let mut buf = vec![0u8; BRIDGE_BUFFER];
        loop {
            // End of file once this process dropped its write half.
            let n = match runtime.block_on(outbound.read(&mut buf)) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if writer.write_all(&buf[..n]).is_err() {
                break;
            }
        }
        let _ = writer.shutdown(std::net::Shutdown::Write);
    })?;
    Ok(Stream { read, write })
}
