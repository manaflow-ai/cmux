//! A creation's run (the app's `CloudCreationFlow`): create the machine (unless it exists), start
//! its bootstrap, wait for its daemon's real ready event, open its first workspace, then hand that
//! workspace to the window. The app runs each await (the create, the waits, the open); this says
//! which comes next and how a run that threw ends. Also the account scope a person's create keeps
//! (`CloudHandlers.checkCreationScope`) and the signed-out creation's sign-in continuation
//! (`CloudSignedOutCreationContinuation`).

use serde::{Deserialize, Serialize};

use super::creation::{Creation, Creations, Effects, Event, ProRefusal, RefusalSource};

/// How long a failed creation no window shows stays listed (as failed, with its reason) before it
/// ends (`failedRowLingers`).
pub const FAILED_ROW_LINGERS_MS: u64 = 300_000;

/// What a window does when a creation starts in it (`start`): its page goes and it shows the
/// creation at once, before any await, so the click focuses the new work.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shown {
    pub clear_page: bool,
    pub cloud_creation: String,
}

/// Starts creation `creation` (listed at once) in `window` when one asked. What the window shows.
pub fn start(creations: &mut Creations, creation: Creation) -> Option<Shown> {
    let shown = creation
        .window_id
        .is_some()
        .then(|| Shown { clear_page: true, cloud_creation: creation.id.clone() });
    creations.begin(creation);
    shown
}

/// Retry: the run stops, the clock starts again, and the app retries the session (if any) and runs
/// again.
pub fn retry(creation: &mut Creation, now_ms: u64) -> Effects {
    creation.apply(Event::Restart { now_ms });
    Effects { cancel_run: true, ..Effects::default() }
}

/// Dismiss (a failed creation): the row and the view go; a created machine stays in the sidebar
/// with its own status. What the app cancels, and whether the window (showing `shown`) stops
/// showing it.
pub fn dismiss(
    creations: &mut Creations,
    id: &str,
    shown: Option<&str>,
) -> (Option<Effects>, bool) {
    (creations.end(id), shown == Some(id))
}

/// A run's steps before the ready wait: create the machine (none when the creation started with
/// one; the new session is then attached), then run the bootstrap hook while it has work
/// (`needs_bootstrap`, `create_flow::bootstrap_needs`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunPlan {
    pub create: bool,
    pub bootstrap: bool,
}

/// The run's plan for `creation` as it starts (`has_session`) and after its create
/// (`needs_bootstrap`, read once the session is attached).
pub fn run_plan(has_session: bool, needs_bootstrap: bool) -> RunPlan {
    RunPlan { create: !has_session, bootstrap: needs_bootstrap }
}

/// What a run threw.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "error")]
pub enum RunError {
    /// A `CancellationError`.
    Cancelled,
    /// The person said no in the confirmation (`CloudMachineCreateFlow.Failure.declined`).
    Declined,
    /// Any other error: its words and its paid plan.
    Failed { message: String, source: RefusalSource },
}

/// How a run that threw ends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "end")]
pub enum RunEnd {
    /// Nothing more: cancelled.
    Return,
    /// The creation closes quietly (its window shows what it showed before): `Creations::remove`.
    Remove,
    /// The creation shows its failure. `offer`: the paid plan to offer the person; `linger_ms`: a
    /// creation no window shows ends after this long, unless a Retry, Dismiss or its machine's
    /// removal cancel the wait first (then [`linger_ends`]).
    #[serde(rename_all = "camelCase")]
    Failed {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        offer: Option<ProRefusal>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        linger_ms: Option<u64>,
    },
}

/// A run of `creation` threw `error` (`task_cancelled`: its task was cancelled meanwhile). A
/// failure is noted on the creation; only a person's own gesture (`started_by_person`) is offered
/// the plan (an agent's or the CLI's create fails with the plan, which the caller offers).
pub fn run_ended(
    creation: &mut Creation,
    error: RunError,
    task_cancelled: bool,
    started_by_person: bool,
) -> RunEnd {
    match error {
        RunError::Cancelled => RunEnd::Return,
        RunError::Declined => RunEnd::Remove,
        RunError::Failed { .. } if task_cancelled => RunEnd::Return,
        RunError::Failed { message, source } => {
            creation.apply(Event::Fail { message, source });
            let offer = creation.plan_refusal.clone().filter(|_| started_by_person);
            // A creation no window shows (a CLI's, an agent's) has nobody to Retry or Dismiss it:
            // `cloud list-machines` shows it failed for a while, then it ends.
            let linger_ms = creation.window_id.is_none().then_some(FAILED_ROW_LINGERS_MS);
            RunEnd::Failed { offer, linger_ms }
        }
    }
}

