//! One WireGuard tunnel shared by many client processes.
//!
//! A WireGuard key supports one live session: the server remembers the
//! endpoint of the last authenticated sender, so two processes handshaking
//! with the same key steal each other's traffic. The macOS app spawns one
//! `remote connect` sidecar per Cloud VM link, so those sidecars cannot each
//! own the tunnel. The hub owns it instead and exposes SOCKS5 CONNECT on an
//! owner-only Unix socket; each sidecar dials VPC addresses through the hub
//! with [`crate::provider::SocksDialer`].
//!
//! The hub is deliberately narrow: no authentication method other than "none"
//! (the Unix socket is `0600` and the peer's uid is checked), CONNECT only,
//! literal IP targets only, and only targets inside the tunnel's routes. It
//! is a carrier, not an authority: the cmux Noise handshake still runs end to
//! end inside every tunneled connection.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_wg::{IpNetwork, WgError, WgNet};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, oneshot};
use tokio::task::JoinSet;

use crate::admin::verify_unix_peer_owner;
use crate::provider::socks::{
    self, COMMAND_CONNECT, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, REPLY_COMMAND_NOT_SUPPORTED,
    REPLY_CONNECTION_REFUSED, REPLY_GENERAL_FAILURE, REPLY_NETWORK_UNREACHABLE, REPLY_NOT_ALLOWED,
    REPLY_SUCCEEDED, Target,
};
use crate::unix_socket::{
    OwnedUnixListener, UnixAcceptBackoff, UnixSocketCleanup, UnixSocketError,
};

/// Concurrent tunneled connections the hub serves. Each VM link uses at most
/// four lanes; this leaves room for many links plus reconnect overlap.
const MAX_HUB_CONNECTIONS: usize = 256;
/// A client that opens the socket must finish the SOCKS exchange within this
/// bound or it is dropped, so a stuck peer cannot pin a connection slot.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub enum HubError {
    Io(io::Error),
    /// The socket path could not be owned (bad directory, already leased).
    Socket(String),
}

impl fmt::Display for HubError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "hub io: {error}"),
            Self::Socket(detail) => write!(formatter, "hub socket: {detail}"),
        }
    }
}

impl std::error::Error for HubError {}

impl From<UnixSocketError> for HubError {
    fn from(error: UnixSocketError) -> Self {
        match error {
            UnixSocketError::Io(error) => Self::Io(error),
            UnixSocketError::Protocol(detail) => Self::Socket(detail),
        }
    }
}

/// A running hub. Dropping it unlinks the socket and stops serving.
pub struct WireGuardHub {
    path: PathBuf,
    routes: Vec<IpNetwork>,
    socket_cleanup: Arc<UnixSocketCleanup>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), HubError>>>,
}

impl fmt::Debug for WireGuardHub {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WireGuardHub")
            .field("path", &self.path)
            .field("routes", &self.routes)
            .finish_non_exhaustive()
    }
}

impl WireGuardHub {
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Networks the hub will connect to, for the readiness report.
    pub fn routes(&self) -> &[IpNetwork] {
        &self.routes
    }

    /// Stop accepting, end every tunneled connection, and unlink the socket.
    pub async fn shutdown(mut self) -> Result<(), HubError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        let result = match self.task.take() {
            Some(task) => task
                .await
                .map_err(|error| HubError::Socket(format!("hub listener task failed: {error}")))?,
            None => Ok(()),
        };
        let _ = self.socket_cleanup.unlink();
        result
    }
}

impl Drop for WireGuardHub {
    fn drop(&mut self) {
        // The listener lives in the accept task; unlink here too because
        // aborting only schedules cancellation.
        let _ = self.socket_cleanup.unlink();
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// Serve SOCKS5 CONNECT for `net` on the Unix socket at `path`.
///
/// The parent directory is created `0700` if missing and must be owned by
/// this user and not writable by others without the sticky bit; the socket is
/// `0600`; a stale socket from a dead hub is replaced, a live one is refused.
pub async fn serve_wireguard_hub(
    net: Arc<WgNet>,
    path: impl Into<PathBuf>,
) -> Result<WireGuardHub, HubError> {
    let path = path.into();
    let listener = OwnedUnixListener::bind(path.clone()).await?;
    let socket_cleanup = listener.cleanup();
    let routes = net.routes().to_vec();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_HUB_CONNECTIONS));
    let task = tokio::spawn(async move {
        let mut accept_backoff = UnixAcceptBackoff::new();
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    connections.shutdown().await;
                    return Ok(());
                }
                Some(_) = connections.join_next(), if !connections.is_empty() => {}
                accepted = listener.listener().accept() => {
                    let (stream, _) = match accepted {
                        Ok(accepted) => {
                            accept_backoff.reset();
                            accepted
                        }
                        Err(error) => {
                            let Some(delay) = accept_backoff.retry_delay(&error) else {
                                return Err(HubError::Io(io::Error::new(
                                    error.kind(),
                                    format!("hub Unix listener accept failed: {error}"),
                                )));
                            };
                            // Bounded retry after a transient accept failure
                            // (descriptor exhaustion, aborted connection).
                            tokio::select! {
                                _ = &mut shutdown_rx => {
                                    connections.shutdown().await;
                                    return Ok(());
                                }
                                _ = tokio::time::sleep(delay) => {}
                            }
                            continue;
                        }
                    };
                    if verify_unix_peer_owner(&stream).is_err() {
                        continue;
                    }
                    let Ok(permit) = permits.clone().try_acquire_owned() else {
                        continue;
                    };
                    let net = Arc::clone(&net);
                    connections.spawn(async move {
                        let _permit = permit;
                        let _ = serve_connection(net, stream).await;
                    });
                }
            }
        }
    });
    Ok(WireGuardHub { path, routes, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

/// One SOCKS5 exchange, then a bidirectional copy until either side closes.
async fn serve_connection(
    net: Arc<WgNet>,
    mut stream: UnixStream,
) -> Result<(), socks::SocksError> {
    let request = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        if !socks::server_greet(&mut stream).await? {
            return Ok(None);
        }
        socks::server_read_request(&mut stream).await.map(Some)
    })
    .await
    .map_err(|_| socks::SocksError::Protocol("handshake timed out".into()))??;
    let Some(request) = request else { return Ok(()) };

    if request.command != COMMAND_CONNECT {
        socks::server_reply(&mut stream, REPLY_COMMAND_NOT_SUPPORTED, None).await?;
        return Ok(());
    }
    let target = match request.target {
        Target::Ip(address) => address,
        Target::Domain { .. } => {
            // The hub dials literal addresses only; names would need a
            // resolver inside the tunnel that nothing here provides.
            socks::server_reply(&mut stream, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, None).await?;
            return Ok(());
        }
    };
    if !net.routes_contain(target.ip()) {
        socks::server_reply(&mut stream, REPLY_NOT_ALLOWED, None).await?;
        return Ok(());
    }
    let mut tunneled = match net.connect(target).await {
        Ok(tunneled) => tunneled,
        Err(error) => {
            socks::server_reply(&mut stream, reply_for(&error), None).await?;
            return Ok(());
        }
    };
    socks::server_reply(&mut stream, REPLY_SUCCEEDED, Some(tunneled.local_addr())).await?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut tunneled).await;
    Ok(())
}

fn reply_for(error: &WgError) -> u8 {
    match error {
        WgError::ConnectionRefused(_) => REPLY_CONNECTION_REFUSED,
        WgError::NoTunnelAddress(_) => REPLY_NETWORK_UNREACHABLE,
        _ => REPLY_GENERAL_FAILURE,
    }
}
