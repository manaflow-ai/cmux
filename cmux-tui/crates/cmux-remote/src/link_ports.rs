//! A link's port forwards: a port of the machine's localhost on 127.0.0.1 and a port this
//! computer picks, through the link's own connection. The app's Forward Port… action for an SSH
//! machine asks the link's socket (`PATH.admin`, [`crate::admin::serve_link_cell_admin`]) with
//! `port-forward`, `port-list` and `port-close`; the bytes go the way `cmux remote forward`'s do
//! ([`LocalPortForward`] over a [`RoutePolicy::LoopbackOnly`] route).
//!
//! One forward per remote (host, port): a second `port-forward` answers the same local port. A
//! forward lives as long as the link process (the app's link for the machine) or until
//! `port-close`; the link's own redials carry it across short drops. Nothing is persisted.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;

use cmux_remote_protocol::{RouteId, RoutePolicy, WorkspaceRequest, WorkspaceResponse};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::bridge::LocalPortForward;
use crate::client::WorkspaceClient;
use crate::service::ServiceMultiplexer;

/// Forwards one link keeps at most.
pub const MAX_LINK_FORWARDS: usize = 64;
/// The remote host a forward reaches when the caller names none.
pub const DEFAULT_FORWARD_HOST: &str = "127.0.0.1";
/// The remote directory a forward's route is scoped to when the caller names none (as
/// `cmux remote dial-tcp`'s default): the daemon scopes every route to an open workspace.
pub const DEFAULT_FORWARD_WORKSPACE_ROOT: &str = "/";
/// The longest a route's open or close may take before the forward gives up on it.
const ROUTE_TIMEOUT: Duration = Duration::from_secs(20);
const CLOSE_ROUTE_TIMEOUT: Duration = Duration::from_secs(2);

/// One forward as `port-forward` and `port-list` answer it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkForward {
    /// The machine's port.
    pub port: u16,
    /// The machine's loopback host the port is on.
    pub host: String,
    /// The port on this computer's 127.0.0.1.
    pub local_port: u16,
    /// `http://127.0.0.1:<local_port>/`.
    pub url: String,
}

/// `port-list`'s answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkForwards {
    pub forwards: Vec<LinkForward>,
}

/// `port-close`'s answer: `closed` is false when no forward had that port.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkForwardClosed {
    pub port: u16,
    pub host: String,
    pub closed: bool,
}

struct Held {
    forward: LocalPortForward,
    client: Arc<WorkspaceClient>,
    route: RouteId,
}

impl Held {
    fn record(&self, host: &str, port: u16) -> LinkForward {
        let local_port = self.forward.local_addr().port();
        LinkForward {
            port,
            host: host.to_owned(),
            local_port,
            url: format!("http://127.0.0.1:{local_port}/"),
        }
    }

    async fn close(self) {
        self.forward.shutdown().await;
        let _ = tokio::time::timeout(
            CLOSE_ROUTE_TIMEOUT,
            self.client.request(WorkspaceRequest::CloseRoute { route: self.route }),
        )
        .await;
    }
}

/// A link's forwards. Answers before the link is up (each forward is refused with why until
/// [`LinkPorts::attach`]); held weakly by the link's socket like the link itself.
#[derive(Default)]
pub struct LinkPorts {
    multiplexer: OnceLock<Weak<ServiceMultiplexer>>,
    forwards: Mutex<BTreeMap<(String, u16), Held>>,
}

impl LinkPorts {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// The link's connection is up: forwards go through `multiplexer` from now on.
    pub fn attach(&self, multiplexer: &Arc<ServiceMultiplexer>) {
        let _ = self.multiplexer.set(Arc::downgrade(multiplexer));
    }

