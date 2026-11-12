//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{EventFilter, Hub, HubEvent, VERSION};
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};
use crate::sender_harness::SocketPeer;
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
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::{Semaphore, broadcast, mpsc};
/// Windows: the daemon socket is `cmux::local_socket` (AF_UNIX with its
/// same-user checks), in `windows_socket.rs`.
#[cfg(windows)]
pub use windows_socket::{UnixListener, bind_unix, router_admin, serve_unix};

pub(crate) mod dual_requests;
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
    /// The owner of this connection's own tasks (each request it sent, a reply waiting for room),
    /// a child of the hub's scope. A request a client sent before it hung up still runs to its
    /// end (a `--no-wait` send is accepted), so the connection's end does not cancel them; the
    /// hub's shutdown does, and joins them.
    scope: cmux_scope::Scope,
    pub id: String,
    /// The listener this connection came in on.
    pub origin: Origin,
    /// The proof it presented (`conn_auth.rs`); what the mode rule reads.
    pub auth: ConnAuth,
    /// The paired machine whose credential it presented (`ConnAuth::Device`
    /// or `ReadOnlyDevice`), from the handshake only, never from a request.
    device: Option<String>,
    /// The person the Cloud carrier attested (`carrier.rs`), from the carrier socket's upgrade
    /// header only, never from a request. Set exactly when `auth` is a carrier proof.
    carrier: Option<carrier::Attested>,
    /// It reads session text raw (`peer_text.rs`): every origin but a peer.
    raw_text: bool,
    name: StdMutex<String>,
    /// Its count in the daemon's unused rule (`daemon/unused_exit.rs`): an `initialize` that says
    /// it only observes marks it, so it keeps nothing once the owner app exited.
    presence: crate::daemon::unused_exit::Presence,
    out: mpsc::Sender<String>,
    /// Holds its lines until what they may show is durable (`durable_gate.rs`); None without the
    /// event journal.
    gate: Option<Arc<durable_gate::Gate>>,
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
    /// The unix socket peer's pid, read at accept (`SO_PEERCRED`, `LOCAL_PEERPID`), or the daemon's
    /// own outbox: where a send's process chain is walked from and whose check is carried
    /// (`sender_harness::check_trust`), provenance only, never a proof.
    pub(super) socket_peer: crate::sender_harness::SocketPeer,
    /// A unix socket peer that is root while this daemon is not (Linux, `daemon/provision.rs`):
    /// the VM provisioning exec, the one caller besides the signed app that may give the person key.
    /// Only a Cloud machine's daemon, not dumpable since its start, has one.
    provisioner: bool,
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
    /// What a first unix `initialize` declared about its caller (`cli_caller.rs`); unset for a
    /// client that is no acpmux CLI and declared nothing.
    declared: std::sync::OnceLock<crate::cli_caller::Declared>,
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
    /// The client's requests being served, by id, with their slots: what its
    /// `$/cancel_request` finds (`in_flight.rs`).
    in_flight: in_flight::InFlight,
    /// Its windows over the chat index (`chat_windows.rs`).
    chat_windows: chat_windows::ConnWindows,
    /// Its refused Stops that wait for room (`requests/cancel_refused.rs`).
    cancel_refusals: Arc<requests::cancel_refused::Waiting>,
    /// A WebSocket's compression, which its `initialize` turns on (`frame_compress.rs`); None
    /// on a transport whose writer does not compress.
    wire: Option<Arc<crate::frame_compress::Wire>>,
    /// Who it is to the book of requests sent on two paths (`dual_requests.rs`): only a peer
    /// daemon's own link over the WebSocket listener (its peer token proven at the upgrade) has
    /// one. Every other connection's `dualId` is ignored.
    pub(crate) dual_principal: Option<&'static str>,
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

    /// What its first `initialize` declared about its caller (`cli_caller.rs`).
    pub(super) fn declared(&self) -> Option<&crate::cli_caller::Declared> {
        self.declared.get()
    }

    /// Whether an unnamed send on it may still be the owner's terminal send: it declared a
    /// terminal, or it is no acpmux CLI and declared nothing (`requests.rs` `owner_terminal`).
    pub(super) fn may_be_owner_terminal(&self) -> bool {
        self.declared().is_none_or(crate::cli_caller::Declared::may_be_owner_terminal)
    }

    /// Whether an agent may be behind it rather than the owner's terminal: it named a session
    /// (proven or not), or it declared no terminal (`cli_caller.rs`). Never for the proven person.
    pub(super) fn agent_side(&self) -> bool {
        !self.is_person()
            && (self.caller().is_some()
                || self.unproven_caller.get().is_some()
                || !self.may_be_owner_terminal())
    }

    /// Whether it proved no session and an agent may be behind it: neither the person's terminal
    /// nor a proven agent (an old acpmux CLI, a shell that declared no terminal, a token this
    /// daemon does not know). Such a connection gets no person verb (team messages, the
    /// person's workflow runs) and no agent's either.
    pub(super) fn unproven_agent(&self) -> bool {
        self.caller().is_none() && self.agent_side()
    }

    /// The refusal of `what` for this connection: `otherwise`, or, for an old acpmux CLI that
    /// proved no session, the one refusal that names it and says which CLI to run
    /// (`cli_caller::old_cli_refused`). A proven agent on an old CLI is refused as any agent: an
    /// update would not change its answer.
    pub(super) fn refusal(
        &self,
        what: &str,
        otherwise: crate::rpc::RpcError,
    ) -> crate::rpc::RpcError {
        let old = self.declared().and_then(crate::cli_caller::Declared::old_client);
        match old.filter(|_| self.caller().is_none()) {
            Some(client) => crate::cli_caller::old_cli_refused(client, what),
            None => otherwise,
        }
    }

    /// The refusal of a verb only the person's own terminal may use, for this connection
    /// ([`Conn::refusal`] of `person_required`).
    pub(super) fn person_only(&self, what: &str) -> crate::rpc::RpcError {
        self.refusal(what, crate::hub::person::person_required(what))
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
        if let Some(declared) =
            params.as_ref().filter(|_| first_local).and_then(crate::cli_caller::of_initialize)
        {
            let _ = self.declared.set(declared);
        }
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

    /// The next line may show every change acknowledged so far (`durable_gate.rs`).
    fn raise_gate(&self) {
        if let Some(gate) = &self.gate {
            gate.raise();
        }
    }

    /// A notification line built for every connection that reads it raw (a shared `session/update`,
    /// `HubEvent::update_line`), as `send` would enqueue it for a local connection.
    // perf-hot: 1us acpmux-token-fanout (every streamed token, per attached connection)
    fn send_line(&self, line: &str) {
        self.raise_gate();
        enqueue_outbound(
            &self.out,
            line.to_owned(),
            false,
            &self.outbound_dropped,
            &self.outbound_gap_pending,
            &self.outbound_lock,
            &self.outbound_pending_controls,
        );
    }

    /// [`Self::send`] of the reply to a request whose method is `reply_to`: the size watch names
    /// it (`wire_size.rs`).
    fn send_replying(&self, msg: &Message, reply_to: Option<&str>) {
        self.raise_gate();
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
    /// `claim` takes the request's in-flight entry as the reply is queued, under the outbound
    /// lock (`in_flight.rs`): a cancel that answered it first leaves the reply unsent
    /// (Some(false)), and one read after it finds nothing to answer, so the client never gets
    /// both the list and the cancelled error.
    fn send_serialized(
        &self,
        id: &Value,
        method: Option<&str>,
        claim: Option<&in_flight::Claim>,
        result: Arc<String>,
        seen: u64,
        anyway: bool,
    ) -> Option<bool> {
        // A result past the cap alone is refused before its line is made: no copy of it.
        let (line, bytes, whole) = if result.len() > crate::rpc::MAX_MESSAGE_BYTES {
            let error = Message::err(id.clone(), RpcError::too_large(result.len())).to_line();
            (error, result.len(), false)
        } else {
            let line = list_reply::reply_line_in(id, result);
            let bytes = line.len();
            if bytes <= crate::rpc::MAX_MESSAGE_BYTES {
                (line, bytes, true)
            } else {
                (Message::err(id.clone(), RpcError::too_large(bytes)).to_line(), bytes, false)
            }
        };
        let lag = || {
            let lag = json!({"watch": true, "dropped": 0, "reason": "list_changed"});
            Message::notification("_acpmux/lagged", lag).to_line()
        };
        self.raise_gate();
        let _guard = self.outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
        let stale = self.notices.load(Ordering::SeqCst) != seen;
        if stale && !anyway {
            return None;
        }
        if claim.is_some_and(|claim| !self.in_flight.claim(claim)) {
            return Some(false);
        }
        let what = method.map_or(crate::wire_size::What::Reply, crate::wire_size::What::ReplyTo);
        crate::wire_size::observe(what, bytes);
        // Each client's share of the list it is sent (`list_bytes.rs`), by its name and origin.
        if matches!(method, Some(crate::rpc::method::MUX_WATCH | crate::rpc::method::MUX_SESSIONS))
        {
            let name = self.name.lock_or_recover().clone();
            let name = if name.is_empty() { "(unnamed)" } else { name.as_str() };
            crate::list_bytes::global().observe(&format!("{name} ({:?})", self.origin), bytes);
        }
        match self.out.try_send(line) {
            Ok(()) if stale => self.enqueue_control_locked(lag()),
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Closed(_)) => return Some(false),
            // No room: it waits for some, and a notice may go first; then the lag follows it.
            Err(mpsc::error::TrySendError::Full(line)) => {
                let (out, notices) = (self.out.clone(), self.notices.clone());
                let pending = self.outbound_pending_controls.clone();
                pending.fetch_add(1, Ordering::AcqRel);
                self.scope.spawn_named("conn-reply-waits-for-room", async move {
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
        self.raise_gate();
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
        crate::home_fs::create_dir_all(parent, 0o700)?;
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
        crate::home_fs::remove_file(path)?;
    }
    crate::config::refuse_lost_home(&crate::config::home())?;
    let listener = UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        crate::home_fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
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
            // A root peer of a Cloud machine's daemon may carry the person key (`daemon/provision.rs`).
            let provisioner = crate::daemon::provision::accept_provisioner(&stream);
            let socket_peer = stream
                .peer_cred()
                .ok()
                .and_then(|c| c.pid())
                .and_then(|p| u32::try_from(p).ok())
                .map_or(SocketPeer::Unknown, SocketPeer::Pid);
            stream::serve_stream(hub, stream, peer, provisioner, socket_peer).await;
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
/// `Origin`, and, for the WebSocket, the token, which is mandatory and
/// comes only from a header (`ws_auth.rs`).
pub async fn listen_ws(hub: Arc<Hub>, addr: String, token: String) -> Result<()> {
    let listener = bind_ws(&addr).await?;
    serve_ws(hub, listener, token).await
}

/// Bind the dashboard/WebSocket port on loopback. `127.0.0.1:0` picks a free
/// port; read it back with `local_addr`. A network address is refused
/// (`ws_auth::check_listen`); [`bind_ws_with`] takes the person's opt-in.
pub async fn bind_ws(addr: &str) -> Result<TcpListener> {
    bind_ws_with(addr, false).await
}

/// [`bind_ws`], binding a network (non-loopback) address too when
/// `allow_network` (`--insecure-network-listen`,
/// `websocket.allowInsecureNetwork`).
pub async fn bind_ws_with(addr: &str, allow_network: bool) -> Result<TcpListener> {
    check_listen_address(addr, allow_network).await?;
    let listener = TcpListener::bind(addr).await.with_context(|| format!("bind {addr}"))?;
    let bound = listener.local_addr().with_context(|| format!("bind {addr}"))?;
    // The address that was bound, should a name resolve differently now.
    ws_auth::check_listen(addr, &[bound], allow_network)?;
    if !ws_auth::is_loopback(&bound) {
        tracing::warn!(
            "the web + websocket listener {bound} is on a network address (opted in): plain ws:// sends the listener token in clear"
        );
    }
    tracing::info!("web + websocket listening on {bound}");
    Ok(listener)
}

/// Refuse `addr` before binding it when any address it names is not
/// loopback and the person did not opt in.
pub async fn check_listen_address(addr: &str, allow_network: bool) -> Result<()> {
    if allow_network {
        return Ok(());
    }
    let addrs: Vec<std::net::SocketAddr> = match addr.parse() {
        Ok(one) => vec![one],
        Err(_) => tokio::net::lookup_host(addr).await.map(Iterator::collect).unwrap_or_default(),
    };
    ws_auth::check_listen(addr, &addrs, false)
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
            let mut stream = stream;
            // The whole head routes the request (`ws_peek.rs`). Each path checks it: serve_http
            // as it reads, tungstenite as it parses it again for the callback.
            let mut probed = false;
            let (head, read) = loop {
                let (head, read) = match ws_peek::request(&mut stream, peer).await {
                    ws_peek::Request::Head { head, read } => (head, read),
                    ws_peek::Request::TooLarge => {
                        refuse_http(stream, Refusal::MissingHost).await;
                        return;
                    }
                    ws_peek::Request::Gone => return,
                };
                // The cmux link proves this is the listener `listener.json` names before it
                // sends a paired peer's bytes (`listener_record.rs`): it answers the link's
                // challenge under the record's key, for the probe alone, once.
                let Some(answer) = crate::listener_record::probe_answer(&read) else {
                    break (head, read);
                };
                if probed {
                    return;
                }
                probed = true;
                if tokio::io::AsyncWriteExt::write_all(&mut stream, answer.as_bytes())
                    .await
                    .is_err()
                {
                    return;
                }
            };
            if !head.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &head, &policy, peer).await;
                return;
            }
            let stream = ws_peek::Replayed::new(read, stream);
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
                // The Cloud carrier's header is read on the carrier socket only (`carrier.rs`).
                if !values(carrier::HEADER).is_empty() {
                    return Err(carrier::wrong_socket_response());
                }
                *record_origins.lock().unwrap_or_else(|e| e.into_inner()) =
                    values("origin").into_iter().map(str::to_owned).collect();
                *record_peer.lock().unwrap_or_else(|e| e.into_inner()) =
                    values(peer_auth::HEADER).into_iter().map(str::to_owned).collect();
                // Only a header carries the token, never the URL (`ws_auth.rs`).
                let presented =
                    ws_auth::presented(&values("authorization"), &values("sec-websocket-protocol"))
                        .map_err(refuse)?;
                let tickets = values(crate::pairing::TICKET_HEADER);
                let proof = pairing::admit(&pairing_hub, peer, presented.token, &tickets, &expected);
                *record_admitted.lock().unwrap_or_else(|e| e.into_inner()) = proof.map_err(refuse)?;
                let mut resp = resp;
                if presented.answer_protocol {
                    resp.headers_mut().insert(
                        "sec-websocket-protocol",
                        tokio_tungstenite::tungstenite::http::HeaderValue::from_static(
                            ws_auth::PROTOCOL,
                        ),
                    );
                }
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
                } else if auth.from_page(&hello) {
                    // The pane read no token or another launch's: every Claude chat of this
                    // machine refuses it (D13). Said here, so the log explains the refusal.
                    tracing::warn!(
                        "a pane connection from {peer} without this launch's LocalApp token: served as remote-origin"
                    );
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
            serve_connection_from(hub, in_rx, out_tx, origin, proof, None, false, SocketPeer::Unknown, device, Some(wire), None)
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

/// Minimal HTTP for the dashboard. The whole head passes the listener rule
/// first; then GET / serves the page, and anything else is 404. The page is
/// static and holds no secret: it reads the token from its URL fragment,
/// which never reaches a server, and its WebSocket presents it.
async fn serve_http(
    mut stream: tokio::net::TcpStream,
    head: &str,
    policy: &ListenerPolicy,
    peer: std::net::SocketAddr,
) {
    if let Err(refusal) = check_head(policy, head) {
        tracing::warn!("web request from {peer} refused: {refusal}");
        refuse_http(stream, refusal).await;
        return;
    }
    let first = head.lines().next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method_ = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let path = target.split_once('?').map_or(target, |(path, _)| path);
    let (status, body, ctype) = if !method_.eq_ignore_ascii_case("get") {
        ("405 Method Not Allowed", "method not allowed".to_owned(), "text/plain")
    } else if path == "/health" {
        ("200 OK", "ok".to_owned(), "text/plain")
    } else if path == "/" || path == "/index.html" {
        ("200 OK", INDEX_HTML.to_owned(), "text/html; charset=utf-8")
    } else {
        ("404 Not Found", "not found".to_owned(), "text/plain")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nreferrer-policy: no-referrer\r\nconnection: close\r\n\r\n{body}",
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

/// The daemon's own outbox delivering a send it kept (`outbox.rs` `attempt_once`): served as
/// `origin` with its proof, and the one local connection whose `senderHarnessChecked` is the
/// daemon's own (`sender_harness::check_trust`).
pub(super) async fn serve_outbox_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    let auth = ConnAuth::proven_for(origin);
    serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        false,
        SocketPeer::Outbox,
        None,
        None,
        None,
    )
    .await
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
    serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        false,
        SocketPeer::Unknown,
        None,
        None,
        None,
    )
    .await
}

/// The usage-patterns key of a listener.
fn origin_usage_key(origin: Origin) -> &'static str {
    match origin {
        Origin::Local => "local",
        Origin::Web => "web",
        Origin::LocalApp => "app",
        Origin::Peer => "peer",
    }
}

/// `serve_connection_authed` for a unix socket peer named by its audit token.
async fn serve_connection_from(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
    provisioner: bool,
    socket_peer: SocketPeer,
    device: Option<String>,
    wire: Option<Arc<crate::frame_compress::Wire>>,
    carrier: Option<carrier::Attested>,
) {
    // A carrier proof comes with the person the carrier socket read, and only with it.
    let carried = matches!(auth, ConnAuth::CarrierOwner | ConnAuth::CarrierTeam);
    let auth = if carried != carrier.is_some() { ConnAuth::None } else { auth };
    if !auth.authenticated() {
        refuse_unauthenticated(&mut inbound, &out, origin).await;
        return;
    }
    // Counted while it is served: a daemon with none stops once unused (`daemon/unused_exit.rs`).
    let client = crate::daemon::unused_exit::client();
    let raw_text = !peer_text::masks(origin);
    let (out, gate) = durable_gate::install(hub.store.durability(), out);
    // The listener's own peer link: the only transport with a writer that compresses (`wire`)
    // and a peer token checked at its upgrade; not a paired machine, nor an in-process carrier.
    let dual_principal = (wire.is_some() && auth == ConnAuth::PeerToken && device.is_none())
        .then_some(dual_requests::PEER_LINK);
    // Opt-in usage patterns: connections by listener, and distinct paired machines (an opaque
    // stand-in for the device id, never the id).
    if cmux_usage_patterns::enabled() {
        cmux_usage_patterns::count("acpmux-connection", origin_usage_key(origin));
        if let Some(device) = device.as_deref() {
            cmux_usage_patterns::count("machine", &cmux_usage_patterns::opaque_id(device));
        }
    }
    let conn = Arc::new(Conn {
        scope: hub.scope.child("acpmux conn"),
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        auth,
        device,
        carrier,
        raw_text,
        name: StdMutex::new(String::new()),
        presence: client.presence(),
        out,
        gate,
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
        socket_peer,
        provisioner,
        requests: std::sync::atomic::AtomicU64::new(0),
        challenged: AtomicBool::new(false),
        nonce: crate::hub::person::new_nonce(),
        person: AtomicBool::new(false),
        trigger: StdMutex::new(None),
        holds_calls: std::sync::atomic::AtomicU32::new(0),
        caller: std::sync::OnceLock::new(),
        unproven_caller: std::sync::OnceLock::new(),
        declared: std::sync::OnceLock::new(),
        peer_leases: StdMutex::new(Some(Vec::new())),
        ephemeral: StdMutex::new(Some(Vec::new())),
        ended: tokio::sync::watch::Sender::new(false),
        preparation_cancels: StdMutex::new(HashMap::new()),
        // A peer daemon's link carries all its clients' reads, which it caps one by one
        // (`media_forward.rs`).
        media: if auth.peer_daemon() {
            crate::hub::media_handles::Handles::for_peer_link()
        } else {
            crate::hub::media_handles::Handles::default()
        },
        remote_media: media_forward::RemoteMedia::default(),
        client_requests: Default::default(),
        in_flight: in_flight::InFlight::counted(hub.requests_in_flight.clone()),
        chat_windows: Default::default(),
        cancel_refusals: Default::default(),
        wire,
        dual_principal,
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
                // The host's sender token (`sender_token.rs`) leaves the request here, before
                // anything reads, stores, logs or forwards it; only a send's checks see it.
                let sender_token = params.as_mut().and_then(crate::sender_token::take);
                conn.bind_person(&hub, &m, &mut params);
                if m == method::INITIALIZE {
                    requests::note_initialize(&conn, params.as_ref().unwrap_or(&Value::Null));
                }
                // Before its reply is built: the reply says whether large messages go compressed.
                if m == method::INITIALIZE
                    && let Some(wire) = &conn.wire
                    && crate::frame_compress::offered(params.as_ref())
                {
                    wire.enable();
                }
                // A peer link sent this request on two paths (`dual_requests.rs`): in order, so
                // the copy read first runs it and the other answers with its answer.
                let seen = dual_requests::key_for(conn.dual_principal, &m, params.as_ref());
                let dual_key = seen.as_ref().map(|(key, _)| key.clone());
                let dual = seen.and_then(dual_requests::admit);
                let dual_key = dual_key.filter(|_| dual.is_some());
                // Registered in order, before the request is spawned: a `$/cancel_request` read
                // after it finds it, and taking it frees its slot (`in_flight.rs`).
                let mut ticket = conn.in_flight.begin(&id, &m, slot, dual_key);
                #[cfg(test)]
                cancel_classes_tests::after_begin(&conn);
                let owner = conn.clone();
                let hub = hub.clone();
                let conn = conn.clone();
                owner.scope.spawn_named("conn-request", async move {
                    let mut first = match dual_requests::before_run(dual).await {
                        Ok(first) => first,
                        Err(answer) => {
                            // A cancel's part on this connection is its own (`dual_requests.rs`).
                            if m == method::SESSION_CANCEL {
                                requests::cancel_on_connection(&hub, &conn, params.as_ref());
                            }
                            if conn.in_flight.finish(&ticket) {
                                conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                            }
                            return;
                        }
                    };
                    let route = || {
                        chats::route(&hub, &conn, &m, params.unwrap_or(Value::Null), sender_token)
                    };
                    let cancel =
                        std::mem::replace(&mut ticket.cancel, tokio::sync::oneshot::channel().1);
                    let claim = ticket.claim();
                    let serve = async {
                        let stage = crate::hub::RequestStage::Dispatch;
                        hub.request_hold(stage, &m, &id).await;
                        list_reply::scope(id.clone(), &m, claim, route).await
                    };
                    // A cancel of its copy on another connection stops it too (`dual_requests.rs`).
                    let also = first.as_mut().and_then(dual_requests::First::take_stop);
                    let served = crate::request_cancel::until_either(cancel, also, serve).await;
                    // Cancelled: the cancel answered it, and a copy sent on another path gets
                    // that answer too (`dual_requests.rs`).
                    let Some((result, sent)) = served.filter(|_| conn.in_flight.finish(&ticket))
                    else {
                        // Stopped by a cancel of its copy on another connection: this copy's
                        // answer here is still owed, and is the cancel's.
                        if conn.in_flight.finish(&ticket) {
                            let cancelled = Err(crate::request_cancel::cancelled_error());
                            conn.send_replying(
                                &dual_requests::reply(id.clone(), cancelled),
                                Some(&m),
                            );
                        }
                        tracing::debug!(
                            target: crate::request_cancel::LOG_TARGET,
                            conn = %conn.id,
                            id = %id,
                            method = %m,
                            "dropped the answer to a request its client cancelled"
                        );
                        dual_requests::finish(
                            first,
                            Some(&Err(crate::request_cancel::cancelled_error())),
                        );
                        return;
                    };
                    // Opt-in usage patterns: methods this daemon serves (an unknown name a client
                    // made up is no key), `/` as `.` so `_acpmux/chat/list` is one key.
                    if cmux_usage_patterns::enabled()
                        && result.as_ref().err().is_none_or(|e| e.code != -32601)
                    {
                        cmux_usage_patterns::count("acpmux-method", &m.replace('/', "."));
                    }
                    // Its answer went whole into an open queue: one sent as its too-large error, or
                    // to a reader that is gone, opened nothing.
                    let watched = m == method::MUX_WATCH && result.is_ok() && sent == Some(true);
                    // A shared session list, sent already as the bytes it was serialized to.
                    if !(sent.is_some() && result.is_ok()) {
                        let answer = result.map_err(|mut e| {
                            // What kind of failure, and what to do (`recovery.rs`).
                            crate::recovery::annotate(&mut e, None);
                            e
                        });
                        dual_requests::finish(first, Some(&answer));
                        conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                    } else {
                        dual_requests::finish(first, None);
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
            // The client gives up on one of its requests: answered as cancelled at once, its
            // slot freed, and its work dropped, which tells the agent or peer it waited on
            // (`request_cancel.rs`). In order: it finds every request read before it. Before
            // every class's own filter (review F3 of #41285): it touches only this connection's
            // own requests, so a read-only machine, a teammate and a trigger may send it.
            Message::Notification { method: m, params } if m == method::CANCEL_REQUEST => {
                if let Some(id) = params.as_ref().and_then(crate::request_cancel::named_id)
                    && let Some((cancelled, dual)) = conn.in_flight.cancel(id)
                {
                    // One copy of a request sent on two paths: the copy that runs stops,
                    // whichever connection it came on, and a later one never runs.
                    if let Some(key) = dual {
                        dual_requests::cancel(&key);
                    }
                    let error = crate::request_cancel::cancelled_error();
                    conn.send_replying(&Message::err(id.clone(), error), Some(&cancelled));
                }
            }
            // A read-only machine's other notifications (a session cancel) change nothing.
            Message::Notification { .. } if conn.auth == ConnAuth::ReadOnlyDevice => {}
            // A teammate through the carrier stops a turn, nothing else (`carrier.rs`).
            Message::Notification { method: m, params }
                if !carrier::takes_notification(&hub, &conn, &m, params.as_ref()) => {}
            Message::Notification { method: m, params: _ } if conn.is_trigger() => {
                tracing::debug!(conn = %conn.id, method = %m, "ignoring notification on trigger connection");
            }
            // The second copy of a notification a peer link sent on two paths.
            Message::Notification { method: m, params }
                if dual_requests::key_for(conn.dual_principal, m.as_str(), params.as_ref())
                    .is_some_and(|seen| !dual_requests::first_notification(seen)) =>
            {
                if m == method::SESSION_CANCEL {
                    requests::cancel_on_connection(&hub, &conn, params.as_ref());
                }
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
                if !conn.is_trigger() && conn.auth != ConnAuth::CarrierTeam {
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
    // A chat's cold archive came or went (`hub/cold_archive.rs`): its row's `coldArchive`. Not a
    // logged record, so nothing but this notice goes out for it.
    if ev.record.dir == crate::hub::COLD_CHANGED {
        let attached = conn.sub_opts(&ev.session_id).is_some();
        if (attached || conn.watch_all.load(Ordering::SeqCst))
            && let Ok(s) = hub.resolve(&ev.session_id)
        {
            let session = if attached || conn.watch_tools.load(Ordering::SeqCst) {
                hub.session_summary(&s)
            } else {
                hub.session_list_summary(&s)
            };
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": session, "kind": crate::hub::COLD_CHANGED, "recordKind": crate::hub::COLD_CHANGED, "seq": s.meta().last_seq}),
            ));
        }
        return;
    }
    chats::push_activity(hub, conn, &ev);
    processes::push_update(conn, &ev);
    let rec = &ev.record;
    // Attached peer updates retain the raw wire id, but also identify its owner and the id its
    // row has here (`qualifiedSessionId`), so clients key live transcripts and prompts by the
    // same route as their session rows. A peer daemon's link names it by its own route.
    let routed = |mut params: Value| {
        if conn.origin != Origin::Peer
            && let Some(remote) = &ev.remote
        {
            races::peer::qualify_event(&remote.peer, &mut params);
            params.set("qualifiedSessionId", Value::String(remote.qualified_id(&ev.session_id)));
        }
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
        let heard = !sub.event_stream || sub.filter.matches_live(rec);
        let repeat = message && heard && {
            let owner = ev.remote.as_ref().map(|r| r.peer.as_str());
            !conn.message_notices.lock_or_recover().live(owner, &ev.session_id, rec.seq)
        };
        if repeat {
            // Sent by the replay.
        } else if sub.event_stream {
            if sub.filter.matches_live(rec) {
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
                let message = || {
                    hub.session_update_encodes.fetch_add(1, Ordering::Relaxed);
                    let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    params.set("sessionId", Value::String(ev.session_id.clone()));
                    crate::hub::merge_mux_meta(
                        &mut params,
                        json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind}),
                    );
                    Message::notification(method::SESSION_UPDATE, routed(params))
                };
                if conn.origin == Origin::Peer {
                    // A peer daemon's link redacts and masks per connection (`send_replying`).
                    conn.send(&message());
                } else {
                    // Every other connection reads the line as it is: built once per record,
                    // shared (`HubEvent::update_line`). None: too large for one frame.
                    let line = ev
                        .update_line
                        .get_or_init(|| message().bounded_line_replying(None).ok().map(Arc::from));
                    match line {
                        Some(line) => conn.send_line(line),
                        None => conn.send(&message()),
                    }
                }
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
                        peer_permission_pending(&ev.session_id, rec, remote),
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
                    json!({"sessionId": sid, "qualifiedSessionId": remote.qualified_id(&ev.session_id), "session": if attached || conn.watch_tools.load(Ordering::SeqCst) { remote.summary.clone() } else { crate::hub::views::without_summary_tools(remote.summary.clone()) }, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer}),
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
        // Built once per record, by the first watcher that sends it, and shared by the others
        // (`HubEvent::row`): with many watchers, each built the whole row again.
        let full = attached || conn.watch_tools.load(Ordering::SeqCst);
        let [list_row, full_row] = &*ev.row;
        let row = if full { full_row } else { list_row };
        let summary = match row.get() {
            Some(summary) => Some(summary),
            None => hub.resolve(&ev.session_id).ok().map(|s| {
                row.get_or_init(|| {
                    if full { hub.session_summary(&s) } else { hub.session_list_summary(&s) }
                })
            }),
        };
        if let Some(summary) = summary {
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": summary, "kind": kind, "recordKind": rec.kind, "seq": rec.seq}),
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
#[cfg(test)]
#[path = "cancel_classes_tests.rs"]
mod cancel_classes_tests;
#[cfg(test)]
#[path = "cancel_prompt_tests.rs"]
mod cancel_prompt_tests;
mod client_request;
mod clock_text;
mod in_flight;
pub(crate) use clock_text::{civil_from_days, iso};
mod change_kind;
mod chat_windows;
pub use chat_windows::live_tasks as live_chat_window_tasks;
pub mod carrier;
mod chats;
pub mod conn_auth;
mod durable_gate;
mod ephemeral;
mod fanout;
mod fix_from_link;
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
mod goal;
pub mod local_app;
pub(crate) mod machine_health;
mod memory_inbox;
mod models_fanout;
mod new_worktree;
mod outbound;
mod plan_build;
mod project_new;
mod prompt_coach;
mod review_queue;
mod run_elsewhere;
use outbound::{
    OUTBOUND_CONTROL_RESERVE, enqueue_after_controls, enqueue_outbound, enqueue_outbound_locked,
    report_outbound_loss_locked,
};
mod machine_tunnel;
pub(crate) mod outbox;
mod pairing;
pub use pairing::serve_connection_device;
pub mod peer_auth;
mod peer_forward;
pub(crate) mod peer_status;
pub mod peer_text;
mod pending;
mod place;
mod processes;
mod prompt_cancel;
mod workflow_activity;
mod workflow_runs;
mod worktrees;
pub mod ws_auth;
use crate::hub::is_permission_ask;
pub use pending::{event_value, into_event_value};
use pending::{peer_permission_pending, permission_pending};
pub(crate) use workflow_activity::owner_call as workflow_owner_call;
mod redact;
pub(crate) use peer_forward::strip_asks as strip_peer_asks;
pub(crate) use redact::url_without_secrets;
pub(crate) mod remote_guard;
mod requests;
pub use requests::{DURABLE_DISPATCH_FEATURE, SESSION_RESUME_FEATURE};
mod accounts;
mod mcp_connect;
mod routes;
mod secrets;
mod vault;
pub(crate) use vault::reply as vault_reply;
mod races;
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
mod request_admission_tests;

#[cfg(test)]
#[path = "acp_list_tests.rs"]
mod acp_list_tests;

#[cfg(test)]
#[path = "list_fit_tests.rs"]
mod list_fit_tests;

#[cfg(test)]
#[path = "list_pending_tests.rs"]
mod list_pending_tests;

#[cfg(test)]
#[path = "list_web_page_tests.rs"]
mod list_web_page_tests;

#[cfg(test)]
#[path = "ack_latency_bench.rs"]
mod ack_latency_bench;

#[cfg(test)]
#[path = "reply_size_tests.rs"]
mod reply_size_tests;

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
mod accept_retry_tests;

#[cfg(test)]
mod nodelay_tests;

#[cfg(test)]
mod outbound_queue_tests;

/// Owner-only TLS ingress from the embedded tailnet node.
#[cfg(all(unix, feature = "tailnet"))]
pub mod tailnet_ingress;

#[cfg(test)]
mod message_notice_tests;

#[cfg(test)]
#[path = "fanout_encode_tests.rs"]
mod fanout_encode_tests;

// What one change costs the watchers at 100, 1,000 and 3,000 sessions (manual).
#[cfg(test)]
#[path = "update_cost_bench.rs"]
mod update_cost_bench;

#[cfg(test)]
#[path = "chat_window_activity_tests.rs"]
mod chat_window_activity_tests;
