//! The event loop: turns platform wakes into [`Input`]s, runs the
//! [`Machine`], and executes its [`Action`]s through the [`Platform`]
//! trait (Linux: `crate::linux::LinuxPlatform`; tests: a fake).
//!
//! One thread, one blocking wait. Every wake is a kernel event (clock set,
//! address change, file write, signal, process exit, one-shot timer) or the
//! pause watch's report of a resume. The agent thread has no tick; the
//! pause watch's thread sleeps [`PAUSE_TICK`] at a time and wakes it only
//! after a pause.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::time::Duration;

use cmux_server_core::layout::Layout;
use cmux_server_core::platform::InstallMode;
use cmux_server_core::role::Role;

use crate::machine::{Action, DaemonState, Input, Machine, Observation};
use crate::roles::{Roles, event_name};
use crate::status::Status;

/// One kernel event the platform woke for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wake {
    /// An identity client accepted before this turn's metadata observation.
    Identity,
    /// The realtime clock was set (`TFD_TIMER_CANCEL_ON_SET`) and moved
    /// against the boot clock by at least [`RESUME_CLOCK_JUMP_NS`]: the
    /// machine was paused, restored or forked.
    ClockSet,
    /// The realtime clock was set but moved against the boot clock by less
    /// than [`RESUME_CLOCK_JUMP_NS`]: a provider's clock sync (Freestyle sets
    /// it on every exec and file operation), not a resume.
    ClockAdjusted,
    /// The pause watch woke more than [`PAUSE_GAP`] past its tick on the
    /// boot clock: the machine was stopped while its boot clock kept running
    /// (Freestyle), so no clock set moved realtime against it.
    Paused,
    /// The set of global addresses changed (rtnetlink, filtered).
    Address,
    /// The driver wrote `/run/cmux/instance-id`.
    DriverFile,
    /// The bake wrote `/etc/cmux/bake-instance-id`.
    BakeFile,
    /// `server.json` was written.
    ConfigFile,
    /// `/var/lib/cmux/carrier.json` was written.
    CarrierFile,
    /// The observation retry timer.
    Retry,
    /// The periodic announce timer.
    AnnounceTimer,
    /// SIGTERM or SIGINT.
    Terminate,
    /// SIGCHLD or the session host's pidfd: reap.
    ProcessExit,
    Rearm,
    Backoff,
    StopDeadline,
}

/// How far the realtime clock must move against the boot clock for a clock
/// set to count as a resume. A snapshot restore (pause, fork) freezes the boot
/// clock, so the set that follows moves realtime by the whole time the machine
/// was stopped; a provider's sync on a running machine moves it by its drift.
pub const RESUME_CLOCK_JUMP_NS: i128 = 2_000_000_000;

/// The wake for a clock set that moved `realtime - boottime` from
/// `before_ns` to `after_ns`.
pub fn clock_set_wake(before_ns: i128, after_ns: i128) -> Wake {
    if (after_ns - before_ns).abs() >= RESUME_CLOCK_JUMP_NS {
        Wake::ClockSet
    } else {
        Wake::ClockAdjusted
    }
}

/// How long the pause watch sleeps (monotonic) between two looks at the
/// boot clock. A pause longer than `PAUSE_TICK + PAUSE_GAP` (30 s) is always
/// found, so every pause the relay retires a registration over (45 s of
/// silence) is.
pub const PAUSE_TICK: Duration = Duration::from_secs(10);

/// How far past [`PAUSE_TICK`] the boot clock must have moved during one
/// sleep for it to count as a pause. An NTP slew moves the boot clock by at
/// most 0.5 ms a second and a step never moves it, so 20 s is no clock sync;
/// it is also far past any scheduling delay of an otherwise idle thread.
pub const PAUSE_GAP: Duration = Duration::from_secs(20);

/// How long the machine was stopped, at least, during a pause-watch sleep
/// that read the boot clock at `before_ns` and again at `after_ns`; `None`
/// when the sleep ended within [`PAUSE_GAP`] of its tick.
pub fn paused_for(before_ns: i128, after_ns: i128) -> Option<Duration> {
    let late = after_ns - before_ns - i128::try_from(PAUSE_TICK.as_nanos()).ok()?;
    if late <= i128::try_from(PAUSE_GAP.as_nanos()).ok()? {
        return None;
    }
    Some(Duration::from_nanos(u64::try_from(late).unwrap_or(u64::MAX)))
}

/// Wall time within which a clock set and a pause-watch gap are the same
/// resume. Each fires within about a second of the resume, and on a provider
/// that has one of them the other never fires.
pub const SAME_RESUME_NS: i128 = 10_000_000_000;

/// The detector a resume signal came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResumeSource {
    /// A clock set that moved realtime against the boot clock.
    ClockSet,
    /// The pause watch's gap on the boot clock.
    PauseWatch,
}

