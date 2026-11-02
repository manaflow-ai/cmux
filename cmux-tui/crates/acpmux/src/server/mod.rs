//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{EventFilter, Hub, HubEvent, VERSION};
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};
use crate::session_identity::SessionReceipt;
use anyhow::{Context, Result};
use cmux_local_auth::{ListenerPolicy, Refusal};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::{Semaphore, broadcast, mpsc};
/// Windows: the daemon socket is `cmux::local_socket` (AF_UNIX with its
/// same-user checks), in `windows_socket.rs`.
#[cfg(windows)]
pub use windows_socket::{UnixListener, bind_unix, router_admin, serve_unix};

mod ws_peek;
mod ws_shutdown;
pub(crate) use ws_shutdown::DRAIN_BUDGET as WS_DRAIN_BUDGET;
pub use ws_shutdown::WsShutdown;

/// How one connection receives one attached session's live records.
#[derive(Debug, Clone, Default)]
pub struct SubOpts {
    /// Every record arrives as `_acpmux/event` (agent notifications nested
    /// in `msg`) instead of `session/update` plus `_acpmux/event`.
    pub event_stream: bool,
    /// With `event_stream`, only records this filter passes are sent.
    pub filter: EventFilter,
    /// Attached without showing the chat (`view.rs`).
    pub hidden: bool,
    /// A peer's chat, attached through this daemon (`peer_forward.rs`): this daemon's presence
    /// for the same raw id is never its (`hub/presence.rs`).
    pub remote: bool,
}

/// Which of one chat's `_acpmux/message` records a connection has heard, so each reaches it once.
/// A record comes live, in seq order (`live`), or from this connection's own `session/load`
/// replay (`replay`), which starts a fresh `MessageNotices`: a reopen hears the history again,
/// but not a record the live stream sent during that replay. A peer's chat replays over the one
/// link every viewer here shares: those records come to every viewer as live ones, so a viewer
/// that heard them already hears them no more; the one that asked starts fresh too
/// (`peer_forward.rs`).
/// Each record by its own seq: a replay's older records may come after a newer live one.
/// Bounded: past `MESSAGE_NOTICES_KEPT` seqs, the lowest is dropped and the low-water mark
/// `floor` rises to it. A live record at or below the mark counts as heard (the live stream
/// comes in seq order, so it sent it). A replay record is checked against the kept seqs alone:
/// one the bound forgot may go a second time, never not at all.
#[derive(Default)]
pub(super) struct MessageNotices {
    heard: std::collections::BTreeSet<u64>,
    floor: u64,
}

/// How many heard seqs one chat's `MessageNotices` keeps above its low-water mark.
pub(super) const MESSAGE_NOTICES_KEPT: usize = 4096;

impl MessageNotices {
    /// The replay's notice of record `seq`: sent unless the live stream sent it and it is still
    /// kept. The mark is not applied: the replay's older records may come after the live stream
    /// raised it, never having been sent.
    pub(super) fn replay(&mut self, seq: u64) -> bool {
        if seq == 0 {
            return true;
        }
        let fresh = self.heard.insert(seq);
        self.bound();
        fresh
    }

    /// The live notice of record `seq`: sent unless this connection heard it. A record of no
    /// known seq (0) is always sent.
    pub(super) fn live(&mut self, seq: u64) -> bool {
        if seq == 0 {
            return true;
        }
        if seq <= self.floor || !self.heard.insert(seq) {
            return false;
        }
        self.bound();
        true
    }

    /// Keeps at most `MESSAGE_NOTICES_KEPT` seqs, raising the mark to the ones it drops.
    fn bound(&mut self) {
        while self.heard.len() > MESSAGE_NOTICES_KEPT {
            if let Some(lowest) = self.heard.pop_first() {
                self.floor = self.floor.max(lowest);
            }
        }
    }

    #[cfg(test)]
    fn kept(&self) -> usize {
        self.heard.len()
    }
}

/// A connection's `MessageNotices`, one per chat it hears: by the chat's owner (None for this
/// daemon, Some(peer) for a peer's chat) and raw id. A peer's chat may keep the raw id of one here
/// (an export and import keeps ids), and each counts its own seqs.
#[derive(Default)]
pub(super) struct MessageNoticeBook {
    chats: HashMap<(Option<String>, String), MessageNotices>,
}

impl MessageNoticeBook {
    /// A fresh count for this connection's own reopen of the chat; one raw id is one owner's chat
    /// on a connection (`view::subscribe_remote`), so the other owner's count ends.
    pub(super) fn reopen(&mut self, owner: Option<&str>, id: &str) {
        self.chats.retain(|(_, i), _| i != id);
        self.chats.insert((owner.map(str::to_owned), id.to_owned()), MessageNotices::default());
    }

    /// `MessageNotices::live` for the chat.
    pub(super) fn live(&mut self, owner: Option<&str>, id: &str, seq: u64) -> bool {
        self.chats.entry((owner.map(str::to_owned), id.to_owned())).or_default().live(seq)
    }

    /// `MessageNotices::replay` for the chat; a chat with no count (none reopened) always sends.
    pub(super) fn replay(&mut self, owner: Option<&str>, id: &str, seq: u64) -> bool {
        self.chats.get_mut(&(owner.map(str::to_owned), id.to_owned())).is_none_or(|n| n.replay(seq))
    }

    /// The connection no longer hears the chat.
    pub(super) fn forget(&mut self, owner: Option<&str>, id: &str) {
        self.chats.remove(&(owner.map(str::to_owned), id.to_owned()));
    }

    /// The connection no longer hears raw id `id` from any owner but `keep`.
    pub(super) fn forget_others(&mut self, keep: Option<&str>, id: &str) {
        self.chats.retain(|(o, i), _| i != id || o.as_deref() == keep);
    }
}

pub struct Conn {
    pub id: String,
    /// The listener this connection came in on.
    pub origin: Origin,
    /// The proof it presented (`conn_auth.rs`); what the mode rule reads.
    pub auth: ConnAuth,
    /// The paired machine whose credential it presented (`ConnAuth::Device`
    /// or `ReadOnlyDevice`), from the handshake only, never from a request.
    device: Option<String>,
    /// It reads session text raw (`peer_text.rs`): every origin but a peer.
    raw_text: bool,
    name: StdMutex<String>,
    out: mpsc::Sender<String>,
    /// True once the client stopped sending (its read side ended): it exited or hung up.
    ended: tokio::sync::watch::Sender<bool>,
    /// Per-session preparation cancellation; no capability or owner token is retained.
    preparation_cancels: StdMutex<HashMap<String, tokio::sync::watch::Sender<bool>>>,
    /// Serializes the capacity check and enqueue across request and watch tasks.
    outbound_lock: Arc<StdMutex<()>>,
    /// Number of notifications rejected because the reader fell behind.
    outbound_dropped: Arc<AtomicU64>,
    /// A gap marker is already queued (or waiting for one queue slot).
    outbound_gap_pending: Arc<AtomicBool>,
    /// Responses waiting for a queue slot; notifications cannot consume these slots.
    outbound_pending_controls: Arc<AtomicUsize>,
    subs: StdMutex<HashMap<String, SubOpts>>,
    /// The chats a `session/load` replayed here: their message notices go once.
    message_notices: StdMutex<MessageNoticeBook>,
    /// Server-derived mailbox identities for this connection's local attachments.
    mailbox_bindings: StdMutex<HashMap<String, SessionReceipt>>,
    watch_all: AtomicBool,
    watch_tools: AtomicBool,
    /// Its pace of full session lists (`hub/list_guard.rs`).
    list_pace: StdMutex<crate::hub::list_guard::Pacer>,
    /// `session_changed` notices queued for it, counted before each is queued
    /// (`list_reply.rs`: a list sent after one must show its change).
    notices: Arc<AtomicU64>,
    watch_inventory: StdMutex<bool>,
    /// The unix socket peer's audit token, read at accept (macOS); what
    /// `_acpmux/person_enroll` checks. None for WebSocket connections.
    peer: Option<cmux_link::app_caller::PeerToken>,
    /// Requests seen so far (`hub/person.rs`: initialize first, the proof second).
    requests: std::sync::atomic::AtomicU64,
    /// Its first request was an `initialize` that got the person challenge.
    challenged: AtomicBool,
    /// This connection's challenge nonce (`hub/person.rs`).
    pub(super) nonce: String,
    /// It proved the person key for its challenge.
    person: AtomicBool,
    /// A Cloud trigger connection is an explicitly scoped principal. It is
    /// never inferred from the local socket and it cannot become a person.
    /// The scope lives only for this connection and is never persisted.
    trigger: StdMutex<Option<TriggerScope>>,
    /// `_acpmux/person_holds` calls on this connection (`hub/person.rs`).
    pub(super) holds_calls: std::sync::atomic::AtomicU32,
    /// The acpmux session it runs in, proven at its first `initialize` (`hub/person.rs` (a)).
    caller: std::sync::OnceLock<String>,
    /// The session a first unix `initialize` named with a token that did not prove it.
    pub(super) unproven_caller: std::sync::OnceLock<String>,
    /// The peers this connection leased (`hub/peer_lease.rs`); None once it
    /// closed, so a lease that settles after the close ends at once.
    peer_leases: StdMutex<Option<Vec<crate::hub::PeerLease>>>,
    /// The ephemeral sessions it created, purged when it closes (`ephemeral.rs`);
    /// None once it closed.
    ephemeral: StdMutex<Option<Vec<String>>>,
    /// The media files it opened (`hub/media_read.rs`), closed when it closes.
    media: crate::hub::media_handles::Handles,
    /// The media files of peers' chats it opened, closed on the peer when it closes
    /// (`media_forward.rs`).
    pub(super) remote_media: media_forward::RemoteMedia,
    /// Requests this daemon sent the client, waiting on its answer (`client_request.rs`).
    client_requests: client_request::ClientRequests,
    /// Its windows over the chat index (`chat_windows.rs`).
    chat_windows: chat_windows::ConnWindows,
    /// Its refused Stops that wait for room (`requests/cancel_refused.rs`).
    cancel_refusals: Arc<requests::cancel_refused::Waiting>,
    /// A WebSocket's compression, which its `initialize` turns on (`frame_compress.rs`); None
    /// on a transport whose writer does not compress.
    wire: Option<Arc<crate::frame_compress::Wire>>,
}

/// The only authority a trigger connection carries after platform admission.
/// Every field is pinned to one machine/chat/delivery; no bearer or owner
/// credential is retained here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TriggerScope {
    pub trigger: String,
    pub owner: String,
    pub team: String,
    pub machine: String,
    pub workspace: String,
    pub session: String,
    pub delivery: String,
    pub prompt_hash: String,
    pub cwd: String,
    pub harness: String,
    pub guest_key: String,
}

// Bound only request handlers that do finite work on behalf of the connection.
// A prompt or wait can remain open for an entire agent turn, so counting it
// here would make unrelated prompts fail after an arbitrary burst of work.
const REQUEST_WORK_LIMIT: usize = 64;
const NOTIFICATION_QUEUE_LIMIT: usize = 16;
const NOTIFICATION_WORK_LIMIT: usize = 16;
const NOTIFICATION_WAIT_LIMIT: usize = 64;
const WORK_BACKPRESSURE_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

fn request_uses_work_budget(method: &str) -> bool {
    !matches!(
        method,
        method::SESSION_NEW
            | method::SESSION_LOAD
            | method::SESSION_RESUME
            | method::SESSION_FORK
            | method::SESSION_PROMPT
            | method::MUX_ATTACH
            | method::MUX_WAIT
    )
}

