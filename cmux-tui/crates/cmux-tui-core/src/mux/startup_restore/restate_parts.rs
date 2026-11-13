//! The restatement of the session after a daemon start, in parts.
//!
//! A start has no fold of the values that the journal states, and the restore can leave a row
//! or a journal value that is not the live tree: the open of the registry rewrites a row with
//! no journal record, a tab row outlives a terminal that ended, a stored row holds a value of
//! another session. One full projection commit mends all of that, but it holds the registry and
//! state locks for a time that grows with the session, and a person's first create after the
//! start waits behind it (or pays for it, when it comes first).
//!
//! So the daemon states the session again workspace by workspace, after it says ready, while it
//! serves: a worker commits one scoped projection for each part of at most
//! [`RESTATE_PART_WORKSPACES`] workspaces, the workspace that the person sees first. A part
//! runs no full projection. A commit of a person that comes before the part of its workspace
//! states that workspace whole in its own record (`resource_content/scoped_projection.rs`), and
//! the part then leaves it out. This does not remove the cost of the restatement: it moves it
//! out of the start and out of the first create, into short holds.
//!
//! The worker gives way: it starts no part while a locker waits for the registry (at most
//! [`RESTATE_MAX_DEFERS`] times in a row for one part), and after each part it stays away from
//! the locks for the time that part held them, so it holds them at most half of the time.
//!
//! Until its part runs, the journal can state an old value of a workspace. The last step
//! states each terminal that has no view (no workspace owns it).
//!
//! A part that is not committed (its walk met a resource that crossed its scope, or the
//! registry refused a value of the live tree as it is) keeps only its own workspace out: its
//! workspaces go back and each gets a part of its own. The workspace that is refused alone
//! stays not whole, and the next commit in it states it. The restatement goes on with the
//! others; it stops after [`RESTATE_MAX_FAILURES`] workspaces that an error kept out.
//!
//! The worker states no part while the daemon shuts down, hands off its hosts or ends
//! terminals (`journal_maintenance_paused`, the rule of the journal's maintenance worker).

use std::collections::VecDeque;
use std::sync::Weak;

use crate::mux::*;
use crate::resource::WorkspacePublicId;

/// The journal operation of one part.
pub(crate) const RESTATE_PART: &str = "session.restate-part";
/// The most workspaces that one part states.
pub(crate) const RESTATE_PART_WORKSPACES: usize = 8;
/// The most times in a row that one part stands back for a locker that waits.
pub(crate) const RESTATE_MAX_DEFERS: usize = 4;
/// The most workspaces that an error keeps out before the restatement stops with that error.
pub(crate) const RESTATE_MAX_FAILURES: usize = 8;
/// How long the worker stands back for a locker that waits.
const RESTATE_DEFER: Duration = Duration::from_millis(5);

/// The work that the restatement has left.
#[derive(Debug, Default)]
pub(crate) struct RestateParts {
    queue: PartQueue,
    /// How many times in a row the next part stood back.
    deferred: usize,
    /// Whether the step for the terminals with no view ran.
    terminals_done: bool,
    pub(crate) tally: RestateTally,
}

/// The workspaces that wait for a part.
#[derive(Debug, Default)]
struct PartQueue {
    /// The workspaces that no part has looked at, the next one first.
    pending: VecDeque<WorkspacePublicId>,
    /// How many of the next workspaces get a part of their own: the ones of a part that was
    /// not committed.
    alone: usize,
    /// The workspaces of the part that the last step walked.
    walked: Vec<WorkspacePublicId>,
}

/// What the restatement did, for the laps of the start line and for tests.
#[derive(Debug, Default, Clone)]
pub(crate) struct RestateTally {
    /// Each committed part in order: its workspaces, the values its walk stated (before the
    /// commit dropped the ones that the journal states already) and how long it held the locks.
    pub(crate) parts: Vec<RestatedPart>,
    /// From ready to the first part.
    pub(crate) wait: Duration,
    /// The time the worker stayed away from the locks between parts.
    pub(crate) pause: Duration,
    /// How many times a part stood back for a locker that waited.
    pub(crate) defers: usize,
    /// Workspaces that no part stated: the walk of the part of one met a resource that crossed
    /// its scope.
    pub(crate) skipped: usize,
    /// Workspaces (and the last step) that no part stated: the registry refused the commit of
    /// the part of one.
    pub(crate) failed: usize,
}

/// One committed part.
#[derive(Debug, Clone, Copy)]
pub(crate) struct RestatedPart {
    pub(crate) workspaces: usize,
    pub(crate) values: usize,
    pub(crate) hold: Duration,
}

