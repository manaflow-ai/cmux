//! One maintenance thread per process.
//!
//! Periodic upkeep (catalog refresh, health views, sweeps, caps) registers
//! here instead of running its own interval, so all of it shares one wake:
//!
//! - Every period is a multiple of a 5-minute grid on the wall clock
//!   ([`GRID`]); a job is due at the next multiple of its period since the
//!   Unix epoch, shifted by its [`Placement::phase`] in whole grid steps. A
//!   300 s, a 600 s and a 900 s job wake the thread once at each 300 s
//!   boundary, and all three share the wake at 1800 s.
//! - The phase spreads a job that calls a server across its period, one
//!   phase per install: every install still wakes only on 300 s boundaries,
//!   but they do not all ask at 00:00 UTC. Chrome's component updater spreads
//!   its checks the same way, from each client's own start
//!   (components/update_client/configurator.h, `InitialDelay`,
//!   `NextCheckDelay`).
//! - A job its owner runs at registration ([`Placement::ran_at_registration`])
//!   first runs on the grid at least half a period (and one [`GRID`]) later,
//!   not seconds after the run at start.
//! - The kernel sees a 30 s leeway ([`LEEWAY`]): on macOS the thread waits on
//!   kqueue `EVFILT_TIMER` armed for a wall-clock instant with
//!   `NOTE_ABSOLUTE | NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME | NOTE_LEEWAY`,
//!   the flags libdispatch arms for a `DISPATCH_WALLTIME` timer
//!   (src/event/event_kevent.c, `_dispatch_timer_index_to_fflags`; the
//!   continuous clock keeps counting while the Mac sleeps), plus `EVFILT_USER`
//!   for registrations and energy edges. On Linux the thread's `PR_SET_TIMERSLACK` is the
//!   leeway and it waits on its command channel.
//! - On macOS the kqueue also waits on a [`PowerSource`]'s descriptor
//!   ([`MaintenanceClock::follow_power`], the daemon's own power reading):
//!   a change of the power source wakes the thread like a
//!   command, with no timer of its own. Linux has no power source here.
//! - With nothing registered the thread waits with no timeout.
//! - A wake later than the leeway allows (the machine slept) runs each overdue
//!   job once, spread over one leeway window, then puts it back on its grid.
//!   A wall clock that steps back puts a job due more than one period ahead
//!   back on its grid from the new time, so either step costs one period.
//! - In Energy Saver a job registered `skippable_in_saver` runs at 4 times its
//!   period ([`SAVER_STRETCH`]); leases and renewals register with `false`.
//!
//! Durability jobs are not allowed here: the output store's flush and
//! snapshot, the journal checkpoint and journal maintenance bound data loss
//! after a crash, so they stay dirty-triggered one-shot [`super::deadline`]s
//! with 10% leeway and no saver stretch. [`MaintenanceClock::register`]
//! refuses their names.
//!
//! Jobs run on the clock thread one after another: a job that blocks delays
//! the jobs after it, so a long job hands its work to a `work` lane.

use std::io;
use std::os::raw::c_int;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_threads::ThreadQos;

use super::energy::{EnergyMode, EnergyWatch};
use super::power::{PowerFollow, PowerReading, PowerSource};

/// The wall-clock grid every period is a multiple of.
pub const GRID: Duration = Duration::from_secs(300);
/// How late the kernel may fire a maintenance wake to share it with others.
pub const LEEWAY: Duration = Duration::from_secs(30);
/// How many periods a skippable job may wait in Energy Saver.
pub const SAVER_STRETCH: u32 = 4;
/// The clock thread's name.
pub const THREAD_NAME: &str = "mux-maintenance";

/// A wake this much before a due instant still runs the job: a timed wait on
/// a monotonic clock can end a little before the wall-clock instant.
const EARLY: Duration = Duration::from_secs(1);
/// A wake this much after a due instant is a sleep gap, not leeway.
const LATE: Duration = Duration::from_secs(60);

