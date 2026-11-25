//! One agent's computer as the chat header shows it: where it runs, what is happening to it now,
//! its size and sleep settings, and why AUTO last moved or grew it (RFD 0080, "AUTO-first agentic
//! computers": the status line beside the Where button and the popover's Size, Sleep and Why
//! rows). Leo, 2026-11-23: "we can size it properly for you as your agent does things"; the person
//! never picks a machine, and can always answer "where is it, how big, why" at a glance.
//!
//! The UI never derives this: it reads [`ComputerStatus`] and picks its copy by the enum values.
//! Copy stays in the UI; the reasons here are the RFD's one-sentence reasons as values.
//!
//! Pure: the caller hands the facts it already holds ([`Facts`]: the hybrid start's newest Show
//! (`crate::hybrid_show`), a Move to Cloud or Bring Back Local in flight or stopped
//! (`crate::moves::progress`), the machine's pause and shape, a create refusal's code, the pins and
//! the last placement reason), and [`status`] answers the one status. No clock, no I/O.
//!
//! Which phase wins when several facts hold, first first:
//! 1. a pause the spend controls made (`paused_by: spend_cap`, or the plan's pool spent), on a
//!    chat whose home is the cloud: local chats keep running;
//! 2. a move that stopped: the chat is still where it was (RFD 0072's failure gate);
//! 3. a move in flight, then a hybrid start's own move;
//! 4. a dropped link to the chat's computer, reconnecting;
//! 5. a hybrid start preparing the cloud computer while the model answers here;
//! 6. a create the server refused for slots (`cloud.quota.exceeded`): staying on this Mac;
//! 7. a cloud computer paused while idle: sleeping, memory and processes kept;
//! 8. a cloud computer paused for a reason this build does not know: paused, with no promise
//!    about its memory or processes;
//! 9. else running.
//!
//! The chat's home is the caller's `home`, except that a hybrid start's live Show moves a chat
//! on this Mac to the cloud; a move that stopped keeps the home where it was. The spend and idle
//! pauses read that home, so a live hybrid chat pauses as any cloud chat does.

use serde::{Deserialize, Serialize};

use crate::hybrid::Cloud;

/// Where the chat's one writer is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Home {
    #[default]
    ThisMac,
    Cloud,
    /// Another machine of the person's own (a peer acpmux).
    Peer,
}

/// What is happening to the computer now; `Running` shows no status line.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    #[default]
    Running,
    /// AUTO chose the cloud and its computer is being made; the model already answers here.
    Preparing,
    Moving,
    /// A move stopped; the chat is still where it was.
    MoveFailed,
    Reconnecting,
    /// Paused in the cloud while idle; memory and processes kept.
    Sleeping,
    /// Paused in the cloud for a reason this build does not know (a `paused_by` word newer than
    /// it): no claim that memory and processes were kept.
    Paused,
    /// Paused at the person's overage limit (`paused_by: spend_cap`).
    PausedSpendCap,
    /// Paused: this week's cloud time is used.
    PausedPoolSpent,
    /// The cloud refused a computer because every slot is busy; the chat stays on this Mac.
    StayingLocalSlotsFull,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    #[default]
    ToCloud,
    ToMac,
}

/// Why a move stopped, as the person's reason.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoveFailure {
    NetworkDropped,
    MacSlept,
    /// The cloud refused it (a limit, a slot, a sign-in).
    Refused,
    #[serde(other)]
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Move {
    pub direction: Direction,
    pub cancellable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<MoveFailure>,
}

/// A computer's size, in vCPU and GiB (never an instance type).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Shape {
    pub vcpu: f64,
    pub memory_gib: f64,
}

/// The Size row: AUTO, or a size the person pinned.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Size {
    #[default]
    Auto,
    Pinned {
        vcpu: f64,
        memory_gib: f64,
    },
}

/// The Sleep row: AUTO (sleeps while it waits), or kept awake until a time or until the person
/// says (no `until_ms`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Sleep {
    #[default]
    Auto,
    KeepAwake {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        until_ms: Option<u64>,
    },
}

/// The Why row's reason: RFD 0072's triggers and RFD 0064's events, in the person's terms.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    /// "your Mac was under memory pressure"
    MacMemoryPressure,
    /// "your Mac was busy"
    MacBusy,
    /// "you closed the lid"
    LidClosed,
    /// "`cargo build` needed more memory" (`command` names it)
    GrewForMemory,
    /// The person moved it.
    PersonMoved,
    /// "all your Cloud slots are busy"
    SlotsFull,
    /// "paused at your overage limit"
    SpendCap,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Why {
    pub at_ms: u64,
    pub reason: Reason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

/// The one status per agent session the UI reads.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ComputerStatus {
    pub session_id: String,
    pub home: Home,
    pub phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase_since_ms: Option<u64>,
    #[serde(default, rename = "move", skip_serializing_if = "Option::is_none")]
    pub move_: Option<Move>,
    /// Only when the agent has a cloud computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<Shape>,
    pub size: Size,
    pub sleep: Sleep,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<Why>,
}