fn try_request_slot(
    slots: &Arc<Semaphore>,
    method: &str,
) -> Result<Option<tokio::sync::OwnedSemaphorePermit>, ()> {
    if !request_uses_work_budget(method) {
        return Ok(None);
    }
    slots.clone().try_acquire_owned().map(Some).map_err(|_| ())
}

fn notification_deadline(method: &str) -> Option<std::time::Duration> {
    (method != crate::rpc::method::SESSION_CANCEL).then_some(WORK_BACKPRESSURE_WAIT)
}

enum NotificationAdmission {
    Accepted,
    Closed,
    Dropped,
}

fn admit_notification(
    tx: &mpsc::Sender<(String, Value)>,
    waiter_slots: &Arc<Semaphore>,
    waits: &mut Vec<tokio::task::JoinHandle<()>>,
    item: (String, Value),
) -> NotificationAdmission {
    waits.retain(|waiter| !waiter.is_finished());
    match tx.try_send(item) {
        Ok(()) => NotificationAdmission::Accepted,
        Err(mpsc::error::TrySendError::Closed(_)) => NotificationAdmission::Closed,
        Err(mpsc::error::TrySendError::Full(item)) => {
            let Ok(waiter_slot) = waiter_slots.clone().try_acquire_owned() else {
                return NotificationAdmission::Dropped;
            };
            let tx = tx.clone();
            waits.push(tokio::spawn(async move {
                let _waiter_slot = waiter_slot;
                // Waiters race with direct sends. This does not affect current
                // handlers: only session/cancel notifications have effects.
                let _ = tx.send(item).await;
            }));
            NotificationAdmission::Accepted
        }
    }
}

fn spawn_notification_worker<F, Fut>(
    mut notifications: mpsc::Receiver<(String, Value)>,
    handler: F,
) -> tokio::task::JoinHandle<()>
where
    F: Fn(String, Value) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(async move {
        let mut handlers = tokio::task::JoinSet::new();
        while let Some((notification_method, params)) = notifications.recv().await {
            let handler = handler.clone();
            handlers.spawn(async move {
                if let Some(deadline) = notification_deadline(&notification_method) {
                    let _ =
                        tokio::time::timeout(deadline, handler(notification_method, params)).await;
                } else {
                    // Cancellation must run to completion: Hub::cancel does
                    // cleanup before scheduling its forced turn end.
                    handler(notification_method, params).await;
                }
            });
            if handlers.len() >= NOTIFICATION_WORK_LIMIT {
                let _ = handlers.join_next().await;
            }
        }
        while handlers.join_next().await.is_some() {}
    })
}

impl Conn {
    fn preparation_cancel(&self, session: &str) -> tokio::sync::watch::Receiver<bool> {
        self.preparation_cancels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(session.to_owned())
            .or_insert_with(|| tokio::sync::watch::Sender::new(false))
            .subscribe()
    }

    fn cancel_preparation(&self, session: &str) {
        if let Some(cancel) =
            self.preparation_cancels.lock().unwrap_or_else(|e| e.into_inner()).remove(session)
        {
            cancel.send_replace(true);
        }
    }

    /// Whether this connection is the person (`hub/person.rs`).
    pub(super) fn is_person(&self) -> bool {
        self.person.load(Ordering::SeqCst) && !self.is_trigger()
    }

    pub(super) fn is_trigger(&self) -> bool {
        self.trigger.lock_or_recover().is_some()
    }

    /// Admit the first verified scope, or require retries to carry the exact
    /// same scope. This prevents a connection from being retargeted between
    /// deliveries while retaining its trigger principal.
    pub(super) fn admit_trigger(&self, scope: TriggerScope) -> Result<(), RpcError> {
        let mut current = self.trigger.lock_or_recover();
        if self.person.load(Ordering::SeqCst) {
            return Err(RpcError::new(-32001, "a person connection cannot become a trigger"));
        }
        match current.as_ref() {
            Some(existing) if existing == &scope => Ok(()),
            Some(_) => Err(RpcError::new(-32001, "trigger scope changed on this connection")),
            None => {
                *current = Some(scope);
                Ok(())
            }
        }
    }

    /// The acpmux session this connection proved it runs in (`hub/person.rs` (a)).
    pub(super) fn caller(&self) -> Option<&str> {
        self.caller.get().map(String::as_str)
    }

    /// Whether this connection gets the person challenge: the unix socket or the proven local app.
    pub(super) fn challengeable(&self) -> bool {
        matches!(self.origin, Origin::Local | Origin::LocalApp)
    }

    /// The person binding (`hub/person.rs`), in order before the request
    /// runs. A `personKey` in any request is stripped and never read. A
    /// local connection whose FIRST request is `initialize` is challenged;
    /// its SECOND request, `_acpmux/person_prove`, makes it the person when
    /// the proof matches its own nonce and id. Nothing else ever does.
    fn bind_person(&self, hub: &Hub, m: &str, params: &mut Option<Value>) {
        let _ = params.as_mut().and_then(crate::hub::person::take_key);
        // Stripped from every request; read from a first unix `initialize` only (person.rs (a)).
        let caller = params.as_mut().and_then(crate::hub::person::take_caller);
        let n = self.requests.fetch_add(1, Ordering::SeqCst) + 1;
        if n == 1 && m == method::INITIALIZE && self.challengeable() {
            self.challenged.store(true, Ordering::SeqCst);
        }
        let first_local = n == 1 && m == method::INITIALIZE && self.origin == Origin::Local;
        if let Some((id, token)) = caller.filter(|_| first_local) {
            let proven = hub.proven_caller((id.clone(), token)).is_some();
            let _ = if proven { &self.caller } else { &self.unproven_caller }.set(id);
        }
        if n == 2 && m == method::MUX_PERSON_PROVE && self.challenged.load(Ordering::SeqCst) {
            let proof = params.as_ref().and_then(|p| p.get("proof")).and_then(Value::as_str);
            let transport = match self.origin {
                Origin::LocalApp => crate::hub::person::TRANSPORT_APP,
                _ => crate::hub::person::TRANSPORT_UNIX,
            };
            if proof.is_some_and(|p| hub.person.proves(transport, &self.nonce, &self.id, p)) {
                self.person.store(true, Ordering::SeqCst);
            }
        }
    }

    /// Hold `lease` until this connection closes; ended now if it already did.
    pub(super) fn hold_peer_lease(&self, hub: &Hub, lease: crate::hub::PeerLease) {
        let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        match leases.as_mut() {
            Some(held) => {
                // A renewal supersedes the earlier lease of its name, whose
                // end would be a no-op (another generation holds the name).
                held.retain(|old| old.name != lease.name);
                held.push(lease);
            }
            None => {
                drop(leases);
                hub.end_peer_lease(&lease);
            }
        }
    }

    /// The connection closed: every peer it leased stops.
    fn end_peer_leases(&self, hub: &Hub) {
        let held = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).take();
        for lease in held.unwrap_or_default() {
            hub.end_peer_lease(&lease);
        }
    }

    /// Resolves once the client is gone: nobody reads its replies any more, or it stopped
    /// sending. A unix socket's writer learns of a closed socket only when it writes, so the
    /// read side ending counts too.
    async fn closed(&self) {
        let mut ended = self.ended.subscribe();
        tokio::select! {
            () = self.out.closed() => {}
            _ = ended.wait_for(|ended| *ended) => {}
        }
    }

    fn send(&self, msg: &Message) {
        self.send_replying(msg, None);
    }

    /// [`Self::send`] of the reply to a request whose method is `reply_to`: the size watch names
    /// it (`wire_size.rs`).
    fn send_replying(&self, msg: &Message, reply_to: Option<&str>) {
        // A request to the client waits on its answer, so it is never dropped as lossy.
        let control = matches!(msg, Message::Response { .. } | Message::Request { .. });
        if msg.method() == Some(method::MUX_SESSION_CHANGED) {
            self.notices.fetch_add(1, Ordering::SeqCst);
        }
        let redacted = if self.origin == Origin::Peer {
            let mut copy = msg.clone();
            let changed = match &mut copy {
                Message::Notification { params: Some(params), .. } => {
                    crate::server::pending::redact_message_hosts(params)
                }
                Message::Response { result: Some(result), .. } => {
                    crate::server::pending::redact_message_hosts(result)
                }
                _ => false,
            };
            changed.then_some(copy)
        } else {
            None
        };
        let base = redacted.as_ref().unwrap_or(msg);
        let masked = (!self.raw_text).then(|| peer_text::masked(base)).flatten();
        let msg = masked.as_ref().unwrap_or(base);
        // No message larger than one frame (`rpc::MAX_MESSAGE_BYTES`): a reply goes as its error,
        // a notification is left out and the client reads again from its last record.
        match msg.bounded_line_replying(reply_to) {
            Ok(line) => {
                enqueue_outbound(
                    &self.out,
                    line,
                    control,
                    &self.outbound_dropped,
                    &self.outbound_gap_pending,
                    &self.outbound_lock,
                    &self.outbound_pending_controls,
                );
            }
            Err(bytes) => self.left_out_too_large(msg.method(), bytes),
        }
    }

    /// A notification of `bytes`, larger than a frame, was left out (`bounded_line` counted it
    /// and warned of it, at most once a minute per method): the client is told it lagged and
    /// reads again from its last record.
    fn left_out_too_large(&self, method: Option<&str>, bytes: usize) {
        tracing::debug!(conn = %self.id, method = ?method, bytes, "left out a notification too large to send");
        enqueue_outbound(
            &self.out,
            Message::notification(
                "_acpmux/lagged",
                json!({"dropped": 1, "reason": "message_too_large"}),
            )
            .to_line(),
            false,
            &self.outbound_dropped,
            &self.outbound_gap_pending,
            &self.outbound_lock,
            &self.outbound_pending_controls,
        );
    }
    /// The reply for `id` whose result is already serialized (`list_reply.rs`), masked
    /// already for a peer, read when [`Conn::notices`] was `seen`. Under the outbound lock:
    /// if a notice was queued since, it is not sent (false) unless `anyway`. A reply that
    /// goes out after such a notice (`anyway`, or one that waited for room in a full queue)
    /// is followed by `_acpmux/lagged {watch: true}`, so the client reads the list again.
    /// One larger than a frame goes as its error, as in [`Self::send`].
    /// None if it was not sent; else whether it went whole into an open queue (not as its
    /// too-large error, nor into a queue whose reader is gone).
    /// `method` is the request's, if known, for the size watch (`wire_size.rs`), which counts
    /// the reply once it goes, never a list left for a newer one.
    fn send_serialized(
        &self,
        id: &Value,
        method: Option<&str>,
        result: &str,
        seen: u64,
        anyway: bool,
    ) -> Option<bool> {
        let mut line = list_reply::reply_line(id, result);
        let bytes = line.len();
        let whole = bytes <= crate::rpc::MAX_MESSAGE_BYTES;
        if !whole {
            line = Message::err(id.clone(), RpcError::too_large(line.len())).to_line();
        }
        let lag = || {
            let lag = json!({"watch": true, "dropped": 0, "reason": "list_changed"});
            Message::notification("_acpmux/lagged", lag).to_line()
        };
        let _guard = self.outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
        let stale = self.notices.load(Ordering::SeqCst) != seen;
        if stale && !anyway {
            return None;
        }
        let what = method.map_or(crate::wire_size::What::Reply, crate::wire_size::What::ReplyTo);
        crate::wire_size::observe(what, bytes);
        match self.out.try_send(line) {
            Ok(()) if stale => self.enqueue_control_locked(lag()),
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Closed(_)) => return Some(false),
            // No room: it waits for some, and a notice may go first; then the lag follows it.
            Err(mpsc::error::TrySendError::Full(line)) => {
                let (out, notices) = (self.out.clone(), self.notices.clone());
                let pending = self.outbound_pending_controls.clone();
                pending.fetch_add(1, Ordering::AcqRel);
                tokio::spawn(async move {
                    if out.send(line).await.is_ok() && notices.load(Ordering::SeqCst) != seen {
                        let _ = out.send(lag()).await;
                    }
                    pending.fetch_sub(1, Ordering::AcqRel);
                });
            }
        }
        Some(whole)
    }

    /// [`Self::send`] for a request to the client that must go out after every response and
    /// request queued before it ([`enqueue_after_controls`]): a GitHub action after the watch
    /// answer that opened the Mac's side (`hub/github_owner.rs`). Refused, with nothing sent,
    /// while one of those still waits for room, or when it is larger than a frame.
    fn send_request_in_order(&self, msg: &Message) -> Result<(), RpcError> {
        let masked = (!self.raw_text).then(|| peer_text::masked(msg)).flatten();
        let msg = masked.as_ref().unwrap_or(msg);
        let line = msg.bounded_line().map_err(RpcError::too_large)?;
        if self.out.is_closed() {
            return Err(RpcError::internal("the connection that would answer ended"));
        }
        let queued = enqueue_after_controls(
            &self.out,
            line,
            &self.outbound_dropped,
            &self.outbound_gap_pending,
            &self.outbound_lock,
            &self.outbound_pending_controls,
        );
        if !queued {
            return Err(RpcError::new(-32000, "the link to that client is backed up; try again")
                .with_data(json!({"reason": "client.busy", "retryable": true})));
        }
        Ok(())
    }

    fn enqueue_control_locked(&self, line: String) {
        enqueue_outbound_locked(
            &self.out,
            line,
            true,
            &self.outbound_dropped,
            &self.outbound_gap_pending,
            &self.outbound_lock,
            &self.outbound_pending_controls,
        );
    }
    fn sub_opts(&self, session_id: &str) -> Option<SubOpts> {
        self.subs.lock_or_recover().get(session_id).cloned()
    }
    /// This daemon's own chats this connection is attached to.
    fn local_attached_ids(&self) -> Vec<String> {
        let subs = self.subs.lock_or_recover();
        subs.iter().filter(|(_, opts)| !opts.remote).map(|(id, _)| id.clone()).collect()
    }
    pub(super) fn bind_mailbox_receipt(&self, receipt: SessionReceipt) {
        self.mailbox_bindings.lock_or_recover().insert(receipt.mux_session_id.clone(), receipt);
    }
    pub(super) fn mailbox_receipt(&self, session_id: &str) -> Option<SessionReceipt> {
        let key = session_id.strip_prefix("acp:").unwrap_or(session_id);
        self.mailbox_bindings
            .lock_or_recover()
            .values()
            .find(|receipt| key == receipt.mux_session_id || key == receipt.qualified_id())
            .cloned()
    }
    pub(super) fn unbind_mailbox_receipt(&self, session_id: &str) {
        self.mailbox_bindings.lock_or_recover().remove(session_id);
    }
    /// Subscribe with default options; keeps options already set.
    fn subscribe(&self, session_id: &str) -> bool {
        let mut subs = self.subs.lock_or_recover();
        if subs.contains_key(session_id) {
            return false;
        }
        subs.insert(session_id.to_owned(), SubOpts::default());
        true
    }
    fn label(&self) -> String {
        let n = self.name.lock_or_recover().clone();
        if n.is_empty() {
            self.id.clone()
        } else {
            format!("{n}#{}", self.id.get(..6).unwrap_or(self.id.as_str()))
        }
    }
}

