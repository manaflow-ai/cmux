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
//! A change returns once a file that holds it is on disk, unless the write failed: that is
//! logged and the change is only in memory until a later write succeeds, as before. The file is
//! written outside the deliveries lock and changes made while one write runs share the next one
//! (group commit): 60 sends at once used to queue behind 180 whole-file writes and syncs, each up
//! to a second on a busy disk (`design/acpmux-perf.md` in leo-workspace).
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
    deliveries: StdMutex<Book>,
    path: StdMutex<Option<PathBuf>>,
    /// The last change on disk, held while a write runs.
    saved: StdMutex<u64>,
    /// Fired on every change: a `send_status` that waits wakes.
    pub changed: Notify,
}

/// The deliveries and the number of changes made to them.
#[derive(Default)]
struct Book {
    deliveries: BTreeMap<String, Delivery>,
    changes: u64,
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
        let mut book = self.book();
        book.deliveries.extend(saved);
        // Attachments come back from beside the file; ones no waiting delivery names go.
        let dir = attachments_dir(path);
        let mut named = std::collections::HashSet::new();
        for d in book.deliveries.values_mut().filter(|d| !d.settled()) {
            let kept = dir.join(format!("{}.json", d.id));
            if let Some(request) =
                std::fs::read(&kept).ok().and_then(|b| serde_json::from_slice(&b).ok())
            {
                d.request = request;
                named.insert(kept);
            }
        }
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            if !named.contains(&entry.path()) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        book.deliveries.values().filter(|d| !d.settled()).cloned().collect()
    }

    fn book(&self) -> std::sync::MutexGuard<'_, Book> {
        self.deliveries.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Where delivery `d`'s attachments are kept, when it has any and the outbox is on disk.
    pub fn attachments_path(&self, d: &Delivery) -> Option<PathBuf> {
        let blocks = d.request.get("prompt").and_then(Value::as_array)?;
        let path = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        crate::attach::any(blocks).then(|| attachments_dir(&path).join(format!("{}.json", d.id)))
    }

    /// Records a new delivery; the same prompt id again answers with the first one.
    pub fn add(&self, delivery: Delivery) -> Delivery {
        let mut book = self.book();
        let prompt_id = delivery.prompt_id().to_owned();
        if let Some(first) = book.deliveries.values().find(|d| d.prompt_id() == prompt_id) {
            let first = first.clone();
            // The first add may still be writing: answer once the file holds it too.
            let change = book.changes;
            drop(book);
            self.save(change);
            return first;
        }
        book.deliveries.insert(delivery.id.clone(), delivery.clone());
        let change = book.changed();
        drop(book);
        self.save(change);
        self.changed.notify_waiters();
        delivery
    }

    pub fn get(&self, id: &str) -> Option<Delivery> {
        self.book().deliveries.get(id).cloned()
    }

    /// Changes delivery `id` with `f` and saves.
    pub fn update(&self, id: &str, f: impl FnOnce(&mut Delivery)) {
        let mut book = self.book();
        let Some(d) = book.deliveries.get_mut(id) else { return };
        f(d);
        d.updated_at = crate::store::now_ms();
        let change = book.changed();
        drop(book);
        self.save(change);
        self.changed.notify_waiters();
    }

    /// Returns once a file that holds change `change` is on disk, or after logging a failed
    /// write (then nothing is marked saved, so the next change writes everything again). A write
    /// that started after the change covers it, so changes made while one write runs share the
    /// next.
    fn save(&self, change: u64) {
        let Some(path) = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return;
        };
        let mut saved = self.saved.lock().unwrap_or_else(|e| e.into_inner());
        if *saved >= change {
            return;
        }
        let (bytes, newest) = {
            let book = self.book();
            // Attachment bytes are kept once beside the file (`keep_attachments`), not rewritten
            // here.
            let on_disk: BTreeMap<&String, std::borrow::Cow<Delivery>> = book
                .deliveries
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
            (serde_json::to_vec(&on_disk), book.changes)
        };
        let written = bytes
            .map_err(anyhow::Error::from)
            .and_then(|bytes| crate::config::write_atomic(&path, &bytes));
        match written {
            Ok(()) => *saved = newest,
            // Not marked saved: the next change writes again.
            Err(e) => tracing::warn!("outbox: could not save {}: {e:#}", path.display()),
        }
    }
}

impl Book {
    /// Counts a change and drops what settled long ago; returns the change's number.
    fn changed(&mut self) -> u64 {
        let now = crate::store::now_ms();
        self.deliveries
            .retain(|_, d| !d.settled() || now.saturating_sub(d.updated_at) < KEEP_SETTLED_MS);
        self.changes += 1;
        self.changes
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

    fn delivery(n: usize) -> Delivery {
        let now = crate::store::now_ms();
        Delivery {
            id: format!("d-{n}"),
            target: "lane".into(),
            request: json!({"sessionId": "lane", "_meta": {"acpmux": {"promptId": format!("p-{n}")}}}),
            caller: None,
            state: State::Queued,
            attempts: 0,
            error: None,
            accepted: None,
            created_at: now,
            updated_at: now,
        }
    }

    /// Sends from many tasks at once share writes, and the file still holds every one of them
    /// when each `add` returns: a restart delivers all of them.
    #[test]
    fn concurrent_adds_are_all_on_disk_when_they_return() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let outbox = std::sync::Arc::new(Outbox::default());
        assert!(outbox.open(&path).is_empty());
        let threads: Vec<_> = (0..64)
            .map(|n| {
                let outbox = outbox.clone();
                let path = path.clone();
                std::thread::spawn(move || {
                    outbox.add(delivery(n));
                    // What a restart would read right now holds this one.
                    let saved: BTreeMap<String, Delivery> =
                        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                    assert!(saved.contains_key(&format!("d-{n}")), "d-{n} not on disk");
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        outbox.update("d-3", |d| d.state = State::Delivered);
        let restarted = Outbox::default();
        let pending = restarted.open(&path);
        assert_eq!(pending.len(), 63);
        assert_eq!(restarted.get("d-3").map(|d| d.state), Some(State::Delivered));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A retry of a prompt whose first add is still writing answers only once the file holds it.
    #[test]
    fn a_duplicate_add_returns_once_the_first_is_on_disk() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let outbox = std::sync::Arc::new(Outbox::default());
        outbox.open(&path);
        // Hold the write lock as a slow write would, then add: the delivery is in memory only.
        let held = outbox.saved.lock().unwrap();
        let first = {
            let outbox = outbox.clone();
            std::thread::spawn(move || outbox.add(delivery(1)))
        };
        while outbox.get("d-1").is_none() {
            std::thread::yield_now();
        }
        let retry = {
            let outbox = outbox.clone();
            let path = path.clone();
            std::thread::spawn(move || {
                let again = outbox.add(delivery(1));
                let saved: BTreeMap<String, Delivery> =
                    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                (again.id, saved.contains_key("d-1"))
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(!retry.is_finished(), "the retry answered before the first add was on disk");
        drop(held);
        first.join().unwrap();
        assert_eq!(retry.join().unwrap(), ("d-1".to_owned(), true));
        let _ = std::fs::remove_dir_all(&dir);
    }

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
        let d = Delivery {
            id: "d1".into(),
            target: "lane".into(),
            request,
            caller: None,
            state: State::Queued,
            attempts: 0,
            error: None,
            accepted: None,
            created_at: 0,
            updated_at: crate::store::now_ms(),
        };
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
