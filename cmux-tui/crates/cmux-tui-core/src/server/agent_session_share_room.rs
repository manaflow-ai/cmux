//! The link share bridge (design chat-multiplayer.md 4.2 and 4.3; the room is cmux-platform's
//! `ChatShareRoom`). With a room configured, create provisions each share there (`PUT`, keyed by
//! its `provision_key`, with the owner's cmux access token, which is never stored) and answers the
//! guest link `url_base#secret`. A revoke reaches the room from `pending_room_ops`, persisted with
//! the change: its `DELETE` is retried until it is answered (or the share's expiry ends it there).
//!
//! Everything waits on events: one-shot sleeps for backoff (1 s doubling to 60 s), run only while
//! a `PUT` or `DELETE` is pending. The host socket of each active share (`cmux.share/1`: the
//! daemon's `guests` after every `hello`, redeem, kick) and the relay of each guest's chat come in
//! the next changes.

use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{LinkShare, LinkShares, ShareState, find};
use crate::mux::Mux;

/// The bridge's waits; tests shorten them.
#[derive(Clone, Debug)]
pub(in crate::server) struct Timing {
    /// One `PUT`, `DELETE` or socket handshake.
    pub(in crate::server) request: Duration,
    /// How long a provision that got no answer is retried before its share is revoked.
    pub(in crate::server) window: Duration,
    pub(in crate::server) backoff_min: Duration,
    pub(in crate::server) backoff_max: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            request: Duration::from_secs(15),
            window: Duration::from_secs(10 * 60),
            backoff_min: Duration::from_secs(1),
            backoff_max: Duration::from_secs(60),
        }
    }
}

/// The configured room: its origin and the waits.
#[derive(Clone)]
pub(in crate::server) struct Room {
    url: String,
    timing: Timing,
}

/// The room configuration and the runtime the requests run on.
#[derive(Default)]
pub(in crate::server) struct Bridge {
    room: Mutex<Option<Room>>,
    invalid: Mutex<bool>,
    runtime: OnceLock<Option<tokio::runtime::Runtime>>,
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

/// What the bridge reads of one share.
struct View {
    url: Option<String>,
    host_token: Option<String>,
    expires_at: u64,
    delete: bool,
    body: Value,
}

fn view(mux: &Mux, share_id: &str) -> Option<View> {
    change(mux, share_id, |s| {
        let room = |field: &str| s.room.as_ref().and_then(|r| r[field].as_str()).map(str::to_owned);
        let body = json!({"provision_key": s.provision_key, "secret_sha256": s.secret_sha256,
            "expires_at": s.expires_at, "uses": s.uses_left});
        let view = View {
            url: room("url"),
            host_token: room("host_token"),
            expires_at: s.expires_at,
            delete: s.pending_room_ops.iter().any(|o| o["op"] == "delete"),
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
        let kept = s.room.as_ref().is_some_and(|r| r["host_token"] == host_token)
            && s.pending_room_ops.iter().any(|o| o["op"] == "delete");
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
    let queued = share.pending_room_ops.iter().any(|o| o["op"] == "delete");
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
        s.pending_room_ops.retain(|o| o != op);
        ((), s.pending_room_ops.len() != before)
    }).is_some()
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
        Some((200..=299, body)) => match (body["host_token"].as_str(), body["url_base"].as_str()) {
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
            candidate.scheme() == "https"
                || (address.is_loopback() && candidate.scheme() == "http")
        }
        Some(url::Host::Ipv6(address)) => {
            candidate.scheme() == "https"
                || (address.is_loopback() && candidate.scheme() == "http")
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
    let share_id = created["share_id"].as_str().unwrap_or_default().to_owned();
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
            let secret = created["secret"].as_str().unwrap_or_default().to_owned();
            created["url"] = json!(format!("{url_base}#{secret}"));
            created["room"] = json!(room.url);
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

/// Runs the share's queued `DELETE` until the room acknowledges it (2xx, or 404/410: gone),
/// retrying any other answer (401/403 included) with backoff, with the host token (the record's,
/// else the one held) or the owner's. The queued op survives a restart. With no credential at
/// all (the owner's token, lost to a restart) it stays queued until the share's expiry, when the
/// room's own alarm has ended it.
fn delete(mux: &Arc<Mux>, share_id: &str, held: Option<Held>) {
    let link_shares = shares(mux);
    if !link_shares.claim_room_delete(share_id) {
        if let Some(Held::Host(url, token)) = &held {
            // A late PUT may carry the only host token while another cleanup worker is in
            // flight. Preserve it in the record so that worker can use it before it exits.
            let _ = retire(mux, share_id, url, token);
        }
        return;
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
        struct DeleteGuard {
            mux: Weak<Mux>,
            share_id: String,
        }

        impl Drop for DeleteGuard {
            fn drop(&mut self) {
                if let Some(mux) = self.mux.upgrade() {
                    let shares = shares(&mux);
                    shares.release_room_delete(&self.share_id);
                    shares.rearm();
                }
            }
        }

        let _guard = DeleteGuard { mux: weak.clone(), share_id: id.clone() };
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
                    }).is_some()
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
                    if v.delete {
                        if !done(&mux, &id, &op) {
                            tokio::time::sleep(wait).await;
                            wait = (wait * 2).min(timing.backoff_max);
                            continue;
                        }
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
                    _ => return,
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

/// `LinkShares::settle`'s step for the room: an ended share's queued `DELETE` runs.
pub(super) fn ended(shares: &LinkShares, ended: &[(String, Option<String>)]) {
    let Some(mux) = shares.mux.lock().unwrap_or_else(|e| e.into_inner()).upgrade() else { return };
    for (share_id, _) in ended.iter().filter(|(_, guest)| guest.is_none()) {
        if view(&mux, share_id).is_some_and(|v| v.delete) {
            delete(&mux, share_id, None);
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
            .filter(|share| {
                share.expires_at <= now
                    && share.pending_room_ops.iter().any(|op| op["op"] == "delete")
            })
            .map(|share| share.share_id.clone())
            .collect::<Vec<_>>()
    };
    for id in ids {
        let Some(v) = view(&mux, &id) else { continue };
        // A restart may have lost the owner's token. Cleanup still runs in a single worker so a
        // transient persistence failure is retried with backoff instead of losing the operation.
        delete(&mux, &id, None);
    }
}

/// Configures the room new links are provisioned in (`CMUX_SHARE_ROOM_URL`, else the build's
/// default) and resumes every queued `DELETE` of before a restart. A share a restart left
/// provisioning never answered its create: it is revoked (a room it made without answering ends
/// at the share's expiry: the owner's token, which its `DELETE` would need, is not kept).
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
            .filter(|s| s.pending_room_ops.iter().any(|o| o["op"] == "delete"))
            .map(|s| s.share_id.clone());
        Ok((ids.collect::<Vec<_>>(), changed))
    });
    for id in bridged.unwrap_or_default() {
        if view(mux, &id).is_some_and(|v| v.delete) {
            delete(mux, &id, None);
        }
    }
    expired(shares);
    shares.settle(mux);
}

#[cfg(test)]
#[path = "agent_session_share_room_tests.rs"]
mod tests;