/// Keep two queue slots available for replies and one for the gap marker that
/// tells a reader to replay from its last cursor.
const OUTBOUND_CONTROL_RESERVE: usize = 3;

fn enqueue_outbound(
    out: &mpsc::Sender<String>,
    line: String,
    control: bool,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) {
    let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
    enqueue_outbound_locked(
        out,
        line,
        control,
        dropped,
        gap_pending,
        outbound_lock,
        pending_controls,
    );
}

/// [`enqueue_outbound`] of a control line that must go out after every control queued before
/// it: queued only if none of those still waits for room in a full queue (each such waits in a
/// task of its own, which a line queued now would pass). False, with nothing queued, if one does
/// or the queue's reader is gone.
fn enqueue_after_controls(
    out: &mpsc::Sender<String>,
    line: String,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) -> bool {
    let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
    if out.is_closed() || pending_controls.load(Ordering::Acquire) != 0 {
        return false;
    }
    enqueue_outbound_locked(out, line, true, dropped, gap_pending, outbound_lock, pending_controls);
    true
}

/// [`enqueue_outbound`] with `outbound_lock` held.
fn enqueue_outbound_locked(
    out: &mpsc::Sender<String>,
    line: String,
    control: bool,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) {
    // Notifications are lossy by design when the reader is too slow, but the
    // The final three permits are reserved for two response/control messages
    // and the recovery marker.
    let reserved = OUTBOUND_CONTROL_RESERVE + pending_controls.load(Ordering::Acquire);
    if !control && out.capacity() <= reserved {
        report_outbound_loss_locked(out, dropped, gap_pending, outbound_lock);
        return;
    }
    match out.try_send(line) {
        Ok(()) => {
            // Let a later queue-pressure episode produce a fresh marker once
            // the previous marker and backlog have drained.
            if gap_pending.load(Ordering::Acquire)
                && pending_controls.load(Ordering::Acquire) == 0
                && out.capacity() > OUTBOUND_CONTROL_RESERVE + 1
            {
                gap_pending.store(false, Ordering::Release);
            }
        }
        Err(mpsc::error::TrySendError::Full(line)) if control => {
            let out = out.clone();
            pending_controls.fetch_add(1, Ordering::AcqRel);
            let pending_controls = Arc::clone(pending_controls);
            tokio::spawn(async move {
                let _ = out.send(line).await;
                pending_controls.fetch_sub(1, Ordering::AcqRel);
            });
        }
        Err(mpsc::error::TrySendError::Full(_)) => {
            report_outbound_loss_locked(out, dropped, gap_pending, outbound_lock)
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {}
    }
}

fn report_outbound_loss_locked(
    out: &mpsc::Sender<String>,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
) {
    let total = dropped.fetch_add(1, Ordering::Relaxed) + 1;
    if gap_pending.swap(true, Ordering::AcqRel) {
        return;
    }
    let marker = Message::notification(
        "_acpmux/lagged",
        json!({"dropped": total, "reason": "output_queue_full"}),
    )
    .to_line();
    if out.try_send(marker).is_err() {
        // Keep the marker pending even when the queue is currently full. The
        // waiter owns the next available slot, so a quiet connection still
        // receives the replay signal after its reader catches up.
        let out = out.clone();
        let dropped = Arc::clone(dropped);
        let gap_pending = Arc::clone(gap_pending);
        let outbound_lock = Arc::clone(outbound_lock);
        tokio::spawn(async move {
            let permit = out.reserve().await;
            let Ok(permit) = permit else {
                gap_pending.store(false, Ordering::Release);
                return;
            };
            let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
            let total = dropped.load(Ordering::Relaxed);
            permit.send(
                Message::notification(
                    "_acpmux/lagged",
                    json!({"dropped": total, "reason": "output_queue_full"}),
                )
                .to_line(),
            );
            gap_pending.store(false, Ordering::Release);
        });
    }
}

// ----------------------------------------------------------------- listen

pub async fn listen_unix(hub: Arc<Hub>, path: PathBuf) -> Result<()> {
    let listener = bind_unix(&path).await?;
    serve_unix(hub, listener).await
}

/// Bind the daemon socket (mode 0600), refusing to steal a live one.
#[cfg(unix)]
pub async fn bind_unix(path: &std::path::Path) -> Result<UnixListener> {
    crate::config::refuse_lost_home(&crate::config::home())?;
    // A configured path longer than sun_path fails here with the path and
    // the limit, never as a bare bind error.
    cmux_unix_socket::check_path(path)?;
    if let Some(parent) = path.parent() {
        // Owner-only when created here, like the /tmp fallback directory.
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    if path.exists() {
        // Refuse to steal a live socket.
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            anyhow::bail!("another acpmux daemon owns {}", path.display());
        }
        // A failed connect is not a dead socket: a live daemon whose accept queue is full
        // refuses it too. Only the holder of the lock that serves it may remove it.
        if let Some(pid) = crate::daemon::socket_held_by_other(path) {
            anyhow::bail!(
                "the acpmux daemon pid {pid} holds the lock that serves {}; leaving its socket in place",
                path.display()
            );
        }
        crate::config::refuse_lost_home(&crate::config::home())?;
        std::fs::remove_file(path)?;
    }
    crate::config::refuse_lost_home(&crate::config::home())?;
    let listener = UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    tracing::info!("listening on {}", path.display());
    Ok(listener)
}

/// How long to wait after a failed `accept`. A connection that died in the queue is gone, so the
/// next accept can run at once; anything else (EMFILE, ENFILE, ENOBUFS) leaves the connection
/// queued, and an immediate retry would spin a core and flood the log until descriptors free up.
pub(crate) fn accept_retry_delay(error: &std::io::Error) -> std::time::Duration {
    use std::io::ErrorKind::{ConnectionAborted, ConnectionReset, Interrupted};
    match error.kind() {
        ConnectionAborted | ConnectionReset | Interrupted => std::time::Duration::ZERO,
        _ => std::time::Duration::from_millis(100),
    }
}

/// Whether a failed `accept` means the listener itself is gone (closed, never listening or not a
/// socket), so a retry can never succeed. Any other failure is about one connection or a passing
/// shortage, and the loop pauses ([`accept_retry_delay`]) and accepts again.
/// Its callers are the Linux sandbox proxy and the tailnet ingress.
#[cfg_attr(not(any(target_os = "linux", feature = "tailnet")), allow(dead_code))]
pub(crate) fn accept_ends_listener(error: &std::io::Error) -> bool {
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(libc::EBADF | libc::EINVAL | libc::ENOTSOCK)) {
        return true;
    }
    error.kind() == std::io::ErrorKind::UnexpectedEof
}

#[cfg(unix)]
pub async fn serve_unix(hub: Arc<Hub>, listener: UnixListener) -> Result<()> {
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("accept failed: {e}");
                tokio::time::sleep(accept_retry_delay(&e)).await;
                continue;
            }
        };
        let hub = hub.clone();
        tokio::spawn(async move {
            // Named by its audit token, read once here, never by pid.
            let peer = {
                use std::os::fd::AsRawFd;
                cmux_link::app_caller::peer_token(stream.as_raw_fd())
            };
            stream::serve_stream(hub, stream, peer).await;
        });
    }
}

const INDEX_HTML: &str = include_str!("../../web/index.html");

/// One TCP port serves both the dashboard page (plain HTTP GET) and the
/// WebSocket protocol. The request head is peeked, never consumed, so the
/// WebSocket handshake still sees the full request.
///
/// Every request passes the localhost listener rule first
/// (plans/cmux-next/identity.md section 4): a loopback `Host`, no foreign
/// `Origin`, and the token, which is mandatory.
pub async fn listen_ws(hub: Arc<Hub>, addr: String, token: String) -> Result<()> {
    let listener = bind_ws(&addr).await?;
    serve_ws(hub, listener, token).await
}

/// Bind the dashboard/WebSocket port. `127.0.0.1:0` picks a free port; read
/// it back with `local_addr`.
pub async fn bind_ws(addr: &str) -> Result<TcpListener> {
    let listener = TcpListener::bind(addr).await.with_context(|| format!("bind {addr}"))?;
    let local = listener.local_addr().map(|a| a.to_string()).unwrap_or_else(|_| addr.to_owned());
    tracing::info!("web + websocket listening on {local}");
    Ok(listener)
}

