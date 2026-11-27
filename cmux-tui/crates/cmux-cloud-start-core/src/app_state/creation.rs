//! One New Cloud Workspace (or New Cloud Machine) from the click to its open terminal (cx-lu8f;
//! the app's `CloudMachineCreation` and `CloudCreations`). A creation exists before any request
//! goes out, so the window shows it and the sidebar lists its row at once. The app keeps the
//! creation's tasks (its run, its bootstrap wait), its session object and its request; this keeps
//! the rest of its state and says how each event changes it.
//!
//! A creation's request bookkeeping (its idempotency key, approvals) is
//! `create_flow::change_key`'s, and whether a bootstrap or machine config still has work is
//! `create_flow::bootstrap_needs`'s.

use serde::{Deserialize, Serialize};

use crate::machine_bootstrap::{self, Outcome, Run};

/// The sidebar row id's prefix while a creation has no workspace: never a daemon id.
pub const ROW_PREFIX: &str = "cloud-creation:";

/// Creation `id`'s sidebar row id (its UUID in lowercase after [`ROW_PREFIX`]).
pub fn row_id(id: &str) -> String {
    format!("{ROW_PREFIX}{}", id.to_lowercase())
}

/// The create call's phase; `created` once the machine exists (or for an existing machine that is
/// not connected yet).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "phase")]
pub enum Phase {
    Requesting,
    Creating,
    Created,
    /// The failure's text, as the person reads it.
    Failed {
        message: String,
    },
}

impl Phase {
    /// A new attempt's phase: `created` for a creation that has its machine's session.
    pub fn initial(has_session: bool) -> Self {
        if has_session { Self::Created } else { Self::Requesting }
    }

    pub fn is_failed(&self) -> bool {
        matches!(self, Self::Failed { .. })
    }
}

/// What a create refused for a paid plan tells the person: the server's text, its upgrade link,
/// and the plan that lifts it (`pro` or `max`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProRefusal {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_url: Option<String>,
    pub plan: String,
    /// The app already showed its own upgrade card (the plan gate): no second offer.
    #[serde(default)]
    pub offered: bool,
}

/// The kind of error a create failed with, as far as a paid plan goes (the app reads its error
/// types into this).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum RefusalSource {
    /// The legacy `/api/vm` refusal that names a plan (`CloudAPIError.planRequired`).
    #[serde(rename_all = "camelCase")]
    PlanRequired {
        #[serde(default)]
        message: Option<String>,
        #[serde(default)]
        upgrade_url: Option<String>,
        plan: String,
    },
    /// The app's own free-plan gate refused before any request (`upgradeRequired(.freePlan)`).
    FreePlanGate,
    /// The app server's `plan_required`, with its `details.plan` when it has one.
    AppServerPlanRequired {
        #[serde(default)]
        plan: Option<String>,
    },
    /// Any other error: no paid plan lifts it.
    Other,
}

/// The paid plan `source` needs, if any (`CloudMachineCreation.proRefusal`).
pub fn pro_refusal(source: &RefusalSource) -> Option<ProRefusal> {
    match source {
        RefusalSource::PlanRequired { message, upgrade_url, plan } => Some(ProRefusal {
            message: message.clone(),
            upgrade_url: upgrade_url.clone(),
            plan: plan.clone(),
            offered: false,
        }),
        // A person's create already showed its card, and an agent's shows none (the agent reports
        // the refusal), so no second offer either way.
        RefusalSource::FreePlanGate => {
            Some(ProRefusal { message: None, upgrade_url: None, plan: "pro".into(), offered: true })
        }
        // The app server's message is the backend's English text, not the person's language: the
        // dialog's own copy stands in.
        RefusalSource::AppServerPlanRequired { plan } => Some(ProRefusal {
            message: None,
            upgrade_url: None,
            plan: if plan.as_deref() == Some("max") { "max" } else { "pro" }.into(),
            offered: false,
        }),
        RefusalSource::Other => None,
    }
}

