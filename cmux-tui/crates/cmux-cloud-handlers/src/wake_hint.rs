//! Wake on intent: the person showed they are about to use a Cloud machine (focused the app or
//! its chat, opened a terminal on it, unlocked the phone with its chat in front) before any key,
//! so a paused machine starts its restore now instead of at the first keystroke (hq#21300:
//! restore is 1.4-10.3 s of a wake and nothing in the guest shortens it).
//!
//! The Mac and iOS shells only forward the raw signal (`cloudMachine.wakeHint {v, id, signal}`)
//! with the facts their models hold; every decision is here: which signal counts, the debounce,
//! the per-machine cap, and the re-pause of a machine a hint woke that nobody used. It extends the
//! typing prewarm ([`crate::decide::prewarm`], cmux#51758): the same paused-only rule and the same
//! cool-down after a failed resume, with the hint's own bounds on top.
//!
//! Bounds, so a stray focus cannot keep a machine awake and billing:
//! - a hint only starts the wake of a `paused` machine; it never touches an awake one, so it
//!   never extends that machine's idle timer;
//! - one hint per machine per [`DEBOUNCE_MS`], and at most [`MAX_HINT_WAKES`] hint wakes per
//!   machine per [`CAP_WINDOW_MS`];
//! - a machine a hint woke with no input within [`IDLE_BOUND_MS`] pauses again; the wake is
//!   counted `false` with the awake seconds it cost, else `used`.
//!
//! Versioned: [`WAKE_HINT_VERSION`]. A hint of a newer version is read by its known fields (a
//! newer client adds fields, never changes these); an unknown signal is skipped, never guessed.
//! Pure: the caller passes the clock (`now_ms`, any monotonic origin).

use std::collections::{HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use crate::decide::{self, Prewarm, PrewarmFacts};

/// The wake hint's protocol version (page -> app `cloudMachine.wakeHint`, app -> rules).
pub const WAKE_HINT_VERSION: u32 = 1;
/// One hint per machine per this long: a focus flapping between windows asks once.
pub const DEBOUNCE_MS: u64 = 2_000;
/// At most this many hint wakes per machine per [`CAP_WINDOW_MS`].
pub const MAX_HINT_WAKES: usize = 4;
/// The window of [`MAX_HINT_WAKES`].
pub const CAP_WINDOW_MS: u64 = 60 * 60 * 1000;
/// A machine a hint woke pauses again when no input came this long after its resume answered.
/// Start value from the brief (30 s); hq#21300's focus-to-first-key data tunes it.
pub const IDLE_BOUND_MS: u64 = 30_000;

/// What the person did. Raw: the shell names the event, the rules decide whether it counts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Signal {
    /// The app or the machine's chat became key / visible.
    Focus,
    /// A terminal on that machine opened.
    Terminal,
    /// The phone unlocked with that machine's chat in front.
    Unlock,
    /// A signal this version does not know (a newer client's): skipped.
    #[serde(other)]
    Unknown,
}

/// A hint as the app forwards it, with the facts its models hold.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Hint {
    /// The sender's [`WAKE_HINT_VERSION`]; 0 (absent) is not a hint.
    pub v: u32,
    pub machine: String,
    pub signal: Option<Signal>,
    /// The hidden setting (`cloud.wakeOnIntent`, default on; the kill switch).
    pub enabled: bool,
    /// The typing prewarm's facts: Cloud may be called, the list is loaded, the machine's status.
    pub allowed: bool,
    pub loaded: bool,
    pub status: Option<String>,
}

/// What a hint does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HintDecision {
    /// Resume the machine now (script-originated), then tell [`WakeHints::resumed`].
    Resume,
    /// Do nothing, for this reason.
    Skip(&'static str),
}

/// How a hint wake ended, for the wake log.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "tag")]
pub enum Outcome {
    /// Input followed: `lead_ms` from the resume's answer to the first input.
    #[serde(rename_all = "camelCase")]
    Used { signal: Signal, lead_ms: u64 },
    /// No input within the bound: the machine pauses again; `awake_ms` is what it cost.
    #[serde(rename_all = "camelCase")]
    False { signal: Signal, awake_ms: u64 },
}

/// What to do about a machine a hint woke, asked when the check comes due.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum IdleDecision {
    /// Ask again this much later.
    #[serde(rename_all = "camelCase")]
    Wait { check_after_ms: u64 },
    /// Pause it (script-originated); the wake was false.
    Pause { outcome: Outcome },
    /// Nothing more to do: it was used, it is no longer running, or no hint woke it.
    Done,
}

