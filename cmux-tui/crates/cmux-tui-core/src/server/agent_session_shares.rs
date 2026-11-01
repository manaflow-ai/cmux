//! Link shares (`agent-session-share-*`, design chat-multiplayer.md 4.2): the owner shares one
//! agent chat with a guest through a link that works a few times (once by default) and expires
//! (24 h by default). The records live next to the session's registry (`agent-session-shares.json`,
//! owner-only, rewritten atomically, `state_file.rs`), so a share, its uses, its guests, a kick and
//! a revoke outlive a daemon restart. A share pins the chat's acpmux
//! session, never the surface number (surfaces are per boot).
//!
//! The verbs are the owner's own: a same-user unix connection that is neither bound (a teammate's
//! proxy or a guest) nor a remote relay. Only the secret's SHA-256 is kept; create answers the
//! secret once. A redeemed guest binds a connection with `agent-session-proxy-bind {link_guest}`
//! and reaches the shared chat as `{id: "guest:<share_id>.<guest_id>", name, approval: "owner"}`,
//! so acpmux holds each of its prompts for the owner. Every guest frame re-checks the share (its
//! state and expiry) and the guest (kicked), and a guest's live stream checks them on every
//! record. Whatever path ends a share or a guest (a revoke, a kick, the expiry timer, or any verb
//! that notices the expiry first) closes its bound connections in the same step (`settle`);
//! expiry is one one-shot timer to the next `expires_at` (no polling).
//!
//! With a hosted room configured (`agent_session_share_room.rs`), create provisions the share in
//! the room first (`provisioning` until it answers) and answers the guest link; a revoke or kick
//! also goes to the room (`pending_room_ops`, retried until acknowledged). Without one a share is
//! `active` from its create and `url` is null.

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::{MessageWriter, Refusal, Response, ok, send_response, tab_session};
use super::Teammate;
use crate::apps::timer::{TimerId, Timers};
use crate::mux::Mux;
use crate::server::agent_transfer::state_file::{read_trusted, save};

#[path = "agent_session_share_room.rs"]
pub(in crate::server) mod room;

pub(super) const GUEST_PREFIX: &str = "guest:";
const FILE: &str = "agent-session-shares.json";
const DEFAULT_TTL_SECS: u64 = 24 * 60 * 60;
const MAX_TTL_SECS: u64 = 7 * DEFAULT_TTL_SECS;
const MIN_TTL_SECS: u64 = 60;
const MAX_USES: u32 = 8;
/// Records kept at once (an ended one goes when room is needed), so the file stays far below
/// `state_file`'s 64 KiB read bound.
const MAX_SHARES: usize = 16;
/// A guest's `client_id` or a redeem's `attempt_id`, in bytes.
const MAX_ID_BYTES: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ShareState {
    Provisioning,
    Active,
    Revoked,
    Expired,
    Closed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum GuestState {
    Active,
    Kicked,
    Left,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Guest {
    guest_id: String,
    name: String,
    joined_at: u64,
    state: GuestState,
    /// SHA-256 of the redeem's `attempt_id`: a retry of that redeem gets this guest again.
    attempt_id_sha256: String,
}

/// What a create asks of its share: how long it lasts, how many guests it lets in, and the
/// caller's id for the request (`LinkShare::create_id`).
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ShareTerms {
    pub(super) ttl_secs: u64,
    pub(super) uses: u32,
    pub(super) create_id: Option<String>,
}

/// A client's `create_id`, in bytes.
const MAX_CREATE_ID_BYTES: usize = 64;

/// One share; times are Unix milliseconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct LinkShare {
    share_id: String,
    session: String,
    /// The surface that showed the chat at create, this boot's number (the session is the pin).
    surface: u64,
    created_at: u64,
    expires_at: u64,
    uses_left: u32,
    state: ShareState,
    secret_sha256: String,
    #[serde(default)]
    provision_key: Option<String>,
    /// The id the creating client chose for its request (`create_id`), so a client whose create
    /// was never answered can find and end that one share. Not a secret.
    #[serde(default)]
    create_id: Option<String>,
    #[serde(default)]
    room: Option<Value>,
    #[serde(default)]
    pending_room_ops: Vec<Value>,
    guests: Vec<Guest>,
}

impl LinkShare {
    /// Ok while a guest may join or act: active and not expired.
    fn live(&self) -> Result<(), &'static str> {
        match self.state {
            ShareState::Active => Ok(()),
            ShareState::Provisioning => Err("share.provisioning"),
            ShareState::Revoked => Err("share.revoked"),
            ShareState::Expired => Err("share.expired"),
            ShareState::Closed => Err("share.closed"),
        }
    }

    /// A string member of the hosted room (`url`, `host_token`), if the share has one.
    fn room_str(&self, field: &str) -> Option<&str> {
        self.room.as_ref()?.get(field)?.as_str()
    }

    /// The room's `DELETE` is already queued.
    fn delete_queued(&self) -> bool {
        self.pending_room_ops.iter().any(|op| op_of(op) == Some("delete"))
    }

    fn shown(&self, now: u64) -> Value {
        let guests: Vec<Value> = self
            .guests
            .iter()
            .map(|g| {
                json!({"guest_id": g.guest_id, "name": g.name, "joined_at": g.joined_at,
                    "state": g.state})
            })
            .collect();
        json!({"share_id": self.share_id, "session": self.session, "surface": self.surface,
            "created_at": self.created_at, "expires_at": self.expires_at,
            "expires_in_secs": self.expires_at.saturating_sub(now) / 1000,
            "uses_left": self.uses_left, "state": self.state, "url": null,
            "create_id": self.create_id,
            "room": self.room.as_ref().map(|room| room.get("url").cloned().unwrap_or(Value::Null)),
            "guests": guests})
    }
}

