//! The link share bridge (design chat-multiplayer.md 4.2 and 4.3; the room is cmux-platform's
//! `ChatShareRoom`). With a room configured, create provisions each share there (`PUT`, keyed by
//! its `provision_key`, with the owner's cmux access token, which is never stored) and the share
//! then keeps one outbound host socket (`cmux.share/1`) while it is active.
//!
//! The daemon stays the authority. After every `hello` it names the guests it holds active
//! (`guests`) before anything else, and the room's `redeem` is answered by the registry's own
//! atomic redeem. A kick and a revoke reach the room from `pending_room_ops`, which is persisted
//! with the change: the kick is resent on every host connect until the room answers `kicked`, and
//! the `DELETE` is retried until it is answered (or the share's expiry ends it at the room).
//!
//! Each guest whose browser is in the room gets a relay of the chat (`agent_session_share_relay.rs`)
//! from the room's `hello` or `guest_joined` until its `guest_left`, a kick or the share's end; a
//! host or guest reconnect starts it again, with a fresh snapshot.
//!
//! Everything waits on events: the sockets, a command channel, and one-shot sleeps for backoff
//! (1 s doubling to 60 s), run only while something is pending.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use cmux_json::JsonSet as _;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use zeroize::Zeroizing;

use super::{GuestState, LinkShare, LinkShares, Redeem, ShareState, find, op_of};
use crate::mux::Mux;
use crate::server::RenderService;

#[path = "agent_session_share_relay.rs"]
mod relay;

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// The bridge's waits; tests shorten them.
#[derive(Clone, Debug)]
pub(in crate::server) struct Timing {
    /// One `PUT`, `DELETE` or socket handshake.
    pub(in crate::server) request: Duration,
    /// How long a provision that got no answer is retried before its share is revoked.
    pub(in crate::server) window: Duration,
    pub(in crate::server) backoff_min: Duration,
    pub(in crate::server) backoff_max: Duration,
    /// A host socket quiet this long is pinged; one quiet as long again after the ping is
    /// dropped and opened again (a connection lost without a close, a NAT mapping gone).
    pub(in crate::server) heartbeat: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            request: Duration::from_secs(15),
            window: Duration::from_secs(10 * 60),
            backoff_min: Duration::from_secs(1),
            backoff_max: Duration::from_secs(60),
            heartbeat: Duration::from_secs(30),
        }
    }
}

/// The configured room: its origin and the waits.
#[derive(Clone)]
pub(in crate::server) struct Room {
    url: String,
    timing: Timing,
}

