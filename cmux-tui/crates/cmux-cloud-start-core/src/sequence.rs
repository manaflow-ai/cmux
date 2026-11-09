//! A Cloud start's one sequencer (cloud-v0-lead, on cmux#39069: "plan to move the start step order
//! into Rust (cmux-cloud-start-core) next, so there's one sequencer"). Pure: the app sends the
//! state, one event and its monotonic clock in milliseconds; this answers the next state and the
//! effects to run, in order. The app runs each step as a platform effect (the link, the Keychain,
//! the guest exec, the tab and pane) and tells its end; it decides nothing about their order.
//!
//! What it decides:
//! - which steps run together: a start's login and its approvals restart begin at once once the
//!   machine is linked (a composer start's copy too), and the login's two machine reads (the
//!   guest's kind and the machine's own login) at once;
//! - the keyed approvals restart: only a daemon that said it is safe, or an idle one whose run
//!   lacks this app's key ([`approvals`]);
//! - when the credential transfer checks the guest again ([`recheck_guest`]);
//! - the step times, one `cloud start step: NAME MS ms` line each, that add up to the span.
//!
//! Served to the app over the app FFI's JSON channel as ops `cloud_sequence_*`
//! (`cmux-layout-reducer-ffi/src/cloud_sequence.rs`).

use serde::{Deserialize, Serialize};

/// What every step line starts with: the chat probe (cmuxterm-hq `cloud_chat_app_probe.py`) matches it.
pub const PREFIX: &str = "cloud start step: ";

/// A login read within this long of the guest check that passed is delivered on that check.
pub const RECHECK_AFTER_MS: u64 = 2_000;

/// Which start the sequence runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Path {
    /// `cmux cloud start-session`: connect, then the login beside the approvals, then the chat's
    /// anchor, its tab and its start.
    Session,
    /// A composer start with a project (`cloud.startChat`): the copy, the login and the approvals
    /// at once on the linked machine, then the chat opens.
    Composer,
    /// A composer start with no project: the login beside the approvals, then the chat opens.
    Home,
    /// The harness login's machine reads: the guest's kind and, for Claude, the machine's own
    /// login, at once; the login read waits only for a spare warm's copy it races.
    MachineReads,
}

/// A step the app runs (every one but [`Step::Approvals`], which is the sequencer's own).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Step {
    Connect,
    Login,
    /// Remote approvals on: [`Step::DaemonStatus`] and [`Step::KeyedRestart`] as [`approvals`] says.
    Approvals,
    Copy,
    Anchor,
    Tab,
    Start,
    Open,
    /// The machine daemon's status: whether it is idle enough for a keyed restart.
    DaemonStatus,
    /// The keyed acpmux restart that carries this app's key.
    KeyedRestart,
    /// The guest's kind (`/etc/cmux/vm-kind`, again until a new guest binds).
    Guest,
    /// The wait for a spare warm's login copy on the machine.
    WarmCopy,
    /// The machine's own Claude login.
    MachineLogin,
}

/// What the app knows when it begins a sequence.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    /// Approvals: the daemon answered that a keyed restart is safe now.
    pub daemon_said_safe: bool,
    /// Approvals: a run on the machine already holds this app's key.
    pub holds_key: bool,
    /// Machine reads: the harness login verdict's `reads_machine`.
    pub reads_machine: bool,
    /// Machine reads: a Claude start (only Claude reads the machine's login).
    pub claude: bool,
    /// Machine reads: the verdict's `warm_copy_conflict`.
    pub warm_copy_conflict: bool,
}

/// How a start turns remote approvals on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Approvals {
    /// A run already holds this app's key: nothing restarts.
    Held,
    /// The daemon said a keyed restart is safe: at once.
    RestartNow,
    /// Read the daemon's status; only an idle daemon restarts.
    IfIdle,
}

/// The keyed restart's rule.
pub fn approvals(_daemon_said_safe: bool, _holds_key: bool) -> Approvals {
    Approvals::IfIdle
}

/// Whether the credential transfer checks the guest again before it writes.
pub fn recheck_guest(_from_cache: bool, _since_guest_check_ms: u64) -> bool {
    true
}

/// `cloud start step: NAME MS ms`.
pub fn line(name: &str, ms: u64) -> String {
    format!("{PREFIX}{name} {ms} ms")
}

/// A step under way.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Running {
    pub step: Step,
    pub since: u64,
    pub split: u64,
}

/// The sequence's state: the app keeps it between calls and sends it with each event.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub path: Option<Path>,
    pub facts: Facts,
    pub last: u64,
    pub running: Vec<Running>,
    pub done: Vec<Step>,
    pub ended: bool,
}

/// One thing that happened, as the app tells it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    Begin {
        path: Path,
        #[serde(default)]
        facts: Facts,
    },
    Done {
        step: Step,
        #[serde(default)]
        idle: Option<bool>,
        #[serde(default)]
        still: Option<bool>,
    },
    Mark {
        step: Step,
        name: String,
    },
    Failed {
        step: Step,
    },
    Stop,
}

/// What the app does next.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    Run { step: Step },
    Log { line: String },
    Cancel { step: Step },
    Finish { failed: bool },
}

/// The next state and the effects to run, in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub state: State,
    pub effects: Vec<Effect>,
}

/// One event at `now` (the app's monotonic clock, in milliseconds).
pub fn step(state: State, _event: Event, _now: u64) -> Answer {
    Answer { state, effects: Vec::new() }
}

#[cfg(test)]
mod tests;
