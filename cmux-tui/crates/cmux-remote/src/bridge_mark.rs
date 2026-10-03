//! The remote bridge mark (plans/cmux-next/identity.md section 3).
//!
//! A peer's mux control stream reaches the session through its Unix socket,
//! where the transport alone says "local". Before any peer byte, the bridge
//! writes the session's mark line and reads the reply, so the session never
//! takes the peer for a local principal (a launch credential or the
//! frontend). Every peer mux connection goes through
//! [`connect_mux_socket_for_peer`].
#![cfg(unix)]

use cmux_tui_core::server::connection_origin::{
    RemoteBridgeMarkReply, remote_bridge_mark_line, remote_bridge_mark_reply,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::services::ServicesError;

/// The longest reply to the mark this bridge reads.
const MARK_REPLY_LIMIT: usize = 4096;
const MARK_REPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Connect to a local mux or terminal-host socket. Both run as this daemon's
/// user, so refuse any other listener before a request or token is written.
pub(crate) async fn connect_owned_unix_socket(
    path: impl AsRef<std::path::Path>,
) -> Result<UnixStream, ServicesError> {
    let stream = UnixStream::connect(path).await?;
    crate::admin::verify_unix_peer_owner(&stream)
        .map_err(|error| ServicesError::Unavailable(error.to_string()))?;
    Ok(stream)
}

/// Connect to the session socket for a peer's mux control stream and mark
/// the connection as a remote bridge before any peer byte.
pub(crate) async fn connect_mux_socket_for_peer(
    path: impl AsRef<std::path::Path>,
) -> Result<UnixStream, ServicesError> {
    let mut socket = connect_owned_unix_socket(path).await?;
    socket.write_all(&remote_bridge_mark_line()).await?;
    socket.flush().await?;
    let reply = tokio::time::timeout(MARK_REPLY_TIMEOUT, read_one_line(&mut socket))
        .await
        .map_err(|_| ServicesError::Unavailable("no reply to the remote bridge mark".into()))??;
    match remote_bridge_mark_reply(&reply) {
        // A daemon from before the mark has no launch credentials or
        // frontend to protect.
        RemoteBridgeMarkReply::Accepted | RemoteBridgeMarkReply::UnknownToDaemon => Ok(socket),
        RemoteBridgeMarkReply::Refused => {
            Err(ServicesError::Unavailable("the session refused the remote bridge mark".into()))
        }
    }
}

/// Read one LF-terminated line byte by byte, so nothing after it is taken
/// from the socket the pump reads next.
async fn read_one_line(socket: &mut UnixStream) -> Result<String, ServicesError> {
    let mut line = Vec::new();
    loop {
        let byte = socket.read_u8().await?;
        if byte == b'\n' {
            break;
        }
        if line.len() == MARK_REPLY_LIMIT {
            return Err(ServicesError::MessageTooLarge(line.len()));
        }
        line.push(byte);
    }
    String::from_utf8(line)
        .map_err(|_| ServicesError::Unavailable("remote bridge mark reply is not UTF-8".into()))
}

/// A fake session's side of the mark, for tests: read the mark, check it,
/// and accept it.
#[cfg(test)]
pub(crate) async fn answer_mark_for_test(mut socket: UnixStream) -> UnixStream {
    let mark = read_one_line(&mut socket).await.unwrap();
    assert_eq!(format!("{mark}\n").into_bytes(), remote_bridge_mark_line());
    socket
        .write_all(b"{\"id\":0,\"ok\":true,\"data\":{\"origin\":\"remote_bridge\"}}\n")
        .await
        .unwrap();
    socket
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    use super::*;

    /// Run the bridge against a fake session that sends `reply` and then
    /// one more line at once. Returns the bridge's result and its first line.
    async fn run(reply: &'static [u8]) -> (Result<UnixStream, ServicesError>, String) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let core = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = tokio::io::BufReader::new(socket);
            let mut first = String::new();
            socket.read_line(&mut first).await.unwrap();
            socket.get_mut().write_all(reply).await.unwrap();
            socket.get_mut().write_all(b"after\n").await.unwrap();
            // Keep the socket open until the bridge has read.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            first
        });
        let connected = connect_mux_socket_for_peer(&path).await;
        (connected, core.await.unwrap())
    }

    #[tokio::test]
    async fn the_peer_mux_connection_is_marked_before_any_peer_byte() {
        let (connected, first) =
            run(b"{\"id\":0,\"ok\":true,\"data\":{\"origin\":\"remote_bridge\"}}\n").await;
        assert_eq!(first.into_bytes(), remote_bridge_mark_line());
        // The bridge took the reply and nothing after it.
        let mut socket = tokio::io::BufReader::new(connected.unwrap());
        let mut next = String::new();
        socket.read_line(&mut next).await.unwrap();
        assert_eq!(next, "after\n");

        let (connected, _) =
            run(b"{\"id\":0,\"ok\":false,\"error\":\"bad request: unknown variant `connection-origin`\"}\n")
                .await;
        assert!(connected.is_ok(), "a daemon from before the mark still serves the peer");

        // Any other reply (a new session always accepts the mark, even while
        // a handoff is pending) closes the peer's connection.
        let (connected, _) = run(b"{\"id\":0,\"ok\":false,\"error\":\"refused\"}\n").await;
        assert!(connected.is_err(), "a refused mark closes the peer's connection");
        let (connected, _) = run(b"not json\n").await;
        assert!(connected.is_err());
    }
}