/// After a windowless failure's linger: whether the creation ends now (still failed, and the wait
/// was not cancelled).
pub fn linger_ends(creation: &Creation, task_cancelled: bool) -> bool {
    !task_cancelled && creation.phase.is_failed()
}

/// Where the bootstrap hook (`startBootstrap`) is: after its machine runs, or after the script's
/// start.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BootstrapAt {
    Running,
    ScriptStarted,
}

/// The bootstrap hook's next step.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BootstrapStep {
    /// Nothing more (cancelled, torn down, or no work left): a Retry starts what is left.
    Stop,
    /// `Event::BeginBootstrapAttempt`, start the script, then `Event::BootstrapStarted`.
    StartScript,
    /// Apply the machine config, then `Event::MachineConfig`. After the script's start: the
    /// applier waits for its lock, so a `--repo` clone is there first.
    ApplyConfig,
}

/// The bootstrap hook's next step at `at`. `needs_script`/`needs_machine_config` are
/// `create_flow::bootstrap_needs`'s for the creation as it is now.
pub fn bootstrap_step(
    creation: &Creation,
    at: BootstrapAt,
    task_cancelled: bool,
    needs_script: bool,
    needs_machine_config: bool,
) -> BootstrapStep {
    if task_cancelled || creation.torn_down {
        return BootstrapStep::Stop;
    }
    match at {
        BootstrapAt::Running if needs_script => BootstrapStep::StartScript,
        _ if needs_machine_config => BootstrapStep::ApplyConfig,
        _ => BootstrapStep::Stop,
    }
}

/// Whether a person's create still belongs to the account and team it started in: false ends the
/// creation and cancels its run (`checkCreationScope`).
pub fn scope_holds(
    expected_user: Option<&str>,
    current_user: Option<&str>,
    expected_team: Option<&str>,
    current_team: Option<&str>,
) -> bool {
    expected_user.is_some() && expected_user == current_user && expected_team == current_team
}

/// One person-initiated creation while hosted Cloud sign-in is pending: replacement, sign-out and
/// policy changes invalidate the previous generation (`CloudSignedOutCreationContinuation`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Continuation {
    pub generation: u64,
    #[serde(default)]
    pub pending: Option<u64>,
}

/// How a sign-in the continuation awaited ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SignedIn {
    /// Another generation took over meanwhile: nothing.
    Stale,
    /// The sign-in failed or its waiter was cancelled: the creation is dropped.
    Dropped,
    /// Replay the creation (consumed first: a replay may itself start another intent).
    Resume,
}

impl Continuation {
    /// Reserves one replay generation, before an action hands its sign-in work off.
    pub fn reserve(&mut self) -> u64 {
        self.cancel();
        self.pending = Some(self.generation);
        self.generation
    }

    fn holds(&self, expected: u64) -> bool {
        self.pending == Some(expected) && self.generation == expected
    }

    /// Before the sign-in: whether `expected` may go on to sign in. A stale or cancelled one is
    /// cancelled (only if it is still the current one).
    pub fn begin(&mut self, expected: u64, cancelled: bool) -> bool {
        if self.holds(expected) && !cancelled {
            return true;
        }
        self.cancel_expected(expected);
        false
    }

    /// After the sign-in of `expected` answered `succeeded` (`cancelled`: its waiter was).
    pub fn finish(&mut self, expected: u64, succeeded: bool, cancelled: bool) -> SignedIn {
        if !self.holds(expected) {
            return SignedIn::Stale;
        }
        self.pending = None;
        self.generation += 1;
        if succeeded && !cancelled { SignedIn::Resume } else { SignedIn::Dropped }
    }

    pub fn cancel(&mut self) {
        self.generation += 1;
        self.pending = None;
    }

    /// Cancels `expected` only while it is the pending one.
    pub fn cancel_expected(&mut self, expected: u64) {
        if self.holds(expected) {
            self.cancel();
        }
    }

    pub fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    /// The account scope changed while a sign-in is pending; `survives` is
    /// `cloud_auth_creation_scope`'s answer (none from the FFI counts as false: never replay across
    /// accounts).
    pub fn scope_changed(&mut self, survives: bool) {
        if self.is_pending() && !survives {
            self.cancel();
        }
    }
}

#[cfg(test)]
#[path = "flow_tests.rs"]
mod tests;