/// The daemon's link shares, read from the session's state directory on first use.
#[derive(Default)]
pub(in crate::server) struct LinkShares {
    shares: Mutex<Option<Vec<LinkShare>>>,
    timers: Timers,
    /// The one timer armed, and the expiry it ends. Changed only under the shares lock (taken
    /// first), so the timer always matches the shares it was computed from.
    armed: Mutex<Option<(TimerId, u64)>>,
    /// Shares (`None`) and guests that ended since the last `settle`, whose connections close.
    ended: Mutex<Vec<(String, Option<String>)>>,
    /// Room DELETE workers currently dispatched, one per share. Expiry can race a worker that is
    /// still waiting for the room's response; do not start a second worker for the same record.
    room_deletes: Mutex<HashSet<String>>,
    /// The daemon the timer's job runs for (set by the first verb or bind).
    mux: Mutex<Weak<Mux>>,
    /// The hosted room each share is bridged to.
    pub(in crate::server) bridge: room::Bridge,
    /// Added to the wall clock (tests move time with it).
    skew_ms: AtomicU64,
    /// Runs once between a guest bind's check and its registration (tests).
    #[cfg(test)]
    pub(super) bind_hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// Every write fails while set (tests).
    #[cfg(test)]
    pub(super) refuse_writes: std::sync::atomic::AtomicBool,
}

impl Drop for LinkShares {
    fn drop(&mut self) {
        self.timers.stop();
    }
}

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn token<const N: usize>() -> Result<String, &'static str> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|_| "share.unsaved")?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

fn digest(parts: &[&str]) -> [u8; 32] {
    let mut hash = Sha256::new();
    for (index, part) in parts.iter().enumerate() {
        if index > 0 {
            hash.update([0u8]);
        }
        hash.update(part.as_bytes());
    }
    hash.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Constant-time equality of two hex digests.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// A name as acpmux takes an author's (`author.rs` `valid`, `unshown`): 1 to 64 characters on
/// one line, not blank, no control, separator, bidi or zero-width mark.
fn valid_name(name: &str) -> bool {
    let unshown = |c: char| {
        c.is_control()
            || (c.is_whitespace() && c != ' ')
            || matches!(
                c,
                '\u{200B}'..='\u{200F}'
                    | '\u{202A}'..='\u{202E}'
                    | '\u{2066}'..='\u{2069}'
                    | '\u{FEFF}'
            )
    };
    name.chars().count() <= 64 && !name.trim().is_empty() && !name.chars().any(unshown)
}

fn valid_id(id: &str) -> bool {
    (1..=MAX_ID_BYTES).contains(&id.len())
}

fn find<'a>(
    shares: &'a mut [LinkShare],
    share_id: &str,
) -> Result<&'a mut LinkShare, &'static str> {
    shares.iter_mut().find(|s| s.share_id == share_id).ok_or("share.unknown")
}

