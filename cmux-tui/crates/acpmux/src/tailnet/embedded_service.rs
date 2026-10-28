//! Event-driven lifecycle for the opt-in tailnet listener. One service owns
//! every listener task; loss of node identity drains it before a replacement.

use std::sync::Arc;
use std::time::Duration;

use cmux_tailnet::Node;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::embedded::Controller;
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
    node: Arc<Node>,
    name: String,
    stop: watch::Sender<bool>,
    task: JoinHandle<anyhow::Result<()>>,
}

impl Active {
    fn matches(&self, node: &Arc<Node>, name: &str) -> bool {
        Arc::ptr_eq(&self.node, node) && self.name == name
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
        if resume_controller.resume().await.is_err() {
            resume_controller.note_listener_error();
        }
    });
    let mut active: Option<Active> = None;
    loop {
        if *stopping.borrow() {
            break;
        }
        let snapshot = controller.snapshot();
        let desired =
            snapshot.running().then(|| controller.node().zip(snapshot.dns_name)).flatten();
        let unchanged = match (&active, &desired) {
            (Some(active), Some((node, name))) => active.matches(node, name),
            (None, None) => true,
            _ => false,
        };
        if !unchanged {
            if let Some(old) = active.take() {
                old.stop().await;
            }
            // Draining yields; logout or a rename may have replaced `desired`.
            let latest = controller.snapshot();
            let desired =
                latest.running().then(|| controller.node().zip(latest.dns_name)).flatten();
            if !*stopping.borrow()
                && let Some((node, name)) = desired
            {
                let (stop, stopping) = watch::channel(false);
                let task = tokio::spawn(crate::server::tailnet_ingress::serve(
                    hub.clone(),
                    node.clone(),
                    name.clone(),
                    stopping,
                ));
                active = Some(Active { node, name, stop, task });
            }
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
                    let _ = tokio::time::timeout(NODE_CLOSE_BOUND,
                        controller.listener_failed(&failed.node)).await;
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
    close_node(&controller).await;
}

async fn close_node(controller: &Controller) {
    let _ = tokio::time::timeout(NODE_CLOSE_BOUND, controller.shutdown()).await;
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
