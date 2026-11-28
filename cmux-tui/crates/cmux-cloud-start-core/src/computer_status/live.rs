//! The live facts the app already holds for a chat's header, folded into [`super::Facts`] (RFD
//! 0080: the status line reads the session's real state, not a test fixture).
//!
//! The app sends what it builds `place` from, as it is: where the chat runs (`at`), the move's
//! view (`moves::place::view`, `place.move`), the hybrid start's newest Show (`place.start`,
//! `hybrid_show::Start`) and, when it has one, the chat's cloud machine as the server lists it
//! (`CloudMachine`: `status`, `pause_reason`, `paused_by`, `spend_cap_pause_at`, `size`,
//! `error`). [`facts`] maps them; [`super::status`] then answers the one status. Pure.
//!
//! A move's stamps are on the app's monotonic clock (`CloudPlaceFlows.nowMs`, uptime), the page's
//! clock is Unix ms: with the app's `clock` (both readings, taken together) [`facts`] puts them on
//! Unix ms, in whole seconds, so a header re-read that only moved the clocks writes the same bytes.

use serde::Deserialize;

use super::{
    Direction, Facts, Home, HybridFacts, MachineFacts, MoveFacts, PausedBy, Reason, Refusal, Shape,
    Size, Sleep, Why, failure_of, non_empty,
};
use crate::moves::place::{self, At, AutoReason, Trigger};

/// `place.move` as `moves::place::view` writes it (camelCase); only what the status reads.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveView {
    pub direction: place::Direction,
    pub trigger: Trigger,
    /// `moving`, `live`, `failed`, `cancelled`.
    pub state: String,
    pub started_ms: u64,
    #[serde(default)]
    pub elapsed_ms: u64,
    #[serde(default)]
    pub can_cancel: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

/// `CloudMachineSize`: CPUs and MB.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct MachineSize {
    pub cpu: Option<f64>,
    pub memory_mb: Option<f64>,
}

/// `CloudMachine.error`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct MachineError {
    pub code: String,
    #[serde(default)]
    pub at: Option<u64>,
}

/// The chat's cloud machine, as the server lists it (snake_case, times in Unix ms).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Machine {
    pub status: Option<String>,
    pub pause_reason: Option<String>,
    pub paused_by: Option<String>,
    pub spend_cap_pause_at: Option<u64>,
    pub size: Option<MachineSize>,
    pub error: Option<MachineError>,
}

/// The app's two clocks, read together when it asks: its monotonic one (what a move is stamped
/// with) and Unix ms (what the page ticks with).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clock {
    pub mono_ms: u64,
    pub wall_ms: u64,
}

impl Clock {
    /// `mono` (a move's stamp) on Unix ms, down to the whole second.
    pub fn wall(&self, mono: u64) -> u64 {
        let wall = self.wall_ms.saturating_sub(self.mono_ms.saturating_sub(mono));
        wall - wall % 1000
    }
}

/// What the app holds for one chat's header.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Live {
    #[serde(deserialize_with = "non_empty")]
    pub session: String,
    #[serde(default)]
    pub at: At,
    #[serde(default, rename = "move")]
    pub move_: Option<MoveView>,
    #[serde(default)]
    pub start: Option<HybridFacts>,
    #[serde(default)]
    pub machine: Option<Machine>,
    #[serde(default)]
    pub reconnecting_since_ms: Option<u64>,
    #[serde(default)]
    pub size: Size,
    #[serde(default)]
    pub sleep: Sleep,
    /// None: the move's stamps pass through as they are.
    #[serde(default)]
    pub clock: Option<Clock>,
}

/// Why Auto moved it, in the person's terms; None for a reason the Why row does not say (Auto
/// bringing it back, the person being away).
fn auto_reason(reason: AutoReason) -> Option<Reason> {
    match reason {
        AutoReason::Memory => Some(Reason::MacMemoryPressure),
        AutoReason::Sleep => Some(Reason::LidClosed),
        AutoReason::LowBattery | AutoReason::Disk | AutoReason::LongTurn => Some(Reason::MacBusy),
        AutoReason::Away | AutoReason::Back => None,
    }
}

/// A move's stamp on the page's clock when the app sent its clocks.
fn stamp(clock: Option<Clock>, mono: u64) -> u64 {
    clock.map_or(mono, |clock| clock.wall(mono))
}

fn why_of(view: &MoveView, clock: Option<Clock>) -> Option<Why> {
    let reason = match view.trigger {
        Trigger::Person | Trigger::Evacuate => Some(Reason::PersonMoved),
        Trigger::Auto(reason) => auto_reason(reason),
    }?;
    Some(Why { at_ms: stamp(clock, view.started_ms), reason, command: None })
}

/// A move still running, or one that stopped; None once it is live or cancelled (the chat is
/// settled where it is).
fn move_of(view: &MoveView, clock: Option<Clock>) -> Option<MoveFacts> {
    let direction = match view.direction {
        place::Direction::ToCloud => Direction::ToCloud,
        place::Direction::ToLocal => Direction::ToMac,
    };
    match view.state.as_str() {
        "moving" => Some(MoveFacts {
            direction,
            since_ms: Some(stamp(clock, view.started_ms)),
            cancellable: view.can_cancel,
            failure: None,
        }),
        "failed" => Some(MoveFacts {
            direction,
            since_ms: Some(stamp(clock, view.started_ms.saturating_add(view.elapsed_ms))),
            cancellable: false,
            failure: Some(failure_of(view.reason.as_deref())),
        }),
        _ => None,
    }
}

fn machine_of(machine: &Machine) -> MachineFacts {
    let shape = machine
        .size
        .and_then(|size| Some(Shape { vcpu: size.cpu?, memory_gib: size.memory_mb? / 1024.0 }));
    let paused = matches!(machine.status.as_deref(), Some("paused" | "pausing"));
    let paused_by = if machine.paused_by.as_deref() == Some("spend_cap") {
        Some(PausedBy::SpendCap)
    } else if paused && machine.pause_reason.as_deref() == Some("idle") {
        Some(PausedBy::Idle)
    } else if paused {
        Some(PausedBy::Unknown)
    } else {
        None
    };
    let paused_since_ms = match paused_by {
        Some(PausedBy::SpendCap) => machine.spend_cap_pause_at,
        _ => None,
    };
    MachineFacts { shape, paused_by, paused_since_ms }
}

/// The facts [`super::status`] reads, from what the app holds.
pub fn facts(live: &Live) -> Facts {
    let home = match live.at {
        At::Local => Home::ThisMac,
        At::Cloud => Home::Cloud,
    };
    let refusal = live
        .machine
        .as_ref()
        .and_then(|machine| machine.error.as_ref())
        .map(|error| Refusal { code: error.code.clone(), at_ms: error.at });
    Facts {
        session_id: live.session.clone(),
        home,
        hybrid: live.start.clone(),
        move_: live.move_.as_ref().and_then(|view| move_of(view, live.clock)),
        reconnecting_since_ms: live.reconnecting_since_ms,
        machine: live.machine.as_ref().map(machine_of),
        refusal,
        size: live.size,
        sleep: live.sleep,
        why: live.move_.as_ref().and_then(|view| why_of(view, live.clock)),
    }
}
