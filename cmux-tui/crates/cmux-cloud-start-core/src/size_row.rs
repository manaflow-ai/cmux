//! The read-only Size row and "More room" (RFD 0144 piece 9, "Manual sizing: not exposed"): with
//! this on, the popover's Size row only says what the computer is now ("now 2 vCPU · 4 GB, grows as
//! it works"), with no Auto and no Pin choice, and offers one request, **More room**, that raises
//! the session's ceiling one plan step for the rest of the task. It names no shape. Leo,
//! 2026-11-23: "here's ... some bigger machine. if you want to request that. and it auto pause
//! resume".
//!
//! Off by default: [`SETTING`] (`cloud.moreRoom`) is false until the person or a build turns it
//! on, and while it is off [`view`] answers nothing, so the existing Auto / Pin row stays exactly as
//! it is.
//!
//! Display only. Raising a ceiling lets AutoSize grow the computer further, and a bigger computer
//! bills more per awake hour, so nothing here asks the server for anything: [`view`] says whether
//! the button is offered and what step it would raise to ([`View::raises_to`], for the caller, not
//! for the copy), and the caller decides whether to send it. The spend cap still guards the bill
//! (RFD 0080), and it pauses, never stops.
//!
//! Pure: the caller hands the facts it already holds ([`Facts`]) and [`view`] answers the row.
//!
//! Rules, first first:
//! 1. setting off: no view (the old row is drawn);
//! 2. a size pinned from the CLI or API reads as that pin, and More room is not offered: a pinned
//!    session runs on its one computer, so a ceiling means nothing to it;
//! 3. no cloud computer yet (on this Mac, or not made): no size and no More room;
//! 4. paused by the spend cap or the plan's pool: the size reads, More room is not offered (more
//!    room would not wake it);
//! 5. already asked for this task: "More room: on";
//! 6. the plan's ceiling is unknown or already the top step ([`PLAN_STEPS`]): not offered;
//! 7. else offered, raising to the next step.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::computer_status::{Home, Phase, Shape, Size};

/// The setting that turns the read-only Size row and More room on (default off).
pub const SETTING: &str = "cloud.moreRoom";

/// The plans' ceilings, smallest first (RFD 0133: Plus 4 / 16, Pro 8 / 32, Max 32 / 64 today).
/// More room raises a session one step up this list.
pub const PLAN_STEPS: [Shape; 3] = [
    Shape { vcpu: 4.0, memory_gib: 16.0 },
    Shape { vcpu: 8.0, memory_gib: 32.0 },
    Shape { vcpu: 32.0, memory_gib: 64.0 },
];

/// Whether `settings` (the person's settings file, flat `"cloud.moreRoom"` or nested
/// `{"cloud": {"moreRoom": ...}}`) turns the row on. Only a JSON `true` does; the flat key wins.
pub fn enabled(settings: &Value) -> bool {
    settings
        .get(SETTING)
        .and_then(Value::as_bool)
        .or_else(|| settings.pointer("/cloud/moreRoom").and_then(Value::as_bool))
        .unwrap_or(false)
}

/// The step above `ceiling`: the first plan step larger than it on either axis. None at the top.
pub fn step_above(ceiling: Shape) -> Option<Shape> {
    PLAN_STEPS
        .into_iter()
        .find(|step| step.vcpu > ceiling.vcpu || step.memory_gib > ceiling.memory_gib)
}

/// What the caller knows of one session. Every key may be left out.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Facts {
    /// [`SETTING`], read by the caller (or [`enabled`]).
    pub enabled: bool,
    pub home: Home,
    pub phase: Phase,
    /// The cloud computer's shape now (`ComputerStatus.shape`).
    pub shape: Option<Shape>,
    pub size: Size,
    /// The session's ceiling now: the plan's, or a step above once More room is on.
    pub plan_ceiling: Option<Shape>,
    /// More room was asked for this task.
    pub more_room: bool,
}

/// Whether the row offers More room.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoreRoom {
    /// Not offered (no cloud computer, pinned, paused, at the top, or the ceiling unknown).
    #[default]
    Hidden,
    /// The button is drawn.
    Offered,
    /// Asked for this task: "More room: on".
    On,
}

/// The read-only Size row the popover and Computer details draw.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct View {
    /// The cloud computer's size now; absent without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub now: Option<Shape>,
    /// A pin made from the CLI or API, shown as is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<Shape>,
    pub more_room: MoreRoom,
    /// The ceiling More room would raise the session to, for the caller. The copy never shows it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raises_to: Option<Shape>,
}

/// The row for `facts`, or None while [`SETTING`] is off (the old row is drawn then).
pub fn view(facts: &Facts) -> Option<View> {
    if !facts.enabled {
        return None;
    }
    if let Size::Pinned { vcpu, memory_gib } = facts.size {
        let pinned = Shape { vcpu, memory_gib };
        return Some(View {
            now: facts.shape,
            pinned: Some(pinned),
            more_room: MoreRoom::Hidden,
            raises_to: None,
        });
    }
    let now = facts.shape.filter(|_| facts.home == Home::Cloud);
    let hidden = View { now, pinned: None, more_room: MoreRoom::Hidden, raises_to: None };
    if now.is_none() || matches!(facts.phase, Phase::PausedSpendCap | Phase::PausedPoolSpent) {
        return Some(hidden);
    }
    if facts.more_room {
        return Some(View { more_room: MoreRoom::On, ..hidden });
    }
    match facts.plan_ceiling.and_then(step_above) {
        Some(step) => Some(View { more_room: MoreRoom::Offered, raises_to: Some(step), ..hidden }),
        None => Some(hidden),
    }
}

#[cfg(test)]
#[path = "size_row/tests.rs"]
mod tests;
