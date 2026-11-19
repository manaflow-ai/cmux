//! Faults against `Supervisor::run`, with real child processes, in the style of
//! `cmux-tui/tests/fault_injection.rs` so the `cmux-fault` harness can adopt them:
//! `kill` (by recorded pid), `quit` (an intent, then the exit), a crash loop past the budget,
//! and a stall shorter than the longest real hold (a slow disk's 10 s fsync).
#![cfg(target_os = "linux")]

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_supervise_core::{
    BudgetState, Cmd, Ended, Liveness, Probe, Progress, Spec, StopCause, Supervisor, record,
};

fn dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("supervise-faults-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A probe the test drives: ready always; progress as `stalled` says.
#[derive(Clone, Default)]
struct Driven {
    stalled: Arc<AtomicBool>,
    looks: Arc<AtomicU32>,
}

impl Probe for Driven {
    fn progress(&mut self) -> Progress {
        self.looks.fetch_add(1, Ordering::SeqCst);
        if self.stalled.load(Ordering::SeqCst) { Progress::Stalled } else { Progress::Moved }
    }
}

fn spec(dir: &std::path::Path, script: &str, probe: Driven, per_day: u32) -> Spec {
    Spec {
        name: "thing".into(),
        state_dir: dir.to_owned(),
        start: Cmd { program: "/bin/sh".into(), args: vec!["-c".into(), script.into()] },
        restart: None,
        probe: Box::new(probe),
        longest_hold: Duration::from_millis(600),
        look_every: Duration::from_millis(50),
        ready_within: Duration::from_secs(2),
        owned: vec![dir.join("sessions")],
        budget_per_day: per_day,
    }
}

fn wait_for(what: &str, within: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + within;
    while !done() {
        assert!(Instant::now() < deadline, "{what} within {within:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn owner(dir: &std::path::Path) -> Option<record::OwnerRecord> {
    record::load(&dir.join("thing.owner.json")).record().cloned()
}

#[test]
fn kill_by_recorded_pid_restarts_once_with_a_death_event_and_quit_never_respawns() {
    let dir = dir("kill-quit");
    let deaths = Arc::new(Mutex::new(Vec::new()));
    let seen = deaths.clone();
    let sup = Supervisor::new(spec(&dir, "exec sleep 30", Driven::default(), 5))
        .on_death(move |d| seen.lock().unwrap().push(d.clone()));
    let files = sup.files().clone();
    let run = std::thread::spawn(move || {
        let mut sup = sup;
        sup.serve()
    });

    wait_for("the first start", Duration::from_secs(5), || owner(&dir).is_some());
    let first = owner(&dir).unwrap();
    assert_eq!(first.epoch, 1);
    assert_eq!(first.liveness(), Liveness::Alive);

    // fault: kill
    unsafe { libc::kill(first.pid as i32, libc::SIGKILL) };
    wait_for("a restart after the kill", Duration::from_secs(5), || {
        owner(&dir).is_some_and(|o| o.epoch == 2 && o.liveness() == Liveness::Alive)
    });
    assert_eq!(first.liveness(), Liveness::Dead, "the killed owner reads dead by its record");
    let logged = deaths.lock().unwrap().clone();
    assert_eq!(logged.len(), 1, "one death event");
    assert_eq!(logged[0].owner, first);
    assert!(matches!(logged[0].cause, StopCause::Died(_)));
    assert_eq!(logged[0].owned, [dir.join("sessions").display().to_string()]);

    // fault: quit. The intent is written before the stop; the exit then respawns nothing.
    let second = owner(&dir).unwrap();
    files.intent.record("person quit", second.epoch).unwrap();
    unsafe { libc::kill(second.pid as i32, libc::SIGTERM) };
    let ended = run.join().unwrap().unwrap();
    assert_eq!(ended, Ended::Stopped("person quit".into()));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(owner(&dir).unwrap().epoch, 2, "no respawn after a quit");
    let ledger = files.budget.today();
    assert_eq!((ledger.stops, ledger.faults), (2, 1), "the quit is counted, not as a fault");
    let health = cmux_supervise_core::supervisor::read_health(&dir, "thing").unwrap();
    assert_eq!(health.state, "stopped");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_crash_loop_past_the_budget_holds_with_its_causes_on_the_health() {
    let dir = dir("budget");
    let ended = Supervisor::run(spec(&dir, "exit 3", Driven::default(), 2)).unwrap();
    match ended {
        Ended::BudgetExceeded(causes) => assert_eq!(causes.len(), 3),
        other => panic!("{other:?}"),
    }
    let health = cmux_supervise_core::supervisor::read_health(&dir, "thing").unwrap();
    assert_eq!(health.state, "restart-budget-exceeded");
    assert!(matches!(health.budget, BudgetState::Exceeded { faults: 3, budget: 2, .. }));
    // A new supervisor the same day holds at once: the ledger is on disk.
    let again = Supervisor::run(spec(&dir, "exit 3", Driven::default(), 2)).unwrap();
    assert!(matches!(again, Ended::BudgetExceeded(_)));
    assert_eq!(owner(&dir).unwrap().epoch, 4, "one start, then the hold");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A thing that runs but never answers readiness.
struct NeverReady;

impl Probe for NeverReady {
    fn ready(&mut self) -> bool {
        false
    }
}

#[test]
fn a_start_that_never_answers_readiness_is_a_failed_start_counted_against_the_budget() {
    let dir = dir("unready");
    let mut spec = spec(&dir, "exec sleep 30", Driven::default(), 1);
    spec.probe = Box::new(NeverReady);
    spec.ready_within = Duration::from_millis(200);
    let ended = Supervisor::run(spec).unwrap();
    match ended {
        Ended::BudgetExceeded(causes) => {
            assert_eq!(causes.len(), 2);
            assert!(causes.iter().all(|c| matches!(c, StopCause::NoProgress(_))), "{causes:?}");
        }
        other => panic!("{other:?}"),
    }
    let last = owner(&dir).unwrap();
    assert_eq!(last.epoch, 2, "one restart, then the hold; never 'running' on no answer");
    wait_for("the unready start ends with its supervisor", Duration::from_secs(5), || {
        last.liveness() == Liveness::Dead
    });
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_owner_record_that_cannot_be_read_starts_nothing_beside_it() {
    let dir = dir("unreadable");
    let path = dir.join("thing.owner.json");
    std::fs::write(&path, b"{\"pid\": 12").unwrap();
    let err = Supervisor::run(spec(&dir, "exec sleep 30", Driven::default(), 5)).unwrap_err();
    assert!(err.to_string().contains("cannot be read"), "{err}");
    assert_eq!(std::fs::read(&path).unwrap(), b"{\"pid\": 12", "the record is left as it was");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_stall_shorter_than_the_longest_hold_never_restarts_and_a_longer_one_restarts_once() {
    let dir = dir("stall");
    let probe = Driven::default();
    let sup = Supervisor::new(spec(&dir, "exec sleep 30", probe.clone(), 5));
    let files = sup.files().clone();
    std::thread::spawn(move || {
        let mut sup = sup;
        sup.serve()
    });
    wait_for("the first start", Duration::from_secs(5), || owner(&dir).is_some());

    // fault: slow-disk. Progress stalls for 400 ms at a time (under the 600 ms hold), then moves.
    for _ in 0..4 {
        probe.stalled.store(true, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(400));
        probe.stalled.store(false, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(120));
    }
    assert!(probe.looks.load(Ordering::SeqCst) > 20, "the probe looked");
    assert_eq!(owner(&dir).unwrap().epoch, 1, "zero self-stops on a slow disk");
    assert_eq!(files.budget.today().stops, 0);

    // A stall over the whole hold is proof: one restart, through a new owner record.
    probe.stalled.store(true, Ordering::SeqCst);
    wait_for("a restart after a proven stall", Duration::from_secs(5), || {
        owner(&dir).is_some_and(|o| o.epoch == 2)
    });
    probe.stalled.store(false, Ordering::SeqCst);
    let ledger = files.budget.today();
    assert!(matches!(ledger.recent[0].cause, StopCause::NoProgress(_)));
    let last = owner(&dir).unwrap();
    files.intent.record("test end", last.epoch).unwrap();
    unsafe { libc::kill(last.pid as i32, libc::SIGKILL) };
    let _ = std::fs::remove_dir_all(&dir);
}
