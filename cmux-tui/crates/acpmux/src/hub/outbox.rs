//! Part of `Hub`; see `hub/mod.rs`. Messages `acpmux send --no-wait` hands to this daemon to
//! deliver (the transport, `server/outbox.rs`), and the peer acceptances a forwarded prompt waits
//! for.
//!
//! A sender gets its delivery id as soon as the message is recorded here, whatever the target: a
//! session on this daemon or on a peer behind ssh, connected or not. The daemon then delivers it
//! in the background, retrying with the same prompt id, so a target that already took it answers
//! with the first outcome instead of running it twice. Each delivery is `queued`, `delivering`
//! (attempt n), `delivered` (the target's acceptance: its session, turn and whether it steered),
//! `held` (the runaway guard holds it until the person resumes the pair, `agent_pairs.rs`) or
//! `failed` (the last error). The record is saved in `outbox.json` beside the sessions on
//! every change, so a daemon restart goes on with what was not delivered yet; a store in memory
//! keeps it in memory. Settled deliveries are kept for [`KEEP_SETTLED_MS`].
//!
//! A peer answers a forwarded `session/prompt` only when its turn ends (or, for a steer, when the
//! agent's step ends), so the forwarding daemon passes the peer's `_acpmux/prompt_accepted` on to
//! the connection that sent the prompt as soon as it arrives ([`PeerAccepts`]).

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Notify;

use crate::rpc::RpcError;

/// How long a delivered or failed message stays readable by `send --status`.
pub const KEEP_SETTLED_MS: u64 = 24 * 60 * 60 * 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Queued,
    Delivering,
    Delivered,
    /// The target's daemon holds it for a paused agent pair: it runs when the person resumes the
    /// pair, never by a retry here.
    Held,
    Failed,
}

/// One message to deliver.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Delivery {
    pub id: String,
    /// The session key the sender named (`NAME`, an id, or `PEER/NAME`).
    pub target: String,
    /// The `session/prompt` params to send, `sessionId` = `target`; its prompt id is the
    /// delivery's idempotency key.
    pub request: Value,
    /// The session the sender's connection proved it runs in, sent again as the caller.
    #[serde(default)]
    pub caller: Option<String>,
    pub state: State,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default)]
    pub error: Option<String>,
    /// The target's `_acpmux/prompt_accepted` (or its reply) once delivered.
    #[serde(default)]
    pub accepted: Option<Value>,
    pub created_at: u64,
    pub updated_at: u64,
}

impl Delivery {
    pub fn prompt_id(&self) -> &str {
        self.request.pointer("/_meta/acpmux/promptId").and_then(Value::as_str).unwrap_or_default()
    }

    pub fn settled(&self) -> bool {
        matches!(self.state, State::Delivered | State::Held | State::Failed)
    }

    /// What `_acpmux/send_status` answers.
    pub fn status(&self) -> Value {
        json!({
            "deliveryId": self.id,
            "target": self.target,
            "promptId": self.prompt_id(),
            "status": self.state,
            "attempts": self.attempts,
            "error": self.error,
            "accepted": self.accepted,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
        })
    }
}

/// The deliveries, saved at `path` when the store is on disk.
#[derive(Default)]
pub struct Outbox {
    deliveries: StdMutex<BTreeMap<String, Delivery>>,
    path: StdMutex<Option<PathBuf>>,
    /// Fired on every change: a `send_status` that waits wakes.
    pub changed: Notify,
}

impl Outbox {
    /// Reads the saved deliveries at `path` and saves there from now on. Returns the ones not
    /// settled, to deliver again. A file that cannot be read starts empty (and is replaced).
    pub fn open(&self, path: &Path) -> Vec<Delivery> {
        let saved: BTreeMap<String, Delivery> = match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::warn!("outbox: {} cannot be read, starting empty: {e}", path.display());
                BTreeMap::new()
            }),
            Err(_) => BTreeMap::new(),
        };
        *self.path.lock().unwrap_or_else(|e| e.into_inner()) = Some(path.to_owned());
        let mut deliveries = self.deliveries.lock().unwrap_or_else(|e| e.into_inner());
        deliveries.extend(saved);
        // Attachments come back from beside the file; ones no waiting delivery names go.
        let dir = attachments_dir(path);
        let mut named = std::collections::HashSet::new();
        for d in deliveries.values_mut().filter(|d| !d.settled()) {
            let kept = dir.join(format!("{}.json", d.id));
            if let Some(request) = std::fs::read(&kept).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
                d.request = request;
                named.insert(kept);
            }
        }
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            if !named.contains(&entry.path()) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        deliveries.values().filter(|d| !d.settled()).cloned().collect()
    }

    /// Where delivery `d`'s attachments are kept, when it has any and the outbox is on disk.
    pub fn attachments_path(&self, d: &Delivery) -> Option<PathBuf> {
        let blocks = d.request.get("prompt").and_then(Value::as_array)?;
        let path = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        crate::attach::any(blocks).then(|| attachments_dir(&path).join(format!("{}.json", d.id)))
    }

    /// Records a new delivery; the same prompt id again answers with the first one.
    pub fn add(&self, delivery: Delivery) -> Delivery {
        let mut deliveries = self.deliveries.lock().unwrap_or_else(|e| e.into_inner());
        let prompt_id = delivery.prompt_id().to_owned();
        if let Some(first) = deliveries.values().find(|d| d.prompt_id() == prompt_id) {
            return first.clone();
        }
        deliveries.insert(delivery.id.clone(), delivery.clone());
        self.save(&mut deliveries);
        drop(deliveries);
        self.changed.notify_waiters();
        delivery
    }

    pub fn get(&self, id: &str) -> Option<Delivery> {
        self.deliveries.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    /// Changes delivery `id` with `f` and saves.
    pub fn update(&self, id: &str, f: impl FnOnce(&mut Delivery)) {
        let mut deliveries = self.deliveries.lock().unwrap_or_else(|e| e.into_inner());
        let Some(d) = deliveries.get_mut(id) else { return };
        f(d);
        d.updated_at = crate::store::now_ms();
        self.save(&mut deliveries);
        drop(deliveries);
        self.changed.notify_waiters();
    }

    /// Drops what settled long ago, then writes the file (when there is one).
    fn save(&self, deliveries: &mut BTreeMap<String, Delivery>) {
        let now = crate::store::now_ms();
        deliveries
            .retain(|_, d| !d.settled() || now.saturating_sub(d.updated_at) < KEEP_SETTLED_MS);
        let Some(path) = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return;
        };
        // Attachment bytes are kept once beside the file (`keep_attachments`), not rewritten here.
        let saved: BTreeMap<&String, std::borrow::Cow<Delivery>> = deliveries
            .iter()
            .map(|(id, d)| {
                let blocks = d.request.get("prompt").and_then(Value::as_array);
                if !blocks.is_some_and(|b| crate::attach::any(b)) {
                    return (id, std::borrow::Cow::Borrowed(d));
                }
                let mut d = d.clone();
                crate::attach::strip(&mut d.request);
                (id, std::borrow::Cow::Owned(d))
            })
            .collect();
        let written = serde_json::to_vec_pretty(&saved)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| crate::config::write_atomic(&path, &bytes));
        if let Err(e) = written {
            tracing::warn!("outbox: could not save {}: {e:#}", path.display());
        }
    }
}