/// A Move to Cloud or Bring Back Local the app runs or ran (`crate::moves::progress`'s toast and
/// the Retry ledger's entry).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct MoveFacts {
    pub direction: Direction,
    pub since_ms: Option<u64>,
    pub cancellable: bool,
    /// Set once it stopped without finishing.
    pub failure: Option<MoveFailure>,
}

/// The hybrid start's newest Show (`crate::hybrid_show`). Keys are snake_case as every other
/// key here; `sinceMs`, as `cloud_hybrid_start` spells it, is read too.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct HybridFacts {
    pub cloud: Cloud,
    pub reason: Option<String>,
    #[serde(alias = "sinceMs")]
    pub since_ms: Option<u64>,
}

/// Why the cloud computer is paused, in the server's words (`paused_by`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PausedBy {
    SpendCap,
    /// The plan's weekly cloud time is used.
    PoolSpent,
    /// Idle auto-pause: memory and processes kept.
    Idle,
    /// A word this build does not know. It reads as [`Phase::Paused`], never as an idle sleep:
    /// nothing says its memory and processes were kept.
    #[serde(other)]
    Unknown,
}

/// The agent's cloud computer, when it has one.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct MachineFacts {
    /// The shape autosize gave it.
    #[serde(default)]
    pub shape: Option<Shape>,
    #[serde(default)]
    pub paused_by: Option<PausedBy>,
    #[serde(default)]
    pub paused_since_ms: Option<u64>,
}

/// A create the server refused: its error code and when.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Refusal {
    pub code: String,
    #[serde(default)]
    pub at_ms: Option<u64>,
}

/// What the caller already knows of one session. `session_id` is required and not empty; every
/// other key may be left out.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct Facts {
    #[serde(deserialize_with = "non_empty")]
    pub session_id: String,
    #[serde(default)]
    pub home: Home,
    #[serde(default)]
    pub hybrid: Option<HybridFacts>,
    #[serde(default, rename = "move")]
    pub move_: Option<MoveFacts>,
    /// Since when the link to the chat's computer is down and being reconnected.
    #[serde(default)]
    pub reconnecting_since_ms: Option<u64>,
    #[serde(default)]
    pub machine: Option<MachineFacts>,
    #[serde(default)]
    pub refusal: Option<Refusal>,
    #[serde(default)]
    pub size: Size,
    #[serde(default)]
    pub sleep: Sleep,
    /// The last placement or growth reason.
    #[serde(default)]
    pub why: Option<Why>,
}

fn non_empty<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    let value = String::deserialize(deserializer)?;
    if value.is_empty() {
        return Err(serde::de::Error::invalid_value(
            serde::de::Unexpected::Str(""),
            &"a session id",
        ));
    }
    Ok(value)
}

/// Whether a server error code is the slots-full refusal (`cloud.quota.exceeded`).
pub fn is_slots_full(code: &str) -> bool {
    code.ends_with("quota.exceeded") || code.ends_with("quota_exceeded")
}

/// Whether a server error code is the spend cap's (`cloud.spend_cap.reached`).
pub fn is_spend_cap(code: &str) -> bool {
    code.ends_with("spend_cap.reached") || code.ends_with("spend_cap_reached")
}

/// A hybrid start's failure reason as the move's failure. The driver's reason is free text (an
/// error message, or a server code), with no typed kind, so only a known code reads as a kind: a
/// refusal code (`cloud.quota.exceeded`, `cloud.spend_cap.reached`) or a [`MoveFailure`] word
/// itself (`network_dropped`, `mac_slept`, `refused`). Anything else, a stray "network" or
/// "sleep" in a message included, is [`MoveFailure::Other`].
fn failure_of(reason: Option<&str>) -> MoveFailure {
    let reason = reason.unwrap_or_default().trim();
    if is_slots_full(reason) || is_spend_cap(reason) {
        return MoveFailure::Refused;
    }
    match reason {
        "network_dropped" => MoveFailure::NetworkDropped,
        "mac_slept" => MoveFailure::MacSlept,
        "refused" => MoveFailure::Refused,
        _ => MoveFailure::Other,
    }
}