enum Cmd {
    /// Send `guests` and the pending kicks again (a guest was kicked).
    Reconcile,
    /// The share ended: send `end` and close, then drop the sender, which lets the queued
    /// `DELETE` go (the room tears the socket down on it, so `end` must reach it first).
    End(&'static str, oneshot::Sender<()>),
}

/// The room configuration, the runtime the sockets and requests run on, and each share's host.
#[derive(Default)]
pub(in crate::server) struct Bridge {
    room: Mutex<Option<Room>>,
    invalid: Mutex<bool>,
    runtime: OnceLock<Option<tokio::runtime::Runtime>>,
    hosts: Mutex<HashMap<String, (u64, mpsc::UnboundedSender<Cmd>)>>,
    next_host: AtomicU64,
    /// The guest relays' connections' outbound budget.
    render: OnceLock<Arc<RenderService>>,
    /// Each share's guests' held prompts (share id, then guest id), kept across the share's host
    /// sockets and the guests' relays until the guest is kicked or the share ends.
    held: Mutex<HashMap<String, HashMap<String, relay::Held>>>,
}

impl Drop for Bridge {
    fn drop(&mut self) {
        // Never blocks, so the last daemon reference may go on a runtime thread.
        if let Some(Some(runtime)) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

/// `scheme://host[:port]` of `raw`: https, or http on a loopback host; no path, query or user.
fn origin(raw: &str) -> Option<String> {
    let url = url::Url::parse(raw.trim()).ok()?;
    let loopback = match url.host()? {
        url::Host::Domain(domain) => domain.eq_ignore_ascii_case("localhost"),
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    };
    let scheme = url.scheme() == "https" || (url.scheme() == "http" && loopback);
    let bare = url.path() == "/" && url.query().is_none() && url.username().is_empty();
    (scheme && bare && url.fragment().is_none()).then(|| url.origin().ascii_serialization())
}

impl Bridge {
    /// The held prompts of `guest` of `share_id`.
    fn held(&self, share_id: &str, guest: &str) -> relay::Held {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.entry(share_id.to_owned()).or_default().entry(guest.to_owned()).or_default().clone()
    }

    /// Forgets the held prompts of a kicked guest, or (`None`) of an ended share's guests.
    fn forget(&self, share_id: &str, guest: Option<&str>) {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        match guest {
            Some(guest) => {
                if let Some(guests) = held.get_mut(share_id) {
                    guests.remove(guest);
                }
            }
            None => {
                held.remove(share_id);
            }
        }
    }

    /// Sets the room new shares are provisioned in (`None`: links have no URL). False when `url`
    /// is no https origin (including an explicit empty string): creation fails with
    /// `share.room_unreachable`, while an unset room preserves local sharing.
    pub(in crate::server) fn configure(&self, url: Option<&str>, timing: Timing) -> bool {
        let room = url.and_then(origin).map(|url| Room { url, timing });
        let valid = room.is_some() || url.is_none();
        *self.invalid.lock().unwrap_or_else(|e| e.into_inner()) = !valid;
        *self.room.lock().unwrap_or_else(|e| e.into_inner()) = room;
        valid
    }

    pub(super) fn invalid(&self) -> bool {
        *self.invalid.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(super) fn room(&self) -> Option<Room> {
        self.room.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn timing(&self) -> Timing {
        self.room().map(|room| room.timing).unwrap_or_default()
    }

    fn runtime(&self) -> Option<&tokio::runtime::Runtime> {
        let runtime = self.runtime.get_or_init(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let mut builder = tokio::runtime::Builder::new_multi_thread();
            builder.worker_threads(1).thread_name("mux-share-room").enable_all().build().ok()
        });
        runtime.as_ref()
    }

    fn command(&self, share_id: &str, cmd: Cmd) {
        if let Some((_, host)) = self.hosts.lock().unwrap_or_else(|e| e.into_inner()).get(share_id)
        {
            let _ = host.send(cmd);
        }
    }
}

fn shares(mux: &Mux) -> &LinkShares {
    &mux.control_clients.agent_sessions.link_shares
}

/// Runs `change` on one share; a `true` answer is written.
fn change<T>(
    mux: &Mux,
    share_id: &str,
    edit: impl FnOnce(&mut LinkShare) -> (T, bool),
) -> Option<T> {
    let directory = mux.session_state_directory();
    shares(mux).with(directory.as_deref(), |all, _| Ok(edit(find(all, share_id)?))).ok()
}

/// The room ended `share_id` (close code 4001, or gone at the upgrade): a share still active
/// here ends (expired when `reason` or its own expiry says so, else revoked), with no room
/// `DELETE` (the room is gone) and no kick left to send, and its guests' connections close.
fn ended_by_room(mux: &Mux, share_id: &str, reason: Option<&str>) {
    let directory = mux.session_state_directory();
    let expired = reason == Some("expired");
    shares(mux).ended_by_room(directory.as_deref(), share_id, expired);
    shares(mux).settle(mux);
}

/// The room refused `share_id`'s host for good: the share is revoked here (no host will serve
/// its guests), its guests' connections close, and its room `DELETE` runs.
fn refused_by_room(mux: &Mux, share_id: &str) {
    let directory = mux.session_state_directory();
    shares(mux).refused_by_room(directory.as_deref(), share_id);
    shares(mux).settle(mux);
}

/// What the bridge reads of one share.
struct View {
    url: Option<String>,
    host_token: Option<String>,
    state: ShareState,
    expires_at: u64,
    /// The guests it holds active (none once the share ended).
    active: Vec<String>,
    kicks: Vec<String>,
    delete: bool,
    body: Value,
}

fn view(mux: &Mux, share_id: &str) -> Option<View> {
    change(mux, share_id, |s| {
        let room = |field: &str| s.room_str(field).map(str::to_owned);
        let active = s.guests.iter().filter(|g| g.state == GuestState::Active && s.live().is_ok());
        let body = json!({"provision_key": s.provision_key, "secret_sha256": s.secret_sha256,
            "expires_at": s.expires_at, "uses": s.uses_left});
        let view = View {
            url: room("url"),
            host_token: room("host_token"),
            state: s.state,
            expires_at: s.expires_at,
            active: active.map(|g| g.guest_id.clone()).collect(),
            kicks: s
                .pending_room_ops
                .iter()
                .filter(|o| op_of(o) == Some("kick"))
                .filter_map(|o| o.get("guest_id").and_then(Value::as_str).map(str::to_owned))
                .collect(),
            delete: s.delete_queued(),
            body,
        };
        (view, false)
    })
}

/// Opens a share still provisioning (not expired, revoked or closed meanwhile) in the room a
/// `PUT` answered. Anything else (`Err`, its code) leaves the room to [`delete`].
fn adopt(mux: &Mux, share_id: &str, url: &str, host_token: &str) -> Result<(), &'static str> {
    let directory = mux.session_state_directory();
    shares(mux).with(directory.as_deref(), |all, _| {
        let s = find(all, share_id)?;
        if s.state != ShareState::Provisioning {
            return Err(s.live().err().unwrap_or("share.revoked"));
        }
        s.room = Some(json!({"url": url, "host_token": host_token}));
        s.state = ShareState::Active;
        Ok(((), true))
    })
}

/// Keeps the room a `PUT` answered for a share that will not open: its host token and a queued
/// `DELETE`, written once (false while the write fails: [`delete`] holds the token meanwhile).
fn retire(mux: &Mux, share_id: &str, url: &str, host_token: &str) -> bool {
    change(mux, share_id, |s| {
        let kept = s.room_str("host_token") == Some(host_token) && s.delete_queued();
        if !kept {
            s.room = Some(json!({"url": url, "host_token": host_token}));
            abandon_share(s, true);
        }
        ((), !kept)
    })
    .is_some()
}

/// A share whose provision failed ends; `delete` queues its room's `DELETE`.
fn abandon_share(share: &mut LinkShare, delete: bool) {
    if share.state == ShareState::Provisioning {
        share.state = ShareState::Revoked;
    }
    let queued = share.delete_queued();
    if delete && share.state != ShareState::Active && !queued {
        share.pending_room_ops.push(json!({"op": "delete"}));
    }
}

fn abandon(mux: &Mux, share_id: &str, delete: bool) {
    change(mux, share_id, |s| (abandon_share(s, delete), true));
}

/// The room acknowledged `op`.
fn done(mux: &Mux, share_id: &str, op: &Value) -> bool {
    change(mux, share_id, |s| {
        let before = s.pending_room_ops.len();
        // The room's DELETE answered: its guests are gone with it, so no kick waits.
        let deleted = op_of(op) == Some("delete");
        s.pending_room_ops.retain(|o| o != op && !(deleted && op_of(o) == Some("kick")));
        ((), s.pending_room_ops.len() != before)
    })
    .is_some()
}

enum Put {
    Done {
        host_token: String,
        url_base: String,
    },
    /// The room answered no: the code create answers.
    Refused(&'static str),
    Unreachable,
}

// Only small control-plane replies (host token and URL) are expected; this is not a media limit.
const MAX_ROOM_RESPONSE_BYTES: usize = 64 * 1024;

/// One HTTP call to the room with `bearer`: its status and bounded JSON body.
async fn call(
    method: reqwest::Method,
    url: &str,
    bearer: &str,
    body: Option<&Value>,
    timeout: Duration,
) -> Option<(u16, Value)> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(timeout)
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
        .build()
        .ok()?;
    let mut request = client.request(method, url).bearer_auth(bearer);
    if let Some(body) = body {
        request = request.json(body);
    }
    let mut reply = request.send().await.ok()?;
    let status = reply.status().as_u16();
    if reply.content_length().is_some_and(|length| length > MAX_ROOM_RESPONSE_BYTES as u64) {
        return None;
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = reply.chunk().await.ok()? {
        if chunk.len() > MAX_ROOM_RESPONSE_BYTES.saturating_sub(bytes.len()) {
            return None;
        }
        bytes.extend_from_slice(&chunk);
    }
    Some((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
}

async fn put(room: &Room, share_id: &str, token: &str, body: &Value) -> Put {
    let url = format!("{}/v1/chat-shares/{share_id}", room.url);
    let reply = call(reqwest::Method::PUT, &url, token, Some(body), room.timing.request).await;
    match reply {
        Some((200..=299, body)) => match (
            body.get("host_token").and_then(Value::as_str),
            body.get("url_base").and_then(Value::as_str),
        ) {
            (Some(token), Some(base)) if !token.is_empty() && valid_url_base(room, base) => {
                Put::Done { host_token: token.into(), url_base: base.into() }
            }
            _ => Put::Unreachable,
        },
        Some((408 | 429, _)) => Put::Unreachable,
        Some((401, _)) => Put::Refused("share.needs_sign_in"),
        Some((400..=499, _)) => Put::Refused("share.room_refused"),
        _ => Put::Unreachable,
    }
}

/// Accept only a guest URL served by this configured room. The room API derives `url_base` from
/// the request origin, so a different origin indicates a bad or compromised response. HTTP is
/// allowed only for loopback rooms used by local development and tests; configured remote rooms
/// are HTTPS-only through [`origin`].
fn valid_url_base(room: &Room, raw: &str) -> bool {
    let Ok(candidate) = url::Url::parse(raw) else { return false };
    if !candidate.username().is_empty()
        || candidate.password().is_some()
        || candidate.fragment().is_some()
    {
        return false;
    }
    let Ok(configured) = url::Url::parse(&room.url) else { return false };
    if candidate.origin().ascii_serialization() != configured.origin().ascii_serialization() {
        return false;
    }
    match candidate.host() {
        Some(url::Host::Domain(domain)) => {
            candidate.scheme() == "https"
                || (domain.eq_ignore_ascii_case("localhost") && candidate.scheme() == "http")
        }
        Some(url::Host::Ipv4(address)) => {
            candidate.scheme() == "https" || (address.is_loopback() && candidate.scheme() == "http")
        }
        Some(url::Host::Ipv6(address)) => {
            candidate.scheme() == "https" || (address.is_loopback() && candidate.scheme() == "http")
        }
        None => false,
    }
}

/// Create's room step: `PUT`, then the share is active and the reply carries its link. With no
/// answer the share stays provisioning and the `PUT` is retried in the background for the window,
/// then the share is revoked; a room that answers late is deleted (its link was never handed out).
pub(super) fn provision(
    mux: &Arc<Mux>,
    mut created: Value,
    room: Room,
    token: Zeroizing<String>,
) -> Result<Value, &'static str> {
    let share_id = created.get("share_id").and_then(Value::as_str).unwrap_or_default().to_owned();
    let body = view(mux, &share_id).ok_or("share.unknown")?.body;
    let Some(runtime) = shares(mux).bridge.runtime() else {
        abandon(mux, &share_id, false);
        return Err("share.room_unreachable");
    };
    match runtime.block_on(put(&room, &share_id, &token, &body)) {
        Put::Done { host_token, url_base } => {
            if let Err(code) = adopt(mux, &share_id, &room.url, &host_token) {
                delete(mux, &share_id, Some(Held::Host(room.url, Zeroizing::new(host_token))));
                return Err(code);
            }
            let secret =
                created.get("secret").and_then(Value::as_str).unwrap_or_default().to_owned();
            created.set("url", json!(format!("{url_base}#{secret}")));
            created.set("room", json!(room.url));
            host(mux, &share_id);
            Ok(created)
        }
        Put::Refused(code) => {
            abandon(mux, &share_id, false);
            Err(code)
        }
        Put::Unreachable => {
            runtime.spawn(retry(Arc::downgrade(mux), share_id, room, token, body));
            Err("share.room_unreachable")
        }
    }
}

async fn retry(
    mux: Weak<Mux>,
    share_id: String,
    room: Room,
    token: Zeroizing<String>,
    body: Value,
) {
    let deadline = tokio::time::Instant::now() + room.timing.window;
    let mut wait = room.timing.backoff_min;
    loop {
        tokio::time::sleep_until((tokio::time::Instant::now() + wait).min(deadline)).await;
        wait = (wait * 2).min(room.timing.backoff_max);
        if tokio::time::Instant::now() >= deadline {
            let Some(mux) = mux.upgrade() else { return };
            abandon(&mux, &share_id, true);
            return delete(&mux, &share_id, Some(Held::Owner(token)));
        }
        match put(&room, &share_id, &token, &body).await {
            // Create already answered that it failed: this room's link was never handed out.
            Put::Done { host_token, .. } => {
                let Some(mux) = mux.upgrade() else { return };
                let held = Held::Host(room.url, Zeroizing::new(host_token));
                return delete(&mux, &share_id, Some(held));
            }
            Put::Refused(_) => {
                return mux.upgrade().map_or((), |mux| abandon(&mux, &share_id, false));
            }
            Put::Unreachable => {}
        }
    }
}

/// A credential [`delete`] holds in memory.
enum Held {
    /// A room's host token the share's record may not hold yet (its write failed): kept until a
    /// write succeeds, then the record's.
    Host(String, Zeroizing<String>),
    /// The owner's token, for a room that never answered with a host token. Never written.
    Owner(Zeroizing<String>),
}

/// A [`delete`] worker's claim on its share, released when the worker ends.
struct DeleteGuard {
    mux: Weak<Mux>,
    share_id: String,
    /// The worker ended for want of a credential, before the share's expiry.
    tokenless: bool,
}

impl Drop for DeleteGuard {
    fn drop(&mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let shares = shares(&mux);
        shares.release_room_delete(&self.share_id);
        shares.rearm();
        // A late PUT that found this worker in flight wrote its host token after the worker's
        // last read: the queued `DELETE` runs now with it, not at the share's expiry.
        if self.tokenless
            && view(&mux, &self.share_id).is_some_and(|v| v.delete && v.host_token.is_some())
        {
            delete(&mux, &self.share_id, None);
        }
    }
}

/// Runs the share's queued `DELETE` until the room acknowledges it (2xx, or 404/410: gone),
/// retrying any other answer (401/403 included) with backoff, with the host token (the record's,
/// else the one held) or the owner's. The queued op survives a restart. With no credential at
/// all (the owner's token, lost to a restart) it stays queued until the share's expiry, when the
/// room's own alarm has ended it.
fn delete(mux: &Arc<Mux>, share_id: &str, held: Option<Held>) {
    delete_after(mux, share_id, held, None);
}

/// [`delete`], whose first request waits for `after` (the host socket's `end`, at most one
/// request's time).
fn delete_after(
    mux: &Arc<Mux>,
    share_id: &str,
    held: Option<Held>,
    after: Option<oneshot::Receiver<()>>,
) {
    let link_shares = shares(mux);
    if !link_shares.claim_room_delete(share_id) {
        // A late PUT may carry the only host token while another cleanup worker is in flight.
        // Preserve it in the record for that worker: one that exits without a credential runs
        // the DELETE again with it ([`DeleteGuard`]); one that exited before this write released
        // its claim, so the claim is this call's now.
        let Some(Held::Host(url, token)) = &held else { return };
        let _ = retire(mux, share_id, url, token);
        if !link_shares.claim_room_delete(share_id) {
            return;
        }
    }
    // Remove this share's expiry from the timer before the worker starts. The worker owns the
    // operation now and will re-arm if it exits while the queued operation remains.
    link_shares.rearm();
    let bridge = &link_shares.bridge;
    let Some(runtime) = bridge.runtime() else {
        link_shares.release_room_delete(share_id);
        link_shares.rearm();
        return;
    };
    let (timing, weak, id) = (bridge.timing(), Arc::downgrade(mux), share_id.to_owned());
    let fallback = bridge.room().map(|room| room.url);
    runtime.spawn(async move {
        let mut guard = DeleteGuard { mux: weak.clone(), share_id: id.clone(), tokenless: false };
        if let Some(after) = after {
            let _ = tokio::time::timeout(timing.request, after).await;
        }
        let op = json!({"op": "delete"});
        let mut wait = timing.backoff_min;
        let mut attempted = false;
        let mut acknowledged = false;
        loop {
            if acknowledged {
                let saved = {
                    let Some(mux) = weak.upgrade() else { return };
                    change(&mux, &id, |s| {
                        abandon_share(s, false);
                        s.pending_room_ops.retain(|pending| pending != &op);
                        ((), true)
                    })
                    .is_some()
                };
                if saved {
                    return;
                }
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(timing.backoff_max);
                continue;
            }
            let target = {
                let Some(mux) = weak.upgrade() else { return };
                let mut unsaved = false;
                if let Some(Held::Host(url, token)) = &held {
                    unsaved = !retire(&mux, &id, url, token);
                }
                let Some(v) = view(&mux, &id) else { return };
                let owner_held = held.as_ref().is_some_and(|held| matches!(held, Held::Owner(_)));
                if owner_held && !v.delete {
                    // Retry the durable revoke while retaining the owner credential for the
                    // room call when the write is still refused.
                    abandon(&mux, &id, true);
                }
                if attempted && shares(&mux).now() >= v.expires_at {
                    if v.delete && !done(&mux, &id, &op) {
                        tokio::time::sleep(wait).await;
                        wait = (wait * 2).min(timing.backoff_max);
                        continue;
                    }
                    return;
                }
                if !v.delete && !unsaved && !owner_held {
                    return;
                }
                let (url, bearer) = match &held {
                    Some(Held::Host(url, token)) if unsaved => {
                        (Some(url.clone()), Some(token.clone()))
                    }
                    Some(Held::Owner(token)) if v.host_token.is_none() => {
                        (v.url, Some(token.clone()))
                    }
                    _ => (v.url, v.host_token.map(Zeroizing::new)),
                };
                match (url.or_else(|| fallback.clone()), bearer) {
                    (Some(url), Some(bearer)) => (url, bearer),
                    // No credential (the owner's, lost to a restart): the room's expiry ends it.
                    _ if shares(&mux).now() >= v.expires_at => {
                        if done(&mux, &id, &op) {
                            return;
                        }
                        tokio::time::sleep(wait).await;
                        wait = (wait * 2).min(timing.backoff_max);
                        continue;
                    }
                    _ => {
                        guard.tokenless = true;
                        return;
                    }
                }
            };
            let url = format!("{}/v1/chat-shares/{id}", target.0);
            let reply = call(reqwest::Method::DELETE, &url, &target.1, None, timing.request).await;
            attempted = true;
            if reply.is_some_and(|(status, _)| matches!(status, 200..=299 | 404 | 410)) {
                acknowledged = true;
                continue;
            }
            if let Some(mux) = weak.upgrade()
                && view(&mux, &id).is_some_and(|v| shares(&mux).now() >= v.expires_at)
            {
                if done(&mux, &id, &op) {
                    return;
                }
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(timing.backoff_max);
                continue;
            }
            tokio::time::sleep(wait).await;
            wait = (wait * 2).min(timing.backoff_max);
        }
    });
}

/// Starts the share's host socket, or has the running one reconcile.
fn host(mux: &Arc<Mux>, share_id: &str) {
    let bridge = &shares(mux).bridge;
    let mut hosts = bridge.hosts.lock().unwrap_or_else(|e| e.into_inner());
    if hosts.get(share_id).is_some_and(|(_, host)| host.send(Cmd::Reconcile).is_ok()) {
        return;
    }
    let Some(runtime) = bridge.runtime() else { return };
    let (sender, commands) = mpsc::unbounded_channel();
    let generation = bridge.next_host.fetch_add(1, Ordering::Relaxed);
    hosts.insert(share_id.to_owned(), (generation, sender));
    let task = serve_host(Arc::downgrade(mux), share_id.to_owned(), generation, commands);
    runtime.spawn(task);
}

/// `LinkShares::settle`'s step for the room: a kicked guest is reconciled; an ended share's
/// socket sends `end` and its queued `DELETE` runs.
pub(super) fn ended(shares: &LinkShares, ended: &[(String, Option<String>)]) {
    let Some(mux) = shares.mux.lock().unwrap_or_else(|e| e.into_inner()).upgrade() else { return };
    for (share_id, guest) in ended {
        shares.bridge.forget(share_id, guest.as_deref());
        if guest.is_some() {
            // An ended share's own entry sends `end`; its kicks are moot.
            if view(&mux, share_id).is_some_and(|v| v.state == ShareState::Active) {
                shares.bridge.command(share_id, Cmd::Reconcile);
            }
            continue;
        }
        let Some(v) = view(&mux, share_id) else { continue };
        let reason = match v.state {
            ShareState::Expired => "expired",
            ShareState::Closed => "closed",
            _ => "revoked",
        };
        // The `DELETE` waits for `end`: the room closes the host socket when it deletes.
        let (sent, after) = oneshot::channel();
        shares.bridge.command(share_id, Cmd::End(reason, sent));
        if v.delete {
            delete_after(&mux, share_id, None, Some(after));
        }
    }
}

/// Starts cleanup for queued room operations that reached the share's expiry without a
/// credential. The daemon's expiry timer covers revoked and failed provisioning records too, so
/// they cannot occupy the share cap forever after a restart.
pub(super) fn expired(shares: &LinkShares) {
    let Some(mux) = shares.mux.lock().unwrap_or_else(|e| e.into_inner()).upgrade() else { return };
    let now = shares.now();
    let ids = {
        let slot = shares.shares.lock().unwrap_or_else(|e| e.into_inner());
        slot.iter()
            .flatten()
            .filter(|share| share.expires_at <= now && share.delete_queued())
            .map(|share| share.share_id.clone())
            .collect::<Vec<_>>()
    };
    for id in ids {
        if view(&mux, &id).is_none() {
            continue;
        }
        // A restart may have lost the owner's token. Cleanup still runs in a single worker so a
        // transient persistence failure is retried with backoff instead of losing the operation.
        delete(&mux, &id, None);
    }
}

/// The host socket of one active share: connects, serves, and reconnects with backoff until the
/// share ends or the room refuses it for good.
async fn serve_host(
    mux: Weak<Mux>,
    share_id: String,
    generation: u64,
    mut commands: mpsc::UnboundedReceiver<Cmd>,
) {
    let Some(timing) = mux.upgrade().map(|mux| shares(&mux).bridge.timing()) else { return };
    let mut wait = timing.backoff_min;
    loop {
        let target = mux.upgrade().and_then(|mux| view(&mux, &share_id));
        let target = target.filter(|v| v.state == ShareState::Active);
        let Some((url, token)) = target.and_then(|v| Some((v.url?, v.host_token?))) else { break };
        match connect(&url, &share_id, &token, timing.request).await {
            Err(Refused::Gone) => {
                // The room has no such share any more (deleted or expired there).
                if let Some(mux) = mux.upgrade() {
                    ended_by_room(&mux, &share_id, None);
                }
                break;
            }
            Err(Refused::ForGood) => {
                if let Some(mux) = mux.upgrade() {
                    refused_by_room(&mux, &share_id);
                }
                break;
            }
            Err(Refused::Retry) => {}
            Ok(socket) => match session(&mux, &share_id, socket, &mut commands, &timing).await {
                None => break,
                Some(true) => wait = timing.backoff_min,
                Some(false) => {}
            },
        }
        tokio::select! {
            () = tokio::time::sleep(wait) => {}
            command = commands.recv() => if matches!(command, None | Some(Cmd::End(..))) { break },
        }
        wait = (wait * 2).min(timing.backoff_max);
    }
    if let Some(mux) = mux.upgrade() {
        let mut hosts = shares(&mux).bridge.hosts.lock().unwrap_or_else(|e| e.into_inner());
        if hosts.get(&share_id).is_some_and(|(g, _)| *g == generation) {
            hosts.remove(&share_id);
        }
    }
}

/// The largest `cmux.share/1` frame (and message) the host socket takes.
const MAX_HOST_FRAME_BYTES: usize = 512 * 1024;

/// Why a host socket did not open.
enum Refused {
    /// The room has no such share (404, 410): it ended there.
    Gone,
    /// Refused for good (401, 403, or a request that cannot be made).
    ForGood,
    /// Try again after the backoff.
    Retry,
}

/// Opens `{room}/v1/chat-shares/{id}/host` with the host token.
async fn connect(url: &str, share_id: &str, token: &str, timeout: Duration) -> Result<Ws, Refused> {
    let socket = format!("{}/v1/chat-shares/{share_id}/host", url.replacen("http", "ws", 1));
    let mut request = socket.into_client_request().map_err(|_| Refused::ForGood)?;
    let bearer = HeaderValue::from_str(&format!("Bearer {token}")).map_err(|_| Refused::ForGood)?;
    request.headers_mut().insert("authorization", bearer);
    // `cmux.share/1` frames are at most 512 KiB: a larger one ends the socket unparsed.
    let config = tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_HOST_FRAME_BYTES))
        .max_frame_size(Some(MAX_HOST_FRAME_BYTES));
    let connect = tokio_tungstenite::connect_async_with_config(request, Some(config), false);
    match tokio::time::timeout(timeout, connect).await {
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(tungstenite::Error::Http(reply))) => Err(match reply.status().as_u16() {
            404 | 410 => Refused::Gone,
            401 | 403 => Refused::ForGood,
            _ => Refused::Retry,
        }),
        _ => Err(Refused::Retry),
    }
}

/// One connected host socket. `None`: stop (the share ended, or the room replaced, ended or
/// refused this host); `Some(ready)`: dropped, after (`true`) or before its `hello`.
async fn session(
    mux: &Weak<Mux>,
    share_id: &str,
    socket: Ws,
    commands: &mut mpsc::UnboundedReceiver<Cmd>,
    timing: &Timing,
) -> Option<bool> {
    let (mut sink, mut stream) = socket.split();
    // Every write is bounded: a socket that takes nothing is dropped and opened again.
    let put = async |sink: &mut futures_util::stream::SplitSink<Ws, Message>, message| {
        tokio::time::timeout(timing.request, sink.send(message))
            .await
            .is_ok_and(|sent| sent.is_ok())
    };
    let mut ready = false;
    // Heard from last: the room is pinged once it has been quiet a heartbeat, and dropped when
    // it stays quiet another.
    let mut heard = tokio::time::Instant::now();
    let mut pinged = false;
    // The reason of the room's own `end`, if it sent one.
    let mut room_end: Option<String> = None;
    let (relay_out, mut relayed) = mpsc::unbounded_channel();
    let mut guests = Guests::new(relay_out);
    loop {
        let quiet = heard + if pinged { timing.heartbeat * 2 } else { timing.heartbeat };
        let out = tokio::select! {
            () = tokio::time::sleep_until(quiet) => {
                if pinged || !put(&mut sink, Message::Ping(Vec::new().into())).await {
                    return Some(ready);
                }
                pinged = true;
                continue;
            }
            frame = stream.next() => match frame {
                Some(Ok(Message::Text(text))) => {
                    (heard, pinged) = (tokio::time::Instant::now(), false);
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap_or(Value::Null);
                    // The room says why it ends the share before it closes with 4001.
                    if frame.get("t").and_then(Value::as_str) == Some("end") {
                        room_end = frame.get("reason").and_then(Value::as_str).map(str::to_owned);
                    }
                    let mux = mux.upgrade()?;
                    let mut out = answer(&mux, share_id, &frame, &mut ready);
                    if ready {
                        out.extend(guests.room(&mux, share_id, &frame));
                    }
                    out
                }
                Some(Ok(Message::Close(frame))) => {
                    let code = frame.map(|frame| u16::from(frame.code));
                    // The room ended the share (it expired or was deleted there): it ends here
                    // too, and its guests' connections close.
                    if code == Some(4001)
                        && let Some(mux) = mux.upgrade()
                    {
                        ended_by_room(&mux, share_id, room_end.as_deref());
                    }
                    // The room refused this host for good: no host will serve the share.
                    if code == Some(4003)
                        && let Some(mux) = mux.upgrade()
                    {
                        refused_by_room(&mux, share_id);
                    }
                    // 4000 replaced, 4001 ended, 4003 refused.
                    return (!matches!(code, Some(4000 | 4001 | 4003))).then_some(ready);
                }
                // Answered at once: tungstenite only queues the pong until the next write, and
                // an idle host socket writes nothing else.
                Some(Ok(Message::Ping(payload))) => {
                    (heard, pinged) = (tokio::time::Instant::now(), false);
                    if !put(&mut sink, Message::Pong(payload)).await {
                        return Some(ready);
                    }
                    continue;
                }
                Some(Ok(_)) => {
                    (heard, pinged) = (tokio::time::Instant::now(), false);
                    continue;
                }
                None | Some(Err(_)) => return Some(ready),
            },
            command = commands.recv() => match command {
                Some(Cmd::Reconcile) if ready => {
                    let mux = mux.upgrade()?;
                    reconcile(&mux, share_id)
                }
                Some(Cmd::Reconcile) => continue,
                Some(Cmd::End(reason, sent)) => {
                    let end = json!({"v": 1, "t": "end", "reason": reason}).to_string();
                    if put(&mut sink, Message::text(end)).await {
                        let _ = tokio::time::timeout(timing.request, sink.close()).await;
                    }
                    drop(sent);
                    return None;
                }
                None => return None,
            },
            relayed = relayed.recv() => match relayed {
                Some(relay::Out::Frame(guest, generation, frame)) => {
                    if !guests.current(&guest, generation) {
                        continue;
                    }
                    vec![frame]
                }
                Some(relay::Out::Ended(guest, generation)) => {
                    let mux = mux.upgrade()?;
                    guests.ended(&mux, share_id, &guest, generation);
                    continue;
                }
                Some(relay::Out::Retry(guest)) => {
                    let mux = mux.upgrade()?;
                    guests.retry(&mux, share_id, &guest);
                    continue;
                }
                None => continue,
            },
        };
        for frame in out {
            if !put(&mut sink, Message::text(frame.to_string())).await {
                return Some(ready);
            }
        }
    }
}

/// `guests {active}` (the daemon's own list), then every kick the room has not acknowledged;
/// nothing once the share ended (a kick that raced its revoke, expiry or closure): an ended
/// share's socket sends only `end`.
fn reconcile(mux: &Mux, share_id: &str) -> Vec<Value> {
    let Some(v) = view(mux, share_id).filter(|v| v.state == ShareState::Active) else {
        return Vec::new();
    };
    let mut out = vec![json!({"v": 1, "t": "guests", "active": v.active})];
    out.extend(v.kicks.into_iter().map(|guest| json!({"v": 1, "t": "kick", "guest_id": guest})));
    out
}

/// A guest relay that could not start, or ended while its guest stayed connected, starts again
/// after this, doubling up to [`RELAY_RETRY_MAX`].
const RELAY_RETRY_MIN: Duration = Duration::from_millis(250);
const RELAY_RETRY_MAX: Duration = Duration::from_secs(30);

/// A connected guest with no relay running: one is started again after a backoff.
struct Waiting {
    sockets: Option<usize>,
    tries: u32,
}

/// The relays of one host socket's guests (dropped with it).
struct Guests {
    relays: HashMap<String, relay::Relay>,
    /// Connected guests whose relay could not start (no connection permit) or ended.
    waiting: HashMap<String, Waiting>,
    next: u64,
    out: mpsc::UnboundedSender<relay::Out>,
}

impl Guests {
    fn new(out: mpsc::UnboundedSender<relay::Out>) -> Self {
        Self { relays: HashMap::new(), waiting: HashMap::new(), next: 0, out }
    }

