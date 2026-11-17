//! The `updater` role and the `cmux host update` verbs: the system half of
//! the self-update (see the module docs of [`super`]). Linux, root, the
//! image's system layout only.

use std::cell::Cell;
use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_server_core::role::{HostEvent, Role, RoleContext, RoleError, StopContext};
use serde_json::{Value, json};

use super::carrier::{CARRIER_MAX_HOLD, CarrierHold, CarrierLook};
use super::channel::{self, CHANNEL_MAX_BYTES, CHANNEL_URL, CMUX_TUI, CMUX_TUI_HOOK};
use super::gate::{Gate, HoldKind, Honor};
use super::store::{self, STORE_DIR};
use super::{
    DOWNLOAD_DIR, Decision, Pending, Plan, clear_pending, decide, load_pending, load_state,
    off_reason, record_installed, record_rollback, save_pending, save_state,
};
use crate::agent::PauseSeen;
use crate::config::Paths;
use crate::daemon_spec::{WORK_HOME, WORK_USER};

/// The first check after `cmux host run` starts (a boot or an update's restart).
const BOOT_DELAY: Duration = Duration::from_secs(30);
/// Every minute while the machine runs: a merged fix reaches an idle machine
/// within about a minute of the channel moving, not five. One check is a GET
/// of the small signed channel file (served uncached, max-age 60) and a
/// signature check; it logs only when its outcome changes.
const INTERVAL: Duration = Duration::from_secs(60);
/// An update waiting for a turn to end looks again this soon.
const BUSY_RETRY: Duration = Duration::from_secs(60);
pub(super) use super::gate::CONNECT_HOLD;
/// The new build has this long to serve after its restart: a session host
/// replays its journal before it listens (minutes for a large one).
const HEALTH_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// The previous build's guard runs this long after the flip, past the
/// health check, and rolls back an update that never proved itself.
const GUARD_AFTER_SECS: u64 = 20 * 60;
const GUARD_UNIT: &str = "cmux-self-update-guard";
const HOST_UNIT: &str = "cmux-host.service";
const ACPMUX_UNIT: &str = "acpmux.service";
const ACPMUX_UNIT_FILE: &str = "/home/cmux/.config/systemd/user/acpmux.service";
const CURRENT_ACPMUX: &str = "/opt/cmux/current/bin/acpmux";

fn log(line: &str) {
    eprintln!("cmux-host: updater: {line}");
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub(super) enum Msg {
    Check,
    Stop,
}

/// Bumped by every stop: a worker whose generation it no longer is has been
/// told to stop, also one that outlived its role's deadline, and touches
/// nothing more ([`stopped`]). The `cmux host update` verbs run outside any
/// worker and never stop.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Held from a worker's last [`stopped`] look through the flip and the
/// queued restarts, and by a stop while it bumps [`GENERATION`]: once a stop
/// returns, no worker flips or restarts anything; a stop that comes during
/// one waits for it (a rename and a few `--no-block` systemctl calls).
static COMMIT: Mutex<()> = Mutex::new(());

pub(super) fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// Starts (or extends) the connect hold now, as a hold of `kind`: a role
/// start, a resume or a restore ([`HoldKind::Resume`]), a bind or a new
/// carrier session ([`HoldKind::Connect`]). The Cloud role's bind takes it
/// before the bind goes out, which the supervisor's `Bound` (an instance id
/// change) does not see.
///
/// The hold lives in the state dir ([`Gate`]), so every process that flips or
/// restarts the services sees it: this service's updater, the operator's
/// `cmux host update check` and the guard. False when a restart of the
/// service is pending: the caller's link would be cut, so a bind leaves
/// `bind.json` for the restarted service, which clears the mark at its start.
///
/// It takes the gate's flock ([`super::gate::hold_connects`]): never call it
/// (or [`hold_if_paused`], [`flip_look`], [`carrier_busy_from`]) inside
/// [`Gate::run`] or [`flip_in_gate`], which would deadlock on that flock.
/// Inside, use `Inside::hold_connects(now)`.
pub(crate) fn hold_connects(paths: &Paths, kind: HoldKind) -> bool {
    super::gate::hold_connects(paths, wall_ms(), kind)
}

/// What the flip answers when the connect hold is on: a bind or resume that
/// came while the update downloaded or staged holds it too (it is retried as busy).
fn connect_hold_busy(left: Duration) -> Outcome {
    Outcome::Busy(vec![format!("connect hold, {} s left", left.as_secs())])
}

/// The flip's answer to the hold as it stands now.
#[cfg(test)]
pub(super) fn held_outcome(paths: &Paths) -> Option<Outcome> {
    held_for(paths).map(connect_hold_busy)
}

/// One look at `realtime - boottime`: whether it moved by a restore's jump
/// since the look just before (never a remembered baseline, so clock syncs
/// that each move it less never add up to one), and it becomes the last.
pub(super) fn restore_look(last: &mut Option<i128>, now: i128) -> bool {
    let restored = restored_between(*last, now);
    *last = Some(now);
    restored
}

/// `realtime - boottime` at the worker's last look ([`hold_after_restore`]).
static CLOCK_OFFSET: Mutex<Option<i128>> = Mutex::new(None);

/// Whether `realtime - boottime` moved from `before` to `now` by a whole stop:
/// a snapshot restore, as the supervisor's clock-set wake counts one.
pub(super) fn restored_between(before: Option<i128>, now: i128) -> bool {
    before.is_some_and(|before| {
        crate::agent::clock_set_wake(before, now) == crate::agent::Wake::ClockSet
    })
}

/// Starts the connect hold for a snapshot restore the supervisor's
/// `Resumed` has not reached yet. A new machine is a restore of the bake's
/// snapshot, so the hold its role start set ran out long before. Its
/// `Resumed` comes only after a metadata read, and this worker's next
/// look could flip first (production probe, 2026-11-08: a new machine
/// flipped 10 s after its create and the app's first link ended).
///
/// This covers a provider whose boot clock stops while the machine is
/// stopped, and reads the clocks itself: the supervisor's record of the same
/// clock set ([`crate::agent::PauseWatch::found`]) waits on its own dispatch.
/// A boot clock that runs through the pause moves nothing here; the pause
/// watch's record covers that ([`hold_if_paused`]).
fn hold_after_restore(paths: &Paths) {
    #[cfg(target_os = "linux")]
    {
        let now = crate::linux::realtime_minus_boottime_ns();
        let mut last = CLOCK_OFFSET.lock().unwrap_or_else(|e| e.into_inner());
        if restore_look(&mut last, now) {
            hold_connects(paths, HoldKind::Resume);
            log("a snapshot restore: no flip during the connect hold");
        }
    }
}

/// Now on the boot clock and the wall clock: `(boot ns, wall ms)`.
pub(super) type Clock<'a> = &'a dyn Fn() -> (i128, u64);

fn clocks() -> (i128, u64) {
    (crate::linux::boottime_ns(), wall_ms())
}

/// The pause count ([`crate::agent::PauseWatch::pause_seq`]) this process's
/// updater last handled, kept across its waits and checks. The role start
/// takes the count then: a pause before it is covered by the start's hold.
static HANDLED: AtomicU64 = AtomicU64::new(0);

/// Starts the connect hold at `now` when `watch` counted a pause after the
/// last one `handled` holds (which it then takes), or is still waking from
/// one: the machine was stopped (paused, restored, forked).
///
/// The updater reads the supervisor's pause watch at its own steps rather
/// than wait for the `Resumed` it leads to. That event comes after the
/// watch's next wake and a metadata read, while this worker's wait or check
/// ends at the resume itself: a claimed spare (a paused machine resumed)
/// flipped 1 to 184 s after its create (production chat probe, 17 of 45
/// runs, 2026-11-07 to 11-08). A count, not a time against the step's start,
/// so a pause found between two steps is never missed.
pub(super) fn hold_if_paused(
    paths: &Paths,
    watch: &crate::agent::PauseWatch,
    handled: &AtomicU64,
    now: (i128, u64),
) -> bool {
    hold_if_paused_past(paths, watch, handled, None, now)
}

/// [`hold_if_paused`], where the pause `own` is the check's own wake
/// ([`own_wake_covers`]) and starts no hold.
fn hold_if_paused_past(
    paths: &Paths,
    watch: &crate::agent::PauseWatch,
    handled: &AtomicU64,
    own: Option<PauseSeen>,
    now: (i128, u64),
) -> bool {
    if !paused_since(watch, handled, own, now) {
        return false;
    }
    // A stop is the machine's own wake (as a resume is): a person's link takes its own connect hold.
    super::gate::hold_connects(paths, now.1, HoldKind::Resume);
    log("the machine was stopped (a pause or restore): no flip during the connect hold");
    true
}

/// Whether `watch` counted a pause after the last one `handled` holds (which
/// it then takes), or is still waking from one, other than the wake `own`
/// ([`own_wake_covers`]); it starts no hold, so it can run inside the gate's
/// flock ([`flip_in_gate`]).
pub(super) fn paused_since(
    watch: &crate::agent::PauseWatch,
    handled: &AtomicU64,
    own: Option<PauseSeen>,
    now: (i128, u64),
) -> bool {
    let seen = watch.seen();
    // Taken first, also for the own wake's count: a later pause counts past it.
    let counted = seen.pauses > handled.fetch_max(seen.pauses, Ordering::SeqCst);
    if own.is_some_and(|own| own_wake_covers(own, seen, now.0)) {
        return false;
    }
    counted || seen.waking(now.0)
}

/// Whether `seen` (a look at boot time `now_ns`) is still the wake `own`,
/// the watch as a `--skip-resume-hold` check found it at its start, still
/// waking from the resume the Scaler's refresh made: the watch has not looked
/// since (the same count and last look), or it counted exactly one pause
/// since, that pause is the one after `own`'s last look (the gap the refresh's
/// resume ended), and it has not been stopped again (it is not waking). A
/// pause counted after any later look names that look, not `own`'s, so it is
/// a new stop, whether or not the first look since counted one (review F1 on
/// ffbe82dc, #39366). A new stop before that first look reads as the same
/// wake (one gap to the watch; the check itself was stopped in it).
pub(super) fn own_wake_covers(own: PauseSeen, seen: PauseSeen, now_ns: i128) -> bool {
    seen == own
        || (seen.pauses == own.pauses.saturating_add(1)
            && seen.pause_from_ns == own.last_look_ns
            && !seen.waking(now_ns))
}

/// The last look before a flip: a pause the watch counted or is waking from
/// other than the check's own wake `own` ([`hold_if_paused`]), or a restore
/// `realtime - boottime` shows from `last` to `offset_now` ([`restore_look`]),
/// starts the connect hold. True when it did.
pub(super) fn flip_look(
    paths: &Paths,
    watch: &crate::agent::PauseWatch,
    handled: &AtomicU64,
    own: Option<PauseSeen>,
    last: &mut Option<i128>,
    offset_now: i128,
    now: (i128, u64),
) -> bool {
    let paused = hold_if_paused_past(paths, watch, handled, own, now);
    let restored = restore_look(last, offset_now);
    if restored {
        super::gate::hold_connects(paths, now.1, HoldKind::Resume);
        log("a snapshot restore: no flip during the connect hold");
    }
    paused || restored
}

/// The pause and restore looks one check makes: the record it reads, the
/// pause count it handled, its last `realtime - boottime` and the watch as
/// the check found it at its start.
pub(super) struct Looks<'a> {
    pub(super) watch: &'a crate::agent::PauseWatch,
    pub(super) handled: &'a AtomicU64,
    pub(super) offset: &'a Mutex<Option<i128>>,
    pub(super) start: PauseSeen,
}

