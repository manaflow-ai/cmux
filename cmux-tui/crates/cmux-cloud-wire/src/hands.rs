//! Chief hands (docs/chief-hands.md; backend hand-levels.ts, hand-routes.ts):
//! the owner's hands and their permission levels, the requests that wait for
//! the owner, the user socket's hand frames, and the texts a person's app
//! signs. Sans-I/O like the rest of this crate: `cmux cloud hands` (cmux-tui
//! `cli/cloud_hands.rs`) does the HTTP and the socket, and the macOS app only
//! signs and shows.
//!
//! The user socket (`/v1/wire/user`, `cmux.wire/1`) is read for two frames:
//! `hand-approval-pending {hand, id, summary, at}` and
//! `hand-approval-settled {hand, id, outcome}`. They are ephemeral (no
//! replay), so each subscribe answer (`snapshot`) asks for the waiting list
//! again ([`tracker::Tracker`] merges the two).

pub mod tracker;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The user socket's path on the API Worker.
pub const USER_SOCKET_PATH: &str = "/v1/wire/user";
/// The socket's subprotocol.
pub const SUBPROTOCOL: &str = "cmux.wire.v1";
/// The frame that answers `welcome`.
pub const SUBSCRIBE: &str = r#"{"t":"subscribe"}"#;
/// The server's refusal of a level change without a valid presence proof.
pub const LEVEL_REFUSED: &str = "hand.level_refused";
/// The refusals that mean the request ended already: the banner goes.
pub const ANSWERED_CODES: [&str; 3] =
    ["hand.approval_answered", "hand.approval_not_found", "hand.not_found"];
/// The longest summary line.
pub const SUMMARY_LIMIT: usize = 300;

/// A hand's permission level. The owner sets it; a raise (to a looser level)
/// needs the owner's presence proof, a lower needs none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HandLevel {
    Full,
    Auto,
    Ask,
    ReadOnly,
}

impl HandLevel {
    /// The level a server or caller names, else none.
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "full" => Self::Full,
            "auto" => Self::Auto,
            "ask" => Self::Ask,
            "read-only" => Self::ReadOnly,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::Auto => "auto",
            Self::Ask => "ask",
            Self::ReadOnly => "read-only",
        }
    }

    /// Stricter to looser, as the server ranks them.
    fn rank(self) -> u8 {
        match self {
            Self::ReadOnly => 0,
            Self::Ask => 1,
            Self::Auto => 2,
            Self::Full => 3,
        }
    }

    /// Whether `self` to `to` loosens the hand.
    pub fn is_raise(self, to: Self) -> bool {
        to.rank() > self.rank()
    }
}

/// The profile a hand was paired with; an owner default level applies per profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HandProfile {
    Sandbox,
    Mac,
}

impl HandProfile {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "sandbox" => Some(Self::Sandbox),
            "mac" => Some(Self::Mac),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Mac => "mac",
        }
    }
}

/// A hand id the client accepts in a path or a signed text: `hand_` and 20
/// base32 characters (backend hand-routes.ts).
pub fn is_hand_id(id: &str) -> bool {
    id.strip_prefix("hand_").is_some_and(|tail| {
        tail.len() == 20
            && tail.bytes().all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b))
    })
}

/// An approval id: 36 characters of lowercase hex and `-` (a UUID).
pub fn is_approval_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b) || b == b'-')
}

/// A level challenge's nonce: 16 to 128 lowercase hex characters.
pub fn is_nonce(nonce: &str) -> bool {
    (16..=128).contains(&nonce.len())
        && nonce.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// One of the owner's hands (`GET /v1/hands`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HandSummary {
    pub hand: String,
    pub name: String,
    pub profile: Option<HandProfile>,
    pub online: bool,
    pub level: Option<HandLevel>,
    pub pending_approvals: Option<i64>,
}

impl HandSummary {
    /// One row; none without a `hand` string. A field of another type, or a
    /// level or profile this build does not know, reads as absent.
    pub fn from_value(row: &Value) -> Option<Self> {
        let hand = row.get("hand")?.as_str()?.to_owned();
        let text = |key: &str| row.get(key).and_then(Value::as_str);
        Some(Self {
            hand,
            name: text("name").unwrap_or_default().to_owned(),
            profile: text("profile").and_then(HandProfile::parse),
            online: row.get("online").and_then(Value::as_bool).unwrap_or(false),
            level: text("level").and_then(HandLevel::parse),
            pending_approvals: row.get("pending_approvals").and_then(Value::as_i64),
        })
    }

    /// The list `GET /v1/hands` answers; none when it is not an array of rows.
    pub fn list(value: &Value) -> Option<Vec<Self>> {
        value.as_array()?.iter().map(Self::from_value).collect()
    }

    /// The name people see: the hand's name, else its id.
    pub fn display_name(&self) -> &str {
        if self.name.is_empty() { &self.hand } else { &self.name }
    }

