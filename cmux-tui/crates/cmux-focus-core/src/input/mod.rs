//! The one input router (handoff/rewrites/R-INPUT/DESIGN.md): the single
//! owner of where every key goes.
//!
//! [`InputRouter`] holds every window's focus (the [`crate::reducer`] state)
//! and decides each key's route in the key's own call, from that one state:
//! the key runs its binding, goes to a sink now, waits in that sink's lane,
//! is consumed, or is AppKit's own (a window the router does not model). A
//! key's sink is fixed when the key is routed and never changes: a key in a
//! lane leaves it only to that sink, or is dropped with a reason when the
//! sink ends. Lanes have no timer.
//!
//! The platform only reports facts ([`InputEvent`]): focus events, what
//! AppKit's dispatch would reach now, sink readiness and lifetime,
//! creations, the input source. AppKit's first responder and key window are
//! outputs of the focus, never inputs of a route except to choose how a key
//! reaches its fixed sink ([`Via`]).
//!
//! [`ledger::Ledger`] checks the invariants of an effect stream (no lost key,
//! no double key, order kept per sink, the sink fixed at key time, no
//! delivery to an ended sink, bounded lanes). Pure: no I/O, no clock.

pub mod key;
pub mod ledger;
mod router;
pub mod sink;

pub use key::{Binding, KeyPhase, KeyRecord, Modifiers, Tier, WindowRole};
pub use router::{InputRouter, LANE_LIMIT};
pub use sink::{FieldKind, Sink, TerminalKey};

use crate::event::FocusEffect;
use crate::state::ExpectationKey;
use std::sync::Arc;

/// A key's id: given by the router to every key event, in typing order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InputId(pub u64);

/// How a key reaches its sink.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Via {
    /// AppKit's own dispatch: the sink's view is the first responder of the
    /// key window (the input method, key equivalents and the view run).
    Responder,
    /// The sink's own input path, whatever has the keyboard: a terminal's
    /// writer (its view's encoder, else the daemon by terminal id), a page's
    /// native key send.
    Direct,
}

/// Why a key waits in its sink's lane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WaitReason {
    /// The sink cannot take input yet (a page before its first paint).
    NotReady,
    /// The sink takes keys only through AppKit and AppKit's dispatch does
    /// not reach it yet (a field), or an input method composes and needs the
    /// sink's view.
    AwaitsResponder,
    /// Keys typed before it wait in the lane: it keeps its place.
    BehindQueued,
}

/// Why a key reached nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DropReason {
    /// Its sink ended before it could take the key.
    SinkGone(GoneReason),
    /// Its window closed before its field took it.
    WindowClosed,
    /// The focus left its field before the field could take it: the person
    /// moved on.
    TargetLeft,
    /// Its sink's lane was full when the key came (refused at key time).
    LaneFull,
}

/// Why a sink ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GoneReason {
    /// Its tab closed.
    Closed,
    /// The creation that was making it failed.
    CreationFailed,
}

/// Why a key was consumed with no effect.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConsumeReason {
    /// The window's focus names nothing that takes keys (an empty pane, no
    /// pane).
    NoTarget,
    /// The key is the release of a press that ran an action or was consumed.
    FollowsConsumedPress,
    /// The release of a delivered press whose sink cannot take a key now (a
    /// field the keyboard left): nothing needs it.
    ReleaseNotTaken,
}

/// What the platform does after a call, in order.
///
/// For a key event the call emits exactly one disposition for the key's own
/// id (`Deliver`, `Run`, `Queued`, `Consumed`, `Dropped` or `Platform`).
/// Keys that waited in a lane before it may be delivered first in the same
/// call, so the platform applies the effects in order. A `Queued` key later
/// ends in exactly one `Deliver`, `Run` or `Dropped`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputEffect {
    /// The key goes to `sink` now.
    Deliver { id: InputId, sink: Sink, via: Via },
    /// The key's binding runs now, with the key as its input, aimed at `tab`
    /// (the tab the key was typed for).
    Run { id: InputId, action: Arc<str>, tab: Option<Arc<str>> },
    /// The key waits in `sink`'s lane; its sink is fixed.
    Queued { id: InputId, sink: Sink, reason: WaitReason },
    /// The key is consumed with no effect.
    Consumed { id: InputId, reason: ConsumeReason },
    /// The key reached nothing.
    Dropped { id: InputId, reason: DropReason },
    /// AppKit's own dispatch takes the key (a window or panel the router does
    /// not model).
    Platform { id: InputId },
    /// A focus effect of `window` (the focus reducer's).
    Focus { window: Arc<str>, effect: FocusEffect },
}

impl InputEffect {
    /// The key the effect is about; none for a focus effect.
    pub fn id(&self) -> Option<InputId> {
        match self {
            InputEffect::Deliver { id, .. }
            | InputEffect::Run { id, .. }
            | InputEffect::Queued { id, .. }
            | InputEffect::Consumed { id, .. }
            | InputEffect::Dropped { id, .. }
            | InputEffect::Platform { id } => Some(*id),
            InputEffect::Focus { .. } => None,
        }
    }
}

/// What the router is told.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputEvent {
    /// A key event, as typed.
    Key(KeyRecord),
    /// A focus event of `window` (topology, intents, responder reports...).
    Focus { window: Arc<str>, event: crate::event::FocusEvent },
    /// A cmux window opened: its focus starts empty.
    WindowOpened { window: Arc<str> },
    /// A cmux window closed: its fields' waiting keys are dropped.
    WindowClosed { window: Arc<str> },
    /// What AppKit's dispatch of a key typed now reaches, classified (the key
    /// window's first responder, or the page of a key Chromium page window),
    /// after it changed.
    Dispatch { reaches: Option<Sink> },
    /// `sink` can take input now (a page painted after its commit, a primary
    /// input reported ready).
    Ready { sink: Sink },
    /// `sink` cannot take input until it reports ready again (a new document
    /// started).
    Pending { sink: Sink },
    /// `sink` ended: its waiting keys are dropped.
    Gone { sink: Sink, reason: GoneReason },
    /// A creation shows `sink` under `key` (its stand-in tab or surface)
    /// before any window's topology has it: keys for it go to `sink`.
    Creation { key: ExpectationKey, sink: Sink },
    /// The creation under `key` failed: its sink ends.
    CreationFailed { key: ExpectationKey },
    /// The input source composes text (an input method): a text key for a
    /// sink whose view is not the first responder waits for it.
    InputSource { composes: bool },
}
