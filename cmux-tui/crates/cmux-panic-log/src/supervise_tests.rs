// crash-allow: the panics and unwraps here are the failures under test.
use super::*;
use std::sync::atomic::AtomicUsize;

const WAIT: Duration = Duration::from_secs(10);

#[derive(Debug, PartialEq, Eq)]
enum Event {
    Restarting(String, Failure),
    Fatal(FatalReport),
}

struct Recording(mpsc::Sender<Event>);

impl FailureSink for Recording {
    fn restarting(&self, worker: &str, failure: &Failure, _backoff: Duration) {
        let _ = self.0.send(Event::Restarting(worker.to_string(), failure.clone()));
    }

    fn fatal(&self, report: &FatalReport) {
        let _ = self.0.send(Event::Fatal(report.clone()));
    }
}

fn supervisor() -> (Supervisor, mpsc::Receiver<Event>) {
    let (tx, rx) = mpsc::channel();
    (Supervisor::new(Arc::new(Recording(tx))), rx)
}

fn fast() -> Restart {
    Restart::state_private().backoff(Duration::from_millis(1), Duration::from_millis(4))
}

/// Panics, typed as a body that returns `()` (a bare `panic!` closure is `!`).
fn boom(message: &str) {
    panic!("{message}");
}

fn panicked(message: &str) -> Failure {
    Failure::Panicked { message: message.to_string() }
}

fn wait_until_finished(supervisor: &Supervisor, name: &str) {
    let deadline = Instant::now() + WAIT;
    while supervisor.live_workers().iter().any(|live| live == name) {
        assert!(Instant::now() < deadline, "{name} still live");
        std::thread::yield_now();
    }
}

#[test]
fn a_fatal_thread_panic_is_reported_fatal_and_the_worker_ends() {
    let (supervisor, events) = supervisor();
    supervisor
        .supervise_thread("fatal-worker", Fatal, ShutdownBehavior::Skip, |_stop: &StopToken| {
            boom("journal invariant broken");
        })
        .unwrap();
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        Event::Fatal(FatalReport {
            worker: "fatal-worker".into(),
            reason: FatalReason::Failed(panicked("journal invariant broken")),
        })
    );
    wait_until_finished(&supervisor, "fatal-worker");
    assert!(events.try_recv().is_err());
}

#[test]
fn a_fatal_thread_error_is_fatal_and_a_clean_return_is_not() {
    let (supervisor, events) = supervisor();
    supervisor
        .supervise_thread("clean", Fatal, ShutdownBehavior::Skip, |_stop: &StopToken| ())
        .unwrap();
    wait_until_finished(&supervisor, "clean");
    supervisor
        .supervise_thread("errs", Fatal, ShutdownBehavior::Skip, |_stop: &StopToken| {
            Err::<(), _>("socket closed")
        })
        .unwrap();
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        Event::Fatal(FatalReport {
            worker: "errs".into(),
            reason: FatalReason::Failed(Failure::Errored { error: "socket closed".into() }),
        })
    );
    assert!(events.try_recv().is_err());
}

#[test]
fn a_restart_worker_runs_again_with_its_state_rebuilt() {
    let (supervisor, events) = supervisor();
    let runs = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&runs);
    supervisor
        .supervise_thread_restarting(
            "private-worker",
            fast(),
            ShutdownBehavior::Skip,
            move |_stop: &StopToken| {
                // The run's private state, built again on each run.
                let mut cache = HashMap::new();
                *cache.entry("frames").or_insert(0_usize) += 1;
                let mut runs = seen.lock().unwrap();
                runs.push(cache["frames"]);
                if runs.len() < 3 {
                    drop(runs);
                    panic!("bad frame");
                }
            },
        )
        .unwrap();
    for _ in 0..2 {
        assert_eq!(
            events.recv_timeout(WAIT).unwrap(),
            Event::Restarting("private-worker".into(), panicked("bad frame"))
        );
    }
    wait_until_finished(&supervisor, "private-worker");
    assert_eq!(*runs.lock().unwrap(), vec![1, 1, 1]);
    assert!(events.try_recv().is_err(), "a run that returns cleanly is not fatal");
}

#[test]
fn a_restart_worker_past_its_budget_gives_up_fatally() {
    let (supervisor, events) = supervisor();
    let runs = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&runs);
    supervisor
        .supervise_thread_restarting(
            "flapping",
            fast().budget(2, Duration::from_secs(60)),
            ShutdownBehavior::Skip,
            move |_stop: &StopToken| {
                counted.fetch_add(1, Ordering::SeqCst);
                boom("flap");
            },
        )
        .unwrap();
    for _ in 0..2 {
        assert!(matches!(events.recv_timeout(WAIT).unwrap(), Event::Restarting(..)));
    }
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        Event::Fatal(FatalReport {
            worker: "flapping".into(),
            reason: FatalReason::GaveUp {
                restarts: 2,
                window: Duration::from_secs(60),
                last: panicked("flap"),
            },
        })
    );
    wait_until_finished(&supervisor, "flapping");
    assert_eq!(runs.load(Ordering::SeqCst), 3, "no live process serving nothing: no 4th run");
}