/// One resume can reach the agent both as a clock set and as a pause-watch
/// gap (a provider whose boot clock runs through a pause and whose realtime
/// is set late). A signal within [`SAME_RESUME_NS`] of the last resume from
/// the other detector is that resume, seen again: a clock sync. Each detector
/// fires once per resume, so a second signal from the same detector is
/// always a new resume, and a resume absorbs at most one signal from the
/// other.
#[derive(Debug, Default)]
pub struct ResumeOnce {
    /// The last resume that has not yet absorbed the other detector's signal.
    last: Option<(ResumeSource, i128)>,
}

impl ResumeOnce {
    /// Whether a resume signal from `source` at wall time `wall_ns` is a new
    /// resume.
    pub fn first(&mut self, source: ResumeSource, wall_ns: i128) -> bool {
        let same = self.last.is_some_and(|(last_source, last_ns)| {
            last_source != source && (wall_ns - last_ns).abs() < SAME_RESUME_NS
        });
        self.last = if same { None } else { Some((source, wall_ns)) };
        !same
    }
}

/// A reaped process the machine cares about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    Daemon {
        lived_ms: u64,
    },
    /// The last announce helper exited.
    Announce,
}

/// The syscall boundary of the agent.
pub trait Platform {
    /// End remote authority before a potentially blocking clone/metadata read.
    fn invalidate_remote_authority(&self) {}
    /// Blocks until at least one wake.
    fn wait(&mut self) -> io::Result<Vec<Wake>>;
    /// Collects exits after a [`Wake::ProcessExit`].
    fn reap(&mut self) -> Vec<Exit>;
    /// One metadata read (single reader, bounded attempts) plus the bound
    /// and bake files.
    fn observe(&mut self) -> Observation;
    /// Supervises a session host left by a previous agent run; returns its
    /// pid.
    fn adopt_daemon(&mut self) -> Option<u32>;
    /// Runs one effect. `Ok(Some(input))` is a follow-up the effect
    /// produced at once (a failed spawn is an immediate exit; an announce
    /// with nothing to send is done).
    fn run(&mut self, action: &Action) -> io::Result<Option<Input>>;
    /// The supervised session host's pid.
    fn daemon_pid(&self) -> Option<u32>;
    /// Whether the supervised session host runs with another relay carrier
    /// route than `carrier.json` names now (`carrier_entry.rs`).
    fn carrier_changed(&mut self) -> bool {
        false
    }
    /// Publishes the status file.
    fn write_status(&mut self, status: &Status) -> io::Result<()>;
    /// Answers accepted identity clients only after the fresh observation's actions.
    fn reply_identity(&mut self, _settled_instance: Option<&str>) {}
}

/// Lines for the journal (stderr) and, optionally, an action log file.
pub struct ActionLog {
    file: Option<File>,
    seq: u64,
}

impl ActionLog {
    pub fn new(path: Option<&Path>) -> io::Result<Self> {
        let file = match path {
            Some(path) => Some(OpenOptions::new().create(true).append(true).open(path)?),
            None => None,
        };
        Ok(Self { file, seq: 0 })
    }

    pub fn line(&mut self, text: &str) {
        self.seq += 1;
        eprintln!("cmux-host: {text}");
        if let Some(file) = self.file.as_mut() {
            let _ = writeln!(file, "{} {text}", self.seq);
        }
    }
}

fn describe(action: &Action) -> String {
    match action {
        Action::Reseed(id)
        | Action::WriteBound(id)
        | Action::Rekey(id)
        | Action::CommitBind(id) => {
            format!("{} id={id}", action.name())
        }
        Action::ArmBackoff(ms) | Action::ArmRetry(ms) => format!("{} ms={ms}", action.name()),
        Action::Notify(event) => format!("{} event={}", action.name(), event_name(event)),
        Action::StartRoles(id) => format!("{} id={}", action.name(), id.as_deref().unwrap_or("-")),
        other => other.name().to_owned(),
    }
}

/// The agent: machine, roles and log over one platform.
pub struct Agent<P: Platform> {
    platform: P,
    machine: Machine,
    roles: Roles,
    log: ActionLog,
    last_wake: &'static str,
    wakes: u64,
}

impl<P: Platform> Agent<P> {
    /// `install`: the layout and mode roles receive in their context, or
    /// why it could not be resolved.
    pub fn new(
        platform: P,
        roles: Vec<Box<dyn Role>>,
        install: Result<(Layout, InstallMode), String>,
        log: ActionLog,
    ) -> Self {
        let roles = Roles::new(roles, install);
        Self { platform, machine: Machine::new(), roles, log, last_wake: "start", wakes: 0 }
    }