impl Looks<'static> {
    /// The service's worker: the supervisor's own watch, kept across steps.
    fn worker() -> Looks<'static> {
        Looks {
            watch: &crate::agent::PAUSES,
            handled: &HANDLED,
            offset: &CLOCK_OFFSET,
            start: crate::agent::PAUSES.seen(),
        }
    }
}

/// The stops one check looks for before its flip and inside its gate.
///
/// Review F1 of #39032 at 51f0d38f: with `--skip-resume-hold`, the Scaler's
/// refresh runs right after the resume it made, and the pause watch can still
/// be waking from that resume (or count it) during the check. That is the
/// wake whose hold the flag skips, so it is no stop ([`own_wake_covers`]). A
/// new pause or restore during the check still is: a look before the gate
/// that finds one starts a resume hold, which the flag would skip, so the
/// stop is kept here and stops the flip inside the gate whatever `honor` is.
pub(super) struct Stops<'l, 'a> {
    looks: &'l Looks<'a>,
    /// The wake the check's skipped resume hold covers.
    own: Option<PauseSeen>,
    /// A stop a look before the gate found.
    found: Cell<bool>,
}

impl<'l, 'a> Stops<'l, 'a> {
    /// At the check's start (boot time `now_ns`): with `honor`
    /// [`Honor::AllButResume`] and the watch still waking, that wake is the
    /// refresh's own.
    pub(super) fn new(looks: &'l Looks<'a>, honor: Honor, now_ns: i128) -> Self {
        let own =
            (honor == Honor::AllButResume && looks.start.waking(now_ns)).then_some(looks.start);
        Stops { looks, own, found: Cell::new(false) }
    }

    /// The look before the gate ([`flip_look`]).
    pub(super) fn before_gate(&self, paths: &Paths, offset_now: i128, now: (i128, u64)) -> bool {
        let mut last = self.looks.offset.lock().unwrap_or_else(|e| e.into_inner());
        let looks = self.looks;
        let stop =
            flip_look(paths, looks.watch, looks.handled, self.own, &mut last, offset_now, now);
        self.note(stop)
    }

    /// The pause count read again right before the gate ([`hold_if_paused`]).
    pub(super) fn recount(&self, paths: &Paths, now: (i128, u64)) -> bool {
        let looks = self.looks;
        let stop = hold_if_paused_past(paths, looks.watch, looks.handled, self.own, now);
        self.note(stop)
    }

    /// Inside the gate, after the carrier look: whether a look before found
    /// a stop, or a pause or restore came since (its query can take
    /// seconds). It starts no hold: the gate's flock is held.
    pub(super) fn in_gate(&self, offset_now: i128, now: (i128, u64)) -> bool {
        let paused = paused_since(self.looks.watch, self.looks.handled, self.own, now);
        let mut last = self.looks.offset.lock().unwrap_or_else(|e| e.into_inner());
        let restored = restore_look(&mut last, offset_now);
        self.found.get() || paused || restored
    }

    fn note(&self, stop: bool) -> bool {
        if stop {
            self.found.set(true);
        }
        stop
    }
}

/// The looks of a check outside the service's process (the operator's
/// `cmux host update check`): the record the service's watch writes
/// ([`super::PAUSE_FILE`]), read again at every look, with this check's own
/// pause count and restore look, both taken at its start.
pub(super) struct OtherLook {
    watch: crate::agent::PauseWatch,
    handled: AtomicU64,
    offset: Mutex<Option<i128>>,
    start: PauseSeen,
}

impl OtherLook {
    pub(super) fn start(paths: &Paths, offset_now: i128) -> OtherLook {
        let watch = crate::agent::PauseWatch::load(&paths.at(super::PAUSE_FILE));
        // One look for the count handled and the start ([`Stops::new`]).
        let start = watch.seen();
        let handled = AtomicU64::new(start.pauses);
        OtherLook { watch, handled, offset: Mutex::new(Some(offset_now)), start }
    }

    pub(super) fn looks(&self) -> Looks<'_> {
        Looks {
            watch: &self.watch,
            handled: &self.handled,
            offset: &self.offset,
            start: self.start,
        }
    }
}

/// [`wait`], then the pause look over it ([`hold_if_paused`]).
fn wait_watching(paths: &Paths, rx: &Receiver<Msg>, d: Duration) -> bool {
    let go_on = wait(rx, d);
    if go_on {
        hold_if_paused(paths, &crate::agent::PAUSES, &HANDLED, clocks());
    }
    go_on
}

