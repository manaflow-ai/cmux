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

/// The keyed restart's rule (the app's `RemoteApprovalPreparations.prepare` asked it of Swift
/// before): a daemon that said a keyed restart is safe restarts at once; else a run that already
/// holds this app's key needs nothing; else only an idle daemon restarts. The chat starts unkeyed
/// otherwise, and its Allow shows the normal restart notice.
pub fn approvals(daemon_said_safe: bool, holds_key: bool) -> Approvals {
    if daemon_said_safe {
        Approvals::RestartNow
    } else if holds_key {
        Approvals::Held
    } else {
        Approvals::IfIdle
    }
}

/// Whether the credential transfer checks the guest again before it writes the login. A login
/// read from cmux's cache (`from_cache`) within [`RECHECK_AFTER_MS`] of the guest check that passed
/// is delivered on that check (one preflight exec instead of two, cmuxterm-hq#8060). A browser
/// sign-in, or a Keychain read slow enough to have shown a prompt, checks again: the target may
/// have changed meanwhile.
pub fn recheck_guest(from_cache: bool, since_guest_check_ms: u64) -> bool {
    !from_cache || since_guest_check_ms > RECHECK_AFTER_MS
}

/// `cloud start step: NAME MS ms`: whole milliseconds, a name only, never an id, a path or a token.
pub fn line(name: &str, ms: u64) -> String {
    format!("{PREFIX}{name} {ms} ms")
}

impl Step {
    /// The step's name in its time line; an approvals step is a split of `approvals`.
    pub fn name(self) -> &'static str {
        match self {
            Step::Connect => "connect",
            Step::Login => "login",
            Step::Approvals => "approvals",
            Step::Copy => "copy",
            Step::Anchor => "anchor",
            Step::Tab => "tab",
            Step::Start => "start",
            Step::Open => "open",
            Step::DaemonStatus => "approvals.status",
            Step::KeyedRestart => "approvals.restart",
            Step::Guest => "guest",
            Step::WarmCopy => "warm-copy",
            Step::MachineLogin => "machine-login",
        }
    }

    /// The approvals' own steps, which the app runs and [`Step::Approvals`] stands for in the plan.
    fn approvals_own(self) -> bool {
        matches!(self, Step::DaemonStatus | Step::KeyedRestart)
    }
}

impl Path {
    /// Whether the path logs its step times. The machine reads do not: their time is the login's
    /// `login.machine` split, and a second clock would count it twice.
    fn logs(self) -> bool {
        self != Path::MachineReads
    }
}

/// A step of the plan and the steps it waits on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub step: Step,
    pub after: Vec<Step>,
}

fn node(step: Step, after: &[Step]) -> Node {
    Node { step, after: after.to_vec() }
}

/// The path's steps, each with the steps it waits on; steps with nothing left to wait on run together.
pub fn plan(path: Path, facts: &Facts) -> Vec<Node> {
    use Step::*;
    match path {
        Path::Session => vec![
            node(Connect, &[]),
            node(Login, &[Connect]),
            node(Approvals, &[Connect]),
            node(Anchor, &[Login, Approvals]),
            node(Tab, &[Anchor]),
            node(Start, &[Tab]),
        ],
        Path::Composer => vec![
            node(Copy, &[]),
            node(Login, &[]),
            node(Approvals, &[]),
            node(Open, &[Copy, Login, Approvals]),
        ],
        Path::Home => vec![node(Login, &[]), node(Approvals, &[]), node(Open, &[Login, Approvals])],
        Path::MachineReads => {
            let mut nodes = Vec::new();
            if facts.reads_machine {
                nodes.push(node(Guest, &[]));
                // Only Claude reads the machine's login, and only Claude's login is what a warm copies.
                if facts.claude && facts.warm_copy_conflict {
                    nodes.push(node(WarmCopy, &[]));
                    nodes.push(node(MachineLogin, &[WarmCopy]));
                } else if facts.claude {
                    nodes.push(node(MachineLogin, &[]));
                }
            }
            nodes
        }
    }
}

/// A step under way: since when, and since its last split.
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
    /// None until begun.
    pub path: Option<Path>,
    pub facts: Facts,
    pub plan: Vec<Node>,
    /// The end of the last step (or the begin): the next step's time runs from it.
    pub last: u64,
    /// The steps under way, in the order they began (with [`Step::Approvals`] for its splits).
    pub running: Vec<Running>,
    pub done: Vec<Step>,
    /// A step failed, the start was stopped or its account check failed: nothing more begins.
    pub stopping: bool,
    /// Finished: every later event is ignored.
    pub ended: bool,
}

/// One thing that happened, as the app tells it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// The start begins `path` with what it knows; a sequence under way ignores it.
    Begin {
        path: Path,
        #[serde(default)]
        facts: Facts,
    },
    /// `step` ended (a cancelled one too). `idle`: the daemon status read's answer. `still`: the
    /// app's check, as it tells this, that the account that asked is still signed in and the start
    /// not cancelled; `Some(false)` stops the start, and only `Some(true)` lets the keyed restart begin.
    Done {
        step: Step,
        #[serde(default)]
        idle: Option<bool>,
        #[serde(default)]
        still: Option<bool>,
    },
    /// A split `name` of running `step` (the login's `login.gate`, `transfer.write`, ...).
    Mark { step: Step, name: String },
    /// `step` threw: the start fails.
    Failed { step: Step },
    /// The start was cancelled, or its account changed, outside any step.
    Stop,
}

/// What the app does next.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Begin `step`, beside the steps already running; tell its end with [`Event::Done`] or [`Event::Failed`].
    Run { step: Step },
    /// One line for the app's Cloud log.
    Log { line: String },
    /// Cancel running `step`; it still tells its end, and the start ends only after it.
    Cancel { step: Step },
    /// Every step the start began has ended: it may release its gate and answer. `failed`: it threw.
    Finish { failed: bool },
}