    pub fn machine(&self) -> &Machine {
        &self.machine
    }

    pub fn platform(&self) -> &P {
        &self.platform
    }

    /// Runs until SIGTERM or SIGINT. The session host keeps running.
    pub fn run(&mut self) -> io::Result<()> {
        let adopted = self.platform.adopt_daemon();
        if let Some(pid) = adopted {
            self.log.line(&format!("adopt-daemon pid={pid}"));
        }
        let first = self.platform.observe();
        let mut boot =
            vec![Input::Boot { adopted_daemon: adopted.is_some() }, Input::Observed(first)];
        // A session host kept from before an agent restart may run with an
        // older carrier route.
        if adopted.is_some() && self.platform.carrier_changed() {
            boot.push(Input::CarrierChanged);
        }
        if self.dispatch(boot) {
            return Ok(());
        }
        loop {
            let wakes = self.platform.wait()?;
            self.wakes += 1;
            let inputs = self.translate(&wakes);
            let exiting = self.dispatch(inputs);
            let settled = (!exiting && self.machine.identity_settled())
                .then(|| self.machine.current_id())
                .flatten();
            self.platform.reply_identity(settled);
            if exiting {
                self.publish();
                return Ok(());
            }
        }
    }

    /// Inputs in a safe order: the retry flag first, then the observation
    /// (so nothing restarts on stale state, P2-2), then everything else,
    /// shutdown last.
    fn translate(&mut self, wakes: &[Wake]) -> Vec<Input> {
        let mut first = Vec::new();
        let mut rest = Vec::new();
        let mut observe = false;
        // A wake a clone gives (P2-1): a failed read then retries even
        // while the session host runs.
        let mut clone_signal = false;
        let mut resumed = false;
        let mut terminate = false;
        for wake in wakes {
            match wake {
                Wake::Identity => {
                    observe = true;
                    // Failure must fence an inherited identity, just like a clone signal.
                    clone_signal = true;
                }
                Wake::ClockSet | Wake::Paused => {
                    self.platform.invalidate_remote_authority();
                    resumed = true;
                    observe = true;
                    clone_signal = true;
                }
                // A clock sync on a running machine: the metadata is read
                // again with the clone signal (a failed read still fences
                // the identity), but remote authority, the roles and their
                // receivers stay up and no `Resumed` is sent. Ending them
                // here dropped the Native receiver on every provider exec.
                Wake::ClockAdjusted => {
                    observe = true;
                    clone_signal = true;
                }
                // A change of the global address set: roles rebind and the
                // metadata is read again with a fresh retry budget. Not a
                // resume: no Resumed event, no announce.
                Wake::Address => {
                    first.push(Input::AddressesChanged);
                    observe = true;
                }
                Wake::ConfigFile => rest.push(Input::ConfigChanged),
                Wake::CarrierFile => {
                    if self.platform.carrier_changed() {
                        rest.push(Input::CarrierChanged);
                    }
                }
                Wake::DriverFile => {
                    self.platform.invalidate_remote_authority();
                    observe = true;
                    clone_signal = true;
                }
                Wake::BakeFile => observe = true,
                Wake::Retry => {
                    first.push(Input::RetryElapsed);
                    observe = true;
                }
                Wake::AnnounceTimer => rest.push(Input::AnnounceTick),
                Wake::Terminate => terminate = true,
                Wake::ProcessExit => {
                    rest.extend(self.platform.reap().into_iter().map(|exit| match exit {
                        Exit::Daemon { lived_ms } => Input::DaemonExited { lived_ms },
                        Exit::Announce => Input::AnnounceDone,
                    }));
                }
                Wake::Rearm => rest.push(Input::RearmElapsed),
                Wake::Backoff => rest.push(Input::BackoffElapsed),
                Wake::StopDeadline => rest.push(Input::StopDeadline),
            }
        }
        if let Some(wake) = wakes.first() {
            self.last_wake = wake_name(*wake);
        }
        if observe {
            let mut obs = self.platform.observe();
            obs.clone_signal = clone_signal;
            first.push(Input::Observed(obs));
        }
        if resumed {
            first.push(Input::ResumeSignal);
        }
        first.extend(rest);
        if terminate {
            first.push(Input::Shutdown);
        }
        first
    }

    /// Runs inputs and their follow-ups; `true` when the loop must exit.
    /// A step's follow-ups run before the next queued input.
    fn dispatch(&mut self, inputs: impl IntoIterator<Item = Input>) -> bool {
        let mut queue: VecDeque<Input> = inputs.into_iter().collect();
        let mut exit = false;
        while let Some(input) = queue.pop_front() {
            let actions = self.machine.step(input);
            let follow = self.run_step(&actions, &mut exit);
            for input in follow.into_iter().rev() {
                queue.push_front(input);
            }
        }
        if !exit {
            self.publish();
        }
        exit
    }