/// Why a bootstrap failed, before it becomes the person's words (`CloudStrings.bootstrap*`, which
/// stay in the app with its localization). `log` is the run's log on the machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "why")]
pub enum FailReason {
    /// The start itself failed (`bootstrapStartFailed`), with the start's reason (empty: none).
    StartFailed {
        reason: String,
    },
    NeedsGitHub {
        repo: String,
    },
    RepoFailed {
        repo: String,
        log: String,
    },
    #[serde(rename_all = "camelCase")]
    ScriptFailed {
        exit_code: i64,
        log: String,
    },
    RunnerNeverCame,
    Stopped {
        log: String,
    },
    StillRunning {
        log: String,
    },
    Unreachable {
        error: String,
    },
}

/// How a started bootstrap ended: the New Cloud Workspace wizard opens its project at `finished`'s
/// `repo_path`, or shows `failed`'s reason.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "end")]
pub enum Completion {
    #[serde(rename_all = "camelCase")]
    Finished {
        #[serde(default)]
        repo_path: Option<String>,
    },
    Failed {
        reason: FailReason,
    },
}

/// The end of the run a start began (`CloudMachineBootstrap.completion`).
pub fn completion(run: &Run) -> Completion {
    let log = machine_bootstrap::log_path;
    let reason = match run {
        Run::Finished { repo_path } => {
            return Completion::Finished { repo_path: repo_path.clone() };
        }
        Run::NeedsGitHub { repo } => FailReason::NeedsGitHub { repo: repo.clone() },
        Run::RepoFailed { repo } => FailReason::RepoFailed { repo: repo.clone(), log: log() },
        Run::ScriptFailed { exit_code } => {
            FailReason::ScriptFailed { exit_code: *exit_code, log: log() }
        }
        Run::RunnerNeverCame => FailReason::RunnerNeverCame,
        Run::Stopped => FailReason::Stopped { log: log() },
        Run::StillRunning => FailReason::StillRunning { log: log() },
        Run::Unreachable { error } => FailReason::Unreachable { error: error.clone() },
    };
    Completion::Failed { reason }
}

/// One creation's state, as the app's `CloudMachineCreation` keeps it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Creation {
    /// The creation's UUID.
    pub id: String,
    /// The window that shows it (none: no window asked, e.g. the CLI).
    #[serde(default)]
    pub window_id: Option<String>,
    /// The machine's session's machine id, once the creation has one.
    #[serde(default)]
    pub machine_id: Option<String>,
    #[serde(default)]
    pub has_session: bool,
    pub phase: Phase,
    /// When this attempt started (the click, or the last Retry).
    pub started_at_ms: u64,
    /// Time from the attempt's start to `ready`.
    #[serde(default)]
    pub ready_after_ms: Option<u64>,
    /// The workspace that opened when the machine was ready.
    #[serde(default)]
    pub workspace_id: Option<String>,
    /// The paid plan the last failure needs, for a CLI or agent caller's answer.
    #[serde(default)]
    pub plan_refusal: Option<ProRefusal>,
    /// How the requested bootstrap started; none without one.
    #[serde(default)]
    pub bootstrap: Option<Outcome>,
    /// How the started bootstrap ended: none until it finishes (if `torn_down` turns true first, it
    /// never will).
    #[serde(default)]
    pub bootstrap_completion: Option<Completion>,
    /// The bootstrap start in flight: a start that returns after a newer one began changes nothing.
    #[serde(default)]
    pub bootstrap_attempt: u64,
    /// The bootstrap wait runs (the app's `completionTask`).
    #[serde(default)]
    pub waiting: bool,
    /// The creation ended for good: the bootstrap wait stopped, and a late start starts none.
    #[serde(default)]
    pub torn_down: bool,
    /// How the requested machine config's apply started.
    #[serde(default)]
    pub machine_config: Option<Outcome>,
}