#[test]
fn a_failure_that_poisons_a_shared_lock_is_fatal_not_restarted() {
    let (supervisor, events) = supervisor();
    let shared = Arc::new(Mutex::new(0_u32));
    let held = Arc::clone(&shared);
    supervisor
        .supervise_thread_restarting(
            "touches-shared",
            fast().shares(Arc::clone(&shared)),
            ShutdownBehavior::Skip,
            move |_stop: &StopToken| {
                let mut value = held.lock().unwrap();
                *value += 1;
                boom("half-mutated");
            },
        )
        .unwrap();
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        Event::Fatal(FatalReport {
            worker: "touches-shared".into(),
            reason: FatalReason::Poisoned(panicked("half-mutated")),
        })
    );
    wait_until_finished(&supervisor, "touches-shared");
    assert!(shared.is_poisoned());
}

#[test]
fn the_backoff_doubles_to_its_cap_and_old_restarts_leave_the_window() {
    let mut budget = Budget::new(
        Restart::state_private()
            .backoff(Duration::from_millis(100), Duration::from_millis(300))
            .budget(3, Duration::from_secs(60)),
    );
    let start = Instant::now();
    let quick = Duration::from_millis(1);
    assert_eq!(budget.next(start, quick), Some(Duration::from_millis(100)));
    assert_eq!(budget.next(start, quick), Some(Duration::from_millis(200)));
    assert_eq!(budget.next(start, quick), Some(Duration::from_millis(300)));
    assert_eq!(budget.next(start, quick), None, "4th restart in the window");
    let later = start + Duration::from_secs(61);
    assert_eq!(
        budget.next(later, Duration::from_secs(61)),
        Some(Duration::from_millis(100)),
        "a run up for the whole window starts the backoff over"
    );
}

#[test]
fn the_default_restart_policy_is_100ms_to_30s_five_per_minute() {
    let policy = Restart::state_private();
    assert_eq!(policy.initial_backoff, Duration::from_millis(100));
    assert_eq!(policy.max_backoff, Duration::from_secs(30));
    assert_eq!(policy.max_restarts, 5);
    assert_eq!(policy.window, Duration::from_secs(60));
}

#[test]
fn shutdown_stops_restarts_waits_for_block_and_names_late_workers() {
    let (supervisor, events) = supervisor();
    let flushed = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&flushed);
    supervisor
        .supervise_thread(
            "journal",
            Fatal,
            ShutdownBehavior::Block { deadline: WAIT },
            move |stop: &StopToken| {
                while !stop.wait_timeout(WAIT) {}
                flag.store(true, Ordering::SeqCst);
            },
        )
        .unwrap();
    supervisor
        .supervise_thread(
            "stuck",
            Fatal,
            ShutdownBehavior::Block { deadline: Duration::from_millis(20) },
            |_stop: &StopToken| std::thread::sleep(WAIT),
        )
        .unwrap();
    supervisor
        .supervise_thread("detached", Fatal, ShutdownBehavior::Continue, |_stop: &StopToken| {
            std::thread::sleep(WAIT);
        })
        .unwrap();
    let skip_runs = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&skip_runs);
    supervisor
        .supervise_thread_restarting(
            "skippable",
            Restart::state_private().backoff(WAIT, WAIT),
            ShutdownBehavior::Skip,
            move |_stop: &StopToken| {
                counted.fetch_add(1, Ordering::SeqCst);
                boom("waits in backoff");
            },
        )
        .unwrap();
    assert!(matches!(events.recv_timeout(WAIT).unwrap(), Event::Restarting(..)));

    let started = Instant::now();
    let report = supervisor.shutdown();
    assert!(started.elapsed() < WAIT, "Continue, Skip and backoff waits did not hold shutdown");
    assert!(flushed.load(Ordering::SeqCst), "Block worker ran to its end");
    assert_eq!(report.late, vec!["stuck".to_string()]);
    wait_until_finished(&supervisor, "skippable");
    assert_eq!(skip_runs.load(Ordering::SeqCst), 1, "no restart after shutdown");
    assert!(matches!(
        supervisor.supervise_thread("late", Fatal, ShutdownBehavior::Skip, |_: &StopToken| ()),
        Err(SuperviseError::ShuttingDown)
    ));
}