    /// A room frame about the guests' browsers, after the daemon's `guests`; what to send the
    /// room back (a prompt no relay can take is refused, `share.busy`).
    fn room(&mut self, mux: &Arc<Mux>, share_id: &str, frame: &Value) -> Vec<Value> {
        // Only `cmux.share/1` frames: another version (or none) starts no relay, sends nothing.
        if frame.get("v").and_then(Value::as_u64) != Some(1) {
            return Vec::new();
        }
        let guest = frame.get("guest_id").and_then(Value::as_str).unwrap_or_default();
        let ask = match frame.get("t").and_then(Value::as_str).unwrap_or_default() {
            // `hello` names each connected guest once; its socket count when the room gives it
            // (`sockets`), else unknown.
            "hello" => {
                self.relays.clear();
                self.waiting.clear();
                for guest in frame.get("guests").and_then(Value::as_array).into_iter().flatten() {
                    let sockets = guest.get("sockets").and_then(Value::as_u64);
                    let sockets = sockets.and_then(|n| usize::try_from(n).ok()).filter(|n| *n > 0);
                    let guest = guest.get("guest_id").and_then(Value::as_str).unwrap_or_default();
                    self.open(mux, share_id, guest, sockets, 0);
                }
                return Vec::new();
            }
            // A guest's (re)connect gets a fresh snapshot; one more socket than before.
            "guest_joined" => {
                let before = match (self.relays.remove(guest), self.waiting.remove(guest)) {
                    (Some(relay), _) => Some(relay.sockets),
                    (None, Some(waiting)) => Some(waiting.sockets),
                    (None, None) => None,
                };
                let sockets = match before {
                    Some(sockets) => sockets.map(|n| n.saturating_add(1)),
                    None => Some(1),
                };
                self.open(mux, share_id, guest, sockets, 0);
                return Vec::new();
            }
            // The relay ends with the guest's last socket. With no count (a room whose `hello`
            // gives none) the first `guest_left` ends it: a relay never outlives its guest's
            // sockets holding a daemon connection; another open tab of the guest reconnects.
            "guest_left" => {
                let sockets = match (self.relays.get_mut(guest), self.waiting.get_mut(guest)) {
                    (Some(relay), _) => Some(&mut relay.sockets),
                    (None, Some(waiting)) => Some(&mut waiting.sockets),
                    (None, None) => None,
                };
                if let Some(sockets) = sockets {
                    let left = sockets.map_or(0, |n| n.saturating_sub(1));
                    *sockets = Some(left);
                    if left == 0 {
                        self.relays.remove(guest);
                        self.waiting.remove(guest);
                    }
                }
                return Vec::new();
            }
            "guest_prompt" => {
                let client_id = frame.get("client_id").and_then(Value::as_str).unwrap_or_default();
                let text = frame.get("text").and_then(Value::as_str).unwrap_or_default();
                let ask =
                    relay::Ask::Prompt { client_id: client_id.to_owned(), text: text.to_owned() };
                // A connected guest whose relay waits to start: refused, said, not lost.
                if self.waiting.contains_key(guest) {
                    return refused(mux, share_id, guest, ask);
                }
                ask
            }
            "guest_typing" => relay::Ask::Typing(frame.get("on") == Some(&Value::Bool(true))),
            "older" => match frame.get("before_seq").and_then(Value::as_u64) {
                Some(before) => relay::Ask::Older(before),
                None => return Vec::new(),
            },
            "prompt_status" => {
                let ids: Vec<String> =
                    (frame.get("client_ids").and_then(Value::as_array).into_iter().flatten())
                        .filter_map(|id| id.as_str().map(str::to_owned))
                        .collect();
                relay::Ask::Status(ids)
            }
            _ => return Vec::new(),
        };
        self.send(mux, share_id, guest, ask)
    }

