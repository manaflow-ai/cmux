//! The person's signed Cloud capability on the Mac (cmux-platform `CloudCapability.ts`, #1126):
//! Leo, 2026-11-09: "can't we just pre-approve peopel sometimes? the handshakes themsleves take ms,
//! no?". `POST /v1/cloud/capability` runs every check a start runs (membership, sign-in policy,
//! plan, grants) once, off the start path, and answers a token. The app sends it on its Cloud calls
//! in `x-cmux-cloud-capability`, so a create or a start skips those reads.
//!
//! The app asks here (ops `cloud_capability_header`, `cloud_capability_answer`, `cloud_capability_drop`);
//! this module holds the token for the app process and decides which one goes on a call, when to ask
//! for the next, and what an answer means. The app only makes the fetch. Asked at
//! sign-in, on a team switch and while the person types (the composer's reserve), and again on a
//! call once the token is past its refresh time; never on a timer, so nothing runs while Cloud is
//! idle. A call never waits for a fetch: it goes with the token it has, or with none (the server's
//! full checks, as before).
//!
//! Times are this Mac's wall clock in ms. The server's own issue and expiry times are read only as
//! a lifetime from the moment the fetch was sent, so a Mac clock that is off never makes a token
//! look fresh past its server expiry.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The request header the token goes in (cmux-platform `CAPABILITY_HEADER`).
pub const HEADER: &str = "x-cmux-cloud-capability";
/// The route that mints it, on the platform origin.
pub const PATH: &str = "/v1/cloud/capability";
/// A token is no longer sent this close to its expiry: transit and the server's own check.
pub const EXPIRY_MARGIN_MS: u64 = 15_000;
/// When an answer names no refresh time: the platform's `CAPABILITY_REFRESH_MS`.
pub const REFRESH_FALLBACK_MS: u64 = 4 * 60_000;
/// A fetch in flight holds off another for this long; its answer clears it sooner.
pub const IN_FLIGHT_MS: u64 = 30_000;
/// After an unreachable or unreadable answer: ask again on a call after this.
pub const RETRY_UNREACHABLE_MS: u64 = 30_000;
/// After a refusal (`auth.forbidden`: no access to the team's machines): the refresh period.
pub const RETRY_REFUSED_MS: u64 = REFRESH_FALLBACK_MS;
/// After `cloud.capability_off` or a backend without the route (404).
pub const RETRY_OFF_MS: u64 = 30 * 60_000;
/// Longest token kept (cmux-platform `MAX_TOKEN_CHARS`).
pub const MAX_TOKEN_CHARS: usize = 4096;

/// A token the app holds for one team.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Held {
    pub token: String,
    pub team: String,
    /// Not sent at or after this.
    #[serde(deserialize_with = "ms")]
    pub use_until_ms: u64,
    /// A call at or after this asks for the next one.
    #[serde(deserialize_with = "ms")]
    pub refresh_at_ms: u64,
}

/// What the app keeps between calls (as JSON, opaque to it).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    #[serde(default)]
    pub held: Option<Held>,
    /// No fetch starts before this (a fetch in flight, or the backoff after a failed one).
    #[serde(default, deserialize_with = "ms")]
    pub next_fetch_ms: u64,
}

/// One call is about to go in `team` (the install token's team) at `now_ms`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UseRequest {
    #[serde(default)]
    pub state: State,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(deserialize_with = "ms")]
    pub now_ms: u64,
}

/// The token to send (none: the full checks), whether to start a fetch now, and the state to keep.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UseReply {
    pub header: Option<String>,
    pub fetch: bool,
    pub state: State,
}

/// The token for a call in `team` at `now_ms`, and whether this call starts the next fetch. A fetch
/// it starts holds off others for [`IN_FLIGHT_MS`]. With no team (signed out, no install token
/// yet) nothing is sent and nothing is fetched.
pub fn use_for(request: &UseRequest) -> UseReply {
    let mut state = request.state.clone();
    let Some(team) = request.team.as_deref().filter(|team| !team.is_empty()) else {
        return UseReply { header: None, fetch: false, state };
    };
    let now = request.now_ms;
    let held = state.held.as_ref().filter(|held| held.team == team);
    let header = held.filter(|held| now < held.use_until_ms).map(|held| held.token.clone());
    let due = held.is_none_or(|held| now >= held.refresh_at_ms);
    let fetch = due && now >= state.next_fetch_ms;
    if fetch {
        state.next_fetch_ms = now.saturating_add(IN_FLIGHT_MS);
    }
    UseReply { header, fetch, state }
}

/// The route's answer to a fetch for `team` sent at `sent_ms`, read at
/// `now_ms`. `status` 0: no answer (unreachable, timed out).
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeepRequest {
    #[serde(default)]
    pub state: State,
    pub team: String,
    #[serde(deserialize_with = "ms")]
    pub sent_ms: u64,
    #[serde(deserialize_with = "ms")]
    pub now_ms: u64,
    #[serde(deserialize_with = "ms")]
    pub status: u64,
    #[serde(default)]
    pub body: Value,
}

/// The state after an answer, and what it was (for the app's one log line; never the token).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeepReply {
    pub state: State,
    pub outcome: &'static str,
}

