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
//! An invite (`agent-session-share-invite {share_id, account, role}`) names a cmux account on a
//! share. The room admits that account after its sign-in and forwards a redeem with `account`
//! instead of the secret; the daemon admits it only while the account is invited and not removed.
//! An invitee is a guest like any other (same `guest:` author, same hold on every prompt), whose
//! author also names its `account` and `role`: `view` watches only, `talk` may also prompt and
//! type. An invite spends no link use. `-uninvite` removes the account and kicks its guests.
//! An invite and `-list` answer `invite_url`, the link the owner hands out (`<room origin>/i/<share_id>`,
//! no secret in it; null without a room). `-invite-chat {surface, account, role}` invites on the
//! chat's invite share and makes that share in the same step when the chat has none (`open.rs`).
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

#[path = "agent_session_share_open.rs"]
mod open;
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
    /// The invited account this guest joined as (`None`: a link guest).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    role: Option<Role>,
}

/// What a create asks of its share: how long it lasts, how many guests it lets in, and the
/// caller's id for the request (`LinkShare::create_id`).
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ShareTerms {
    pub(super) ttl_secs: u64,
    pub(super) uses: u32,
    pub(super) create_id: Option<String>,
}

/// The encoded registry at its largest: `state_file`'s 64 KiB read bound, less a margin.
const MAX_SAVED_BYTES: usize = 62 * 1024;

/// Whether `shares` stays readable after a restart whatever later happens to it without a new
/// record: a change that adds records (a share, an invitee, a guest) is refused unless the
/// registry still fits once every share is ended, every guest kicked and every invitee removed,
/// with each kick and each room `DELETE` queued, and every share without a room given the largest
/// one a room's answer may write (`room::adopt`, `room::retire`). Kicks, revokes, expiry, closes
/// and the room's answers are never refused, so they must always fit.
fn fits(shares: &[LinkShare]) -> bool {
    let mut worst = shares.to_vec();
    for share in &mut worst {
        // `provisioning` is the longest state; an end writes a shorter one.
        share.state = ShareState::Provisioning;
        if share.room.is_none() {
            share.room = Some(json!({"url": "u".repeat(room::MAX_ROOM_URL_BYTES),
                "host_token": "t".repeat(room::MAX_HOST_TOKEN_BYTES)}));
        }
        for guest in share.guests.iter_mut().filter(|g| g.state == GuestState::Active) {
            guest.state = GuestState::Kicked;
            share.pending_room_ops.push(json!({"op": "kick", "guest_id": guest.guest_id}));
        }
        for invitee in &mut share.invitees {
            invitee.state = InviteState::Removed;
        }
        if !share.delete_queued() {
            share.pending_room_ops.push(json!({"op": "delete"}));
        }
    }
    serde_json::to_vec(&worst).is_ok_and(|bytes| bytes.len() <= MAX_SAVED_BYTES)
}

/// Whether `shares` [`fits`], once the ended shares that may go are gone if it did not.
fn fits_or_prune(shares: &mut Vec<LinkShare>) -> bool {
    if fits(shares) {
        return true;
    }
    prune(shares);
    fits(shares)
}

/// Drops the ended shares, but one whose room still has to hear of it (a kick of an ended share
/// is moot: its room ends with it). The record that goes is only history: no guest reaches an
/// ended share, and its id answers `share.unknown` from then on.
fn prune(shares: &mut Vec<LinkShare>) {
    shares.retain(|s| {
        s.live().is_ok()
            || s.state == ShareState::Provisioning
            || s.pending_room_ops.iter().any(|o| op_of(o) != Some("kick"))
    });
}

/// Accounts invited to one share at once.
const MAX_INVITEES: usize = 16;
/// An invited account's live guests at once (its browsers and devices).
const MAX_GUESTS_PER_ACCOUNT: usize = 4;
/// An account (an email address or a cmux `@handle`), in bytes.
const MAX_ACCOUNT_BYTES: usize = 320;

/// What an invited account may do: `view` watches, `talk` also prompts (held) and types.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Role {
    View,
    Talk,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum InviteState {
    Invited,
    Removed,
}

/// An account the owner invited to a share.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Invitee {
    /// Trimmed and lowercased (`normal_account`).
    account: String,
    role: Role,
    invited_at: u64,
    state: InviteState,
}

