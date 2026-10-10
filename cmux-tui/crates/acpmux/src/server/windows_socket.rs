//! The daemon socket on Windows: `cmux::local_socket`, AF_UNIX with the
//! same-user checks the cmux daemon uses. The socket file is owned by our
//! token user; every accepted peer must be our user and not sandboxed (a
//! refused one is closed before it can send a line). Its accept blocks, so
//! it runs on its own thread and each connection is bridged into tokio
//! (`crate::local_stream::bridge`).

use crate::hub::Hub;
use anyhow::{Context, Result};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// The bound daemon socket.
pub struct UnixListener(cmux::local_socket::Listener);

/// Binds the daemon socket, refusing to steal a live one. A missing socket
/// folder is made owner-only; an existing one is left as it is (the socket
/// file's owner and the peer check protect the socket, as mode 0600 does on
/// Unix).
pub async fn bind_unix(path: &Path) -> Result<UnixListener> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty())
        && std::fs::symlink_metadata(parent).is_err()
    {
        cmux::local_socket::private_directory(parent)
            .with_context(|| format!("create {}", parent.display()))?;
    }
    // A socket file is a reparse point that `Path::exists` does not follow.
    if std::fs::symlink_metadata(path).is_ok() {
        match cmux::local_socket::connect_same_user(path) {
            Ok(_) => anyhow::bail!("another acpmux daemon owns {}", path.display()),
            // Another user's socket: never removed, never used.
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                return Err(anyhow::Error::new(e).context(format!("bind {}", path.display())));
            }
            Err(_) => std::fs::remove_file(path)
                .with_context(|| format!("remove the stale socket {}", path.display()))?,
        }
    }
    let listener = cmux::local_socket::listen_explicit(path)
        .with_context(|| format!("bind {}", path.display()))?;
    tracing::info!("listening on {}", path.display());
    Ok(UnixListener(listener))
}

/// Accepts connections until the process ends. A refused peer (another
/// user, a sandboxed process) is logged and dropped.
pub async fn serve_unix(hub: Arc<Hub>, listener: UnixListener) -> Result<()> {
    let (tx, mut rx) = mpsc::channel::<cmux::local_socket::Stream>(16);
    std::thread::Builder::new()
        .name("acpmux-accept".into())
        .spawn(move || {
            loop {
                match listener.0.accept_with_peer() {
                    Ok((stream, _peer)) => {
                        if tx.blocking_send(stream).is_err() {
                            break;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                        tracing::warn!("socket peer {e}");
                    }
                    Err(e) => {
                        tracing::warn!("accept failed: {e}");
                        // No busy loop on a persistent accept error.
                        std::thread::sleep(Duration::from_millis(100));
                    }
                }
            }
        })
        .context("start the daemon socket's accept thread")?;
    while let Some(socket) = rx.recv().await {
        match crate::local_stream::bridge(socket) {
            Ok(stream) => {
                tokio::spawn(super::serve_stream(hub.clone(), stream, None));
            }
            Err(e) => tracing::warn!("accept failed: {e}"),
        }
    }
    anyhow::bail!("the daemon socket's accept thread ended")
}
