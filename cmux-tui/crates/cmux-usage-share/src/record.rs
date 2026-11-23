//! The wire record: cmux-platform's `{at, src, ev}` (src/server/usage/Validate.ts). The server
//! refuses a whole batch on any field it does not list, so every field here is one it lists, and an
//! optional one is left out when absent instead of sent as null.

use serde::{Deserialize, Serialize};

/// The `src` every acpmux record carries.
pub const SRC: &str = "acpmux";

/// One spooled line: when, which process, and the event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    /// Unix ms.
    pub at: u64,
    pub src: String,
    pub ev: Event,
}

/// The events acpmux writes, tagged by `t` as Validate.ts's `EVENTS` names them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Event {
    /// The first time this daemon sees a session.
    Session(SessionEvent),
    /// One finished turn.
    Turn(TurnEvent),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionEvent {
    /// The session id, hashed (24 hex).
    pub session: String,
    pub harness: String,
    /// `local`, or a hashed machine id.
    pub machine: String,
}

/// How a turn ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
    Done,
    Failed,
    Cancelled,
}

impl Outcome {
    /// acpmux's `turn_result` status: `completed`, `cancelled` or `failed`.
    pub fn from_status(status: &str) -> Option<Self> {
        match status {
            "completed" => Some(Self::Done),
            "cancelled" => Some(Self::Cancelled),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// One turn, as Validate.ts's `turn` takes it. Token counts are what the harness reported;
/// `input_tokens` is the fresh input alone (the cache's reads and writes are their own counts).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TurnEvent {
    pub session: String,
    pub harness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Wall time of the turn, ms.
    pub ms: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub tool_calls: u32,
    pub subagents: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
}

/// The largest cost Validate.ts takes.
pub const USD_MAX: f64 = 10_000.0;
/// The largest integer Validate.ts takes as a u64 (JavaScript's safe integer).
pub const U64_MAX_SAFE: u64 = (1 << 53) - 1;

/// `text` when it is a token Validate.ts takes (`^[A-Za-z0-9._:\[\]-]{1,64}$`).
pub fn token(text: &str) -> Option<String> {
    let ok = !text.is_empty()
        && text.len() <= 64
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b".:_[]-".contains(&b));
    ok.then(|| text.to_owned())
}

/// A harness or model name as a token: one that is not stays `other` (harness) or is left out.
pub fn harness_token(text: &str) -> String {
    token(text).unwrap_or_else(|| "other".to_owned())
}

impl TurnEvent {
    /// Clamps every number into the range Validate.ts takes, so one odd count never refuses the
    /// batch it rides in.
    pub fn clamped(mut self) -> Self {
        for n in [
            &mut self.ms,
            &mut self.input_tokens,
            &mut self.output_tokens,
            &mut self.cache_read_tokens,
            &mut self.cache_write_tokens,
        ] {
            *n = (*n).min(U64_MAX_SAFE);
        }
        self.cost_usd =
            self.cost_usd.filter(|c| c.is_finite() && *c >= 0.0).map(|c| c.min(USD_MAX));
        self
    }
}
