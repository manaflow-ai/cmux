//! Durable FIFO queue for `team_send` while the mesh hub is unavailable.
//!
//! Team messages are hub deliveries, so they must not enter the local prompt outbox. This small
//! queue keeps the original wire message and retries its head when a heartbeat proves the hub is
//! reachable again. A transient error leaves the head in place; a hub refusal settles and removes
//! it so a permanent recipient error cannot spin forever.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::mesh::{MeshHub, OutMessage, Receipt};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct QueuedTeamSend {
    pub(crate) id: String,
    pub(crate) message: OutMessage,
    pub(crate) address: String,
    #[serde(default)]
    pub(crate) caller: Option<String>,
    pub(crate) receipt: Receipt,
}

#[derive(Default)]
struct State {
    path: Option<PathBuf>,
    pending: VecDeque<QueuedTeamSend>,
}

/// A persisted FIFO queue. The mutex is intentionally synchronous: mutations are tiny and the
/// daemon calls the disk-backed methods from its blocking pool when handling a client request.
#[derive(Default)]
pub(crate) struct TeamSendQueue {
    state: Mutex<State>,
    flushing: tokio::sync::Mutex<()>,
}

impl TeamSendQueue {
    /// Opens the queue file. A missing or malformed file starts empty and is replaced on the next
    /// enqueue; a malformed queue must not prevent the daemon from serving local sessions.
    pub(crate) fn open(&self, path: &Path) {
        let pending = std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<VecDeque<QueuedTeamSend>>(&bytes).ok())
            .unwrap_or_default();
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.path = Some(path.to_owned());
        state.pending = pending;
    }

    /// Adds one message, or returns the existing item for the same sender and idempotency key.
    pub(crate) fn enqueue(
        &self,
        message: OutMessage,
        address: String,
        caller: Option<String>,
    ) -> anyhow::Result<Receipt> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = state.pending.iter().find(|entry| {
            entry.message.idempotency_key == message.idempotency_key
                && entry.caller == caller
                && entry.address == address
        }) {
            return Ok(existing.receipt.clone());
        }
        let id = format!("teamq:{}", uuid::Uuid::now_v7());
        let now = crate::store::now_ms();
        let receipt = Receipt {
            message_id: id.clone(),
            state: "queued".into(),
            to: message.to.clone(),
            attempt: 0,
            prompt_id: None,
            detail: Some("the mesh hub is unavailable; queued for reconnect".into()),
            created_at: now,
            leased_until: None,
            acked_at: None,
            delivered_at: None,
            read_at: None,
            read_by: None,
            acked_by: None,
            resolution: None,
            start_work: None,
            result: None,
        };
        state.pending.push_back(QueuedTeamSend {
            id,
            message,
            address,
            caller,
            receipt: receipt.clone(),
        });
        if let Err(error) = persist(&state) {
            state.pending.pop_back();
            return Err(error);
        }
        Ok(receipt)
    }

    #[cfg(test)]
    pub(crate) fn pending(&self) -> Vec<QueuedTeamSend> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).pending.iter().cloned().collect()
    }

    /// Sends the queue head in order. Returned entries were taken by the hub and should be
    /// recorded in the daemon's team receipt journal by the caller.
    pub(crate) async fn flush(&self, mesh: &dyn MeshHub) -> Vec<(QueuedTeamSend, Receipt)> {
        let _serial = self.flushing.lock().await;
        let mut sent = Vec::new();
        loop {
            let item =
                { self.state.lock().unwrap_or_else(|e| e.into_inner()).pending.front().cloned() };
            let Some(item) = item else { break };
            match mesh.send(&item.message).await {
                Ok(receipt) => {
                    let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                    if state.pending.front().is_some_and(|front| front.id == item.id) {
                        state.pending.pop_front();
                        if let Err(error) = persist(&state) {
                            // Keep the item for an idempotent retry if its removal was not made
                            // durable. The hub's idempotency key prevents a duplicate message.
                            state.pending.push_front(item.clone());
                            tracing::warn!(
                                "team send queue: could not persist delivery: {error:#}"
                            );
                            break;
                        }
                        sent.push((item, receipt));
                    }
                }
                Err(error) if error.refused => {
                    let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                    if state.pending.front().is_some_and(|front| front.id == item.id) {
                        state.pending.pop_front();
                        if let Err(persist_error) = persist(&state) {
                            state.pending.push_front(item.clone());
                            tracing::warn!(
                                "team send queue: could not persist refusal: {persist_error:#}"
                            );
                            break;
                        }
                        let mut receipt = item.receipt;
                        receipt.state = "refused".into();
                        receipt.detail = Some(error.to_string());
                        sent.push((item, receipt));
                    }
                }
                Err(error) => {
                    let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(front) =
                        state.pending.front_mut().filter(|front| front.id == item.id)
                    {
                        front.receipt.detail = Some(error.to_string());
                        let _ = persist(&state);
                    }
                    break;
                }
            }
        }
        sent
    }
}