    /// Forward the machine's `host:port` (host default [`DEFAULT_FORWARD_HOST`], a loopback
    /// address the daemon checks) to 127.0.0.1 and a port this computer picks. A second call for
    /// the same host and port answers the forward it already has.
    pub async fn forward(
        &self,
        port: u16,
        host: Option<String>,
        workspace_root: Option<String>,
    ) -> Result<LinkForward, String> {
        if port == 0 {
            return Err("port-forward needs a port from 1 to 65535".into());
        }
        let host = host.filter(|h| !h.is_empty()).unwrap_or_else(|| DEFAULT_FORWARD_HOST.into());
        let mut forwards = self.forwards.lock().await;
        if let Some(held) = forwards.get(&(host.clone(), port)) {
            return Ok(held.record(&host, port));
        }
        if forwards.len() >= MAX_LINK_FORWARDS {
            return Err(format!(
                "this machine already has {MAX_LINK_FORWARDS} forwarded ports; close one with port-close first"
            ));
        }
        let multiplexer = self
            .multiplexer
            .get()
            .and_then(Weak::upgrade)
            .ok_or_else(|| "the machine's link is not connected yet".to_owned())?;
        let root = workspace_root
            .filter(|r| !r.is_empty())
            .unwrap_or_else(|| DEFAULT_FORWARD_WORKSPACE_ROOT.into());
        let (client, route) =
            tokio::time::timeout(ROUTE_TIMEOUT, open_route(multiplexer.clone(), root, &host, port))
                .await
                .map_err(|_| {
                    format!(
                        "the machine did not open a route to {host}:{port} within {}s",
                        ROUTE_TIMEOUT.as_secs()
                    )
                })??;
        let listen = SocketAddr::from(([127, 0, 0, 1], 0));
        let forward = match LocalPortForward::bind(multiplexer, route, listen).await {
            Ok(forward) => forward,
            Err(error) => {
                let _ = tokio::time::timeout(
                    CLOSE_ROUTE_TIMEOUT,
                    client.request(WorkspaceRequest::CloseRoute { route }),
                )
                .await;
                return Err(format!("could not listen on 127.0.0.1: {error}"));
            }
        };
        let held = Held { forward, client, route };
        let record = held.record(&host, port);
        forwards.insert((host, port), held);
        Ok(record)
    }

    /// Every forward, in (host, port) order.
    pub async fn list(&self) -> LinkForwards {
        let forwards = self.forwards.lock().await;
        LinkForwards {
            forwards: forwards
                .iter()
                .map(|((host, port), held)| held.record(host, *port))
                .collect(),
        }
    }

    /// Stop forwarding the machine's `host:port`: its listener and connections close.
    pub async fn close(&self, port: u16, host: Option<String>) -> LinkForwardClosed {
        let host = host.filter(|h| !h.is_empty()).unwrap_or_else(|| DEFAULT_FORWARD_HOST.into());
        let held = self.forwards.lock().await.remove(&(host.clone(), port));
        let closed = held.is_some();
        if let Some(held) = held {
            held.close().await;
        }
        LinkForwardClosed { port, host, closed }
    }
}

/// `cmux remote forward`'s route: open `root` and a loopback-only route to `host:port` in it.
/// The client holds the workspace open, so it lives as long as the forward.
async fn open_route(
    multiplexer: Arc<ServiceMultiplexer>,
    root: String,
    host: &str,
    port: u16,
) -> Result<(Arc<WorkspaceClient>, RouteId), String> {
    let client = WorkspaceClient::connect(multiplexer)
        .await
        .map_err(|error| format!("could not reach the machine's daemon: {error}"))?;
    let workspace = match client
        .request(WorkspaceRequest::OpenWorkspace { root: root.clone() })
        .await
        .map_err(|error| format!("the machine refused to open {root}: {error}"))?
    {
        WorkspaceResponse::Workspace { id, .. } => id,
        other => return Err(format!("unexpected open-workspace response: {other:?}")),
    };
    match client
        .request(WorkspaceRequest::CreateRoute {
            workspace,
            host: host.to_owned(),
            port,
            policy: RoutePolicy::LoopbackOnly,
        })
        .await
        .map_err(|error| format!("the machine refused a route to {host}:{port}: {error}"))?
    {
        WorkspaceResponse::RouteCreated { route, .. } => Ok((client, route)),
        other => Err(format!("unexpected create-route response: {other:?}")),
    }
}
