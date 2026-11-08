//! The runner's tick: due times become run rows, rows become processes.

use crate::catch_up::{CatchUp, plan_fires};
use crate::gate::{Gate, Verdict, clip_event, verdict};
use crate::run::{Run, RunState, event_run_id, manual_run_id, run_id};
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
    Exited {
        code: i32,
    },
    Signaled {
        signal: i32,
    },
    TimedOut,
    Error(String),
    /// The body never ran: the condition said no (`condition_false`).
    Skipped {
        reason: String,
    },
    /// The body never ran: the condition failed (`condition_exit_N`,
    /// `condition_timeout`).
    Refused {
        reason: String,
    },
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

/// The guardrails' verdict on a fire of `a` at `now`.
pub fn gate_verdict(
    store: &Store,
    a: &crate::automation::Automation,
    now: i64,
    exec: &dyn Executor,
) -> Result<Verdict, StoreError> {
    let history = store.runs(&a.id)?;
    Ok(verdict(&a.gate, &history, now, &|pid| exec.is_alive(pid)))
}

/// One pass over every enabled automation at `now`.
pub fn tick(store: &Store, now: i64, exec: &mut dyn Executor) -> Result<TickReport, StoreError> {
    let mut report = TickReport::default();
    for a in store.list()? {
        // A fenced automation is moving to another store: it never fires here.
        if !a.enabled || a.fenced() {
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
            event: None,
            dropped: 0,
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
            let stop = match verdict(&a.gate, &history, now, &|pid| exec.is_alive(pid)) {
                Verdict::Go => None,
                // `catch_up all` queues behind a live run instead of skipping.
                Verdict::Busy { .. } if queue_all => None,
                other => other.reason(),
            };
            match stop {
                Some(why) => {
                    if store.insert_run(&row(t, RunState::Skipped, Some(why.into())))? {
                        report.skipped += 1;
                    }
                }
                None => {
                    store.insert_run(&row(t, RunState::Queued, None))?;
                }
            }
        }
        if let Some(newest) =
            plan.run.iter().copied().chain(plan.skipped.iter().map(|(t, _)| *t)).max()
        {
            store.note_slot(&a.id, newest)?;
        }
        store.set_handled_through(&a.id, plan.handled_through)?;
        // Start the oldest queued run when none is running.
        let history = store.runs(&a.id)?;
        let running = history
            .iter()
            .any(|r| r.state == RunState::Running && r.pid.is_some_and(|p| exec.is_alive(p)));
        if !running {
            let (queued, settled): (Vec<Run>, Vec<Run>) =
                history.into_iter().partition(|r| r.state == RunState::Queued);
            for mut next in queued {
                match verdict(&a.gate, &settled, now, &|_| false).reason() {
                    None => {
                        let id = next.id.clone();
                        start_run(store, next, now, exec)?;
                        report.started.push(id);
                        break;
                    }
                    Some(why) => {
                        next.state = RunState::Skipped;
                        next.reason = Some(why.into());
                        next.finished_at = Some(now);
                        store.put_run(&next)?;
                        report.skipped += 1;
                    }
                }
            }
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
    start_manual_with_event(store, automation, key, None, now, exec)
}

/// [`start_manual`] with an event (`run --event`), as a watch line would
/// bring. A person's run skips the cooldown and cap, never the one live run:
/// beside a live run it is recorded `skipped: previous_run_running`. Its
/// condition still runs.
pub fn start_manual_with_event(
    store: &Store,
    automation: &str,
    key: &str,
    event: Option<&str>,
    now: i64,
    exec: &mut dyn Executor,
) -> Result<String, StoreError> {
    let a = store.get(automation)?;
    if let Some(h) = &a.handoff {
        return Err(crate::store::moving(&a, h));
    }
    let run = Run {
        id: manual_run_id(&a.id, key),
        automation: a.id.clone(),
        trigger: "manual".into(),
        event: event.map(clip_event),
        dropped: 0,
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
    let history = store.runs(&a.id)?;
    if history.iter().any(|r| r.id == id) {
        return Ok(id);
    }
    let one_live = Gate::default();
    if let Verdict::Busy { .. } = verdict(&one_live, &history, now, &|pid| exec.is_alive(pid)) {
        let skipped = Run {
            state: RunState::Skipped,
            reason: Some("previous_run_running".into()),
            finished_at: Some(now),
            ..run
        };
        store.insert_run(&skipped)?;
        return Ok(id);
    }
    if store.insert_run(&run)? {
        start_run(store, run, now, exec)?;
    }
    Ok(id)
}

/// What a watch event did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventOutcome {
    /// A run started (its id).
    Started(String),
    /// The guardrails dropped it (`paused`, `moving`, or a [`Verdict`]
    /// reason); the automation's dropped count went up.
    Dropped(&'static str),
}

/// A watch event of `automation` at `now`: a run with the event when the
/// guardrails let it, else a counted drop. `key` makes the run id unique.
/// Drops are counted, never rowed, so a log that spews cannot grow the
/// history; the next run carries the count.
pub fn start_event(
    store: &Store,
    automation: &str,
    event: &str,
    key: &str,
    now: i64,
    exec: &mut dyn Executor,
) -> Result<EventOutcome, StoreError> {
    let a = store.get(automation)?;
    let stop = if !a.enabled {
        Some("paused")
    } else if a.fenced() {
        Some("moving")
    } else {
        gate_verdict(store, &a, now, exec)?.reason()
    };
    if let Some(why) = stop {
        store.add_dropped(&a.id)?;
        return Ok(EventOutcome::Dropped(why));
    }
    let run = Run {
        id: event_run_id(&a.id, key),
        automation: a.id.clone(),
        trigger: "watch".into(),
        event: Some(clip_event(event)),
        dropped: store.take_dropped(&a.id)?,
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
    Ok(EventOutcome::Started(id))
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
        ExecOutcome::Skipped { reason } => (RunState::Skipped, Some(reason), None),
        ExecOutcome::Refused { reason } => (RunState::Failed, Some(reason), None),
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