#[test]
fn a_fatal_worker_that_errs_while_stopping_is_not_fatal_and_block_workers_finish() {
    let (supervisor, events) = supervisor();
    supervisor
        .supervise_thread(
            "conn",
            Fatal,
            ShutdownBehavior::Block { deadline: WAIT },
            |stop: &StopToken| {
                while !stop.wait_timeout(WAIT) {}
                Err::<(), _>("peer closed during stop")
            },
        )
        .unwrap();
    let flushed = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&flushed);
    supervisor
        .supervise_thread(
            "journal",
            Fatal,
            ShutdownBehavior::Block { deadline: WAIT },
            move |stop: &StopToken| {
                while !stop.wait_timeout(WAIT) {}
                std::thread::sleep(Duration::from_millis(20));
                flag.store(true, Ordering::SeqCst);
            },
        )
        .unwrap();
    let report = supervisor.shutdown();
    assert!(report.late.is_empty());
    assert!(flushed.load(Ordering::SeqCst), "the other Block worker ran to its end");
    wait_until_finished(&supervisor, "conn");
    assert!(events.try_recv().is_err(), "a stop is not a failure, for Fatal workers too");
}

#[test]
fn a_handle_stop_ends_a_fatal_worker_that_errs_quietly() {
    let (supervisor, events) = supervisor();
    let worker = supervisor
        .supervise_thread("conn", Fatal, ShutdownBehavior::Skip, |stop: &StopToken| {
            while !stop.wait_timeout(WAIT) {}
            Err::<(), _>("peer closed during stop")
        })
        .unwrap();
    worker.stop();
    wait_until_finished(&supervisor, "conn");
    assert!(events.try_recv().is_err());
}

#[test]
fn a_handle_stops_its_own_worker_only() {
    let (supervisor, _events) = supervisor();
    let loop_body = |stop: &StopToken| while !stop.wait_timeout(WAIT) {};
    let first =
        supervisor.supervise_thread("first", Fatal, ShutdownBehavior::Skip, loop_body).unwrap();
    let _second =
        supervisor.supervise_thread("second", Fatal, ShutdownBehavior::Skip, loop_body).unwrap();
    assert_eq!(first.name(), "first");
    first.stop();
    wait_until_finished(&supervisor, "first");
    assert_eq!(supervisor.live_workers(), vec!["second".to_string()]);
    supervisor.shutdown();
}

#[test]
fn the_exit_record_is_a_supervised_exit_line_with_the_process_fields() {
    let mut fields = Fields::new();
    fields.insert("process".into(), "cmux-tui".into());
    let sink = ExitProcess::new(None, fields, |_| {});
    let line = sink.record(&FatalReport {
        worker: "mux-conn".into(),
        reason: FatalReason::Failed(panicked("boom")),
    });
    assert_eq!(line["kind"], "supervised_exit");
    assert_eq!(line["worker"], "mux-conn");
    assert_eq!(line["process"], "cmux-tui");
    assert_eq!(line["test"], false);
    assert_eq!(line["message"], "supervised worker mux-conn panicked: boom");
}

static EXIT_CODE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

