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

/// Run the socket server. This should be called from a tokio runtime
/// on a background thread.
pub async fn run_socket_server(state: Arc<SharedState>) -> anyhow::Result<()> {
    // Remove stale socket file
    let _ = std::fs::remove_file(SOCKET_PATH);

    let listener = UnixListener::bind(SOCKET_PATH)?;
    tracing::info!("Socket server listening on {}", SOCKET_PATH);

    // Set socket permissions (readable/writable by owner only)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(SOCKET_PATH, std::fs::Permissions::from_mode(0o700))?;
    }

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                // Authenticate the client
                match auth::authenticate_peer(&stream) {
                    Ok(peer_info) => {
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
    let mut line = String::new();

    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line).await?;
        if bytes_read == 0 {
            break; // Client disconnected
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Parse and dispatch the v2 request
        let response = v2::dispatch(trimmed, &state);
        let response_json = serde_json::to_string(&response)?;

        writer.write_all(response_json.as_bytes()).await?;
        writer.write_all(b"\n").await?;
        writer.flush().await?;
    }

    Ok(())
}

/// Clean up the socket file on shutdown.
pub fn cleanup() {
    let _ = std::fs::remove_file(SOCKET_PATH);
}
