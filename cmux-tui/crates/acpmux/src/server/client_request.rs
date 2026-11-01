//! Requests this daemon sends to a client over its own connection, and their answers.
//!
//! acpmux answered clients and never asked them anything until the GitHub broker
//! (`github_broker.rs`): the lane asks the Mac whose link lends it a GitHub login. An answer
//! settles the one request of its id on this connection, and a request fails when its time is
//! up or the connection ends, so nothing waits on a client that is gone.

use super::Conn;
use crate::rpc::{Id, Message, RpcError};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tokio::sync::oneshot;

type Reply = oneshot::Sender<Result<Value, RpcError>>;

/// How many requests may wait on one client at once; past that a request fails at once
/// instead of queueing behind a client that stopped reading.
const WAITING_MAX: usize = 8;

/// One connection's requests waiting on the client, by id.
#[derive(Default)]
pub(crate) struct ClientRequests {
    next: AtomicU64,
    waiting: Mutex<HashMap<String, Reply>>,
    /// Its `initialize` lent this machine a GitHub login (`hub/github_owner.rs`); it counts
    /// from its `_acpmux/watch`.
    pub(crate) lends_github: AtomicBool,
}

impl ClientRequests {
    fn waiting(&self) -> std::sync::MutexGuard<'_, HashMap<String, Reply>> {
        self.waiting.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Conn {
    /// Whether the client is still connected.
    pub(crate) fn is_open(&self) -> bool {
        !*self.ended.borrow()
    }

    /// Ask the client `method` and wait at most `budget` for its answer.
    pub(crate) async fn request_client(
        &self,
        method: &str,
        params: Value,
        budget: std::time::Duration,
    ) -> Result<Value, RpcError> {
        let id = format!("acpmux-{}", self.client_requests.next.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        {
            let mut waiting = self.client_requests.waiting();
            if waiting.len() >= WAITING_MAX {
                return Err(RpcError::new(-32000, "too many requests already wait on that client")
                    .with_data(serde_json::json!({"reason": "client.busy"})));
            }
            waiting.insert(id.clone(), tx);
        }
        let mut ended = self.ended.subscribe();
        let gone = || RpcError::internal("the connection that would answer ended");
        let request = Message::request(Value::String(id.clone()), method, params);
        let reply = if !self.is_open() {
            Err(gone())
        } else if let Err(e) = self.send_request_in_order(&request) {
            Err(e)
        } else {
            tokio::select! {
                reply = rx => reply.unwrap_or_else(|_| Err(gone())),
                _ = ended.wait_for(|ended| *ended) => Err(gone()),
                _ = tokio::time::sleep(budget) => Err(RpcError::internal(format!(
                    "no answer within {}s", budget.as_secs()
                ))),
            }
        };
        self.client_requests.waiting().remove(&id);
        reply
    }

    /// The client answered request `id`.
    pub(super) fn settle_client_request(
        &self,
        id: &Id,
        result: Option<Value>,
        error: Option<RpcError>,
    ) {
        let Some(id) = id.as_str() else { return };
        let tx = self.client_requests.waiting().remove(id);
        if let Some(tx) = tx {
            let _ = tx.send(match error {
                Some(e) => Err(e),
                None => Ok(result.unwrap_or(Value::Null)),
            });
        }
    }
}