    /// Whether the launch read asks for its waiting requests (an unknown count asks).
    pub fn may_wait(&self) -> bool {
        self.pending_approvals.unwrap_or(1) > 0
    }
}

/// A hand request that waits for the owner (`hand-approval-pending`, or the
/// launch read `GET /v1/hands/<hand>/approvals`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HandApproval {
    pub hand: String,
    pub id: String,
    /// What the hand asks to do, as one line ([`describe`]).
    pub summary: String,
    /// When it was asked, in ms since the epoch.
    pub at: f64,
    /// The banner id and the tracker's key ([`approval_key`]).
    pub key: String,
}

impl HandApproval {
    /// Parses one approval object; `fallback` is the list's hand for the
    /// launch read, `now_ms` the time of one without `at`.
    pub fn from_value(object: &Value, fallback: Option<&str>, now_ms: f64) -> Option<Self> {
        let hand = object.get("hand").and_then(Value::as_str).or(fallback)?;
        let id = object.get("id").and_then(Value::as_str)?;
        if !is_hand_id(hand) || !is_approval_id(id) {
            return None;
        }
        Some(Self {
            hand: hand.to_owned(),
            id: id.to_owned(),
            summary: describe(object.get("summary")),
            at: object.get("at").and_then(Value::as_f64).unwrap_or(now_ms),
            key: approval_key(hand, id),
        })
    }

    /// The waiting requests of `hand` in a list answer (rows that do not parse are skipped).
    pub fn list(value: &Value, hand: &str, now_ms: f64) -> Vec<Self> {
        value
            .as_array()
            .map(|rows| {
                rows.iter().filter_map(|row| Self::from_value(row, Some(hand), now_ms)).collect()
            })
            .unwrap_or_default()
    }
}

/// The banner id of one approval.
pub fn approval_key(hand: &str, id: &str) -> String {
    format!("hand-approval.{hand}.{id}")
}

/// One line from the hand's summary: `action` and its argv, title, paths or
/// prompt; a plain string as it is; at most [`SUMMARY_LIMIT`] characters.
pub fn describe(summary: Option<&Value>) -> String {
    let line = match summary {
        Some(Value::Object(object)) => {
            let action = object.get("action").and_then(Value::as_str).unwrap_or_default();
            let joined = |key: &str, separator: &str| {
                object
                    .get(key)
                    .and_then(Value::as_array)
                    .map(|items| items.iter().map(plain).collect::<Vec<_>>().join(separator))
            };
            let detail = joined("argv", " ")
                .or_else(|| object.get("title").and_then(Value::as_str).map(str::to_owned))
                .or_else(|| joined("paths", ", "))
                .or_else(|| object.get("prompt").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_default();
            [action, detail.as_str()]
                .iter()
                .filter(|part| !part.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join(": ")
        }
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    };
    line.chars().take(SUMMARY_LIMIT).collect()
}

/// A string as its text, anything else as its JSON.
fn plain(value: &Value) -> String {
    value.as_str().map_or_else(|| value.to_string(), str::to_owned)
}

/// How a waiting approval ended (`hand-approval-settled.outcome`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HandOutcome {
    Allowed,
    Denied,
    Expired,
}

impl HandOutcome {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "allowed" => Some(Self::Allowed),
            "denied" => Some(Self::Denied),
            "expired" => Some(Self::Expired),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Allowed => "allowed",
            Self::Denied => "denied",
            Self::Expired => "expired",
        }
    }
}

/// One user-socket frame, as the hands read it.
#[derive(Debug, Clone, PartialEq)]
pub enum HandFrame {
    /// Answer with [`SUBSCRIBE`].
    Welcome,
    /// Subscribed (also after a reconnect): read the waiting approvals now.
    Snapshot,
    Pending(HandApproval),
    Settled {
        hand: String,
        id: String,
        outcome: HandOutcome,
    },
    /// Any other frame, or a hand frame whose ids do not check.
    Ignored,
}

impl HandFrame {
    /// Decodes one text frame. A snapshot (up to about 1.5 MB) is only
    /// scanned for its type, never built into a value.
    pub fn decode(text: &[u8], now_ms: f64) -> Self {
        #[derive(Deserialize)]
        struct Kind<'a> {
            #[serde(borrow, default)]
            t: Option<std::borrow::Cow<'a, str>>,
        }
        let Ok(kind) = serde_json::from_slice::<Kind<'_>>(text) else { return Self::Ignored };
        match kind.t.as_deref() {
            Some("welcome") => Self::Welcome,
            Some("snapshot") => Self::Snapshot,
            Some("hand-approval-pending") => serde_json::from_slice::<Value>(text)
                .ok()
                .and_then(|object| HandApproval::from_value(&object, None, now_ms))
                .map_or(Self::Ignored, Self::Pending),
            Some("hand-approval-settled") => {
                let Ok(object) = serde_json::from_slice::<Value>(text) else {
                    return Self::Ignored;
                };
                let field = |key: &str| object.get(key).and_then(Value::as_str);
                match (field("hand"), field("id"), field("outcome").and_then(HandOutcome::parse)) {
                    (Some(hand), Some(id), Some(outcome))
                        if is_hand_id(hand) && is_approval_id(id) =>
                    {
                        Self::Settled { hand: hand.to_owned(), id: id.to_owned(), outcome }
                    }
                    _ => Self::Ignored,
                }
            }
            _ => Self::Ignored,
        }
    }
}

