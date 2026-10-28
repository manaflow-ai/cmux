//! Link shares (`agent-session-share-*`, design chat-multiplayer.md 4.2): the owner shares one
//! agent chat with a guest through a link that works a few times (once by default) and expires
//! (24 h by default). The records live next to the session's registry (`agent-session-shares.json`,
//! owner-only, rewritten atomically, `state_file.rs`), so a share, its uses, its guests, a kick and
//! a revoke outlive a daemon restart. A share pins the chat's acpmux
//! session, never the surface number (surfaces are per boot).
//!
//! The verbs are the owner's own: a same-user unix connection that is neither bound (a teammate's
//! proxy or a guest) nor a remote relay. Only the secret's SHA-256 is kept; create answers the
//! secret once. Expiry is checked on every use. The guest's binding (a connection that reaches the
//! shared chat as the redeemed guest, its prompts held for the owner) comes in the next change.
//!
//! The hosted room (`room`, `provision_key`, `pending_room_ops`, the `provisioning` state) comes
//! with the room bridge: until then a share is `active` from its create and `url` is null.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::{MessageWriter, Response, ok, send_response, tab_session};
use crate::mux::Mux;
use crate::server::agent_transfer::state_file::{read_trusted, save};

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
            "uses_left": self.uses_left, "state": self.state, "room": self.room, "url": null,
            "guests": guests})
    }
}

/// The daemon's link shares, read from the session's state directory on first use.
#[derive(Default)]
pub(in crate::server) struct LinkShares {
    shares: Mutex<Option<Vec<LinkShare>>>,
    /// Added to the wall clock (tests move time with it).
    skew_ms: AtomicU64,
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    surface: u64,
    #[serde(default)]
    ttl_secs: Option<u64>,
    #[serde(default)]
    uses: Option<u32>,
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
    pub(super) fn advance(&self, by: std::time::Duration) {
        self.skew_ms.fetch_add(by.as_millis() as u64, Ordering::Relaxed);
    }

    /// Runs `change` on the shares under their lock, with every share past its expiry marked
    /// expired first. A change answering `(value, true)` is written before the answer and rolled
    /// back when the write fails (`share.unsaved`).
    fn with<T>(
        &self,
        directory: Option<&Path>,
        change: impl FnOnce(&mut Vec<LinkShare>, u64) -> Result<(T, bool), &'static str>,
    ) -> Result<T, &'static str> {
        let now = self.now();
        let mut slot = self.shares.lock().unwrap_or_else(|e| e.into_inner());
        let shares = slot.get_or_insert_with(|| load(directory));
        for share in shares.iter_mut() {
            if share.state == ShareState::Active && now >= share.expires_at {
                share.state = ShareState::Expired;
            }
        }
        let before = shares.clone();
        let (value, changed) = change(shares, now)?;
        if changed
            && let Some(directory) = directory
            && let Err(error) = save(directory, FILE, shares)
        {
            *shares = before;
            eprintln!("cmux-tui: link shares not written: {error}");
            return Err("share.unsaved");
        }
        Ok(value)
    }

    /// A new share of `session`, shown on `surface`; answers the secret once.
    pub(super) fn insert(
        &self,
        directory: Option<&Path>,
        session: String,
        surface: u64,
        ttl_secs: u64,
        uses: u32,
    ) -> Result<Value, &'static str> {
        let (share_id, secret, provision_key) = (token::<16>()?, token::<16>()?, token::<16>()?);
        self.with(directory, |shares, now| {
            if shares.len() >= MAX_SHARES {
                shares.retain(|s| s.live().is_ok());
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
                state: ShareState::Active,
                secret_sha256: hex(&digest(&[&secret])),
                provision_key: Some(provision_key),
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
                    _ => Err("share.kicked"),
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
        self.with(directory, |shares, _| {
            let share = find(shares, &p.share_id)?;
            let Some(guest_id) = &p.guest_id else {
                let changed = share.state != ShareState::Revoked;
                share.state = ShareState::Revoked;
                return Ok((json!({"share_id": share.share_id, "state": share.state}), changed));
            };
            let guest =
                share.guests.iter_mut().find(|g| &g.guest_id == guest_id).ok_or("share.unknown")?;
            let changed = guest.state != GuestState::Kicked;
            guest.state = GuestState::Kicked;
            Ok((
                json!({"share_id": share.share_id, "guest_id": guest_id, "state": guest.state}),
                changed,
            ))
        })
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
            let session = tab_session(mux, p.surface).ok_or("share.not_a_chat")?;
            shares.insert(directory, session, p.surface, ttl, uses)
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
        "share.name" => "a name is 1 to 64 characters on one line",
        "share.limit" => "too many shares on this machine",
        "share.not_a_chat" => "not an agent chat with a session",
        "share.not_trusted" => "only the owner's own local connection manages shares",
        "share.unsaved" => "the share could not be saved",
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

#[cfg(test)]
#[path = "agent_session_shares_tests.rs"]
mod tests;
