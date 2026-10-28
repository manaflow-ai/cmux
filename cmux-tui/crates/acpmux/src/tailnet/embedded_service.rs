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

pub(crate) struct Service {
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
    controller: Arc<Controller>,
}

impl Service {
    pub(crate) fn spawn(hub: Arc<Hub>) -> Self {
        let (stop, stopping) = watch::channel(false);
        let controller = hub.tailnet_controller();
        let task = tokio::spawn(run(hub, stopping));
        Self { stop, task, controller }
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

async fn run(hub: Arc<Hub>, mut stopping: watch::Receiver<bool>) {
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
        let snapshot = controller.snapshot();
        let desired = if controller.retirement_pending() {
            None
        } else {
            snapshot.running().then(|| controller.node().zip(snapshot.dns_name)).flatten()
        };
        let unchanged = match (&active, &desired) {
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
            let desired =
                latest.running().then(|| controller.node().zip(latest.dns_name)).flatten();
            if !*stopping.borrow() {
                if let Some((node, name)) = desired {
                    let (stop, stopping) = watch::channel(false);
                    let task = tokio::spawn(crate::server::tailnet_ingress::serve(
                        hub.clone(),
                        node.clone(),
                        name.clone(),
                        stopping,
                    ));
                    active = Some(Active { node: Some(node), name, stop, task });
                }
            } else if let Some((node, _)) = desired {
                release_node(node);
            }
        } else if let Some((node, _)) = desired {
            // The active listener already owns its identity. Release this
            // comparison-only clone away from the Tokio worker.
            release_node(node);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tailnet_service_bounds_and_joins_stalled_listener_cleanup() {
        let (dropped, notice) = tokio::sync::oneshot::channel();
        struct OnDrop(Option<tokio::sync::oneshot::Sender<()>>);
        impl Drop for OnDrop {
            fn drop(&mut self) {
                let _ = self.0.take().unwrap().send(());
            }
        }
        let guard = OnDrop(Some(dropped));
        let mut task = tokio::spawn(async move {
            let _guard = guard;
            std::future::pending::<()>().await;
        });
        drain(&mut task, Duration::from_millis(1)).await;
        assert!(task.is_finished());
        assert!(notice.await.is_ok());
    }
}