    /// Queues `ask` for `guest`'s relay; with its queue full, refused at once.
    fn send(&self, mux: &Mux, share_id: &str, guest: &str, ask: relay::Ask) -> Vec<Value> {
        let Some(relay) = self.relays.get(guest) else { return Vec::new() };
        match relay.asks.try_send(ask) {
            Ok(()) => Vec::new(),
            Err(full) => refused(mux, share_id, guest, full.into_inner()),
        }
    }

    /// Starts the relay of a guest the daemon holds active, with its sockets (`None`: unknown).
    /// With no connection permit free the guest waits, and it is tried again after a backoff.
    fn open(
        &mut self,
        mux: &Arc<Mux>,
        share_id: &str,
        guest: &str,
        sockets: Option<usize>,
        tries: u32,
    ) {
        self.waiting.remove(guest);
        if !view(mux, share_id).is_some_and(|v| v.active.iter().any(|g| g == guest)) {
            return;
        }
        let bridge = &shares(mux).bridge;
        let render = bridge.render.get_or_init(|| Arc::new(RenderService::new())).clone();
        self.next = self.next.wrapping_add(1);
        let ids = (share_id, guest);
        let held = bridge.held(share_id, guest);
        let out = self.out.clone();
        match relay::start(mux, render, ids, self.next, out, held) {
            Some(mut relay) => {
                relay.sockets = sockets;
                relay.tries = tries;
                self.relays.insert(guest.to_owned(), relay);
            }
            None => self.wait(guest, sockets, tries),
        }
    }

