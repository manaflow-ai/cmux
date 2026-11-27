//! The restart gate: the connect hold and a pending restart of
//! `cmux-host.service`, kept in the state dir so every process that flips or
//! restarts the services sees them. Those are the service's updater, the
//! operator's `cmux host update check` and the guard's
//! `cmux host update guard`, each its own process, and the Cloud role's bind.
//!
//! [`GATE_FILE`] (root, 0600) holds two absolute wall-clock expiries in
//! Unix ms: until when no update flips (the connect hold, after a role
//! start, a bind, a resume, a restore or a new carrier session), and until
//! when a queued restart of the service is pending. Every read and write
//! happens under the flock on [`GATE_LOCK`], and a flip with its restarts
//! runs inside that lock ([`Gate::run`]). So a bind's hold either comes
//! first and the flip sees it, or waits until the restart is queued and
//! sees it pending, then leaves `bind.json` for the restarted service. That
//! service clears the pending mark when it starts, before it accepts binds
//! ([`Gate::service_started_at`]). A mark it never clears (a restart that never
//! came) lapses after [`RESTART_PENDING_FOR`].
//!
//! Each hold has a kind ([`HoldKind`]). A resume hold (the role's start, a
//! resume, a snapshot restore) is the machine's own wake; a connect hold (a
//! bind, a `Bound`, a new carrier session) is a person's link coming up. The
//! file keeps the end of the connect holds apart from the end of every hold,
//! so a later hold of either kind never turns the other into one that may be
//! skipped. Only `cmux host update check --skip-resume-hold` (the Scaler's
//! spare refresh) skips a resume hold ([`Honor::AllButResume`]); a file from
//! before the kinds reads as connect holds only.
//!
//! An update's flip also leaves an own-flip mark in the file
//! ([`Inside::flip_restart_queued`]): when it was queued, and
//! `realtime - boottime` then. The restarted service's updater takes it once
//! at its start ([`Gate::take_own_flip`]) and, when it is that restart, takes
//! no start hold: the machine is the one that just flipped, neither new nor
//! claimed, and a bind or new carrier session still takes its own connect
//! hold. A mark older than [`RESTART_PENDING_FOR`], from the future, or from
//! before a reboot or a snapshot restore (`realtime - boottime` moved) is no
//! such restart, and the start holds as a cold start does.
//!
//! A bind marks itself in flight ([`Gate::begin_bind`]) before its request
//! leaves the gate and clears the mark when it is done ([`Gate::end_bind`]),
//! so a rollback, which honors no hold, still never flips and restarts under
//! a bind's request.
//!
//! The gate fails closed: when its lock, its state or a write fails, no
//! update flips and a bind does not go out (it retries). A rollback still
//! goes (keeping a build that never proved itself is worse, #37280); a bind
//! can't go out then either, so there is none for it to cut. A state that
//! can't be parsed is replaced by a held, restart-pending one with a bind in
//! flight, which lapses on its own, so a bad file never wedges a machine.
//!
//! Every rule above is one pure step in [`machine`] (`gate/machine.rs`, its table in
//! `schemas/updater-gate/table.json`); this file is the shell around it: each method locks,
//! reads, steps, writes when the step says so, and maps the step's verdict to its answer.

use std::cell::Cell;
use std::fmt;
use std::fs;
use std::io;
use std::time::Duration;

use crate::config::Paths;

pub mod machine;

use machine::{Event, GateState, Refusal, Verdict};

