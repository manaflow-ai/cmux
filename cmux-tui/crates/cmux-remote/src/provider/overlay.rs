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
    DialError, DialOp, DialReply, DialRequest, MAX_LINE_BYTES, PathState, Service, line,
    parse_line,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

/// Why an overlay dial failed.
#[derive(Debug)]
pub enum OverlayDialError {
    /// The link's socket did not accept the connection (no running link).
    LinkUnavailable(io::Error),
    /// The link answered with a failure.
    Refused { error: Option<DialError>, path_state: PathState, relay_available: bool },
    /// The link closed the connection or answered something that is not a reply.
    Protocol,
}

impl std::fmt::Display for OverlayDialError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LinkUnavailable(error) => write!(formatter, "cmux link is not running: {error}"),
            Self::Refused { error, path_state, .. } => {
                write!(formatter, "cmux link refused the dial: {error:?} ({path_state:?})")
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
    let request = DialRequest { op: DialOp::Dial, host: host.to_string(), service };
    stream
        .write_all(line(&request).as_bytes())
        .await
        .map_err(|_| OverlayDialError::Protocol)?;
    let reply = read_reply(&mut stream).await?;
    if !reply.ok {
        return Err(OverlayDialError::Refused {
            error: reply.error_code,
            path_state: reply.path_state,
            relay_available: reply.relay_available,
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
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::UnixListener;

    async fn fake_link(reply: &'static str) -> (cmux_unix_socket::TestDir, std::path::PathBuf) {
        let directory = cmux_unix_socket::short_test_dir("ovdial");
        let path = directory.path().join("link.sock");
        let listener = UnixListener::bind(&path).unwrap();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request = lines.next_line().await.unwrap().unwrap();
            assert_eq!(request, r#"{"op":"link.dial","host":"inst_b","service":"daemon"}"#);
            write.write_all(reply.as_bytes()).await.unwrap();
            write.write_all(b"{\"ok\":true}\n").await.unwrap();
            let echoed = lines.next_line().await.unwrap().unwrap();
            write.write_all(format!("{echoed}\n").as_bytes()).await.unwrap();
        });
        (directory, path)
    }

    #[tokio::test]
    async fn a_dial_returns_the_stream_after_the_reply_with_no_byte_lost() {
        let (_directory, path) =
            fake_link("{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n").await;
        let dialed = dial_link(&path, "inst_b", Service::Daemon).await.unwrap();
        assert_eq!(dialed.path_state, PathState::Direct);
        assert!(!dialed.relay_available);
        let mut lines = BufReader::new(dialed.stream);
        let mut first = String::new();
        lines.read_line(&mut first).await.unwrap();
        assert_eq!(first, "{\"ok\":true}\n", "the first service byte stays in the stream");
        lines.get_mut().write_all(b"ping\n").await.unwrap();
        let mut echoed = String::new();
        lines.read_line(&mut echoed).await.unwrap();
        assert_eq!(echoed, "ping\n");
    }

    #[tokio::test]
    async fn a_refused_dial_reports_the_link_error_and_no_relay() {
        let directory = cmux_unix_socket::short_test_dir("ovdial");
        let path = directory.path().join("link.sock");
        let listener = UnixListener::bind(&path).unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 64];
            let _ = stream.read(&mut request).await;
            let reply = "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n";
            stream.write_all(reply.as_bytes()).await.unwrap();
        });
        match dial_link(&path, "inst_b", Service::Daemon).await {
            Err(OverlayDialError::Refused { error, path_state, relay_available }) => {
                assert_eq!(error, Some(DialError::Unreachable));
                assert_eq!(path_state, PathState::Unreachable);
                assert!(!relay_available);
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
        let missing = directory.path().join("none.sock");
        assert!(matches!(
            dial_link(&missing, "inst_b", Service::Daemon).await,
            Err(OverlayDialError::LinkUnavailable(_))
        ));
    }
}
