//! A list op runs once per `opId` (`op-once-v1`). A phone on a lossy link resends
//! `_acpmux/archive` or `_acpmux/rename` when its reply is lost; each resend runs again: a
//! rename takes new `listSeq`s (every watcher reads the row again), and an archive resent after
//! an unarchive archives again. With an `opId`, a repeat answers the first run's result and
//! writes nothing.
//!
//! The ids are a bounded LRU of the most recent [`OP_ONCE_MOST`]: a retry comes within seconds,
//! so an id older than that many ops runs again, as before this existed. Only a success is kept:
//! an error, or a run dropped mid-way, leaves the id free to run again. The same id with other
//! params is a client bug, refused (`op_id.reused`), never answered with another op's result.
//! A request with no `opId` runs as before.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::sync::{Arc, Mutex as StdMutex};

use serde_json::{Value, json};

use crate::rpc::RpcError;

/// The `initialize` capability of a daemon that runs a list op once per `opId`.
pub const CAPABILITY: &str = "op-once-v1";

/// The recent op ids kept, across every method.
pub(crate) const OP_ONCE_MOST: usize = 1024;

/// The longest `opId` read: a longer one is refused, so no client grows the table.
const OP_ID_MOST: usize = 128;

/// One op: its params (less `opId`) and, once it succeeded, its result.
type Slot = Arc<tokio::sync::Mutex<Option<(String, Value)>>>;

#[derive(Default)]
struct Recent {
    /// Each id's slot and the touch that placed it last in `order`.
    slots: HashMap<String, (u64, Slot)>,
    /// Touches oldest first; one whose number is not its id's latest is stale and skipped.
    order: VecDeque<(u64, String)>,
    touch: u64,
}

impl Recent {
    fn slot(&mut self, key: String) -> Slot {
        self.touch += 1;
        let touch = self.touch;
        let slot = match self.slots.get_mut(&key) {
            Some((at, slot)) => {
                *at = touch;
                slot.clone()
            }
            None => {
                let slot = Slot::default();
                self.slots.insert(key.clone(), (touch, slot.clone()));
                slot
            }
        };
        self.order.push_back((touch, key));
        while self.slots.len() > OP_ONCE_MOST {
            let Some((at, key)) = self.order.pop_front() else { break };
            if self.slots.get(&key).is_some_and(|(latest, _)| *latest == at) {
                self.slots.remove(&key);
            }
        }
        // Stale touches of ids touched again: bounded to a constant times the table.
        if self.order.len() > OP_ONCE_MOST * 4 {
            let slots = &self.slots;
            self.order.retain(|(at, key)| slots.get(key).is_some_and(|(latest, _)| latest == at));
        }
        slot
    }
}

/// The recent ops of one daemon run (`Hub::op_once`).
#[derive(Default)]
pub(crate) struct OpOnce {
    recent: StdMutex<Recent>,
    /// Repeats answered from a kept result (tests and counters).
    repeats: std::sync::atomic::AtomicU64,
}

impl OpOnce {
    /// `run` once per `params.opId` of `method`: a repeat with the same params answers the first
    /// success. Concurrent repeats wait for the first, so two never both write.
    pub(crate) async fn run<F, Fut>(
        &self,
        method: &str,
        params: &Value,
        run: F,
    ) -> Result<Value, RpcError>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Value, RpcError>>,
    {
        let Some(op_id) = op_id(params)? else { return run().await };
        let slot = self
            .recent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .slot(format!("{method}\0{op_id}"));
        let fingerprint = fingerprint(params);
        let mut kept = slot.lock().await;
        if let Some((first, result)) = kept.as_ref() {
            if *first != fingerprint {
                return Err(RpcError::invalid_params(
                    "opId names an earlier op with other params: send a new opId for a new op",
                )
                .with_data(json!({"reason": "op_id.reused"})));
            }
            self.repeats.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            return Ok(result.clone());
        }
        let result = run().await?;
        *kept = Some((fingerprint, result.clone()));
        Ok(result)
    }

    #[cfg(test)]
    pub(crate) fn repeats(&self) -> u64 {
        self.repeats.load(std::sync::atomic::Ordering::Relaxed)
    }
}

/// The request's `opId`: absent (or null) runs as before; anything but a short non-empty string
/// is refused.
fn op_id(params: &Value) -> Result<Option<&str>, RpcError> {
    match params.get("opId") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(id)) if !id.is_empty() && id.len() <= OP_ID_MOST => Ok(Some(id)),
        Some(_) => Err(RpcError::invalid_params(format!(
            "opId must be a non-empty string of at most {OP_ID_MOST} bytes"
        ))
        .with_data(json!({"reason": "op_id.invalid"}))),
    }
}

/// What a repeat must match: the params less `opId` and `_meta` (a resend may carry another
/// trace or deadline).
fn fingerprint(params: &Value) -> String {
    let Some(map) = params.as_object() else { return params.to_string() };
    let mut keys: Vec<&String> =
        map.keys().filter(|k| k.as_str() != "opId" && k.as_str() != "_meta").collect();
    keys.sort();
    let mut out = String::new();
    for key in keys {
        out.push_str(key);
        out.push('\0');
        out.push_str(&map[key].to_string());
        out.push('\0');
    }
    out
}

#[cfg(test)]
#[path = "op_once_tests.rs"]
mod tests;
