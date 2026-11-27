//! The host budget's verdict as one more Auto signal (RFD 0072 "Into Auto"): the daemon's
//! `host_pressure` (`_acpmux/status`, cmux-tui `cmux-host-budget` `Verdict` plus acpmux's
//! `power`) is the one source of this computer's memory pressure and battery. The app reads only
//! what the daemon cannot: a sleep it is told of, free disk and the person's idle time.
//!
//! The verdict also says whether this computer is over its CPU and RAM budget. That is the
//! RFD's shadow stage: [`judge`] says what Auto would do for it (move a busy chat out, reason
//! [`AutoReason::Busy`]) and the app appends that to `auto-shadow.jsonl`; nothing moves for it.
//! The rule that acts is [`auto`], unchanged.
//!
//! A daemon with Auto on reserve (cmux-host-budget `reserve.rs`, acpmux `reserve_shadow.rs`)
//! also publishes `reserve`: the chats the reserve rule would hold moved out, and why. That is
//! the Busy signal when present: only a chat it names would move. An older daemon has no
//! `reserve`, and the budget's `ok`/`over` stand in, as before.

use super::{At, AutoDecision, AutoReason, ChatState, Mode, Pressure, Signals, auto, rule};
use serde::{Deserialize, Serialize};

/// The daemon's power reading inside the verdict (acpmux `host_power.rs` `power_json`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Power {
    pub battery_percent: Option<u8>,
    pub on_ac: Option<bool>,
    pub lid_closed: Option<bool>,
}

/// The part of `host_pressure` Auto reads. Every key is optional: an older daemon's verdict, or
/// none, reads as "not known", which moves nothing.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Verdict {
    /// Within budget; `null` before the daemon's first sample.
    pub ok: Option<bool>,
    /// Why it is over, one phrase each, in the daemon's words.
    pub over: Vec<String>,
    /// `normal`, `warn`, `critical` or `unknown`.
    pub pressure: Option<String>,
    pub power: Option<Power>,
    /// Auto on reserve's shadow verdict (acpmux `host_pressure.reserve`); absent on an older daemon.
    pub reserve: Option<Reserve>,
}

/// The part of `host_pressure.reserve` Auto reads: the chats it would hold moved out.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Reserve {
    pub out: Vec<ReserveOut>,
}

/// One chat the reserve rule would hold out, and its reason (`cpu`, `memory`, `interactive`,
/// `memoryPressure` or `thermal`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReserveOut {
    pub session: String,
    pub reason: String,
}

impl Verdict {
    /// Why this verdict alone would move `session` out: the reserve rule's reason when the
    /// daemon has one (`Some(Some(reason))` for a chat it names, `None` for one it does not),
    /// else over budget (`Some(None)`).
    fn busy(&self, session: &str) -> Option<Option<String>> {
        match &self.reserve {
            Some(reserve) => {
                reserve.out.iter().find(|o| o.session == session).map(|o| Some(o.reason.clone()))
            }
            None => (self.ok == Some(false)).then_some(None),
        }
    }

    fn memory(&self) -> Pressure {
        match self.pressure.as_deref() {
            Some("critical") => Pressure::Critical,
            Some("warn") => Pressure::Warn,
            _ => Pressure::Normal,
        }
    }
}

/// What the app reads itself, for what no verdict holds.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Own {
    /// A sleep the app was told of (`NSWorkspace.willSleepNotification`).
    pub sleeping: bool,
    pub disk_free_bytes: Option<u64>,
    /// Time since the person's last input on this computer.
    pub idle_ms: Option<u64>,
}

/// The rule's [`Signals`]: memory and battery from the verdict, a closed lid as a sleep.
pub fn signals(own: &Own, verdict: Option<&Verdict>) -> Signals {
    let power = verdict.and_then(|v| v.power).unwrap_or_default();
    Signals {
        sleeping: own.sleeping || power.lid_closed == Some(true),
        on_battery: power.on_ac == Some(false),
        battery_percent: power.battery_percent,
        memory: verdict.map(Verdict::memory).unwrap_or_default(),
        disk_free_bytes: own.disk_free_bytes,
        idle_ms: own.idle_ms,
    }
}

/// What Auto would do for the verdict alone, beside what it does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shadow {
    pub would: AutoDecision,
    /// The verdict's reasons.
    pub over: Vec<String>,
    /// The reserve rule's reason, when it named this chat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reserve: Option<String>,
}

/// The decision and, when the verdict alone would differ, its shadow.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Judgment {
    #[serde(flatten)]
    pub decision: AutoDecision,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadow: Option<Shadow>,
}

/// [`auto`] on the verdict's signals, and the shadow: a local chat with work, the person here
/// (input within [`rule::AWAY_MS`]: away is no reason to move, RFD 0072 rule 1), the reserve rule
/// naming this chat (`session`; an older daemon: the computer over budget) and the rule otherwise
/// keeping it here would move out for [`AutoReason::Busy`].
pub fn judge(
    mode: Mode,
    chat: &ChatState,
    own: &Own,
    session: &str,
    verdict: Option<&Verdict>,
) -> Judgment {
    let decision = auto(mode, chat, &signals(own, verdict));
    let busy = verdict.and_then(|v| Some((v, v.busy(session)?)));
    let shadow = busy
        .filter(|_| {
            mode == Mode::Auto
                && decision == AutoDecision::Stay
                && !chat.moving
                && chat.at == At::Local
                && (chat.turn_running || chat.queued > 0)
                && own.idle_ms.is_some_and(|idle| idle < rule::AWAY_MS)
        })
        .map(|(v, reserve)| Shadow {
            would: AutoDecision::ToCloud { reason: AutoReason::Busy },
            over: v.over.clone(),
            reserve,
        });
    Judgment { decision, shadow }
}

/// One `auto-shadow.jsonl` line: when, which chat, what Auto did and what the verdict would have it do.
pub fn shadow_line(now_ms: u64, session: &str, judgment: &Judgment) -> Option<String> {
    let shadow = judgment.shadow.as_ref()?;
    let mut line = serde_json::json!({
        "v": 1,
        "atMs": now_ms,
        "session": session,
        "did": judgment.decision,
        "would": shadow.would,
        "over": shadow.over,
    });
    if let (Some(obj), Some(reserve)) = (line.as_object_mut(), &shadow.reserve) {
        obj.insert("reserve".into(), serde_json::json!(reserve));
    }
    serde_json::to_string(&line).ok()
}

#[cfg(test)]
mod tests;
