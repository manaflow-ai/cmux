//! Conditions, guardrails and watch events (cmuxterm-hq docs/automation-triggers.md).

use std::time::{Duration, Instant};

use cmux_automations::exec::{prompt_text, run_job};
use cmux_automations::watch::Watches;
use cmux_automations::{
    AutomationSpec, Body, CatchUp, EventOutcome, Executor, Gate, Job, RunState, Store, Trigger,
    Verdict, start_event, start_manual_with_event, tick,
};

const T0: i64 = 1_793_350_800;

fn store(tag: &str) -> Store {
    let dir =
        std::env::temp_dir().join(format!("cmux-automations-gate-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    Store::open(&dir).unwrap()
}

fn spec(name: &str, trigger: Trigger, command: &str, gate: Gate) -> AutomationSpec {
    AutomationSpec {
        name: name.into(),
        trigger,
        body: Body::Command {
            command: command.into(),
            folder: Some(std::env::temp_dir().to_string_lossy().into_owned()),
        },
        catch_up: CatchUp::default(),
        timeout_seconds: 30,
        enabled: true,
        gate,
    }
}

fn watch() -> Trigger {
    Trigger::Watch { command: "tail -F app.log".into(), debounce_seconds: 5 }
}

/// Records starts; `alive` says whether every started run still runs.
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

/// Starts nothing: `run_job` runs the body in the test itself.
struct Pending;
impl Executor for Pending {
    fn start(&mut self, _job: &Job) -> Result<u32, String> {
        Ok(std::process::id())
    }
    fn is_alive(&self, _pid: u32) -> bool {
        true
    }
}

fn condition(cmd: &str) -> Gate {
    Gate { condition: Some(cmd.into()), ..Gate::default() }
}

#[test]
fn a_condition_that_says_yes_runs_the_body_with_the_event_and_its_output() {
    let store = store("cond-yes");
    let gate = condition("read line; echo \"saw $line\"; exit 0");
    let a = store
        .create(
            spec(
                "yes",
                Trigger::Manual,
                "cat \"$CMUX_AUTOMATION_EVENT_FILE\"; echo \"[$CMUX_AUTOMATION_CONDITION_OUTPUT]\"",
                gate,
            ),
            T0,
        )
        .unwrap();
    let run =
        start_manual_with_event(&store, &a.id, "k", Some("FATAL db timeout"), T0, &mut Pending)
            .unwrap();
    run_job(&store, &a.id, &run).unwrap();
    let r = store.run(&a.id, &run).unwrap().unwrap();
    assert_eq!(r.state, RunState::Succeeded, "{r:?}");
    assert_eq!(r.event.as_deref(), Some("FATAL db timeout"));
    let log = std::fs::read_to_string(store.log_path(&a.id, &run)).unwrap();
    assert!(log.contains("FATAL db timeout"), "{log}");
    assert!(
        log.contains("[saw FATAL db timeout"),
        "the condition's output reaches the body: {log}"
    );
}

#[test]
fn a_condition_that_says_no_skips_the_run_and_one_that_fails_fails_it() {
    let store = store("cond-no");
    let no =
        store.create(spec("no", Trigger::Manual, "echo ran", condition("exit 1")), T0).unwrap();
    let run = start_manual_with_event(&store, &no.id, "k", None, T0, &mut Pending).unwrap();
    run_job(&store, &no.id, &run).unwrap();
    let r = store.run(&no.id, &run).unwrap().unwrap();
    assert_eq!((r.state, r.reason.as_deref()), (RunState::Skipped, Some("condition_false")));
    let log = std::fs::read_to_string(store.log_path(&no.id, &run)).unwrap();
    assert!(!log.contains("\nran\n"), "the body never ran: {log}");

    let bad =
        store.create(spec("bad", Trigger::Manual, "echo ran", condition("exit 3")), T0).unwrap();
    let run = start_manual_with_event(&store, &bad.id, "k", None, T0, &mut Pending).unwrap();
    run_job(&store, &bad.id, &run).unwrap();
    let r = store.run(&bad.id, &run).unwrap().unwrap();
    assert_eq!((r.state, r.reason.as_deref()), (RunState::Failed, Some("condition_exit_3")));
}

#[test]
fn guardrails_one_live_run_then_cooldown_then_the_daily_cap() {
    let store = store("verdict");
    let gate = Gate { cooldown_seconds: 600, max_runs_per_day: Some(2), ..Gate::default() };
    let a = store.create(spec("guarded", watch(), "true", gate), T0).unwrap();
    let mut exec = Recorder { alive: true, ..Recorder::default() };

    assert!(matches!(
        start_event(&store, &a.id, "e1", "1", T0, &mut exec).unwrap(),
        EventOutcome::Started(_)
    ));
    // The run is live: the next event is dropped and counted, never rowed.
    assert_eq!(
        start_event(&store, &a.id, "e2", "2", T0 + 1, &mut exec).unwrap(),
        EventOutcome::Dropped("previous_run_running")
    );
    exec.alive = false;
    assert_eq!(
        start_event(&store, &a.id, "e3", "3", T0 + 60, &mut exec).unwrap(),
        EventOutcome::Dropped("cooldown")
    );
    assert_eq!(store.runs(&a.id).unwrap().len(), 1, "drops are not run rows");
    assert_eq!(store.state(&a.id).unwrap().dropped, 2);

    // After the cooldown the next event runs and carries the drop count.
    let EventOutcome::Started(second) =
        start_event(&store, &a.id, "e4", "4", T0 + 601, &mut exec).unwrap()
    else {
        panic!("the cooldown is over");
    };
    let r = store.run(&a.id, &second).unwrap().unwrap();
    assert_eq!((r.trigger.as_str(), r.dropped), ("watch", 2));
    assert_eq!(store.state(&a.id).unwrap().dropped, 0);

    // Two runs in 24 hours: the cap holds the third until the first leaves the window.
    let history = store.runs(&a.id).unwrap();
    let v = cmux_automations::verdict(&a.gate, &history, T0 + 1_300, &|_| false);
    assert_eq!(v, Verdict::Cap { max: 2, until: T0 + 86_400 });
    assert!(matches!(
        start_event(&store, &a.id, "e5", "5", T0 + 86_401, &mut exec).unwrap(),
        EventOutcome::Started(_)
    ));
}

/// Starts nothing: every start fails.
struct Broken;
impl Executor for Broken {
    fn start(&mut self, _job: &Job) -> Result<u32, String> {
        Err("no shell".into())
    }
    fn is_alive(&self, _pid: u32) -> bool {
        false
    }
}

#[test]
fn a_start_that_failed_does_not_count_toward_cooldown_or_cap() {
    let store = store("start-failed");
    let gate = Gate { cooldown_seconds: 600, max_runs_per_day: Some(1), ..Gate::default() };
    let a = store.create(spec("broken", watch(), "true", gate), T0).unwrap();
    let EventOutcome::Started(run) =
        start_event(&store, &a.id, "e1", "1", T0, &mut Broken).unwrap()
    else {
        panic!("nothing holds the first event");
    };
    let r = store.run(&a.id, &run).unwrap().unwrap();
    assert_eq!(r.state, RunState::Failed);
    let history = store.runs(&a.id).unwrap();
    assert_eq!(cmux_automations::verdict(&a.gate, &history, T0 + 1, &|_| false), Verdict::Go);
}

#[test]
fn a_paused_watch_drops_its_events() {
    let store = store("paused");
    let a = store.create(spec("paused", watch(), "true", Gate::default()), T0).unwrap();
    store.set_enabled(&a.id, false, T0).unwrap();
    assert_eq!(
        start_event(&store, &a.id, "e", "1", T0, &mut Recorder::default()).unwrap(),
        EventOutcome::Dropped("paused")
    );
}

#[test]
fn a_scheduled_fire_inside_the_cooldown_is_skipped_with_the_reason() {
    let store = store("tick-cooldown");
    let gate = Gate { cooldown_seconds: 3_600, ..Gate::default() };
    let every = Trigger::Every { seconds: 600, anchor: T0 };
    let a = store.create(spec("every", every, "true", gate), T0).unwrap();
    let mut exec = Recorder::default();
    tick(&store, T0 + 600, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    // Its run ended; the next due time is inside the hour's cooldown.
    let mut first = store.runs(&a.id).unwrap().remove(0);
    first.state = RunState::Succeeded;
    store.put_run(&first).unwrap();
    tick(&store, T0 + 1_200, &mut exec).unwrap();
    let runs = store.runs(&a.id).unwrap();
    assert_eq!(exec.started.len(), 1, "{runs:?}");
    assert_eq!(runs.last().unwrap().reason.as_deref(), Some("cooldown"));
}

#[test]
fn a_watch_has_no_due_times_and_needs_a_command() {
    assert_eq!(watch().next_after(T0).unwrap(), None);
    assert!(Trigger::Watch { command: " ".into(), debounce_seconds: 5 }.validate().is_err());
    assert!(Trigger::Watch { command: "x".into(), debounce_seconds: 0 }.validate().is_err());
    assert!(Trigger::Watch { command: "x".into(), debounce_seconds: 30 }.validate().is_ok());
    assert!(Trigger::Watch { command: "x".into(), debounce_seconds: 31 }.validate().is_err());
}

#[test]
fn event_text_is_quoted_data_whose_fence_it_cannot_close() {
    let text = prompt_text("[h]", "run_x", "Fix it.", "a ``` b ```` c", 3);
    assert!(text.contains("Fix it.\n"));
    assert!(text.contains("`````text\na ``` b ```` c\n`````"), "{text}");
    assert!(text.contains("not instructions"));
    assert!(text.contains("3 more event(s)"));
    let plain = prompt_text("[h]", "run_x", "Fix it.", "", 0);
    assert!(!plain.contains("## Event"));
}

#[test]
fn bursts_of_lines_are_one_event_after_the_debounce() {
    let store = store("debounce");
    let a = store.create(spec("w", watch(), "true", Gate::default()), T0).unwrap();
    let mut w = Watches::new(store);
    // No real command here: the watcher's start fails quietly or runs; lines come from the seam.
    w.reconcile(std::slice::from_ref(&a), i64::MAX / 4);
    let ms = 1_000_000_000i64;
    w.add_line(&a.id, "panic: one", ms);
    w.add_line(&a.id, "  at main.rs:3", ms + 1_000);
    assert!(w.due_events(ms + 5_999).is_empty());
    let events = w.due_events(ms + 6_000);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].text, "panic: one\n  at main.rs:3\n");
    // A stream that never pauses still makes an event every 30 s.
    for i in 0..40 {
        w.add_line(&a.id, "spam", ms + 10_000 + i * 1_000);
    }
    assert_eq!(w.due_events(ms + 40_000).len(), 1);
}

#[test]
fn queued_catch_up_runs_still_meet_the_cooldown_and_cap() {
    let store = store("catch-up-gate");
    let gate = Gate { max_runs_per_day: Some(1), ..Gate::default() };
    let every = Trigger::Every { seconds: 600, anchor: T0 };
    let mut s = spec("all", every, "true", gate);
    s.catch_up = CatchUp::All { max: 10 };
    let a = store.create(s, T0).unwrap();
    let mut exec = Recorder { alive: true, ..Recorder::default() };
    // Three fires were missed: the first starts, the others queue behind it.
    tick(&store, T0 + 1_800, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    exec.alive = false;
    tick(&store, T0 + 1_801, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1, "the cap of one run a day holds the queued ones");
    let runs = store.runs(&a.id).unwrap();
    assert!(runs.iter().all(|r| r.state != RunState::Queued), "{runs:?}");
    assert!(runs.iter().any(|r| r.reason.as_deref() == Some("cap_reached")), "{runs:?}");
}

#[test]
fn a_manual_run_never_starts_beside_a_live_run() {
    let store = store("manual-busy");
    let a = store.create(spec("m", Trigger::Manual, "true", Gate::default()), T0).unwrap();
    let mut exec = Recorder { alive: true, ..Recorder::default() };
    start_manual_with_event(&store, &a.id, "one", None, T0, &mut exec).unwrap();
    let second = start_manual_with_event(&store, &a.id, "two", None, T0 + 1, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    let r = store.run(&a.id, &second).unwrap().unwrap();
    assert_eq!((r.state, r.reason.as_deref()), (RunState::Skipped, Some("previous_run_running")));
}

#[cfg(unix)]
#[test]
fn a_condition_whose_child_keeps_its_output_open_still_ends_in_time() {
    use cmux_automations::exec::{Condition, run_condition};
    let started = Instant::now();
    let c = run_condition(
        "sleep 600 & echo yes; exit 0",
        None,
        "",
        &[],
        std::process::Stdio::null(),
        Duration::from_secs(60),
    );
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    assert!(matches!(&c, Condition::Go { output } if output.contains("yes")), "{c:?}");
}

#[cfg(unix)]
#[test]
fn a_watch_that_closes_its_output_is_stopped_without_holding_the_runner() {
    let store = store("closed");
    let pidfile = std::env::temp_dir().join(format!("cmux-watch-closed-{}", std::process::id()));
    let cmd = format!(
        "echo $$ > {}; echo FATAL; exec 1>&-; trap '' TERM; exec sleep 600",
        pidfile.display()
    );
    let a = store
        .create(
            spec(
                "closed",
                Trigger::Watch { command: cmd, debounce_seconds: 1 },
                "true",
                Gate::default(),
            ),
            T0,
        )
        .unwrap();
    let now_ms = || {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as i64
    };
    let mut w = Watches::new(store);
    w.reconcile(std::slice::from_ref(&a), now_ms());
    let deadline = Instant::now() + Duration::from_secs(20);
    while w.status()[0].running && Instant::now() < deadline {
        let started = Instant::now();
        w.wait(Duration::from_millis(200), &now_ms);
        assert!(started.elapsed() < Duration::from_secs(2), "wait held the runner");
    }
    assert!(!w.status()[0].running, "a watch whose output closed is over");
    let pid: i32 = std::fs::read_to_string(&pidfile).unwrap().trim().parse().unwrap();
    // It ignores SIGTERM: the runner escalates after the grace.
    let deadline = Instant::now() + Duration::from_secs(20);
    // SAFETY: probes (signal 0) the process the watch started.
    while unsafe { libc::kill(pid, 0) } == 0 && Instant::now() < deadline {
        w.wait(Duration::from_millis(200), &now_ms);
    }
    assert!(unsafe { libc::kill(pid, 0) } != 0, "the process is gone");
    let started = Instant::now();
    drop(w);
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[cfg(unix)]
#[test]
fn a_real_watch_command_turns_its_lines_into_an_event_and_stops_with_the_runner() {
    let store = store("real");
    let pidfile = std::env::temp_dir().join(format!("cmux-watch-pid-{}", std::process::id()));
    let cmd =
        format!("echo $$ > {}; echo FATAL one; echo FATAL two; exec sleep 600", pidfile.display());
    let a = store
        .create(
            spec(
                "real",
                Trigger::Watch { command: cmd, debounce_seconds: 1 },
                "true",
                Gate::default(),
            ),
            T0,
        )
        .unwrap();
    let now_ms = || {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as i64
    };
    let mut w = Watches::new(store);
    w.reconcile(std::slice::from_ref(&a), now_ms());
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut events = Vec::new();
    while events.is_empty() && Instant::now() < deadline {
        w.wait(Duration::from_millis(200), &now_ms);
        events = w.due_events(now_ms());
    }
    assert_eq!(events.len(), 1, "one event for the burst");
    assert_eq!(events[0].text, "FATAL one\nFATAL two\n");
    let pid: i32 = std::fs::read_to_string(&pidfile).unwrap().trim().parse().unwrap();
    assert!(w.status()[0].running);
    drop(w);
    // SAFETY: probes (signal 0) the process the watch started.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    assert!(!alive, "the watch command stops when the runner's Watches is dropped");
}
