//! The store and the runner's tick: durable definitions, one run per due
//! time, catch-up rows after sleep, overlap, orphan recovery, exclusive
//! runner lock.

use std::path::PathBuf;

use cmux_automations::{
    AutomationSpec, Body, CatchUp, ExecOutcome, Executor, Job, RunState, RunnerLock, Store,
    Trigger, finish, recover_orphans, start_manual, tick,
};

const FRI_0900: i64 = 1_793_350_800;
const HOUR: i64 = 3_600;
const DAY: i64 = 86_400;

fn temp_root(tag: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-automations-test-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn spec(name: &str, trigger: Trigger) -> AutomationSpec {
    AutomationSpec {
        name: name.into(),
        trigger,
        body: Body::Command { command: "echo hi".into(), folder: None },
        catch_up: CatchUp::default(),
        timeout_seconds: 60,
        enabled: true,
    }
}

fn daily() -> Trigger {
    Trigger::Cron { expr: "0 9 * * *".into(), tz: "UTC".into() }
}

#[derive(Default)]
struct Recorder {
    started: Vec<Job>,
    alive: bool,
}

impl Executor for Recorder {
    fn start(&mut self, job: &Job) -> Result<u32, String> {
        self.started.push(job.clone());
        Ok(4_000_000 + self.started.len() as u32)
    }
    fn is_alive(&self, _pid: u32) -> bool {
        self.alive
    }
}

#[test]
fn create_survives_reopen_and_ids_are_unique() {
    let root = temp_root("create");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Morning brief", daily()), FRI_0900 - HOUR).unwrap();
    let b = store.create(spec("Second", daily()), FRI_0900 - HOUR).unwrap();
    assert_ne!(a.id, b.id);
    assert!(a.id.starts_with("auto_") && a.id.len() == 25, "{}", a.id);

    let again = Store::open(&root).unwrap();
    let list = again.list().unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(again.find("morning brief").unwrap().id, a.id, "name lookup ignores case");
    assert_eq!(again.find(&a.id[..10]).unwrap().id, a.id, "unique id prefix");
    assert!(again.find("auto_").is_err(), "an ambiguous prefix is refused");
}

#[test]
fn duplicate_name_is_refused() {
    let store = Store::open(&temp_root("dup")).unwrap();
    store.create(spec("Brief", daily()), 0).unwrap();
    assert!(store.create(spec("brief", daily()), 0).is_err());
}

#[test]
fn invalid_schedule_is_refused_before_anything_is_written() {
    let root = temp_root("invalid");
    let store = Store::open(&root).unwrap();
    assert!(
        store
            .create(spec("Bad", Trigger::Cron { expr: "61 * * * *".into(), tz: "UTC".into() }), 0)
            .is_err()
    );
    assert!(store.list().unwrap().is_empty());
}

#[test]
fn tick_runs_a_due_time_once_even_when_ticked_twice() {
    let store = Store::open(&temp_root("once")).unwrap();
    let a = store.create(spec("Brief", daily()), FRI_0900 - HOUR).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    let r1 = tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    let r2 = tick(&store, FRI_0900 + 35, &mut exec).unwrap();
    assert_eq!(r1.started.len(), 1);
    assert!(r2.started.is_empty());
    assert_eq!(exec.started.len(), 1);
    let runs = store.runs(&a.id).unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, RunState::Running);
    assert_eq!(runs[0].scheduled_at, Some(FRI_0900));
    assert_eq!(runs[0].pid, Some(4_000_001));
}

#[test]
fn a_crash_after_writing_runs_but_before_the_cursor_does_not_double_run() {
    // Two stores over one directory stand for a runner that died and its
    // replacement: the replacement's tick sees the same due time.
    let root = temp_root("crash");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Brief", daily()), FRI_0900 - HOUR).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    store.set_handled_through(&a.id, FRI_0900 - HOUR).unwrap(); // the cursor write "never happened"
    let mut exec2 = Recorder { alive: true, ..Default::default() };
    tick(&Store::open(&root).unwrap(), FRI_0900 + 40, &mut exec2).unwrap();
    assert!(
        exec2.started.is_empty(),
        "the run id already exists, so the due time is not started again"
    );
    assert_eq!(store.runs(&a.id).unwrap().len(), 1);
}

