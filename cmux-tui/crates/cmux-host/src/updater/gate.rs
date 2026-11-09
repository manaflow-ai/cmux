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
//! When the files can't be opened (not root, no state dir) the gate runs
//! without them, as it must on a machine without the updater.

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
    _file: Option<fs::File>,
}

impl Gate {
    pub fn new(paths: &Paths) -> Gate {
        Gate { paths: paths.clone() }
    }

    fn lock(&self) -> Locked {
        use std::os::unix::io::AsRawFd as _;
        let path = self.paths.at(GATE_LOCK);
        let file = path
            .parent()
            .and_then(|dir| fs::create_dir_all(dir).ok())
            .and_then(|()| {
                fs::OpenOptions::new().create(true).truncate(false).write(true).open(&path).ok()
            })
            // SAFETY: flock on a descriptor this function owns.
            .filter(|file| unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0);
        Locked { _file: file }
    }

    fn read(&self) -> GateState {
        fs::read(self.paths.at(GATE_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
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
    /// would be cut, so a bind waits for the restarted service.
    pub fn hold(&self, now_ms: u64, hold: Duration) -> bool {
        let _lock = self.lock();
        let mut state = self.read();
        let until = now_ms.saturating_add(ms(hold));
        state.held_until_ms = Some(state.held_until_ms.map_or(until, |held| held.max(until)));
        let _ = self.write(&state);
        state.restart_pending_until_ms.is_none_or(|pending| now_ms >= pending)
    }

    /// How much of the connect hold is left at `now_ms`, if any.
    pub fn held_left(&self, now_ms: u64) -> Option<Duration> {
        let _lock = self.lock();
        left(self.read().held_until_ms, now_ms)
    }

    /// Runs `act` (a flip and its restarts) inside the gate, unless
    /// `honor_hold` and the connect hold is on at `now_ms` (`Err` is the hold
    /// left). `act` gets the call that marks the service's restart pending,
    /// made after its flip and before its restarts. An update's flip honors
    /// the hold; a rollback does not (keeping a build that never proved itself
    /// is worse than a restart, #37280), but it is still serialized with binds.
    pub fn run<R>(
        &self,
        now_ms: u64,
        honor_hold: bool,
        act: impl FnOnce(&dyn Fn()) -> R,
    ) -> Result<R, Duration> {
        let _lock = self.lock();
        if honor_hold && let Some(left) = left(self.read().held_until_ms, now_ms) {
            return Err(left);
        }
        let mark = || {
            let mut state = self.read();
            state.restart_pending_until_ms = Some(now_ms.saturating_add(ms(RESTART_PENDING_FOR)));
            let _ = self.write(&state);
        };
        Ok(act(&mark))
    }

    /// The service started: no restart of it is pending any more.
    pub fn service_started(&self) {
        let _lock = self.lock();
        let mut state = self.read();
        if state.restart_pending_until_ms.take().is_some() {
            let _ = self.write(&state);
        }
    }
}

/// The connect hold a bind (or a new connect) takes at `now_ms`: false when
/// a restart of the service is pending, so the caller does not bind now.
pub fn hold_connects(paths: &Paths, now_ms: u64) -> bool {
    Gate::new(paths).hold(now_ms, CONNECT_HOLD)
}

fn left(until_ms: Option<u64>, now_ms: u64) -> Option<Duration> {
    until_ms
        .and_then(|until| until.checked_sub(now_ms))
        .filter(|left| *left > 0)
        .map(Duration::from_millis)
}