/// Jobs that bound data loss after a crash; they never run on the clock.
const DURABILITY_JOBS: [&str; 4] = [
    "output_store.flush",
    "output_store.snapshot",
    "journal_retention.checkpoint",
    "journal_maintenance",
];

/// What a job is and how often it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct JobSpec {
    /// A stable `owner.job` name, for diagnostics and the durability check.
    pub name: &'static str,
    /// The period; rounded up to a multiple of [`GRID`].
    pub period: Duration,
    /// Whether Energy Saver may stretch the period to [`SAVER_STRETCH`] times.
    pub skippable_in_saver: bool,
}

/// Where a job's runs sit on its grid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Placement {
    /// The shift of the job's grid from the epoch's, in [`GRID`] steps, taken
    /// modulo the steps of its period. Jobs with one phase and periods that
    /// divide each other share their wakes.
    pub phase: u64,
    /// The owner ran the job at registration: its first grid run comes at
    /// least half a period, and at least one [`GRID`], after it.
    pub ran_at_registration: bool,
}

/// Why a job was not registered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegisterError {
    /// The job bounds data loss after a crash and must stay a dirty-triggered
    /// one-shot deadline.
    Durability(&'static str),
    /// The clock thread has stopped.
    Stopped,
    /// The power source's notification was not registered (its notify(3)
    /// status).
    PowerSource(u32),
}

impl std::fmt::Display for RegisterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Durability(name) => {
                write!(f, "{name} is a durability job: use a one-shot wake::deadline")
            }
            Self::Stopped => f.write_str("the maintenance clock has stopped"),
            Self::PowerSource(status) => {
                write!(f, "the power source notification was refused (notify status {status})")
            }
        }
    }
}

impl std::error::Error for RegisterError {}

type Job = Box<dyn FnMut() + Send>;

enum Command {
    Register(JobSpec, Placement, Job),
    /// The energy mode changed; the thread reads it.
    Energy,
    /// Wait on this power source too and pass its readings on.
    FollowPower(PowerFollow),
    Stop,
}

/// Why a wait ended.
enum Wake {
    /// The timer fired or the wait was woken: run what is due.
    Due,
    Command(Command),
    /// The power source's descriptor is readable.
    #[cfg_attr(
        not(any(test, target_os = "macos")),
        expect(dead_code, reason = "only the macOS kqueue wait watches a descriptor")
    )]
    Power,
    /// Every sender is gone.
    Closed,
}

/// The thread's blocking wait: until the wall-clock instant `until`, or with
/// no timeout when it is `None`, or until a command arrives.
trait Wait: Send {
    fn wait(&mut self, until: Option<SystemTime>, now: SystemTime) -> Wake;

    /// Ends later waits with [`Wake::Power`] while `descriptor` is readable.
    fn watch_power(&mut self, descriptor: c_int) -> io::Result<()>;
}

/// Wakes the thread's [`Wait`] after a command was queued.
trait Trigger: Send + Sync {
    fn trigger(&self);
}

/// The wall clock the schedule reads.
trait WallClock {
    fn now(&self) -> SystemTime;
}

struct SystemClock;

impl WallClock for SystemClock {
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }
}

#[derive(Clone)]
struct Mailbox {
    commands: Sender<Command>,
    trigger: Arc<dyn Trigger>,
}

impl Mailbox {
    fn send(&self, command: Command) -> Result<(), RegisterError> {
        self.commands.send(command).map_err(|_| RegisterError::Stopped)?;
        self.trigger.trigger();
        Ok(())
    }
}

/// The process's maintenance thread. Dropping it stops the thread.
pub struct MaintenanceClock {
    mailbox: Mailbox,
    thread: Option<JoinHandle<()>>,
    _energy: EnergyWatch,
}