/// An account as the daemon keeps and compares it: trimmed, lowercased, one token (no
/// whitespace or control characters), 3 to 320 bytes, an email address or an `@handle`.
fn normal_account(account: &str) -> Result<String, &'static str> {
    let account = account.trim().to_lowercase();
    let token = !account.chars().any(|c| c.is_whitespace() || c.is_control());
    let shaped = account.strip_prefix('@').map_or_else(
        || {
            account
                .split_once('@')
                .is_some_and(|(user, host)| !user.is_empty() && host.contains('.'))
        },
        |handle| !handle.is_empty() && !handle.contains('@'),
    );
    if token && shaped && (3..=MAX_ACCOUNT_BYTES).contains(&account.len()) {
        Ok(account)
    } else {
        Err("share.bad_request")
    }
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
    #[serde(default)]
    invitees: Vec<Invitee>,
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

    /// The link an invitee opens: the room's origin, then `/i/<share_id>` (no secret in it, the
    /// room signs the account in). Null while the share has no room.
    fn invite_url(&self) -> Value {
        self.room_str("url")
            .map_or(Value::Null, |origin| json!(format!("{origin}/i/{}", self.share_id)))
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
                let mut shown = json!({"guest_id": g.guest_id, "name": g.name,
                    "joined_at": g.joined_at, "state": g.state});
                if let Some(account) = &g.account {
                    shown["account"] = json!(account);
                    shown["role"] = json!(g.role);
                }
                shown
            })
            .collect();
        let invitees: Vec<Value> = self
            .invitees
            .iter()
            .map(|i| {
                json!({"account": i.account, "role": i.role, "invited_at": i.invited_at,
                    "state": i.state})
            })
            .collect();
        json!({"share_id": self.share_id, "session": self.session, "surface": self.surface,
            "created_at": self.created_at, "expires_at": self.expires_at,
            "expires_in_secs": self.expires_at.saturating_sub(now) / 1000,
            "uses_left": self.uses_left, "state": self.state, "url": null,
            "create_id": self.create_id,
            "room": self.room.as_ref().map(|room| room.get("url").cloned().unwrap_or(Value::Null)),
            "invite_url": self.invite_url(), "guests": guests, "invitees": invitees})
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
    /// The shares file could not be read back and is not yet moved aside (`set_aside`): no write
    /// goes over it until it is.
    unreadable: std::sync::atomic::AtomicBool,
    /// Every write fails while set (tests).
    #[cfg(test)]
    pub(super) refuse_writes: std::sync::atomic::AtomicBool,
    /// Moving an unreadable file aside fails while set (tests).
    #[cfg(test)]
    pub(super) refuse_set_aside: std::sync::atomic::AtomicBool,
}

impl Drop for LinkShares {
    fn drop(&mut self) {
        self.timers.stop();
    }
}

