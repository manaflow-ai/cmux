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
//! A tab's sink that ended takes no key until it is a new sink (a window shows
//! it again after none did, or a creation names it again): the router says so
//! with [`InputEffect::SinkEnded`] and [`InputEffect::SinkNew`].
//!
//! [`ledger::Ledger`] checks the invariants of an effect stream (no lost key,
//! no double key, order kept per sink, the sink fixed at key time, no
//! delivery to an ended sink, bounded lanes). Pure: no I/O, no clock.

mod binding;
mod dialog;
pub mod key;
mod lane;
pub mod ledger;
mod lifetime;
mod offer;
mod router;
mod session;
pub mod sink;

pub use dialog::DialogScope;
pub use key::{Binding, KeyPhase, KeyRecord, Modifiers, Tier, WindowRole};
pub use lane::LaneLimit;
pub use router::InputRouter;
pub use session::{SessionEnd, SessionKey, SessionKind};
pub use sink::{FieldKind, Sink, TerminalKey};

use crate::event::FocusEffect;
use crate::state::ExpectationKey;
use crate::topology::Kind;
use crate::window::Reduction;
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
    /// A dialog blocks the sink: the key, typed before the dialog, waits for
    /// its answer.
    Blocked,
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
    /// Its sink's lane was full when the key came (refused at key time, a
    /// loss the platform shows).
    LaneFull,
}

/// Why a sink ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GoneReason {
    /// Its tab closed. A closed tab's id shows again only when Reopen Closed
    /// brings the tab back, as a new tab.
    Closed,
    /// The creation that was making it failed.
    CreationFailed,
    /// It ended and its tab stays (a terminal whose process exited, shown
    /// with its end banner): it takes no key until a creation names it again
    /// (a restart) or its tab closes, wherever its tab shows meanwhile.
    Exited,
}

/// How the offer of a key to its page first ended with no action.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OfferEnd {
    /// The page handled the key: it said so, or it answered a newer key (a
    /// page answers its keys in key order).
    Handled,
    /// The page ended before it answered.
    PageGone,
    /// More offers to the same page waited for its answers than a lane holds:
    /// the oldest one's action can no longer run, and the platform shows that
    /// (R9 R-L5).
    Overflow,
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
    /// Escape in a field the keyboard moved into from content gave the
    /// keyboard back to that content (#33049).
    ReturnedFocus,
}

/// What the platform does after a call, in order.
///
/// For a key event the call emits exactly one disposition for the key's own
/// id (`Deliver`, `Run`, `Queued`, `Consumed`, `Dropped`, `Platform`, `Offer`
/// or `SessionKey`). Keys that waited in a lane before it may be delivered
/// first in the same call, so the platform applies the effects in order. A
/// `Queued` key later ends in exactly one `Deliver`, `Run` or `Dropped`; an
/// `Offer`ed key later gets one `Run` (its page left it unhandled) or one
/// `OfferClosed`, or nothing while its page has not answered.
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
    /// The key goes to the page `sink` first; `action` runs only when the
    /// page reports it unhandled ([`InputEvent::PageUnhandled`], then a `Run`).
    Offer { id: InputId, sink: Sink, via: Via, action: Arc<str> },
    /// The running key session takes the key.
    SessionKey { id: InputId, key: SessionKey },
    /// The key session ended (the platform removes its labels or recorder).
    SessionEnded { kind: SessionKind, reason: SessionEnd },
    /// The offer of key `id` to its page ended with no action.
    OfferClosed { id: InputId, reason: OfferEnd },
    /// A tab's sink ended: no key reaches it until a [`InputEffect::SinkNew`]
    /// for it. Its waiting keys are dropped in the same call.
    SinkEnded { sink: Sink, reason: GoneReason },
    /// From now `sink` names a new sink, not the one that ended: a window shows
    /// it again after none did (Reopen Closed reuses the tab id), a creation
    /// names it again, or nothing names the ended one any more. Keys held for
    /// the ended one (a press not yet released) reach nothing.
    SinkNew { sink: Sink },
    /// A focus effect of `window` (the focus reducer's).
    Focus { window: Arc<str>, effect: FocusEffect },
    /// A focus event of `window` was reduced (after its `Focus` effects):
    /// whether the reducer ran, and what the address bar memory asks for
    /// (DESIGN.md stage S2: the app's focus handle replies with this).
    FocusReduced { window: Arc<str>, reduction: Reduction },
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
            | InputEffect::Platform { id }
            | InputEffect::Offer { id, .. }
            | InputEffect::OfferClosed { id, .. }
            | InputEffect::SessionKey { id, .. } => Some(*id),
            InputEffect::Focus { .. }
            | InputEffect::FocusReduced { .. }
            | InputEffect::SessionEnded { .. }
            | InputEffect::SinkEnded { .. }
            | InputEffect::SinkNew { .. } => None,
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
    /// input reported ready). A report for a sink that ended counts for none:
    /// after [`InputEffect::SinkNew`] for it, the platform reports again at the
    /// new sink's own first paint.
    Ready { sink: Sink },
    /// `sink` cannot take input until it reports ready again (a new document
    /// started).
    Pending { sink: Sink },
    /// `sink` ended: its waiting keys are dropped. A tab's sink takes no key
    /// until it is a new sink ([`InputEffect::SinkNew`]); a field, overlay or
    /// dialog only loses its waiting keys. An exited sink whose tab then closes
    /// is reported again, `Closed`.
    Gone { sink: Sink, reason: GoneReason },
    /// A creation makes `sink`, a tab of `kind`, under `key` (its stand-in tab
    /// or surface): keys for it go to `sink` before any window's topology has
    /// it. Each creation gets one reply: [`InputEvent::Created`] or
    /// [`InputEvent::CreationFailed`], before or after its stand-in showed. A
    /// creation that names a sink that ended makes a new sink of that id (a
    /// reopen, a restart, a relaunch).
    Creation { key: ExpectationKey, sink: Sink, kind: Kind },
    /// The creation under `key` is done. Keys for its tab still go to its
    /// sink until a window shows the tab.
    Created { key: ExpectationKey },
    /// The creation under `key` failed, before or after its stand-in showed: its
    /// sink ends, and its waiting and later keys are dropped with the reason
    /// (the daemon gives back the bytes it already took for the terminal).
    CreationFailed { key: ExpectationKey },
    /// The input source composes text (an input method): a text key for a
    /// sink whose view is not the first responder waits for it.
    InputSource { composes: bool },
    /// A key session starts in `window` (the action that starts it sends this
    /// in its own turn); one that runs ends first.
    SessionStarted { kind: SessionKind, window: Arc<str> },
    /// The platform ended the running key session (a pick, nothing to label).
    SessionEnded,
    /// Dialog `id` shows and blocks `scope`.
    DialogShown { id: u64, scope: DialogScope },
    /// Dialog `id` was answered or dismissed: the keys its target kept wait
    /// for go on.
    DialogDismissed { id: u64 },
    /// The page left key `id`, offered to it first, unhandled: its action
    /// runs.
    PageUnhandled { id: InputId },
    /// The page handled key `id`, offered to it first: its action never runs.
    PageHandled { id: InputId },
}