/// No flip or restart this long after the role starts (a boot, or a restart
/// that is not the one an update's own flip queued: [`Gate::take_own_flip`]),
/// a bind or a resume: a new or claimed machine's first link comes up then,
/// and a restart kills it before its hello (nightly 8d8fc7a, 2026-11-06: a
/// spare claimed at 21:28:35 restarted at 21:28:41 and its first dial never
/// came back). Past it, a chat that started holds the update as busy, so the
/// update waits for an idle machine.
pub const CONNECT_HOLD: Duration = Duration::from_secs(5 * 60);
/// How long a queued restart of the service may stay pending.
pub const RESTART_PENDING_FOR: Duration = Duration::from_secs(120);
/// How long a bind's in-flight mark lasts: past its request's 20 s deadline,
/// for a bind whose process died before it cleared the mark.
pub const BIND_IN_FLIGHT_FOR: Duration = Duration::from_secs(60);
/// The gate's flock.
pub const GATE_LOCK: &str = "/var/lib/cmux/self-update/gate.lock";
/// The gate's state.
pub const GATE_FILE: &str = "/var/lib/cmux/self-update/gate.json";

/// What started a connect hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldKind {
    /// The machine's own wake: the role's start (a boot, or a restart other
    /// than the own flip's), a resume or a snapshot restore. A person's link may follow,
    /// and it takes its own connect hold (a bind, a new carrier session).
    Resume,
    /// A person's link coming up: a bind, a `Bound` or a new carrier session.
    Connect,
}

impl HoldKind {
    /// Its name in `cmux host update check`'s answer.
    pub fn name(self) -> &'static str {
        match self {
            HoldKind::Resume => "resume",
            HoldKind::Connect => "connect",
        }
    }
}

/// Which holds a flip honors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Honor {
    /// Every hold: an update's flip.
    All,
    /// Every hold but a resume hold: `cmux host update check
    /// --skip-resume-hold`, the Scaler's refresh of a spare it just warmed.
    AllButResume,
    /// None: a rollback (still serialized with binds, and it waits for a
    /// bind in flight). It runs when the gate fails.
    Nothing,
}

/// Why the gate did not run a flip ([`Gate::run`]).
#[derive(Debug)]
pub enum Refused {
    /// A hold the flip honors is on, for this long.
    Held(Duration),
    /// A bind's request is in flight; its mark lasts this long at most.
    BindInFlight(Duration),
    /// The gate's lock or state failed.
    Gate(io::Error),
}

impl Refused {
    /// When to look again.
    pub fn retry_in(&self) -> Duration {
        match self {
            Refused::Held(left) => *left,
            Refused::BindInFlight(left) => (*left).min(Duration::from_secs(5)),
            Refused::Gate(_) => Duration::from_secs(30),
        }
    }
}

impl PartialEq for Refused {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Refused::Held(a), Refused::Held(b))
            | (Refused::BindInFlight(a), Refused::BindInFlight(b)) => a == b,
            (Refused::Gate(a), Refused::Gate(b)) => a.kind() == b.kind(),
            _ => false,
        }
    }
}

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refused::Held(left) => write!(f, "connect hold, {} s left", left.as_secs()),
            Refused::BindInFlight(left) => {
                write!(f, "a bind is in flight (its mark lapses in {} s)", left.as_secs())
            }
            Refused::Gate(e) => write!(f, "the restart gate failed: {e}"),
        }
    }
}

pub struct Gate {
    paths: Paths,
}

/// The gate's flock, held until dropped. The drop unlocks before it closes: a child the
/// service forked meanwhile (a session host, `wg`, systemctl) keeps no lock through its copy.
struct Locked {
    _lock: cmux_file_lock::FileLock,
}

/// What `act` may do inside [`Gate::run`], under the gate's flock (or, for a
/// rollback the failed gate let through, without it).
pub struct Inside<'a> {
    gate: &'a Gate,
    now_ms: u64,
    skipped: Option<HoldKind>,
    /// Whether `act` queued the restart ([`Inside::restart_queued`]): the
    /// pending mark [`Gate::run`] wrote before `act` goes again if not.
    queued: Cell<bool>,
}