impl RestateTally {
    /// The workspaces that the parts stated.
    #[cfg(test)]
    pub(crate) fn workspaces(&self) -> usize {
        self.parts.iter().map(|part| part.workspaces).sum()
    }

    /// The laps for the start line (`startup_timings.rs`, `after_ready`): the wait, each part,
    /// the pauses in one lap, and `session.restate` = the sum of the parts.
    pub(crate) fn laps(&self) -> Value {
        let ms = |took: Duration| (took.as_secs_f64() * 10_000.0).round() / 10.0;
        let mut laps = vec![serde_json::json!({"step":"session.restate.wait","ms":ms(self.wait)})];
        laps.extend(self.parts.iter().map(|part| {
            serde_json::json!({
                "step":"session.restate.part",
                "ms":ms(part.hold),
                "values":part.values,
                "workspaces":part.workspaces,
            })
        }));
        laps.push(serde_json::json!({
            "step":"session.restate.pause",
            "ms":ms(self.pause),
            "defers":self.defers,
        }));
        laps.push(serde_json::json!({
            "step":"session.restate",
            "ms":ms(self.parts.iter().map(|part| part.hold).sum()),
            "values":self.parts.iter().map(|part| part.values).sum::<usize>(),
            "parts":self.parts.len(),
            "skipped":self.skipped,
            "failed":self.failed,
        }));
        Value::Array(laps)
    }
}

/// What one call of [`Mux::restate_step`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PartStep {
    /// A part was committed; it held the locks this long.
    Stated(Duration),
    /// A locker waited for the registry, or the daemon shuts down, hands off its hosts or ends
    /// terminals: no part started.
    Deferred,
    /// No commit: the workspaces that the step looked at are whole or gone, or the part was
    /// not committed (its workspaces went back, or its one workspace stays out).
    Passed,
    /// Nothing is left.
    Done,
}

/// Why a step committed nothing.
#[derive(Debug)]
enum NoPart {
    /// Each workspace is whole or gone; no terminal with no view is owed.
    Nothing,
    /// The walk met a resource that crossed its scope.
    Escaped,
}

impl fmt::Display for NoPart {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Nothing => formatter.write_str("nothing to state"),
            Self::Escaped => formatter.write_str("the part's walk left its scope"),
        }
    }
}

impl std::error::Error for NoPart {}