/// How much of the connect hold is left now.
pub(super) fn held_for(paths: &Paths) -> Option<Duration> {
    Gate::new(paths).held_left(wall_ms())
}

thread_local! {
    static WORKER_GENERATION: Cell<Option<u64>> = const { Cell::new(None) };
}

fn stopped() -> bool {
    WORKER_GENERATION.with(Cell::get).is_some_and(|mine| mine != GENERATION.load(Ordering::SeqCst))
}

struct Worker {
    tx: Sender<Msg>,
    thread: JoinHandle<()>,
    done: Receiver<()>,
}

/// The role `cmux host run` starts last on a bound Cloud machine.
pub struct UpdaterRole {
    paths: Paths,
    worker: Option<Worker>,
}

impl UpdaterRole {
    pub fn new(paths: Paths) -> Self {
        Self { paths, worker: None }
    }

    fn halt(&mut self, deadline: Instant) -> Result<(), RoleError> {
        let Some(worker) = self.worker.take() else { return Ok(()) };
        let _ = worker.tx.send(Msg::Stop);
        // Bump the generation under COMMIT, so a flip in progress finishes
        // first and none starts after.
        loop {
            match COMMIT.try_lock() {
                Ok(_commit) => {
                    GENERATION.fetch_add(1, Ordering::SeqCst);
                    break;
                }
                Err(std::sync::TryLockError::Poisoned(e)) => {
                    let _commit = e.into_inner();
                    GENERATION.fetch_add(1, Ordering::SeqCst);
                    break;
                }
                Err(std::sync::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(std::sync::TryLockError::WouldBlock) => {
                    return Err(RoleError("updater was flipping at the deadline".to_owned()));
                }
            }
        }
        match worker.done.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Err(RecvTimeoutError::Timeout) => {
                // The worker kills its download and stops before it changes
                // anything more; a restart command is bounded and ends on its own.
                Err(RoleError("updater did not stop by the deadline".to_owned()))
            }
            _ => {
                let _ = worker.thread.join();
                Ok(())
            }
        }
    }
}

impl Role for UpdaterRole {
    fn name(&self) -> &str {
        "updater"
    }

    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        // A Cloud machine only: bound, the system root, the image's store.
        if ctx.instance_id.is_none() || !self.paths.is_system_root() || self.worker.is_some() {
            return Ok(());
        }
        if !self.paths.at(store::CURRENT_LINK).exists() {
            return Ok(());
        }
        hold_connects(&self.paths, HoldKind::Resume);
        hold_after_restore(&self.paths);
        HANDLED.store(crate::agent::PAUSES.pause_seq(), Ordering::SeqCst);
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let paths = self.paths.clone();
        let generation = GENERATION.load(Ordering::SeqCst);
        let thread = std::thread::Builder::new()
            .name("cmux-host-updater".to_owned())
            .spawn(move || {
                let _done = done_tx;
                WORKER_GENERATION.with(|g| g.set(Some(generation)));
                run(&paths, &rx);
            })
            .map_err(|e| RoleError(e.to_string()))?;
        self.worker = Some(Worker { tx, thread, done });
        Ok(())
    }

    fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError> {
        self.halt(ctx.deadline)
    }

    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        match event {
            HostEvent::Resumed | HostEvent::Bound { .. } | HostEvent::ChannelChanged => {
                // A resume is the machine's own wake; `Bound` is a person's machine.
                match event {
                    HostEvent::Resumed => {
                        hold_connects(&self.paths, HoldKind::Resume);
                    }
                    HostEvent::Bound { .. } => {
                        hold_connects(&self.paths, HoldKind::Connect);
                    }
                    _ => {}
                }
                if let Some(worker) = &self.worker {
                    let _ = worker.tx.send(Msg::Check);
                }
                Ok(())
            }
            HostEvent::Parked { deadline } | HostEvent::Shutdown { deadline } => {
                self.halt(*deadline)
            }
            _ => Ok(()),
        }
    }
}

/// Waits `d` or until a message: false when the role stops.
fn wait(rx: &Receiver<Msg>, d: Duration) -> bool {
    match rx.recv_timeout(d) {
        Ok(Msg::Check) | Err(RecvTimeoutError::Timeout) => true,
        Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => false,
    }
}

fn run(paths: &Paths, rx: &Receiver<Msg>) {
    if let Some(pending) = load_pending(paths)
        && !resolve(paths, &pending, rx)
    {
        return;
    }
    if !wait_watching(paths, rx, BOOT_DELAY) {
        return;
    }
    loop {
        // A check during the hold waits it out (a Check message only wakes it
        // to look again).
        hold_after_restore(paths);
        if let Some(left) = held_for(paths) {
            if !wait_watching(paths, rx, left) {
                return;
            }
            continue;
        }
        let (outcome, _) = check(paths, Honor::All);
        let next = if matches!(outcome, Outcome::Busy(_)) { BUSY_RETRY } else { INTERVAL };
        if !wait_watching(paths, rx, next) {
            return;
        }
    }
}

/// What one check did.
#[derive(Debug)]
pub enum Outcome {
    Off(String),
    Current(String),
    Older,
    RolledBackBefore,
    Busy(Vec<String>),
    /// The flip happened; this process is about to be restarted.
    Updating(String),
    Failed(String),
}

impl Outcome {
    fn line(&self) -> String {
        match self {
            Outcome::Off(why) => format!("off: {why}"),
            Outcome::Current(commit) => format!("current ({commit})"),
            Outcome::Older => "the channel's build is older than the one applied here".to_owned(),
            Outcome::RolledBackBefore => "the channel's build was rolled back here".to_owned(),
            Outcome::Busy(names) => format!("waiting for idle: {}", names.join(", ")),
            Outcome::Updating(commit) => format!("updating to {commit}"),
            Outcome::Failed(why) => format!("failed: {why}"),
        }
    }

    /// The operator verb's answer; `skipped_hold` names the hold the check
    /// went past (`--skip-resume-hold`), so the Scaler can count them.
    pub(super) fn json(&self, skipped_hold: Option<HoldKind>) -> Value {
        let state = match self {
            Outcome::Off(_) => "off",
            Outcome::Current(_) => "current",
            Outcome::Older => "older",
            Outcome::RolledBackBefore => "rolled-back-before",
            Outcome::Busy(_) => "busy",
            Outcome::Updating(_) => "updating",
            Outcome::Failed(_) => "failed",
        };
        let mut v = json!({"state": state, "detail": self.line()});
        if let (Some(kind), Some(map)) = (skipped_hold, v.as_object_mut()) {
            map.insert("skipped_hold".into(), json!(kind.name()));
        }
        v
    }
}

/// The updater's lock (`<state>/lock`, flock): one check, commit, rollback
/// or guard at a time, in this process or another (`cmux host update
/// check`). Released when the holder exits, also when the restart ends it.
struct Lock {
    _file: fs::File,
}

impl Lock {
    fn take(paths: &Paths, wait: bool) -> Option<Lock> {
        use std::os::unix::io::AsRawFd as _;
        let dir = paths.at(super::STATE_DIR);
        fs::create_dir_all(&dir).ok()?;
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(dir.join("lock"))
            .ok()?;
        let flags = if wait { libc::LOCK_EX } else { libc::LOCK_EX | libc::LOCK_NB };
        // SAFETY: flock on a descriptor this function owns.
        (unsafe { libc::flock(file.as_raw_fd(), flags) } == 0).then_some(Lock { _file: file })
    }
}

