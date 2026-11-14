//! Requests and notifications a peer link sends twice, once on each of two paths, while its
//! active path is in doubt (`peer_dual.rs` on the sending side). Both copies carry the same
//! `_meta.acpmux.dualId`: the first copy to arrive runs, and a repeat on the other connection
//! is answered with the first one's answer, so the request runs once whichever path delivered
//! it. A repeated notification is dropped.
//!
//! Who may use it, and what it serves:
//! - Only a peer daemon's own link (the WebSocket listener's `PeerToken` connections) carries a
//!   `dualId`; on any other connection (the Web, a paired machine, an in-process carrier such as
//!   the mesh relay) it is ignored, and the request runs as any other (`Conn::dual_principal`).
//! - Each entry is keyed by that principal and the `dualId`, and bound to the request it was
//!   made for (a digest of its method and params): a repeat is served the cached answer only
//!   when the same principal sends the same request, which was authorized as a whole when its
//!   first copy ran. Anything else runs through the full request path.
//! - Only requests whose effect is not bound to the connection that runs it ([`dual_safe`]):
//!   neither a `session/load` nor an attach, nor a prompt that carries a cloud turn prepared on
//!   one connection or whose caller reads its reply on that connection, nor one forwarded for
//!   another client (`via`). A cancel's own part on each connection (the preparations made
//!   there) runs on both copies (`requests::cancel_on_connection`).
//! - A client's `$/cancel_request` of either copy ([`cancel`], review F1 of #41285) stops the
//!   copy that runs, whichever connection it runs on: that copy answers -32800 on its own
//!   connection, and a copy that arrives later takes that answer and never runs.
//!
//! Bounded: at most [`MOST`] keys, each kept [`KEEP_FOR`] after its answer; the oldest go first.

use crate::rpc::RpcError;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{oneshot, watch};

/// The principal of a peer daemon's own link (`Conn::dual_principal`): its peer token is the
/// proof, and every holder of it is the same principal.
pub(crate) const PEER_LINK: &str = "peerToken";
/// The feature a daemon lists in `initialize` when it takes `dualId`.
pub const FEATURE: &str = "dualSend";
/// The longest `dualId` taken; a longer one is ignored (the request runs as usual).
const MAX_KEY: usize = 128;
/// Keys kept at most.
const MOST: usize = 4096;
/// How long a key is kept after its answer: a repeat comes within one path's lag of the first.
const KEEP_FOR: Duration = Duration::from_secs(120);

/// What the first copy of a request ended with.
#[derive(Debug, Clone)]
pub(super) enum Outcome {
    Answer(Result<Value, RpcError>),
    /// Its answer went out as bytes already (a shared session list, `list_reply.rs`): a repeat
    /// runs the read itself.
    RunAgain,
}

/// Whether this copy runs the request or waits on the first.
pub(super) enum Seen {
    First(First),
    Repeat(watch::Receiver<Option<Outcome>>),
}

/// The first copy's handle: [`First::finish`] publishes its outcome to any repeat.
pub(super) struct First {
    key: Key,
    tx: watch::Sender<Option<Outcome>>,
    /// Fires when a cancel of any copy stops this one ([`cancel`]); taken by the task that
    /// runs it ([`First::take_stop`]).
    stop: Option<oneshot::Receiver<()>>,
}

impl First {
    pub(super) fn finish(self, outcome: Outcome) {
        self.tx.send_replace(Some(outcome));
        if let Some(entry) = book().entries.get_mut(&self.key) {
            entry.done_at = Some(Instant::now());
            entry.stop = None;
        }
    }

    /// What tells the running copy that a cancel of either copy stopped it.
    pub(super) fn take_stop(&mut self) -> Option<oneshot::Receiver<()>> {
        self.stop.take()
    }
}

/// An entry's key: the principal that sent it and its `dualId`.
pub(crate) type Key = (String, String);

struct Entry {
    tx: watch::Sender<Option<Outcome>>,
    /// The request it was made for (`digest`): a repeat must be the same request.
    digest: u64,
    done_at: Option<Instant>,
    /// Copies that arrived under this key.
    copies: u32,
    /// Stops the first copy while it runs ([`cancel`]); gone once it finished.
    stop: Option<oneshot::Sender<()>>,
}

#[derive(Default)]
struct Book {
    entries: HashMap<Key, Entry>,
    order: VecDeque<Key>,
}

static BOOK: LazyLock<Mutex<Book>> = LazyLock::new(Default::default);

fn book() -> std::sync::MutexGuard<'static, Book> {
    BOOK.lock().unwrap_or_else(|e| e.into_inner())
}

/// The methods a peer link sends on two paths: each runs once whichever copy came first, and
/// none has an effect bound to the connection that ran it. A `session/load`, an attach or a
/// subscription replays or subscribes on its own connection: the copy that lost would get the
/// first one's answer with nothing streamed to it, so those go only on the link's chosen path
/// (`peer_dual.rs`), and a `dualId` on one is ignored here.
pub const METHODS: [&str; 4] = [
    crate::rpc::method::SESSION_PROMPT,
    crate::rpc::method::SESSION_CANCEL,
    crate::rpc::method::MUX_WAIT,
    crate::rpc::method::MUX_STATS,
];