#[cfg(test)]
thread_local! {
    static PARTS_HELD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Run `body` with the restatement of each mux that starts on this thread held back: no part
/// runs until the test runs them (`Mux::restate_session_in_parts`), as a daemon that a person
/// uses in the first moments after ready.
#[cfg(test)]
pub(crate) fn holding_the_parts<R>(body: impl FnOnce() -> R) -> R {
    PARTS_HELD.with(|held| held.set(true));
    let result = body();
    PARTS_HELD.with(|held| held.set(false));
    result
}

impl Mux {
    /// Start the restatement of the session (see the module text). Called one time, at the end
    /// of a start; it does not wait for the parts. A session with no workspace states nothing.
    ///
    /// In this crate's unit tests no thread starts: the parts run here, before the start
    /// returns, unless the test holds them ([`holding_the_parts`]).
    pub(in crate::mux) fn start_session_restate(self: &Arc<Self>) {
        if self.with_state(|state| state.workspaces.is_empty()) {
            return;
        }
        #[cfg(test)]
        if !PARTS_HELD.with(std::cell::Cell::get)
            && let Err(error) = self.restate_session_in_parts()
        {
            eprintln!("cmux-tui: session restate: not done: {error:#}");
        }
        #[cfg(not(test))]
        self.spawn_session_restate();
    }

    /// The worker of the restatement, on its own thread. It takes its turn after the adoptions
    /// that the start scheduled (`startup_adoption_gate.rs`): they commit under the same locks.
    pub(in crate::mux) fn spawn_session_restate(
        self: &Arc<Self>,
    ) -> Option<std::thread::JoinHandle<()>> {
        let ticket = self.startup_adoption_gate.ticket();
        let mux = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("session-restate".into())
            .spawn(move || run_session_restate(&mux, ticket))
            .inspect_err(|error| eprintln!("cmux-tui: session restate: no thread: {error}"))
            .ok()
    }

    /// The workspaces of the session for the restatement: the one that the person sees first,
    /// then the list order. One read of the state.
    pub(crate) fn session_restate_parts(&self) -> RestateParts {
        let pending = self.with_state(|state| {
            let active = state.workspaces.get(state.active_workspace);
            let rest = state
                .workspaces
                .iter()
                .enumerate()
                .filter(|(index, _)| *index != state.active_workspace)
                .map(|(_, workspace)| workspace);
            active.into_iter().chain(rest).map(|workspace| workspace.public_id.clone()).collect()
        });
        RestateParts {
            queue: PartQueue { pending, ..PartQueue::default() },
            ..RestateParts::default()
        }
    }

    /// One step of the restatement. No part starts while the daemon shuts down, hands off its
    /// hosts or ends terminals. `waiters` is the count of lockers that wait for the registry
    /// now (`SignaledMutex::waiters`): with one or more, no part starts, at most
    /// [`RESTATE_MAX_DEFERS`] times in a row. Else ONE scoped commit of the next workspaces that
    /// the fold does not hold whole, at most [`RESTATE_PART_WORKSPACES`] (one, for a workspace
    /// of a part that was not committed); after the last workspace, one commit for the
    /// terminals that have no view.
    pub(crate) fn restate_step(
        &self,
        parts: &mut RestateParts,
        waiters: usize,
    ) -> anyhow::Result<PartStep> {
        if parts.queue.pending.is_empty() && parts.terminals_done {
            return Ok(PartStep::Done);
        }
        if self.journal_maintenance_paused() {
            return Ok(PartStep::Deferred);
        }
        if waiters > 0 && parts.deferred < RESTATE_MAX_DEFERS {
            parts.deferred = parts.deferred.saturating_add(1);
            parts.tally.defers = parts.tally.defers.saturating_add(1);
            return Ok(PartStep::Deferred);
        }
        parts.deferred = 0;
        if parts.queue.pending.is_empty() {
            parts.terminals_done = true;
            parts.queue.walked.clear();
            return self.commit_restate_part(parts, |mux, registry, state, _| {
                let workspace = state
                    .workspaces
                    .get(state.active_workspace)
                    .or(state.workspaces.first())
                    .map(|workspace| workspace.public_id.clone())
                    .ok_or_else(|| anyhow::Error::new(NoPart::Nothing))?;
                mux.restate_unplaced_terminals_projection_locked(registry, state, &workspace)?
                    .ok_or_else(|| anyhow::Error::new(NoPart::Nothing))
            });
        }
        self.commit_restate_part(parts, |mux, registry, state, queue| {
            let bound = if queue.alone > 0 { 1 } else { RESTATE_PART_WORKSPACES };
            let mut part = Vec::with_capacity(bound);
            while part.len() < bound {
                let Some(workspace) = queue.pending.pop_front() else { break };
                queue.alone = queue.alone.saturating_sub(1);
                let live = state.workspaces.iter().any(|live| live.public_id == workspace);
                if live && !registry.workspace_is_whole(&workspace) {
                    part.push(workspace);
                }
            }
            loop {
                queue.walked.clone_from(&part);
                if part.is_empty() {
                    return Err(anyhow::Error::new(NoPart::Nothing));
                }
                let projection = mux
                    .restate_part_projection_locked(registry, state, &part)?
                    .ok_or_else(|| anyhow::Error::new(NoPart::Escaped))?;
                // The walk adds the stored and the live active workspace when they differ. A
                // part is never more than its bound: give the last ones back and walk again.
                let excess = projection.restated.len().saturating_sub(RESTATE_PART_WORKSPACES);
                if excess == 0 {
                    return Ok(projection);
                }
                for _ in 0..excess {
                    if let Some(workspace) = part.pop() {
                        queue.pending.push_front(workspace);
                    }
                }
            }
        })
    }

    /// Commit the projection that `walk` makes under the registry and state locks as one part.
    fn commit_restate_part(
        &self,
        parts: &mut RestateParts,
        walk: impl FnOnce(
            &Self,
            &WorkspaceRegistry,
            &mut State,
            &mut PartQueue,
        ) -> anyhow::Result<ResourceEffectProjection>,
    ) -> anyhow::Result<PartStep> {
        let mutation = WorkspaceMutation::local("cmux-tui", Actor::Daemon);
        let fingerprint =
            serde_json::json!({"operation":RESTATE_PART,"part":parts.tally.parts.len()});
        let queue = &mut parts.queue;
        let mut stated = None;
        let committed = self.commit_resource_mutation_plan(
            &mutation,
            RESTATE_PART,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let started = Instant::now();
                let projection = walk(self, registry, state, queue)?;
                let values = projection.changes.as_array().map_or(0, Vec::len);
                stated = Some((started, projection.restated.len(), values));
                // A part changes no value of the live tree: no dock rule can refuse it, and
                // the commit does not copy the state.
                Ok(resource_effects::projection_plan(projection).keeping_dock_columns())
            },
        );
        match committed {
            Ok(_) => {
                let (started, workspaces, values) =
                    stated.context("a part committed with no walk")?;
                let hold = started.elapsed();
                parts.tally.parts.push(RestatedPart { workspaces, values, hold });
                Ok(PartStep::Stated(hold))
            }
            Err(error) => match error.downcast_ref::<NoPart>() {
                Some(NoPart::Nothing) => Ok(PartStep::Passed),
                Some(NoPart::Escaped) => Self::part_not_committed(parts, error, true),
                None => Self::part_not_committed(parts, error, false),
            },
        }
    }

    /// A part that was not committed: `escaped` when its walk met a resource that crossed its
    /// scope, else the registry refused it (a value of the live tree that the store does not
    /// take as it is). The workspaces of a part of 2 or more go back to the front and each gets
    /// a part of its own, so that only the workspace that the cause is about stays out. A part
    /// of one is counted and its workspace stays not whole: the next commit in it states it.
    /// The error comes back after [`RESTATE_MAX_FAILURES`] workspaces that an error kept out
    /// (a registry that takes no commit refuses each part).
    fn part_not_committed(
        parts: &mut RestateParts,
        error: anyhow::Error,
        escaped: bool,
    ) -> anyhow::Result<PartStep> {
        let walked = std::mem::take(&mut parts.queue.walked);
        if walked.len() > 1 {
            parts.queue.alone = walked.len();
            for workspace in walked.into_iter().rev() {
                parts.queue.pending.push_front(workspace);
            }
            return Ok(PartStep::Passed);
        }
        if escaped {
            parts.tally.skipped = parts.tally.skipped.saturating_add(1);
        } else {
            parts.tally.failed = parts.tally.failed.saturating_add(1);
            if parts.tally.failed > RESTATE_MAX_FAILURES {
                return Err(error);
            }
        }
        eprintln!("cmux-tui: session restate: a part was not stated: {error:#}");
        Ok(PartStep::Passed)
    }

    /// Each step of the restatement at once, with no locker that waits and no pause: what the
    /// worker does, for this crate's unit tests. It ends early on a daemon that shuts down,
    /// hands off its hosts or ends terminals (the worker waits there).
    #[cfg(test)]
    pub(crate) fn restate_session_in_parts(&self) -> anyhow::Result<RestateTally> {
        let mut parts = self.session_restate_parts();
        while !matches!(self.restate_step(&mut parts, 0)?, PartStep::Done | PartStep::Deferred) {}
        self.record_session_restate(&parts.tally);
        Ok(parts.tally)
    }
}