/// One check, honoring the holds `honor` names; on an update this ends with
/// `cmux-host.service` restarting. With the outcome, the hold the flip went
/// past, if it went past one.
pub fn check(paths: &Paths, honor: Honor) -> (Outcome, Option<HoldKind>) {
    let Some(_lock) = Lock::take(paths, false) else {
        return (Outcome::Failed("another update check runs".to_owned()), None);
    };
    // The service's own watch; in another process (the operator's check), the
    // record that watch writes, with this check's own count and restore look.
    let other;
    let looks = if crate::agent::PAUSES.has_looked() {
        Looks::worker()
    } else {
        other = OtherLook::start(paths, crate::linux::realtime_minus_boottime_ns());
        other.looks()
    };
    let stops = Stops::new(&looks, honor, clocks().0);
    let mut skipped = None;
    let outcome = check_step(paths, looks.watch, looks.handled, &clocks, || {
        check_inner(paths, &stops, honor, &mut skipped)
    });
    let mut state = load_state(paths);
    let line = outcome.line();
    if state.last.as_deref() != Some(line.as_str()) {
        log(&line);
    }
    if let Some(kind) = skipped {
        log(&format!("went past a {} hold (--skip-resume-hold): {line}", kind.name()));
    }
    state.last = Some(line);
    state.last_at = now();
    let _ = save_state(paths, &state);
    (outcome, skipped)
}

/// Runs one check (`inner`), then the pause look over it on every way out
/// but a flip (which looked right before it): a check that returned early
/// after a pause (a busy look that timed out across it) starts the connect
/// hold, or a flip could follow a minute later.
pub(super) fn check_step(
    paths: &Paths,
    watch: &crate::agent::PauseWatch,
    handled: &AtomicU64,
    clock: Clock<'_>,
    inner: impl FnOnce() -> Outcome,
) -> Outcome {
    let outcome = inner();
    if !matches!(outcome, Outcome::Updating(_)) {
        hold_if_paused(paths, watch, handled, clock());
    }
    outcome
}

/// [`check`]'s work, honoring the holds `honor` names, with its pause and
/// restore looks (`stops`); `skipped` gets the hold the flip's gate went past.
fn check_inner(
    paths: &Paths,
    stops: &Stops<'_, '_>,
    honor: Honor,
    skipped: &mut Option<HoldKind>,
) -> Outcome {
    if let Some(why) = off_reason(paths) {
        return Outcome::Off(why);
    }
    if load_pending(paths).is_some() {
        return Outcome::Failed("an update is waiting for its health check".to_owned());
    }
    let Some(target) = channel::local_target() else {
        return Outcome::Off(format!("no build for {}", std::env::consts::ARCH));
    };
    let body = match fetch(CHANNEL_URL, CHANNEL_MAX_BYTES as u64, None) {
        Ok(body) => body,
        Err(e) => return Outcome::Failed(format!("reading {CHANNEL_URL}: {e}")),
    };
    let payload = match channel::verify(&body, &channel::trusted_keys(), now()) {
        Ok(payload) => payload,
        Err(e) => return Outcome::Failed(format!("refusing {CHANNEL_URL}: {e}")),
    };
    let mut state = load_state(paths);
    let plan = match decide(paths, &state, &payload, target) {
        Ok(Decision::Update(plan)) => plan,
        Ok(Decision::Current) => return Outcome::Current(payload.commit),
        Ok(Decision::Older) => return Outcome::Older,
        Ok(Decision::RolledBack) => return Outcome::RolledBackBefore,
        Err(e) => return Outcome::Failed(e),
    };
    match busy_sessions(paths) {
        Ok(busy) if busy.is_empty() => {}
        Ok(busy) => return Outcome::Busy(busy),
        Err(e) => return Outcome::Busy(vec![e]),
    }
    if let Err(e) = stage(paths, &plan) {
        return Outcome::Failed(e);
    }
    if stopped() {
        return Outcome::Failed("the updater stopped".to_owned());
    }
    if let Err(e) = store::build_profile(paths, plan.from, plan.to, &plan.replacements()) {
        return Outcome::Failed(format!("building profile {}: {e}", plan.to));
    }
    record_installed(&mut state, &plan);
    let _ = save_state(paths, &state);
    let pending = plan.pending(now());
    if let Err(e) = save_pending(paths, &pending) {
        return Outcome::Failed(format!("recording the update: {e}"));
    }
    if let Err(e) = arm_guard(&pending) {
        clear_pending(paths);
        return Outcome::Failed(format!("arming the guard: {e}"));
    }
    // Everything is staged: the last look is right before the flip and the
    // restarts, so a turn can only start in the milliseconds between them,
    // and acpmux's restart keeps and adopts even that one's agent. The
    // carrier sessions' last look is inside the gate ([`flip_in_gate`]).
    let last = match off_reason(paths) {
        Some(why) => Some(Outcome::Off(why)),
        None => match acpmux_busy_sessions() {
            Ok(busy) if busy.is_empty() => None,
            Ok(busy) => Some(Outcome::Busy(busy)),
            Err(e) => Some(Outcome::Busy(vec![e])),
        },
    };
    let commit = COMMIT.lock().unwrap_or_else(|e| e.into_inner());
    // A stop during this check (its download, its busy look) holds its flip.
    stops.before_gate(paths, crate::linux::realtime_minus_boottime_ns(), clocks());
    let last =
        last.or_else(|| stopped().then(|| Outcome::Failed("the updater stopped".to_owned())));
    if let Some(outcome) = last {
        drop(commit);
        disarm_guard();
        clear_pending(paths);
        return outcome;
    }
    // The pause count read again right before the gate, which then sees the
    // hold a pause found since the look above starts (a resume-kind hold:
    // the machine's own wake).
    stops.recount(paths, clocks());
    // The connect hold's last look, the carrier sessions' last look, the flip
    // and the queued restarts run inside the gate (`Gate::run`, shared with
    // every process): a bind or a new session that takes the hold before the
    // restart is seen here, and one after waits.
    // After the carrier look (inside the gate): a stop a look above found
    // (its resume hold is one `--skip-resume-hold` skips), or a pause or
    // restore during the query.
    let stopped = || stops.in_gate(crate::linux::realtime_minus_boottime_ns(), clocks());
    let carrier = || carrier_sessions_within(CARRIER_READ_IN_GATE);
    let (flipped, went_past) = flip_in_gate(paths, wall_ms, honor, carrier, stopped, |inside| {
        store::flip(paths, plan.to)?;
        log(&format!(
            "profile {} -> {}: cmux-tui {} ({}); restarting the services",
            plan.from,
            plan.to,
            short_hex(&plan.cmux_tui.sha256),
            short_hex(&plan.commit)
        ));
        inside.restart_queued(wall_ms());
        restart_after_flip(&store_binary(&plan.old_cmux_tui));
        Ok::<(), std::io::Error>(())
    });
    drop(commit);
    *skipped = went_past;
    if !matches!(flipped, Gated::Flipped) {
        disarm_guard();
        clear_pending(paths);
    }
    match flipped {
        Gated::Flipped => Outcome::Updating(plan.commit),
        Gated::Held(left) => connect_hold_busy(left),
        Gated::Busy(why) => Outcome::Busy(vec![why]),
        Gated::Off(why) => Outcome::Off(why),
        Gated::Failed(e) => Outcome::Failed(format!("flipping to profile {}: {e}", plan.to)),
    }
}

