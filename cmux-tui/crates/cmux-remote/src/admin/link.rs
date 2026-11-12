//! A link's own local socket (`remote connect`): its state, and a wait until it is connected
//! by a caller's deadline. The link is the only layer that redials; an owner asks here instead
//! of retrying on its own. It answers from the start: before the first connect it reports the
//! first dial ([`LinkCell`]), after it the connection.
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
use crate::first_dial::{LinkCell, LinkPhase, NotConnected};
use crate::observability::ConnectionState;
use crate::unix_socket::{OwnedUnixListener, UnixAcceptBackoff, UnixSocketError};

/// The longest wait one [`AdminRequest::AwaitReady`] may ask for.
pub const LINK_AWAIT_LIMIT: Duration = Duration::from_secs(120);

/// The answer to both link requests.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkStatus {
    /// `connected`, `reconnecting`, `disconnected` or `closed`; before the first connect also
    /// `connecting` (a first dial in flight) and `failed` (a permanent error: the link exits);
    /// `down` when an [`AdminRequest::AwaitReady`] ran out of time.
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

/// What a link socket answers for.
#[derive(Clone)]
enum LinkTarget {
    Connection(Weak<ClientConnection>),
    Cell(Weak<LinkCell>),
}

/// Serve `connection`'s state on `path` until the returned server is shut down or dropped. The
/// server holds the connection weakly: once its owner lets it go, every answer is `closed`.
pub async fn serve_link_admin(
    connection: &Arc<ClientConnection>,
    path: impl Into<PathBuf>,
) -> Result<AdminServer, AdminError> {
    serve(LinkTarget::Connection(Arc::downgrade(connection)), path.into()).await
}

/// Serve a link's state on `path` from before its first connect: the first dial's state until
/// [`LinkCell::attach`], then the connection's. Held weakly, as [`serve_link_admin`] holds a
/// connection.
pub async fn serve_link_cell_admin(
    cell: &Arc<LinkCell>,
    path: impl Into<PathBuf>,
) -> Result<AdminServer, AdminError> {
    serve(LinkTarget::Cell(Arc::downgrade(cell)), path.into()).await
}

async fn serve(target: LinkTarget, path: PathBuf) -> Result<AdminServer, AdminError> {
    let listener = OwnedUnixListener::bind(path.clone()).await.map_err(|error| match error {
        UnixSocketError::Io(error) => AdminError::Io(error),
        UnixSocketError::Protocol(message) => {
            AdminError::Protocol(format!("could not own link Unix socket: {message}"))
        }
    })?;
    let socket_cleanup = listener.cleanup();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_ADMIN_CONNECTIONS));
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
            let target = target.clone();
            connections.spawn(async move {
                let _permit = permit;
                let _ = serve_link_connection(target, stream).await;
            });
        }
        connections.shutdown().await;
        Ok(())
    });
    Ok(AdminServer { path, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

async fn serve_link_connection(target: LinkTarget, stream: UnixStream) -> Result<(), AdminError> {
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
            Ok(request) => match &target {
                LinkTarget::Connection(connection) => dispatch(connection, request).await,
                LinkTarget::Cell(cell) => dispatch_cell(cell, request).await,
            },
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
            AdminResponse::success(await_connection(&connection, await_deadline(within_ms)).await)
        }
        _ => AdminResponse::failure("a link's socket answers only link-state and await-ready"),
    }
}

/// A link's answer from its [`LinkCell`]: the first dial's state, or once it connected, the
/// connection's ([`dispatch`]).
async fn dispatch_cell(cell: &Weak<LinkCell>, request: AdminRequest) -> AdminResponse {
    let Some(cell) = cell.upgrade() else {
        return match request {
            AdminRequest::LinkState | AdminRequest::AwaitReady { .. } => {
                AdminResponse::success(closed())
            }
            _ => AdminResponse::failure("a link's socket answers only link-state and await-ready"),
        };
    };
    match request {
        AdminRequest::LinkState => AdminResponse::success(match cell.phase() {
            LinkPhase::Connected(connection) => match connection.upgrade() {
                Some(connection) => current(&connection),
                None => closed(),
            },
            LinkPhase::Connecting { reason } => LinkStatus { state: "connecting".into(), reason },
            LinkPhase::Disconnected { reason } => {
                LinkStatus { state: state_name(ConnectionState::Disconnected).into(), reason }
            }
            LinkPhase::Failed { reason } => failed(reason),
            LinkPhase::Closed => closed(),
        }),
        AdminRequest::AwaitReady { within_ms } => {
            let deadline = await_deadline(within_ms);
            match cell.wait_connected(deadline).await {
                Ok(connection) => {
                    AdminResponse::success(await_connection(&connection, deadline).await)
                }
                Err(NotConnected::TimedOut { reason }) => AdminResponse::success(LinkStatus {
                    state: "down".into(),
                    reason: Some(reason.unwrap_or_else(|| NOT_CONNECTED_YET.into())),
                }),
                Err(NotConnected::Failed { reason }) => AdminResponse::success(failed(reason)),
                Err(NotConnected::Closed) => AdminResponse::success(closed()),
            }
        }
        _ => AdminResponse::failure("a link's socket answers only link-state and await-ready"),
    }
}

fn await_deadline(within_ms: u64) -> tokio::time::Instant {
    tokio::time::Instant::now() + Duration::from_millis(within_ms).min(LINK_AWAIT_LIMIT)
}

/// Wait on a connected-once link until it is connected or `deadline` passes.
async fn await_connection(
    connection: &ClientConnection,
    deadline: tokio::time::Instant,
) -> LinkStatus {
    match connection.await_ready(deadline).await {
        Ok(()) => current(connection),
        Err(ConnectionError::Closed) => closed(),
        Err(error) => LinkStatus {
            state: "down".into(),
            reason: Some(connection.last_failure().unwrap_or_else(|| error.to_string())),
        },
    }
}

/// The reason a wait that ran out before the first dial finished reports.
const NOT_CONNECTED_YET: &str = "the link has not connected yet";

fn failed(reason: String) -> LinkStatus {
    LinkStatus { state: "failed".into(), reason: Some(reason) }
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