impl MaintenanceClock {
    /// Starts the `mux-maintenance` thread at utility QoS, following `energy`.
    pub fn start(energy: &Arc<EnergyMode>) -> io::Result<Self> {
        let (commands, receiver) = mpsc::channel();
        let (waiter, trigger) = platform::waiter(receiver)?;
        let mailbox = Mailbox { commands, trigger };
        let edges = mailbox.clone();
        let watch = energy.watch(move || {
            let _ = edges.send(Command::Energy);
        });
        let mode = Arc::clone(energy);
        // supervise-allow: owned by MaintenanceClock, which keeps the handle and joins it; each job runs under catch_unwind in drive, so a job's panic skips that run and the clock keeps serving the others.
        let thread = cmux_threads::spawn(THREAD_NAME, ThreadQos::Utility, move || {
            platform::prepare_thread();
            drive(Schedule::default(), waiter, &SystemClock, &mode);
        })?;
        Ok(Self { mailbox, thread: Some(thread), _energy: watch })
    }

    /// Runs `job` every `spec.period` on the grid, first at the next multiple
    /// of the period. Durability jobs are refused (a debug assertion too).
    pub fn register(
        &self,
        spec: JobSpec,
        job: impl FnMut() + Send + 'static,
    ) -> Result<(), RegisterError> {
        self.register_placed(spec, Placement::default(), job)
    }

    /// [`MaintenanceClock::register`] on the grid `placement` shifts.
    pub fn register_placed(
        &self,
        spec: JobSpec,
        placement: Placement,
        job: impl FnMut() + Send + 'static,
    ) -> Result<(), RegisterError> {
        check(spec)?;
        self.mailbox.send(Command::Register(spec, placement, Box::new(job)))
    }

    /// Waits on `source` on the clock thread and calls `deliver` there with
    /// its first reading and each reading that differs from the last.
    /// `deliver` must only store the reading or flip a mode, never block.
    /// One source per clock: a second one is dropped. Where the thread cannot
    /// wait on a descriptor (not macOS) the source is dropped with a log line
    /// and `deliver` is never called.
    pub fn follow_power(
        &self,
        source: impl PowerSource + 'static,
        deliver: impl FnMut(PowerReading) + Send + 'static,
    ) -> Result<(), RegisterError> {
        let follow = PowerFollow::new(Box::new(source), Box::new(deliver));
        self.mailbox.send(Command::FollowPower(follow))
    }
}

impl Drop for MaintenanceClock {
    fn drop(&mut self) {
        let _ = self.mailbox.send(Command::Stop);
        let Some(thread) = self.thread.take() else { return };
        // A job that drops its own clock cannot wait for its thread.
        if thread.thread().id() != std::thread::current().id() {
            let _ = thread.join();
        }
    }
}

fn check(spec: JobSpec) -> Result<(), RegisterError> {
    let checked = refuse_durability(spec);
    debug_assert!(
        checked.is_ok(),
        "{} is a durability job: use a one-shot wake::deadline",
        spec.name
    );
    checked
}

/// The durability refusal of [`check`], without its debug assertion.
fn refuse_durability(spec: JobSpec) -> Result<(), RegisterError> {
    if DURABILITY_JOBS.contains(&spec.name) {
        Err(RegisterError::Durability(spec.name))
    } else {
        Ok(())
    }
}

/// The thread's loop: wait for the earliest due instant or a command, apply
/// the energy mode, run what is due.
fn drive(
    mut schedule: Schedule,
    mut waiter: impl Wait,
    clock: &impl WallClock,
    energy: &EnergyMode,
) {
    schedule.set_saver(energy.is_saver());
    let mut power: Option<PowerFollow> = None;
    loop {
        match waiter.wait(schedule.next_wake(), clock.now()) {
            Wake::Due | Wake::Command(Command::Energy) => {}
            Wake::Command(Command::Register(spec, placement, job)) => {
                schedule.register(spec, placement, job, clock.now());
            }
            Wake::Command(Command::FollowPower(follow)) => {
                power = power.or_else(|| watch_power(&mut waiter, follow));
            }
            Wake::Power => {
                if let Some(follow) = power.as_mut() {
                    follow.changed();
                }
            }
            Wake::Command(Command::Stop) | Wake::Closed => return,
        }
        let now = clock.now();
        schedule.set_saver(energy.is_saver());
        schedule.run_due(now);
    }
}

