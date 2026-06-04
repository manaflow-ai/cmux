//! Unix socket server for the cmux control API.
//!
//! Listens on a Unix socket and handles line-delimited JSON v2 protocol.
//! Each client connection is handled in a separate tokio task.

use std::os::unix::fs::FileTypeExt;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::Semaphore;
use tokio::time::{timeout, Duration};

use crate::app::SharedState;
use crate::socket::auth;
use crate::socket::v2;

/// Maximum request line size (1 MB). Lines exceeding this limit cause disconnection.
const MAX_REQUEST_LEN: usize = 1024 * 1024;
/// Maximum concurrent client connections.
const MAX_CONNECTIONS: usize = 64;
/// Idle timeout per client connection. Clients that send no data within this
/// window are disconnected to free resources.
const CLIENT_IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// Determine the socket path. Prefers `XDG_RUNTIME_DIR` (user-private) over `/tmp`.
///
/// Validates that `XDG_RUNTIME_DIR` is owned by the current user and not
/// world-writable, per the XDG Base Directory Specification.
pub fn socket_path() -> String {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        let path = std::path::Path::new(&dir);
        if path.is_absolute() {
            if let Ok(meta) = std::fs::metadata(path) {
                use std::os::unix::fs::MetadataExt;
                let my_uid = unsafe { libc::getuid() };
                if meta.is_dir() && meta.uid() == my_uid && (meta.mode() & 0o777) == 0o700 {
                    return format!("{}/cmux.sock", dir);
                }
            }
            tracing::warn!(
                "XDG_RUNTIME_DIR ({}) failed validation, falling back to /tmp",
                dir
            );
        }
    }
    format!("/tmp/cmux-{}.sock", unsafe { libc::getuid() })
}

/// Run the socket server. This should be called from a tokio runtime
/// on a background thread.
pub async fn run_socket_server(state: Arc<SharedState>) -> anyhow::Result<()> {
    let control_mode = auth::SocketControlMode::from_env();
    let server_pid = std::process::id();
    tracing::info!("Socket control mode: {:?}", control_mode);
    if control_mode == auth::SocketControlMode::CmuxOnly {
        tracing::info!(
            "CmuxOnly mode: same-UID + descendant-PID check via /proc enabled"
        );
    }

    let path = socket_path();

    // Check if an existing socket is live before removing
    let socket_path = std::path::Path::new(&path);
    if socket_path.exists() {
        // Only remove if it's actually a Unix socket, not a regular file
        let metadata = std::fs::symlink_metadata(socket_path)?;
        if metadata.file_type().is_socket() {
            if std::os::unix::net::UnixStream::connect(&path).is_ok() {
                anyhow::bail!("Another cmux instance is already running on {}", path);
            }
            // Socket is stale — safe to remove
            let _ = std::fs::remove_file(&path);
        } else {
            anyhow::bail!(
                "Path {} exists but is not a socket — refusing to overwrite",
                path
            );
        }
    }

    // Restrict socket permissions: set umask before bind so the socket is
    // created with 0o600 from the start, then restore the original umask.
    // The umask window is brief (just the bind syscall) and the only side
    // effect on concurrent file creates is MORE restrictive permissions.
    let listener = {
        let old_umask = unsafe { libc::umask(0o177) };
        let result = UnixListener::bind(&path);
        unsafe { libc::umask(old_umask) };
        result?
    };
    tracing::info!("Socket server listening on {}", path);

    let semaphore = Arc::new(Semaphore::new(MAX_CONNECTIONS));

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                // Authenticate the client
                match auth::authenticate_peer(&stream) {
                    Ok(peer_info) => {
                        if !auth::is_authorized(&peer_info, control_mode, server_pid) {
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
                        // Acquire permit before spawning to bound both tasks and connections
                        let permit = match semaphore.clone().acquire_owned().await {
                            Ok(permit) => permit,
                            Err(_) => continue,
                        };
                        let state = state.clone();
                        tokio::spawn(async move {
                            let _permit = permit;
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
            let available = match timeout(CLIENT_IDLE_TIMEOUT, reader.fill_buf()).await {
                Ok(r) => r?,
                Err(_) => {
                    tracing::debug!("Client idle timeout, disconnecting");
                    return Ok(());
                }
            };
            if available.is_empty() {
                break true;
            }
            match available.iter().position(|&b| b == b'\n') {
                Some(pos) => {
                    if line_buf.len() + pos > MAX_REQUEST_LEN {
                        tracing::warn!(
                            "Client sent oversized request ({} bytes), disconnecting",
                            line_buf.len() + pos
                        );
                        return Ok(());
                    }
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

        // Dispatch on a blocking thread to avoid holding std::sync::Mutex on async runtime
        let state_clone = state.clone();
        let trimmed_owned = trimmed.to_string();
        let response =
            tokio::task::spawn_blocking(move || v2::dispatch(&trimmed_owned, &state_clone)).await?;
        let mut response_json = serde_json::to_string(&response)?;
        response_json.push('\n');
        writer.write_all(response_json.as_bytes()).await?;
        writer.flush().await?;

        if eof {
            break;
        }
    }

    Ok(())
}

/// Clean up the socket file on shutdown.
pub fn cleanup() {
    let _ = std::fs::remove_file(socket_path());
}