/// The origin of the app's bundled agent pane page (a `cmux-agent` URL
/// scheme handler). A `file://` page would send `Origin: null`, which every
/// localhost listener refuses.
pub const AGENT_PANE_ORIGIN: &str = "cmux-agent://pane";

/// The Origin and Host rule of this listener: its own origin (the
/// dashboard page), the agent pane, and the origins and hosts the config
/// adds (`websocket.allowed_origins`, `websocket.allowed_hosts`). Never
/// `null`. An entry that does not parse is skipped with a warning. The Host
/// rule holds on every bind: a non-loopback `websocket.listen` also accepts
/// IP address literals, and the names clients use must be listed in
/// `websocket.allowed_hosts`.
pub fn listener_policy(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    let mut policy =
        ListenerPolicy::for_bind_keeping_host_rule(address).with_origin(AGENT_PANE_ORIGIN);
    if !address.ip().is_loopback() && extra_hosts.is_empty() {
        tracing::warn!(
            "websocket.listen {address} is not loopback: clients may connect by IP address only; list host names in websocket.allowedHosts"
        );
    }
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_none() {
            tracing::warn!(
                "websocket.allowed_origins: ignoring {origin:?} (not scheme://host[:port])"
            );
            continue;
        }
        policy = policy.with_origin(origin);
    }
    for host in extra_hosts {
        policy = policy.with_host(host);
    }
    policy
}

/// Validate a `--allow-dev-origin` value: only a loopback `http` origin with
/// an explicit port (a page dev server on this machine). Anything else is an
/// error, so the flag can never admit a web site.
pub fn dev_origin(value: &str) -> Result<String> {
    let origin = cmux_local_auth::parse_origin(value)
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} is not scheme://host:port"))?;
    let rest = origin
        .strip_prefix("http://")
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} must be http"))?;
    let (host, port) = rest
        .rsplit_once(':')
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} needs a port"))?;
    anyhow::ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]") && port.parse::<u16>().is_ok(),
        "--allow-dev-origin {value:?} must be a loopback host with a port"
    );
    Ok(origin)
}

/// An accepted web socket streams many small ACP deltas: send each at once (no Nagle delay).
fn tune_ws_socket(stream: &tokio::net::TcpStream) {
    if let Err(e) = stream.set_nodelay(true) {
        tracing::debug!("ws TCP_NODELAY: {e}");
    }
}

pub async fn serve_ws(hub: Arc<Hub>, listener: TcpListener, token: String) -> Result<()> {
    serve_ws_with(hub, listener, token, WsAuth::default()).await
}

/// The proofs a WebSocket connection may present beyond the dashboard
/// token: this launch's LocalApp token (`local_app.rs`) and peer token
/// (`peer_auth.rs`). Without one, no connection gets that origin.
#[derive(Default, Clone)]
pub struct WsAuth {
    pub local_app: Option<Arc<local_app::LocalAppAuth>>,
    pub peer: Option<Arc<peer_auth::PeerAuth>>,
}

/// How long a connection may wait before its first frame decides whether it
/// is the local app (`local_app.rs`); after it, it is remote-origin.
const FIRST_FRAME: std::time::Duration = std::time::Duration::from_secs(10);

/// Bound pre-authentication work separately from the per-connection request budget.
/// A client can otherwise hold a task and file descriptor while it dribbles out
/// an HTTP upgrade request.
const WS_HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const WS_HANDSHAKE_CONCURRENCY: usize = 64;

/// The largest WebSocket frame or message a connection reads. The app's agent pane sends a frame
/// of up to 32 MiB (`AcpmuxPaneMethods.maximumFrameBytes`); a prompt with a few screenshots is
/// past tungstenite's 16 MiB frame default, which ended the read with no log line and reset the
/// socket mid-send ("The agent connection was interrupted", 2026-10-20).
pub const WS_MAX_MESSAGE_BYTES: usize = 64 << 20;

/// The listener's and the peer client's WebSocket limits (`WS_MAX_MESSAGE_BYTES`).
pub fn ws_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(WS_MAX_MESSAGE_BYTES))
        .max_frame_size(Some(WS_MAX_MESSAGE_BYTES))
}

/// `serve_ws` with this launch's LocalApp and peer tokens: a connection
/// that meets every LocalApp condition is served as `Origin::LocalApp`, one
/// that proves the peer token as `Origin::Peer`, any other as `Origin::Web`.
pub async fn serve_ws_with(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
) -> Result<()> {
    let shutdown = hub.ws_shutdown.clone();
    serve_ws_until(hub, listener, token, auth, shutdown).await
}

/// The daemon's listener: drains established WebSockets with Close 1012 on shutdown.
pub async fn serve_ws_until(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
    shutdown: WsShutdown,
) -> Result<()> {
    let (shutdown, _draining) = shutdown.listener();
    anyhow::ensure!(!token.is_empty(), "the acpmux web listener needs a token");
    if shutdown.is_requested() {
        return Ok(());
    }
    let bound = listener.local_addr()?;
    let (extra_origins, extra_hosts) = {
        let config = hub.config.read().await;
        let (mut origins, hosts) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
            .unwrap_or_default();
        origins.extend(config.dev_origins.iter().cloned());
        (origins, hosts)
    };
    let policy = Arc::new(listener_policy(listener.local_addr()?, &extra_origins, &extra_hosts));
    // Each handshake checks the token current at that moment: a rotation
    // (`hub/web_token.rs`) applies from the next one on. The daemon set it
    // already; a caller that did not (tests) gets `token`.
    hub.web_token.set_if_unset(token);
    let handshake_slots = Arc::new(Semaphore::new(WS_HANDSHAKE_CONCURRENCY));
    let mut connections = tokio::task::JoinSet::new();
    loop {
        let accepted = tokio::select! {
            biased;
            () = shutdown.requested() => break,
            () = shutdown.normal() => {
                shutdown.close_clients();
                break;
            }
            _ = connections.join_next(), if !connections.is_empty() => continue,
            accepted = listener.accept() => accepted,
        };
        let (stream, peer) = match accepted {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws accept failed: {e}");
                tokio::time::sleep(accept_retry_delay(&e)).await;
                continue;
            }
        };
        tune_ws_socket(&stream);
        let handshake_slot = match handshake_slots.clone().try_acquire_owned() {
            Ok(slot) => slot,
            Err(_) => {
                tracing::warn!(peer = %peer, error = "handshake_capacity", "rejecting websocket handshake");
                tokio::spawn(refuse_ws_transport(stream, 503, "handshake_capacity"));
                continue;
            }
        };
        let hub = hub.clone();
        // Read and subscribed before the handshake, so a rotation during it
        // still closes a connection that presented the old token.
        let (token, rotated) = hub.web_token.watch();
        let policy = policy.clone();
        let local_app = auth.local_app.clone();
        let peer_auth = auth.peer.clone();
        let shutdown = shutdown.clone();
        connections.spawn(async move {
            let _handshake_slot = handshake_slot;
            let mut head = [0u8; 4096];
            let Some(n) = ws_peek::request(&stream, &mut head, peer).await else { return };
            // The peek only routes the request. Each path checks the full head it parses:
            // serve_http reads it, tungstenite parses the upgrade request for the callback.
            let head_text = String::from_utf8_lossy(head.get(..n).unwrap_or(&head)).into_owned();
            if !head_text.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &policy, &token, peer).await;
                return;
            }
            let expected = token.clone();
            // The upgrade request's Origin headers, for the LocalApp check.
            let seen_origins: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_origins = seen_origins.clone();
            // Its peer token headers, for the Peer check.
            let seen_peer: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_peer = seen_peer.clone();
            // A ticket or a paired machine's credential (`pairing.rs`).
            let admitted: Arc<StdMutex<pairing::Admitted>> = Arc::default();
            let (record_admitted, pairing_hub) = (admitted.clone(), hub.clone());
            let callback = move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                                 resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let values = |name: &str| {
                    req.headers()
                        .get_all(name)
                        .iter()
                        .map(|value| value.to_str().unwrap_or("\u{0}"))
                        .collect::<Vec<_>>()
                };
                let refuse = |refusal: Refusal| {
                    use tokio_tungstenite::tungstenite::http::{Response, StatusCode};
                    let mut response = Response::new(Some(refusal.reason().to_owned()));
                    *response.status_mut() =
                        StatusCode::from_u16(refusal.status()).unwrap_or(StatusCode::FORBIDDEN);
                    response
                };
                if let Err(refusal) = policy.check(&values("host"), &values("origin")) {
                    return Err(refuse(refusal));
                }
                *record_origins.lock().unwrap_or_else(|e| e.into_inner()) =
                    values("origin").into_iter().map(str::to_owned).collect();
                *record_peer.lock().unwrap_or_else(|e| e.into_inner()) =
                    values(peer_auth::HEADER).into_iter().map(str::to_owned).collect();
                let header = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .and_then(cmux_local_auth::bearer_token);
                let query = req.uri().query().and_then(cmux_local_auth::query_token);
                let tickets = values(crate::pairing::TICKET_HEADER);
                let proof = pairing::admit(&pairing_hub, peer, header.or(query), &tickets, &expected);
                *record_admitted.lock().unwrap_or_else(|e| e.into_inner()) = proof.map_err(refuse)?;
                Ok(resp)
            };
            let mut ws = match tokio::time::timeout(
                WS_HANDSHAKE_TIMEOUT,
                tokio_tungstenite::accept_hdr_async_with_config(
                    stream,
                    callback,
                    Some(ws_config()),
                ),
            )
            .await
            {
                Err(_) => {
                    tracing::warn!(peer = %peer, error = "handshake_timeout", "closing stalled websocket handshake");
                    return;
                }
                Ok(Ok(ws)) => ws,
                Ok(Err(e)) => {
                    tracing::warn!("ws handshake from {peer} rejected: {e}");
                    return;
                }
            };
            // Only the HTTP upgrade is admission-controlled; an established
            // connection is governed by its authenticated request budget.
            drop(_handshake_slot);
            let admitted = std::mem::take(&mut *admitted.lock().unwrap_or_else(|e| e.into_inner()));
            let device = match admitted {
                pairing::Admitted::Ticket(secret) => {
                    let close = tokio::select! {
                        biased;
                        () = shutdown.normal() => true,
                        () = shutdown.closing() => true,
                        () = pairing::serve_redeem(hub, &mut ws, secret) => false,
                    };
                    if close {
                        ws_shutdown::close(&mut ws, shutdown.close_code_restart()).await;
                    }
                    return;
                }
                pairing::Admitted::Device(device) => Some(device),
                pairing::Admitted::Dashboard => None,
            };
            let (sink, mut source) = ws.split();
            let (in_tx, in_rx) = mpsc::channel::<String>(256);
            let (out_tx, out_rx) = mpsc::channel::<String>(4096);
            let mut children = ws_shutdown::Children::new();
            let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
            let wire = Arc::new(crate::frame_compress::Wire::default());
            let writer = tokio::spawn(ws_shutdown::write(
                sink,
                out_rx,
                stopped,
                shutdown.clone(),
                wire.clone(),
            ));
            children.track(&writer);
            // The handshake above checked the listener token: every
            // connection past it is authenticated (`conn_auth.rs`).
            let mut proof = ConnAuth::ListenerToken;
            // The first frame decides LocalApp; it reaches the protocol handler without the token.
            let mut origin = Origin::Web;
            let mut first = None;
            let presented =
                std::mem::take(&mut *seen_peer.lock().unwrap_or_else(|e| e.into_inner()));
            if let Some(device) = &device {
                (origin, proof) = pairing::origin_of(device);
            } else if peer_auth.as_ref().is_some_and(|a| a.is_peer(peer, &presented)) {
                origin = Origin::Peer;
                proof = ConnAuth::PeerToken;
            } else if let Some(auth) = &local_app {
                let frame = tokio::select! {
                    biased;
                    () = shutdown.closing() => None,
                    frame = async {
                        tokio::time::timeout(FIRST_FRAME, async {
                            while let Some(Ok(frame)) = source.next().await {
                                if let tokio_tungstenite::tungstenite::Message::Text(t) = frame {
                                    return Some(t.to_string());
                                }
                            }
                            None
                        }).await.ok().flatten()
                    } => frame,
                };
                let origins = seen_origins.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let hello = local_app::Hello {
                    listener: bound,
                    peer,
                    origins: &origins,
                    first_frame: frame.as_deref(),
                };
                if auth.is_local_app(&hello) {
                    origin = Origin::LocalApp;
                    proof = ConnAuth::LocalApp;
                }
                first = frame.map(|f| local_app::strip_token(&f));
            }
            if let Some(first) = first
                && in_tx.send(first).await.is_err()
            {
                return;
            }
            // Binary frames are upload data (`upload_frames.rs`), written in order by their own
            // worker; it refuses them on any connection but the local app's.
            let frames = upload_frames::spawn(hub.clone(), origin, proof, out_tx.clone());
            let read_shutdown = shutdown.clone();
            let reader = tokio::spawn(async move {
                tokio::select! {
                    biased;
                    () = read_shutdown.closing() => {},
                    () = async {
                        while let Some(frame) = source.next().await {
                            let frame = match frame {
                                Ok(frame) => frame,
                                // A read error ends the connection; say why, or the client sees only a reset.
                                Err(e) => {
                                    tracing::warn!("closing a {origin:?} connection from {peer}: {e}");
                                    break;
                                }
                            };
                            let sent = match frame {
                                // After the frames before it are written (`upload_frames::InFlight`).
                                tokio_tungstenite::tungstenite::Message::Text(t) => {
                                    frames.in_flight.drained().await;
                                    in_tx.send(t.to_string()).await.is_ok()
                                }
                                tokio_tungstenite::tungstenite::Message::Binary(b) => frames.send(b).await,
                                _ => true,
                            };
                            if !sent {
                                break;
                            }
                        }
                    } => {},
                }
            });
            children.track(&reader);
            // A rotation ends a Web or Peer connection, which presented the
            // dashboard token; a revocation ends a paired machine's, which
            // presented its own. Ending its read half closes `in_rx`, so
            // `serve_connection_with` returns through its own cleanup
            // (detach counts, fan-out task) before the writer sends Close.
            // LocalApp also proved this launch's LocalApp token, so it stays.
            let _open = device.as_ref().map(|d| hub.pairing.opened(&d.id));
            let ends: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
                match &device {
                    Some(d) => Box::pin(hub.pairing.revoked(&d.id)),
                    None => Box::pin(rotated),
                };
            let watcher = matches!(origin, Origin::Web | Origin::Peer).then(|| {
                let read_half = reader.abort_handle();
                tokio::spawn(async move {
                    ends.await;
                    tracing::info!("closing a {origin:?} connection: its credential ended");
                    read_half.abort();
                })
            });
            if let Some(watcher) = &watcher {
                children.track(watcher);
            }
            let (origin, proof, device) = match device {
                Some(device) => {
                    let (origin, proof) = pairing::origin_of(&device);
                    (origin, proof, Some(device.id))
                }
                None => (origin, proof, None),
            };
            serve_connection_from(hub, in_rx, out_tx, origin, proof, None, device, Some(wire))
                .await;
            if let Some(watcher) = watcher {
                watcher.abort();
            }
            let _ = stop.send(());
            // Its read half may wait on a silent client; the close is ours.
            reader.abort();
            let _ = writer.await;
        });
    }
    // Close admission before clients see 1012, so their immediate retry cannot reconnect to
    // this dying listener. Already accepted upgrades also see the latched shutdown signal.
    ws_shutdown::close_admission(listener);
    shutdown.close_clients();
    if tokio::time::timeout(ws_shutdown::DRAIN_BUDGET, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
    Ok(())
}