#[test]
fn sleep_through_four_days_gives_one_catch_up_and_four_visible_skips() {
    let store = Store::open(&temp_root("sleep")).unwrap();
    let a = store.create(spec("Brief", daily()), FRI_0900 - 4 * DAY - HOUR).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    let report = tick(&store, FRI_0900 + 2 * HOUR, &mut exec).unwrap();
    assert_eq!(report.started.len(), 1);
    let runs = store.runs(&a.id).unwrap();
    assert_eq!(runs.len(), 5);
    let ran: Vec<_> = runs.iter().filter(|r| r.state == RunState::Running).collect();
    assert_eq!(ran.len(), 1);
    assert_eq!(ran[0].scheduled_at, Some(FRI_0900));
    assert_eq!(ran[0].late_seconds, 2 * HOUR);
    assert_eq!(
        runs.iter()
            .filter(|r| r.state == RunState::Skipped && r.reason.as_deref() == Some("superseded"))
            .count(),
        4
    );
    // The job the executor got knows it is late.
    assert_eq!(exec.started[0].late_seconds, 2 * HOUR);
}

#[test]
fn a_running_previous_run_makes_the_next_due_time_skip() {
    let store = Store::open(&temp_root("overlap")).unwrap();
    let a = store
        .create(
            spec("Hourly", Trigger::Cron { expr: "0 * * * *".into(), tz: "UTC".into() }),
            FRI_0900 - 60,
        )
        .unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    tick(&store, FRI_0900 + HOUR + 5, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    let runs = store.runs(&a.id).unwrap();
    let skipped = runs.iter().find(|r| r.scheduled_at == Some(FRI_0900 + HOUR)).unwrap();
    assert_eq!(skipped.state, RunState::Skipped);
    assert_eq!(skipped.reason.as_deref(), Some("previous_run_running"));
}

#[test]
fn paused_automations_do_not_run_and_resume_does_not_replay_the_pause() {
    let store = Store::open(&temp_root("pause")).unwrap();
    let a = store.create(spec("Brief", daily()), FRI_0900 - HOUR).unwrap();
    store.set_enabled(&a.id, false, FRI_0900 - 30).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    assert!(exec.started.is_empty());
    store.set_enabled(&a.id, true, FRI_0900 + 2 * DAY + 60).unwrap();
    tick(&store, FRI_0900 + 2 * DAY + 90, &mut exec).unwrap();
    assert!(exec.started.is_empty(), "times inside the pause are not caught up");
    assert!(store.runs(&a.id).unwrap().is_empty());
}

#[test]
fn finish_records_the_outcome_and_frees_the_next_run() {
    let store = Store::open(&temp_root("finish")).unwrap();
    let a = store
        .create(
            spec("Hourly", Trigger::Cron { expr: "0 * * * *".into(), tz: "UTC".into() }),
            FRI_0900 - 60,
        )
        .unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    let report = tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    finish(&store, &a.id, &report.started[0], ExecOutcome::Exited { code: 0 }, FRI_0900 + 50)
        .unwrap();
    tick(&store, FRI_0900 + HOUR + 5, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 2);
    let runs = store.runs(&a.id).unwrap();
    let first = runs.iter().find(|r| r.id == report.started[0]).unwrap();
    assert_eq!(first.state, RunState::Succeeded);
    assert_eq!(first.finished_at, Some(FRI_0900 + 50));
}

#[test]
fn failures_and_timeouts_are_failed_with_a_reason() {
    let store = Store::open(&temp_root("fail")).unwrap();
    let a = store.create(spec("Brief", Trigger::Manual), 0).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    let r1 = start_manual(&store, &a.id, "k1", 100, &mut exec).unwrap();
    finish(&store, &a.id, &r1, ExecOutcome::Exited { code: 3 }, 110).unwrap();
    let r2 = start_manual(&store, &a.id, "k2", 200, &mut exec).unwrap();
    finish(&store, &a.id, &r2, ExecOutcome::TimedOut, 260).unwrap();
    let runs = store.runs(&a.id).unwrap();
    let get = |id: &str| runs.iter().find(|r| r.id == id).unwrap().clone();
    assert_eq!(get(&r1).state, RunState::Failed);
    assert_eq!(get(&r1).reason.as_deref(), Some("exit_3"));
    assert_eq!(get(&r2).reason.as_deref(), Some("timeout"));
}

#[test]
fn manual_run_with_the_same_key_starts_once() {
    let store = Store::open(&temp_root("manual")).unwrap();
    let a = store.create(spec("Brief", Trigger::Manual), 0).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    let r1 = start_manual(&store, &a.id, "same", 100, &mut exec).unwrap();
    let r2 = start_manual(&store, &a.id, "same", 101, &mut exec).unwrap();
    assert_eq!(r1, r2);
    assert_eq!(exec.started.len(), 1);
}

#[test]
fn orphans_are_recovered_queued_runs_start_dead_running_runs_fail() {
    let store = Store::open(&temp_root("orphan")).unwrap();
    let a = store
        .create(
            spec("Hourly", Trigger::Cron { expr: "0 * * * *".into(), tz: "UTC".into() }),
            FRI_0900 - 60,
        )
        .unwrap();
    let mut exec = Recorder { alive: false, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap(); // running, but its pid is dead
    let fixed = recover_orphans(&store, FRI_0900 + 600, &mut exec).unwrap();
    assert_eq!(fixed, 1);
    let run = store.runs(&a.id).unwrap().pop().unwrap();
    assert_eq!(run.state, RunState::Failed);
    assert_eq!(run.reason.as_deref(), Some("runner_died"));
    assert_eq!(exec.started.len(), 1, "a run that started is never re-run by itself");
}

#[test]
fn one_shot_disables_itself_after_it_runs() {
    let store = Store::open(&temp_root("oneshot")).unwrap();
    let a = store.create(spec("Remind", Trigger::At { at: FRI_0900 }), FRI_0900 - HOUR).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    assert!(!store.get(&a.id).unwrap().enabled);
    assert_eq!(exec.started.len(), 1);
}

#[test]
fn delete_hides_the_automation_but_keeps_its_history_on_disk() {
    let root = temp_root("delete");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Brief", daily()), FRI_0900 - HOUR).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    tick(&store, FRI_0900 + 5, &mut exec).unwrap();
    store.delete(&a.id).unwrap();
    assert!(store.list().unwrap().is_empty());
    assert!(store.find(&a.id).is_err());
    assert!(root.join(".deleted").read_dir().unwrap().next().is_some());
}

#[test]
fn only_one_runner_holds_the_lock() {
    let root = temp_root("lock");
    let store = Store::open(&root).unwrap();
    let first = RunnerLock::acquire(&store).unwrap();
    assert!(first.is_some());
    assert!(RunnerLock::acquire(&store).unwrap().is_none());
    drop(first);
    assert!(RunnerLock::acquire(&store).unwrap().is_some());
}

#[test]
fn a_torn_history_line_is_ignored_not_fatal() {
    let root = temp_root("torn");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Brief", Trigger::Manual), 0).unwrap();
    let mut exec = Recorder { alive: true, ..Default::default() };
    start_manual(&store, &a.id, "k", 1, &mut exec).unwrap();
    let path = root.join(&a.id).join("runs.jsonl");
    let mut text = std::fs::read_to_string(&path).unwrap();
    text.push_str("{\"id\":\"run_trunc");
    std::fs::write(&path, text).unwrap();
    assert_eq!(store.runs(&a.id).unwrap().len(), 1);
    start_manual(&store, &a.id, "k2", 2, &mut exec).unwrap();
    assert_eq!(
        store.runs(&a.id).unwrap().len(),
        2,
        "a write after a torn line starts on its own line"
    );
}

#[test]
fn update_bumps_the_version_and_keeps_history() {
    let store = Store::open(&temp_root("update")).unwrap();
    let a = store.create(spec("Brief", daily()), 0).unwrap();
    let mut changed = a.spec();
    changed.trigger = Trigger::Cron { expr: "30 8 * * *".into(), tz: "UTC".into() };
    let b = store.update(&a.id, changed, 10).unwrap();
    assert_eq!(b.version, a.version + 1);
    assert_eq!(b.created_at, a.created_at);
    assert_eq!(b.updated_at, 10);
}

#[test]
fn run_ids_are_deterministic_per_due_time() {
    use cmux_automations::run_id;
    assert_eq!(
        run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900),
        run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900)
    );
    assert_ne!(
        run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900),
        run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900 + 60)
    );
    assert_ne!(
        run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900),
        run_id("auto_bbbbbbbbbbbbbbbbbbbb", FRI_0900)
    );
    assert!(run_id("auto_aaaaaaaaaaaaaaaaaaaa", 0).starts_with("run_"));
    // The id is stored and compared across machines: its derivation must never change.
    assert_eq!(run_id("auto_aaaaaaaaaaaaaaaaaaaa", FRI_0900), "run_d2wwsnkgaqvsacwxjsaj");
}
