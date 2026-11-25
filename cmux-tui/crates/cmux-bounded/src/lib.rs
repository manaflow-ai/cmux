//! A state machine whose every waiting state declares how long it may wait and what happens then.
//!
//! Why: a session reads "starting", a terminal reads "reconnecting", and nothing ever moves it on.
//! Each such hang was one state that expected some event to arrive and had no path out when it
//! did not (cmuxterm-hq handbook `transitional-state-without-a-deadline`, `wait-with-no-deadline`;
//! design `remote-cloud-durability.md` 4.3). Leo, 2026-11-24: "have good state machines ... these
//! recovery processes needs to be able to happen just automatically".
//!
//! The rule, in the type system: a machine implements [`BoundedMachine`], whose [`wait`] says for
//! every state one of three things ([`Wait`]):
//!
//! - [`Wait::Settled`]: steady or terminal (connected, idle, done, failed with an action). Nothing
//!   is awaited.
//! - [`Wait::Bounded`]: the machine waits on something it does not control. Past `bound` the
//!   [`Driver`] feeds `on_expiry`, the recovery edge, back into the machine.
//! - [`Wait::OnPerson`]: only a person can move it, and it names the one action that does.
//!
//! [`wait`] is written as an exhaustive `match` on the state with no `_` arm, so a new state that
//! declares no bound does not compile. `tests/no_wildcard_wait.rs` reads every `impl
//! BoundedMachine` under `cmux-tui/crates` and fails on a catch-all arm in its `wait`.
//!
//! The [`Driver`] arms a [`cmux_deadline::Deadline`] on every state entry, cancels it on any
//! transition, fires the recovery edge when it passes and records a [`WaitOverran`] (a tracing
//! warning and a process-wide counter, [`overrun_count`]). [`Driver::report`] gives a UI the
//! serializable [`WaitReport`]. [`testing::assert_every_wait_recovers`] drives each bounded state
//! past its bound and asserts the machine reaches a settled state or a person's action within a
//! total budget.
//!
//! [`wait`]: BoundedMachine::wait

mod driver;
pub mod testing;
#[cfg(feature = "tokio")]
mod tokio_driver;

use std::fmt::Debug;
use std::time::Duration;

pub use cmux_deadline::{Clock, Deadline};
pub use driver::{Driver, WaitKind, WaitOverran, WaitReport, overrun_count, overrun_total};

/// How long a waiting state the person can do nothing about stays out of sight in a UI
/// (`schemas/notice-timing/notice-timing.json`, `connectionQuietMs`; handbook
/// `connection-state-with-no-action-or-bound`). [`WaitReport::show`] applies it.
pub const CONNECTION_QUIET: Duration = Duration::from_millis(10_000);

/// What a state waits on. See the crate docs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wait<E> {
    /// Steady or terminal: nothing is awaited.
    Settled,
    /// Waiting on something the machine does not control. Past `bound`, `on_expiry` is fed.
    Bounded {
        bound: Duration,
        /// The recovery edge. It must leave the state: to a retry with backoff, or after a total
        /// budget to a settled state with an action.
        on_expiry: E,
        /// What is awaited, for telemetry and a UI ("the harness's first reply").
        why: &'static str,
    },
    /// Only a person can move it, with this one action ("Sign in", "Restart the session").
    OnPerson { action: &'static str },
}

impl<E> Wait<E> {
    pub fn bounded(bound: Duration, on_expiry: E, why: &'static str) -> Self {
        Self::Bounded { bound, on_expiry, why }
    }

    pub fn bound(&self) -> Option<Duration> {
        match self {
            Self::Bounded { bound, .. } => Some(*bound),
            Self::Settled | Self::OnPerson { .. } => None,
        }
    }

    pub fn kind(&self) -> WaitKind {
        match self {
            Self::Settled => WaitKind::Settled,
            Self::Bounded { .. } => WaitKind::Bounded,
            Self::OnPerson { .. } => WaitKind::OnPerson,
        }
    }
}

/// A state machine whose every state declares its [`Wait`].
pub trait BoundedMachine {
    /// Compared after each step: a step that changes it enters a new state (the driver re-arms
    /// its bound); one that leaves it equal keeps the running clock, so an ignored event never
    /// extends a wait. A state whose bound is "silence since the last progress" carries a
    /// progress count, so progress is a new state.
    type State: Clone + PartialEq + Debug;
    type Event: Debug;

    /// The machine's name in telemetry (`acpmux.session`, `tui.attach`).
    const NAME: &'static str;

    /// What `state` waits on: an exhaustive `match` with no `_` arm.
    fn wait(state: &Self::State) -> Wait<Self::Event>;

    /// Apply one event.
    fn step(&mut self, event: Self::Event);

    fn state(&self) -> &Self::State;

    /// A short name for `state` in telemetry and a [`WaitReport`]: by default its `Debug` text up
    /// to the first `(`, `{` or space (the variant's name).
    fn label(state: &Self::State) -> String {
        let text = format!("{state:?}");
        text.split(['(', '{', ' ']).next().unwrap_or_default().to_owned()
    }
}
