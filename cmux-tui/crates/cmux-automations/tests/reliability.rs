//! Reliability and visibility (docs/automations-desktop-parity.md): a run
//! whose process could not start is retried with backoff, the runner leaves a
//! heartbeat so a dead or hung runner shows, failed runs stay unread until
//! seen, a prompt run that stops on a permission prompt "needs you", and each
//! prompt run names its agent chat.

use std::path::PathBuf;

use cmux_automations::exec::{prompt_outcome, session_name};
use cmux_automations::{
    AutomationSpec, Body, CatchUp, ExecOutcome, Executor, Job, MAX_RETRIES, RETRY_BACKOFF_SECONDS,
    RunState, RunnerBeat, RunnerHealth, STALL_SECONDS, Store, Trigger, finish, is_retryable,
    runner_health, start_manual, tick, unread_failures,
};

fn temp_root(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-automations-reliability-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn manual(name: &str) -> AutomationSpec {
    AutomationSpec {
        name: name.into(),
        trigger: Trigger::Manual,
        body: Body::Command { command: "echo hi".into(), folder: None },
        catch_up: CatchUp::default(),
        timeout_seconds: 60,
        enabled: true,
        gate: Default::default(),
    }
}

/// Starts fail while `failing` is set; every start is recorded.
#[derive(Default)]
struct Flaky {
    failing: bool,
    started: Vec<Job>,
}

impl Executor for Flaky {
    fn start(&mut self, job: &Job) -> Result<u32, String> {
        self.started.push(job.clone());
        if self.failing { Err("No such file or directory".into()) } else { Ok(4_100_000) }
    }
    fn is_alive(&self, _pid: u32) -> bool {
        false
    }
}

const T0: i64 = 1_793_350_800;

#[test]
fn a_run_that_could_not_start_is_retried_with_backoff_then_given_up() {
    let store = Store::open(&temp_root("retry")).unwrap();
    let a = store.create(manual("Flaky start"), T0).unwrap();
    let mut exec = Flaky { failing: true, ..Default::default() };
    let first = start_manual(&store, &a.id, "k", T0, &mut exec).unwrap();
    let r = store.run(&a.id, &first).unwrap().unwrap();
    assert_eq!(r.state, RunState::Failed);
    assert!(r.reason.as_deref().unwrap().starts_with("start_failed"), "{:?}", r.reason);

    // Not before the first backoff.
    tick(&store, T0 + RETRY_BACKOFF_SECONDS[0] - 1, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1, "no retry before the backoff");

    // Each backoff makes one retry, linked to the run it retries.
    let mut now = T0;
    let mut previous = first;
    for attempt in 1..=MAX_RETRIES {
        now += RETRY_BACKOFF_SECONDS[(attempt - 1) as usize];
        let report = tick(&store, now, &mut exec).unwrap();
        assert_eq!(report.started.len(), 1, "attempt {attempt} starts once");
        let retry = store.run(&a.id, &report.started[0]).unwrap().unwrap();
        assert_eq!(retry.attempt, attempt);
        assert_eq!(retry.retry_of.as_deref(), Some(previous.as_str()));
        assert_eq!(retry.state, RunState::Failed);
        // Seen again, the same due retry is one run.
        assert!(tick(&store, now, &mut exec).unwrap().started.is_empty());
        previous = retry.id;
    }
    // Then it gives up: the last failure stays.
    tick(&store, now + 3_600, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1 + MAX_RETRIES as usize, "no retry after the last attempt");
}

#[test]
fn a_retry_that_starts_succeeds_and_stops_the_chain() {
    let store = Store::open(&temp_root("retry-ok")).unwrap();
    let a = store.create(manual("Recovers"), T0).unwrap();
    let mut exec = Flaky { failing: true, ..Default::default() };
    start_manual(&store, &a.id, "k", T0, &mut exec).unwrap();
    exec.failing = false;
    let report = tick(&store, T0 + RETRY_BACKOFF_SECONDS[0], &mut exec).unwrap();
    let retry = store.run(&a.id, &report.started[0]).unwrap().unwrap();
    assert_eq!(retry.state, RunState::Running);
    finish(&store, &a.id, &retry.id, ExecOutcome::Exited { code: 0 }, T0 + 40).unwrap();
    tick(&store, T0 + 3_000, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 2);
}

#[test]
fn only_infrastructure_failures_are_retried_and_only_recent_ones() {
    assert!(is_retryable("start_failed: No such file or directory"));
    assert!(is_retryable("error: Resource temporarily unavailable"));
    // The body ran: its own failure is the person's to see, never re-run.
    for reason in
        ["exit_7", "timeout", "needs_permission", "runner_died", "signal_9", "condition_exit_2"]
    {
        assert!(!is_retryable(reason), "{reason}");
    }

    // A start failure from long before (an older runner) is not retried now.
    let store = Store::open(&temp_root("retry-old")).unwrap();
    let a = store.create(manual("Old"), T0).unwrap();
    let mut exec = Flaky { failing: true, ..Default::default() };
    start_manual(&store, &a.id, "k", T0, &mut exec).unwrap();
    tick(&store, T0 + 86_400, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
}

#[test]
fn the_runner_heartbeat_tells_running_stalled_and_stopped_apart() {
    let store = Store::open(&temp_root("beat")).unwrap();
    assert_eq!(store.beat().unwrap(), None);
    let beat = RunnerBeat {
        pid: 4242,
        host: Some("mini".into()),
        started_at: T0,
        beat_at: T0 + 30,
        version: "1.0.0".into(),
    };
    store.put_beat(&beat).unwrap();
    assert_eq!(store.beat().unwrap().as_ref(), Some(&beat));

    assert_eq!(runner_health(true, Some(&beat), T0 + 60), RunnerHealth::Running);
    // The lock is held but the loop stopped beating: hung.
    assert_eq!(
        runner_health(true, Some(&beat), T0 + 30 + STALL_SECONDS + 1),
        RunnerHealth::Stalled
    );
    // No lock: stopped, whatever the last beat said.
    assert_eq!(runner_health(false, Some(&beat), T0 + 60), RunnerHealth::Stopped);
    assert_eq!(runner_health(false, None, T0), RunnerHealth::Stopped);
    // A runner from before heartbeats holds the lock and never beats: running.
    assert_eq!(runner_health(true, None, T0), RunnerHealth::Running);
}

#[test]
fn failed_runs_are_unread_until_the_automation_is_seen() {
    let store = Store::open(&temp_root("unread")).unwrap();
    let a = store.create(manual("Fails"), T0).unwrap();
    let mut exec = Flaky::default();
    let one = start_manual(&store, &a.id, "1", T0, &mut exec).unwrap();
    finish(&store, &a.id, &one, ExecOutcome::Exited { code: 7 }, T0 + 5).unwrap();
    let two = start_manual(&store, &a.id, "2", T0 + 10, &mut exec).unwrap();
    finish(&store, &a.id, &two, ExecOutcome::Exited { code: 0 }, T0 + 15).unwrap();
    assert_eq!(store.seen_at(&a.id).unwrap(), 0);
    assert_eq!(unread_failures(&store.runs(&a.id).unwrap(), 0), 1);

    store.mark_seen(&a.id, T0 + 20).unwrap();
    let seen = store.seen_at(&a.id).unwrap();
    assert_eq!(seen, T0 + 20);
    assert_eq!(unread_failures(&store.runs(&a.id).unwrap(), seen), 0);

    // Seen is its own file: the runner's cursor writes never undo it.
    store.set_handled_through(&a.id, T0 + 30).unwrap();
    assert_eq!(store.seen_at(&a.id).unwrap(), T0 + 20);

    let three = start_manual(&store, &a.id, "3", T0 + 40, &mut exec).unwrap();
    finish(&store, &a.id, &three, ExecOutcome::TimedOut, T0 + 50).unwrap();
    assert_eq!(unread_failures(&store.runs(&a.id).unwrap(), seen), 1);
}

#[test]
fn a_prompt_run_that_asks_for_permission_needs_you_and_its_timeout_is_a_timeout() {
    // The agent launcher exits 5 when a turn asks for a permission (`--on-permission fail`)
    // and 3 when its own `--timeout` cancels the turn.
    assert_eq!(
        prompt_outcome(ExecOutcome::Exited { code: 5 }),
        ExecOutcome::Refused { reason: "needs_permission".into() }
    );
    assert_eq!(prompt_outcome(ExecOutcome::Exited { code: 3 }), ExecOutcome::TimedOut);
    assert_eq!(prompt_outcome(ExecOutcome::Exited { code: 0 }), ExecOutcome::Exited { code: 0 });
    assert_eq!(prompt_outcome(ExecOutcome::Exited { code: 1 }), ExecOutcome::Exited { code: 1 });
}

#[test]
fn each_prompt_run_names_its_agent_chat() {
    let name = session_name("auto_abcdefgh234567abcdef", "run_234567abcdefghijklmn");
    assert_eq!(name, "auto-abcdefgh-234567ab");
    assert_eq!(name, session_name("auto_abcdefgh234567abcdef", "run_234567abcdefghijklmn"));
}