/// The phase, its start, the move shown and a reason the phase itself gives.
type Derived = (Phase, Option<u64>, Option<Move>, Option<Why>);

fn why_at(reason: Reason, at_ms: Option<u64>) -> Option<Why> {
    at_ms.map(|at_ms| Why { at_ms, reason, command: None })
}

fn derive(facts: &Facts, home: Home) -> Derived {
    let machine = facts.machine.as_ref();
    let paused = machine.and_then(|machine| Some((machine.paused_by?, machine.paused_since_ms)));
    let in_cloud = home == Home::Cloud;
    match paused {
        Some((PausedBy::SpendCap, since)) if in_cloud => {
            return (Phase::PausedSpendCap, since, None, why_at(Reason::SpendCap, since));
        }
        Some((PausedBy::PoolSpent, since)) if in_cloud => {
            return (Phase::PausedPoolSpent, since, None, None);
        }
        _ => {}
    }
    if let Some(moving) = &facts.move_ {
        let shown = Move {
            direction: moving.direction,
            cancellable: moving.cancellable && moving.failure.is_none(),
            failure: moving.failure,
        };
        let phase = if moving.failure.is_some() { Phase::MoveFailed } else { Phase::Moving };
        return (phase, moving.since_ms, Some(shown), None);
    }
    let hybrid = facts.hybrid.as_ref();
    if let Some(hybrid) = hybrid.filter(|hybrid| hybrid.cloud == Cloud::Moving) {
        let shown = Move { direction: Direction::ToCloud, cancellable: false, failure: None };
        return (Phase::Moving, hybrid.since_ms, Some(shown), None);
    }
    if let Some(since) = facts.reconnecting_since_ms {
        return (Phase::Reconnecting, Some(since), None, None);
    }
    if let Some(hybrid) = hybrid {
        match hybrid.cloud {
            Cloud::Booting | Cloud::Ready => {
                return (Phase::Preparing, hybrid.since_ms, None, None);
            }
            Cloud::Failed if hybrid.reason.as_deref().is_some_and(is_slots_full) => {
                let why = why_at(Reason::SlotsFull, hybrid.since_ms);
                return (Phase::StayingLocalSlotsFull, hybrid.since_ms, None, why);
            }
            Cloud::Failed => {
                let failure = Some(failure_of(hybrid.reason.as_deref()));
                let shown = Move { direction: Direction::ToCloud, cancellable: false, failure };
                return (Phase::MoveFailed, hybrid.since_ms, Some(shown), None);
            }
            Cloud::None | Cloud::Moving | Cloud::Live => {}
        }
    }
    let slots_full = facts.refusal.as_ref().filter(|refusal| is_slots_full(&refusal.code));
    if let Some(refusal) = slots_full.filter(|_| !in_cloud) {
        let why = why_at(Reason::SlotsFull, refusal.at_ms);
        return (Phase::StayingLocalSlotsFull, refusal.at_ms, None, why);
    }
    match paused {
        Some((PausedBy::Unknown, since)) if in_cloud => (Phase::Paused, since, None, None),
        Some((_, since)) if in_cloud => (Phase::Sleeping, since, None, None),
        _ => (Phase::Running, None, None, None),
    }
}

/// The chat's home: a hybrid start that committed its move left a chat on this Mac in the cloud;
/// a move that stopped keeps it where it was, whatever the Show says.
fn home_of(facts: &Facts) -> Home {
    let move_failed = facts.move_.as_ref().is_some_and(|moving| moving.failure.is_some());
    match facts.hybrid.as_ref().map(|hybrid| hybrid.cloud) {
        Some(Cloud::Live) if facts.home == Home::ThisMac && !move_failed => Home::Cloud,
        _ => facts.home,
    }
}

/// The one status of `facts`' session.
pub fn status(facts: &Facts) -> ComputerStatus {
    let home = home_of(facts);
    let (phase, phase_since_ms, move_, phase_why) = derive(facts, home);
    // The phase's own reason wins over an older placement reason; a newer one stays.
    let why = match (phase_why, facts.why.clone()) {
        (Some(own), Some(last)) if last.at_ms > own.at_ms => Some(last),
        (Some(own), _) => Some(own),
        (None, last) => last,
    };
    let shape = facts.machine.as_ref().and_then(|machine| machine.shape);
    ComputerStatus {
        session_id: facts.session_id.clone(),
        home,
        phase,
        phase_since_ms,
        move_,
        shape,
        size: facts.size,
        sleep: facts.sleep,
        why,
    }
}

#[cfg(test)]
#[path = "computer_status/tests.rs"]
mod tests;
