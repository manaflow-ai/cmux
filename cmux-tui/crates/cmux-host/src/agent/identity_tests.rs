use super::*;

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
}

impl Platform for Fake {
    fn invalidate_remote_authority(&self) {
        self.invalidations.set(self.invalidations.get() + 1);
    }
    fn wait(&mut self) -> io::Result<Vec<Wake>> {
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
        Ok(None)
    }
    fn carrier_changed(&mut self) -> bool {
        self.carrier.pop_front().unwrap_or(false)
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