/// The folder beside `outbox.json` (at `path`) that keeps waiting deliveries' attachments.
fn attachments_dir(path: &Path) -> PathBuf {
    path.with_file_name("outbox-attachments")
}

/// Keeps `request` (with its attachment bytes) at `path`, owner-only. Blocking.
pub fn keep_attachments(path: &Path, request: &Value) -> anyhow::Result<()> {
    crate::agent_tools::write_private(path, &serde_json::to_vec(request)?)
}

type AcceptHook = Box<dyn FnOnce(Value) + Send>;

/// Prompts forwarded to a peer that wait for the peer's acceptance, by peer and prompt id. Two
/// forwards of one id (a retry while the first still waits) each get theirs.
#[derive(Default)]
pub struct PeerAccepts {
    hooks: StdMutex<HashMap<(String, String), Vec<(u64, AcceptHook)>>>,
    next: std::sync::atomic::AtomicU64,
}

impl PeerAccepts {
    /// Calls `hook` with peer `peer`'s `_acpmux/prompt_accepted` for `prompt_id`, once. Returns
    /// the wait's token for [`Self::forget`].
    pub fn wait(&self, peer: &str, prompt_id: &str, hook: AcceptHook) -> u64 {
        let token = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let key = (peer.to_owned(), prompt_id.to_owned());
        self.hooks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(key)
            .or_default()
            .push((token, hook));
        token
    }

    /// The forwarded prompt answered: this wait no longer listens.
    pub fn forget(&self, peer: &str, prompt_id: &str, token: u64) {
        let mut hooks = self.hooks.lock().unwrap_or_else(|e| e.into_inner());
        let key = (peer.to_owned(), prompt_id.to_owned());
        if let Some(waits) = hooks.get_mut(&key) {
            waits.retain(|(t, _)| *t != token);
            if waits.is_empty() {
                hooks.remove(&key);
            }
        }
    }

    /// Peer `peer`'s `_acpmux/prompt_accepted` arrived: every forward of that id to it hears it.
    pub fn accepted(&self, peer: &str, params: &Value) {
        let Some(prompt_id) = params.get("promptId").and_then(Value::as_str) else { return };
        let key = (peer.to_owned(), prompt_id.to_owned());
        let waits = self.hooks.lock().unwrap_or_else(|e| e.into_inner()).remove(&key);
        for (_, hook) in waits.into_iter().flatten() {
            hook(params.clone());
        }
    }
}

/// The refusal for a `send_queue` from a connection that is not the unix socket.
pub fn local_only() -> RpcError {
    RpcError::invalid_params("only the unix socket queues a message for delivery")
        .with_data(json!({"reason": "outbox.local_only"}))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A waiting delivery's attachments are kept once beside `outbox.json`, which never holds
    /// their bytes; a restart reads them back, and ones nothing names go.
    #[test]
    fn attachments_are_kept_beside_the_file_and_come_back_after_a_restart() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let block = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
        let data = block["data"].as_str().unwrap().to_owned();
        let request = json!({"sessionId": "lane", "prompt": [block],
                             "_meta": {"acpmux": {"promptId": "p1"}}});
        let d = Delivery { id: "d1".into(), target: "lane".into(), request, caller: None,
            state: State::Queued, attempts: 0, error: None, accepted: None,
            created_at: 0, updated_at: crate::store::now_ms() };
        let outbox = Outbox::default();
        outbox.open(&path);
        let kept = outbox.attachments_path(&d).unwrap();
        keep_attachments(&kept, &d.request).unwrap();
        let orphan = kept.with_file_name("gone.json");
        std::fs::write(&orphan, b"{}").unwrap();
        outbox.add(d);
        assert!(!std::fs::read_to_string(&path).unwrap().contains(&data));
        assert_eq!(outbox.get("d1").unwrap().request["prompt"][0]["data"], data);
        let restarted = Outbox::default();
        let pending = restarted.open(&path);
        assert_eq!(pending[0].request["prompt"][0]["data"], data);
        assert!(kept.exists() && !orphan.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