async fn refuse_ws_transport(mut stream: tokio::net::TcpStream, status: u16, error: &str) {
    let reason = match status {
        503 => "Service Unavailable",
        _ => "Bad Request",
    };
    let body = format!("{{\"error\":\"{error}\"}}\n");
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// Check the `Host` and `Origin` values of a complete request head.
fn check_head(policy: &ListenerPolicy, head: &str) -> Result<(), Refusal> {
    let mut hosts = Vec::new();
    let mut origins = Vec::new();
    for line in head.split("\r\n").skip(1) {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name.eq_ignore_ascii_case("host") {
            hosts.push(value.trim());
        } else if name.eq_ignore_ascii_case("origin") {
            origins.push(value.trim());
        }
    }
    policy.check(&hosts, &origins)
}

async fn refuse_http(mut stream: tokio::net::TcpStream, refusal: Refusal) {
    let status = match refusal.status() {
        401 => "401 Unauthorized",
        _ => "403 Forbidden",
    };
    let body = refusal.reason();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// The largest request head the dashboard reads.
const MAX_HTTP_HEAD_BYTES: usize = 32 * 1024;

/// Read a request head up to its blank line. None when it is larger than
/// [`MAX_HTTP_HEAD_BYTES`] (room for large localhost cookies), the peer
/// closes first, or it takes over 2 s.
async fn read_http_head(stream: &mut tokio::net::TcpStream) -> Option<String> {
    let read = async {
        let mut head = Vec::with_capacity(1024);
        let mut chunk = [0u8; 4096];
        while !head.windows(4).any(|window| window == b"\r\n\r\n") {
            if head.len() >= MAX_HTTP_HEAD_BYTES {
                return None;
            }
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 {
                return None;
            }
            head.extend_from_slice(chunk.get(..n).unwrap_or(&chunk));
        }
        Some(String::from_utf8_lossy(&head).into_owned())
    };
    tokio::time::timeout(std::time::Duration::from_secs(2), read).await.ok().flatten()
}

/// Minimal HTTP for the dashboard. The whole head passes the listener rule
/// first; then GET / with a matching token serves the page, and anything
/// else is 401 or 404.
async fn serve_http(
    mut stream: tokio::net::TcpStream,
    policy: &ListenerPolicy,
    token: &str,
    peer: std::net::SocketAddr,
) {
    let Some(head) = read_http_head(&mut stream).await else {
        refuse_http(stream, Refusal::MissingHost).await;
        return;
    };
    if let Err(refusal) = check_head(policy, &head) {
        tracing::warn!("web request from {peer} refused: {refusal}");
        refuse_http(stream, refusal).await;
        return;
    }
    let first = head.lines().next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method_ = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let (status, body, ctype) = if !method_.eq_ignore_ascii_case("get") {
        ("405 Method Not Allowed", "method not allowed".to_owned(), "text/plain")
    } else if path == "/health" {
        ("200 OK", "ok".to_owned(), "text/plain")
    } else if path == "/" || path == "/index.html" {
        if cmux_local_auth::check_token(cmux_local_auth::query_token(query), token).is_ok() {
            ("200 OK", INDEX_HTML.to_owned(), "text/html; charset=utf-8")
        } else {
            ("401 Unauthorized", "<!doctype html><meta charset=utf-8><title>acpmux</title><p style=\"font-family:system-ui;padding:2rem\">This dashboard needs its token. Run <code>acpmux web</code> in a terminal to open it with its token (<code>acpmux web --no-open --show-token</code> prints the link).</p>".to_owned(), "text/html; charset=utf-8")
        }
    } else {
        ("404 Not Found", "not found".to_owned(), "text/plain")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ------------------------------------------------------------ connection

/// Where a connection came from. A `Web` connection (the WebSocket
/// listener: peer daemons, remote clients, relays) is remote-origin: remote
/// chains build their settings from scratch, so it never starts or sets a
/// preset that carries harness args or a system prompt, and the session
/// pool never serves it. `LocalApp` is the app's own agent pane, proven by
/// every condition in `local_app.rs`: the pool serves it, it may start any
/// configured preset, and like `Web` it never sets a preset's harness args
/// or system prompt and never reads a token back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Origin {
    /// The local Unix socket.
    #[default]
    Local,
    /// The WebSocket listener.
    Web,
    /// The app's agent pane over the WebSocket listener (`local_app.rs`).
    LocalApp,
    /// A peer acpmux daemon over the WebSocket listener, proven by this
    /// launch's peer token (`peer_auth.rs`). It has the Web's rights except
    /// the current-mode rule for prompts and permission answers.
    Peer,
}

impl Origin {
    /// Web or Peer: a connection held to the Web's rules.
    pub fn web_class(self) -> bool {
        matches!(self, Origin::Web | Origin::Peer)
    }
}

/// A connection from the local Unix socket.
pub async fn serve_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
) {
    serve_connection_with(hub, inbound, out, Origin::Local).await
}

/// An in-process connection (tests, an embedding): the caller vouches for
/// the proof `origin` implies (`ConnAuth::proven_for`). A transport that
/// checks its own proof uses `serve_connection_authed`.
pub async fn serve_connection_with(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    serve_connection_authed(hub, inbound, out, origin, ConnAuth::proven_for(origin)).await
}

/// A connection with the proof its transport checked. `ConnAuth::None`
/// gets no sessions and no data: its first request is refused and the
/// connection ends (`conn_auth.rs`).
pub async fn serve_connection_authed(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
) {
    serve_connection_from(hub, inbound, out, origin, auth, None, None, None).await
}

/// A paired machine's connection, served as its role says
/// (`pairing::origin_of`): the WebSocket listener's, once the handshake
/// proved `device`'s credential, or an in-process caller that vouches for it.
pub async fn serve_connection_device(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    device: crate::pairing::DeviceAuth,
) {
    let (origin, auth) = pairing::origin_of(&device);
    serve_connection_from(hub, inbound, out, origin, auth, None, Some(device.id), None).await
}

/// `serve_connection_authed` for a unix socket peer named by its audit token.
async fn serve_connection_from(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
    device: Option<String>,
    wire: Option<Arc<crate::frame_compress::Wire>>,
) {
    if !auth.authenticated() {
        refuse_unauthenticated(&mut inbound, &out, origin).await;
        return;
    }
    // Counted while it is served: a daemon with none stops once unused (`daemon/unused_exit.rs`).
    let _client = crate::daemon::unused_exit::client();
    let raw_text = !peer_text::masks(origin);
    let conn = Arc::new(Conn {
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        auth,
        device,
        raw_text,
        name: StdMutex::new(String::new()),
        out,
        outbound_lock: Arc::new(StdMutex::new(())),
        outbound_dropped: Arc::new(AtomicU64::new(0)),
        outbound_gap_pending: Arc::new(AtomicBool::new(false)),
        outbound_pending_controls: Arc::new(AtomicUsize::new(0)),
        subs: StdMutex::new(HashMap::new()),
        message_notices: StdMutex::new(MessageNoticeBook::default()),
        mailbox_bindings: StdMutex::new(HashMap::new()),
        watch_all: AtomicBool::new(false),
        watch_tools: AtomicBool::new(false),
        list_pace: Default::default(),
        notices: Arc::new(AtomicU64::new(0)),
        watch_inventory: StdMutex::new(false),
        peer,
        requests: std::sync::atomic::AtomicU64::new(0),
        challenged: AtomicBool::new(false),
        nonce: crate::hub::person::new_nonce(),
        person: AtomicBool::new(false),
        trigger: StdMutex::new(None),
        holds_calls: std::sync::atomic::AtomicU32::new(0),
        caller: std::sync::OnceLock::new(),
        unproven_caller: std::sync::OnceLock::new(),
        peer_leases: StdMutex::new(Some(Vec::new())),
        ephemeral: StdMutex::new(Some(Vec::new())),
        ended: tokio::sync::watch::Sender::new(false),
        preparation_cancels: StdMutex::new(HashMap::new()),
        // A peer daemon's link carries all its clients' reads, which it caps one by one
        // (`media_forward.rs`).
        media: if auth == ConnAuth::PeerToken {
            crate::hub::media_handles::Handles::for_peer_link()
        } else {
            crate::hub::media_handles::Handles::default()
        },
        remote_media: media_forward::RemoteMedia::default(),
        client_requests: Default::default(),
        chat_windows: Default::default(),
        cancel_refusals: Default::default(),
        wire,
    });
    tracing::debug!(conn = %conn.id, "client connected");

    let fan = fanout::start(hub.clone(), conn.clone());
    let request_slots = Arc::new(Semaphore::new(REQUEST_WORK_LIMIT));
    let (notification_tx, notification_rx) =
        mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let (cancel_tx, cancel_rx) = mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let notification_handler = {
        let hub = hub.clone();
        let conn = conn.clone();
        move |method: String, params| {
            let hub = hub.clone();
            let conn = conn.clone();
            async move { handle_notification(&hub, &conn, &method, params).await }
        }
    };
    let notification_worker =
        spawn_notification_worker(notification_rx, notification_handler.clone());
    let cancel_worker = spawn_notification_worker(cancel_rx, notification_handler);

    let notification_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut notification_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let cancel_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut cancel_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let dropped_notifications = Arc::new(AtomicU64::new(0));
    while let Some(line) = inbound.recv().await {
        if line.trim().is_empty() {
            continue;
        }
        let msg = match Message::parse(&line) {
            Ok(m) => m,
            Err(e) => {
                conn.send(&Message::err(Value::Null, e));
                continue;
            }
        };
        match msg {
            Message::Request { id, method: m, mut params } => {
                // Once a local connection has been admitted as a trigger
                // principal it is a single-purpose channel. In particular,
                // the local socket must not keep granting ordinary person
                // RPCs after trigger authentication.
                if conn.is_trigger() && !m.starts_with("trigger/chat.") {
                    conn.send(&Message::err(
                        id,
                        RpcError::new(
                            -32001,
                            "trigger connection accepts trigger/chat operations only",
                        )
                        .with_data(json!({"reason": "trigger.connection_scope"})),
                    ));
                    continue;
                }
                let slot = match try_request_slot(&request_slots, &m) {
                    Ok(slot) => slot,
                    Err(()) => {
                        let error = RpcError::new(-32000, "connection request limit reached")
                            .with_data(json!({
                                "reason": "connection.busy",
                                "retryable": true,
                            }));
                        conn.send(&Message::err(id, error));
                        continue;
                    }
                };
                // In order, before the request is spawned: a later request
                // on this connection sees the person decided.
                if m == method::INITIALIZE
                    && conn.origin == Origin::Local
                    && let Some(caller) =
                        params.as_ref().and_then(|p| p.pointer("/_meta/acpmux/callerSession"))
                    && let Some(id) = caller.get("sessionId").and_then(Value::as_str)
                {
                    hub.session_meta(id).await;
                    // Known once adoption has read the earlier run's token (`settle_caller`).
                    if let Some(token) = caller.get("token").and_then(Value::as_str) {
                        hub.settle_caller(id, token).await;
                    }
                }
                conn.bind_person(&hub, &m, &mut params);
                // Before its reply is built: the reply says whether large messages go compressed.
                if m == method::INITIALIZE
                    && let Some(wire) = &conn.wire
                    && crate::frame_compress::offered(params.as_ref())
                {
                    wire.enable();
                }
                let hub = hub.clone();
                let conn = conn.clone();
                tokio::spawn(async move {
                    let _slot = slot;
                    let route = chats::route(&hub, &conn, &m, params.unwrap_or(Value::Null));
                    let (result, sent) = list_reply::scope(id.clone(), &m, route).await;
                    // Its answer went whole into an open queue: one sent as its too-large error, or
                    // to a reader that is gone, opened nothing.
                    let watched = m == method::MUX_WATCH && result.is_ok() && sent == Some(true);
                    // A shared session list, sent already as the bytes it was serialized to.
                    if !(sent.is_some() && result.is_ok()) {
                        let reply = match result {
                            Ok(v) => Message::ok(id, v),
                            Err(mut e) => {
                                // What kind of failure, and what to do (`recovery.rs`).
                                crate::recovery::annotate(&mut e, None);
                                Message::err(id, e)
                            }
                        };
                        conn.send_replying(&reply, Some(&m));
                    }
                    // A Mac that lends GitHub counts from here: its watch answer is queued, so
                    // no action reaches it before the answer that opens its side.
                    if watched
                        && conn.watch_all.load(Ordering::SeqCst)
                        && conn.client_requests.lends_github.load(Ordering::SeqCst)
                    {
                        hub.add_github_owner(&conn);
                    }
                });
            }
            // A read-only machine's notifications (a cancel) change nothing.
            Message::Notification { .. } if conn.auth == ConnAuth::ReadOnlyDevice => {}
            Message::Notification { method: m, params: _ } if conn.is_trigger() => {
                tracing::debug!(conn = %conn.id, method = %m, "ignoring notification on trigger connection");
            }
            Message::Notification { method: m, params } => {
                let params = params.unwrap_or(Value::Null);
                if m == method::SESSION_CANCEL {
                    match admit_notification(
                        &cancel_tx,
                        &cancel_waiters,
                        &mut cancel_waits,
                        (method::SESSION_CANCEL.to_owned(), params),
                    ) {
                        NotificationAdmission::Accepted => {}
                        NotificationAdmission::Closed => break,
                        NotificationAdmission::Dropped => {
                            if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                                tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                            }
                        }
                    }
                    continue;
                }
                match admit_notification(
                    &notification_tx,
                    &notification_waiters,
                    &mut notification_waits,
                    (m, params),
                ) {
                    NotificationAdmission::Accepted => {}
                    NotificationAdmission::Closed => break,
                    NotificationAdmission::Dropped => {
                        if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                            tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                        }
                    }
                }
            }
            // An answer to a request this daemon sent the client (`client_request.rs`).
            Message::Response { id, result, error } => {
                if !conn.is_trigger() {
                    conn.settle_client_request(&id, result, error);
                }
            }
        }
    }
    conn.ended.send_replace(true);
    let preparations: Vec<_> =
        conn.preparation_cancels.lock().unwrap_or_else(|e| e.into_inner()).drain().collect();
    for (session, cancel) in preparations {
        cancel.send_replace(true);
        if let Ok(session) = hub.resolve(&session) {
            session.abandon_prepared_connection(&conn.id);
        }
    }
    // Cancellation has to reach the hub even when ordinary notifications are
    // still draining. Its worker is bounded independently and must never be
    // aborted by connection cleanup.
    for waiter in cancel_waits {
        let _ = waiter.await;
    }
    drop(cancel_tx);
    let _ = cancel_worker.await;

    let deadline = tokio::time::Instant::now() + WORK_BACKPRESSURE_WAIT;
    let mut waiters = notification_waits.into_iter();
    while let Some(mut waiter) = waiters.next() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if tokio::time::timeout(remaining, &mut waiter).await.is_err() {
            waiter.abort();
            let _ = waiter.await;
            for waiter in waiters {
                waiter.abort();
                let _ = waiter.await;
            }
            tracing::debug!(conn = %conn.id, "notification admission waiters did not drain");
            break;
        }
    }
    drop(notification_tx);
    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
    let mut notification_worker = notification_worker;
    if tokio::time::timeout(remaining, &mut notification_worker).await.is_err() {
        notification_worker.abort();
        let _ = notification_worker.await;
    }
    let dropped = dropped_notifications.load(Ordering::Relaxed);
    if dropped > 0 {
        tracing::debug!(conn = %conn.id, dropped, "notification admission drops during connection");
    }
    fan.abort();
    conn.media.close_all();
    conn.remote_media.close_all();
    view::release_all(&hub, &conn);
    // Leases first: ending one is cheap and synchronous, while the ephemeral
    // release awaits each session's kill. A leased peer must not keep
    // reconnecting to a forward port its bridge already closed, which another
    // process could bind (`hub/peer_lease.rs`).
    conn.end_peer_leases(&hub);
    ephemeral::release_all(&hub, &conn).await;
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// An unauthenticated connection: no hub subscription, no session, no
/// data. The first request gets the refusal, then the connection ends.
async fn refuse_unauthenticated(
    inbound: &mut mpsc::Receiver<String>,
    out: &mpsc::Sender<String>,
    origin: Origin,
) {
    tracing::warn!("refusing an unauthenticated {origin:?} connection");
    // Bounded: a client that never sends a request does not hold the task.
    let _ = tokio::time::timeout(FIRST_FRAME, async {
        while let Some(line) = inbound.recv().await {
            match Message::parse(&line) {
                Ok(Message::Request { id, .. }) => {
                    let _ = out.send(Message::err(id, conn_auth::refused()).to_line()).await;
                    return;
                }
                Ok(_) => continue,
                Err(_) if line.trim().is_empty() => continue,
                Err(_) => return,
            }
        }
    })
    .await;
}

