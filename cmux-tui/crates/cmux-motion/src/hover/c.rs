//! Plain C-layout forms of the hover machines, for the app's C ABI
//! (cmux-app-ffi `hover.rs`, `cmux_motion_ffi.h`). The app keeps each machine
//! as one of these structs (a value, no handle, no allocation) and passes it
//! by pointer per pointer move; a call rebuilds the Rust machine, applies a
//! batch of events and writes the struct and the effects back. Target ids are
//! the host's own 64-bit handles. Every conversion is total: an unknown kind
//! or out-of-range number from the host reads as a safe value (idle, no
//! effect), never a panic.

use super::geometry::{
    HoverCardEscapeGeometry, HoverPoint, HoverRect, HoverRowAlignment, HoverZone,
};
use super::intent::{HoverIntent, HoverIntentEffect, HoverIntentPhase, IntentEffects};
use super::machine::{
    Effects, HoverCardEffect, HoverCardEvent, HoverCardLeave, HoverCardMachine,
    HoverCardMachineParts, HoverCardPhase, HoverSuppression, HoverSuppressions, HoverTarget,
    MAX_EFFECTS_PER_EVENT,
};
use super::timing::{
    HOVER_CARD_PIN_LIFETIME, HOVER_CARD_RESHOW_WINDOW, HOVER_CARD_SHOW_DELAY,
    HOVER_CARD_STILL_POINTER_DELAY, HOVER_CARD_SWEEP_INTERVAL, HoverIntentTiming,
};

/// `HoverTarget<u64>`. `leave`: 0 lingers, 1 hides (after `reshow` ns).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverTarget {
    pub id: u64,
    pub window: i64,
    pub delay: i64,
    pub reshow: i64,
    pub leave: u8,
}

pub const LEAVE_LINGERS: u8 = 0;
pub const LEAVE_HIDES: u8 = 1;

impl From<CmuxHoverTarget> for HoverTarget<u64> {
    fn from(t: CmuxHoverTarget) -> Self {
        let leave = if t.leave == LEAVE_HIDES {
            HoverCardLeave::Hides { reshow: t.reshow }
        } else {
            HoverCardLeave::Lingers
        };
        Self { id: t.id, window: t.window, delay: t.delay, leave }
    }
}

impl From<&HoverTarget<u64>> for CmuxHoverTarget {
    fn from(t: &HoverTarget<u64>) -> Self {
        let (leave, reshow) = match t.leave {
            HoverCardLeave::Lingers => (LEAVE_LINGERS, 0),
            HoverCardLeave::Hides { reshow } => (LEAVE_HIDES, reshow),
        };
        Self { id: t.id, window: t.window, delay: t.delay, reshow, leave }
    }
}

pub const PHASE_IDLE: u8 = 0;
pub const PHASE_PENDING: u8 = 1;
pub const PHASE_SHOWN: u8 = 2;
pub const PHASE_PINNED: u8 = 3;
pub const PHASE_LEAVING: u8 = 4;
pub const PHASE_GRACE: u8 = 5;

/// `HoverCardMachine<u64>`, every field. `phase` (`PHASE_*`) with its
/// `target` and `token` (each meaningful only for the phases that carry
/// it); `suppressions` bit 0 drag, 1 scroll, 2 sidebarHide. The windows are
/// nanoseconds; the host may set them between calls (tunables).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverCardMachine {
    pub target: CmuxHoverTarget,
    pub last_hit: CmuxHoverTarget,
    pub token: u64,
    pub next_token: u64,
    pub reshow_window: i64,
    pub pin_lifetime: i64,
    pub leave_window: i64,
    pub aim_window: i64,
    pub still_pointer_delay: i64,
    pub phase: u8,
    pub suppressions: u8,
    pub has_last_hit: bool,
    pub quiet: bool,
    pub pointer_on_card: bool,
    pub owned_card_shown: bool,
    pub was_on_card: bool,
}