/// An event on one creation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "event")]
pub enum Event {
    /// The create call reached `phase` (`note`).
    Note {
        phase: Phase,
    },
    /// The server returned the machine's session (`attach`).
    #[serde(rename_all = "camelCase")]
    Attach {
        machine_id: String,
    },
    /// The create failed with `message` (the person's words for it) and `source`'s paid plan.
    Fail {
        message: String,
        source: RefusalSource,
    },
    #[serde(rename_all = "camelCase")]
    MarkReady {
        now_ms: u64,
    },
    #[serde(rename_all = "camelCase")]
    Opened {
        workspace_id: String,
    },
    /// A new attempt (Retry): the clock starts again.
    #[serde(rename_all = "camelCase")]
    Restart {
        now_ms: u64,
    },
    /// A new bootstrap start, before it is sent: the last one's wait stops and its completion goes.
    BeginBootstrapAttempt,
    /// The start of `attempt` answered `outcome`.
    BootstrapStarted {
        outcome: Outcome,
        attempt: u64,
    },
    /// The wait `attempt`'s start began ended with `completion`.
    BootstrapCompleted {
        completion: Completion,
        attempt: u64,
    },
    MachineConfig {
        outcome: Outcome,
    },
    /// The creation ends for good (dismissed, or its machine deleted).
    TearDown,
}

/// What the app does after an event.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Effects {
    /// Cancel the creation's run (its `task`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cancel_run: bool,
    /// Cancel the bootstrap wait (its `completionTask`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cancel_wait: bool,
    /// Start the bootstrap wait for this attempt (`BootstrapStarted`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_wait: Option<u64>,
    /// The attempt number `BeginBootstrapAttempt` handed out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempt: Option<u64>,
}

impl Creation {
    /// A creation listed at once, with its machine's session when the machine exists.
    pub fn new(
        id: String,
        window_id: Option<String>,
        machine_id: Option<String>,
        now_ms: u64,
    ) -> Self {
        let has_session = machine_id.is_some();
        Self {
            id,
            window_id,
            machine_id,
            has_session,
            phase: Phase::initial(has_session),
            started_at_ms: now_ms,
            ready_after_ms: None,
            workspace_id: None,
            plan_refusal: None,
            bootstrap: None,
            bootstrap_completion: None,
            bootstrap_attempt: 0,
            waiting: false,
            torn_down: false,
            machine_config: None,
        }
    }

    pub fn row_id(&self) -> String {
        row_id(&self.id)
    }

    /// Time since the attempt started, or until it was ready.
    pub fn elapsed_ms(&self, now_ms: u64) -> u64 {
        self.ready_after_ms.unwrap_or_else(|| now_ms.saturating_sub(self.started_at_ms))
    }

    /// Applies `event`; what the app does next.
    pub fn apply(&mut self, event: Event) -> Effects {
        let mut effects = Effects::default();
        match event {
            Event::Note { phase } => self.phase = phase,
            Event::Attach { machine_id } => {
                self.machine_id = Some(machine_id);
                self.has_session = true;
                self.phase = Phase::Created;
            }
            Event::Fail { message, source } => {
                // Before the phase: a caller that observes the failure reads the plan with it.
                self.plan_refusal = pro_refusal(&source);
                self.phase = Phase::Failed { message };
            }
            Event::MarkReady { now_ms } => {
                if self.ready_after_ms.is_none() {
                    self.ready_after_ms = Some(now_ms.saturating_sub(self.started_at_ms));
                }
            }
            Event::Opened { workspace_id } => self.workspace_id = Some(workspace_id),
            Event::Restart { now_ms } => {
                self.started_at_ms = now_ms;
                self.ready_after_ms = None;
                self.plan_refusal = None;
                self.phase = Phase::initial(self.has_session);
            }
            Event::BeginBootstrapAttempt => {
                effects.cancel_wait = self.waiting;
                self.waiting = false;
                self.bootstrap_completion = None;
                self.bootstrap_attempt += 1;
                effects.attempt = Some(self.bootstrap_attempt);
            }
            Event::BootstrapStarted { outcome, attempt } => {
                if self.torn_down || attempt != self.bootstrap_attempt {
                    return effects;
                }
                let failed = (outcome.status == "failed").then(|| outcome.reason.clone());
                self.bootstrap = Some(outcome);
                if let Some(reason) = failed {
                    let reason = reason.unwrap_or_default();
                    self.bootstrap_completion =
                        Some(Completion::Failed { reason: FailReason::StartFailed { reason } });
                } else {
                    self.waiting = true;
                    effects.start_wait = Some(attempt);
                }
            }
            Event::BootstrapCompleted { completion, attempt } => {
                // The app cancels a stale wait; one that answers anyway changes nothing.
                if self.waiting && !self.torn_down && attempt == self.bootstrap_attempt {
                    self.waiting = false;
                    self.bootstrap_completion = Some(completion);
                }
            }
            Event::MachineConfig { outcome } => self.machine_config = Some(outcome),
            Event::TearDown => {
                self.torn_down = true;
                effects.cancel_run = true;
                effects.cancel_wait = self.waiting;
                self.waiting = false;
            }
        }
        effects
    }
}