/// The next state and the effects to run, in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub state: State,
    pub effects: Vec<Effect>,
}

/// One event at `now` (the app's monotonic clock, in milliseconds).
pub fn step(mut state: State, event: Event, now: u64) -> Answer {
    let mut effects = Vec::new();
    if !state.ended {
        match event {
            Event::Begin { path, facts } => {
                if state.path.is_none() {
                    state.plan = plan(path, &facts);
                    (state.path, state.facts, state.last) = (Some(path), facts, now);
                    begin_ready(&mut state, now, &mut effects);
                    finish_if_over(&mut state, &mut effects);
                }
            }
            Event::Done { step, idle, still } => {
                if take(&mut state, step) {
                    ended(&mut state, step, idle, still, now, &mut effects);
                }
            }
            Event::Mark { step, name } => {
                let logs = state.path.is_some_and(Path::logs);
                if let Some(run) = state.running.iter_mut().find(|run| run.step == step) {
                    if logs {
                        effects
                            .push(Effect::Log { line: line(&name, now.saturating_sub(run.split)) });
                    }
                    run.split = now;
                }
            }
            Event::Failed { step } => {
                if take(&mut state, step) {
                    stop(&mut state, &mut effects);
                }
            }
            Event::Stop => {
                if state.path.is_some() {
                    stop(&mut state, &mut effects);
                }
            }
        }
    }
    Answer { state, effects }
}

/// Removes running `step`; false when it was not running (a stray or late event).
fn take(state: &mut State, step: Step) -> bool {
    if step == Step::Approvals {
        return false;
    }
    let Some(index) = state.running.iter().position(|run| run.step == step) else { return false };
    state.running.remove(index);
    true
}

/// A step's end, once taken off the running ones.
fn ended(
    state: &mut State,
    step: Step,
    idle: Option<bool>,
    still: Option<bool>,
    now: u64,
    effects: &mut Vec<Effect>,
) {
    if state.stopping {
        return finish_if_over(state, effects);
    }
    if still == Some(false) {
        return stop(state, effects);
    }
    if step.approvals_own() {
        let logs = state.path.is_some_and(Path::logs);
        if let Some(run) = state.running.iter_mut().find(|run| run.step == Step::Approvals) {
            if logs {
                effects
                    .push(Effect::Log { line: line(step.name(), now.saturating_sub(run.split)) });
            }
            run.split = now;
        }
        // Right before the restart: an idle daemon, on the app's fresh account and cancellation check.
        if step == Step::DaemonStatus && idle == Some(true) && still == Some(true) {
            return run(state, Step::KeyedRestart, now, effects);
        }
        state.running.retain(|run| run.step != Step::Approvals);
        return completed(state, Step::Approvals, now, effects);
    }
    completed(state, step, now, effects);
}

/// A plan step done: its time line, then the steps it let begin, or the finish.
fn completed(state: &mut State, step: Step, now: u64, effects: &mut Vec<Effect>) {
    state.done.push(step);
    if state.path.is_some_and(Path::logs) {
        effects.push(Effect::Log { line: line(step.name(), now.saturating_sub(state.last)) });
    }
    state.last = now;
    begin_ready(state, now, effects);
    finish_if_over(state, effects);
}

/// Begins every plan step whose waits are done, in plan order.
fn begin_ready(state: &mut State, now: u64, effects: &mut Vec<Effect>) {
    let ready: Vec<Step> = state
        .plan
        .iter()
        .filter(|node| {
            !state.done.contains(&node.step)
                && !state.running.iter().any(|run| run.step == node.step)
                && node.after.iter().all(|after| state.done.contains(after))
        })
        .map(|node| node.step)
        .collect();
    for step in ready {
        // A held approvals step completes at once and may have begun later ones already.
        if state.done.contains(&step) || state.running.iter().any(|run| run.step == step) {
            continue;
        }
        if step == Step::Approvals {
            begin_approvals(state, now, effects);
        } else {
            run(state, step, now, effects);
        }
    }
}

/// Remote approvals on, as [`approvals`] says.
fn begin_approvals(state: &mut State, now: u64, effects: &mut Vec<Effect>) {
    match approvals(state.facts.daemon_said_safe, state.facts.holds_key) {
        Approvals::Held => completed(state, Step::Approvals, now, effects),
        how => {
            state.running.push(Running { step: Step::Approvals, since: now, split: now });
            let first =
                if how == Approvals::RestartNow { Step::KeyedRestart } else { Step::DaemonStatus };
            run(state, first, now, effects);
        }
    }
}

fn run(state: &mut State, step: Step, now: u64, effects: &mut Vec<Effect>) {
    state.running.push(Running { step, since: now, split: now });
    effects.push(Effect::Run { step });
}

/// Nothing more begins: every running step is cancelled, and the start ends once they all ended.
fn stop(state: &mut State, effects: &mut Vec<Effect>) {
    if !state.stopping {
        state.stopping = true;
        state.running.retain(|run| run.step != Step::Approvals);
        effects.extend(state.running.iter().map(|run| Effect::Cancel { step: run.step }));
    }
    finish_if_over(state, effects);
}

/// The finish, once nothing runs and either the start stopped or every plan step is done.
fn finish_if_over(state: &mut State, effects: &mut Vec<Effect>) {
    if state.ended || !state.running.is_empty() {
        return;
    }
    let all_done = state.plan.iter().all(|node| state.done.contains(&node.step));
    if state.stopping || all_done {
        state.ended = true;
        effects.push(Effect::Finish { failed: state.stopping });
    }
}

#[cfg(test)]
mod tests;