    /// `guest` stays connected with no relay: it is started again after a backoff.
    fn wait(&mut self, guest: &str, sockets: Option<usize>, tries: u32) {
        self.waiting.insert(guest.to_owned(), Waiting { sockets, tries });
        let factor = 2_u32.saturating_pow(tries.min(16));
        let delay = RELAY_RETRY_MIN.saturating_mul(factor).min(RELAY_RETRY_MAX);
        let (out, guest) = (self.out.clone(), guest.to_owned());
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            let _ = out.send(relay::Out::Retry(guest));
        });
    }

    /// A waiting guest's backoff ran out: its relay is started again.
    fn retry(&mut self, mux: &Arc<Mux>, share_id: &str, guest: &str) {
        if let Some(waiting) = self.waiting.remove(guest) {
            self.open(mux, share_id, guest, waiting.sockets, waiting.tries.saturating_add(1));
        }
    }

    /// Whether `generation` is `guest`'s current relay: a replaced relay's late frames are dropped.
    fn current(&self, guest: &str, generation: u64) -> bool {
        self.relays.get(guest).is_some_and(|relay| relay.generation == generation)
    }

    /// A relay ended (its attachment closed: detached, overflow, the guest kicked). The current
    /// one of a guest still connected starts again after a backoff; a kicked guest's does not
    /// (`open` checks the guest is active).
    fn ended(&mut self, mux: &Mux, share_id: &str, guest: &str, generation: u64) {
        if !self.current(guest, generation) {
            return;
        }
        let active = view(mux, share_id).is_some_and(|v| v.active.iter().any(|g| g == guest));
        if let Some(relay) = self.relays.remove(guest)
            && active
            && relay.sockets != Some(0)
        {
            self.wait(guest, relay.sockets, relay.tries.saturating_add(1));
        }
    }
}

