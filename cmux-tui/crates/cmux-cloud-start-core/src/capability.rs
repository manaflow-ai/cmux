//! The signed Cloud capability (cmux-platform#1126; Leo, 2026-11-09: "why do we even need to have
//! checks just-in-time anyways, can't we just pre-approve peopel sometimes? the handshakes
//! themsleves take ms, no?"). The app asks `POST /v1/cloud/capability` with its install token at
//! sign-in, on a team switch, on Cloud intent and before the held one is due, never on a start; it
//! holds the answer in memory only and sends it in [`HEADER`] on every op it relays to `/v1/ops`
//! and `/v1/read` with a token of the same team. The Worker then skips the plan and membership
//! reads of that call; a missing, expired or stale capability only means today's full checks.
//!
//! Pure: the app does the HTTP, the timer and the clock; these rules say what a mint's answer
//! holds, what a call sends and when the next mint goes, and [`holder`] is the app's holder over
//! them (sign-in, a team switch, sign-out, refresh and retry) as one reducer.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub mod holder;

/// The request header a relayed op carries the capability in (cmux-platform `CAPABILITY_HEADER`).
pub const HEADER: &str = "x-cmux-cloud-capability";
/// The mint route, relative to the API origin (cmux-platform `CAPABILITY_PATH`).
pub const PATH: &str = "v1/cloud/capability";
/// cmux-platform's `MAX_TOKEN_CHARS`: a longer answer is not a capability.
const MAX_TOKEN_CHARS: usize = 4096;
/// The longest a capability lives (cmux-platform `CAPABILITY_TTL_MS`); an answer claiming more is refused.
const MAX_LIFETIME_MS: i64 = 5 * 60_000;
/// No call sends a capability this close to its expiry: its flight and the clocks' skew would land
/// it expired, which costs the Worker a verify for nothing.
pub const SEND_MARGIN_MS: i64 = 15_000;
/// After a mint that failed, the next one for the same team waits this long (a start never waits on it).
pub const RETRY_AFTER_MS: i64 = 30_000;
/// The timer mints again only while Cloud was used this recently ("every 4 min while Cloud is open").
pub const IDLE_STOP_MS: i64 = 30 * 60_000;

/// The capability the app holds, its times on this Mac's clock (the answer's lifetime counted from
/// its arrival, so a Mac clock that is off never makes a valid one look expired or an expired one valid).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Held {
    pub token: String,
    /// The backend team (`team_…`) it was minted for: the install token's team claim.
    pub team: String,
    pub expires_at: i64,
    pub refresh_at: i64,
}

/// The held capability from a mint's answer (`status`, the parsed `body`) for `team`, received at
/// `now`; `None` for a refusal, a deployment without capabilities, another team or a malformed answer.
pub fn read_mint(status: u16, body: &Value, team: &str, now: i64) -> Option<Held> {
    if status != 200 || body.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let value = body.get("value")?;
    let token = value.get("capability")?.as_str()?;
    if !well_formed(token) || value.get("team")?.as_str()? != team || team.is_empty() {
        return None;
    }
    let issued = value.get("issued_at")?.as_i64()?;
    let expires = value.get("expires_at")?.as_i64()?;
    let lifetime = expires - issued;
    if lifetime <= SEND_MARGIN_MS || lifetime > MAX_LIFETIME_MS {
        return None;
    }
    // The server's refresh time, kept inside the lifetime; a minute early when it names none.
    let refresh = value
        .get("refresh_at")
        .and_then(Value::as_i64)
        .map(|at| at - issued)
        .unwrap_or(lifetime - 60_000)
        .clamp(0, lifetime - SEND_MARGIN_MS);
    Some(Held {
        token: token.to_owned(),
        team: team.to_owned(),
        expires_at: now + lifetime,
        refresh_at: now + refresh,
    })
}

/// `cc1.<payload>.<signature>`, base64url parts, at most [`MAX_TOKEN_CHARS`]: the only shape a
/// header ever carries (it is never logged, and nothing else is sent in its place).
fn well_formed(token: &str) -> bool {
    let base64url = |part: &str| {
        !part.is_empty()
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };
    let mut parts = token.split('.');
    token.len() <= MAX_TOKEN_CHARS
        && parts.next() == Some("cc1")
        && parts.next().is_some_and(base64url)
        && parts.next().is_some_and(base64url)
        && parts.next().is_none()
}

/// Why the app asks: a relayed call wants its header, the refresh timer fired, or sign-in, a team
/// switch or the person's Cloud intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Reason {
    Call,
    Timer,
    Intent,
}

/// What the app holds and knows when it asks [`plan`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub held: Option<Held>,
    /// The team of the token the call goes with (the install token's team claim); `None` signed out.
    pub team: Option<String>,
    pub now: i64,
    /// When a mint for `failed_team` last failed.
    pub failed_at: Option<i64>,
    pub failed_team: Option<String>,
    /// When a call or an intent last asked.
    pub last_use: Option<i64>,
}

/// The answer: the header value this call sends, whether a mint goes now (in the background; a
/// call never waits for it), and how long until the timer should ask again.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub send: Option<String>,
    pub fetch: bool,
    pub wake_in: Option<i64>,
}

/// The capability a call sends, whether to mint, and when to look again.
pub fn plan(state: &State, reason: Reason) -> Plan {
    let Some(team) = state.team.as_deref().filter(|team| !team.is_empty()) else {
        return Plan::default();
    };
    let held = state.held.as_ref().filter(|held| held.team == team);
    let send = held
        .filter(|held| state.now < held.expires_at - SEND_MARGIN_MS)
        .map(|held| held.token.clone());
    let due = held.is_none_or(|held| state.now >= held.refresh_at);
    let backing_off = state.failed_team.as_deref() == Some(team)
        && state.failed_at.is_some_and(|at| state.now - at < RETRY_AFTER_MS);
    // The timer keeps one warm only while Cloud is in use; a call or an intent always may.
    let in_use =
        reason != Reason::Timer || state.last_use.is_some_and(|at| state.now - at < IDLE_STOP_MS);
    // The timer wakes at the refresh time, or after a failed refresh when the backoff ends; never while idle.
    let retry_in = backing_off
        .then(|| state.failed_at.map(|at| at + RETRY_AFTER_MS - state.now))
        .flatten()
        .unwrap_or(0);
    let wake_in =
        held.filter(|_| in_use).map(|held| (held.refresh_at - state.now).max(retry_in).max(0));
    Plan { send, fetch: due && !backing_off && in_use, wake_in }
}

#[cfg(test)]
mod tests;