/// Turn a hub record into client notifications for one connection.
fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    if ev.record.kind == crate::hub::PEER_LAGGED {
        if conn.sub_opts(&ev.session_id).is_some() {
            conn.send(&Message::notification("_acpmux/lagged", ev.record.msg.clone()));
        }
        return;
    }
    chats::push_activity(hub, conn, &ev);
    processes::push_update(conn, &ev);
    let rec = &ev.record;
    // Attached peer updates retain the raw wire id, but also identify its owner so
    // clients can key live transcripts by the same route as their session rows.
    let routed = |mut params: Value| {
        if let Some(obj) = params.as_object_mut() {
            obj.remove("peer");
            if let Some(remote) = &ev.remote {
                obj.insert("peer".into(), json!(remote.peer));
            }
        }
        params
    };
    let watching = conn.watch_all.load(Ordering::SeqCst);
    let sub = conn.sub_opts(&ev.session_id);
    let attached = sub.is_some();
    if !watching && !attached {
        return;
    }
    if let Some(sub) = &sub
        && rec.dir != "peer"
    {
        // A session message a `session/load` replay already sent here, as its envelope or its
        // notice, is not sent again (`MessageNotices`); an event stream hears only the kinds it
        // asked for, this notice too.
        let message = rec.dir == "mux" && rec.kind == "_acpmux/message";
        let heard = !sub.event_stream || sub.filter.matches(rec);
        let repeat = message && heard && {
            let owner = ev.remote.as_ref().map(|r| r.peer.as_str());
            !conn.message_notices.lock_or_recover().live(owner, &ev.session_id, rec.seq)
        };
        if repeat {
            // Sent by the replay.
        } else if sub.event_stream {
            if sub.filter.matches(rec) {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    routed(event_value(&ev.session_id, rec)),
                ));
            }
        } else {
            // Agent -> client updates as standard ACP notifications.
            if rec.dir == "in"
                && !rec.kind.ends_with(".replay")
                && let Some(m) = rec.msg.get("method").and_then(Value::as_str)
                && m == method::SESSION_UPDATE
            {
                let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                params.set("sessionId", Value::String(ev.session_id.clone()));
                crate::hub::merge_mux_meta(
                    &mut params,
                    json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind}),
                );
                conn.send(&Message::notification(method::SESSION_UPDATE, routed(params)));
            }
            if rec.dir == "mux" {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    routed(event_value(&ev.session_id, rec)),
                ));
            }
        }
        if message && heard && !repeat {
            // Routed as the event beside it: a peer's chat id alone may match one here.
            conn.send(&Message::notification(method::MUX_MESSAGE, routed(rec.msg.clone())));
        }
        if rec.dir == "mux" && is_permission_ask(&rec.kind) {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                routed(permission_pending(&ev.session_id, rec, "attach")),
            ));
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // A peer's prompt the person must answer, for a unix socket or app
            // watcher that did not attach the session (`hub/person.rs` (c)):
            // never relayed on to a Web client or another peer daemon.
            if rec.kind == crate::hub::PEER_PERMISSION_PENDING {
                if !attached && !conn.origin.web_class() {
                    conn.send(&Message::notification(
                        method::MUX_PERMISSION_PENDING,
                        peer_permission_pending(&ev.session_id, rec, &remote.peer),
                    ));
                }
                return;
            }
            // Peers already filter to the interesting kinds and send a summary. Another
            // daemon's link hears no change of a row this daemon mirrors: the link drops every
            // such row (`peer.rs` `watch_sessions`), so each change of one peer's row went out on
            // every other peer's link for nothing (24 copies of every change with one daemon's
            // 25 peers, 2026-10-30), and the row's origin hears it from its own.
            if rec.dir == "peer" && !view::a_link(conn) {
                let sid = remote
                    .summary
                    .get("sessionId")
                    .cloned()
                    .unwrap_or_else(|| Value::String(ev.session_id.clone()));
                conn.send(&Message::notification(
                    method::MUX_SESSION_CHANGED,
                    json!({"sessionId": sid, "session": if attached || conn.watch_tools.load(Ordering::SeqCst) { remote.summary.clone() } else { crate::hub::views::without_summary_tools(remote.summary.clone()) }, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer}),
                ));
            }
            return;
        }
        if rec.dir == "mux" && rec.kind == "purged" {
            // `replaced`: the same chat came back under this id (`Session::replaced`).
            let mut params = json!({"sessionId": ev.session_id, "session": {"sessionId": ev.session_id}, "kind": "purged", "recordKind": "purged", "seq": rec.seq});
            if rec.msg.get("replaced") == Some(&Value::Bool(true)) {
                params.set("replaced", Value::Bool(true));
            }
            conn.send(&Message::notification(method::MUX_SESSION_CHANGED, params));
            return;
        }
        // A deferred new chat has no attachment yet. Its command publication must still wake
        // the page's read of that chat's command list, including when skills arrive after creation.
        if rec.dir != "mux" && rec.kind != "available_commands_update" {
            return;
        }
        let Some(kind) = change_kind::session_change_kind(&rec.kind) else { return };
        if let Ok(s) = hub.resolve(&ev.session_id) {
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": if attached || conn.watch_tools.load(Ordering::SeqCst) { hub.session_summary(&s) } else { hub.session_list_summary(&s) }, "kind": kind, "recordKind": rec.kind, "seq": rec.seq}),
            ));
        }
        // A watcher that is not attached still learns a permission is waiting.
        if is_permission_ask(&rec.kind) && !attached {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                permission_pending(&ev.session_id, rec, "watch"),
            ));
        }
    }
}