/// The worker: wait for ready as a start's adoptions do (ready, or the release of the start's
/// adoptions, or their wait limit with no ready), take the turn after them, then one step at a
/// time. It holds the mux for a step and for its wait at the adoption gate (as each adoption of
/// a start does), not while it sleeps, so a mux that its owner dropped ends it.
fn run_session_restate(mux: &Weak<Mux>, ticket: startup_adoption_gate::Ticket) {
    let started = Instant::now();
    loop {
        let Some(mux) = mux.upgrade() else { return };
        if mux.shutting_down.load(Ordering::Acquire) {
            return;
        }
        if mux.server_lifecycle_ready()
            || mux.startup_adoptions_released.load(Ordering::Acquire)
            || started.elapsed() >= terminal_adoption::STARTUP_READY_WAIT
        {
            break;
        }
        drop(mux);
        std::thread::sleep(RESTATE_DEFER);
    }
    let ready = Instant::now();
    let mut parts = {
        let Some(mux) = mux.upgrade() else { return };
        let gate = mux.startup_adoption_gate.clone();
        let turn = gate.turn(ticket, || mux.shutting_down.load(Ordering::Acquire));
        if turn.is_none() {
            return;
        }
        drop(turn);
        mux.session_restate_parts()
    };
    loop {
        let Some(mux) = mux.upgrade() else { return };
        if mux.shutting_down.load(Ordering::Acquire) {
            return;
        }
        if parts.tally.parts.is_empty() {
            parts.tally.wait = ready.elapsed();
        }
        let step = mux.restate_step(&mut parts, mux.workspace_registry.waiters());
        let pause = match step {
            // RED ARM, NOT FOR MERGE: the pause of a committed part is taken out.
            Ok(PartStep::Stated(_)) => Duration::ZERO,
            Ok(PartStep::Deferred) => RESTATE_DEFER,
            Ok(PartStep::Passed) => Duration::ZERO,
            Ok(PartStep::Done) => {
                mux.record_session_restate(&parts.tally);
                return;
            }
            Err(error) => {
                eprintln!("cmux-tui: session restate: stopped: {error:#}");
                mux.record_session_restate(&parts.tally);
                return;
            }
        };
        drop(mux);
        if !pause.is_zero() {
            std::thread::sleep(pause);
            parts.tally.pause = parts.tally.pause.saturating_add(pause);
        }
    }
}