impl CmuxHoverCardMachine {
    /// A new machine with the default windows.
    #[must_use]
    pub fn new() -> Self {
        Self::from(&HoverCardMachine::<u64>::new())
    }
}

impl From<CmuxHoverCardMachine> for HoverCardMachine<u64> {
    fn from(c: CmuxHoverCardMachine) -> Self {
        let target = HoverTarget::from(c.target);
        let token = c.token;
        let phase = match c.phase {
            PHASE_PENDING => HoverCardPhase::Pending { target, token },
            PHASE_SHOWN => HoverCardPhase::Shown { target },
            PHASE_PINNED => HoverCardPhase::Pinned { target, token },
            PHASE_LEAVING => HoverCardPhase::Leaving { target, token },
            PHASE_GRACE => HoverCardPhase::Grace { token },
            _ => HoverCardPhase::Idle,
        };
        Self::from_parts(HoverCardMachineParts {
            phase,
            suppressions: HoverSuppressions::from_bits(c.suppressions),
            last_hit: c.has_last_hit.then(|| HoverTarget::from(c.last_hit)),
            quiet: c.quiet,
            // Token 0 is never armed; a zeroed struct still hands out 1 first.
            next_token: c.next_token.max(1),
            pointer_on_card: c.pointer_on_card,
            owned_card_shown: c.owned_card_shown,
            was_on_card: c.was_on_card,
            reshow_window: c.reshow_window,
            pin_lifetime: c.pin_lifetime,
            leave_window: c.leave_window,
            aim_window: c.aim_window,
            still_pointer_delay: c.still_pointer_delay,
        })
    }
}

impl From<&HoverCardMachine<u64>> for CmuxHoverCardMachine {
    fn from(m: &HoverCardMachine<u64>) -> Self {
        let (phase, target, token) = match m.phase() {
            HoverCardPhase::Idle => (PHASE_IDLE, CmuxHoverTarget::default(), 0),
            HoverCardPhase::Pending { target, token } => (PHASE_PENDING, target.into(), *token),
            HoverCardPhase::Shown { target } => (PHASE_SHOWN, target.into(), 0),
            HoverCardPhase::Pinned { target, token } => (PHASE_PINNED, target.into(), *token),
            HoverCardPhase::Leaving { target, token } => (PHASE_LEAVING, target.into(), *token),
            HoverCardPhase::Grace { token } => (PHASE_GRACE, CmuxHoverTarget::default(), *token),
        };
        Self {
            target,
            last_hit: m.last_hit().map(CmuxHoverTarget::from).unwrap_or_default(),
            token,
            next_token: m.next_token(),
            reshow_window: m.reshow_window,
            pin_lifetime: m.pin_lifetime,
            leave_window: m.leave_window,
            aim_window: m.aim_window,
            still_pointer_delay: m.still_pointer_delay,
            phase,
            suppressions: m.suppressions().bits(),
            has_last_hit: m.last_hit().is_some(),
            quiet: m.quiet(),
            pointer_on_card: m.pointer_on_card(),
            owned_card_shown: m.owned_card_shown(),
            was_on_card: m.was_on_card(),
        }
    }
}

pub const EVENT_HIT: u8 = 0;
pub const EVENT_POINTER_ON_CARD: u8 = 1;
pub const EVENT_DEADLINE: u8 = 2;
pub const EVENT_DISMISS: u8 = 3;
pub const EVENT_SUPPRESS: u8 = 4;
pub const EVENT_UNSUPPRESS: u8 = 5;
pub const EVENT_TARGET_REMOVED: u8 = 6;
pub const EVENT_PIN: u8 = 7;
pub const EVENT_OWNED: u8 = 8;

/// One `HoverCardEvent<u64>`. `kind` (`EVENT_*`) picks the fields it reads:
/// hit: `flag` (a target is under the pointer), `target`, `moved`, `aiming`,
/// `bridging`; pointerOnCard and owned: `flag`; deadline: `token`;
/// suppress and unsuppress: `suppression` (0 drag, 1 scroll, 2 sidebarHide);
/// targetRemoved: `target.id`; pin: `target`; dismiss: nothing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverCardEvent {
    pub target: CmuxHoverTarget,
    pub token: u64,
    pub kind: u8,
    pub suppression: u8,
    pub flag: bool,
    pub moved: bool,
    pub aiming: bool,
    pub bridging: bool,
}

