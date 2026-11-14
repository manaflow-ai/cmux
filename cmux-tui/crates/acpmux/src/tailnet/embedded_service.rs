//! Event-driven lifecycle for the opt-in tailnet listener. One service owns
//! every listener task; loss of node identity drains it before a replacement.

use std::sync::Arc;
use std::time::Duration;

use cmux_tailnet::Node;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::embedded::{Controller, release_node};
use crate::hub::Hub;

const DRAIN_BOUND: Duration = Duration::from_secs(2);
const NODE_CLOSE_BOUND: Duration = Duration::from_secs(3);

/// Held by every supervisor action (stop, spawn, failure retirement) and by
/// the shutdown fence. Its value is true once fenced.
type Fence = Arc<tokio::sync::Mutex<bool>>;

pub(crate) struct Service {
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
    controller: Arc<Controller>,
    fenced: Fence,
}

impl Service {
    pub(crate) fn spawn(hub: Arc<Hub>) -> Self {
        let (stop, stopping) = watch::channel(false);
        let controller = hub.tailnet_controller();
        let fenced = Fence::default();
        let task = tokio::spawn(run(hub, stopping, fenced.clone()));
        Self { stop, task, controller, fenced }
    }

    /// Fence supervision before the daemon's WebSocket shutdown: no start,
    /// replacement or listener-failure retirement happens after this, and the
    /// current listener stays up so that shutdown can send its own close (1012
    /// on restart) and drain it. Waits for a supervisor action already under
    /// way (bounded by its drain and close bounds).
    pub(crate) async fn fence(&self) {
        fence(&self.controller, &self.fenced).await;
    }

    pub(crate) async fn shutdown(mut self) {
        self.controller.begin_shutdown();
        self.stop.send_replace(true);
        drain(&mut self.task, DRAIN_BOUND + NODE_CLOSE_BOUND + Duration::from_secs(1)).await;
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        // Covers a daemon error return as well as its normal shutdown path.
        self.controller.begin_shutdown();
        self.stop.send_replace(true);
    }
}

struct Active {
    node: Option<Arc<Node>>,
    name: String,
    stop: watch::Sender<bool>,
    task: JoinHandle<anyhow::Result<()>>,
}

impl Active {
    fn matches(&self, node: &Arc<Node>, name: &str) -> bool {
        self.node.as_ref().is_some_and(|current| Arc::ptr_eq(current, node)) && self.name == name
    }

    async fn stop(mut self) {
        self.stop.send_replace(true);
        drain(&mut self.task, DRAIN_BOUND).await;
    }
}

impl Drop for Active {
    fn drop(&mut self) {
        self.stop.send_replace(true);
        self.task.abort();
        if let Some(node) = self.node.take() {
            release_node(node);
        }
    }
}

async fn drain<T>(task: &mut JoinHandle<T>, bound: Duration) {
    if tokio::time::timeout(bound, &mut *task).await.is_err() {
        task.abort();
        let _ = task.await;
    }
}

async fn fence(controller: &Controller, fenced: &tokio::sync::Mutex<bool>) {
    let mut fenced = fenced.lock().await;
    *fenced = true;
    controller.fence().await;
}