/// The creations in flight (`CloudService.creations`), for every window's progress view and
/// sidebar row, oldest first.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Creations {
    #[serde(default)]
    pub all: Vec<Creation>,
}

impl Creations {
    /// A new creation, listed at once.
    pub fn begin(&mut self, creation: Creation) -> &mut Creation {
        self.all.push(creation);
        let last = self.all.len() - 1;
        &mut self.all[last]
    }

    pub fn creation(&self, id: &str) -> Option<&Creation> {
        self.all.iter().find(|creation| creation.id == id)
    }

    pub fn creation_mut(&mut self, id: &str) -> Option<&mut Creation> {
        self.all.iter_mut().find(|creation| creation.id == id)
    }

    /// The creation of sidebar row `row`: none for a row without [`ROW_PREFIX`].
    pub fn by_row(&self, row: &str) -> Option<&Creation> {
        if !row.starts_with(ROW_PREFIX) {
            return None;
        }
        self.all.iter().find(|creation| creation.row_id() == row)
    }

    /// Whether `workspace_id` is the opened workspace of the creation a window shows (`shown`):
    /// showing it keeps the creation view until it is mirrored.
    pub fn opens(&self, workspace_id: Option<&str>, shown: Option<&str>) -> bool {
        let (Some(workspace_id), Some(shown)) = (workspace_id, shown) else { return false };
        self.creation(shown).and_then(|creation| creation.workspace_id.as_deref())
            == Some(workspace_id)
    }

    /// The creations window `window_id` lists, oldest first.
    pub fn shown_in(&self, window_id: &str) -> Vec<&Creation> {
        self.all
            .iter()
            .filter(|creation| creation.window_id.as_deref() == Some(window_id))
            .collect()
    }

    /// The row leaves (its workspace is mirrored, or the person declined): its run stops, and a
    /// bootstrap wait goes on for whoever still holds the creation. The creation, if it was listed.
    pub fn remove(&mut self, id: &str) -> Option<Creation> {
        let index = self.all.iter().position(|creation| creation.id == id)?;
        Some(self.all.remove(index))
    }

    /// The creation ends for good: the row leaves and every wait of it stops. What the app cancels.
    pub fn end(&mut self, id: &str) -> Option<Effects> {
        let mut creation = self.remove(id)?;
        Some(creation.apply(Event::TearDown))
    }

    /// The machine was deleted or left the list: its creations end. Their ids and what the app
    /// cancels for each.
    pub fn machine_removed(&mut self, machine_id: &str) -> Vec<(String, Effects)> {
        let ids: Vec<String> = self
            .all
            .iter()
            .filter(|creation| creation.machine_id.as_deref() == Some(machine_id))
            .map(|creation| creation.id.clone())
            .collect();
        ids.into_iter().filter_map(|id| self.end(&id).map(|effects| (id, effects))).collect()
    }
}

#[cfg(test)]
#[path = "creation_tests.rs"]
mod tests;