fn str_param<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

pub(crate) fn session_key(params: &Value) -> Result<&str, RpcError> {
    str_param(params, "sessionId")
        .or_else(|| str_param(params, "session"))
        .or_else(|| str_param(params, "name"))
        .ok_or_else(|| RpcError::invalid_params("sessionId or session is required"))
}

fn mux_meta(params: &Value) -> Option<&Value> {
    params.get("_meta").and_then(|m| m.get("acpmux"))
}

mod agent_login;
mod agent_messages;
mod app_reply;
mod client_request;
mod clock_text;
pub(crate) use clock_text::{civil_from_days, iso};
mod change_kind;
mod chat_windows;
pub use chat_windows::live_tasks as live_chat_window_tasks;
mod chats;
pub mod conn_auth;
mod ephemeral;
mod fanout;
mod forum;
mod media_forward;
mod mesh_control_send;
pub mod mesh_relay;
pub(super) mod mesh_send;
mod team;
mod trigger_authority;
mod trigger_chat;
pub use conn_auth::ConnAuth;
mod fork_through;
mod harness_admin;
mod harness_enable;
pub(crate) mod host_notice;
mod inventory_watch;
mod lane_parent;
mod list_reply;
use lane_parent::lane_parent;
mod bg_tasks;
pub mod local_app;
pub(crate) mod machine_health;
mod models_fanout;
mod new_worktree;
pub(crate) mod outbox;
mod pairing;
pub mod peer_auth;
mod peer_forward;
mod peer_status;
pub mod peer_text;
mod pending;
mod place;
mod processes;
mod worktrees;
use crate::hub::is_permission_ask;
pub use pending::{event_value, into_event_value};
use pending::{peer_permission_pending, permission_pending};
mod redact;
pub(crate) use peer_forward::strip_asks as strip_peer_asks;
pub(crate) use redact::url_without_secrets;
pub(crate) mod remote_guard;
mod requests;
pub use requests::SESSION_RESUME_FEATURE;
mod routes;
mod secrets;
mod session_auth;
mod session_files;
mod stream;
mod subsessions;
pub(crate) mod trust_gate;
pub mod upload_frames;
mod view;
mod vm_host;
pub(crate) mod wait;
#[cfg(windows)]
mod windows_socket;
use requests::handle_notification;

#[cfg(test)]
#[path = "mirror_relay_tests.rs"]
mod mirror_relay_tests;

#[cfg(test)]
mod request_admission_tests {
    use super::{
        NOTIFICATION_QUEUE_LIMIT, NOTIFICATION_WORK_LIMIT, REQUEST_WORK_LIMIT,
        notification_deadline, request_uses_work_budget, try_request_slot,
    };
    use std::sync::Arc;
    use tokio::sync::Semaphore;

    #[test]
    fn long_running_requests_do_not_consume_short_work_budget() {
        assert!(!request_uses_work_budget(crate::rpc::method::SESSION_PROMPT));
        assert!(!request_uses_work_budget(crate::rpc::method::MUX_WAIT));
        assert!(!request_uses_work_budget(crate::rpc::method::SESSION_NEW));
        assert!(!request_uses_work_budget(crate::rpc::method::SESSION_LOAD));
        assert!(!request_uses_work_budget(crate::rpc::method::SESSION_RESUME));
        assert!(!request_uses_work_budget(crate::rpc::method::SESSION_FORK));
        assert!(!request_uses_work_budget(crate::rpc::method::MUX_ATTACH));
        // A method no handler serves; built, not a literal, so the registry check
        // (protocol::tests) does not read it as a served method.
        let unknown = ["_acpmux", "unknown"].join("/");
        assert!(request_uses_work_budget(&unknown));

        let slots = Semaphore::new(REQUEST_WORK_LIMIT);
        let _holds: Vec<_> = (0..REQUEST_WORK_LIMIT)
            .map(|_| slots.try_acquire().expect("short work slot"))
            .collect();
        assert!(slots.try_acquire().is_err());

        // Open prompts and waits are admitted independently of the finite
        // handler budget, so a connection can keep more than 64 turns open.
        let slots = Arc::new(Semaphore::new(REQUEST_WORK_LIMIT));
        for _ in 0..(REQUEST_WORK_LIMIT + 1) {
            assert!(
                try_request_slot(&slots, crate::rpc::method::SESSION_PROMPT).unwrap().is_none()
            );
        }
    }

    #[test]
    fn cancellation_handlers_have_no_abort_deadline() {
        assert_eq!(notification_deadline(crate::rpc::method::SESSION_CANCEL), None);
        assert_eq!(notification_deadline("$/cancel_request"), Some(super::WORK_BACKPRESSURE_WAIT));
    }

    #[tokio::test]
    async fn accepted_notification_is_drained_after_input_disconnects() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::sync::mpsc;

        let (tx, rx) = mpsc::channel(1);
        let handled = Arc::new(AtomicUsize::new(0));
        let worker = super::spawn_notification_worker(rx, {
            let handled = handled.clone();
            move |_method, _params| {
                let handled = handled.clone();
                async move {
                    handled.fetch_add(1, Ordering::SeqCst);
                }
            }
        });
        tx.send(("session/cancel".to_owned(), serde_json::json!({}))).await.unwrap();
        drop(tx);
        worker.await.unwrap();
        assert_eq!(handled.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn cancellation_lane_is_independent_of_slow_notifications() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use tokio::sync::{Notify, mpsc};

        let (notification_tx, notification_rx) = mpsc::channel(NOTIFICATION_QUEUE_LIMIT);
        let (cancel_tx, cancel_rx) = mpsc::channel(NOTIFICATION_QUEUE_LIMIT);
        let notification_started = Arc::new(Notify::new());
        let release_notifications = Arc::new(Notify::new());
        let cancel_handled = Arc::new(AtomicBool::new(false));

        let notification_worker = super::spawn_notification_worker(notification_rx, {
            let notification_started = notification_started.clone();
            let release_notifications = release_notifications.clone();
            move |_method, _params| {
                let notification_started = notification_started.clone();
                let release_notifications = release_notifications.clone();
                async move {
                    notification_started.notify_one();
                    release_notifications.notified().await;
                }
            }
        });
        let cancel_worker = super::spawn_notification_worker(cancel_rx, {
            let cancel_handled = cancel_handled.clone();
            move |_method, _params| {
                let cancel_handled = cancel_handled.clone();
                async move { cancel_handled.store(true, Ordering::SeqCst) }
            }
        });

        for _ in 0..NOTIFICATION_WORK_LIMIT {
            notification_tx.try_send(("session/update".to_owned(), serde_json::json!({}))).unwrap();
        }
        notification_started.notified().await;
        cancel_tx
            .send((crate::rpc::method::SESSION_CANCEL.to_owned(), serde_json::json!({})))
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while !cancel_handled.load(Ordering::SeqCst) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("cancel lane should not wait for ordinary handlers");

        release_notifications.notify_waiters();
        drop(notification_tx);
        drop(cancel_tx);
        notification_worker.await.unwrap();
        cancel_worker.await.unwrap();
    }

    #[tokio::test]
    async fn cancellation_worker_finishes_after_input_closes() {
        use tokio::sync::{Notify, mpsc};

        let (tx, rx) = mpsc::channel(1);
        let started = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let mut worker = super::spawn_notification_worker(rx, {
            let started = started.clone();
            let release = release.clone();
            move |_method, _params| {
                let started = started.clone();
                let release = release.clone();
                async move {
                    started.notify_one();
                    release.notified().await;
                }
            }
        });

        tx.send((crate::rpc::method::SESSION_CANCEL.to_owned(), serde_json::json!({})))
            .await
            .unwrap();
        started.notified().await;
        drop(tx);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut worker).await.is_err()
        );
        release.notify_one();
        worker.await.unwrap();
    }
}

#[cfg(test)]
#[path = "acp_list_tests.rs"]
mod acp_list_tests;

#[cfg(test)]
#[path = "list_fit_tests.rs"]
mod list_fit_tests;

#[cfg(test)]
#[path = "session_list_pages_tests.rs"]
mod session_list_pages_tests;

#[cfg(test)]
#[path = "watch_delta_link_tests.rs"]
mod watch_delta_link_tests;

#[cfg(test)]
#[path = "compressed_link_tests.rs"]
mod compressed_link_tests;

#[cfg(test)]
mod key_route_tests;

#[cfg(test)]
mod accept_retry_tests {
    use super::{accept_ends_listener, accept_retry_delay};
    use std::io::{Error, ErrorKind};
    use std::time::Duration;

    #[test]
    fn running_out_of_descriptors_pauses_before_the_next_accept() {
        // The queued connection stays queued on EMFILE, so an immediate retry spins a core.
        #[cfg(unix)]
        assert!(accept_retry_delay(&Error::from_raw_os_error(libc::EMFILE)) > Duration::ZERO);
        #[cfg(unix)]
        assert!(accept_retry_delay(&Error::from_raw_os_error(libc::ENFILE)) > Duration::ZERO);
        assert!(accept_retry_delay(&Error::other("no buffers")) > Duration::ZERO);
    }

