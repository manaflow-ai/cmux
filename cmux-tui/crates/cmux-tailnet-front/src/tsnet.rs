//! The front on a real tailnet node (feature `tsnet`).
//!
//! - [`TailnetListener`]: a [`FrontListener`] over one TCP port of an embedded tsnet node
//!   ([`cmux_tailnet::Node::listen_tcp`]). It listens on the node's tailnet addresses only, the
//!   same path acpmux's tailnet ingress takes for its :443 (`server/tailnet_ingress.rs`:
//!   `listen_tcp` on a blocking thread, then `AsyncFd` + `try_accept`). It takes any
//!   `Arc<Node>`, so acpmux's `tailnet::embedded::Controller::node()` works as well as the
//!   stable node below.
//! - [`StableNode`]: the one stable node per user. Its identity is its state folder: tsnet keeps
//!   the node key and login there, so a restart with the same folder and hostname comes back as
//!   the same device with the same tailnet IP and MagicDNS name. It is never ephemeral.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tailnet::{BackendState, Listener, Node, NodeConfig};
use tokio::io::unix::AsyncFd;
use tokio::net::UnixStream;
use tokio::sync::Mutex;

use crate::front::FrontListener;

/// The stable node's name on the tailnet when the user names none.
pub const DEFAULT_HOSTNAME: &str = "cmux";

/// How long opening a tailnet listener may take.
const LISTEN_BOUND: Duration = Duration::from_secs(10);

fn other(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}

/// Whether a failed accept means the listener is gone (the same rule as acpmux's
/// `accept_errors::accept_ends_listener`).
fn ends_listener(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::EBADF | libc::EINVAL | libc::ENOTSOCK))
        || error.kind() == io::ErrorKind::UnexpectedEof
}

/// One TCP port of a tailnet node, as a [`FrontListener`]. Dropping it stops tsnet listening
/// on that port.
pub struct TailnetListener {
    port: u16,
    // One serve loop accepts from it; the lock only lends `try_accept` its `&mut`.
    inner: Mutex<AsyncFd<Listener>>,
    // Keeps the node up while the listener is.
    _node: Arc<Node>,
}

impl TailnetListener {
    /// Listen on `port` of `node`'s tailnet addresses.
    pub async fn bind(node: Arc<Node>, port: u16) -> io::Result<Self> {
        let listen_node = Arc::clone(&node);
        let opening = tokio::task::spawn_blocking(move || listen_node.listen_tcp(port));
        let listener = tokio::time::timeout(LISTEN_BOUND, opening)
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "tailnet listen timed out"))?
            .map_err(other)?
            .map_err(other)?;
        Ok(Self { port, inner: Mutex::new(AsyncFd::new(listener)?), _node: node })
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl FrontListener for TailnetListener {
    type Stream = UnixStream;

    async fn accept(&self) -> io::Result<UnixStream> {
        let mut listener = self.inner.lock().await;
        loop {
            let mut ready = listener.readable_mut().await?;
            let accepted = ready.try_io(|fd| {
                fd.get_mut().try_accept()?.ok_or_else(|| io::Error::from(io::ErrorKind::WouldBlock))
            });
            match accepted {
                // Not a whole accept record yet: wait for the next readiness.
                Err(_would_block) => continue,
                Ok(Ok((stream, _remote))) => {
                    stream.set_nonblocking(true)?;
                    return UnixStream::from_std(stream);
                }
                Ok(Err(error)) if ends_listener(&error) => return Err(error),
                // One lost connection: accept the next.
                Ok(Err(_)) => continue,
            }
        }
    }
}

/// How the stable node joins the tailnet.
#[derive(Debug, Clone)]
pub struct StableNodeConfig {
    /// The node's identity: keys and login live here. Keep it across restarts.
    pub state_dir: PathBuf,
    /// The device name: `cmux` by default, `cmux-<slug>` for a per-workspace node.
    pub hostname: String,
    /// A pre-auth key for headless sign-in (first start only; later starts reuse the login).
    pub auth_key: Option<String>,
    /// A coordination server other than Tailscale's (Headscale).
    pub control_url: Option<String>,
}

impl StableNodeConfig {
    /// The per-user node: hostname `cmux`, state in `<root>/cmux`.
    pub fn per_user(root: &Path) -> Self {
        Self::named(root, DEFAULT_HOSTNAME)
    }

    /// A per-workspace node: hostname `cmux-<slug>`, state in `<root>/cmux-<slug>`.
    pub fn per_workspace(root: &Path, slug: &str) -> Self {
        Self::named(root, &format!("{DEFAULT_HOSTNAME}-{slug}"))
    }

    fn named(root: &Path, hostname: &str) -> Self {
        Self {
            state_dir: root.join(hostname),
            hostname: hostname.to_owned(),
            auth_key: None,
            control_url: None,
        }
    }

    /// The tsnet configuration. Never ephemeral: an ephemeral node is deleted when it goes
    /// offline, and comes back with a new IP.
    pub fn node_config(&self) -> NodeConfig {
        let mut config = NodeConfig::new(&self.state_dir, &self.hostname);
        config.auth_key = self.auth_key.clone();
        config.control_url = self.control_url.clone();
        config.ephemeral = false;
        config
    }
}

/// The node's identity as the tailnet sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub hostname: String,
    pub dns_name: Option<String>,
    pub ips: Vec<String>,
}

/// The stable node, started.
pub struct StableNode {
    node: Arc<Node>,
    hostname: String,
}

impl StableNode {
    /// Start the node and wait (blocking, at most `within`) until it is Running.
    pub fn start_blocking(config: &StableNodeConfig, within: Duration) -> io::Result<Self> {
        let node = Node::new(&config.node_config()).map_err(other)?;
        node.start().map_err(other)?;
        let deadline = Instant::now() + within;
        loop {
            let state = node.status().map(|s| s.state()).unwrap_or(BackendState::NoState);
            if state == BackendState::Running && node.ips().is_ok_and(|ips| !ips.is_empty()) {
                break;
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("tailnet node {} not Running ({state:?})", config.hostname),
                ));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Ok(Self { node: Arc::new(node), hostname: config.hostname.clone() })
    }

    pub fn node(&self) -> &Arc<Node> {
        &self.node
    }

    pub fn identity(&self) -> io::Result<Identity> {
        let status = self.node.status().map_err(other)?;
        Ok(Identity {
            hostname: self.hostname.clone(),
            dns_name: status.dns_name(),
            ips: self.node.ips().map_err(other)?,
        })
    }

    /// A front listener on `port` of this node.
    pub async fn listen(&self, port: u16) -> io::Result<TailnetListener> {
        TailnetListener::bind(Arc::clone(&self.node), port).await
    }
}

#[cfg(test)]
#[path = "tsnet_tests.rs"]
mod tests;
