//! One client connection's supervision. A connection changes the hub's shared state:
//! its views, peer leases and ephemeral sessions, released when it ends, and what its
//! requests and notifications change. So it runs under the hub's supervisor as
//! `Fatal`, as each of its requests (`request_task.rs`) and notification handlers
//! does: a panic ends the daemon, which its supervisor starts again, never a daemon
//! that keeps a dead connection's leases or a lock it poisoned
//! (`crate::supervised`; `content/browser/browser_main_loop.cc`). Shutdown: Skip, as
//! the hub's other tasks. Only the transport pumps around it (`stream.rs`, the
//! WebSocket reader and writer) are scoped: they own a socket half and a channel end.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
use std::sync::{Arc, Mutex as StdMutex};

use futures::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use super::requests::handle_notification;
use super::{Conn, ConnAuth, Hub, Origin, peer_text, serve_connection_body};
use crate::supervised::{Fatal, ShutdownBehavior};

/// The supervised worker that serves one client connection.
pub(crate) const CONNECTION_WORKER: &str = "server.connection";
/// The supervised worker of one client notification's handler.
pub(crate) const NOTIFICATION_WORKER: &str = "server.notification";

/// `serve_connection_authed` for a unix socket peer named by its audit token: the
/// connection's body runs under the hub's supervisor, and this returns once it ended.
pub(super) async fn serve_connection_from(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
    device: Option<String>,
) {
    let supervisor = hub.supervisor().clone();
    let serve = Box::pin(serve_connection_body(hub, inbound, out, origin, auth, peer, device));
    let served = crate::supervised::call(
        &supervisor,
        CONNECTION_WORKER,
        Fatal,
        ShutdownBehavior::Skip,
        serve,
    )
    .await;
    if let Err(error) = served {
        tracing::warn!("a client connection was not served: {error}");
    }
}

/// The handler of `conn`'s notifications: each runs under the hub's supervisor as
/// `Fatal` (a cancel ends a turn). A handler dropped at its deadline stops with it.
pub(super) fn notification_handler(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
) -> impl Fn(String, Value) -> BoxFuture<'static, ()> + Clone + Send + 'static {
    let (hub, conn) = (hub.clone(), conn.clone());
    move |method: String, params: Value| {
        let supervisor = hub.supervisor().clone();
        let (hub, conn) = (hub.clone(), conn.clone());
        Box::pin(async move {
            // An agent tool server's notifications are MCP (`agent_mcp.rs`): nothing to do.
            let handle = Box::pin(async move {
                if conn.agent_tools().is_none() {
                    handle_notification(&hub, &conn, &method, params).await
                }
            });
            let handled = crate::supervised::call(
                &supervisor,
                NOTIFICATION_WORKER,
                Fatal,
                ShutdownBehavior::Skip,
                handle,
            )
            .await;
            if let Err(error) = handled {
                tracing::warn!("a client notification was not handled: {error}");
            }
        })
    }
}

impl Conn {
    /// A new connection's state, sending on `out`.
    pub(super) fn new(
        origin: Origin,
        auth: ConnAuth,
        device: Option<String>,
        peer: Option<cmux_link::app_caller::PeerToken>,
        out: mpsc::Sender<String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::now_v7().to_string(),
            origin,
            auth,
            device,
            raw_text: !peer_text::masks(origin),
            name: StdMutex::new(String::new()),
            out,
            outbound_lock: Arc::new(StdMutex::new(())),
            outbound_dropped: Arc::new(AtomicU64::new(0)),
            outbound_gap_pending: Arc::new(AtomicBool::new(false)),
            outbound_pending_controls: Arc::new(AtomicUsize::new(0)),
            subs: StdMutex::new(Default::default()),
            mailbox_bindings: StdMutex::new(Default::default()),
            watch_all: AtomicBool::new(false),
            watch_inventory: StdMutex::new(false),
            peer,
            requests: std::sync::atomic::AtomicU64::new(0),
            challenged: AtomicBool::new(false),
            nonce: crate::hub::person::new_nonce(),
            person: AtomicBool::new(false),
            holds_calls: std::sync::atomic::AtomicU32::new(0),
            caller: std::sync::OnceLock::new(),
            unproven_caller: std::sync::OnceLock::new(),
            agent_tools: std::sync::OnceLock::new(),
            peer_leases: StdMutex::new(Some(Vec::new())),
            ephemeral: StdMutex::new(Some(Vec::new())),
            ended: tokio::sync::watch::Sender::new(false),
            // A peer daemon's link carries all its clients' reads, which it caps one by one
            // (`media_forward.rs`).
            media: if auth == ConnAuth::PeerToken {
                crate::hub::media_handles::Handles::for_peer_link()
            } else {
                crate::hub::media_handles::Handles::default()
            },
            remote_media: super::media_forward::RemoteMedia::default(),
            memory_vote: std::sync::OnceLock::new(),
        }
    }
}

#[cfg(test)]
#[path = "connection_task_tests.rs"]
mod tests;