/// Moves `directory`'s shares file to the first free name of `.unreadable`,
/// `.unreadable-<ms>`, `.unreadable-<ms>-1`, … A hard link never replaces what is at its
/// name (a `rename` would: two moves in one millisecond, or a clock that went back, pick the
/// same name), so a taken name moves on to the next; the original is removed once linked. A
/// filesystem without hard links falls back to `rename`, and only onto a name nothing is at.
fn set_aside_unreplaced(directory: &Path, ms: u64) -> std::io::Result<()> {
    use std::io::ErrorKind;
    let path = directory.join(FILE);
    let mut attempt = 0u64;
    loop {
        let aside = directory.join(match attempt {
            0 => format!("{FILE}.unreadable"),
            1 => format!("{FILE}.unreadable-{ms}"),
            n => format!("{FILE}.unreadable-{ms}-{}", n - 1),
        });
        attempt += 1;
        match std::fs::hard_link(&path, &aside) {
            Ok(()) => {
                return match std::fs::remove_file(&path) {
                    Err(error) if error.kind() != ErrorKind::NotFound => Err(error),
                    _ => Ok(()),
                };
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
            Err(_) if std::fs::symlink_metadata(&aside).is_ok() => {}
            Err(_) => {
                return match std::fs::rename(&path, &aside) {
                    Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
                    moved => moved,
                };
            }
        }
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

/// The author a guest binds as; an invitee's also names its role. The author is stamped on what
/// the guest sends (`_meta.acpmux.author`), which every participant of the chat sees, so it never
/// names the invitee's account (often an email): that stays in the owner's own `-list`.
fn author_of(share: &LinkShare, guest: &Guest) -> Value {
    let mut author = json!({"id": format!("{GUEST_PREFIX}{}.{}", share.share_id, guest.guest_id),
        "name": guest.name, "approval": "owner"});
    if guest.account.is_some() {
        author["role"] = json!(guest.role.unwrap_or(Role::View));
    }
    author
}

/// Whether a bound guest's author may only watch (an invitee with the `view` role).
pub(super) fn view_only(author: &Value) -> bool {
    author["role"].is_string() && author["role"] != json!(Role::Talk)
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
pub(super) struct Invite {
    pub(super) share_id: String,
    pub(super) account: String,
    #[serde(default)]
    pub(super) role: Option<Role>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Uninvite {
    share_id: String,
    account: String,
}

/// A redeem: a link guest's (`secret`) or an invited account's (`account`, attested by the room
/// after its sign-in, never with the secret).
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Redeem {
    pub(super) share_id: String,
    #[serde(default)]
    pub(super) secret: String,
    pub(super) name: String,
    pub(super) attempt_id: String,
    #[serde(default)]
    pub(super) account: Option<String>,
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
        let shares = slot.get_or_insert_with(|| self.load(directory));
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
            // A refused change leaves nothing behind.
            Err(code) => {
                *shares = before;
                Err(code)
            }
        };
        self.note_ended(&start, shares);
        answer
    }

    /// The shares in `directory`'s file (none without one). A file that is there but does not
    /// read back (past the state file's bound, not this user's, not JSON) is moved aside to
    /// `agent-session-shares.json.unreadable` ([`Self::set_aside`]), so the next write does not
    /// destroy it; until it is
    /// moved, every write is refused ([`Self::save`]).
    fn load(&self, directory: Option<&Path>) -> Vec<LinkShare> {
        let Some(directory) = directory else { return Vec::new() };
        let path = directory.join(FILE);
        if std::fs::symlink_metadata(&path).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
        {
            return Vec::new();
        }
        let read = read_trusted(&path).and_then(|bytes| serde_json::from_slice(&bytes).ok());
        if let Some(shares) = read {
            return shares;
        }
        match self.set_aside(directory) {
            Ok(()) => eprintln!("cmux-tui: unreadable link shares kept aside as {FILE}.unreadable"),
            Err(error) => {
                eprintln!("cmux-tui: unreadable link shares not moved aside, not written: {error}");
                self.unreadable.store(true, Ordering::Relaxed);
            }
        }
        Vec::new()
    }

    /// Moves an unreadable shares file to `agent-session-shares.json.unreadable` (or, when one
    /// from before is there, `….unreadable-<unix ms>`, then `….unreadable-<unix ms>-<n>`), so no
    /// write replaces it and no earlier copy is lost. Ok when there is nothing at the path any
    /// more.
    fn set_aside(&self, directory: &Path) -> std::io::Result<()> {
        #[cfg(test)]
        if self.refuse_set_aside.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("set aside refused (test)"));
        }
        set_aside_unreplaced(directory, wall_ms())
    }

    fn save(&self, directory: Option<&Path>, shares: &[LinkShare]) -> Option<std::io::Result<()>> {
        #[cfg(test)]
        if self.refuse_writes.load(Ordering::Relaxed) {
            return Some(Err(std::io::Error::other("writes refused (test)")));
        }
        let directory = directory?;
        if self.unreadable.load(Ordering::Relaxed) {
            if let Err(error) = self.set_aside(directory) {
                return Some(Err(error));
            }
            eprintln!("cmux-tui: unreadable link shares kept aside as {FILE}.unreadable");
            self.unreadable.store(false, Ordering::Relaxed);
        }
        Some(save(directory, FILE, &shares))
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
        let ids = open::NewIds::draw()?;
        self.with(directory, |shares, now| {
            open::push(shares, now, ids, session, surface, terms, provisioning).map(|v| (v, true))
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
        let account = p.account.as_deref().map(normal_account).transpose()?;
        let guest_id = token::<8>()?;
        let attempt = hex(&digest(&[&p.attempt_id]));
        self.with(directory, |shares, now| {
            let share = find(shares, &p.share_id)?;
            let secret_matches =
                || !p.secret.is_empty() && same(&hex(&digest(&[&p.secret])), &share.secret_sha256);
            let (account, role) = match account {
                None if !secret_matches() => return Err("share.secret"),
                None => (None, None),
                Some(account) => {
                    // An ended share says how it ended, to any account.
                    share.live()?;
                    // A retry of a removed account's earlier join says it was removed.
                    let earlier = share.guests.iter().any(|g| {
                        g.account.as_ref() == Some(&account) && same(&g.attempt_id_sha256, &attempt)
                    });
                    let invitee = share
                        .invitees
                        .iter()
                        .find(|i| i.account == account && i.state == InviteState::Invited);
                    match (invitee, earlier) {
                        (Some(invitee), _) => {
                            let role = invitee.role;
                            (Some(account), Some(role))
                        }
                        (None, true) => return Err("share.kicked"),
                        // An account that is not invited but holds the link's secret joins by
                        // the link, as a link guest (a use spent, no account kept).
                        (None, false) if secret_matches() => (None, None),
                        (None, false) => return Err("share.not_invited"),
                    }
                }
            };
            share.live()?;
            let reply = |g: &Guest| {
                let mut answer =
                    json!({"share_id": p.share_id, "guest_id": g.guest_id, "name": g.name});
                // An invitee's role (a link guest has none): the room hands it to the page.
                if let Some(role) = g.role {
                    answer["role"] = json!(role);
                }
                answer
            };
            if let Some(guest) = share.guests.iter().find(|g| same(&g.attempt_id_sha256, &attempt))
            {
                // An attempt is one account's: another account (or a link guest) never gets it.
                if guest.account != account {
                    return Err(if account.is_some() {
                        "share.not_invited"
                    } else {
                        "share.secret"
                    });
                }
                return match guest.state {
                    GuestState::Active => Ok((reply(guest), false)),
                    GuestState::Kicked => Err("share.kicked"),
                    GuestState::Left => Err("share.left"),
                };
            }
            match &account {
                // An invite spends no link use; it bounds the account's live guests instead.
                Some(account) => {
                    let live = share
                        .guests
                        .iter()
                        .filter(|g| g.account.as_ref() == Some(account))
                        .filter(|g| g.state == GuestState::Active)
                        .count();
                    if live >= MAX_GUESTS_PER_ACCOUNT {
                        return Err("share.used");
                    }
                    // The account's ended guests go: an invited account may join again anyway,
                    // so its history only grows the file.
                    share.guests.retain(|g| {
                        g.account.as_ref() != Some(account) || g.state == GuestState::Active
                    });
                }
                None if share.uses_left == 0 => return Err("share.used"),
                None => share.uses_left -= 1,
            }
            let guest = Guest {
                guest_id,
                name: p.name.clone(),
                joined_at: now,
                state: GuestState::Active,
                attempt_id_sha256: attempt,
                account,
                role,
            };
            let answer = reply(&guest);
            share.guests.push(guest);
            if !fits_or_prune(shares) {
                return Err("share.limit");
            }
            Ok((answer, true))
        })
    }

    /// Invites an account to a share (`talk` unless named `view`). Inviting it again with the
    /// same role changes nothing; with another role it is refused (`share.invited`: uninvite
    /// first, so no bound guest keeps an author its role no longer matches). A removed account
    /// invited again joins anew; its earlier guests stay removed.
    pub(super) fn invite(
        &self,
        directory: Option<&Path>,
        p: &Invite,
    ) -> Result<Value, &'static str> {
        let account = normal_account(&p.account)?;
        let role = p.role.unwrap_or(Role::Talk);
        self.with(directory, |shares, now| open::invite_in(shares, &p.share_id, account, role, now))
    }

    /// Removes an invited account: it joins no more, and every guest it joined as is kicked (its
    /// connections close at the next `settle`, and the room hears each kick).
    fn uninvite(&self, directory: Option<&Path>, p: &Uninvite) -> Result<Value, &'static str> {
        let account = normal_account(&p.account)?;
        self.with(directory, |shares, _| {
            let share = find(shares, &p.share_id)?;
            let room_hears = share.room.is_some() && share.live().is_ok();
            let invitee =
                share.invitees.iter_mut().find(|i| i.account == account).ok_or("share.unknown")?;
            let mut changed = invitee.state != InviteState::Removed;
            invitee.state = InviteState::Removed;
            let mut kicks = Vec::new();
            for guest in share.guests.iter_mut().filter(|g| g.account.as_ref() == Some(&account)) {
                if guest.state == GuestState::Active {
                    guest.state = GuestState::Kicked;
                    changed = true;
                    if room_hears {
                        kicks.push(json!({"op": "kick", "guest_id": guest.guest_id}));
                    }
                }
            }
            share.pending_room_ops.extend(kicks);
            let answer = json!({"share_id": share.share_id, "account": account,
                "state": InviteState::Removed});
            Ok((answer, changed))
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
        let shares = slot.get_or_insert_with(|| self.load(directory));
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
    let open = slot.get_or_insert_with(|| shares.load(directory.as_deref())).iter();
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
        "agent-session-share-create" => {
            parse(params).and_then(|p: Create| open::create(mux, shares, directory, p))
        }
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
        // The room new links go to and the API their owner token must come from: the app mints from
        // this API, so a room and a token never come from two environments (cmux#31372).
        "agent-session-share-room" => {
            let room = shares.bridge.room();
            let url = room.as_ref().map(|room| room.url());
            let api = url.and_then(crate::cloud_conversations::platform::share_owner_api);
            Ok(json!({"room": url, "owner_api": api}))
        }
        "agent-session-share-invite" => {
            parse(params).and_then(|p: Invite| shares.invite(directory, &p))
        }
        "agent-session-share-invite-chat" => parse(params)
            .and_then(|p: open::InviteChat| open::invite_chat(mux, shares, directory, p)),
        "agent-session-share-uninvite" => {
            parse(params).and_then(|p: Uninvite| shares.uninvite(directory, &p))
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
        "share.not_invited" => "this account is not invited to the share",
        "share.invited" => "the account is already invited with another role; uninvite it first",
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
#[path = "agent_session_share_invite_chat_tests.rs"]
mod invite_chat_tests;
#[cfg(test)]
#[path = "agent_session_shares_tests.rs"]
mod tests;