impl CmuxHoverCardEvent {
    /// The event, or `None` for an unknown kind or suppression.
    #[must_use]
    pub fn event(&self) -> Option<HoverCardEvent<u64>> {
        let suppression = || HoverSuppression::ALL.get(usize::from(self.suppression)).copied();
        Some(match self.kind {
            EVENT_HIT => HoverCardEvent::Hit {
                target: self.flag.then(|| HoverTarget::from(self.target)),
                moved: self.moved,
                aiming: self.aiming,
                bridging: self.bridging,
            },
            EVENT_POINTER_ON_CARD => HoverCardEvent::PointerOnCard(self.flag),
            EVENT_DEADLINE => HoverCardEvent::Deadline(self.token),
            EVENT_DISMISS => HoverCardEvent::Dismiss,
            EVENT_SUPPRESS => HoverCardEvent::Suppress(suppression()?),
            EVENT_UNSUPPRESS => HoverCardEvent::Unsuppress(suppression()?),
            EVENT_TARGET_REMOVED => HoverCardEvent::TargetRemoved(self.target.id),
            EVENT_PIN => HoverCardEvent::Pin(HoverTarget::from(self.target)),
            EVENT_OWNED => HoverCardEvent::Owned(self.flag),
            _ => return None,
        })
    }
}

pub const EFFECT_SCHEDULE: u8 = 0;
pub const EFFECT_CANCEL_TIMER: u8 = 1;
pub const EFFECT_SHOW: u8 = 2;
pub const EFFECT_HIDE: u8 = 3;

/// One `HoverCardEffect<u64>`. schedule: `token`, `after` (ns); show:
/// `target`, `sliding`; cancelTimer and hide: nothing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverCardEffect {
    pub target: CmuxHoverTarget,
    pub token: u64,
    pub after: i64,
    pub kind: u8,
    pub sliding: bool,
}

impl From<&HoverCardEffect<u64>> for CmuxHoverCardEffect {
    fn from(e: &HoverCardEffect<u64>) -> Self {
        match e {
            HoverCardEffect::Schedule { token, after } => {
                Self { token: *token, after: *after, kind: EFFECT_SCHEDULE, ..Self::default() }
            }
            HoverCardEffect::CancelTimer => Self { kind: EFFECT_CANCEL_TIMER, ..Self::default() },
            HoverCardEffect::Show { target, sliding } => Self {
                target: target.into(),
                kind: EFFECT_SHOW,
                sliding: *sliding,
                ..Self::default()
            },
            HoverCardEffect::Hide => Self { kind: EFFECT_HIDE, ..Self::default() },
        }
    }
}

/// The result of one batch.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BatchResult {
    /// Events applied, from the start of the batch.
    pub events: usize,
    /// Effects written, from the start of `out`.
    pub effects: usize,
}

/// Applies `events` in order to `machine` and writes their effects to `out`
/// in order. An event is applied only while `out` has room for the most one
/// event can produce (`MAX_EFFECTS_PER_EVENT`), so the host calls again with
/// the rest. An unknown event kind is skipped (counted as applied, no effect).
pub fn reduce_card_batch(
    machine: &mut CmuxHoverCardMachine,
    events: &[CmuxHoverCardEvent],
    out: &mut [CmuxHoverCardEffect],
) -> BatchResult {
    let mut m = HoverCardMachine::<u64>::from(*machine);
    let mut result = BatchResult::default();
    for event in events {
        if out.len().saturating_sub(result.effects) < MAX_EFFECTS_PER_EVENT {
            break;
        }
        let effects: Effects<u64> = match event.event() {
            Some(event) => m.reduce(event),
            None => Effects::new(),
        };
        for effect in effects.iter() {
            if let Some(slot) = out.get_mut(result.effects) {
                *slot = CmuxHoverCardEffect::from(effect);
                result.effects = result.effects.saturating_add(1);
            }
        }
        result.events = result.events.saturating_add(1);
    }
    *machine = CmuxHoverCardMachine::from(&m);
    result
}

