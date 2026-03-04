//! Unix socket server for the cmux control API.
//!
//! Listens on `/tmp/cmux.sock` and handles line-delimited JSON v2 protocol.
//! Each client connection is handled in a separate tokio task.

use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

use crate::app::SharedState;
use crate::socket::auth;
use crate::socket::v2;

const SOCKET_PATH: &str = "/tmp/cmux.sock";
/// Maximum request line size (1 MB). Lines exceeding this limit cause disconnection.
const MAX_REQUEST_LEN: usize = 1024 * 1024;

/// Run the socket server. This should be called from a tokio runtime
/// on a background thread.
pub async fn run_socket_server(state: Arc<SharedState>) -> anyhow::Result<()> {
    let control_mode = auth::SocketControlMode::from_env();
    tracing::info!("Socket control mode: {:?}", control_mode);

    // Remove stale socket file
    let _ = std::fs::remove_file(SOCKET_PATH);

    let listener = UnixListener::bind(SOCKET_PATH)?;
    tracing::info!("Socket server listening on {}", SOCKET_PATH);

    // Set socket permissions (readable/writable by owner only)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(SOCKET_PATH, std::fs::Permissions::from_mode(0o600))?;
    }

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                // Authenticate the client
                match auth::authenticate_peer(&stream) {
                    Ok(peer_info) => {
                        if !auth::is_authorized(&peer_info, control_mode) {
                            tracing::warn!(
                                "Client rejected: pid={}, uid={} (mode={:?})",
                                peer_info.pid,
                                peer_info.uid,
                                control_mode,
                            );
                            continue;
                        }
                        tracing::debug!(
                            "Client connected: pid={}, uid={}",
                            peer_info.pid,
                            peer_info.uid
                        );
                        let state = state.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_client(stream, state).await {
                                tracing::debug!("Client disconnected: {}", e);
                            }
                        });
                    }
                    Err(e) => {
                        tracing::warn!("Client authentication failed: {}", e);
                    }
                }
            }
            Err(e) => {
                tracing::error!("Accept error: {}", e);
            }
        }
    }
}

/// Handle a single client connection.
async fn handle_client(
    stream: tokio::net::UnixStream,
    state: Arc<SharedState>,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line_buf: Vec<u8> = Vec::with_capacity(4096);

    loop {
        line_buf.clear();

        // Bounded line read: consume from BufReader in chunks, enforcing MAX_REQUEST_LEN
        // before the full line is assembled in memory.
        let eof = loop {
            let available = reader.fill_buf().await?;
            if available.is_empty() {
                break true;
            }
            match available.iter().position(|&b| b == b'\n') {
                Some(pos) => {
                    line_buf.extend_from_slice(&available[..pos]);
                    reader.consume(pos + 1);
                    break false;
                }
                None => {
                    let len = available.len();
                    line_buf.extend_from_slice(available);
                    reader.consume(len);
                    if line_buf.len() > MAX_REQUEST_LEN {
                        tracing::warn!(
                            "Client sent oversized request ({} bytes), disconnecting",
                            line_buf.len()
                        );
                        return Ok(());
                    }
                }
            }
        };

        if eof && line_buf.is_empty() {
            break; // Client disconnected
        }

        if line_buf.len() > MAX_REQUEST_LEN {
            tracing::warn!(
                "Client sent oversized request ({} bytes), disconnecting",
                line_buf.len()
            );
            break;
        }

        let trimmed = std::str::from_utf8(&line_buf)
            .map(|s| s.trim())
            .unwrap_or("");
        if trimmed.is_empty() {
            if eof {
                break;
            }
            continue;
        }

        // Parse and dispatch the v2 request
        let response = v2::dispatch(trimmed, &state);
        let response_json = serde_json::to_string(&response)?;

        writer.write_all(response_json.as_bytes()).await?;
        writer.write_all(b"\n").await?;
        writer.flush().await?;

        if eof {
            break;
        }
    }

    Ok(())
}

/// Clean up the socket file on shutdown.
pub fn cleanup() {
    let _ = std::fs::remove_file(SOCKET_PATH);
}