/// Keeps a good answer's token for `team`; on anything else holds none for that team and backs
/// off: [`RETRY_OFF_MS`] when the backend has no capabilities, [`RETRY_REFUSED_MS`] on a refusal,
/// else [`RETRY_UNREACHABLE_MS`]. A token another team's answer named, an expired one, or one that
/// could not go in a header is never kept.
pub fn keep(request: &KeepRequest) -> KeepReply {
    let mut state = request.state.clone();
    if state.held.as_ref().is_some_and(|held| held.team == request.team) {
        state.held = None;
    }
    let now = request.now_ms;
    let back_off = |mut state: State, after: u64, outcome| {
        state.next_fetch_ms = now.saturating_add(after);
        KeepReply { state, outcome }
    };
    let body = &request.body;
    let code = body.pointer("/error/code").and_then(Value::as_str).unwrap_or_default();
    match request.status {
        200 => {}
        404 => return back_off(state, RETRY_OFF_MS, "off"),
        401 | 403 if code != "owner.unreachable" => {
            return back_off(state, RETRY_REFUSED_MS, "refused");
        }
        0 => return back_off(state, RETRY_UNREACHABLE_MS, "unreachable"),
        _ => return back_off(state, RETRY_UNREACHABLE_MS, "failed"),
    }
    let value = body.get("value").unwrap_or(&Value::Null);
    let token = value.get("capability").and_then(Value::as_str).unwrap_or_default();
    let team = value.get("team").and_then(Value::as_str).unwrap_or_default();
    let number = |name: &str| value.get(name).and_then(whole);
    let (Some(issued), Some(expires)) = (number("issued_at"), number("expires_at")) else {
        return back_off(state, RETRY_UNREACHABLE_MS, "unreadable");
    };
    if body.get("ok").and_then(Value::as_bool) != Some(true) || !header_safe(token) {
        return back_off(state, RETRY_UNREACHABLE_MS, "unreadable");
    }
    if team != request.team {
        return back_off(state, RETRY_UNREACHABLE_MS, "wrong_team");
    }
    let lifetime = expires.saturating_sub(issued);
    let refresh = number("refresh_at").map_or(REFRESH_FALLBACK_MS, |at| at.saturating_sub(issued));
    let use_until_ms = request.sent_ms.saturating_add(lifetime).saturating_sub(EXPIRY_MARGIN_MS);
    if use_until_ms <= now {
        return back_off(state, RETRY_UNREACHABLE_MS, "expired");
    }
    let refresh_at_ms = request.sent_ms.saturating_add(refresh.min(lifetime)).min(use_until_ms);
    state.held =
        Some(Held { token: token.to_owned(), team: team.to_owned(), use_until_ms, refresh_at_ms });
    state.next_fetch_ms = 0;
    KeepReply { state, outcome: "held" }
}

/// The token this app process holds, kept here so the app carries no state of its own (Swift stays minimal in
/// the Cloud core: `.github/language-boundaries.toml` `cloud-core-swift-minimal`).
static HELD: std::sync::Mutex<State> =
    std::sync::Mutex::new(State { held: None, next_fetch_ms: 0 });

fn held() -> std::sync::MutexGuard<'static, State> {
    HELD.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// `cloud_capability_header`: a call in `team` is about to go at `now_ms`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeaderRequest {
    #[serde(default)]
    pub team: Option<String>,
    #[serde(deserialize_with = "ms")]
    pub now_ms: u64,
}

/// The token to send (none: the server's full checks) and whether the app starts the fetch now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeaderReply {
    pub header: Option<String>,
    pub fetch: bool,
}

/// [`use_for`] on the process's held state.
pub fn header(request: &HeaderRequest) -> HeaderReply {
    let mut state = held();
    let reply = use_for(&UseRequest {
        state: state.clone(),
        team: request.team.clone(),
        now_ms: request.now_ms,
    });
    *state = reply.state;
    HeaderReply { header: reply.header, fetch: reply.fetch }
}

/// `cloud_capability_answer`: [`KeepRequest`] without the state, which this process holds.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnswerRequest {
    pub team: String,
    #[serde(deserialize_with = "ms")]
    pub sent_ms: u64,
    #[serde(deserialize_with = "ms")]
    pub now_ms: u64,
    #[serde(deserialize_with = "ms")]
    pub status: u64,
    #[serde(default)]
    pub body: Value,
}

/// What the answer was (for the app's one log line; never the token).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AnswerReply {
    pub outcome: &'static str,
}

/// [`keep`] on the process's held state.
pub fn answer(request: AnswerRequest) -> AnswerReply {
    let mut state = held();
    let reply = keep(&KeepRequest {
        state: state.clone(),
        team: request.team,
        sent_ms: request.sent_ms,
        now_ms: request.now_ms,
        status: request.status,
        body: request.body,
    });
    *state = reply.state;
    AnswerReply { outcome: reply.outcome }
}

/// `cloud_capability_drop`: the install token was refused, or the account or team changed. Nothing is sent until
/// a new token is fetched.
pub fn forget() {
    *held() = State::default();
}

/// A whole non-negative number from JSON, written as an integer or (through Swift's `JSONValue`) a float.
fn whole(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| ms(value.clone()).ok())
}

/// A time (or status) the app sent as a JSON number: Swift's `JSONValue` keeps numbers as `Double`, so a
/// whole `1.0e12` is read as well as `1000000000000`; a negative, fractional or non-finite one is refused.
fn ms<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    let value = f64::deserialize(deserializer)?;
    if value.is_finite() && value >= 0.0 && value.fract() == 0.0 && value < 9.007_199_254_740_992e15
    {
        #[allow(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "checked above: finite, non-negative, whole and under 2^53"
        )]
        return Ok(value as u64);
    }
    Err(serde::de::Error::custom("a whole non-negative number"))
}

/// A token that can go in a header as is: the platform's `cc1.<b64url>.<b64url>` alphabet, no
/// longer than it keeps.
fn header_safe(token: &str) -> bool {
    !token.is_empty()
        && token.len() <= MAX_TOKEN_CHARS
        && token.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

#[cfg(test)]
mod tests;
