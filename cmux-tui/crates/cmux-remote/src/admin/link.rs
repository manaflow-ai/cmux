//! A link's own local socket (`remote connect`): its state, and a wait until it is connected
//! by a caller's deadline. The link is the only layer that redials; an owner asks here instead
//! of retrying on its own.
//!
//! Owner-only like the daemon's admin socket: an owner-controlled directory, the peer's uid
//! checked on every connection, and nothing but [`AdminRequest::LinkState`] and
//! [`AdminRequest::AwaitReady`] answered. It reads state and spends the link's own redial
//! budget; it runs nothing and reaches no other object.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, oneshot};
use tokio::task::JoinSet;

use super::{
    ADMIN_IO_TIMEOUT, AdminError, AdminRequest, AdminResponse, AdminServer, MAX_ADMIN_CONNECTIONS,
    MAX_ADMIN_MESSAGE_BYTES, encode_admin_response, read_bounded_admin_message, timeout_admin_io,
    validate_peer,
};
use crate::connection::{ClientConnection, ConnectionError};
use crate::observability::ConnectionState;
use crate::unix_socket::{OwnedUnixListener, UnixAcceptBackoff, UnixSocketError};

/// The longest wait one [`AdminRequest::AwaitReady`] may ask for.
pub const LINK_AWAIT_LIMIT: Duration = Duration::from_secs(120);

/// The answer to both link requests.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkStatus {
    /// `connected`, `reconnecting`, `disconnected` or `closed`; `down` when an
    /// [`AdminRequest::AwaitReady`] ran out of time.
    pub state: String,
    /// Why the link is not connected, when it is not.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// The link socket that sits beside a `remote connect` local socket: `PATH.admin`.
pub fn link_admin_socket(local_socket: &Path) -> PathBuf {
    let mut path = OsString::from(local_socket.as_os_str());
    path.push(".admin");
    PathBuf::from(path)
}

/// How long a client waits for an answer: a wait's own deadline plus the usual I/O bound.
pub(super) fn response_timeout(request: &AdminRequest) -> Duration {
    match request {
        AdminRequest::AwaitReady { within_ms } => {
            Duration::from_millis(*within_ms).min(LINK_AWAIT_LIMIT) + ADMIN_IO_TIMEOUT
        }
        _ => ADMIN_IO_TIMEOUT,
    }
}

/// Serve `connection`'s state on `path` until the returned server is shut down or dropped. The
/// server holds the connection weakly: once its owner lets it go, every answer is `closed`.
pub async fn serve_link_admin(
    connection: &Arc<ClientConnection>,
    path: impl Into<PathBuf>,
) -> Result<AdminServer, AdminError> {
    let path = path.into();
    let listener = OwnedUnixListener::bind(path.clone()).await.map_err(|error| match error {
        UnixSocketError::Io(error) => AdminError::Io(error),
        UnixSocketError::Protocol(message) => {
            AdminError::Protocol(format!("could not own link Unix socket: {message}"))
        }
    })?;
    let socket_cleanup = listener.cleanup();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_ADMIN_CONNECTIONS));
    let connection = Arc::downgrade(connection);
    let task = tokio::spawn(async move {
        let mut accept_backoff = UnixAcceptBackoff::new();
        let mut connections = JoinSet::new();
        loop {
            let stream = tokio::select! {
                _ = &mut shutdown_rx => break,
                Some(_) = connections.join_next(), if !connections.is_empty() => continue,
                accepted = listener.listener().accept() => match accepted {
                    Ok((stream, _)) => {
                        accept_backoff.reset();
                        stream
                    }
                    Err(error) => {
                        let Some(delay) = accept_backoff.retry_delay(&error) else {
                            connections.shutdown().await;
                            return Err(AdminError::Io(error));
                        };
                        tokio::select! {
                            _ = &mut shutdown_rx => break,
                            () = tokio::time::sleep(delay) => continue,
                        }
                    }
                },
            };
            if validate_peer(&stream).is_err() {
                continue;
            }
            let Ok(permit) = permits.clone().try_acquire_owned() else { continue };
            let connection = connection.clone();
            connections.spawn(async move {
                let _permit = permit;
                let _ = serve_link_connection(connection, stream).await;
            });
        }
        connections.shutdown().await;
        Ok(())
    });
    Ok(AdminServer { path, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

async fn serve_link_connection(
    connection: Weak<ClientConnection>,
    stream: UnixStream,
) -> Result<(), AdminError> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut encoded = Vec::new();
    let size = timeout_admin_io(
        "reading link request",
        read_bounded_admin_message(&mut reader, &mut encoded),
    )
    .await?;
    let response = if size == 0 {
        AdminResponse::failure("empty link request")
    } else if size > MAX_ADMIN_MESSAGE_BYTES {
        AdminResponse::failure("link request is too large")
    } else {
        match serde_json::from_slice::<AdminRequest>(&encoded) {
            Ok(request) => dispatch(&connection, request).await,
            Err(error) => AdminResponse::failure(format!("invalid link request: {error}")),
        }
    };
    let response = encode_admin_response(response)?;
    timeout_admin_io("writing link response", writer.write_all(&response)).await?;
    timeout_admin_io("closing link response", writer.shutdown()).await?;
    Ok(())
}

async fn dispatch(connection: &Weak<ClientConnection>, request: AdminRequest) -> AdminResponse {
    match request {
        AdminRequest::LinkState => AdminResponse::success(match connection.upgrade() {
            Some(connection) => current(&connection),
            None => closed(),
        }),
        AdminRequest::AwaitReady { within_ms } => {
            let Some(connection) = connection.upgrade() else {
                return AdminResponse::success(closed());
            };
            let within = Duration::from_millis(within_ms).min(LINK_AWAIT_LIMIT);
            let deadline = tokio::time::Instant::now() + within;
            AdminResponse::success(match connection.await_ready(deadline).await {
                Ok(()) => current(&connection),
                Err(ConnectionError::Closed) => closed(),
                Err(error) => LinkStatus {
                    state: "down".into(),
                    reason: Some(connection.last_failure().unwrap_or_else(|| error.to_string())),
                },
            })
        }
        _ => AdminResponse::failure("a link's socket answers only link-state and await-ready"),
    }
}

fn current(connection: &ClientConnection) -> LinkStatus {
    let state = *connection.subscribe_state().borrow();
    let reason = match state {
        ConnectionState::Connected | ConnectionState::Closed => None,
        ConnectionState::Reconnecting | ConnectionState::Disconnected => connection.last_failure(),
    };
    LinkStatus { state: state_name(state).into(), reason }
}

fn closed() -> LinkStatus {
    LinkStatus { state: state_name(ConnectionState::Closed).into(), reason: None }
}

fn state_name(state: ConnectionState) -> &'static str {
    match state {
        ConnectionState::Connected => "connected",
        ConnectionState::Reconnecting => "reconnecting",
        ConnectionState::Disconnected => "disconnected",
        ConnectionState::Closed => "closed",
    }
}