/// Every hover timing token, nanoseconds.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverTiming {
    pub card_show_delay: i64,
    pub card_reshow_window: i64,
    pub card_sweep_interval: i64,
    pub card_pin_lifetime: i64,
    pub card_still_pointer_delay: i64,
    pub tooltip_delay: i64,
    pub tooltip_warm: i64,
    pub card_grace: i64,
    pub card_aim: i64,
}

impl CmuxHoverTiming {
    /// The defaults.
    #[must_use]
    pub const fn standard() -> Self {
        let i = HoverIntentTiming::STANDARD;
        Self {
            card_show_delay: HOVER_CARD_SHOW_DELAY,
            card_reshow_window: HOVER_CARD_RESHOW_WINDOW,
            card_sweep_interval: HOVER_CARD_SWEEP_INTERVAL,
            card_pin_lifetime: HOVER_CARD_PIN_LIFETIME,
            card_still_pointer_delay: HOVER_CARD_STILL_POINTER_DELAY,
            tooltip_delay: i.tooltip_delay,
            tooltip_warm: i.tooltip_warm,
            card_grace: i.card_grace,
            card_aim: i.card_aim,
        }
    }
}

pub const INTENT_IDLE: u8 = 0;
pub const INTENT_PENDING: u8 = 1;
pub const INTENT_SHOWN: u8 = 2;
pub const INTENT_WARM: u8 = 3;

/// `HoverIntent<u64>`: `phase` (`INTENT_*`) with its `target` and `token`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverIntent {
    pub target: u64,
    pub token: u64,
    pub next_token: u64,
    pub delay: i64,
    pub warm_for: i64,
    pub phase: u8,
}

impl CmuxHoverIntent {
    #[must_use]
    pub fn new(delay: i64, warm_for: i64) -> Self {
        Self::from(&HoverIntent::<u64>::new(delay, warm_for))
    }
}

impl From<CmuxHoverIntent> for HoverIntent<u64> {
    fn from(c: CmuxHoverIntent) -> Self {
        let phase = match c.phase {
            INTENT_PENDING => HoverIntentPhase::Pending { target: c.target, token: c.token },
            INTENT_SHOWN => HoverIntentPhase::Shown { target: c.target },
            INTENT_WARM => HoverIntentPhase::Warm { token: c.token },
            _ => HoverIntentPhase::Idle,
        };
        Self::from_parts(phase, c.next_token.max(1), c.delay, c.warm_for)
    }
}

impl From<&HoverIntent<u64>> for CmuxHoverIntent {
    fn from(i: &HoverIntent<u64>) -> Self {
        let (phase, target, token) = match *i.phase() {
            HoverIntentPhase::Idle => (INTENT_IDLE, 0, 0),
            HoverIntentPhase::Pending { target, token } => (INTENT_PENDING, target, token),
            HoverIntentPhase::Shown { target } => (INTENT_SHOWN, target, 0),
            HoverIntentPhase::Warm { token } => (INTENT_WARM, 0, token),
        };
        Self {
            target,
            token,
            next_token: i.next_token(),
            delay: i.delay,
            warm_for: i.warm_for,
            phase,
        }
    }
}

/// One `HoverIntentEffect<u64>`, `kind` as `EFFECT_*`: schedule `token`
/// after `after` ns; show `target`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxHoverIntentEffect {
    pub target: u64,
    pub token: u64,
    pub after: i64,
    pub kind: u8,
}