/// The user socket's URL on the API origin `api` (`http` gives `ws`, anything else `wss`).
pub fn user_socket_url(api: &str) -> String {
    let api = api.trim_end_matches('/');
    let (scheme, rest) = match api.split_once("://") {
        Some(("http", rest)) => ("ws", rest),
        Some((_, rest)) => ("wss", rest),
        None => ("wss", api),
    };
    let host = rest.split('/').next().unwrap_or(rest);
    format!("{scheme}://{host}{USER_SOCKET_PATH}")
}

/// The delay before reconnect `attempt` (0 first): 500 ms doubling to 30 s,
/// ±20% by `random` in 0..1.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "clamped to 0..=36000 ms first, so the cast keeps the value"
)]
pub fn reconnect_delay_ms(attempt: u32, random: f64) -> u64 {
    let base = (500.0 * 2f64.powi(attempt.min(62).try_into().unwrap_or(62))).min(30_000.0);
    let spread = base * 0.2 * (random.clamp(0.0, 1.0) * 2.0 - 1.0);
    (base + spread).clamp(0.0, 36_000.0) as u64
}

/// What a level change names: one hand, or the owner default of new hands of a profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Hand(String),
    Default(HandProfile),
}

impl Target {
    /// A hand id, or `default:<profile>`; none for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        match text.strip_prefix("default:") {
            Some(profile) => HandProfile::parse(profile).map(Self::Default),
            None => is_hand_id(text).then(|| Self::Hand(text.to_owned())),
        }
    }

    /// The text the level proof names.
    pub fn text(&self) -> String {
        match self {
            Self::Hand(hand) => hand.clone(),
            Self::Default(profile) => format!("default:{}", profile.as_str()),
        }
    }

    /// `POST` for a single-use nonce for one raise.
    pub fn challenge_path(&self) -> String {
        match self {
            Self::Hand(hand) => format!("/v1/hands/{hand}/level-challenge"),
            Self::Default(profile) => format!("/v1/hands/defaults/{}/challenge", profile.as_str()),
        }
    }

    /// `PUT {level}` (plus the proof for a raise).
    pub fn level_path(&self) -> String {
        match self {
            Self::Hand(hand) => format!("/v1/hands/{hand}/level"),
            Self::Default(profile) => format!("/v1/hands/defaults/{}", profile.as_str()),
        }
    }
}

/// How a level change goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LevelPlan {
    /// The plain `PUT`; a [`LEVEL_REFUSED`] answer makes it a raise after all
    /// (the known level was stale, or a default's current level is not known).
    Plain,
    /// A raise: challenge, presence proof, then the `PUT`.
    Proof,
}

/// A hand's change from its `known` level: a lower is plain, a raise or an
/// unknown level takes the proof. The app does not know a default's current
/// level, so a default tries the plain `PUT` first.
pub fn level_plan(target: &Target, known: Option<HandLevel>, to: HandLevel) -> LevelPlan {
    match (target, known) {
        (Target::Default(_), _) => LevelPlan::Plain,
        (Target::Hand(_), Some(from)) if !from.is_raise(to) => LevelPlan::Plain,
        (Target::Hand(_), _) => LevelPlan::Proof,
    }
}

/// The texts a person's app signs (backend hand-levels.ts). Each is built
/// here from ids that were checked; the app never signs a text that the
/// server or the wire sent.
pub mod proof {
    use super::{HandLevel, Target};

    /// The install key signs this to register the presence key of `install`.
    pub fn presence_registration(environment: &str, install: &str, x: &str, y: &str) -> String {
        format!("cmux-hand-presence-key:{environment}:{install}:{x}:{y}")
    }

    /// The presence key signs this to raise `target` to `level`.
    pub fn level(environment: &str, target: &Target, level: HandLevel, nonce: &str) -> String {
        format!("cmux-hand-level:{environment}:{}:{}:{nonce}", target.text(), level.as_str())
    }

    /// The install key signs this to allow one waiting request.
    pub fn approval(environment: &str, hand: &str, id: &str) -> String {
        format!("cmux-hand-approval:{environment}:{hand}:{id}:allow")
    }
}

#[cfg(test)]
mod tests;