/// `cmux host update adopt`: puts a machine whose software predates the self-update (or
/// whose work link the Mac app's in-place update replaced, which turns the updater off)
/// on the channel's build once, from outside: a client runs it over the Cloud exec route
/// with a copy of the new build when the machine never registers on the carrier relay
/// (cmuxterm-hq#7086). Such a machine's link is down, so nothing waits on it: unlike
/// [`check`] it honors no hold and reads no busy session or carrier session (the old
/// build answers neither), and runs as soon as it is asked. It relinks the work user's
/// cmux-tui into `current` ([`super::relink_work_link`]), then stages, builds and flips
/// the next profile as [`check`] does, records the update as pending and restarts the
/// services: the new `cmux host run` proves it or rolls it back ([`healthy`]), and its
/// guard is the new build's own (the old one has no `host update guard`). From then on
/// the machine updates itself. A rollback after the flip leaves the work link on
/// `current`, that is on the image's build, not the file the Mac app had put there
/// (kept at [`super::WORK_CMUX_TUI_KEPT`]).
pub fn adopt(paths: &Paths) -> Outcome {
    let Some(_lock) = Lock::take(paths, false) else {
        return Outcome::Failed("another update check runs".to_owned());
    };
    if paths.at(super::OFF_FILE).exists() {
        return Outcome::Off(format!("{} exists", super::OFF_FILE));
    }
    if load_pending(paths).is_some() {
        return Outcome::Failed("an update is waiting for its health check".to_owned());
    }
    let Some(target) = channel::local_target() else {
        return Outcome::Off(format!("no build for {}", std::env::consts::ARCH));
    };
    let body = match fetch(CHANNEL_URL, CHANNEL_MAX_BYTES as u64, None) {
        Ok(body) => body,
        Err(e) => return Outcome::Failed(format!("reading {CHANNEL_URL}: {e}")),
    };
    let payload = match channel::verify(&body, &channel::trusted_keys(), now()) {
        Ok(payload) => payload,
        Err(e) => return Outcome::Failed(format!("refusing {CHANNEL_URL}: {e}")),
    };
    let mut state = load_state(paths);
    let plan = match decide(paths, &state, &payload, target) {
        Ok(Decision::Update(plan)) => plan,
        Ok(Decision::Current) => return Outcome::Current(payload.commit),
        Ok(Decision::Older) => return Outcome::Older,
        Ok(Decision::RolledBack) => return Outcome::RolledBackBefore,
        Err(e) => return Outcome::Failed(e),
    };
    if let Err(e) = stage(paths, &plan) {
        return Outcome::Failed(e);
    }
    if let Err(e) = store::build_profile(paths, plan.from, plan.to, &plan.replacements()) {
        return Outcome::Failed(format!("building profile {}: {e}", plan.to));
    }
    record_installed(&mut state, &plan);
    let _ = save_state(paths, &state);
    let pending = plan.pending(now());
    if let Err(e) = save_pending(paths, &pending) {
        return Outcome::Failed(format!("recording the update: {e}"));
    }
    // The new profile's own `cmux` (the binary has `host` only under that name).
    let guard = store::profile_dir(paths, plan.to).join("bin/cmux");
    if let Err(e) = arm_guard_with(&pending, &guard) {
        clear_pending(paths);
        return Outcome::Failed(format!("arming the guard: {e}"));
    }
    let commit = COMMIT.lock().unwrap_or_else(|e| e.into_inner());
    // Last before the flip, so a step that failed above left the work link as it was.
    let relinked = match super::relink_work_link(paths) {
        Ok(relinked) => relinked,
        Err(e) => {
            drop(commit);
            disarm_guard();
            clear_pending(paths);
            return Outcome::Failed(format!("relinking {}: {e}", super::WORK_CMUX_TUI_LINK));
        }
    };
    if let Err(e) = store::flip(paths, plan.to) {
        super::restore_work_link(paths, relinked);
        drop(commit);
        disarm_guard();
        clear_pending(paths);
        return Outcome::Failed(format!("flipping to profile {}: {e}", plan.to));
    }
    if relinked != super::Relinked::Unchanged {
        log(&format!("{} links {} again", super::WORK_CMUX_TUI_LINK, super::CURRENT_CMUX_TUI));
    }
    log(&format!(
        "adopt: profile {} -> {}: cmux-tui {} ({}); restarting the services",
        plan.from,
        plan.to,
        short_hex(&plan.cmux_tui.sha256),
        short_hex(&plan.commit)
    ));
    restart_after_flip(&store_binary(&plan.old_cmux_tui));
    drop(commit);
    Outcome::Updating(plan.commit)
}

/// What the flip's step inside the gate did.
#[derive(Debug)]
pub(super) enum Gated<E> {
    Flipped,
    /// A hold the check honors is on (also one a new carrier session just took).
    Held(Duration),
    /// Attached carrier sessions hold the update.
    Busy(String),
    /// [`super::OFF_FILE`] appeared.
    Off(String),
    Failed(E),
}

/// The flip's last step, inside the gate (its flock held, [`Gate::run`]): the
/// holds `honor` honors, [`super::OFF_FILE`], then a live look at the
/// carrier sessions (`carrier`), then `flip` (the flip and its restarts; it calls
/// `restart_queued` between them). The carrier look is under the flock, so a
/// session that attached after the hold was read is seen here, and a new one
/// takes its connect hold under the same flock and stops this flip. The
/// carrier look can take seconds (its query's bound inside the gate is
/// [`CARRIER_READ_IN_GATE`]; one past it is busy), so `stopped`
/// looks for a pause or restore again after it: one during the query starts
/// the hold (resume kind) and stops this flip whatever `honor` is, as a pause
/// found before the gate would. Each hold starts at `clock()` when it is
/// taken, after the look, not at the run's start. With the hold the run went
/// past (`--skip-resume-hold`), if any.
pub(super) fn flip_in_gate<E>(
    paths: &Paths,
    clock: impl Fn() -> u64,
    honor: Honor,
    carrier: impl FnOnce() -> Result<Vec<String>, Unread>,
    stopped: impl FnOnce() -> bool,
    flip: impl FnOnce(&super::gate::Inside) -> Result<(), E>,
) -> (Gated<E>, Option<HoldKind>) {
    let ran = Gate::new(paths).run(clock(), honor, |inside| {
        if paths.at(super::OFF_FILE).exists() {
            return (Gated::Off(format!("{} exists", super::OFF_FILE)), inside.skipped());
        }
        let new_session = Cell::new(false);
        let busy = match carrier() {
            // No answer within the in-gate bound: busy, and no carrier look
            // (it starts no bound and forgets no session), so a slow channel
            // never reads as no sessions, also past the carrier hold's bound.
            Err(Unread::TimedOut(limit)) => Some(format!(
                "carrier sessions unknown (no answer within {} s inside the gate)",
                limit.as_secs()
            )),
            read => carrier_look(read.map_err(Unread::why), || {
                inside.hold_connects(clock());
                new_session.set(true);
            }),
        };
        let gated = match busy {
            Some(why) => Gated::Busy(why),
            None if new_session.get() => Gated::Held(CONNECT_HOLD),
            None if stopped() => {
                inside.hold(HoldKind::Resume, clock());
                log("the machine was stopped during the carrier look: no flip during the connect hold");
                Gated::Held(CONNECT_HOLD)
            }
            None => match flip(inside) {
                Ok(()) => Gated::Flipped,
                Err(e) => Gated::Failed(e),
            },
        };
        (gated, inside.skipped())
    });
    ran.unwrap_or_else(|left| (Gated::Held(left), None))
}

/// The first 12 characters of a hash for a log line; a shorter or non-ASCII text is logged whole, never sliced
/// inside a character.
pub(super) fn short_hex(hash: &str) -> &str {
    hash.get(..12).unwrap_or(hash)
}

fn store_binary(sha: &str) -> PathBuf {
    Path::new(STORE_DIR).join(sha).join(CMUX_TUI)
}

/// Downloads what the store lacks, each checked against the signed sha256 and size.
fn stage(paths: &Paths, plan: &Plan) -> Result<(), String> {
    let need: Vec<_> = [(&plan.cmux_tui, CMUX_TUI), (&plan.cmux_tui_hook, CMUX_TUI_HOOK)]
        .into_iter()
        .filter(|(bin, name)| !store::has_entry(paths, &bin.sha256, name))
        .collect();
    let total: u64 = need.iter().map(|(bin, _)| bin.size).sum();
    if let Some(free) = free_bytes(&paths.at(store::STORE_ROOT))
        && free < total.saturating_mul(2) + (256 << 20)
    {
        return Err(format!("{free} bytes free; the update needs {total} and room to spare"));
    }
    let dir = paths.at(DOWNLOAD_DIR);
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for (bin, name) in need {
        let file = dir.join(format!("{}-{name}", bin.sha256));
        let _ = fs::remove_file(&file);
        fetch(&bin.url, bin.size, Some(&file))
            .map_err(|e| format!("downloading {}: {e}", bin.url))?;
        let size = fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        if size != bin.size {
            let _ = fs::remove_file(&file);
            return Err(format!("{} is {size} bytes, not the channel's {}", bin.url, bin.size));
        }
        if let Err(e) = store::add_entry(paths, &bin.sha256, name, &file) {
            let _ = fs::remove_file(&file);
            return Err(format!("{}: {e}", bin.url));
        }
    }
    Ok(())
}