/// One reconciliation of the listener against the controller, serialized
/// with the shutdown fence. Returns false, touching nothing, once fenced.
async fn reconcile(
    controller: &Controller,
    fenced: &tokio::sync::Mutex<bool>,
    active: &mut Option<Active>,
    stopping: &watch::Receiver<bool>,
    spawn: impl FnOnce(Arc<Node>, String) -> Active,
) -> bool {
    let fenced = fenced.lock().await;
    if *fenced || controller.stopping() {
        return false;
    }
    let snapshot = controller.snapshot();
    let desired = if controller.retirement_pending() {
        None
    } else {
        snapshot.running().then(|| controller.node().zip(snapshot.dns_name)).flatten()
    };
    let unchanged = match (&*active, &desired) {
        (Some(active), Some((node, name))) => active.matches(node, name),
        (None, None) => true,
        _ => false,
    };
    if !unchanged {
        // `desired` is only a comparison snapshot. Do not let its Arc be
        // dropped on the Tokio worker while the active listener drains.
        if let Some((node, _)) = desired {
            release_node(node);
        }
        if let Some(old) = active.take() {
            old.stop().await;
        }
        // Draining yields; logout or a rename may have replaced `desired`.
        let latest = controller.snapshot();
        let desired = (!controller.retirement_pending() && latest.running())
            .then(|| controller.node().zip(latest.dns_name))
            .flatten();
        if !*stopping.borrow() {
            if let Some((node, name)) = desired {
                *active = Some(spawn(node, name));
            }
        } else if let Some((node, _)) = desired {
            release_node(node);
        }
    } else if let Some((node, _)) = desired {
        // The active listener already owns its identity. Release this
        // comparison-only clone away from the Tokio worker.
        release_node(node);
    }
    drop(fenced);
    true
}

async fn run(hub: Arc<Hub>, mut stopping: watch::Receiver<bool>, fenced: Fence) {
    let controller = hub.tailnet_controller();
    let mut changes = controller.subscribe();
    let resume_controller = controller.clone();
    let resume = tokio::spawn(async move {
        // Resume publishes its own errors while holding the lifecycle gates.
        // A callback here could overwrite a newer explicit start's snapshot.
        let _ = resume_controller.resume().await;
    });
    let mut active: Option<Active> = None;
    loop {
        if *stopping.borrow() {
            break;
        }
        let spawn = |node: Arc<Node>, name: String| {
            let (stop, stopping) = watch::channel(false);
            let task = tokio::spawn(crate::server::tailnet_ingress::serve(
                hub.clone(),
                node.clone(),
                name.clone(),
                stopping,
            ));
            Active { node: Some(node), name, stop, task }
        };
        if !reconcile(&controller, &fenced, &mut active, &stopping, spawn).await {
            hold_fenced(&mut active, &mut stopping).await;
            break;
        }
        tokio::select! {
            biased;
            _ = stopping.changed() => break,
            _ = async {
                if let Some(active) = active.as_mut() {
                    let _ = (&mut active.task).await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => {
                // A listener that ends after the shutdown fence was closed by
                // the daemon's WebSocket shutdown, not a failure. Holding the
                // fence lock keeps the fence from landing mid-retirement.
                let fence_held = fenced.lock().await;
                if *fence_held || controller.stopping() {
                    drop(active.take());
                    break;
                }
                // A failed listener stays stopped until explicit retry. Do not
                // spin against a port or certificate configuration failure.
                if let Some(failed) = active.take() {
                    let failed_node = failed.node.as_ref().cloned();
                    let _ = tokio::time::timeout(NODE_CLOSE_BOUND, async {
                        if let Some(node) = failed_node
                            && controller.listener_is_current(&node)
                        {
                            controller.listener_failed(&node).await;
                        }
                    }).await;
                }
                drop(fence_held);
            }
            change = changes.recv() => {
                if matches!(change, Err(tokio::sync::broadcast::error::RecvError::Closed)) {
                    break;
                }
                // A lagged receiver also reads the current snapshot next.
            }
        }
    }
    resume.abort();
    let _ = resume.await;
    if let Some(active) = active {
        active.stop().await;
    }
}

/// After the shutdown fence, neither reconcile nor stop the current listener:
/// wait until it ends on its own (the daemon's WebSocket shutdown closes and
/// drains it) or until `Service::shutdown` stops supervision.
async fn hold_fenced(active: &mut Option<Active>, stopping: &mut watch::Receiver<bool>) {
    let finished = match active.as_mut() {
        None => return,
        Some(current) => tokio::select! {
            biased;
            _ = stopping.wait_for(|stopped| *stopped) => false,
            _ = &mut current.task => true,
        },
    };
    if finished {
        // A finished JoinHandle must not be polled again; dropping it is enough.
        drop(active.take());
    }
}

#[cfg(test)]
mod tests;
