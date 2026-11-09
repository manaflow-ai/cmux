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
//! ([`Gate::service_started`]). A mark it never clears (a restart that never
//! came) lapses after [`RESTART_PENDING_FOR`].
//!
//! A bind marks itself in flight ([`Gate::begin_bind`]) before its request
//! leaves the gate and clears the mark when it is done
//! ([`Gate::end_bind`]), so a rollback, which does not honor the connect
//! hold, still never flips and restarts under a bind's request.
//!
//! The gate fails closed: when its lock, its state or a write fails, no
//! update flips and a bind does not go out (it retries). A rollback still
//! goes (keeping a build that never proved itself is worse, #37280); a bind
//! can't go out then either, so there is none for it to cut. A state that
//! can't be parsed is replaced by a held, restart-pending one with a bind in
//! flight, which lapses on its own, so a bad file never wedges a machine.

use std::fmt;
use std::fs;
use std::io;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::config::Paths;

/// No flip or restart this long after the role starts (a boot or an update's
/// restart), a bind or a resume: a new or claimed machine's first link comes
/// up then, and a restart kills it before its hello (nightly 8d8fc7a,
/// 2026-11-06: a spare claimed at 21:28:35 restarted at 21:28:41 and its
/// first dial never came back). Past it, a chat that started holds the update
/// as busy, so the update waits for an idle machine.
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

#[derive(Debug, Default, Serialize, Deserialize)]
struct GateState {
    #[serde(default)]
    held_until_ms: Option<u64>,
    #[serde(default)]
    restart_pending_until_ms: Option<u64>,
    #[serde(default)]
    bind_in_flight_until_ms: Option<u64>,
}

/// What runs inside the gate ([`Gate::run`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flip {
    /// An update's flip: waits for the connect hold and a bind in flight,
    /// and does not run when the gate fails.
    Update,
    /// A rollback: waits only for a bind in flight, and runs when the gate
    /// fails.
    Rollback,
}