/// What the room is told of an ask for `guest` no relay can take (`share.busy`).
fn refused(mux: &Mux, share_id: &str, guest: &str, ask: relay::Ask) -> Vec<Value> {
    let held = shares(mux).bridge.held(share_id, guest);
    relay::refuse(&held, (share_id, guest), ask, "share.busy").into_iter().collect()
}

/// The redeem refusals the room may pass to a guest.
const GUEST_REFUSALS: [&str; 8] = [
    "share.secret",
    "share.used",
    "share.name",
    "share.expired",
    "share.revoked",
    "share.closed",
    "share.kicked",
    "share.left",
];

/// The daemon's answer to one room frame.
fn answer(mux: &Mux, share_id: &str, frame: &Value, ready: &mut bool) -> Vec<Value> {
    if frame.get("v").and_then(Value::as_u64) != Some(1) {
        return Vec::new();
    }
    match frame.get("t").and_then(Value::as_str).unwrap_or_default() {
        "hello" => {
            *ready = true;
            reconcile(mux, share_id)
        }
        // The room sends a redeem only after the daemon's `guests`.
        "redeem" if *ready => {
            let field =
                |name: &str| frame.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
            let redeem = Redeem {
                share_id: share_id.to_owned(),
                secret: field("secret"),
                name: field("name"),
                attempt_id: field("attempt_id"),
            };
            let directory = mux.session_state_directory();
            let redeemed = shares(mux).redeem(directory.as_deref(), redeem);
            shares(mux).settle(mux);
            let request_id = frame.get("request_id").unwrap_or(&Value::Null);
            match redeemed {
                Ok(guest) => vec![json!({"v": 1, "t": "redeemed", "request_id": request_id,
                    "guest_id": guest.get("guest_id")})],
                // Only the refusals a guest may see reach the room (and the guest page); any
                // other (storage, provisioning, an unknown share) is `share.unavailable`.
                Err(code) => {
                    let code =
                        if GUEST_REFUSALS.contains(&code) { code } else { "share.unavailable" };
                    vec![json!({"v": 1, "t": "redeemed", "request_id": request_id, "error": code})]
                }
            }
        }
        "kicked" => {
            if let Some(guest) = frame.get("guest_id").and_then(Value::as_str) {
                done(mux, share_id, &json!({"op": "kick", "guest_id": guest}));
            }
            Vec::new()
        }
        _ => Vec::new(),
    }
}