fn load(directory: Option<&Path>) -> Vec<LinkShare> {
    directory
        .and_then(|directory| read_trusted(&directory.join(FILE)))
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// The author a guest binds as.
fn author_of(share: &LinkShare, guest: &Guest) -> Value {
    json!({"id": format!("{GUEST_PREFIX}{}.{}", share.share_id, guest.guest_id),
        "name": guest.name, "approval": "owner"})
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    surface: u64,
    /// The session the caller saw on `surface`: a surface that shows another chat by now is
    /// refused (`share.chat_moved`), so a share never goes to a chat nobody named.
    #[serde(default)]
    session: Option<String>,
    /// The caller's id for this request, shown in list (`LinkShare::create_id`).
    #[serde(default)]
    create_id: Option<String>,
    #[serde(default)]
    ttl_secs: Option<u64>,
    #[serde(default)]
    uses: Option<u32>,
    /// The owner's cmux cloud access token, for the room's `PUT` only (never stored).
    #[serde(default)]
    owner_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    #[serde(default)]
    surface: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Named {
    share_id: String,
    #[serde(default)]
    guest_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Redeem {
    pub(super) share_id: String,
    pub(super) secret: String,
    pub(super) name: String,
    pub(super) attempt_id: String,
}

impl LinkShares {
    fn now(&self) -> u64 {
        wall_ms().saturating_add(self.skew_ms.load(Ordering::Relaxed))
    }

    #[cfg(test)]
    pub(super) fn advance(&self, by: Duration) {
        self.skew_ms.fetch_add(by.as_millis() as u64, Ordering::Relaxed);
    }

    /// Runs `change` on the shares under their lock, with every share past its expiry marked
    /// expired first. A change answering `(value, true)` is written before the answer and rolled
    /// back when the write fails (`share.unsaved`). Every share or guest that stops being live
    /// here is queued for [`Self::settle`], whatever the change answered.
    fn with<T>(
        &self,
        directory: Option<&Path>,
        change: impl FnOnce(&mut Vec<LinkShare>, u64) -> Result<(T, bool), &'static str>,
    ) -> Result<T, &'static str> {
        let now = self.now();
        let mut slot = self.shares.lock().unwrap_or_else(|e| e.into_inner());
        let shares = slot.get_or_insert_with(|| load(directory));
        let start = shares.clone();
        // Expiry ends a share that is not yet active too: a late room answer never opens it.
        for share in shares.iter_mut() {
            let open = matches!(share.state, ShareState::Active | ShareState::Provisioning);
            if open && now >= share.expires_at {
                share.state = ShareState::Expired;
            }
        }
        let before = shares.clone();
        let answer = match change(shares, now) {
            Ok((value, true)) => match self.save(directory, shares) {
                Some(Err(error)) => {
                    *shares = before;
                    eprintln!("cmux-tui: link shares not written: {error}");
                    Err("share.unsaved")
                }
                _ => Ok(value),
            },
            Ok((value, false)) => Ok(value),
            Err(code) => Err(code),
        };
        self.note_ended(&start, shares);
        answer
    }

    fn save(&self, directory: Option<&Path>, shares: &[LinkShare]) -> Option<std::io::Result<()>> {
        #[cfg(test)]
        if self.refuse_writes.load(Ordering::Relaxed) {
            return Some(Err(std::io::Error::other("writes refused (test)")));
        }
        directory.map(|d| save(d, FILE, &shares))
    }

    pub(super) fn claim_room_delete(&self, share_id: &str) -> bool {
        self.room_deletes.lock().unwrap_or_else(|e| e.into_inner()).insert(share_id.to_owned())
    }

    pub(super) fn release_room_delete(&self, share_id: &str) {
        self.room_deletes.lock().unwrap_or_else(|e| e.into_inner()).remove(share_id);
    }

    /// Queues what was live in `start` and is not in `now`.
    fn note_ended(&self, start: &[LinkShare], now: &[LinkShare]) {
        let mut ended = self.ended.lock().unwrap_or_else(|e| e.into_inner());
        for was in start.iter().filter(|s| s.live().is_ok()) {
            let is = now.iter().find(|s| s.share_id == was.share_id);
            if is.is_none_or(|s| s.live().is_err()) {
                ended.push((was.share_id.clone(), None));
                continue;
            }
            for guest in was.guests.iter().filter(|g| g.state == GuestState::Active) {
                let still = is
                    .into_iter()
                    .flat_map(|s| &s.guests)
                    .any(|g| g.guest_id == guest.guest_id && g.state == GuestState::Active);
                if !still {
                    ended.push((was.share_id.clone(), Some(guest.guest_id.clone())));
                }
            }
        }
    }

    /// Whether `author` may still read: a guest of a live, unexpired share who was not removed.
    /// Any other author is not a link guest's and passes. Cheap: one lock, no write.
    pub(in crate::server) fn guest_live(&self, author: &Value) -> bool {
        let Some(rest) = author["id"].as_str().and_then(|id| id.strip_prefix(GUEST_PREFIX)) else {
            return true;
        };
        let Some((share_id, guest_id)) = rest.split_once('.') else { return false };
        let now = self.now();
        let slot = self.shares.lock().unwrap_or_else(|e| e.into_inner());
        slot.iter().flatten().any(|s| {
            s.share_id == share_id
                && s.live().is_ok()
                && now < s.expires_at
                && s.guests.iter().any(|g| g.guest_id == guest_id && g.state == GuestState::Active)
        })
    }

    /// Closes the connections of every share and guest that ended, then arms the next expiry.
    /// Called after every verb, bind and guest frame, and by the timer.
    pub(in crate::server) fn settle(&self, mux: &Mux) {
        let ended = std::mem::take(&mut *self.ended.lock().unwrap_or_else(|e| e.into_inner()));
        if !ended.is_empty() {
            room::ended(self, &ended);
            close(mux, |id| {
                let Some((share, guest)) =
                    id.strip_prefix(GUEST_PREFIX).and_then(|rest| rest.split_once('.'))
                else {
                    return false;
                };
                ended.iter().any(|(s, g)| s == share && g.as_deref().is_none_or(|g| g == guest))
            });
        }
        self.rearm();
    }

    /// A new share of `session`, shown on `surface` (`provisioning` until its room answers);
    /// answers the secret once.
    pub(super) fn insert(
        &self,
        directory: Option<&Path>,
        session: String,
        surface: u64,
        terms: ShareTerms,
        provisioning: bool,
    ) -> Result<Value, &'static str> {
        let ShareTerms { ttl_secs, uses, create_id } = terms;
        let (share_id, secret, provision_key) = (token::<16>()?, token::<16>()?, token::<16>()?);
        self.with(directory, |shares, now| {
            if shares.len() >= MAX_SHARES {
                // An ended share goes, unless its room still has to hear of it.
                // A kick of an ended share is moot: its room ends with it.
                shares.retain(|s| {
                    s.live().is_ok()
                        || s.state == ShareState::Provisioning
                        || s.pending_room_ops.iter().any(|o| op_of(o) != Some("kick"))
                });
            }
            if shares.len() >= MAX_SHARES {
                return Err("share.limit");
            }
            let expires_at = now.saturating_add(ttl_secs.saturating_mul(1000));
            shares.push(LinkShare {
                share_id: share_id.clone(),
                session: session.clone(),
                surface,
                created_at: now,
                expires_at,
                uses_left: uses,
                state: if provisioning { ShareState::Provisioning } else { ShareState::Active },
                secret_sha256: hex(&digest(&[&secret])),
                provision_key: Some(provision_key),
                create_id,
                room: None,
                pending_room_ops: Vec::new(),
                guests: Vec::new(),
            });
            let reply = json!({"share_id": share_id, "secret": secret, "url": null,
                "expires_at": expires_at, "session": session, "surface": surface,
                "uses_left": uses});
            Ok((reply, true))
        })
    }

    /// Spends a use and names a new guest; a retry of a recorded `attempt_id` gets that guest
    /// again without a use, while the share is live.
    pub(super) fn redeem(
        &self,
        directory: Option<&Path>,
        p: Redeem,
    ) -> Result<Value, &'static str> {
        if !valid_name(&p.name) {
            return Err("share.name");
        }
        if !valid_id(&p.attempt_id) {
            return Err("share.bad_request");
        }
        let guest_id = token::<8>()?;
        let attempt = hex(&digest(&[&p.attempt_id]));
        self.with(directory, |shares, now| {
            let share = find(shares, &p.share_id)?;
            if !same(&hex(&digest(&[&p.secret])), &share.secret_sha256) {
                return Err("share.secret");
            }
            share.live()?;
            let reply =
                |g: &Guest| json!({"share_id": p.share_id, "guest_id": g.guest_id, "name": g.name});
            if let Some(guest) = share.guests.iter().find(|g| same(&g.attempt_id_sha256, &attempt))
            {
                return match guest.state {
                    GuestState::Active => Ok((reply(guest), false)),
                    GuestState::Kicked => Err("share.kicked"),
                    GuestState::Left => Err("share.left"),
                };
            }
            if share.uses_left == 0 {
                return Err("share.used");
            }
            share.uses_left -= 1;
            let guest = Guest {
                guest_id,
                name: p.name.clone(),
                joined_at: now,
                state: GuestState::Active,
                attempt_id_sha256: attempt,
            };
            let answer = reply(&guest);
            share.guests.push(guest);
            Ok((answer, true))
        })
    }

    /// Revokes a share (`guest_id: None`) or kicks one guest of it.
    fn end(&self, directory: Option<&Path>, p: &Named) -> Result<Value, &'static str> {
        let mut schedule_delete = false;
        let answer = self.with(directory, |shares, _| {
            let share = find(shares, &p.share_id)?;
            let room_hears = share.room.is_some() && share.live().is_ok();
            let Some(guest_id) = &p.guest_id else {
                let was_live = share.live().is_ok();
                let was_provisioning = share.state == ShareState::Provisioning;
                let changed = share.state != ShareState::Revoked;
                share.state = ShareState::Revoked;
                if changed && (share.room.is_some() || was_provisioning) && !share.delete_queued() {
                    share.pending_room_ops.push(json!({"op": "delete"}));
                }
                schedule_delete = !was_live && share.delete_queued();
                return Ok((json!({"share_id": share.share_id, "state": share.state}), changed));
            };
            let guest =
                share.guests.iter_mut().find(|g| &g.guest_id == guest_id).ok_or("share.unknown")?;
            let changed = guest.state != GuestState::Kicked;
            guest.state = GuestState::Kicked;
            if changed && room_hears {
                share.pending_room_ops.push(json!({"op": "kick", "guest_id": guest_id}));
            }
            Ok((
                json!({"share_id": share.share_id, "guest_id": guest_id, "state": guest.state}),
                changed,
            ))
        });
        if answer.is_ok() && schedule_delete {
            let mut ended = self.ended.lock().unwrap_or_else(|e| e.into_inner());
            if !ended.iter().any(|(share, guest)| share == &p.share_id && guest.is_none()) {
                ended.push((p.share_id.clone(), None));
            }
        }
        answer
    }

    /// Closes every open share of `session` (its chat was closed or removed): the guests'
    /// connections close at the next `settle`, and a share with a room queues its `DELETE`.
    /// The closure stands even when it cannot be written: the chat is gone, so its shares are
    /// closed in memory (no guest reaches it, its rooms end) and the write is retried.
    fn close_chat(&self, directory: Option<&Path>, session: &str) {
        self.close_where(directory, |s| s.session == session);
    }

    /// Closes every open share whose chat `gone` names, as [`Self::close_chat`] does.
    fn close_where(&self, directory: Option<&Path>, gone: impl Fn(&LinkShare) -> bool) {
        self.end_where(directory, gone, |share| {
            share.state = ShareState::Closed;
            if share.room.is_some() && !share.delete_queued() {
                share.pending_room_ops.push(json!({"op": "delete"}));
            }
        });
    }

    /// The room ended `share_id` (it closed the host socket with 4001, or refused its upgrade as
    /// gone): a share still open here ends, with no room `DELETE` (the room is gone) and no kick
    /// left to send. It expired when the room said so (`end {reason: "expired"}`) or its expiry
    /// passed here too (the room's alarm won the race); else it is revoked.
    pub(super) fn ended_by_room(&self, directory: Option<&Path>, share_id: &str, expired: bool) {
        let now = self.now();
        self.end_where(
            directory,
            |s| s.share_id == share_id,
            |share| {
                share.state = if expired || now >= share.expires_at {
                    ShareState::Expired
                } else {
                    ShareState::Revoked
                };
                share
                    .pending_room_ops
                    .retain(|o| op_of(o) != Some("kick") && op_of(o) != Some("delete"));
            },
        );
    }

    /// The room refused `share_id`'s host for good (401/403, close code 4003): a share still
    /// open here is revoked, since no guest could reach its host; its kicks are moot, and the
    /// room `DELETE` is queued (retried until the share's expiry, when the room ends it itself).
    pub(super) fn refused_by_room(&self, directory: Option<&Path>, share_id: &str) {
        self.end_where(
            directory,
            |s| s.share_id == share_id,
            |share| {
                share.state = ShareState::Revoked;
                share.pending_room_ops.retain(|o| op_of(o) != Some("kick"));
                if share.room.is_some() && !share.delete_queued() {
                    share.pending_room_ops.push(json!({"op": "delete"}));
                }
            },
        );
    }

    /// Ends every open share `which` picks with `end`. The end stands even when it cannot be
    /// written: no guest reaches the share from now on, and the write is retried.
    fn end_where(
        &self,
        directory: Option<&Path>,
        which: impl Fn(&LinkShare) -> bool,
        end: impl Fn(&mut LinkShare),
    ) {
        let mut slot = self.shares.lock().unwrap_or_else(|e| e.into_inner());
        let shares = slot.get_or_insert_with(|| load(directory));
        let start = shares.clone();
        let mut changed = false;
        for share in shares.iter_mut().filter(|s| which(s)) {
            if matches!(share.state, ShareState::Active | ShareState::Provisioning) {
                end(share);
                changed = true;
            }
        }
        self.note_ended(&start, shares);
        if changed && let Some(Err(error)) = self.save(directory, shares) {
            eprintln!("cmux-tui: ended link shares not written, retrying: {error}");
            drop(slot);
            self.save_later(Duration::from_secs(1));
        }
    }

    /// Writes the shares again after `wait`, doubling up to a minute until a write succeeds
    /// (`close_chat`). Stops when the daemon is gone.
    fn save_later(&self, wait: Duration) {
        let weak = self.mux.lock().unwrap_or_else(|e| e.into_inner()).clone();
        self.timers.schedule(wait, move || {
            let Some(mux) = weak.upgrade() else { return };
            let shares = &mux.control_clients.agent_sessions.link_shares;
            let directory = mux.session_state_directory();
            let slot = shares.shares.lock().unwrap_or_else(|e| e.into_inner());
            let Some(all) = slot.as_ref() else { return };
            if let Some(Err(_)) = shares.save(directory.as_deref(), all) {
                drop(slot);
                shares.save_later((wait * 2).min(Duration::from_secs(60)));
            }
        });
    }

    /// The chat a live guest reaches: its share's session and surface, and the guest's author.
    fn guest(
        &self,
        directory: Option<&Path>,
        share_id: &str,
        guest_id: &str,
    ) -> Result<(String, u64, Value), &'static str> {
        self.with(directory, |shares, _| {
            let share = find(shares, share_id)?;
            share.live()?;
            let guest =
                share.guests.iter().find(|g| g.guest_id == guest_id).ok_or("share.unknown")?;
            if guest.state != GuestState::Active {
                return Err("share.kicked");
            }
            Ok(((share.session.clone(), share.surface, author_of(share, guest)), false))
        })
    }

    /// Arms the one timer at the next active share or pending room operation's expiry (cancelling
    /// an earlier one). The expiry is read and the timer replaced under the shares lock, so two
    /// callers never leave a timer that does not match the shares.
    fn rearm(&self) {
        let room_deletes = self.room_deletes.lock().unwrap_or_else(|e| e.into_inner());
        let shares = self.shares.lock().unwrap_or_else(|e| e.into_inner());
        let now = self.now();
        let next = shares
            .iter()
            .flatten()
            .filter(|s| {
                !room_deletes.contains(&s.share_id)
                    && s.expires_at > now
                    && (matches!(s.state, ShareState::Active | ShareState::Provisioning)
                        || s.pending_room_ops.iter().any(|o| op_of(o) != Some("kick")))
            })
            .map(|s| s.expires_at)
            .min();
        let mut armed = self.armed.lock().unwrap_or_else(|e| e.into_inner());
        if armed.as_ref().map(|(_, at)| *at) == next {
            return;
        }
        if let Some((timer, _)) = armed.take() {
            self.timers.cancel(timer);
        }
        let Some(at) = next else { return };
        let weak = self.mux.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let after = Duration::from_millis(at.saturating_sub(self.now()));
        let timer = self.timers.schedule(after, move || {
            if let Some(mux) = weak.upgrade() {
                mux.control_clients.agent_sessions.link_shares.expired(&mux);
            }
        });
        *armed = Some((timer, at));
    }

    /// Remembers the daemon the timer runs for.
    fn serve(&self, mux: &Arc<Mux>) {
        *self.mux.lock().unwrap_or_else(|e| e.into_inner()) = Arc::downgrade(mux);
    }

    /// The timer's job: marks what expired, closes its guests, then arms the next expiry (again
    /// at the same one, if the timer ran early).
    pub(super) fn expired(&self, mux: &Mux) {
        {
            let _shares = self.shares.lock().unwrap_or_else(|e| e.into_inner());
            *self.armed.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        let directory = mux.session_state_directory();
        let _ = self.with(directory.as_deref(), |_, _| Ok(((), false)));
        room::expired(self);
        self.settle(mux);
    }
}

