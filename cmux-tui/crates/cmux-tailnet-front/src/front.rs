//! The TCP front on the stable node.
//!
//! v1 does not terminate SSH: the SSH username is inside the encrypted stream, so the front can
//! not read `ssh <workspace>@cmux` without holding the host key and running an SSH server. It
//! picks the workspace by the port the connection came in on instead:
//!
//! - port 22 -> the user's default workspace's SSH,
//! - ports 2201, 2202, ... -> the other workspaces' SSH, in a stable order,
//! - any other mapped port -> one workspace's preview port.
//!
//! Each accepted connection resolves its target once, from the [`PlacementTable`], and splices
//! raw TCP to it until either side closes. A move changes only where the next connection goes.
//!
//! The listener (the tsnet node's listener in production) and the dialer (plain TCP, or a relay
//! later) are traits, so the forwarding is tested with loopback TCP.

use std::collections::BTreeMap;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_scope::{CloseReport, Scope};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use crate::placement::{Backend, PlacementTable};

/// The port the default workspace's SSH answers on.
pub const SSH_PORT: u16 = 22;
/// The first port of the other workspaces' SSH.
pub const SSH_EXTRA_BASE_PORT: u16 = 2201;
/// How long a dial to the current placement may take before the front drops the connection.
pub const DEFAULT_DIAL_TIMEOUT: Duration = Duration::from_secs(10);

/// What one front port forwards to.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Route {
    /// The workspace's SSH server.
    Ssh { workspace: String },
    /// One of the workspace's preview ports.
    Preview { workspace: String, port: u16 },
}

impl Route {
    pub fn workspace(&self) -> &str {
        match self {
            Self::Ssh { workspace } | Self::Preview { workspace, .. } => workspace,
        }
    }
}

/// Front port -> route.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PortMap(pub BTreeMap<u16, Route>);

impl PortMap {
    /// The v1 SSH layout: 22 for `default_workspace`, 2201.. for `others` in the order given
    /// (callers pass a stable order, e.g. creation order, so a workspace keeps its port).
    /// Workspaces past the last port are left out.
    pub fn ssh_layout(default_workspace: &str, others: &[&str]) -> Self {
        let mut map = BTreeMap::new();
        map.insert(SSH_PORT, Route::Ssh { workspace: default_workspace.to_owned() });
        let mut port = SSH_EXTRA_BASE_PORT;
        for workspace in others.iter().filter(|w| **w != default_workspace) {
            map.insert(port, Route::Ssh { workspace: (*workspace).to_owned() });
            match port.checked_add(1) {
                Some(next) => port = next,
                None => break,
            }
        }
        Self(map)
    }

    /// Add a preview: front port `front_port` -> `workspace`'s preview `port`.
    pub fn with_preview(mut self, front_port: u16, workspace: &str, port: u16) -> Self {
        self.0.insert(front_port, Route::Preview { workspace: workspace.to_owned(), port });
        self
    }

    pub fn route(&self, front_port: u16) -> Option<&Route> {
        self.0.get(&front_port)
    }
}

/// Whether the front runs and what it serves. Off by default: nothing listens unless asked.
#[derive(Debug, Clone)]
pub struct FrontConfig {
    pub enabled: bool,
    pub ports: PortMap,
    pub dial_timeout: Duration,
}

impl Default for FrontConfig {
    fn default() -> Self {
        Self { enabled: false, ports: PortMap::default(), dial_timeout: DEFAULT_DIAL_TIMEOUT }
    }
}

/// Where accepted connections come from: the stable node's listener for one port.
pub trait FrontListener: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn accept(&self) -> impl Future<Output = io::Result<Self::Stream>> + Send;
}

/// How the front reaches a backend.
pub trait Dialer: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn dial(&self, backend: &Backend) -> impl Future<Output = io::Result<Self::Stream>> + Send;
}

impl FrontListener for TcpListener {
    type Stream = TcpStream;
    async fn accept(&self) -> io::Result<TcpStream> {
        let (stream, _) = TcpListener::accept(self).await?;
        let _ = stream.set_nodelay(true);
        Ok(stream)
    }
}

/// Plain TCP to `host:port`.
#[derive(Debug, Clone, Copy, Default)]
pub struct TcpDialer;

impl Dialer for TcpDialer {
    type Stream = TcpStream;
    async fn dial(&self, backend: &Backend) -> io::Result<TcpStream> {
        let stream = TcpStream::connect(backend.as_str()).await?;
        let _ = stream.set_nodelay(true);
        Ok(stream)
    }
}

