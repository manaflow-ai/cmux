//! What a client link runs beside its local socket: the network watch that tells the link the
//! network changed, the link's own socket (`PATH.admin`: its state and a wait by a caller's
//! deadline), and the SSH route record.

use std::fs;
#[cfg(unix)]
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[cfg(unix)]
use cmux_remote::admin::{AdminServer, link_admin_socket, serve_link_admin};
use cmux_remote::connection::ClientConnection;
use cmux_remote::network_watch::{self, NetworkWatch};
use tokio::sync::watch;

/// Started before the link's first dial, so a network change made while it dials still
/// reaches the link once it is up (the first connect and the link are two phases, and a
/// receiver taken in the second would mark that change as seen).
pub(super) struct PendingSidecars {
    watch: NetworkWatch,
    changes: watch::Receiver<u64>,
}

impl PendingSidecars {
    pub(super) fn start() -> Self {
        let watch = NetworkWatch::start();
        let changes = watch.subscribe();
        Self { watch, changes }
    }

    /// Hand every network change since [`PendingSidecars::start`] to `connection`, and serve
    /// its state beside `local_socket`. A link socket that cannot be bound (a path too long,
    /// a leased path) leaves the link working without it.
    pub(super) async fn attach(
        self,
        connection: &Arc<ClientConnection>,
        local_socket: &Path,
    ) -> LinkSidecars {
        let forward =
            tokio::spawn(network_watch::forward(self.changes, Arc::downgrade(connection)));
        #[cfg(unix)]
        let admin = serve_link_admin(connection, link_admin_socket(local_socket)).await.ok();
        #[cfg(not(unix))]
        let _ = local_socket;
        LinkSidecars {
            _watch: self.watch,
            forward,
            #[cfg(unix)]
            _admin: admin,
        }
    }
}

/// Ends the forwarding and unlinks the link socket when dropped.
pub(super) struct LinkSidecars {
    _watch: NetworkWatch,
    forward: tokio::task::JoinHandle<()>,
    #[cfg(unix)]
    _admin: Option<AdminServer>,
}

impl Drop for LinkSidecars {
    fn drop(&mut self) {
        self.forward.abort();
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
