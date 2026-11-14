//! The `cmux link` overlay dial: a stream to a service of a paired host
//! through this machine's link (plans/cmux-next/transport.md 12a).
//!
//! The caller connects to the link's local socket, sends one `link.dial`
//! line and reads one reply line; on success the same connection carries
//! the service's bytes. Slice 1 reaches the session daemon's remote entry
//! (JSON lines) on direct paths only. A Noise `TransportProvider` over this
//! carrier is the later step (transport.md 14), when a remote service
//! speaks Noise.

use std::io;
use std::path::Path;

use cmux_link::dial::{
    DialError, DialOp, DialReply, DialRequest, MAX_LINE_BYTES, PathState, Service, line, parse_line,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

/// Why an overlay dial failed.
#[derive(Debug)]
pub enum OverlayDialError {
    /// The link's socket did not accept the connection (no running link).
    LinkUnavailable(io::Error),
    /// The link answered with a failure.
    Refused {
        error: Option<DialError>,
        path_state: PathState,
        relay_available: bool,
        /// The link's `error_detail`: what failed.
        detail: Option<String>,
    },
    /// The link closed the connection or answered something that is not a reply.
    Protocol,
}

impl std::fmt::Display for OverlayDialError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LinkUnavailable(error) => write!(formatter, "cmux link is not running: {error}"),
            Self::Refused { error, path_state, detail: None, .. } => {
                write!(formatter, "cmux link refused the dial: {error:?} ({path_state:?})")
            }
            Self::Refused { error, path_state, detail: Some(detail), .. } => {
                write!(
                    formatter,
                    "cmux link refused the dial: {error:?} ({path_state:?}): {detail}"
                )
            }
            Self::Protocol => formatter.write_str("cmux link sent an invalid reply"),
        }
    }
}

impl std::error::Error for OverlayDialError {}

/// A connected stream and how it reaches the peer.
#[derive(Debug)]
pub struct OverlayStream {
    pub stream: UnixStream,
    pub path_state: PathState,
    pub relay_available: bool,
}

/// Dial `service` on paired host `host` through the link at `link_socket`.
pub async fn dial_link(
    link_socket: &Path,
    host: &str,
    service: Service,
) -> Result<OverlayStream, OverlayDialError> {
    let mut stream =
        UnixStream::connect(link_socket).await.map_err(OverlayDialError::LinkUnavailable)?;
    // The listener must be this user's cmux link, not a socket squatter.
    let fd = std::os::fd::AsRawFd::as_raw_fd(&stream);
    match tokio::task::spawn_blocking(move || cmux_link::caller::verify_fd(fd)).await {
        Ok(Ok(())) => {}
        Ok(Err(refused)) => return Err(OverlayDialError::LinkUnavailable(refused.into())),
        Err(_) => return Err(OverlayDialError::Protocol),
    }
    let request = DialRequest { op: DialOp::Dial, host: host.to_string(), service };
    stream.write_all(line(&request).as_bytes()).await.map_err(|_| OverlayDialError::Protocol)?;
    let reply = read_reply(&mut stream).await?;
    if !reply.ok {
        return Err(OverlayDialError::Refused {
            error: reply.error_code,
            path_state: reply.path_state,
            relay_available: reply.relay_available,
            detail: reply.error_detail,
        });
    }
    Ok(OverlayStream {
        stream,
        path_state: reply.path_state,
        relay_available: reply.relay_available,
    })
}

/// Read the reply one byte at a time, so the stream's first bytes stay unread.
async fn read_reply(stream: &mut UnixStream) -> Result<DialReply, OverlayDialError> {
    let mut bytes = Vec::with_capacity(128);
    loop {
        let byte = stream.read_u8().await.map_err(|_| OverlayDialError::Protocol)?;
        if byte == b'\n' {
            break;
        }
        if bytes.len() >= MAX_LINE_BYTES {
            return Err(OverlayDialError::Protocol);
        }
        bytes.push(byte);
    }
    let text = String::from_utf8(bytes).map_err(|_| OverlayDialError::Protocol)?;
    parse_line::<DialReply>(&text).ok_or(OverlayDialError::Protocol)
}

#[cfg(test)]
mod tests;