    /// Runs one step's actions. The identity group (reseed, drop, write)
    /// is guarded: its first failure skips the rest of the group (up to
    /// and including `CommitBind`) and answers `BindFailed`, so nothing
    /// spawns on inherited identity. Actions after the group (`Ready`)
    /// still run.
    fn run_step(&mut self, actions: &[Action], exit: &mut bool) -> Vec<Input> {
        let mut follow = Vec::new();
        let binding = actions.iter().find_map(|a| match a {
            Action::CommitBind(id) => Some(id.clone()),
            _ => None,
        });
        let mut skipping = false;
        for action in actions {
            if skipping {
                if matches!(action, Action::CommitBind(_)) {
                    skipping = false;
                }
                continue;
            }
            self.log.line(&describe(action));
            match action {
                Action::Exit => *exit = true,
                Action::CommitBind(id) => follow.push(Input::BindCommitted(id.clone())),
                Action::Recheck => follow.push(Input::Observed(self.platform.observe())),
                Action::StartRoles(id) => {
                    let errors = self.roles.start(id.clone());
                    self.log_all(errors);
                }
                Action::StopRoles => {
                    let errors = self.roles.stop_all();
                    self.log_all(errors);
                }
                Action::Notify(event) => {
                    let errors = self.roles.notify(event);
                    self.log_all(errors);
                }
                Action::ParkRoles => {
                    let ok = match self.roles.park() {
                        Ok(()) => true,
                        Err(errors) => {
                            self.log_all(errors);
                            self.log.line("park refused by a role");
                            false
                        }
                    };
                    follow.push(Input::RolesParked { ok });
                }
                Action::ShutdownRoles => {
                    let errors = self.roles.shutdown();
                    self.log_all(errors);
                }
                _ => match self.platform.run(action) {
                    Ok(Some(input)) => follow.push(input),
                    Ok(None) => {}
                    Err(err) => {
                        self.log.line(&format!("{} failed: {err}", action.name()));
                        let guarded = matches!(
                            action,
                            Action::Reseed(_) | Action::DropRemoteIdentity | Action::WriteBound(_)
                        );
                        if guarded && let Some(id) = binding.clone() {
                            self.log.line(&format!("bind-failed id={id}"));
                            follow.push(Input::BindFailed(id));
                            skipping = true;
                            continue;
                        }
                        if *action == Action::SpawnDaemon {
                            follow.push(Input::DaemonExited { lived_ms: 0 });
                        }
                    }
                },
            }
        }
        follow
    }

    fn log_all(&mut self, lines: Vec<String>) {
        for line in lines {
            self.log.line(&line);
        }
    }

    fn publish(&mut self) {
        let status = Status {
            agent_pid: std::process::id(),
            agent_running: true,
            instance_id: self.machine.current_id().map(str::to_owned),
            parked: self.machine.is_parked(),
            daemon: daemon_name(self.machine.daemon()).to_owned(),
            daemon_pid: self.platform.daemon_pid(),
            fast_exits: self.machine.fast_exits(),
            roles: self.roles.statuses(),
            last_wake: self.last_wake.to_owned(),
            wakes: self.wakes,
        };
        if let Err(err) = self.platform.write_status(&status) {
            self.log.line(&format!("status write failed: {err}"));
        }
    }
}

fn wake_name(wake: Wake) -> &'static str {
    match wake {
        Wake::Identity => "identity",
        Wake::ClockSet => "clock",
        Wake::ClockAdjusted => "clock-adjusted",
        Wake::Paused => "paused",
        Wake::Address => "net",
        Wake::DriverFile => "driver-file",
        Wake::BakeFile => "bake-file",
        Wake::ConfigFile => "config-file",
        Wake::CarrierFile => "carrier-file",
        Wake::Retry => "retry",
        Wake::AnnounceTimer => "announce-timer",
        Wake::Terminate => "terminate",
        Wake::ProcessExit => "exit",
        Wake::Rearm => "rearm",
        Wake::Backoff => "backoff",
        Wake::StopDeadline => "stop-deadline",
    }
}

pub fn daemon_name(state: &DaemonState) -> &'static str {
    match state {
        DaemonState::Down => "down",
        DaemonState::Running => "running",
        DaemonState::Stopping(_) => "stopping",
        DaemonState::Backoff => "backoff",
    }
}

#[cfg(test)]
mod identity_tests {
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
        let mut agent =
            Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
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
        assert_eq!(
            paused_for(base, base + tick + gap + 1),
            Some(Duration::from_nanos(20_000_000_001))
        );
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
        let mut agent =
            Agent::new(fake, vec![], Err("no roles".into()), ActionLog::new(None).unwrap());
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
}