fn free_bytes(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: a valid C string and an out parameter of the right type.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    Some(st.f_bavail as u64 * st.f_frsize as u64)
}

/// HTTPS GET with curl (the image has it; no redirects), at most `max`
/// bytes; into `out`, or the body.
fn fetch(url: &str, max: u64, out: Option<&Path>) -> Result<Vec<u8>, String> {
    let mut cmd = Command::new("curl");
    cmd.args(["--fail", "--silent", "--show-error", "--proto", "=https", "--tlsv1.2"])
        .args(["--connect-timeout", "20", "--max-time", "900", "--retry", "2"])
        .arg("--max-filesize")
        .arg(max.to_string());
    if let Some(out) = out {
        cmd.arg("--output").arg(out);
    }
    let mut child = cmd
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("curl: {e}"))?;
    // Read both pipes on their own threads so curl never blocks on a full
    // one while this thread watches for a stop.
    let drain = |pipe: Option<Box<dyn std::io::Read + Send>>, limit: u64| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(pipe) = pipe {
                let _ = pipe.take(limit + 1).read_to_end(&mut buf);
            }
            buf
        })
    };
    let stdout = drain(child.stdout.take().map(|p| Box::new(p) as _), max);
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as _), 64 << 10);
    let status = loop {
        if stopped() {
            // Our own child: kill and reap it.
            let _ = child.kill();
            let _ = child.wait();
            return Err("the updater stopped".to_owned());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(e) => return Err(format!("curl: {e}")),
        }
    };
    let body = stdout.join().unwrap_or_default();
    if !status.success() {
        let err = stderr.join().unwrap_or_default();
        return Err(String::from_utf8_lossy(&err).trim().to_owned());
    }
    if body.len() as u64 > max {
        return Err("the body is over its limit".to_owned());
    }
    Ok(body)
}

/// `acpmux …` as the work user, at most 20 s: whether it exited 0, and its stdout.
fn acpmux(args: &[&str]) -> Option<(bool, String)> {
    let user = crate::linux::spawn::lookup_user(WORK_USER)?;
    let output = Command::new("timeout")
        .args(["20", "runuser", "-u", WORK_USER, "--", "env"])
        .arg(format!("HOME={WORK_HOME}"))
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{}", user.uid))
        .arg(CURRENT_ACPMUX)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some((output.status.success(), String::from_utf8_lossy(&output.stdout).into_owned()))
}

/// What a restart would cut: the attached carrier sessions ([`carrier_busy`],
/// bounded), then [`acpmux_busy_sessions`]. Empty only when both are idle.
fn busy_sessions(paths: &Paths) -> Result<Vec<String>, String> {
    let carrier = carrier_busy(paths);
    let mut busy = acpmux_busy_sessions()?;
    busy.extend(carrier);
    Ok(busy)
}

/// The carrier hold between looks ([`super::carrier`]).
static CARRIER: Mutex<Option<CarrierHold>> = Mutex::new(None);

/// One look at the session host's carrier sessions: why they hold the
/// update, if they do. A new session starts the connect hold, so a claimed
/// spare's first link is never cut, also past the carrier hold's bound.
fn carrier_busy(paths: &Paths) -> Option<String> {
    carrier_busy_from(paths, carrier_sessions())
}

/// [`carrier_busy`] for a rollback: only sessions the list shows hold it,
/// under the same bound. A list that can't be read holds nothing here: the
/// session host that would answer is the build being rolled back, and
/// keeping a broken build is worse than a restart (#37280).
fn rollback_carrier_busy(paths: &Paths) -> Option<String> {
    carrier_sessions().ok().and_then(|ids| carrier_busy_from(paths, Ok(ids)))
}

/// [`carrier_busy`] for the sessions one look read.
pub(super) fn carrier_busy_from(
    paths: &Paths,
    sessions: Result<Vec<String>, String>,
) -> Option<String> {
    carrier_look(sessions, || {
        hold_connects(paths, HoldKind::Connect);
    })
}

/// One look at the carrier sessions through the hold between looks
/// ([`CARRIER`]); a new session calls `start_hold`.
fn carrier_look(
    sessions: Result<Vec<String>, String>,
    start_hold: impl FnOnce(),
) -> Option<String> {
    let mut hold = CARRIER.lock().unwrap_or_else(|e| e.into_inner());
    let look = hold.get_or_insert_with(CarrierHold::default).look(Instant::now(), sessions);
    drop(hold);
    act_on_look(look, start_hold)
}

/// What one carrier look does: a new session starts the connect hold
/// (`start_hold`), the bound is logged once, and the answer is why the
/// update waits, if it does.
pub(super) fn act_on_look(look: CarrierLook, start_hold: impl FnOnce()) -> Option<String> {
    if look.new_session {
        start_hold();
        log("a new carrier session: no flip during the connect hold");
    }
    if look.bound_passed {
        log(&format!(
            "carrier sessions held this update for {} min; it goes at the next idle gap",
            CARRIER_MAX_HOLD.as_secs() / 60
        ));
    }
    look.busy
}

/// The bound of a carrier read outside the gate.
const CARRIER_READ: Duration = Duration::from_secs(20);

/// The bound of the flip's carrier read inside the gate ([`flip_in_gate`]):
/// the gate's flock is held meanwhile, so every bind and hold on the machine
/// waits on it. A read that runs past it holds the flip as busy
/// ([`Unread::TimedOut`]), never as no sessions.
pub(super) const CARRIER_READ_IN_GATE: Duration = Duration::from_secs(4);

/// Why one read of the carrier sessions has no list.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Unread {
    /// The query ran past its bound (`timeout`'s exit status 124).
    TimedOut(Duration),
    /// Any other failure.
    Failed(String),
}

impl Unread {
    /// The failure an exited query's `status` shows, run under `limit`.
    pub(super) fn of(status: std::process::ExitStatus, limit: Duration) -> Unread {
        if status.code() == Some(124) {
            Unread::TimedOut(limit)
        } else {
            Unread::Failed(format!("its admin channel answered {status}"))
        }
    }

    fn why(self) -> String {
        match self {
            Unread::TimedOut(limit) => {
                format!("its admin channel did not answer within {} s", limit.as_secs())
            }
            Unread::Failed(why) => why,
        }
    }
}

/// [`carrier_sessions_within`] the bound outside the gate.
fn carrier_sessions() -> Result<Vec<String>, String> {
    carrier_sessions_within(CARRIER_READ).map_err(Unread::why)
}

/// The attached carrier sessions, from the session host's admin channel
/// (`cmux-tui remote enroll connections --json`, at most `limit`), run as the
/// user and home the session host runs with (the layout marker), since the
/// channel answers only its own user.
fn carrier_sessions_within(limit: Duration) -> Result<Vec<String>, Unread> {
    let marker = fs::read_to_string(Paths::new("/").at(crate::config::LAYOUT_MARKER_FILE)).ok();
    let home =
        crate::cloud::daemon_noise_key::session_home(marker.as_deref()).ok_or_else(|| {
            Unread::Failed("the session host's layout is not recorded yet".to_owned())
        })?;
    let mut cmd = Command::new("timeout");
    cmd.arg(limit.as_secs().max(1).to_string());
    if home != Path::new(crate::daemon_spec::ROOT_HOME) {
        cmd.args(["runuser", "-u", WORK_USER, "--"]);
    }
    cmd.arg("env")
        .arg(format!("HOME={}", home.display()))
        .arg(super::CURRENT_CMUX_TUI)
        .args(["remote", "enroll", "connections", "--session", crate::daemon_spec::SESSION])
        .arg("--json");
    let stdout = output_within(cmd, limit)?;
    super::carrier::attached_sessions_in(&String::from_utf8_lossy(&stdout))
        .ok_or_else(|| Unread::Failed("its connection list is unreadable".to_owned()))
}