/// Adds `follow`'s descriptor to `waiter` and passes on its first reading;
/// `None` when the waiter cannot wait on it.
fn watch_power(waiter: &mut impl Wait, mut follow: PowerFollow) -> Option<PowerFollow> {
    if let Err(error) = waiter.watch_power(follow.descriptor()) {
        eprintln!("cmux-tui: {THREAD_NAME}: not following the power source ({error})");
        return None;
    }
    follow.changed();
    Some(follow)
}

struct Entry {
    spec: JobSpec,
    phase: u64,
    job: Job,
    /// What the next grid run counts from: the last run, or the
    /// registration before the first (plus [`min_gap`] for a job its owner
    /// ran at registration).
    from: SystemTime,
    next: SystemTime,
}

impl Entry {
    /// The first instant on this job's grid of `period` seconds after `time`.
    fn next_after(&self, time: SystemTime, period: u64) -> SystemTime {
        next_on_grid(time, period, self.phase)
    }
}

#[derive(Default)]
struct Schedule {
    entries: Vec<Entry>,
    saver: bool,
}

impl Schedule {
    fn period_secs(&self, spec: JobSpec) -> u64 {
        let grid = GRID.as_secs();
        let base = spec.period.as_secs().div_ceil(grid).max(1) * grid;
        if self.saver && spec.skippable_in_saver { base * u64::from(SAVER_STRETCH) } else { base }
    }

    fn register(&mut self, spec: JobSpec, placement: Placement, job: Job, now: SystemTime) {
        let period = self.period_secs(spec);
        let from = if placement.ran_at_registration { now + min_gap(period) } else { now };
        let next = next_on_grid(from, period, placement.phase);
        self.entries.push(Entry { spec, phase: placement.phase, job, from, next });
    }

    /// Moves skippable jobs to the grid of the new mode, counted from their
    /// last run; a job that leaves the saver overdue runs at the next wake.
    fn set_saver(&mut self, saver: bool) {
        if self.saver == saver {
            return;
        }
        self.saver = saver;
        for index in 0..self.entries.len() {
            let spec = self.entries[index].spec;
            if spec.skippable_in_saver {
                let period = self.period_secs(spec);
                let entry = &mut self.entries[index];
                entry.next = entry.next_after(entry.from, period);
            }
        }
    }

    fn next_wake(&self) -> Option<SystemTime> {
        self.entries.iter().map(|entry| entry.next).min()
    }

    /// Runs every job due at `now` and returns their names in run order.
    fn run_due(&mut self, now: SystemTime) -> Vec<&'static str> {
        self.regrid_ahead(now);
        self.spread_overdue(now);
        let mut ran = Vec::new();
        for index in 0..self.entries.len() {
            let due = self.entries[index].next;
            if due > now + EARLY {
                continue;
            }
            let period = self.period_secs(self.entries[index].spec);
            let entry = &mut self.entries[index];
            let _ = catch_unwind(AssertUnwindSafe(&mut entry.job));
            entry.from = now;
            entry.next = entry.next_after(due.max(now), period);
            ran.push(entry.spec.name);
        }
        ran
    }

    /// After the wall clock stepped back, puts every job due more than one
    /// period ahead back on its grid from `now`: a backward step, like a
    /// forward one, costs at most one period.
    fn regrid_ahead(&mut self, now: SystemTime) {
        for index in 0..self.entries.len() {
            let period = self.period_secs(self.entries[index].spec);
            let entry = &mut self.entries[index];
            if entry.next > now + Duration::from_secs(period) {
                entry.from = now;
                entry.next = entry.next_after(now, period);
            }
        }
    }

    /// After a sleep gap, gives the overdue jobs slots across one leeway
    /// window from `now`, earliest due first, so they do not all run in the
    /// wake that ends the gap.
    fn spread_overdue(&mut self, now: SystemTime) {
        let mut late: Vec<usize> = (0..self.entries.len())
            .filter(|&index| self.entries[index].next + LATE < now)
            .collect();
        if late.is_empty() {
            return;
        }
        late.sort_by_key(|&index| self.entries[index].next);
        let slots = u32::try_from(late.len()).unwrap_or(u32::MAX);
        for (slot, index) in (0u32..).zip(late) {
            self.entries[index].next = now + LEEWAY * slot / slots;
        }
    }
}