impl From<&HoverIntentEffect<u64>> for CmuxHoverIntentEffect {
    fn from(e: &HoverIntentEffect<u64>) -> Self {
        match *e {
            HoverIntentEffect::Schedule { token, after } => {
                Self { token, after, kind: EFFECT_SCHEDULE, ..Self::default() }
            }
            HoverIntentEffect::CancelTimer => Self { kind: EFFECT_CANCEL_TIMER, ..Self::default() },
            HoverIntentEffect::Show(target) => {
                Self { target, kind: EFFECT_SHOW, ..Self::default() }
            }
            HoverIntentEffect::Hide => Self { kind: EFFECT_HIDE, ..Self::default() },
        }
    }
}

pub const INTENT_CALL_HOVER: u8 = 0;
pub const INTENT_CALL_DEADLINE: u8 = 1;
pub const INTENT_CALL_DISMISS: u8 = 2;

/// One call on `intent`: hover (`has_target`, `value` the target id),
/// deadline (`value` the token) or dismiss. Writes at most
/// `MAX_INTENT_EFFECTS` effects to `out` and returns how many; an unknown
/// call, or an `out` shorter than `MAX_INTENT_EFFECTS`, changes nothing.
pub fn intent_call(
    intent: &mut CmuxHoverIntent,
    call: u8,
    has_target: bool,
    value: u64,
    out: &mut [CmuxHoverIntentEffect],
) -> usize {
    if out.len() < super::intent::MAX_INTENT_EFFECTS {
        return 0;
    }
    let mut i = HoverIntent::<u64>::from(*intent);
    let effects: IntentEffects<u64> = match call {
        INTENT_CALL_HOVER => i.hover(has_target.then_some(value)),
        INTENT_CALL_DEADLINE => i.deadline(value),
        INTENT_CALL_DISMISS => i.dismiss(),
        _ => return 0,
    };
    let mut n = 0usize;
    for effect in effects.iter() {
        if let Some(slot) = out.get_mut(n) {
            *slot = CmuxHoverIntentEffect::from(effect);
            n = n.saturating_add(1);
        }
    }
    *intent = CmuxHoverIntent::from(&i);
    n
}

/// `HoverCardEscapeGeometry`; `is_leading` the card sits left of its row.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct CmuxHoverEscapeGeometry {
    pub anchor: HoverRect,
    pub card: HoverRect,
    pub escape_slot: HoverRect,
    pub gap_strip: HoverRect,
    pub is_leading: bool,
}

impl From<HoverCardEscapeGeometry> for CmuxHoverEscapeGeometry {
    fn from(g: HoverCardEscapeGeometry) -> Self {
        Self {
            anchor: g.anchor,
            card: g.card,
            escape_slot: g.escape_slot,
            gap_strip: g.gap_strip,
            is_leading: g.is_leading,
        }
    }
}

impl From<CmuxHoverEscapeGeometry> for HoverCardEscapeGeometry {
    fn from(g: CmuxHoverEscapeGeometry) -> Self {
        Self {
            anchor: g.anchor,
            card: g.card,
            escape_slot: g.escape_slot,
            gap_strip: g.gap_strip,
            is_leading: g.is_leading,
        }
    }
}

/// `alignment` 0 top, 1 middle (any other number: top).
#[must_use]
pub fn row_alignment(alignment: u8) -> HoverRowAlignment {
    if alignment == 1 { HoverRowAlignment::Middle } else { HoverRowAlignment::Top }
}

pub const ZONE_ROW: u8 = 0;
pub const ZONE_CARD: u8 = 1;
pub const ZONE_ESCAPE: u8 = 2;
pub const ZONE_GAP: u8 = 3;
pub const ZONE_OUTSIDE: u8 = 4;

/// The zone number (`ZONE_*`) of `point` for `geometry`.
#[must_use]
pub fn zone(geometry: CmuxHoverEscapeGeometry, point: HoverPoint) -> u8 {
    match HoverCardEscapeGeometry::from(geometry).zone(point) {
        HoverZone::Row => ZONE_ROW,
        HoverZone::Card => ZONE_CARD,
        HoverZone::Escape => ZONE_ESCAPE,
        HoverZone::Gap => ZONE_GAP,
        HoverZone::Outside => ZONE_OUTSIDE,
    }
}