/// Why the gate did not run a flip.
#[derive(Debug)]
pub enum Refused {
    /// The connect hold is on, for this long.
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

fn ms(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

/// The gate under one root (`/` on a machine; a temp dir in tests).
pub struct Gate {
    paths: Paths,
}

/// The gate's flock, held until dropped.
struct Locked {
    _file: fs::File,
}

impl Gate {
    pub fn new(paths: &Paths) -> Gate {
        Gate { paths: paths.clone() }
    }

    fn lock(&self) -> io::Result<Locked> {
        use std::os::unix::io::AsRawFd as _;
        let path = self.paths.at(GATE_LOCK);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let file = fs::OpenOptions::new().create(true).truncate(false).write(true).open(&path)?;
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Locked { _file: file })
    }

    /// The state under the lock. Missing is empty; unparsable is replaced by
    /// a held, restart-pending state with a bind in flight (written back)
    /// that lapses on its own.
    fn read(&self, now_ms: u64) -> io::Result<GateState> {
        let bytes = match fs::read(self.paths.at(GATE_FILE)) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(GateState::default()),
            Err(e) => return Err(e),
        };
        if let Ok(state) = serde_json::from_slice(&bytes) {
            return Ok(state);
        }
        // What the file said is lost: a bind may be in flight, so the
        // barrier holds for a fresh bound, as if one had just started.
        let state = GateState {
            held_until_ms: Some(now_ms.saturating_add(ms(CONNECT_HOLD))),
            restart_pending_until_ms: Some(now_ms.saturating_add(ms(RESTART_PENDING_FOR))),
            bind_in_flight_until_ms: Some(now_ms.saturating_add(ms(BIND_IN_FLIGHT_FOR))),
        };
        self.write(&state)?;
        Ok(state)
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

    /// Starts or extends the connect hold to at least `now_ms + hold`. False
    /// when a restart of the service is pending at `now_ms`: a link made now
    /// would be cut, so a bind waits for the restarted service. An error
    /// when the hold could not be recorded.
    pub fn hold(&self, now_ms: u64, hold: Duration) -> io::Result<bool> {
        let _lock = self.lock()?;
        let mut state = self.read(now_ms)?;
        extend(&mut state, now_ms, hold);
        self.write(&state)?;
        Ok(!pending(&state, now_ms))
    }

    /// A bind is about to go out: the connect hold and the bind's in-flight
    /// mark ([`BIND_IN_FLIGHT_FOR`]), so neither an update nor a rollback
    /// flips under its request. False (and nothing marked) when a restart
    /// of the service is pending. Pair a true with [`Gate::end_bind`].
    pub fn begin_bind(&self, now_ms: u64) -> io::Result<bool> {
        let _lock = self.lock()?;
        let mut state = self.read(now_ms)?;
        if pending(&state, now_ms) {
            return Ok(false);
        }
        extend(&mut state, now_ms, CONNECT_HOLD);
        state.bind_in_flight_until_ms = Some(now_ms.saturating_add(ms(BIND_IN_FLIGHT_FOR)));
        self.write(&state)?;
        Ok(true)
    }

    /// The bind is done: its mark goes, and the connect hold runs from now.
    pub fn end_bind(&self, now_ms: u64) -> io::Result<()> {
        let _lock = self.lock()?;
        let mut state = self.read(now_ms)?;
        state.bind_in_flight_until_ms = None;
        extend(&mut state, now_ms, CONNECT_HOLD);
        self.write(&state)
    }

    /// How much of the connect hold is left at `now_ms`, if any.
    pub fn held_left(&self, now_ms: u64) -> io::Result<Option<Duration>> {
        let _lock = self.lock()?;
        Ok(left(self.read(now_ms)?.held_until_ms, now_ms))
    }

    /// Runs `act` (a flip and its restarts) inside the gate, unless `flip`
    /// waits for what the gate holds. The restart is marked pending before
    /// `act` runs, and the mark goes again when `act` fails. An update's
    /// flip honors the connect hold; a rollback does not (keeping a build
    /// that never proved itself is worse than a restart, #37280), but it
    /// waits for a bind in flight. A rollback that waits marks the restart
    /// pending, so no new bind starts before it. When the gate fails, an
    /// update does not flip and a rollback runs without it.
    pub fn run<R, E>(
        &self,
        now_ms: u64,
        flip: Flip,
        act: impl FnOnce() -> Result<R, E>,
    ) -> Result<Result<R, E>, Refused> {
        match self.run_locked(now_ms, flip) {
            Ok(_lock) => {
                let result = act();
                if result.is_err() {
                    // Still under the lock: the restart that was marked never comes.
                    let _ = self.clear_pending_locked(now_ms);
                }
                Ok(result)
            }
            Err(Refused::Gate(e)) if flip == Flip::Rollback => {
                eprintln!("cmux-host: updater: the rollback runs without the restart gate: {e}");
                Ok(act())
            }
            Err(refused) => Err(refused),
        }
    }

    fn run_locked(&self, now_ms: u64, flip: Flip) -> Result<Locked, Refused> {
        let lock = self.lock().map_err(Refused::Gate)?;
        let mut state = self.read(now_ms).map_err(Refused::Gate)?;
        let in_flight = left(state.bind_in_flight_until_ms, now_ms);
        if flip == Flip::Update
            && let Some(left) = left(state.held_until_ms, now_ms)
        {
            return Err(Refused::Held(left));
        }
        state.restart_pending_until_ms = Some(now_ms.saturating_add(ms(RESTART_PENDING_FOR)));
        if let Some(left) = in_flight {
            // No new bind starts before the rollback. Its write failing must
            // not turn this into a gate failure, which a rollback runs through.
            if flip == Flip::Rollback {
                let _ = self.write(&state);
            }
            return Err(Refused::BindInFlight(left));
        }
        self.write(&state).map_err(Refused::Gate)?;
        Ok(lock)
    }

    /// Clears the pending mark; the caller holds the lock.
    fn clear_pending_locked(&self, now_ms: u64) -> io::Result<()> {
        let mut state = self.read(now_ms)?;
        state.restart_pending_until_ms = None;
        self.write(&state)
    }

    /// The service started: no restart of it is pending any more.
    pub fn service_started(&self, now_ms: u64) -> io::Result<()> {
        let _lock = self.lock()?;
        let mut state = self.read(now_ms)?;
        if state.restart_pending_until_ms.take().is_some() {
            self.write(&state)?;
        }
        Ok(())
    }
}

/// The connect hold a new connect takes at `now_ms`: false when a restart of
/// the service is pending.
pub fn hold_connects(paths: &Paths, now_ms: u64) -> io::Result<bool> {
    Gate::new(paths).hold(now_ms, CONNECT_HOLD)
}

fn extend(state: &mut GateState, now_ms: u64, hold: Duration) {
    let until = now_ms.saturating_add(ms(hold));
    state.held_until_ms = Some(state.held_until_ms.map_or(until, |held| held.max(until)));
}

fn pending(state: &GateState, now_ms: u64) -> bool {
    state.restart_pending_until_ms.is_some_and(|pending| now_ms < pending)
}

fn left(until_ms: Option<u64>, now_ms: u64) -> Option<Duration> {
    until_ms
        .and_then(|until| until.checked_sub(now_ms))
        .filter(|left| *left > 0)
        .map(Duration::from_millis)
}

#[cfg(test)]
impl Gate {
    /// [`Gate::run`] as the tests drive it: an update when `honor_hold`,
    /// else a rollback, with an `act` that can't fail (its argument is a
    /// no-op: the restart is marked pending before `act`).
    pub fn run_test<R>(
        &self,
        now_ms: u64,
        honor_hold: bool,
        act: impl FnOnce(&dyn Fn()) -> R,
    ) -> Result<R, Refused> {
        let flip = if honor_hold { Flip::Update } else { Flip::Rollback };
        self.run(now_ms, flip, || Ok::<R, std::convert::Infallible>(act(&|| {})))
            .map(|r| r.unwrap_or_else(|e| match e {}))
    }
}
