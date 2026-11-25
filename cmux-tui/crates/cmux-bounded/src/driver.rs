//! The [`Driver`]: arms each state's bound on entry, fires its recovery edge when it passes.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Duration;

use cmux_deadline::{Clock, Deadline};
use serde::{Deserialize, Serialize};

use crate::{BoundedMachine, CONNECTION_QUIET, Wait};

/// Which of the three [`Wait`]s a state declares, without its event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitKind {
    Settled,
    Bounded,
    OnPerson,
}

/// A bounded wait that passed its bound: the driver fed its recovery edge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaitOverran {
    pub machine: &'static str,
    pub state: String,
    pub bound: Duration,
    /// From the state's entry to the moment the driver noticed (at least `bound`).
    pub waited: Duration,
    pub why: &'static str,
    /// The state the recovery edge led to.
    pub to: String,
}

/// What a UI draws for a machine's current wait. Serializable for FFI and the wire.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WaitReport {
    pub machine: String,
    pub state: String,
    pub kind: WaitKind,
    /// Since the state was entered.
    pub since_ms: u64,
    /// The bound of a [`WaitKind::Bounded`] state.
    pub bound_ms: Option<u64>,
    /// What a bounded state awaits.
    pub why: Option<String>,
    /// The one action of a [`WaitKind::OnPerson`] state.
    pub action: Option<String>,
    /// Whether a UI shows the wait at all: a person's action at once, a bounded wait only once it
    /// has lasted [`CONNECTION_QUIET`] (handbook `connection-state-with-no-action-or-bound`).
    pub show: bool,
}

struct Armed<I: Clock> {
    deadline: Deadline<I>,
    bound: Duration,
    why: &'static str,
}

/// Runs a [`BoundedMachine`]: every event goes through [`Driver::feed`], and the owner calls
/// [`Driver::expire_due`] at [`Driver::deadline`] (with the `tokio` feature, `expired()` and
/// `run()` do it). The clock is `std::time::Instant` by default; every method has an `_at(now)`
/// form for a manual clock in tests.
pub struct Driver<M: BoundedMachine, I: Clock = std::time::Instant> {
    machine: M,
    entered: I,
    armed: Option<Armed<I>>,
    overruns: Vec<WaitOverran>,
}

impl<M: BoundedMachine, I: Clock> Driver<M, I> {
    pub fn new(machine: M) -> Self {
        Self::new_at(machine, I::now())
    }

    /// Starts the machine in its current state, entered at `now`.
    pub fn new_at(machine: M, now: I) -> Self {
        let mut driver = Self { machine, entered: now, armed: None, overruns: Vec::new() };
        driver.enter(now);
        driver
    }

    pub fn machine(&self) -> &M {
        &self.machine
    }

    pub fn into_machine(self) -> M {
        self.machine
    }

    pub fn state(&self) -> &M::State {
        self.machine.state()
    }

    /// When the current state's bound passes, or None for a settled or person's state.
    pub fn deadline(&self) -> Option<I> {
        self.armed.as_ref().map(|armed| armed.deadline.end())
    }

    /// When the current state was entered.
    pub fn entered(&self) -> I {
        self.entered
    }

    /// The overruns this driver recorded, oldest first.
    pub fn overruns(&self) -> &[WaitOverran] {
        &self.overruns
    }

    /// Applies one event. Returns whether it entered a new state (and so re-armed the bound).
    pub fn feed(&mut self, event: M::Event) -> bool {
        self.feed_at(event, I::now())
    }

    pub fn feed_at(&mut self, event: M::Event, now: I) -> bool {
        let before = self.machine.state().clone();
        self.machine.step(event);
        let moved = *self.machine.state() != before;
        if moved {
            self.enter(now);
        }
        moved
    }

    /// Past the current state's bound, records a [`WaitOverran`] and feeds the recovery edge.
    /// Before it, or in a state with no bound, does nothing and returns None.
    pub fn expire_due(&mut self) -> Option<WaitOverran> {
        self.expire_due_at(I::now())
    }

    pub fn expire_due_at(&mut self, now: I) -> Option<WaitOverran> {
        let armed = self.armed.as_ref()?;
        if !armed.deadline.expired_at(now) {
            return None;
        }
        let (bound, why) = (armed.bound, armed.why);
        let waited = now.saturating_duration_since(self.entered);
        let state = M::label(self.machine.state());
        let before = self.machine.state().clone();
        // `wait` is a pure function of the state, so the event is read again rather than kept
        // (an event need not be Clone).
        let Wait::Bounded { on_expiry, .. } = M::wait(&before) else {
            // The state changed under the driver without a step; take its own wait from now.
            self.enter(now);
            return None;
        };
        self.machine.step(on_expiry);
        let stayed = *self.machine.state() == before;
        if stayed {
            tracing::error!(
                target: "cmux_bounded",
                machine = M::NAME,
                state = %state,
                "a recovery edge left its state unchanged; its bound restarts"
            );
        }
        // Re-arm even when it stayed, so a broken edge waits its bound again instead of spinning.
        self.enter(now);
        let overran = WaitOverran {
            machine: M::NAME,
            state,
            bound,
            waited,
            why,
            to: M::label(self.machine.state()),
        };
        record(&overran);
        self.overruns.push(overran.clone());
        Some(overran)
    }

    /// What a UI draws for the current wait.
    pub fn report(&self) -> WaitReport {
        self.report_at(I::now())
    }

    pub fn report_at(&self, now: I) -> WaitReport {
        let wait = M::wait(self.machine.state());
        let since = now.saturating_duration_since(self.entered);
        let (bound_ms, why, action, show) = match &wait {
            Wait::Settled => (None, None, None, false),
            Wait::Bounded { bound, why, .. } => {
                (Some(millis(*bound)), Some((*why).to_owned()), None, since >= CONNECTION_QUIET)
            }
            Wait::OnPerson { action } => (None, None, Some((*action).to_owned()), true),
        };
        WaitReport {
            machine: M::NAME.to_owned(),
            state: M::label(self.machine.state()),
            kind: wait.kind(),
            since_ms: millis(since),
            bound_ms,
            why,
            action,
            show,
        }
    }

    fn enter(&mut self, now: I) {
        self.entered = now;
        self.armed = match M::wait(self.machine.state()) {
            Wait::Bounded { bound, why, .. } => {
                Some(Armed { deadline: Deadline::starting(now, bound), bound, why })
            }
            Wait::Settled | Wait::OnPerson { .. } => None,
        };
    }
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

static OVERRUNS: Mutex<BTreeMap<&'static str, u64>> = Mutex::new(BTreeMap::new());

fn record(overran: &WaitOverran) {
    tracing::warn!(
        target: "cmux_bounded",
        machine = overran.machine,
        state = %overran.state,
        bound_ms = millis(overran.bound),
        waited_ms = millis(overran.waited),
        why = overran.why,
        to = %overran.to,
        "wait overran its bound; recovery edge fired"
    );
    let mut counts = OVERRUNS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let count = counts.entry(overran.machine).or_default();
    *count = count.saturating_add(1);
}

/// How many waits of `machine` overran their bound in this process (a chaos harness or test
/// reads it before and after a fault).
pub fn overrun_count(machine: &str) -> u64 {
    let counts = OVERRUNS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    counts.get(machine).copied().unwrap_or(0)
}

/// Every machine's overruns in this process.
pub fn overrun_total() -> u64 {
    let counts = OVERRUNS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    counts.values().sum()
}
