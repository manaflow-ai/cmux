//! The daemon socket's stream, one type per platform, so the client, the
//! `acpmux stdio` relay and the server's connection code are the same on
//! every platform.
//!
//! Unix: a tokio unix stream (unchanged). Windows: `cmux::local_socket` (AF_UNIX
//! with its same-user checks: a client refuses a socket file another user
//! owns, the daemon refuses a peer of another user or a sandboxed one). That
//! API blocks, so each connection is bridged into tokio: two threads copy
//! between the socket and an in-memory duplex stream.

use std::io;
use std::path::Path;

#[cfg(unix)]
pub type Stream = tokio::net::UnixStream;
#[cfg(unix)]
pub type ReadHalf = tokio::net::unix::OwnedReadHalf;
#[cfg(unix)]
pub type WriteHalf = tokio::net::unix::OwnedWriteHalf;

#[cfg(windows)]
pub type Stream = tokio::io::DuplexStream;
#[cfg(windows)]
pub type ReadHalf = tokio::io::ReadHalf<Stream>;
#[cfg(windows)]
pub type WriteHalf = tokio::io::WriteHalf<Stream>;

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
    tokio::io::split(stream)
}

/// Bytes the bridge copies at a time, and the duplex buffer per direction.
#[cfg(windows)]
const BRIDGE_BUFFER: usize = 64 * 1024;

/// Bridges a connected blocking socket into tokio. The returned stream ends
/// (reads end of file) when the peer closes; dropping it closes the socket.
#[cfg(windows)]
pub(crate) fn bridge(socket: cmux::local_socket::Stream) -> io::Result<Stream> {
    use std::io::{Read, Write};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (ours, theirs) = tokio::io::duplex(BRIDGE_BUFFER);
    let (mut from_us, mut to_us) = tokio::io::split(theirs);
    let mut reader = socket.try_clone()?;
    let mut writer = socket;
    let runtime = tokio::runtime::Handle::current();
    let inbound = runtime.clone();
    std::thread::Builder::new().name("acpmux-socket-read".into()).spawn(move || {
        let mut buf = vec![0u8; BRIDGE_BUFFER];
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if inbound.block_on(to_us.write_all(&buf[..n])).is_err() {
                break;
            }
        }
        // The peer is done sending: our side reads end of file.
        let _ = inbound.block_on(to_us.shutdown());
    })?;
    std::thread::Builder::new().name("acpmux-socket-write".into()).spawn(move || {
        let mut buf = vec![0u8; BRIDGE_BUFFER];
        loop {
            let n = match runtime.block_on(from_us.read(&mut buf)) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if writer.write_all(&buf[..n]).is_err() {
                break;
            }
        }
        // Our side closed (or the peer stopped reading): close both ways, so
        // the read thread's blocking read ends too.
        let _ = writer.shutdown(std::net::Shutdown::Both);
    })?;
    Ok(ours)
}
