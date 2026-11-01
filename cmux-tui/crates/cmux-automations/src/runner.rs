//! The runner's tick: due times become run rows, rows become processes.

use crate::catch_up::{CatchUp, plan_fires};
use crate::run::{Run, RunState, manual_run_id, run_id};
use crate::store::{Store, StoreError};
use crate::trigger::Trigger;

/// What an executor starts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Job {
    pub automation: String,
    pub run: String,
    pub scheduled_at: Option<i64>,
    pub late_seconds: i64,
}

/// Starts runs. The real one ([`crate::exec::ProcessExecutor`]) spawns
/// `cmux automation _exec`; tests record.
pub trait Executor {
    /// Start the job; the process id it runs as.
    fn start(&mut self, job: &Job) -> Result<u32, String>;
    /// Whether that process still runs.
    fn is_alive(&self, pid: u32) -> bool;
}

/// How a run's process ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExecOutcome {
    Exited { code: i32 },
    Signaled { signal: i32 },
    TimedOut,
    Error(String),
}

/// What one tick did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TickReport {
    /// Run ids started.
    pub started: Vec<String>,
    /// Run rows recorded as skipped.
    pub skipped: usize,
    /// Automations whose schedule could not be read, with the reason.
    pub errors: Vec<(String, String)>,
}

fn start_run(
    store: &Store,
    mut run: Run,
    now: i64,
    exec: &mut dyn Executor,
) -> Result<(), StoreError> {
    let job = Job {
        automation: run.automation.clone(),
        run: run.id.clone(),
        scheduled_at: run.scheduled_at,
        late_seconds: run.late_seconds,
    };
    run.started_at = Some(now);
    run.runner = crate::sys::hostname();
    match exec.start(&job) {
        Ok(pid) => {
            run.state = RunState::Running;
            run.pid = Some(pid);
        }
        Err(why) => {
            run.state = RunState::Failed;
            run.reason = Some(format!("start_failed: {why}"));
            run.finished_at = Some(now);
        }
    }
    store.put_run(&run)
}

fn busy(runs: &[Run], exec: &dyn Executor) -> bool {
    runs.iter().any(|r| match r.state {
        RunState::Queued => true,
        RunState::Running => r.pid.is_some_and(|p| exec.is_alive(p)),
        _ => false,
    })
}

/// One pass over every enabled automation at `now`.
pub fn tick(store: &Store, now: i64, exec: &mut dyn Executor) -> Result<TickReport, StoreError> {
    let mut report = TickReport::default();
    for a in store.list()? {
        if !a.enabled {
            continue;
        }
        let since = store.state(&a.id)?.handled_through;
        let plan = match plan_fires(&a.trigger, since, now, a.catch_up) {
            Ok(plan) => plan,
            Err(e) => {
                report.errors.push((a.id.clone(), e.0));
                continue;
            }
        };
        let row = |t: i64, state: RunState, reason: Option<String>| Run {
            id: run_id(&a.id, t),
            automation: a.id.clone(),
            trigger: "schedule".into(),
            scheduled_at: Some(t),
            state,
            reason,
            created_at: now,
            started_at: None,
            finished_at: (state == RunState::Skipped).then_some(now),
            late_seconds: (now - t).max(0),
            pid: None,
            runner: None,
            exit_code: None,
            version: a.version,
        };
        for (t, why) in &plan.skipped {
            if store.insert_run(&row(*t, RunState::Skipped, Some(why.clone())))? {
                report.skipped += 1;
            }
        }
        let queue_all = matches!(a.catch_up, CatchUp::All { .. });
        for &t in &plan.run {
            let history = store.runs(&a.id)?;
            if history.iter().any(|r| r.id == run_id(&a.id, t)) {
                continue;
            }
            if busy(&history, exec) && !queue_all {
                if store.insert_run(&row(
                    t,
                    RunState::Skipped,
                    Some("previous_run_running".into()),
                ))? {
                    report.skipped += 1;
                }
            } else {
                store.insert_run(&row(t, RunState::Queued, None))?;
            }
        }
        store.set_handled_through(&a.id, plan.handled_through)?;
        // Start the oldest queued run when none is running.
        let history = store.runs(&a.id)?;
        let running = history
            .iter()
            .any(|r| r.state == RunState::Running && r.pid.is_some_and(|p| exec.is_alive(p)));
        if !running && let Some(next) = history.into_iter().find(|r| r.state == RunState::Queued) {
            let id = next.id.clone();
            start_run(store, next, now, exec)?;
            report.started.push(id);
        }
        if matches!(a.trigger, Trigger::At { .. })
            && a.trigger.next_after(now).ok().flatten().is_none()
        {
            store.set_enabled(&a.id, false, now)?;
        }
    }
    Ok(report)
}

/// Start a manual run. The same `key` names the same run, so a retried
/// command starts it once. Returns the run id.
pub fn start_manual(
    store: &Store,
    automation: &str,
    key: &str,
    now: i64,
    exec: &mut dyn Executor,
) -> Result<String, StoreError> {
    let a = store.get(automation)?;
    let run = Run {
        id: manual_run_id(&a.id, key),
        automation: a.id.clone(),
        trigger: "manual".into(),
        scheduled_at: None,
        state: RunState::Queued,
        reason: None,
        created_at: now,
        started_at: None,
        finished_at: None,
        late_seconds: 0,
        pid: None,
        runner: None,
        exit_code: None,
        version: a.version,
    };
    let id = run.id.clone();
    if store.insert_run(&run)? {
        start_run(store, run, now, exec)?;
    }
    Ok(id)
}

/// Record how a run ended.
pub fn finish(
    store: &Store,
    automation: &str,
    run: &str,
    outcome: ExecOutcome,
    now: i64,
) -> Result<(), StoreError> {
    let Some(mut r) = store.run(automation, run)? else {
        return Err(StoreError::NotFound(run.into()));
    };
    let (state, reason, code) = match outcome {
        ExecOutcome::Exited { code: 0 } => (RunState::Succeeded, None, Some(0)),
        ExecOutcome::Exited { code } => {
            (RunState::Failed, Some(format!("exit_{code}")), Some(code))
        }
        ExecOutcome::Signaled { signal } => {
            (RunState::Failed, Some(format!("signal_{signal}")), None)
        }
        ExecOutcome::TimedOut => (RunState::Failed, Some("timeout".into()), None),
        ExecOutcome::Error(why) => (RunState::Failed, Some(format!("error: {why}")), None),
    };
    r.state = state;
    r.reason = reason;
    r.exit_code = code;
    r.finished_at = Some(now);
    store.put_run(&r)
}

/// After a runner (re)starts: a `running` row whose process is gone failed
/// with `runner_died`. It is never re-run by itself, because its agent may
/// have done part of the work. Returns how many rows were fixed.
pub fn recover_orphans(
    store: &Store,
    now: i64,
    exec: &mut dyn Executor,
) -> Result<usize, StoreError> {
    let mut fixed = 0;
    for a in store.list()? {
        for mut r in store.runs(&a.id)? {
            if r.state == RunState::Running && !r.pid.is_some_and(|p| exec.is_alive(p)) {
                r.state = RunState::Failed;
                r.reason = Some("runner_died".into());
                r.finished_at = Some(now);
                store.put_run(&r)?;
                fixed += 1;
            }
        }
    }
    Ok(fixed)
}