/// The agent chat `session` was closed or removed: its link shares close (design 4.2, "Closing
/// the chat ends its shares"), their guests' connections end, and each room hears `end
/// {reason: closed}` and its `DELETE`.
pub(crate) fn close_chat_shares(mux: &Mux, session: &str) {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    shares.close_chat(directory.as_deref(), session);
    shares.settle(mux);
}

/// A page of acpmux's list named `session` closed: its link shares in `before`
/// ([`open_chat_shares`]) close; one made since, for the chat reopened, stays.
pub(crate) fn close_listed_chat_shares(mux: &Mux, session: &str, before: &HashSet<String>) {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    shares.close_where(directory.as_deref(), |s| {
        before.contains(&s.share_id) && s.session == session
    });
    shares.settle(mux);
}

/// The ids of the open link shares now: taken before acpmux is asked for its chat list, so the
/// list's sweep ([`close_unlisted_chat_shares`]) never reaches a share created after it.
pub(crate) fn open_chat_shares(mux: &Mux) -> HashSet<String> {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    let mut slot = shares.shares.lock().unwrap_or_else(|e| e.into_inner());
    let open = slot.get_or_insert_with(|| load(directory.as_deref())).iter();
    open.filter(|s| matches!(s.state, ShareState::Active | ShareState::Provisioning))
        .map(|s| s.share_id.clone())
        .collect()
}

