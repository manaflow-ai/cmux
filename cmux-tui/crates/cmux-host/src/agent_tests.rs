//! The agent loop over a fake platform: identity replies, clock and pause
//! wakes, and the session host restarts (carrier route, old build).

use super::*;

#[derive(Default)]
struct Fake {
    observations: VecDeque<Option<&'static str>>,
    wakes: VecDeque<Wake>,
    reads: usize,
    replies: Vec<(usize, Option<String>)>,
    invalidations: std::cell::Cell<usize>,
    /// `carrier_changed` answers, in order (then `false`).
    carrier: VecDeque<bool>,
    exits: VecDeque<Exit>,
    /// Every action run, by name.
    ran: Vec<&'static str>,
    /// The adopted host's executable is stale: an update flipped the
    /// build under it (`build_changed`).
    stale_exe: bool,
    /// `look_host` answers, in order (then none attached).
    looks: VecDeque<HostLook>,
    /// The fake clock: each `wait` moves it by the next of `advance_ms`.
    clock_ms: u64,
    advance_ms: VecDeque<u64>,
    /// Every action run (and every look), with the fake clock.
    timed: Vec<(u64, &'static str)>,
    /// The session host's restart budget, when the test keeps one.
    budget: Option<cmux_supervise_core::Budget>,
}

impl Platform for Fake {
    fn invalidate_remote_authority(&self) {
        self.invalidations.set(self.invalidations.get() + 1);
    }
    fn wait(&mut self) -> io::Result<Vec<Wake>> {
        self.clock_ms += self.advance_ms.pop_front().unwrap_or(0);
        Ok(vec![self.wakes.pop_front().unwrap()])
    }
    fn reap(&mut self) -> Vec<Exit> {
        self.exits.drain(..).collect()
    }
    fn observe(&mut self) -> Observation {
        self.reads += 1;
        Observation {
            instance_id: self.observations.pop_front().unwrap().map(str::to_owned),
            bake_id: None,
            bound_id: Some("a".into()),
            clone_signal: false,
        }
    }
    fn adopt_daemon(&mut self) -> Option<u32> {
        Some(1)
    }
    fn run(&mut self, action: &Action) -> io::Result<Option<Input>> {
        self.ran.push(action.name());
        self.timed.push((self.clock_ms, action.name()));
        Ok(None)
    }
    fn carrier_changed(&mut self) -> bool {
        self.carrier.pop_front().unwrap_or(false)
    }
    fn build_changed(&mut self) -> bool {
        self.stale_exe
    }
    fn look_host(&mut self) -> HostLook {
        self.ran.push("look-host");
        self.timed.push((self.clock_ms, "look-host"));
        let mut look =
            self.looks.pop_front().unwrap_or(HostLook { attached: Some(0), ..HostLook::default() });
        look.since_changed_ms = self.clock_ms;
        look
    }
    fn daemon_pid(&self) -> Option<u32> {
        Some(1)
    }
    fn write_status(&mut self, _: &Status) -> io::Result<()> {
        Ok(())
    }
    fn reply_identity(&mut self, id: Option<&str>) {
        self.replies.push((self.reads, id.map(str::to_owned)));
    }
    fn record_stop(
        &mut self,
        cause: cmux_supervise_core::StopCause,
    ) -> Option<cmux_supervise_core::BudgetState> {
        self.budget.as_ref().map(|b| b.record(cause).unwrap())
    }
}

/// A session host crash is counted on the supervisor contract before the machine sees it; past
/// the budget the agent holds (an hour's backoff) instead of restarting at once.
#[test]
fn a_crash_past_the_restart_budget_is_counted_and_held() {
    let dir = std::env::temp_dir().join(format!("cmux-host-budget-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let budget = cmux_supervise_core::Budget::new(dir.join("stops.json"), 0);
    let fake = Fake {
        observations: std::iter::repeat_n(Some("a"), 4).collect(),
        wakes: [Wake::Identity, Wake::ProcessExit, Wake::Terminate].into(),
        exits: [Exit::Daemon { lived_ms: 60_000 }].into(),
        budget: Some(budget.clone()),
        ..Fake::default()
    };
    let mut agent = Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
    agent.run().unwrap();
    let ran = &agent.platform.ran;
    assert!(ran.contains(&"arm-backoff"), "held: {ran:?}");
    assert!(!ran.contains(&"spawn-daemon"), "held, no restart: {ran:?}");
    let ledger = budget.today();
    assert_eq!(ledger.faults, 1);
    assert!(matches!(ledger.recent[0].cause, cmux_supervise_core::StopCause::Died(_)));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn identity_queries_observe_again_and_refuse_failed_metadata_or_clone_transition() {
    let fake = Fake {
        observations: [Some("a"), Some("a"), None, Some("b")].into(),
        wakes: [Wake::Identity, Wake::Identity, Wake::Identity, Wake::Terminate].into(),
        reads: 0,
        replies: vec![],
        invalidations: std::cell::Cell::new(0),
        carrier: VecDeque::new(),
        exits: VecDeque::new(),
        ran: vec![],
        ..Fake::default()
    };
    let mut agent = Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
    agent.run().unwrap();
    assert_eq!(
        agent.platform.replies,
        vec![(2, Some("a".into())), (3, None), (4, None), (4, None)]
    );
}

/// Runs `wakes` on a bound machine and returns its action log and how
/// often remote authority was ended.
fn run_wakes(wakes: &[Wake]) -> (String, usize) {
    let fake = Fake {
        observations: std::iter::repeat_n(Some("a"), wakes.len() + 1).collect(),
        wakes: wakes.iter().copied().chain([Wake::Terminate]).collect(),
        reads: 0,
        replies: vec![],
        invalidations: std::cell::Cell::new(0),
        carrier: VecDeque::new(),
        exits: VecDeque::new(),
        ran: vec![],
        ..Fake::default()
    };
    // One file per call: the tests run in parallel.
    static RUNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let run = RUNS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let path =
        std::env::temp_dir().join(format!("cmux-host-clock-{}-{run}.log", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let mut agent =
        Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(Some(&path)).unwrap());
    agent.run().unwrap();
    let log = std::fs::read_to_string(&path).unwrap_or_default();
    let _ = std::fs::remove_file(&path);
    // Every clock wake still reads the metadata again (the clone check).
    assert_eq!(agent.platform.reads, wakes.len() + 1);
    (log, agent.platform.invalidations.get())
}

#[test]
fn a_clock_sync_keeps_remote_authority_and_sends_no_resume() {
    let (log, invalidations) = run_wakes(&[Wake::ClockAdjusted, Wake::ClockAdjusted]);
    assert_eq!(invalidations, 0, "a clock sync ended remote authority: {log}");
    assert!(!log.contains("event=resumed"), "a clock sync sent Resumed: {log}");
}

#[test]
fn a_resume_clock_jump_ends_remote_authority_and_sends_resume() {
    let (log, invalidations) = run_wakes(&[Wake::ClockSet]);
    assert_eq!(invalidations, 1);
    assert!(log.contains("event=resumed"), "a resume sent no Resumed: {log}");
}

#[test]
fn only_a_clock_jump_past_the_threshold_is_a_resume() {
    let base = 1_793_780_000_000_000_000_i128;
    // Drift a provider's exec sync corrects, either way.
    assert_eq!(clock_set_wake(base, base + 3_000_000), Wake::ClockAdjusted);
    assert_eq!(clock_set_wake(base, base - 250_000_000), Wake::ClockAdjusted);
    assert_eq!(clock_set_wake(base, base + RESUME_CLOCK_JUMP_NS - 1), Wake::ClockAdjusted);
    // A pause or fork: the boot clock stood still while time went on.
    assert_eq!(clock_set_wake(base, base + RESUME_CLOCK_JUMP_NS), Wake::ClockSet);
    assert_eq!(clock_set_wake(base, base + 140_000_000_000), Wake::ClockSet);
    assert_eq!(clock_set_wake(base, base - 30_000_000_000), Wake::ClockSet);
}

#[test]
fn a_pause_watch_gap_ends_remote_authority_and_sends_resume() {
    // Freestyle: the boot clock ran through the pause, so the realtime
    // set after it moved nothing and only the pause watch saw it.
    let (log, invalidations) = run_wakes(&[Wake::ClockAdjusted, Wake::Paused]);
    assert_eq!(invalidations, 1, "a pause watch gap kept remote authority: {log}");
    assert_eq!(log.matches("event=resumed").count(), 1, "{log}");
}

#[test]
fn only_a_sleep_far_past_its_tick_is_a_pause() {
    let tick = i128::try_from(PAUSE_TICK.as_nanos()).unwrap();
    let gap = i128::try_from(PAUSE_GAP.as_nanos()).unwrap();
    let base = 2_000_000_000_000_i128;
    // On time, a scheduling delay, and a slew's worth of drift.
    assert_eq!(paused_for(base, base + tick), None);
    assert_eq!(paused_for(base, base + tick + 1_500_000_000), None);
    assert_eq!(paused_for(base, base + tick + gap), None);
    // A claim that resumed a spare paused for five minutes.
    assert_eq!(paused_for(base, base + tick + gap + 1), Some(Duration::from_nanos(20_000_000_001)));
    assert_eq!(paused_for(base, base + 300_000_000_000), Some(Duration::from_secs(290)));
    // A boot clock that went backwards is no pause.
    assert_eq!(paused_for(base, base - 60_000_000_000), None);
}

#[test]
fn one_resume_seen_by_both_detectors_is_one_resume() {
    use ResumeSource::{ClockSet, PauseWatch};
    let wall = 1_793_780_000_000_000_000_i128;
    let mut once = ResumeOnce::default();
    assert!(once.first(ClockSet, wall));
    // The other detector a second later: the same resume.
    assert!(!once.first(PauseWatch, wall + 1_000_000_000));
    // A second pause, 5 min of wall time later: a new resume, and the
    // other detector just inside the window is the same one.
    assert!(once.first(PauseWatch, wall + 300_000_000_000));
    assert!(!once.first(ClockSet, wall + 300_000_000_000 + SAME_RESUME_NS - 1));
    assert!(once.first(ClockSet, wall + 300_000_000_000 + 2 * SAME_RESUME_NS));
}

#[test]
fn consecutive_resumes_from_one_detector_are_each_a_resume() {
    use ResumeSource::{ClockSet, PauseWatch};
    let wall = 1_793_780_000_000_000_000_i128;
    let mut once = ResumeOnce::default();
    // Two real resumes 5 s apart, each a clock set: each gets its own
    // Resumed (transport reset, report).
    assert!(once.first(ClockSet, wall));
    assert!(once.first(ClockSet, wall + 5_000_000_000));
    // The pause watch's view of the second one is the same resume.
    assert!(!once.first(PauseWatch, wall + 5_500_000_000));
    // A third resume 2 s later is new, from either detector.
    assert!(once.first(ClockSet, wall + 7_500_000_000));
    assert!(!once.first(PauseWatch, wall + 8_000_000_000));
    assert!(once.first(PauseWatch, wall + 9_000_000_000));
}

/// The session host (adopted, so `Running`) under a fake spawner: the
/// run of `wakes` with `carrier_changed` answering `carrier`; returns
/// the actions run.
fn run_carrier(wakes: &[Wake], carrier: &[bool]) -> Vec<&'static str> {
    let fake = Fake {
        observations: std::iter::repeat_n(Some("a"), 16).collect(),
        wakes: wakes.iter().copied().chain([Wake::Terminate]).collect(),
        reads: 0,
        replies: vec![],
        invalidations: std::cell::Cell::new(0),
        carrier: carrier.iter().copied().collect(),
        exits: [Exit::Daemon { lived_ms: 60_000 }].into(),
        ran: vec![],
        ..Fake::default()
    };
    let mut agent = Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
    agent.run().unwrap();
    std::mem::take(&mut agent.platform.ran)
}

#[test]
fn carrier_json_appearing_respawns_the_session_host() {
    // Boot: the adopted host matches; then carrier.json is written.
    let ran = run_carrier(&[Wake::CarrierFile, Wake::ProcessExit], &[false, true]);
    let terminate = ran.iter().position(|a| *a == "terminate-daemon").expect("no stop");
    let spawn = ran.iter().position(|a| *a == "spawn-daemon").expect("no respawn");
    assert!(terminate < spawn, "{ran:?}");
    assert!(!ran.contains(&"stop-terminal-hosts"), "{ran:?}");
}

#[test]
fn an_adopted_host_with_an_old_route_respawns_at_boot() {
    let ran = run_carrier(&[Wake::ProcessExit], &[true]);
    assert_eq!(
        ran.iter().filter(|a| matches!(**a, "terminate-daemon" | "spawn-daemon")).count(),
        2,
        "{ran:?}"
    );
}

#[test]
fn an_unchanged_route_restarts_nothing() {
    let ran = run_carrier(&[Wake::CarrierFile, Wake::CarrierFile], &[false, false, false]);
    assert!(!ran.contains(&"terminate-daemon"), "{ran:?}");
    assert!(!ran.contains(&"spawn-daemon"), "{ran:?}");
}

/// The adopted host on a stale executable (an update's flip restarted
/// only the agent), `wakes` each `advance_ms` later on the fake clock,
/// `looks` its carrier sessions: the timed actions.
fn run_old_build(
    wakes: &[Wake],
    advance_ms: &[u64],
    looks: &[HostLook],
) -> Vec<(u64, &'static str)> {
    let fake = Fake {
        observations: std::iter::repeat_n(Some("a"), 16).collect(),
        wakes: wakes.iter().copied().chain([Wake::Terminate]).collect(),
        exits: [Exit::Daemon { lived_ms: 60_000 }].into(),
        stale_exe: true,
        looks: looks.iter().copied().collect(),
        advance_ms: advance_ms.iter().copied().collect(),
        ..Fake::default()
    };
    let mut agent = Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
    agent.run().unwrap();
    std::mem::take(&mut agent.platform.timed)
}

fn at(timed: &[(u64, &'static str)], name: &str) -> Option<(usize, u64)> {
    timed.iter().position(|(_, a)| *a == name).map(|i| (i, timed[i].0))
}

fn attached(n: usize) -> HostLook {
    HostLook { attached: Some(n), input_idle_ms: Some(1_000), since_changed_ms: 0 }
}

#[test]
fn an_adopted_host_on_an_old_build_respawns_at_boot() {
    // No carrier session attached: the old build goes at once, the way
    // a route change does (SIGTERM handoff, terminal hosts kept).
    let timed = run_old_build(&[Wake::ProcessExit], &[1_000], &[attached(0)]);
    let ran: Vec<_> = timed.iter().map(|(_, a)| *a).collect();
    let (terminate, _) = at(&timed, "terminate-daemon").expect("no stop");
    let (spawn, _) = at(&timed, "spawn-daemon").expect("no respawn");
    assert!(terminate < spawn, "{ran:?}");
    assert!(at(&timed, "replace-old-host").is_some_and(|(i, _)| i < terminate), "{ran:?}");
    assert!(!ran.contains(&"stop-terminal-hosts"), "{ran:?}");
    assert!(!ran.contains(&"mark-host-deferred"), "{ran:?}");
}

#[test]
fn a_busy_old_host_is_replaced_when_its_sessions_end() {
    // Boot (t=0): one session attached. The 15 s look: still attached.
    // The session detaches at 20 s; the 30 s look sees none; the old host
    // hands off on SIGTERM and exits 1 s later.
    const DETACH_MS: u64 = 20_000;
    let timed = run_old_build(
        &[Wake::HostLook, Wake::HostLook, Wake::ProcessExit],
        &[15_000, 15_000, 1_000],
        &[attached(1), attached(1), attached(0)],
    );
    let ran: Vec<_> = timed.iter().map(|(_, a)| *a).collect();
    let looks: Vec<_> = timed.iter().filter(|(_, a)| *a == "look-host").collect();
    assert_eq!(looks.len(), 3, "{ran:?}");
    let (terminate, terminate_ms) = at(&timed, "terminate-daemon").expect("never replaced");
    let (spawn, spawn_ms) = at(&timed, "spawn-daemon").expect("no respawn");
    // Kept while attached: nothing stops it before the look that saw none.
    assert_eq!(terminate_ms, 30_000, "{timed:?}");
    assert!(terminate < spawn, "{ran:?}");
    assert_eq!(ran.iter().filter(|a| **a == "mark-host-deferred").count(), 1, "{ran:?}");
    assert!(ran.contains(&"arm-host-look"), "{ran:?}");
    assert!(!ran.contains(&"stop-terminal-hosts"), "{ran:?}");
    // The link blip: from the detach to the new host's spawn (its listen
    // then waits for the journal replay, not modelled here).
    let blip_s = (spawn_ms - DETACH_MS) as f64 / 1000.0;
    eprintln!("link blip: detach at {DETACH_MS} ms, new host spawned at {spawn_ms} ms: {blip_s} s");
    assert!(spawn_ms - DETACH_MS <= crate::machine::HOST_LOOK_MS + 1_000, "{timed:?}");
}