impl Inside<'_> {
    /// The state as `act` sees it; one that can't be read is empty here (the
    /// run already read it, and the writes below are best effort).
    fn state(&self) -> GateState {
        self.gate.read(self.now_ms).unwrap_or_default()
    }

    /// `event` on [`Inside::state`], written best effort.
    fn mark(&self, now_ms: u64, event: Event) {
        let step = machine::step(self.state(), now_ms, event);
        if step.write {
            let _ = self.gate.write(&step.state);
        }
    }

    /// Marks the service's restart pending: after the flip, before the restarts.
    /// [`Gate::run`] marked it before `act` already; this keeps it.
    pub fn restart_queued(&self, now_ms: u64) {
        self.queued.set(true);
        self.mark(now_ms, Event::RestartQueued);
    }

    /// [`Inside::restart_queued`] for an update's flip, which also marks the
    /// restart as this updater's own ([`Gate::take_own_flip`]); `offset_ns`
    /// is `realtime - boottime` now. A rollback's restart leaves no mark. A
    /// mark that can't be written makes the restart a cold start.
    pub fn flip_restart_queued(&self, now_ms: u64, offset_ns: i128) {
        self.queued.set(true);
        self.mark(now_ms, Event::FlipRestartQueued { offset_ns });
    }

    /// Starts or extends a connect hold under the flock already held (a new
    /// carrier session the flip's last look found), so the next flip sees it.
    pub fn hold_connects(&self, now_ms: u64) -> io::Result<()> {
        self.hold(HoldKind::Connect, now_ms)
    }

    /// Starts or extends a hold of `kind` under the flock already held: a
    /// connect, or a stop the flip's last look found (the machine's own wake).
    /// `now_ms` is read when the hold starts, not the run's start: the look
    /// before it can take seconds, and a pause during it minutes. An error
    /// when the hold could not be recorded (the caller keeps it itself).
    pub fn hold(&self, kind: HoldKind, now_ms: u64) -> io::Result<()> {
        match self.gate.apply(now_ms, Event::InsideHold { kind })? {
            Verdict::Done => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    /// The hold this run went past ([`Honor::AllButResume`] with a resume
    /// hold on), if any.
    pub fn skipped(&self) -> Option<HoldKind> {
        self.skipped
    }
}

impl Gate {
    pub fn new(paths: &Paths) -> Self {
        Gate { paths: paths.clone() }
    }

    fn lock(&self) -> io::Result<Locked> {
        use cmux_file_lock::{FileLock, Kind};
        let path = self.paths.at(GATE_LOCK);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let file = fs::OpenOptions::new().create(true).truncate(false).write(true).open(&path)?;
        // The same blocking exclusive flock as before.
        let lock = FileLock::take(file, Kind::Exclusive)?;
        Ok(Locked { _lock: lock })
    }

    /// The state under the lock. Missing is empty; unparsable is replaced by
    /// [`Event::UnreadableFile`]'s state (written back), which lapses on its own.
    fn read(&self, now_ms: u64) -> io::Result<GateState> {
        let bytes = match fs::read(self.paths.at(GATE_FILE)) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(GateState::default()),
            Err(e) => return Err(e),
        };
        if let Ok(state) = serde_json::from_slice(&bytes) {
            return Ok(state);
        }
        let step = machine::step(GateState::default(), now_ms, Event::UnreadableFile);
        self.write(&step.state)?;
        Ok(step.state)
    }

    /// Reads, steps and writes when the step says so; the caller holds the lock.
    fn apply(&self, now_ms: u64, event: Event) -> io::Result<Verdict> {
        let step = machine::step(self.read(now_ms)?, now_ms, event);
        if step.write {
            self.write(&step.state)?;
        }
        Ok(step.verdict)
    }

    fn write(&self, state: &GateState) -> io::Result<()> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let path = self.paths.at(GATE_FILE);
        let tmp = path.with_extension("json.tmp");
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&serde_json::to_vec(state).map_err(io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(&tmp, &path)
    }

    /// Starts or extends the connect hold to at least `now_ms + hold`, as a
    /// hold of `kind`. False when a restart of the service is pending at
    /// `now_ms`: a link made now would be cut, so a bind waits for the
    /// restarted service. An error when the hold could not be recorded. It
    /// takes the flock: never inside [`Gate::run`] (see [`hold_connects`]).
    pub fn hold(&self, now_ms: u64, hold: Duration, kind: HoldKind) -> io::Result<bool> {
        let _lock = self.lock()?;
        match self.apply(now_ms, Event::Hold { kind, hold })? {
            Verdict::HoldTaken { restart_pending } => Ok(!restart_pending),
            other => Err(unexpected(other)),
        }
    }

    /// A bind is about to go out: the connect hold and the bind's in-flight
    /// mark ([`BIND_IN_FLIGHT_FOR`]), so neither an update nor a rollback
    /// flips under its request. False (and nothing marked) when a restart
    /// of the service is pending. Pair a true with [`Gate::end_bind`].
    pub fn begin_bind(&self, now_ms: u64) -> io::Result<bool> {
        let _lock = self.lock()?;
        match self.apply(now_ms, Event::BeginBind)? {
            Verdict::BindBegun => Ok(true),
            Verdict::Refused(Refusal::RestartPending) => Ok(false),
            other => Err(unexpected(other)),
        }
    }

    /// The bind is done: its mark goes, and the connect hold runs from now.
    pub fn end_bind(&self, now_ms: u64) -> io::Result<()> {
        let _lock = self.lock()?;
        match self.apply(now_ms, Event::EndBind)? {
            Verdict::Done => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    /// How much of the connect hold is left at `now_ms`, if any.
    pub fn held_left(&self, now_ms: u64) -> io::Result<Option<Duration>> {
        let _lock = self.lock()?;
        match self.apply(now_ms, Event::HeldLeft)? {
            Verdict::HeldLeft(left) => Ok(left),
            other => Err(unexpected(other)),
        }
    }

    /// Runs `act` (a flip and its restarts) inside the gate, unless a hold
    /// `honor` honors is on at `now_ms`, or a bind is in flight. `act` gets
    /// [`Inside`]: its `restart_queued` marks the service's restart pending,
    /// called after its flip and before its restarts. The restart is marked
    /// pending before `act` runs too, so a gate that can't write stops the
    /// flip before it happens; when `act` queues no restart (its flip failed
    /// or it did not flip), the mark goes again. An update's flip honors
    /// every hold; `--skip-resume-hold` every hold but a resume hold; a
    /// rollback none (keeping a build that never proved itself is worse than
    /// a restart, #37280), but it is still serialized with binds and waits
    /// for a bind in flight. A rollback that waits marks the restart pending,
    /// so no new bind starts before it. When the gate fails, an update does
    /// not flip and a rollback runs without it.
    pub fn run<R>(
        &self,
        now_ms: u64,
        honor: Honor,
        act: impl FnOnce(&Inside) -> R,
    ) -> Result<R, Refused> {
        match self.run_locked(now_ms, honor) {
            Ok((_lock, skipped)) => {
                let inside = Inside { gate: self, now_ms, skipped, queued: Cell::new(false) };
                let result = act(&inside);
                if !inside.queued.get() {
                    // Still under the lock: the restart that was marked never comes.
                    let _ = self.clear_pending_locked(now_ms);
                }
                Ok(result)
            }
            Err(Refused::Gate(e)) if honor == Honor::Nothing => {
                eprintln!("cmux-host: updater: the rollback runs without the restart gate: {e}");
                Ok(act(&Inside { gate: self, now_ms, skipped: None, queued: Cell::new(false) }))
            }
            Err(refused) => Err(refused),
        }
    }

    fn run_locked(&self, now_ms: u64, honor: Honor) -> Result<(Locked, Option<HoldKind>), Refused> {
        let lock = self.lock().map_err(Refused::Gate)?;
        let state = self.read(now_ms).map_err(Refused::Gate)?;
        let step = machine::step(state, now_ms, Event::Run { honor });
        match step.verdict {
            Verdict::Run { skipped } => {
                self.write(&step.state).map_err(Refused::Gate)?;
                Ok((lock, skipped))
            }
            Verdict::Refused(Refusal::Held(left)) => Err(Refused::Held(left)),
            Verdict::Refused(Refusal::BindInFlight(left)) => {
                // No new bind starts before the rollback. Its write failing must
                // not turn this into a gate failure, which a rollback runs through.
                if step.write {
                    let _ = self.write(&step.state);
                }
                Err(Refused::BindInFlight(left))
            }
            other => Err(Refused::Gate(unexpected(other))),
        }
    }

    /// Clears the pending mark; the caller holds the lock.
    fn clear_pending_locked(&self, now_ms: u64) -> io::Result<()> {
        match self.apply(now_ms, Event::RunFinished { queued: false })? {
            Verdict::Done => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    /// Takes the own-flip mark ([`Inside::flip_restart_queued`]), so only one
    /// start ever reads it: whether this start, at `now_ms` with
    /// `realtime - boottime` at `offset_ns`, is the restart an update's flip
    /// queued at most [`RESTART_PENDING_FOR`] ago, with no reboot or restore
    /// since. Anything else (no mark, an old one, one from the future, a
    /// moved offset, a gate that fails, a mark this start can't remove) is a
    /// cold start.
    pub fn take_own_flip(&self, now_ms: u64, offset_ns: i128) -> bool {
        let Ok(_lock) = self.lock() else { return false };
        let Ok(state) = self.read(now_ms) else { return false };
        let step = machine::step(state, now_ms, Event::TakeOwnFlip);
        let Verdict::OwnFlip { mark: Some(mark), fresh } = step.verdict else { return false };
        if step.write && self.write(&step.state).is_err() {
            return false;
        }
        fresh
            // The restore test role's `restored_between` makes, read here
            // because the gate builds on every Unix and the role on Linux only.
            && crate::agent::clock_set_wake(i128::from(mark.offset_ns), offset_ns)
                != crate::agent::Wake::ClockSet
    }

    /// The service started at `now_ms`: no restart of it is pending any more.
    /// True when this start is the restart a flip or a rollback queued
    /// ([`Inside::restart_queued`], [`Inside::flip_restart_queued`]) and its
    /// mark had not lapsed. The Cloud role then reports the machine degraded
    /// until the restarted session host answers (`cloud/session.rs`
    /// `Session::after_restart`): its services are restarting, and a spare in
    /// that state must not be handed out. A start the mark cannot be cleared
    /// for is no such restart. An error when the gate failed: binds wait for it.
    pub fn service_started_at(&self, now_ms: u64) -> io::Result<bool> {
        let _lock = self.lock()?;
        match self.apply(now_ms, Event::ServiceStarted)? {
            Verdict::ServiceStarted { restart_was_pending } => Ok(restart_was_pending),
            other => Err(unexpected(other)),
        }
    }
}

/// The connect hold of `kind` a new connect or a wake takes at `now_ms`:
/// false when a restart of the service is pending, so the caller does not
/// bind now; an error when the gate failed to record it. A bind takes
/// [`Gate::begin_bind`] instead.
///
/// It takes the gate's flock itself ([`Gate::hold`]), so it must never be
/// called inside [`Gate::run`]: the flock is not reentrant (a second open
/// file waits on the first), and the run would deadlock on itself. Inside,
/// use [`Inside::hold_connects`] (or [`Inside::hold`]) with the time of the hold.
pub fn hold_connects(paths: &Paths, now_ms: u64, kind: HoldKind) -> io::Result<bool> {
    Gate::new(paths).hold(now_ms, CONNECT_HOLD, kind)
}

/// A verdict [`machine::step`] does not give for the event asked: a bug, failed closed.
fn unexpected(verdict: Verdict) -> io::Error {
    io::Error::other(format!("the restart gate answered {}", verdict.name()))
}

#[cfg(test)]
impl Gate {
    /// [`Gate::service_started_at`] as the tests start a service: at time 0, its answer
    /// and a gate failure ignored.
    pub fn service_started(&self) {
        let _ = self.service_started_at(0);
    }
}

#[cfg(test)]
#[path = "gate_tests.rs"]
pub(super) mod tests;