/// Counters, for tests and the status surface.
#[derive(Debug, Default)]
pub struct FrontStats {
    pub accepted: AtomicU64,
    pub forwarded: AtomicU64,
    pub no_placement: AtomicU64,
    pub dial_failed: AtomicU64,
}

/// The front: a placement table, a dialer, and the scope that owns its listener and
/// connection tasks ([`Front::close`] ends them all).
pub struct Front<D: Dialer> {
    table: Arc<PlacementTable>,
    dialer: D,
    dial_timeout: Duration,
    stats: FrontStats,
    scope: Scope,
}

impl<D: Dialer> Front<D> {
    pub fn new(table: Arc<PlacementTable>, dialer: D) -> Arc<Self> {
        Self::with_dial_timeout(table, dialer, DEFAULT_DIAL_TIMEOUT)
    }

    pub fn with_dial_timeout(
        table: Arc<PlacementTable>,
        dialer: D,
        timeout: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            table,
            dialer,
            dial_timeout: timeout,
            stats: FrontStats::default(),
            scope: Scope::new("tailnet-front"),
        })
    }

    /// Serve `listener` by `route` as one of the front's tasks (ends at [`Front::close`]).
    pub fn spawn_serve<L: FrontListener>(
        self: &Arc<Self>,
        listener: L,
        route: Route,
    ) -> JoinHandle<Option<io::Result<()>>> {
        self.scope.spawn_until_cancelled(
            "tailnet-front.listener",
            Arc::clone(self).serve(listener, route),
        )
    }

    /// Stop every listener and open connection, waiting at most `within`.
    pub async fn close(&self, within: Duration) -> CloseReport {
        self.scope.close(within).await
    }

    pub fn table(&self) -> &Arc<PlacementTable> {
        &self.table
    }

    pub fn stats(&self) -> &FrontStats {
        &self.stats
    }

    /// The route's current target and the generation it came from.
    pub fn resolve(&self, route: &Route) -> Option<(Backend, u64)> {
        match route {
            Route::Ssh { workspace } => self.table.ssh_target(workspace),
            Route::Preview { workspace, port } => self.table.preview_target(workspace, *port),
        }
    }

    /// Accept on `listener` forever, forwarding each connection by `route`. Returns only when
    /// the listener fails.
    pub async fn serve<L: FrontListener>(
        self: Arc<Self>,
        listener: L,
        route: Route,
    ) -> io::Result<()> {
        loop {
            let inbound = listener.accept().await?;
            self.stats.accepted.fetch_add(1, Ordering::Relaxed);
            let front = Arc::clone(&self);
            let route = route.clone();
            self.scope.spawn_until_cancelled("tailnet-front.connection", async move {
                front.forward(inbound, &route).await;
            });
        }
    }

    /// Forward one accepted connection: resolve now, dial, splice until either side closes.
    pub async fn forward<S>(&self, mut inbound: S, route: &Route)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        let Some((backend, _generation)) = self.resolve(route) else {
            self.stats.no_placement.fetch_add(1, Ordering::Relaxed);
            return;
        };
        let dialed = tokio::time::timeout(self.dial_timeout, self.dialer.dial(&backend)).await;
        let mut outbound = match dialed {
            Ok(Ok(stream)) => stream,
            Ok(Err(_)) | Err(_) => {
                self.stats.dial_failed.fetch_add(1, Ordering::Relaxed);
                return;
            }
        };
        self.stats.forwarded.fetch_add(1, Ordering::Relaxed);
        let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
    }
}

impl Front<TcpDialer> {
    /// Start the front on plain TCP listeners at `bind_ip` (the tsnet node's listeners replace
    /// these when it is wired in). `None` when the config is off: nothing binds, nothing runs.
    pub async fn start_tcp(
        table: Arc<PlacementTable>,
        config: &FrontConfig,
        bind_ip: IpAddr,
    ) -> io::Result<Option<(Arc<Self>, Vec<u16>)>> {
        if !config.enabled {
            return Ok(None);
        }
        let front = Self::with_dial_timeout(table, TcpDialer, config.dial_timeout);
        let mut ports = Vec::new();
        for (port, route) in &config.ports.0 {
            let listener = TcpListener::bind(SocketAddr::new(bind_ip, *port)).await?;
            let bound = listener.local_addr()?.port();
            front.spawn_serve(listener, route.clone());
            ports.push(bound);
        }
        Ok(Some((front, ports)))
    }
}

#[cfg(test)]
#[path = "front_tests.rs"]
mod tests;
