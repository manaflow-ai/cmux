use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::*;

/// A wall-clock instant on every grid the tests use (a multiple of 3600 s).
fn base() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(1_800_000_000)
}

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

#[derive(Clone)]
struct FakeClock(Arc<Mutex<SystemTime>>);

impl FakeClock {
    fn new(now: SystemTime) -> Self {
        Self(Arc::new(Mutex::new(now)))
    }

    fn set(&self, now: SystemTime) {
        *self.0.lock().unwrap() = now;
    }
}

impl WallClock for FakeClock {
    fn now(&self) -> SystemTime {
        *self.0.lock().unwrap()
    }
}

#[derive(Default)]
struct Log {
    /// Every `until` the loop waited for.
    asked: Vec<Option<SystemTime>>,
    /// The instants of timer wakes.
    wakes: Vec<SystemTime>,
}

/// A wait that jumps the clock to the instant it is asked for, stops after
/// `end`, models a machine asleep between the two instants of `asleep`, and
/// steps the wall clock back by `step_back.1` in the first wake at or after
/// `step_back.0`.
struct FakeWait {
    clock: FakeClock,
    log: Arc<Mutex<Log>>,
    end: SystemTime,
    asleep: Option<(SystemTime, SystemTime)>,
    step_back: Option<(SystemTime, Duration)>,
    commands: VecDeque<(SystemTime, Command)>,
}

impl Wait for FakeWait {
    fn wait(&mut self, until: Option<SystemTime>, _now: SystemTime) -> Wake {
        let mut log = self.log.lock().unwrap();
        log.asked.push(until);
        if let Some((when, _)) = self.commands.front()
            && until.is_none_or(|until| *when <= until)
        {
            let (when, command) = self.commands.pop_front().unwrap();
            self.clock.set(when);
            return Wake::Command(command);
        }
        let Some(until) = until else {
            return Wake::Closed;
        };
        let mut woke = match self.asleep {
            Some((from, to)) if until >= from && until < to => to,
            _ => until,
        };
        if let Some((at, by)) = self.step_back
            && woke >= at
        {
            self.step_back = None;
            woke -= by;
        }
        if woke > self.end {
            return Wake::Closed;
        }
        self.clock.set(woke);
        log.wakes.push(woke);
        Wake::Due
    }

    fn watch_power(&mut self, _descriptor: c_int) -> io::Result<()> {
        Ok(())
    }
}