    #[test]
    fn a_connection_that_died_in_the_queue_retries_at_once() {
        assert_eq!(accept_retry_delay(&Error::from(ErrorKind::ConnectionAborted)), Duration::ZERO);
        assert_eq!(accept_retry_delay(&Error::from(ErrorKind::ConnectionReset)), Duration::ZERO);
        assert_eq!(accept_retry_delay(&Error::from(ErrorKind::Interrupted)), Duration::ZERO);
    }

    #[test]
    fn only_a_listener_that_is_gone_ends_the_accept_loop() {
        // A closed tailnet listener reports end of stream; a closed fd reports EBADF.
        assert!(accept_ends_listener(&Error::from(ErrorKind::UnexpectedEof)));
        #[cfg(unix)]
        assert!(accept_ends_listener(&Error::from_raw_os_error(libc::EBADF)));
        #[cfg(unix)]
        assert!(accept_ends_listener(&Error::from_raw_os_error(libc::EINVAL)));
        // Descriptor exhaustion, a dropped connection or one record that lost its fd pass.
        #[cfg(unix)]
        assert!(!accept_ends_listener(&Error::from_raw_os_error(libc::EMFILE)));
        #[cfg(unix)]
        assert!(!accept_ends_listener(&Error::from_raw_os_error(libc::ENFILE)));
        assert!(!accept_ends_listener(&Error::from(ErrorKind::ConnectionAborted)));
        assert!(!accept_ends_listener(&Error::other("accept failed")));
    }
}

#[cfg(test)]
mod nodelay_tests {
    use super::tune_ws_socket;

    #[tokio::test]
    async fn an_accepted_web_socket_sends_without_nagle_delay() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let _client = tokio::net::TcpStream::connect(address).await.unwrap();
        let (accepted, _) = listener.accept().await.unwrap();
        assert!(!accepted.nodelay().unwrap(), "a fresh socket has Nagle on");
        tune_ws_socket(&accepted);
        assert!(accepted.nodelay().unwrap());
    }
}

#[cfg(test)]
mod outbound_queue_tests {
    use super::{Message, enqueue_after_controls, enqueue_outbound};
    use serde_json::json;
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
    use std::sync::{Arc, Mutex};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn a_slow_reader_gets_a_gap_signal_without_losing_a_response() {
        let (out, mut queued) = mpsc::channel(3);
        out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
        let dropped = Arc::new(AtomicU64::new(0));
        let gap_pending = Arc::new(AtomicBool::new(false));
        let pending_controls = Arc::new(AtomicUsize::new(0));
        let lock = Arc::new(Mutex::new(()));

        enqueue_outbound(
            &out,
            Message::notification("session/update", json!({"kind": "progress"})).to_line(),
            false,
            &dropped,
            &gap_pending,
            &lock,
            &pending_controls,
        );
        enqueue_outbound(
            &out,
            Message::ok(json!(7), json!({"status": "complete"})).to_line(),
            true,
            &dropped,
            &gap_pending,
            &lock,
            &pending_controls,
        );

        assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
        let gap = Message::parse(&queued.recv().await.unwrap()).unwrap();
        let Message::Notification { method, params } = gap else { panic!("{gap:?}") };
        assert_eq!(method, "_acpmux/lagged");
        let params = params.unwrap();
        assert_eq!(params["reason"], "output_queue_full");
        assert_eq!(params["dropped"], 1);
        let response = Message::parse(&queued.recv().await.unwrap()).unwrap();
        assert!(matches!(response, Message::Response { id, .. } if id == json!(7)));
    }

    #[tokio::test]
    async fn a_full_queue_delivers_its_gap_after_the_reader_catches_up() {
        let (out, mut queued) = mpsc::channel(1);
        out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
        let dropped = Arc::new(AtomicU64::new(0));
        let gap_pending = Arc::new(AtomicBool::new(false));
        let pending_controls = Arc::new(AtomicUsize::new(0));
        let lock = Arc::new(Mutex::new(()));

        enqueue_outbound(
            &out,
            Message::notification("session/update", json!({"kind": "progress"})).to_line(),
            false,
            &dropped,
            &gap_pending,
            &lock,
            &pending_controls,
        );
        assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
        let gap = Message::parse(&queued.recv().await.unwrap()).unwrap();
        assert!(matches!(gap, Message::Notification { method, .. } if method == "_acpmux/lagged"));
    }

    /// Review of #26784 at 0a57249: a watch answer that waited for room in a full queue (in a
    /// task of its own) could be passed by the GitHub request sent after it, which the Mac then
    /// refused. That request now waits for no such answer: it is refused until none is left.
    #[tokio::test]
    async fn a_request_in_order_never_passes_an_answer_waiting_for_room() {
        let (out, mut queued) = mpsc::channel(1);
        out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
        let dropped = Arc::new(AtomicU64::new(0));
        let gap_pending = Arc::new(AtomicBool::new(false));
        let pending_controls = Arc::new(AtomicUsize::new(0));
        let lock = Arc::new(Mutex::new(()));
        let answer = Message::ok(json!(7), json!({"sessions": []})).to_line();
        enqueue_outbound(&out, answer, true, &dropped, &gap_pending, &lock, &pending_controls);
        let request =
            || Message::request(json!("acpmux-0"), "_acpmux/github_action", json!({})).to_line();

        // The reader takes a line; the answer still waits for room in its task. The request is
        // refused, and queues nothing.
        assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
        let sent = enqueue_after_controls(
            &out,
            request(),
            &dropped,
            &gap_pending,
            &lock,
            &pending_controls,
        );
        assert!(!sent, "nothing goes ahead of an answer that waits for room");
        let first = Message::parse(&queued.recv().await.unwrap()).unwrap();
        assert!(matches!(first, Message::Response { id, .. } if id == json!(7)));
        // The answer is in the queue, so the request is sent after it.
        while pending_controls.load(std::sync::atomic::Ordering::Acquire) != 0 {
            tokio::task::yield_now().await;
        }
        assert!(enqueue_after_controls(
            &out,
            request(),
            &dropped,
            &gap_pending,
            &lock,
            &pending_controls
        ));
        let next = Message::parse(&queued.recv().await.unwrap()).unwrap();
        assert!(matches!(next, Message::Request { .. }));
    }

    /// Review of #26784 at d0b90b0: a request to a client whose reader was gone counted as sent,
    /// and its action waited out the whole wait before failing.
    #[test]
    fn a_request_in_order_to_a_reader_that_is_gone_is_not_sent() {
        let (out, queued) = mpsc::channel(4);
        drop(queued);
        let (dropped, gap_pending) =
            (Arc::new(AtomicU64::new(0)), Arc::new(AtomicBool::new(false)));
        let (pending, lock) = (Arc::new(AtomicUsize::new(0)), Arc::new(Mutex::new(())));
        let request = Message::request(json!("acpmux-0"), "_acpmux/github_action", json!({}));
        let sent = enqueue_after_controls(
            &out,
            request.to_line(),
            &dropped,
            &gap_pending,
            &lock,
            &pending,
        );
        assert!(!sent);
    }
}

/// Owner-only TLS ingress from the embedded tailnet node.
#[cfg(all(unix, feature = "tailnet"))]
pub mod tailnet_ingress;

#[cfg(test)]
mod message_notice_tests {
    use super::{MESSAGE_NOTICES_KEPT, MessageNoticeBook, MessageNotices};

    /// A long-lived connection keeps a bounded count of one chat's messages: past the bound the
    /// oldest go under the low-water mark, still heard, and newer ones are still told apart.
    #[test]
    fn a_long_lived_chat_keeps_a_bounded_count() {
        let mut n = MessageNotices::default();
        let total = (MESSAGE_NOTICES_KEPT * 3) as u64;
        // Message records are sparse among a chat's records: every third seq.
        for i in 1..=total {
            assert!(n.live(i * 3), "seq {} goes once", i * 3);
            assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
        }
        assert_eq!(n.kept(), MESSAGE_NOTICES_KEPT);
        // Heard ones, under the mark or above it, are not sent again.
        assert!(!n.live(3));
        assert!(!n.live(total * 3));
        // A newer record still goes, and a gap above the mark is still told apart.
        assert!(n.live(total * 3 + 1));
        assert!(n.live(total * 3 - 1));
        assert!(!n.live(total * 3 - 1));
        assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
    }

    /// A replay's older record still goes once more live records than the bound have raised the
    /// low-water mark past it: the replay never sent it, and a repeat beats a loss.
    #[test]
    fn a_replay_record_below_a_risen_floor_still_goes() {
        let mut n = MessageNotices::default();
        // The reopen's replay is at seq 10 when the live stream sends more than the bound.
        let live_from = 1_000u64;
        for seq in live_from..live_from + MESSAGE_NOTICES_KEPT as u64 + 10 {
            assert!(n.live(seq));
        }
        assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
        // The replay reaches records the live stream never sent, below the risen mark.
        assert!(n.replay(10));
        assert!(n.replay(live_from + 5), "the replay sends what the bound forgot again");
        // Ones the live stream sent and still keeps are not sent again.
        assert!(!n.replay(live_from + MESSAGE_NOTICES_KEPT as u64));
        assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
    }

    /// A peer's chat that keeps the raw id of one here (an export and import keeps ids) counts its
    /// own seqs: neither chat's record silences the other's of the same seq.
    #[test]
    fn a_peer_chat_with_a_local_raw_id_hears_its_own_messages() {
        let mut book = MessageNoticeBook::default();
        assert!(book.live(None, "c", 3));
        assert!(book.live(Some("p"), "c", 3));
        assert!(!book.live(None, "c", 3));
        assert!(!book.live(Some("p"), "c", 3));
        assert!(book.live(Some("q"), "c", 3));
        // A reopen of the peer's chat replays it afresh and ends the local chat's count.
        book.reopen(Some("p"), "c");
        assert!(book.replay(Some("p"), "c", 3));
        assert!(book.live(None, "c", 3));
        // Detaching the local chat leaves the peer's count.
        book.forget(None, "c");
        assert!(!book.live(Some("p"), "c", 3));
        // Switching to the local chat drops every peer's count of that raw id.
        book.forget_others(None, "c");
        assert!(book.live(Some("p"), "c", 3));
        // A chat with no count from a reopen sends its replay.
        assert!(book.replay(None, "d", 1));
    }

    /// A replay racing the live stream sends each message notice once, whichever sends first.
    #[test]
    fn a_message_notice_goes_once_across_replay_and_live() {
        // A record heard once is not heard again live (another viewer's reopen of a peer's chat
        // replays it over the shared link); a record of no known seq always goes.
        let mut n = MessageNotices::default();
        assert!(n.live(2));
        assert!(!n.live(2));
        assert!(n.live(0));
        assert!(n.live(0));
        // The live stream sent seq 5 while the replay was at 3: the replay skips only 5.
        let mut n = MessageNotices::default();
        assert!(n.live(5));
        assert!(n.replay(3));
        assert!(!n.replay(5));
        assert!(n.replay(6));
        assert!(!n.live(6));
        // A peer's replay reaches a viewer as live records: an older one after a newer one
        // still goes.
        let mut n = MessageNotices::default();
        assert!(n.live(9));
        assert!(n.live(4));
        assert!(!n.live(4));
        // The replay sent 3 and 4 before the live stream reached them.
        let mut n = MessageNotices::default();
        assert!(n.replay(3));
        assert!(n.replay(4));
        assert!(!n.live(4));
        assert!(n.live(5));
    }
}
