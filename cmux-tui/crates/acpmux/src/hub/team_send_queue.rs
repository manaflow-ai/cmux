//! Durable FIFO queue for `team_send` while the mesh hub is unavailable.
//!
//! Team messages are hub deliveries, so they must not enter the local prompt outbox. This small
//! queue keeps the original wire message and retries its head when a heartbeat proves the hub is
//! reachable again. A transient error leaves the head in place; a hub refusal settles and removes
//! it so a permanent recipient error cannot spin forever.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

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
            let item = {
                self.state
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .pending
                    .front()
                    .cloned()
            };
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
                            tracing::warn!("team send queue: could not persist delivery: {error:#}");
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
                            tracing::warn!("team send queue: could not persist refusal: {persist_error:#}");
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
                    if let Some(front) = state.pending.front_mut().filter(|front| front.id == item.id) {
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