#[derive(Clone, Copy, Debug)]
struct Open {
    signal: Signal,
    /// When the resume answered; None while it is in flight.
    woke_at: Option<u64>,
}

#[derive(Debug, Default)]
struct Machine {
    last_hint: Option<u64>,
    last_failure: Option<u64>,
    wakes: VecDeque<u64>,
    open: Option<Open>,
}

/// Every machine's hint state. One per app process.
#[derive(Debug, Default)]
pub struct WakeHints {
    machines: HashMap<String, Machine>,
}

impl WakeHints {
    /// Decides one hint. A `Resume` counts toward the cap at once, so a hint racing its own
    /// resume cannot start a second.
    pub fn hint(&mut self, hint: &Hint, now_ms: u64) -> HintDecision {
        if hint.v == 0 {
            return HintDecision::Skip("noVersion");
        }
        if !hint.enabled {
            return HintDecision::Skip("disabled");
        }
        let signal = match hint.signal {
            None | Some(Signal::Unknown) => return HintDecision::Skip("unknownSignal"),
            Some(signal) => signal,
        };
        if hint.machine.is_empty() {
            return HintDecision::Skip("notListed");
        }
        let machine = self.machines.entry(hint.machine.clone()).or_default();
        let facts = PrewarmFacts {
            allowed: hint.allowed,
            loaded: hint.loaded,
            status: hint.status.clone(),
            since_failure_ms: machine.last_failure.map(|at| now_ms.saturating_sub(at)),
        };
        if let Prewarm::Skip(reason) = decide::prewarm(&facts) {
            return HintDecision::Skip(reason);
        }
        if machine.open.is_some_and(|open| open.woke_at.is_none()) {
            return HintDecision::Skip("inFlight");
        }
        if machine.last_hint.is_some_and(|at| now_ms.saturating_sub(at) < DEBOUNCE_MS) {
            return HintDecision::Skip("debounced");
        }
        machine.last_hint = Some(now_ms);
        while machine.wakes.front().is_some_and(|&at| now_ms.saturating_sub(at) >= CAP_WINDOW_MS) {
            machine.wakes.pop_front();
        }
        if machine.wakes.len() >= MAX_HINT_WAKES {
            return HintDecision::Skip("capped");
        }
        machine.wakes.push_back(now_ms);
        machine.open = Some(Open { signal, woke_at: None });
        HintDecision::Resume
    }

    /// The hint's resume answered. Accepted: the idle check is due in the returned ms. Failed:
    /// the typing prewarm's cool-down applies to the next hint.
    pub fn resumed(&mut self, machine: &str, ok: bool, now_ms: u64) -> Option<u64> {
        let state = self.machines.get_mut(machine)?;
        let open = state.open.as_mut()?;
        if ok {
            open.woke_at = Some(now_ms);
            Some(IDLE_BOUND_MS)
        } else {
            state.open = None;
            state.last_failure = Some(now_ms);
            None
        }
    }

    /// The person used the machine (typed, sent, attached). Ends its hint wake as `used`, once.
    pub fn input(&mut self, machine: &str, now_ms: u64) -> Option<Outcome> {
        let state = self.machines.get_mut(machine)?;
        let open = state.open.take()?;
        let woke_at = open.woke_at.unwrap_or(now_ms);
        Some(Outcome::Used { signal: open.signal, lead_ms: now_ms.saturating_sub(woke_at) })
    }

    /// The idle check of a machine a hint woke, with its status now.
    pub fn idle(&mut self, machine: &str, status: Option<&str>, now_ms: u64) -> IdleDecision {
        let Some(state) = self.machines.get_mut(machine) else { return IdleDecision::Done };
        let Some(open) = state.open else { return IdleDecision::Done };
        let Some(woke_at) = open.woke_at else {
            return IdleDecision::Wait { check_after_ms: IDLE_BOUND_MS };
        };
        // Still coming up: wait for it, the bound counts from running.
        if status == Some("starting") {
            return IdleDecision::Wait { check_after_ms: IDLE_BOUND_MS };
        }
        if status != Some("running") {
            state.open = None;
            return IdleDecision::Done;
        }
        let awake_ms = now_ms.saturating_sub(woke_at);
        if awake_ms < IDLE_BOUND_MS {
            return IdleDecision::Wait { check_after_ms: IDLE_BOUND_MS - awake_ms };
        }
        state.open = None;
        IdleDecision::Pause { outcome: Outcome::False { signal: open.signal, awake_ms } }
    }
}

#[cfg(test)]
#[path = "wake_hint_tests.rs"]
mod tests;