/// Whether request or notification `method` with `params` may go on two paths: on the list
/// ([`METHODS`]), and with nothing in it bound to the connection that runs it. The sender
/// (`peer_dual.rs`) and this daemon decide by the same rule, so what is copied is what is
/// deduplicated.
pub fn dual_safe(method: &str, params: &Value) -> bool {
    if !METHODS.contains(&method) {
        return false;
    }
    let mux = params.pointer("/_meta/acpmux");
    // Forwarded for another client (the Web, a paired machine): held to that client's rules,
    // which are not the link's.
    if mux.and_then(|m| m.get("via")).is_some() {
        return false;
    }
    if method == crate::rpc::method::SESSION_PROMPT {
        // A cloud turn is prepared on one connection and runs only there (`validate_prepared`).
        if params.get("cloud_turn").is_some() {
            return false;
        }
        // Its caller reads the reply on the connection it asked on (`lane_report_reads.rs`).
        let reads_reply = crate::cli::output::READS_REPLY_META;
        if mux.and_then(|m| m.get(reads_reply)).and_then(Value::as_bool) == Some(true) {
            return false;
        }
    }
    true
}

/// The book's key and digest for a request or notification `method` that `principal` sent
/// with `params`: None when the connection may not use a `dualId`, the request may not go on
/// two paths ([`dual_safe`]), or it has no usable `dualId`.
pub(crate) fn key_for(
    principal: Option<&str>,
    method: &str,
    params: Option<&Value>,
) -> Option<(Key, u64)> {
    let principal = principal?;
    let params = params?;
    if !dual_safe(method, params) {
        return None;
    }
    let key = key_of(Some(params))?;
    Some(((principal.to_owned(), key), digest(method, params)))
}

/// What a request is, without its `dualId`: both copies of one have the same.
fn digest(method: &str, params: &Value) -> u64 {
    let mut params = params.clone();
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("dualId");
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    method.hash(&mut hasher);
    params.to_string().hash(&mut hasher);
    hasher.finish()
}

/// The `dualId` of a request's or notification's params, if it has a usable one.
pub(super) fn key_of(params: Option<&Value>) -> Option<String> {
    let key = params?.pointer("/_meta/acpmux/dualId")?.as_str()?;
    (!key.is_empty() && key.len() <= MAX_KEY).then(|| key.to_owned())
}

impl Book {
    fn prune(&mut self, now: Instant) {
        while let Some(oldest) = self.order.front() {
            let expired = self.entries.get(oldest).is_none_or(|entry| {
                entry.done_at.is_some_and(|at| now.duration_since(at) > KEEP_FOR)
            });
            if !expired && self.order.len() <= MOST {
                break;
            }
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            }
        }
    }
}

impl Book {
    /// None for a key known for another request: it runs as any request does.
    fn admit(&mut self, key: Key, digest: u64, now: Instant) -> Option<Seen> {
        self.prune(now);
        if let Some(entry) = self.entries.get_mut(&key) {
            if entry.digest != digest {
                return None;
            }
            entry.copies = entry.copies.saturating_add(1);
            return Some(Seen::Repeat(entry.tx.subscribe()));
        }
        let tx = watch::Sender::new(None);
        let (stop, stopped) = oneshot::channel();
        let entry = Entry { tx: tx.clone(), digest, done_at: None, copies: 1, stop: Some(stop) };
        self.entries.insert(key.clone(), entry);
        self.order.push_back(key.clone());
        Some(Seen::First(First { key, tx, stop: Some(stopped) }))
    }
}

/// A request with key and digest `seen` ([`key_for`]) arrived: the first copy runs it, a
/// repeat waits on the first. None: it runs as any request does.
pub(super) fn admit((key, digest): (Key, u64)) -> Option<Seen> {
    book().admit(key, digest, Instant::now())
}

/// The client cancelled a copy of request `key` (`$/cancel_request` on the connection it came
/// on): the copy that runs stops, on whichever connection, and answers -32800 there; a copy
/// that arrives later takes that answer (review F1 of #41285). True when one was running.
pub(super) fn cancel(key: &Key) -> bool {
    let stop = book().entries.get_mut(key).and_then(|entry| entry.stop.take());
    stop.is_some_and(|stop| stop.send(()).is_ok())
}

/// A notification with key and digest `seen` arrived: false for a repeat only.
pub(super) fn first_notification(seen: (Key, u64)) -> bool {
    match admit(seen) {
        Some(Seen::First(first)) => {
            first.finish(Outcome::RunAgain);
            true
        }
        Some(Seen::Repeat(_)) => false,
        None => true,
    }
}

/// A repeat's answer: the first copy's, once it has one. None when the first was dropped
/// (its key evicted before it answered) or answered as bytes: the repeat runs the request.
pub(super) async fn first_answer(
    mut first: watch::Receiver<Option<Outcome>>,
) -> Option<Result<Value, RpcError>> {
    let outcome = first.wait_for(Option::is_some).await.ok()?.clone()?;
    match outcome {
        Outcome::Answer(answer) => Some(answer),
        Outcome::RunAgain => None,
    }
}

/// Before a request runs: Ok with the handle of the first copy (None without a dual id) to run
/// it, or Err with the first copy's answer for a repeat to send as is.
pub(super) async fn before_run(
    dual: Option<Seen>,
) -> Result<Option<First>, Result<Value, RpcError>> {
    match dual {
        Some(Seen::Repeat(first)) => match first_answer(first).await {
            Some(answer) => Err(answer),
            None => Ok(None),
        },
        Some(Seen::First(first)) => Ok(Some(first)),
        None => Ok(None),
    }
}

/// The first copy answered `answer`, or None when its answer went out as bytes.
pub(super) fn finish(first: Option<First>, answer: Option<&Result<Value, RpcError>>) {
    if let Some(first) = first {
        first.finish(answer.map_or(Outcome::RunAgain, |a| Outcome::Answer(a.clone())));
    }
}

/// The reply to request `id` that answered `answer`.
pub(super) fn reply(id: Value, answer: Result<Value, RpcError>) -> crate::rpc::Message {
    match answer {
        Ok(v) => crate::rpc::Message::ok(id, v),
        Err(e) => crate::rpc::Message::err(id, e),
    }
}

#[cfg(test)]
mod tests;
