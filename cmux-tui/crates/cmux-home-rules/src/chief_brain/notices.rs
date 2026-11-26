//! `ChiefReplyWatchdog` (the "Chief is not running" notice under a waiting message) and
//! `ChiefSettleNotice` (the "still starting" / "organizing" line).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::time::parse_rfc3339;

/// `ChiefReplyWatchdog.limit`, in seconds.
pub const REPLY_LIMIT_SECS: f64 = 120.0;
/// `ChiefReplyWatchdog.agentSenderMark`.
pub const AGENT_SENDER_MARK: &str = "agent~";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchdogParticipant {
    pub id: String,
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastMessage {
    pub author: String,
    #[serde(default, rename = "clientMsgID", alias = "clientMsgId")]
    pub client_msg_id: String,
    pub created_at: String,
    #[serde(default)]
    pub retracted_at: Option<Value>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WatchdogSummary {
    pub participants: Vec<WatchdogParticipant>,
    pub last_message: Option<LastMessage>,
}

/// `waitingSince(_:)`, in seconds since 1970.
pub fn waiting_since(summary: &WatchdogSummary) -> Option<f64> {
    let last = summary.last_message.as_ref()?;
    if last.retracted_at.as_ref().is_some_and(|v| !v.is_null()) {
        return None;
    }
    let kind =
        summary.participants.iter().find(|p| p.id == last.author).and_then(|p| p.kind.as_deref());
    if kind == Some("agent")
        || last.author.starts_with("agent_")
        || last.client_msg_id.starts_with(AGENT_SENDER_MARK)
    {
        return None;
    }
    parse_rfc3339(&last.created_at)
}

/// `nextCheck(_:now:)`.
pub fn next_check(since: f64, now: f64) -> f64 {
    let appear = since + REPLY_LIMIT_SECS;
    if now < appear {
        return appear;
    }
    let minutes = ((now - since) / 60.0).floor() + 1.0;
    since + minutes * 60.0
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchdogRequest {
    #[serde(default)]
    pub summary: WatchdogSummary,
    pub now_secs: f64,
    /// The keeper's `isRunning`; leave it out to learn whether it is needed (`pastLimit`).
    pub brain_running: Option<bool>,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchdogReply {
    pub waiting_since_secs: Option<f64>,
    /// The message has waited the limit: the notice shows unless the brain runs.
    pub past_limit: bool,
    /// `HomeStrings.chiefNotRunning`, by name.
    pub notice: Option<&'static str>,
    pub next_check_secs: Option<f64>,
}

/// `notice(_:now:brainRunning:)` and `nextCheck(_:now:)` at once.
pub fn watchdog(r: &WatchdogRequest) -> WatchdogReply {
    let since = waiting_since(&r.summary);
    let past_limit = since.is_some_and(|s| r.now_secs - s >= REPLY_LIMIT_SECS);
    WatchdogReply {
        waiting_since_secs: since,
        past_limit,
        notice: (past_limit && r.brain_running == Some(false)).then_some("chiefNotRunning"),
        next_check_secs: since.map(|s| next_check(s, r.now_secs)),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SettleNotice {
    /// `HomeStrings.chiefStillStarting(seconds:)`.
    StillStarting { seconds: i64 },
    /// `HomeStrings.chiefOrganizing(built:total:)`.
    Organizing { built: i64, total: i64 },
    /// `HomeStrings.chiefMemoryPaused`.
    MemoryPaused,
}

/// A JSON number `as? Int` takes: an integer, or a float with no fraction.
fn as_int(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    if let Some(i) = v.as_i64() {
        return Some(i);
    }
    let f = v.as_f64()?;
    (f.fract() == 0.0 && f.abs() < 9.0e18).then_some(f as i64)
}

/// `ChiefSettleNotice.text(json:)`.
pub fn settle_text(json: &str) -> Option<SettleNotice> {
    let value: Value = serde_json::from_str(json).ok()?;
    let object = value.as_object()?;
    if let Some(seconds) = as_int(object.get("startingSecs"))
        && seconds >= 0
    {
        return Some(SettleNotice::StillStarting { seconds });
    }
    let built = as_int(object.get("built"))?;
    let total = as_int(object.get("total"))?;
    (built >= 0 && built < total).then_some(SettleNotice::Organizing { built, total })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettleRequest {
    /// The status file's text (None: no file).
    pub json: Option<String>,
    /// `compactor.json` sits beside it.
    #[serde(default)]
    pub compactor_paused: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettleReply {
    pub notice: Option<SettleNotice>,
}

/// `ChiefSettleWatch.read`'s choice.
pub fn settle(r: &SettleRequest) -> SettleReply {
    let notice = r
        .json
        .as_deref()
        .and_then(settle_text)
        .or_else(|| r.compactor_paused.then_some(SettleNotice::MemoryPaused));
    SettleReply { notice }
}