fn persist(state: &State) -> anyhow::Result<()> {
    let Some(path) = state.path.as_deref() else { return Ok(()) };
    let bytes = serde_json::to_vec_pretty(&state.pending)?;
    crate::config::write_atomic(path, &bytes).map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage};
    use futures::future::BoxFuture;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct FakeMesh {
        bodies: Mutex<Vec<String>>,
        outcomes: Mutex<VecDeque<Result<Receipt, HubError>>>,
    }

    impl MeshHub for FakeMesh {
        fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
            Box::pin(async { Ok(Vec::new()) })
        }

        fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
            Box::pin(async { Ok(()) })
        }

        fn heartbeat<'a>(
            &'a self,
            _: &'a Heartbeat,
        ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
            Box::pin(async { Err(HubError::unavailable("unused in queue test")) })
        }

        fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
            self.bodies.lock().unwrap().push(message.body.clone());
            let outcome = self
                .outcomes
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| Ok(receipt("hub-message", "delivered")));
            Box::pin(async move { outcome })
        }

        fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
            Box::pin(async move { Ok(receipt(id, "delivered")) })
        }
    }

    fn message(body: &str, key: &str) -> OutMessage {
        OutMessage {
            to: crate::mesh::Target {
                team_address: Some("@member/agent".into()),
                ..Default::default()
            },
            from: crate::mesh::Sender::default(),
            kind: crate::mesh::Kind::Prompt,
            op: None,
            body: body.into(),
            mode: crate::mesh::Mode::TurnEnd,
            idempotency_key: key.into(),
        }
    }

    fn receipt(id: &str, state: &str) -> Receipt {
        serde_json::from_value(serde_json::json!({"messageId": id, "state": state})).unwrap()
    }

    #[tokio::test]
    async fn queue_persists_and_flushes_in_fifo_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("team-send-queue.json");
        let queue = TeamSendQueue::default();
        queue.open(&path);
        queue.enqueue(message("first", "one"), "@member/agent".into(), None).unwrap();
        queue.enqueue(message("second", "two"), "@member/agent".into(), None).unwrap();

        let reopened = TeamSendQueue::default();
        reopened.open(&path);
        assert_eq!(
            reopened.pending().iter().map(|item| item.message.body.as_str()).collect::<Vec<_>>(),
            ["first", "second"]
        );

        let mesh = FakeMesh::default();
        let sent = reopened.flush(&mesh).await;
        assert_eq!(mesh.bodies.lock().unwrap().as_slice(), ["first", "second"]);
        assert_eq!(sent.len(), 2);
        assert!(reopened.pending().is_empty());
        let after_restart = TeamSendQueue::default();
        after_restart.open(&path);
        assert!(after_restart.pending().is_empty());
    }

    #[tokio::test]
    async fn transient_failure_keeps_head_and_stops_fifo_flush() {
        let queue = TeamSendQueue::default();
        queue.enqueue(message("first", "one"), "@member/agent".into(), None).unwrap();
        queue.enqueue(message("second", "two"), "@member/agent".into(), None).unwrap();
        let mesh = FakeMesh::default();
        mesh.outcomes.lock().unwrap().push_back(Err(HubError::unavailable("offline")));

        assert!(queue.flush(&mesh).await.is_empty());
        assert_eq!(
            queue.pending().iter().map(|item| item.message.body.as_str()).collect::<Vec<_>>(),
            ["first", "second"]
        );
    }

    #[tokio::test]
    async fn refused_message_is_settled_and_removed() {
        let queue = TeamSendQueue::default();
        queue.enqueue(message("bad", "one"), "@member/agent".into(), None).unwrap();
        let mesh = FakeMesh::default();
        mesh.outcomes.lock().unwrap().push_back(Err(HubError::refused("unknown recipient")));

        let sent = queue.flush(&mesh).await;
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].1.state, "refused");
        assert!(queue.pending().is_empty());
    }
}