type Runs = Arc<Mutex<Vec<(&'static str, SystemTime)>>>;

fn spec(name: &'static str, period: u64, skippable_in_saver: bool) -> JobSpec {
    JobSpec { name, period: secs(period), skippable_in_saver }
}

fn add(schedule: &mut Schedule, runs: &Runs, clock: &FakeClock, job: JobSpec) {
    add_placed(schedule, runs, clock, job, Placement::default(), base());
}

fn add_placed(
    schedule: &mut Schedule,
    runs: &Runs,
    clock: &FakeClock,
    job: JobSpec,
    placement: Placement,
    now: SystemTime,
) {
    let (runs, clock) = (Arc::clone(runs), clock.clone());
    schedule.register(
        job,
        placement,
        Box::new(move || runs.lock().unwrap().push((job.name, clock.now()))),
        now,
    );
}

struct Sim {
    clock: FakeClock,
    runs: Runs,
    log: Arc<Mutex<Log>>,
    schedule: Schedule,
}

impl Sim {
    fn new(jobs: &[JobSpec]) -> Self {
        let clock = FakeClock::new(base());
        let runs = Runs::default();
        let mut schedule = Schedule::default();
        for job in jobs {
            add(&mut schedule, &runs, &clock, *job);
        }
        Self { clock, runs, log: Arc::default(), schedule }
    }

    fn run(self, end: SystemTime, asleep: Option<(SystemTime, SystemTime)>, saver: bool) -> Self {
        let waiter = FakeWait {
            clock: self.clock.clone(),
            log: Arc::clone(&self.log),
            end,
            asleep,
            step_back: None,
            commands: VecDeque::new(),
        };
        drive(self.schedule, waiter, &self.clock, &EnergyMode::new(saver));
        Self { schedule: Schedule::default(), ..self }
    }

    fn runs_of(&self, name: &str) -> Vec<u64> {
        let runs = self.runs.lock().unwrap();
        runs.iter()
            .filter(|(job, _)| *job == name)
            .map(|(_, at)| at.duration_since(base()).unwrap().as_secs())
            .collect()
    }
}

#[test]
fn periods_of_300_600_and_900_share_their_wakes() {
    let sim = Sim::new(&[
        spec("a.300", 300, false),
        spec("b.600", 600, false),
        spec("c.900", 900, false),
    ])
    .run(base() + secs(1800), None, false);

    assert_eq!(sim.runs_of("a.300"), [300, 600, 900, 1200, 1500, 1800]);
    assert_eq!(sim.runs_of("b.600"), [600, 1200, 1800]);
    assert_eq!(sim.runs_of("c.900"), [900, 1800]);
    // 11 runs, 6 wakes: at 900 the 300 s and 900 s jobs fire in one wake,
    // at 1800 all three do.
    let wakes = &sim.log.lock().unwrap().wakes;
    let offsets: Vec<u64> =
        wakes.iter().map(|at| at.duration_since(base()).unwrap().as_secs()).collect();
    assert_eq!(offsets, [300, 600, 900, 1200, 1500, 1800]);
}

#[test]
fn nothing_registered_waits_with_no_timeout() {
    let sim = Sim::new(&[]).run(base() + secs(86_400), None, false);
    let log = sim.log.lock().unwrap();
    assert_eq!(log.asked, [None]);
    assert!(log.wakes.is_empty());
}

#[test]
fn a_registration_arms_the_first_timed_wait() {
    let clock = FakeClock::new(base());
    let runs = Runs::default();
    let (job_runs, job_clock) = (Arc::clone(&runs), clock.clone());
    let job: Job = Box::new(move || job_runs.lock().unwrap().push(("late.300", job_clock.now())));
    let log = Arc::new(Mutex::new(Log::default()));
    let waiter = FakeWait {
        clock: clock.clone(),
        log: Arc::clone(&log),
        end: base() + secs(600),
        asleep: None,
        step_back: None,
        commands: VecDeque::from([(
            base() + secs(10),
            Command::Register(spec("late.300", 300, false), Placement::default(), job),
        )]),
    };
    drive(Schedule::default(), waiter, &clock, &EnergyMode::new(false));

    let log = log.lock().unwrap();
    assert_eq!(log.asked[0], None, "no timer before the first registration");
    assert_eq!(log.asked[1], Some(base() + secs(300)));
    assert_eq!(runs.lock().unwrap().len(), 2);
}

#[test]
fn the_saver_stretches_only_skippable_jobs_up_to_four_periods() {
    let sim = Sim::new(&[spec("cache.sweep", 300, true), spec("lease.renew", 300, false)]).run(
        base() + secs(3600),
        None,
        true,
    );

    assert_eq!(sim.runs_of("cache.sweep"), [1200, 2400, 3600]);
    assert_eq!(sim.runs_of("lease.renew"), (1..=12).map(|n| n * 300).collect::<Vec<_>>());
}

#[test]
fn a_saver_edge_moves_skippable_jobs_without_a_gap_past_four_periods() {
    let clock = FakeClock::new(base());
    let runs = Runs::default();
    let mut schedule = Schedule::default();
    add(&mut schedule, &runs, &clock, spec("cache.sweep", 300, true));
    add(&mut schedule, &runs, &clock, spec("lease.renew", 300, false));

    assert_eq!(schedule.run_due(base() + secs(300)), ["cache.sweep", "lease.renew"]);
    schedule.set_saver(true);
    let sweep = schedule.entries[0].next;
    assert!(sweep > base() + secs(300) && sweep <= base() + secs(300 + 4 * 300));
    assert_eq!(schedule.entries[1].next, base() + secs(600), "a lease keeps its period");

    schedule.set_saver(false);
    assert_eq!(schedule.entries[0].next, base() + secs(600));
}

#[test]
fn a_two_hour_sleep_runs_each_job_once_spread_over_one_leeway() {
    let woke = base() + secs(100 + 7200);
    let sim = Sim::new(&[
        spec("a.300", 300, false),
        spec("b.600", 600, false),
        spec("c.900", 900, false),
    ])
    .run(woke + secs(60), Some((base() + secs(100), woke)), false);

    let woke = 7300;
    assert_eq!(sim.runs_of("a.300"), [woke]);
    assert_eq!(sim.runs_of("b.600"), [woke + 10]);
    assert_eq!(sim.runs_of("c.900"), [woke + 20]);
    for name in ["a.300", "b.600", "c.900"] {
        assert!(sim.runs_of(name)[0] < woke + LEEWAY.as_secs());
    }
}

#[test]
fn periods_round_up_to_the_five_minute_grid() {
    let schedule = Schedule::default();
    assert_eq!(schedule.period_secs(spec("x", 1, false)), 300);
    assert_eq!(schedule.period_secs(spec("x", 450, false)), 600);
    assert_eq!(schedule.period_secs(spec("x", 86_400, false)), 86_400);
    assert_eq!(next_on_grid(base() + secs(1), 600, 0), base() + secs(600));
    assert_eq!(next_on_grid(base(), 600, 0), base() + secs(600), "strictly after");
}

/// Installs with other phases ask a server at other instants of the period,
/// each still on a 300 s boundary; jobs of one install share their wakes.
#[test]
fn a_phase_spreads_installs_across_the_period_on_grid_boundaries() {
    const SIX_HOURS: u64 = 6 * 3600;
    let start = base();
    let mut firsts = std::collections::BTreeSet::new();
    for phase in 0..72u64 {
        let next = next_on_grid(start, SIX_HOURS, phase);
        let since = next.duration_since(UNIX_EPOCH).unwrap().as_secs();
        assert_eq!(since % GRID.as_secs(), 0, "phase {phase} wakes on a 300 s boundary");
        assert_eq!(since % SIX_HOURS, phase * GRID.as_secs(), "phase {phase}");
        assert!(next > start && next <= start + secs(SIX_HOURS));
        firsts.insert(next);
    }
    assert_eq!(firsts.len(), 72, "72 phases, 72 instants in the period");
    assert_eq!(next_on_grid(start, SIX_HOURS, 72 + 5), next_on_grid(start, SIX_HOURS, 5));

    // One install (phase 7): a 6 h and a 24 h job share the 24 h job's wakes.
    let clock = FakeClock::new(start);
    let runs = Runs::default();
    let mut schedule = Schedule::default();
    let placement = Placement { phase: 7, ran_at_registration: false };
    add_placed(&mut schedule, &runs, &clock, spec("catalog", SIX_HOURS, true), placement, start);
    add_placed(&mut schedule, &runs, &clock, spec("sweep", 86_400, false), placement, start);
    let sweep = schedule.entries[1].next;
    let catalog = schedule.entries[0].next;
    assert_eq!(sweep.duration_since(catalog).unwrap().as_secs() % SIX_HOURS, 0);
}

/// A job its owner ran at registration does not run on the grid seconds
/// later: a daemon that starts 10 s before its boundary waits for the next.
#[test]
fn a_job_run_at_registration_first_runs_on_the_grid_half_a_period_later() {
    const SIX_HOURS: u64 = 6 * 3600;
    let boundary = next_on_grid(base(), SIX_HOURS, 0);
    let start = boundary - secs(10);
    let clock = FakeClock::new(start);
    let runs = Runs::default();
    let mut schedule = Schedule::default();
    let ran = Placement { phase: 0, ran_at_registration: true };
    add_placed(&mut schedule, &runs, &clock, spec("catalog", SIX_HOURS, true), ran, start);
    add_placed(&mut schedule, &runs, &clock, spec("lease", 300, false), ran, start);
    add_placed(
        &mut schedule,
        &runs,
        &clock,
        spec("plain", 300, false),
        Placement::default(),
        start,
    );

    assert_eq!(schedule.entries[0].next, boundary + secs(SIX_HOURS), "not the boundary 10 s on");
    assert_eq!(schedule.entries[1].next, boundary + secs(300), "at least one grid step");
    assert_eq!(schedule.entries[2].next, boundary, "a job not run at start keeps its boundary");
    assert_eq!(schedule.run_due(boundary), ["plain"]);

    // A saver edge before the first grid run keeps the gap too.
    let mut schedule = Schedule::default();
    add_placed(&mut schedule, &runs, &clock, spec("catalog", SIX_HOURS, true), ran, start);
    schedule.set_saver(true);
    schedule.set_saver(false);
    assert_eq!(schedule.entries[0].next, boundary + secs(SIX_HOURS));

    // Half a period, not a whole one: a start 4 h before the boundary runs at it.
    let early = boundary - secs(4 * 3600);
    let mut schedule = Schedule::default();
    add_placed(&mut schedule, &runs, &clock, spec("catalog", SIX_HOURS, true), ran, early);
    assert_eq!(schedule.entries[0].next, boundary);
}

#[test]
fn a_panicking_job_does_not_stop_the_others() {
    let clock = FakeClock::new(base());
    let runs = Runs::default();
    let mut schedule = Schedule::default();
    let bad = spec("bad.job", 300, false);
    schedule.register(bad, Placement::default(), Box::new(|| panic!("job failed")), base());
    add(&mut schedule, &runs, &clock, spec("good.job", 300, false));
    assert_eq!(schedule.run_due(base() + secs(300)), ["bad.job", "good.job"]);
    assert_eq!(runs.lock().unwrap().len(), 1);
}

#[test]
fn ordinary_jobs_may_register() {
    assert_eq!(check(spec("acpmux.catalog", 300, false)), Ok(()));
}

#[test]
fn durability_jobs_are_refused() {
    for name in DURABILITY_JOBS {
        assert_eq!(refuse_durability(spec(name, 300, false)), Err(RegisterError::Durability(name)));
    }
    assert_eq!(refuse_durability(spec("acpmux.catalog", 300, false)), Ok(()));
}

#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "output_store.flush is a durability job")]
fn a_durability_registration_asserts_in_debug_builds() {
    let _ = check(spec("output_store.flush", 300, false));
}

#[test]
fn a_wall_clock_step_back_costs_at_most_one_period() {
    for back in [3600, 86_400] {
        let sim = Sim::new(&[spec("lease.renew", 300, false)]);
        // The wake due at base + 300 reads a wall clock `back` seconds earlier.
        let stepped = base() + secs(300) - secs(back);
        let waiter = FakeWait {
            clock: sim.clock.clone(),
            log: Arc::clone(&sim.log),
            end: stepped + secs(600),
            asleep: None,
            step_back: Some((base() + secs(300), secs(back))),
            commands: VecDeque::new(),
        };
        drive(sim.schedule, waiter, &sim.clock, &EnergyMode::new(false));

        let runs: Vec<SystemTime> = sim.runs.lock().unwrap().iter().map(|(_, at)| *at).collect();
        assert_eq!(runs, [stepped + secs(300), stepped + secs(600)], "stepped back {back} s");
    }
}

#[test]
fn the_clock_thread_wakes_on_commands_and_stops_on_drop() {
    let energy = EnergyMode::new(false);
    let clock = MaintenanceClock::start(&energy).expect("the clock thread starts");
    clock.register(spec("test.idle", 300, true), || {}).expect("registered");
    assert!(energy.set_saver(true));
    // Drop joins the thread: it must wake from its wait on the stop command.
    drop(clock);
}

#[cfg(target_os = "macos")]
#[test]
fn the_armed_kevent_carries_the_leeway() {
    let until = base() + secs(300);
    let event = platform::timer_event(until, LEEWAY);
    assert_eq!(event.filter, libc::EVFILT_TIMER);
    assert_ne!(event.fflags & libc::NOTE_LEEWAY, 0);
    assert_ne!(event.fflags & libc::NOTE_ABSOLUTE, 0);
    assert_ne!(event.fflags & libc::NOTE_NSECONDS, 0);
    assert_ne!(event.fflags & libc::NOTE_MACH_CONTINUOUS_TIME, 0);
    assert_eq!(event.fflags & libc::NOTE_MACHTIME, 0, "a calendar deadline, not mach ticks");
    assert_eq!(event.ext[1], 30_000_000_000);
    assert_eq!(event.data, 1_800_000_300_000_000_000);
    assert_ne!(event.flags & libc::EV_ONESHOT, 0);
}

#[cfg(target_os = "macos")]
#[test]
fn a_real_kqueue_accepts_and_fires_the_wall_clock_timer() {
    let (_commands, receiver) = mpsc::channel();
    let (waiter, _trigger) = platform::waiter(receiver).expect("a kqueue");
    let until = SystemTime::now() + Duration::from_millis(50);
    let change = platform::timer_event(until, Duration::from_millis(1));
    let events = waiter.kevent(Some(&change), Some(secs(5))).expect("kevent64");

    let timer = events.iter().find(|event| event.filter == libc::EVFILT_TIMER);
    let timer = timer.expect("the timer fired within 5 s");
    assert_eq!(
        timer.flags & libc::EV_ERROR,
        0,
        "the kernel refused the timer: errno {}",
        timer.data
    );
    assert!(SystemTime::now() + Duration::from_millis(5) >= until, "the timer fired early");
}

#[cfg(target_os = "linux")]
#[test]
fn the_clock_thread_takes_the_leeway_as_timer_slack() {
    // PR_GET_TIMERSLACK returns an int, too small for 30 s: procfs has the
    // whole value, under the thread's own id.
    let slack = std::thread::spawn(|| {
        platform::prepare_thread();
        // SAFETY: gettid takes no arguments and cannot fail.
        let tid = unsafe { libc::gettid() };
        std::fs::read_to_string(format!("/proc/{tid}/timerslack_ns"))
            .expect("the thread's timer slack")
    })
    .join()
    .unwrap();
    assert_eq!(slack.trim(), "30000000000");
}