/// The first instant after `time` (whole seconds) that is a multiple of
/// `period` seconds since the Unix epoch plus the shift of `phase` grid
/// steps, taken modulo the period's steps.
fn next_on_grid(time: SystemTime, period: u64, phase: u64) -> SystemTime {
    let grid = GRID.as_secs();
    let shift = phase % (period / grid).max(1) * grid;
    let secs = time.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs());
    // Counted from `shift - period` (before the epoch), so no step goes below zero.
    let lead = period - shift;
    let next = (secs.saturating_add(lead) / period + 1).saturating_mul(period);
    UNIX_EPOCH + Duration::from_secs(next - lead)
}

/// How long after a run at registration the first grid run may come: half
/// the period, at least one [`GRID`].
fn min_gap(period: u64) -> Duration {
    Duration::from_secs((period / 2).max(GRID.as_secs()))
}

#[cfg(target_os = "macos")]
mod platform {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::raw::c_int;
    use std::sync::Arc;
    use std::sync::mpsc::{Receiver, TryRecvError};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::{Command, LEEWAY, THREAD_NAME, Trigger, Wait, Wake};

    const TIMER: u64 = 1;
    const USER: u64 = 2;
    /// A wall-clock (calendar) deadline in nanoseconds on the continuous
    /// clock, with the leeway in `ext[1]`.
    pub(super) const WALL_TIMER: u32 = libc::NOTE_ABSOLUTE
        | libc::NOTE_NSECONDS
        | libc::NOTE_MACH_CONTINUOUS_TIME
        | libc::NOTE_LEEWAY;

    pub(super) fn waiter(
        commands: Receiver<Command>,
    ) -> io::Result<(KqueueWait, Arc<dyn Trigger>)> {
        // SAFETY: kqueue takes no arguments; a negative result is an error.
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `fd` is a new descriptor nothing else owns.
        let kq = Arc::new(unsafe { OwnedFd::from_raw_fd(fd) });
        apply(&kq, &user_event(libc::EV_ADD | libc::EV_CLEAR, 0))?;
        let trigger: Arc<dyn Trigger> = Arc::new(KqueueTrigger { kq: Arc::clone(&kq) });
        Ok((KqueueWait { kq, commands, armed: None, power: None }, trigger))
    }

    /// The timer filter keeps the thread's QoS; nothing else to set.
    pub(super) fn prepare_thread() {}

    fn user_event(flags: u16, fflags: u32) -> libc::kevent64_s {
        libc::kevent64_s {
            ident: USER,
            filter: libc::EVFILT_USER,
            flags,
            fflags,
            data: 0,
            udata: 0,
            ext: [0, 0],
        }
    }