/// Configures the room new links are provisioned in (`CMUX_SHARE_ROOM_URL`, else the build's
/// default) and resumes every share bridged before a restart: an active share's host socket, a
/// queued `DELETE`. A share a restart left provisioning never answered its create: it is revoked
/// (a room it made without answering ends at the share's expiry: the owner's token, which its
/// `DELETE` would need, is not kept).
pub fn start_link_share_bridge(mux: &Arc<Mux>, room: Option<&str>) {
    let shares = shares(mux);
    if !shares.bridge.configure(room, Timing::default()) {
        eprintln!("cmux-tui: the link share room is invalid; link creation is disabled");
    }
    shares.serve(mux);
    let Some(directory) = mux.session_state_directory() else { return };
    let bridged = shares.with(Some(directory.as_path()), |all, _| {
        let mut changed = false;
        for share in all.iter_mut().filter(|s| s.state == ShareState::Provisioning) {
            let bridged = share.room.is_some();
            abandon_share(share, bridged);
            changed = true;
        }
        let ids = all
            .iter()
            // Each active share gets its host socket again, each queued DELETE resumes.
            .filter(|s| (s.state == ShareState::Active && s.room.is_some()) || s.delete_queued())
            .map(|s| s.share_id.clone());
        Ok((ids.collect::<Vec<_>>(), changed))
    });
    for id in bridged.unwrap_or_default() {
        match view(mux, &id) {
            Some(v) if v.delete => delete(mux, &id, None),
            Some(v) if v.state == ShareState::Active => host(mux, &id),
            _ => {}
        }
    }
    expired(shares);
    shares.settle(mux);
}

#[cfg(test)]
#[path = "agent_session_share_room_tests.rs"]
mod tests;