#[test]
fn a_fatal_failure_appends_the_exit_line_then_ends_the_process_with_70() {
    let dir = std::env::temp_dir().join(format!("cmux-supervise-exit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("panic.log");
    let _ = std::fs::remove_file(&log);
    let sink = ExitProcess::new(Some(log.clone()), Fields::new(), |code| {
        EXIT_CODE.store(code, Ordering::SeqCst);
    });
    let supervisor = Supervisor::new(Arc::new(sink));
    let _worker = supervisor
        .supervise_thread("journal", Fatal, ShutdownBehavior::Continue, |_stop| {
            Err::<(), _>("disk full")
        })
        .unwrap();
    wait_until_finished(&supervisor, "journal");
    assert_eq!(EXIT_CODE.load(Ordering::SeqCst), SUPERVISED_FATAL_EXIT_CODE);
    let text = std::fs::read_to_string(&log).unwrap();
    let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
    assert_eq!(line["kind"], "supervised_exit");
    assert_eq!(line["worker"], "journal");
    assert_eq!(line["message"], "supervised worker journal returned an error: disk full");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(feature = "tokio")]
mod tasks {
    use super::*;

    async fn next(events: &mpsc::Receiver<Event>) -> Event {
        let deadline = Instant::now() + WAIT;
        loop {
            if let Ok(event) = events.try_recv() {
                return event;
            }
            assert!(Instant::now() < deadline, "no event");
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_fatal_task_panic_is_fatal_through_the_join_error() {
        let (supervisor, events) = supervisor();
        supervisor
            .supervise_task("fatal-task", Fatal, ShutdownBehavior::Skip, |_stop| async {
                boom("sort is not a total order");
            })
            .unwrap();
        assert_eq!(
            next(&events).await,
            Event::Fatal(FatalReport {
                worker: "fatal-task".into(),
                reason: FatalReason::Failed(panicked("sort is not a total order")),
            })
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_restart_task_runs_again_then_gives_up() {
        let (supervisor, events) = supervisor();
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&runs);
        supervisor
            .supervise_task_restarting(
                "flapping-task",
                fast().budget(1, Duration::from_secs(60)),
                ShutdownBehavior::Skip,
                move |_stop| {
                    let counted = Arc::clone(&counted);
                    async move {
                        counted.fetch_add(1, Ordering::SeqCst);
                        Err::<(), _>("relay refused")
                    }
                },
            )
            .unwrap();
        let errored = Failure::Errored { error: "relay refused".into() };
        assert_eq!(next(&events).await, Event::Restarting("flapping-task".into(), errored.clone()));
        assert_eq!(
            next(&events).await,
            Event::Fatal(FatalReport {
                worker: "flapping-task".into(),
                reason: FatalReason::GaveUp {
                    restarts: 1,
                    window: Duration::from_secs(60),
                    last: errored,
                },
            })
        );
        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn shutdown_aborts_skip_tasks_and_waits_for_block_tasks() {
        let (supervisor, events) = supervisor();
        let flushed = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&flushed);
        supervisor
            .supervise_task(
                "journal-task",
                Fatal,
                ShutdownBehavior::Block { deadline: WAIT },
                move |stop| async move {
                    stop.cancelled().await;
                    flag.store(true, Ordering::SeqCst);
                },
            )
            .unwrap();
        supervisor
            .supervise_task("idle-task", Fatal, ShutdownBehavior::Skip, |_stop| {
                std::future::pending::<()>()
            })
            .unwrap();
        let blocking = supervisor.clone();
        let report = tokio::task::spawn_blocking(move || blocking.shutdown()).await.unwrap();
        assert!(report.late.is_empty());
        assert!(flushed.load(Ordering::SeqCst));
        let deadline = Instant::now() + WAIT;
        while !supervisor.live_workers().is_empty() {
            assert!(Instant::now() < deadline, "skip task not aborted");
            tokio::task::yield_now().await;
        }
        assert!(events.try_recv().is_err(), "a stop is not a failure");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_fatal_task_whose_setup_panics_is_fatal() {
        let (supervisor, events) = supervisor();
        supervisor
            .supervise_task("setup-task", Fatal, ShutdownBehavior::Skip, |_stop| {
                boom("bind failed before the loop");
                async {}
            })
            .unwrap();
        assert_eq!(
            next(&events).await,
            Event::Fatal(FatalReport {
                worker: "setup-task".into(),
                reason: FatalReason::Failed(panicked("bind failed before the loop")),
            })
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_restart_task_whose_setup_panics_restarts_then_gives_up() {
        let (supervisor, events) = supervisor();
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&runs);
        supervisor
            .supervise_task_restarting(
                "setup-restart",
                fast().budget(1, Duration::from_secs(60)),
                ShutdownBehavior::Skip,
                move |_stop| {
                    counted.fetch_add(1, Ordering::SeqCst);
                    boom("cache build failed");
                    async {}
                },
            )
            .unwrap();
        let failure = panicked("cache build failed");
        assert_eq!(next(&events).await, Event::Restarting("setup-restart".into(), failure.clone()));
        assert_eq!(
            next(&events).await,
            Event::Fatal(FatalReport {
                worker: "setup-restart".into(),
                reason: FatalReason::GaveUp {
                    restarts: 1,
                    window: Duration::from_secs(60),
                    last: failure,
                },
            })
        );
        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_fatal_task_that_errs_after_its_stop_is_not_fatal() {
        let (supervisor, events) = supervisor();
        let worker = supervisor
            .supervise_task(
                "conn-task",
                Fatal,
                ShutdownBehavior::Block { deadline: WAIT },
                |stop| async move {
                    stop.cancelled().await;
                    Err::<(), _>("peer closed during stop")
                },
            )
            .unwrap();
        worker.stop();
        let deadline = Instant::now() + WAIT;
        while !supervisor.live_workers().is_empty() {
            assert!(Instant::now() < deadline, "conn-task still live");
            tokio::task::yield_now().await;
        }
        assert!(events.try_recv().is_err(), "a stop is not a failure");
    }

    #[test]
    fn a_task_outside_a_runtime_is_refused() {
        let (supervisor, _events) = supervisor();
        assert!(matches!(
            supervisor.supervise_task("orphan", Fatal, ShutdownBehavior::Skip, |_stop| async {}),
            Err(SuperviseError::NoRuntime)
        ));
        assert!(supervisor.live_workers().is_empty());
    }
}