/// How long past its `timeout` bound a read may run before [`output_within`]
/// kills its process group: `timeout` only sends SIGTERM and waits, so a
/// child that ignores it (or a grandchild under `runuser` that keeps stdout
/// open) would hold the caller, and the gate's flock with it, past the bound
/// (review F1 on #39366 at 6ac5a558).
pub(super) const READ_KILL_AFTER: Duration = Duration::from_secs(1);

/// The stdout of `cmd` (a `timeout LIMIT ...` command line) once it exits 0,
/// read under a hard deadline of `limit` + [`READ_KILL_AFTER`]: past it, the
/// whole process group the command leads is killed and the read is
/// [`Unread::TimedOut`], whatever the children do with SIGTERM or the pipe.
pub(super) fn output_within(mut cmd: Command, limit: Duration) -> Result<Vec<u8>, Unread> {
    use std::os::unix::process::CommandExt as _;
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|e| Unread::Failed(format!("cmux-tui: {e}")))?;
    let pid = child.id();
    let mut out = child.stdout.take();
    let (tx, rx) = mpsc::channel();
    // Detached: a reader a killed group's escapee keeps blocked holds nothing but its pipe.
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(out) = out.as_mut() {
            let _ = out.read_to_end(&mut bytes);
        }
        let _ = tx.send(bytes);
    });
    let bytes = match rx.recv_timeout(limit.saturating_add(READ_KILL_AFTER)) {
        Ok(bytes) => bytes,
        Err(_) => {
            let _ = Command::new("kill")
                .args(["-KILL", "--", &format!("-{pid}")])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            let _ = child.wait();
            return Err(Unread::TimedOut(limit));
        }
    };
    let status = child.wait().map_err(|e| Unread::Failed(format!("cmux-tui: {e}")))?;
    if !status.success() {
        return Err(Unread::of(status, limit));
    }
    Ok(bytes)
}

/// The acpmux sessions that run a turn or wait on a permission, by name
/// (as `acpmux host update --if-idle` reads them). Fails closed: an error,
/// which the caller counts as busy, unless acpmux answered. Empty only when
/// it answered that no daemon runs and its unit is down (or absent).
fn acpmux_busy_sessions() -> Result<Vec<String>, String> {
    let (_, status) = acpmux(&["--json", "daemon", "status"]).ok_or("acpmux did not run")?;
    match super::daemon_running(&status) {
        None => return Err("acpmux daemon status is unreadable".to_owned()),
        Some(false) => {
            return match user_unit_state(ACPMUX_UNIT).as_deref() {
                Some("inactive" | "failed") => Ok(Vec::new()),
                _ if !Path::new(ACPMUX_UNIT_FILE).exists() => Ok(Vec::new()),
                state => Err(format!("no acpmux daemon answered, its unit is {state:?}")),
            };
        }
        Some(true) => {}
    }
    let (ok, ls) = acpmux(&["--json", "ls"]).ok_or("acpmux ls did not run")?;
    if !ok {
        return Err("acpmux ls failed".to_owned());
    }
    super::busy_sessions_in(&ls).ok_or_else(|| "acpmux ls is unreadable".to_owned())
}

/// `systemctl --user is-active UNIT` in the work user's manager: its word.
fn user_unit_state(unit: &str) -> Option<String> {
    let user = crate::linux::spawn::lookup_user(WORK_USER)?;
    let output = Command::new("timeout")
        .args(["20", "runuser", "-u", WORK_USER, "--", "env"])
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{}", user.uid))
        .args(["systemctl", "--user", "is-active", unit])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let word = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!word.is_empty()).then_some(word)
}

/// Whether the new build serves: the session host answers `identify` and
/// its process, and the work user's acpmux daemon (where the image runs
/// one), run the new store entry. (A build reports the commit of the first
/// build of its source tree, which need not be the channel's commit, so the
/// executable is what tells the builds apart.)
fn healthy(paths: &Paths, pending: &Pending) -> bool {
    let new = store_binary(&pending.cmux_tui);
    let runs_new = |pid: &str| {
        let pid = pid.trim();
        !pid.is_empty()
            && pid.bytes().all(|b| b.is_ascii_digit())
            && fs::read_link(format!("/proc/{pid}/exe")).ok().as_deref() == Some(new.as_path())
    };
    let serving = crate::cloud::role::daemon_socket(paths).is_some_and(|socket| {
        crate::cloud::role::query_identify(&socket, Duration::from_secs(2)).is_ok()
    });
    let session_host = serving
        && fs::read_to_string(paths.at(crate::config::DAEMON_PID_FILE))
            .is_ok_and(|pid| runs_new(&pid));
    if !session_host {
        return false;
    }
    if !paths.at(ACPMUX_UNIT_FILE).exists() {
        return true;
    }
    acpmux(&["--json", "daemon", "status"])
        .and_then(|(_, status)| serde_json::from_str::<Value>(status.trim()).ok())
        .and_then(|v| v.get("pid").and_then(Value::as_u64))
        .is_some_and(|pid| runs_new(&pid.to_string()))
}

/// Before a rollback's restart: waits while `carrier` says carrier sessions
/// hold it (the flip's own rule, [`carrier_busy`], with its
/// [`CARRIER_MAX_HOLD`] bound), looking again every [`BUSY_RETRY`] through
/// `wait`. False when `wait` says the waiter stopped.
pub(super) fn rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    mut wait: impl FnMut(Duration) -> bool,
) -> bool {
    let mut logged = false;
    while let Some(why) = carrier() {
        if !logged {
            log(&format!("the rollback waits: {why}"));
            logged = true;
        }
        if !wait(BUSY_RETRY) {
            return false;
        }
    }
    true
}

/// The health timeout's rollback waits for carrier sessions, waking on the
/// role's messages; false when the role stops (the guard still covers it).
pub(super) fn timeout_rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    rx: &Receiver<Msg>,
) -> bool {
    rollback_waits(carrier, |d| wait(rx, d))
}

/// The guard's rollback (`cmux host update guard`, a oneshot unit with no
/// start timeout) waits for carrier sessions by sleeping; `sleep` is
/// injected for the tests.
pub(super) fn guard_rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    mut sleep: impl FnMut(Duration),
) {
    rollback_waits(carrier, |d| {
        sleep(d);
        true
    });
}

/// The new `cmux host run` proves the pending update or rolls it back.
/// False when the role stopped meanwhile (the guard still covers it).
fn resolve(paths: &Paths, pending: &Pending, rx: &Receiver<Msg>) -> bool {
    if store::current_generation(paths).ok() != Some(pending.to) {
        log("the pending update's profile is not current (rolled back?); clearing it");
        clear_pending(paths);
        return true;
    }
    let deadline = Instant::now() + HEALTH_TIMEOUT;
    loop {
        if healthy(paths, pending) {
            commit(paths, pending);
            return true;
        }
        if Instant::now() >= deadline {
            if !timeout_rollback_waits(&mut || rollback_carrier_busy(paths), rx) {
                return false;
            }
            rollback(
                paths,
                pending,
                "the new build did not serve within ten minutes of its restart",
                true,
            );
            return true;
        }
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => return false,
            _ => {}
        }
    }
}

fn commit(paths: &Paths, pending: &Pending) {
    let _lock = Lock::take(paths, true);
    if load_pending(paths).as_ref() != Some(pending) {
        return;
    }
    let mut state = load_state(paths);
    state.applied_commit = Some(pending.commit.clone());
    state.applied_committed_at = pending.committed_at;
    let took = now().saturating_sub(pending.started_at);
    state.last = Some(format!("updated to {} (serving {took} s after the flip)", pending.commit));
    state.last_at = now();
    clear_pending(paths);
    disarm_guard();
    let (profiles, packages) = store::gc(paths, &[pending.from], &state.installed);
    state.installed.retain(|sha| !packages.contains(sha));
    let _ = save_state(paths, &state);
    log(&format!(
        "updated to {} (profile {}, serving {took} s after the flip); removed profiles {profiles:?}",
        pending.commit, pending.to
    ));
}