    /// The one-shot wall-clock timer for `until`, `leeway` late at most.
    /// `ext[1]` carries the leeway in the timer's unit (`NOTE_LEEWAY`).
    pub(super) fn timer_event(until: SystemTime, leeway: Duration) -> libc::kevent64_s {
        let at = until.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_nanos());
        libc::kevent64_s {
            ident: TIMER,
            filter: libc::EVFILT_TIMER,
            flags: libc::EV_ADD | libc::EV_ONESHOT,
            fflags: WALL_TIMER,
            data: i64::try_from(at).unwrap_or(i64::MAX),
            udata: 0,
            ext: [0, u64::try_from(leeway.as_nanos()).unwrap_or(u64::MAX)],
        }
    }

    /// Level-triggered readability of the power source's descriptor: a
    /// notification not yet drained wakes the next wait again.
    fn power_event(descriptor: u64, flags: u16) -> libc::kevent64_s {
        libc::kevent64_s {
            ident: descriptor,
            filter: libc::EVFILT_READ,
            flags,
            fflags: 0,
            data: 0,
            udata: 0,
            ext: [0, 0],
        }
    }

    fn timer_delete() -> libc::kevent64_s {
        libc::kevent64_s {
            ident: TIMER,
            filter: libc::EVFILT_TIMER,
            flags: libc::EV_DELETE,
            fflags: 0,
            data: 0,
            udata: 0,
            ext: [0, 0],
        }
    }

    fn apply(kq: &OwnedFd, change: &libc::kevent64_s) -> io::Result<()> {
        // SAFETY: one valid change in, no event list, no timeout: the call
        // returns at once.
        let result = unsafe {
            libc::kevent64(kq.as_raw_fd(), change, 1, std::ptr::null_mut(), 0, 0, std::ptr::null())
        };
        if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    pub(super) struct KqueueWait {
        kq: Arc<OwnedFd>,
        commands: Receiver<Command>,
        /// The instant the kqueue timer is armed for.
        armed: Option<SystemTime>,
        /// The power source's descriptor while the kqueue waits on it.
        power: Option<u64>,
    }

    impl Wait for KqueueWait {
        fn wait(&mut self, until: Option<SystemTime>, now: SystemTime) -> Wake {
            match self.commands.try_recv() {
                Ok(command) => return Wake::Command(command),
                Err(TryRecvError::Disconnected) => return Wake::Closed,
                Err(TryRecvError::Empty) => {}
            }
            let change = match until {
                _ if until == self.armed => None,
                Some(at) => Some(timer_event(at, LEEWAY)),
                None => Some(timer_delete()),
            };
            self.armed = until;
            let events = match self.kevent(change.as_ref(), None) {
                Ok(events) => events,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => return Wake::Due,
                Err(error) => return self.stop(&error),
            };
            let mut refused = None;
            let mut user = false;
            let mut power = false;
            for event in &events {
                user |= event.filter == libc::EVFILT_USER;
                if event.filter == libc::EVFILT_READ && Some(event.ident) == self.power {
                    power = event.flags & libc::EV_ERROR == 0;
                    if event.flags & (libc::EV_EOF | libc::EV_ERROR) != 0 {
                        self.stop_power();
                    }
                }
                if event.filter == libc::EVFILT_TIMER {
                    // The one-shot timer is gone once it fires or fails to arm.
                    self.armed = None;
                    if event.flags & libc::EV_ERROR != 0 {
                        refused = Some(event.data);
                    }
                }
            }
            if power {
                return Wake::Power;
            }
            let (Some(errno), Some(at), false) = (refused, until, user) else {
                return Wake::Due;
            };
            let error = io::Error::from_raw_os_error(i32::try_from(errno).unwrap_or(libc::EINVAL));
            eprintln!(
                "cmux-tui: {THREAD_NAME}: wall-clock timer refused ({error}); waiting on a relative timeout"
            );
            match self.kevent(None, Some(at.duration_since(now).unwrap_or(Duration::ZERO))) {
                Err(error) if error.kind() != io::ErrorKind::Interrupted => self.stop(&error),
                _ => Wake::Due,
            }
        }

        fn watch_power(&mut self, descriptor: c_int) -> io::Result<()> {
            let ident =
                u64::try_from(descriptor).map_err(|_| io::Error::from_raw_os_error(libc::EBADF))?;
            apply(&self.kq, &power_event(ident, libc::EV_ADD))?;
            self.power = Some(ident);
            Ok(())
        }
    }

    impl KqueueWait {
        /// Applies `change`, then waits for up to three events, at most
        /// `timeout` when given. A change the kernel refuses comes back as an
        /// `EV_ERROR` event.
        pub(super) fn kevent(
            &self,
            change: Option<&libc::kevent64_s>,
            timeout: Option<Duration>,
        ) -> io::Result<Vec<libc::kevent64_s>> {
            let changes = change.map_or(std::ptr::null(), std::ptr::from_ref);
            let count = i32::from(change.is_some());
            let timespec = timeout.map(|timeout| libc::timespec {
                tv_sec: libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX),
                tv_nsec: libc::c_long::from(timeout.subsec_nanos()),
            });
            let timespec_ptr = timespec.as_ref().map_or(std::ptr::null(), std::ptr::from_ref);
            let mut events = [user_event(0, 0); 3];
            // SAFETY: `changes` is null or one valid change, `events` has
            // room for three, `timespec_ptr` is null (block until an event) or
            // a valid timeout that outlives the call.
            let ready = unsafe {
                libc::kevent64(
                    self.kq.as_raw_fd(),
                    changes,
                    count,
                    events.as_mut_ptr(),
                    3,
                    0,
                    timespec_ptr,
                )
            };
            let ready = usize::try_from(ready).map_err(|_| io::Error::last_os_error())?;
            Ok(events[..ready].to_vec())
        }

        /// A power descriptor at its end (or refused) would be readable on
        /// every wait: the kqueue stops waiting on it and the readings stop.
        fn stop_power(&mut self) {
            let Some(ident) = self.power.take() else { return };
            let _ = apply(&self.kq, &power_event(ident, libc::EV_DELETE));
            eprintln!(
                "cmux-tui: {THREAD_NAME}: the power source notification closed; readings stop"
            );
        }

        /// A kqueue that cannot wait stops the clock instead of spinning;
        /// later registrations get [`super::RegisterError::Stopped`].
        fn stop(&mut self, error: &io::Error) -> Wake {
            eprintln!(
                "cmux-tui: {THREAD_NAME}: kqueue wait failed ({error}); the maintenance clock stops"
            );
            self.armed = None;
            Wake::Closed
        }
    }

    struct KqueueTrigger {
        kq: Arc<OwnedFd>,
    }

    impl Trigger for KqueueTrigger {
        fn trigger(&self) {
            let _ = apply(&self.kq, &user_event(0, libc::NOTE_TRIGGER));
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use std::io;
    use std::os::raw::c_int;
    use std::sync::Arc;
    use std::sync::mpsc::{Receiver, RecvTimeoutError};
    use std::time::{Duration, SystemTime};

    use super::{Command, Trigger, Wait, Wake};

    pub(super) fn waiter(
        commands: Receiver<Command>,
    ) -> io::Result<(ChannelWait, Arc<dyn Trigger>)> {
        Ok((ChannelWait { commands }, Arc::new(ChannelTrigger)))
    }

    /// The leeway of every timed wait on this thread: Linux timer slack.
    pub(super) fn prepare_thread() {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            let slack =
                libc::c_ulong::try_from(super::LEEWAY.as_nanos()).unwrap_or(libc::c_ulong::MAX);
            // SAFETY: PR_SET_TIMERSLACK takes one integer and changes only
            // the calling thread.
            unsafe { libc::prctl(libc::PR_SET_TIMERSLACK, slack, 0, 0, 0) };
        }
    }

    pub(super) struct ChannelWait {
        commands: Receiver<Command>,
    }

    impl Wait for ChannelWait {
        fn wait(&mut self, until: Option<SystemTime>, now: SystemTime) -> Wake {
            let received = match until {
                None => self.commands.recv().map_err(|_| RecvTimeoutError::Disconnected),
                Some(at) => {
                    let wait = at.duration_since(now).unwrap_or(Duration::ZERO);
                    // wakeup-allow: deadline the clock's next grid instant, the thread's timer slack is its leeway
                    self.commands.recv_timeout(wait)
                }
            };
            match received {
                Ok(command) => Wake::Command(command),
                Err(RecvTimeoutError::Timeout) => Wake::Due,
                Err(RecvTimeoutError::Disconnected) => Wake::Closed,
            }
        }

        /// The thread waits on its channel alone; here the daemon follows
        /// the app's `energy.set` and reads no power source.
        fn watch_power(&mut self, _descriptor: c_int) -> io::Result<()> {
            Err(io::ErrorKind::Unsupported.into())
        }
    }

    /// The channel send wakes the receiver itself.
    struct ChannelTrigger;

    impl Trigger for ChannelTrigger {
        fn trigger(&self) {}
    }
}

#[cfg(test)]
#[path = "maintenance_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "maintenance_power_tests.rs"]
mod power_tests;
