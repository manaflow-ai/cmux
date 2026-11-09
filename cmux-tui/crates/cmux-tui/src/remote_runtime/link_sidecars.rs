//! What a client link runs beside its local socket: the network watch that tells the link the
//! network changed, the link's own socket (`PATH.admin`: its state and a wait by a caller's
//! deadline), and the SSH route record.

use std::fs;
#[cfg(unix)]
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[cfg(unix)]
use cmux_remote::admin::{AdminServer, link_admin_socket, serve_link_cell_admin};
use cmux_remote::connection::ClientConnection;
use cmux_remote::first_dial::{LinkCell, LinkPhase};
use cmux_remote::network_watch::{self, NetworkWatch};
use tokio::sync::watch;

/// Started before the link's first dial, so the link's socket answers while it dials (the first
/// dial is a recovery like any later one, cmuxterm-hq#7766), and a network change made while it
/// dials both wakes that dial and still reaches the link once it is up (the first connect and the
/// link are two phases, and a receiver taken in the second would mark that change as seen).
pub(super) struct PendingSidecars {
    watch: NetworkWatch,
    changes: watch::Receiver<u64>,
    cell: Arc<LinkCell>,
    #[cfg(unix)]
    admin: Option<AdminServer>,
}

impl PendingSidecars {
    /// Watch the kernel's network changes and serve the link's state beside `local_socket`. A
    /// link socket that cannot be bound (a path too long, a leased path) leaves the link working
    /// without it.
    pub(super) async fn start(local_socket: &Path) -> Self {
        Self::start_with(NetworkWatch::start(), local_socket).await
    }

    /// [`PendingSidecars::start`] on a given watch (a test signals a manual one).
    pub(super) async fn start_with(watch: NetworkWatch, local_socket: &Path) -> Self {
        let changes = watch.subscribe();
        let cell = LinkCell::new();
        #[cfg(unix)]
        let admin = serve_link_cell_admin(&cell, link_admin_socket(local_socket)).await.ok();
        #[cfg(not(unix))]
        let _ = local_socket;
        Self {
            watch,
            changes,
            cell,
            #[cfg(unix)]
            admin,
        }
    }

    /// The link's state, which the first dial publishes.
    pub(super) fn cell(&self) -> &Arc<LinkCell> {
        &self.cell
    }

    /// Every network change from [`PendingSidecars::start`] on, for the first dial.
    pub(super) fn network(&self) -> watch::Receiver<u64> {
        self.watch.subscribe()
    }

    /// The first connect succeeded: the link's socket answers for `connection` from now on, and
    /// every network change since [`PendingSidecars::start`] goes to it.
    pub(super) fn attach(mut self, connection: &Arc<ClientConnection>) -> LinkSidecars {
        self.cell.attach(connection);
        let changes = self.changes.clone();
        let forward = tokio::spawn(network_watch::forward(changes, Arc::downgrade(connection)));
        LinkSidecars {
            _watch: self.watch.clone(),
            forward,
            cell: self.cell.clone(),
            #[cfg(unix)]
            _admin: self.admin.take(),
        }
    }
}

impl Drop for PendingSidecars {
    fn drop(&mut self) {
        // A first dial cancelled midway: every waiter returns. A failed one keeps its reason, and
        // after `attach` [`LinkSidecars`] owns the close.
        if matches!(
            self.cell.phase(),
            LinkPhase::Connecting { .. } | LinkPhase::Disconnected { .. }
        ) {
            self.cell.close();
        }
    }
}

/// Ends the forwarding and unlinks the link socket when dropped.
pub(super) struct LinkSidecars {
    _watch: NetworkWatch,
    forward: tokio::task::JoinHandle<()>,
    cell: Arc<LinkCell>,
    #[cfg(unix)]
    _admin: Option<AdminServer>,
}

impl Drop for LinkSidecars {
    fn drop(&mut self) {
        self.forward.abort();
        self.cell.close();
    }
}

/// `<socket>.route`: the SSH route a client runtime's local socket tunnels
/// to. Only SSH routes are recorded (no credential is in them); the CLI only
/// prints it, never runs it.
pub(crate) fn tunnel_route_record(socket: &Path) -> PathBuf {
    let mut path = socket.as_os_str().to_owned();
    path.push(".route");
    PathBuf::from(path)
}

pub(super) fn write_tunnel_route(socket: &Path, route: &str) -> Option<PathBuf> {
    if !route.starts_with("ssh://") {
        return None;
    }
    let record = tunnel_route_record(socket);
    let _ = fs::remove_file(&record);
    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file =
            OpenOptions::new().write(true).create_new(true).mode(0o600).open(&record).ok()?;
        file.write_all(route.as_bytes()).ok()?;
    }
    #[cfg(not(unix))]
    fs::write(&record, route).ok()?;
    Some(record)
}