/// acpmux listed its chats whole: every link share in `before` ([`open_chat_shares`], taken
/// before the list was asked for) of a chat not in `listed` closes (it was closed or purged
/// while nothing watched, or its closure was never written before a restart). A share created
/// since, for a chat newer than the list, stays.
pub(crate) fn close_unlisted_chat_shares(
    mux: &Mux,
    listed: &HashSet<String>,
    before: &HashSet<String>,
) {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    shares.close_where(directory.as_deref(), |s| {
        before.contains(&s.share_id) && !listed.contains(&s.session)
    });
    shares.settle(mux);
}

/// The kind of a queued room operation (`kick`, `delete`).
pub(super) fn op_of(op: &Value) -> Option<&str> {
    op.get("op").and_then(Value::as_str)
}

/// Ends at once every guest connection whose author id `ended` names.
fn close(mux: &Mux, ended: impl Fn(&str) -> bool) {
    let clients: Vec<u64> = {
        let authors = mux
            .control_clients
            .agent_sessions
            .proxy_authors
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        authors
            .iter()
            .filter(|(_, a)| a["id"].as_str().is_some_and(&ended))
            .map(|(c, _)| *c)
            .collect()
    };
    for client in clients {
        mux.control_clients.abort_connection(client);
    }
}

/// `agent-session-share-*` of the owner's own connection (`bound`: a teammate's or a guest's).
pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    cmd: &str,
    mut object: serde_json::Map<String, Value>,
    bound: bool,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    object.remove("cmd");
    if bound || !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return fail(writer, id, "share.not_trusted");
    }
    let shares = &mux.control_clients.agent_sessions.link_shares;
    shares.serve(mux);
    let directory = mux.session_state_directory();
    let directory = directory.as_deref();
    let params = Value::Object(object);
    let answer = match cmd {
        "agent-session-share-create" => parse(params).and_then(|p: Create| {
            let ttl = p.ttl_secs.unwrap_or(DEFAULT_TTL_SECS);
            let uses = p.uses.unwrap_or(1);
            if !(MIN_TTL_SECS..=MAX_TTL_SECS).contains(&ttl) || !(1..=MAX_USES).contains(&uses) {
                return Err("share.bad_request");
            }
            if p.create_id
                .as_ref()
                .is_some_and(|id| id.is_empty() || id.len() > MAX_CREATE_ID_BYTES)
            {
                return Err("share.bad_request");
            }
            let terms = ShareTerms { ttl_secs: ttl, uses, create_id: p.create_id };
            let session = tab_session(mux, p.surface).ok_or("share.not_a_chat")?;
            if p.session.as_ref().is_some_and(|named| *named != session) {
                return Err("share.chat_moved");
            }
            if shares.bridge.invalid() {
                return Err("share.room_unreachable");
            }
            match shares.bridge.room() {
                None => shares.insert(directory, session, p.surface, terms, false),
                Some(room) => {
                    let token = p.owner_token.map(zeroize::Zeroizing::new);
                    let token = token.filter(|t| !t.is_empty() && t.len() <= 8192);
                    let token = token.ok_or("share.needs_sign_in")?;
                    let created = shares.insert(directory, session, p.surface, terms, true)?;
                    room::provision(mux, created, room, token)
                }
            }
        }),
        "agent-session-share-list" => parse(params).and_then(|p: List| {
            let session = match p.surface {
                Some(surface) => Some(tab_session(mux, surface).ok_or("share.not_a_chat")?),
                None => None,
            };
            shares.with(directory, |all, now| {
                let shown = all.iter().filter(|s| session.as_ref().is_none_or(|x| *x == s.session));
                Ok((json!({"shares": shown.map(|s| s.shown(now)).collect::<Vec<_>>()}), false))
            })
        }),
        "agent-session-share-revoke" | "agent-session-share-kick" => {
            parse(params).and_then(|p: Named| {
                if (cmd == "agent-session-share-kick") != p.guest_id.is_some() {
                    return Err("share.bad_request");
                }
                shares.end(directory, &p)
            })
        }
        "agent-session-share-redeem" => {
            parse(params).and_then(|p: Redeem| shares.redeem(directory, p))
        }
        _ => Err("share.bad_request"),
    };
    // A revoke, a kick, or an expiry any verb noticed closes the guests' connections now.
    shares.settle(mux);
    match answer {
        Ok(data) => ok(writer, id, data),
        Err(code) => fail(writer, id, code),
    }
}