/// Flips back to the previous profile and restarts what runs the new build.
fn rollback(paths: &Paths, pending: &Pending, why: &str, in_host: bool) {
    let _lock = Lock::take(paths, true);
    if load_pending(paths).as_ref() != Some(pending) {
        return;
    }
    // A stopped worker leaves the rollback to the guard.
    let _commit = COMMIT.lock().unwrap_or_else(|e| e.into_inner());
    if stopped() {
        return;
    }
    log(&format!("rolling {} back to profile {}: {why}", pending.commit, pending.from));
    // The flip back and its restarts go through the gate, so no bind goes out
    // between them; the hold does not stop a rollback.
    let _ = Gate::new(paths).run(wall_ms(), Honor::Nothing, |inside| {
        if let Err(e) = store::flip(paths, pending.from) {
            log(&format!("flipping back to profile {}: {e}", pending.from));
            return;
        }
        let mut state = load_state(paths);
        record_rollback(&mut state, pending);
        state.last = Some(format!("rolled back {}: {why}", pending.commit));
        state.last_at = now();
        let _ = save_state(paths, &state);
        clear_pending(paths);
        if in_host {
            disarm_guard();
        }
        inside.restart_queued(wall_ms());
        restart_after_flip(&store_binary(&pending.cmux_tui));
    });
}

fn systemctl(args: &[&str]) -> bool {
    Command::new("timeout")
        .arg("60")
        .arg("systemctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// `systemctl --user …` in the work user's manager, at most 60 s.
fn user_systemctl(args: &[&str]) -> bool {
    let Some(user) = crate::linux::spawn::lookup_user(WORK_USER) else { return false };
    Command::new("timeout")
        .args(["60", "runuser", "-u", WORK_USER, "--", "env"])
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{}", user.uid))
        .args(["systemctl", "--user"])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// The previous build's `cmux host update guard --to <to>`, as a transient
/// timer [`GUARD_AFTER_SECS`] from now.
fn arm_guard(pending: &Pending) -> Result<(), String> {
    arm_guard_with(pending, &store::profile_dir(&Paths::new("/"), pending.from).join("bin/cmux"))
}

/// [`arm_guard`] with `program` as the guard's `cmux`: an adopt's previous build has
/// no `host update guard`, so its guard is the new build's own ([`adopt`]).
fn arm_guard_with(pending: &Pending, program: &Path) -> Result<(), String> {
    disarm_guard();
    let _ = systemctl(&["stop", &format!("{GUARD_UNIT}.service")]);
    let _ = systemctl(&[
        "reset-failed",
        &format!("{GUARD_UNIT}.service"),
        &format!("{GUARD_UNIT}.timer"),
    ]);
    let status = Command::new("systemd-run")
        .arg(format!("--unit={GUARD_UNIT}"))
        .arg(format!("--on-active={GUARD_AFTER_SECS}"))
        // --collect: the units go once they ran or stopped, failed or not, so
        // the next update can create them again.
        .args(["--collect", "--timer-property=AccuracySec=10s", "--property=Type=oneshot"])
        .arg("--quiet")
        .arg(program)
        .args(["host", "update", "guard", "--to", &pending.to.to_string()])
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("systemd-run: {e}"))?;
    if status.success() { Ok(()) } else { Err(format!("systemd-run exited {status}")) }
}

/// Stops the guard's timer (its service, a oneshot, has not started; the
/// guard itself never calls this).
fn disarm_guard() {
    let _ = systemctl(&["stop", &format!("{GUARD_UNIT}.timer")]);
    let _ = systemctl(&["reset-failed", &format!("{GUARD_UNIT}.timer")]);
}

/// Restarts what runs `old` (the binary just replaced): the work user's
/// acpmux, the other `cmux-*` system services, and last `cmux-host.service`.
fn restart_after_flip(old: &Path) {
    if !user_systemctl(&["restart", "--no-block", ACPMUX_UNIT]) {
        log("restarting the work user's acpmux.service failed (none on this image?)");
    }
    for unit in services_running(old) {
        // Only the image's own cmux units: a provider agent or an operator's
        // shell that happens to run the binary (`cmux host update check`) stays.
        if unit.starts_with("cmux-") && unit != HOST_UNIT && !unit.starts_with(GUARD_UNIT) {
            let _ = systemctl(&["restart", "--no-block", &unit]);
        }
    }
    let _ = systemctl(&["restart", "--no-block", HOST_UNIT]);
}

/// The system services (`/system.slice/<unit>.service`) with a process
/// whose executable is `binary`. Terminal hosts (their own scopes) and the
/// user's units are not services here.
fn services_running(binary: &Path) -> Vec<String> {
    let mut units = Vec::new();
    for entry in fs::read_dir("/proc").into_iter().flatten().flatten() {
        let dir = entry.path();
        if !entry.file_name().to_str().is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit())) {
            continue;
        }
        if fs::read_link(dir.join("exe")).ok().as_deref() != Some(binary) {
            continue;
        }
        let Ok(cgroup) = fs::read_to_string(dir.join("cgroup")) else { continue };
        for line in cgroup.lines() {
            if let Some(unit) = line.strip_prefix("0::/system.slice/")
                && unit.ends_with(".service")
                && !unit.contains('/')
                && !units.iter().any(|u| u == unit)
            {
                units.push(unit.to_owned());
            }
        }
    }
    units
}

/// `cmux host update status [--json] | check [--skip-resume-hold] | guard --to N`.
/// `--skip-resume-hold` is for the Scaler's refresh of a spare it just
/// warmed: the resume it made holds no person's link, and every other hold
/// still holds the flip ([`Honor::AllButResume`]).
pub fn verb(args: &[String]) -> u8 {
    let paths = Paths::new("/");
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["status"] | ["status", "--json"] => {
            let state = load_state(&paths);
            let value = json!({
                "channel": CHANNEL_URL,
                "off": off_reason(&paths),
                "current": store::current_generation(&paths).ok(),
                "generations": store::generations(&paths),
                "cmux_tui": store::current_generation(&paths).ok()
                    .and_then(|g| store::linked_package(&paths, g, CMUX_TUI).ok()),
                "pending": load_pending(&paths),
                "state": state,
            });
            println!("{value}");
            0
        }
        ["adopt"] => {
            let outcome = adopt(&paths);
            log(&outcome.line());
            println!("{}", outcome.json(None));
            if matches!(outcome, Outcome::Failed(_)) { 1 } else { 0 }
        }
        ["check"] | ["check", "--skip-resume-hold"] => {
            let honor = if args.len() > 1 { Honor::AllButResume } else { Honor::All };
            let (outcome, skipped) = check(&paths, honor);
            println!("{}", outcome.json(skipped));
            if matches!(outcome, Outcome::Failed(_)) { 1 } else { 0 }
        }
        // The guard reads no pause record: its rollback flips past the connect
        // hold on purpose (`rollback` runs the gate with `Honor::Nothing`,
        // #37280: keeping a build that never proved itself is worse than a
        // restart) and waits only for attached carrier sessions, so a pause's
        // hold could not change what it does.
        ["guard", "--to", to] => {
            let Ok(to) = to.parse::<u64>() else { return 2 };
            let Some(pending) = load_pending(&paths).filter(|p| p.to == to) else { return 0 };
            if store::current_generation(&paths).ok() != Some(to) {
                clear_pending(&paths);
                return 0;
            }
            guard_rollback_waits(&mut || rollback_carrier_busy(&paths), std::thread::sleep);
            rollback(
                &paths,
                &pending,
                "the new build did not prove itself within twenty minutes of the flip",
                false,
            );
            0
        }
        _ => {
            eprintln!(
                "usage: cmux host update status [--json] | check [--skip-resume-hold] | adopt | guard --to GENERATION"
            );
            2
        }
    }
}