fn parse<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, &'static str> {
    serde_json::from_value(params).map_err(|_| "share.bad_request")
}

fn fail(writer: &MessageWriter, id: Option<Value>, code: &str) -> bool {
    let message = match code {
        "share.unknown" => "no such share or guest",
        "share.secret" => "the link's secret does not match",
        "share.revoked" => "the owner ended this share",
        "share.expired" => "the share expired",
        "share.provisioning" | "share.closed" => "the share is not open",
        "share.used" => "the link was already used",
        "share.kicked" => "the owner removed this guest",
        "share.left" => "this guest left the share",
        "share.name" => "a name is 1 to 64 characters on one line",
        "share.limit" => "too many shares on this machine",
        "share.not_a_chat" => "not an agent chat with a session",
        "share.chat_moved" => "the surface shows another chat now; name the chat again",
        "share.not_trusted" => "only the owner's own local connection manages shares",
        "share.unsaved" => "the share could not be saved",
        "share.needs_sign_in" => "sharing a link needs the owner's cmux sign-in (owner_token)",
        "share.room_unreachable" => "the share room did not answer; the share was not opened",
        "share.room_refused" => "the share room refused this share (or sharing is off there)",
        _ => "bad request",
    };
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(message.to_owned()),
            error_code: Some(code.to_owned()),
            error_delivery: None,
        },
    )
}

/// `agent-session-proxy-bind {link_guest: {share_id, guest_id}}`: the author of a live guest.
pub(super) fn guest_author(mux: &Arc<Mux>, link: Value) -> Result<Value, Refusal> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Link {
        share_id: String,
        guest_id: String,
    }
    let link: Link = serde_json::from_value(link).map_err(|_| Refusal::BadRequest)?;
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    shares.serve(mux);
    let found = shares.guest(directory.as_deref(), &link.share_id, &link.guest_id);
    shares.settle(mux);
    #[cfg(test)]
    if let Some(hook) = shares.bind_hook.lock().unwrap_or_else(|e| e.into_inner()).take() {
        hook();
    }
    found.map(|(_, _, author)| author).map_err(|_| Refusal::ShareEnded)
}

/// The acpmux prompt id of a guest's prompt: `g-` and 22 characters of base64url SHA-256 of the
/// share, the guest and the prompt's `client_id`.
fn guest_prompt_id(share_id: &str, guest_id: &str, client_id: &str) -> String {
    let hash = digest(&[share_id, guest_id, client_id]);
    let prompt_id = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash);
    format!("g-{}", prompt_id.get(..22).unwrap_or(&prompt_id))
}

/// A bound guest's frame: its share and guest are still live, it names no other author or chat,
/// and it goes to the surface that shows the share's chat (whatever surface it named). A prompt's
/// id is `g-` and 22 characters of base64url SHA-256 of the share, the guest and the frame's
/// `client_id`, so acpmux's prompt ledger runs a retried prompt once.
pub(super) fn check_guest(
    mux: &Mux,
    client: u64,
    bound: Value,
    supplied: Option<Value>,
    pinned: Option<Value>,
    object: &mut serde_json::Map<String, Value>,
) -> Result<Teammate, Refusal> {
    let id = bound["id"].as_str().unwrap_or_default();
    let (share_id, guest_id) = id
        .strip_prefix(GUEST_PREFIX)
        .and_then(|rest| rest.split_once('.'))
        .ok_or(Refusal::NotTrusted)?;
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    let found = shares.guest(directory.as_deref(), share_id, guest_id);
    shares.settle(mux);
    let (session, surface, author) = found.map_err(|_| Refusal::ShareEnded)?;
    if author != bound
        || supplied.is_some_and(|a| a != bound)
        || pinned.is_some_and(|p| p.as_str() != Some(session.as_str()))
    {
        return Err(Refusal::NotTrusted);
    }
    let cmd = object.get("cmd").and_then(Value::as_str).unwrap_or_default().to_owned();
    if cmd == "agent-session-prompt" {
        let client_id = object.remove("client_id");
        let client_id = client_id.as_ref().and_then(Value::as_str).filter(|c| valid_id(c));
        let Some(client_id) = client_id else { return Err(Refusal::BadRequest) };
        object.insert("prompt_id".into(), json!(guest_prompt_id(share_id, guest_id, client_id)));
    }
    if cmd == "agent-session-detach" {
        // This connection's attachment to the shared chat, on whatever surface it resolved to
        // (after a restart that is not the share's stored one).
        let attached = mux
            .control_clients
            .agent_sessions
            .lock()
            .attachments
            .iter()
            .find(|((c, _), a)| *c == client && a.record_session == session)
            .map(|((_, s), _)| *s);
        object.insert("surface".into(), json!(attached.unwrap_or(surface)));
        return Ok(Teammate { author, pinned: None });
    }
    // The share's surface, or (after a restart renumbered the surfaces) the one showing its chat.
    let shown = Some(surface).filter(|s| tab_session(mux, *s).as_deref() == Some(session.as_str()));
    let shown = shown.or_else(|| {
        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        surfaces.into_iter().find(|s| tab_session(mux, *s).as_deref() == Some(session.as_str()))
    });
    let surface = shown.ok_or(Refusal::NotShared)?;
    object.insert("surface".into(), json!(surface));
    Ok(Teammate { author, pinned: Some(session) })
}

#[cfg(test)]
#[path = "agent_session_shares_tests.rs"]
mod tests;
