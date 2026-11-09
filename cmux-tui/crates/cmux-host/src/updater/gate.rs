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
//! Each hold has a kind ([`HoldKind`]). A resume hold (the role's start, a
//! resume, a snapshot restore) is the machine's own wake; a connect hold (a
//! bind, a `Bound`, a new carrier session) is a person's link coming up. The
//! file keeps the end of the connect holds apart from the end of every hold,
//! so a later hold of either kind never turns the other into one that may be
//! skipped. Only `cmux host update check --skip-resume-hold` (the Scaler's
//! spare refresh) skips a resume hold ([`Honor::AllButResume`]); a file from
//! before the kinds reads as connect holds only.
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
    /// The end of every hold, whatever its kind (all a build from before the
    /// kinds reads).
    #[serde(default)]
    held_until_ms: Option<u64>,
    /// The end of the connect holds alone (0: none). Missing in a file from
    /// before the kinds: then every hold in it is a connect hold.
    #[serde(default)]
    connect_until_ms: Option<u64>,
    #[serde(default)]
    restart_pending_until_ms: Option<u64>,
}

impl GateState {
    /// When the holds no flag skips end.
    fn connect_until(&self) -> Option<u64> {
        self.connect_until_ms.or(self.held_until_ms)
    }

    fn hold(&mut self, until: u64, kind: HoldKind) {
        // Read before `held_until_ms` moves: an old file's hold is a connect hold.
        let connect = self.connect_until().unwrap_or(0);
        self.connect_until_ms =
            Some(if kind == HoldKind::Connect { connect.max(until) } else { connect });
        self.held_until_ms = Some(self.held_until_ms.map_or(until, |held| held.max(until)));
    }
}

/// What started a connect hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldKind {
    /// The machine's own wake: the role's start (a boot or an update's
    /// restart), a resume or a snapshot restore. A person's link may follow,
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
    /// None: a rollback (still serialized with binds).
    Nothing,
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

/// What `act` may do inside [`Gate::run`], under the gate's flock.
pub struct Inside<'a> {
    gate: &'a Gate,
    now_ms: u64,
    skipped: Option<HoldKind>,
}

impl Inside<'_> {
    /// Marks the service's restart pending: after the flip, before the restarts.
    pub fn restart_queued(&self) {
        let mut state = self.gate.read();
        state.restart_pending_until_ms = Some(self.now_ms.saturating_add(ms(RESTART_PENDING_FOR)));
        let _ = self.gate.write(&state);
    }

    /// Starts or extends a connect hold under the flock already held (a new
    /// carrier session the flip's last look found), so the next flip sees it.
    pub fn hold_connects(&self) {
        self.hold(HoldKind::Connect);
    }

    /// Starts or extends a hold of `kind` under the flock already held: a
    /// connect, or a stop the flip's last look found (the machine's own wake).
    pub fn hold(&self, kind: HoldKind) {
        let mut state = self.gate.read();
        state.hold(self.now_ms.saturating_add(ms(CONNECT_HOLD)), kind);
        let _ = self.gate.write(&state);
    }

    /// The hold this run went past ([`Honor::AllButResume`] with a resume
    /// hold on), if any.
    pub fn skipped(&self) -> Option<HoldKind> {
        self.skipped
    }
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

    /// Starts or extends the connect hold to at least `now_ms + hold`, as a
    /// hold of `kind`. False when a restart of the service is pending at
    /// `now_ms`: a link made now would be cut, so a bind waits for the
    /// restarted service.
    pub fn hold(&self, now_ms: u64, hold: Duration, kind: HoldKind) -> bool {
        let _lock = self.lock();
        let mut state = self.read();
        state.hold(now_ms.saturating_add(ms(hold)), kind);
        let _ = self.write(&state);
        state.restart_pending_until_ms.is_none_or(|pending| now_ms >= pending)
    }

    /// How much of the connect hold is left at `now_ms`, if any.
    pub fn held_left(&self, now_ms: u64) -> Option<Duration> {
        let _lock = self.lock();
        left(self.read().held_until_ms, now_ms)
    }

    /// Runs `act` (a flip and its restarts) inside the gate, unless a hold
    /// `honor` honors is on at `now_ms` (`Err` is the hold left). `act` gets
    /// [`Inside`]: its `restart_queued` marks the service's restart pending,
    /// called after its flip and before its restarts. An update's flip honors
    /// every hold; `--skip-resume-hold` every hold but a resume hold; a
    /// rollback none (keeping a build that never proved itself is worse than
    /// a restart, #37280), but it is still serialized with binds.
    pub fn run<R>(
        &self,
        now_ms: u64,
        honor: Honor,
        act: impl FnOnce(&Inside) -> R,
    ) -> Result<R, Duration> {
        let _lock = self.lock();
        let state = self.read();
        let mut skipped = None;
        match honor {
            Honor::All => {
                if let Some(left) = left(state.held_until_ms, now_ms) {
                    return Err(left);
                }
            }
            Honor::AllButResume => {
                if let Some(left) = left(state.connect_until(), now_ms) {
                    return Err(left);
                }
                if left(state.held_until_ms, now_ms).is_some() {
                    skipped = Some(HoldKind::Resume);
                }
            }
            Honor::Nothing => {}
        }
        Ok(act(&Inside { gate: self, now_ms, skipped }))
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

/// The connect hold of `kind` a bind, a new connect or a wake takes at
/// `now_ms`: false when a restart of the service is pending, so the caller
/// does not bind now.
pub fn hold_connects(paths: &Paths, now_ms: u64, kind: HoldKind) -> bool {
    Gate::new(paths).hold(now_ms, CONNECT_HOLD, kind)
}

fn left(until_ms: Option<u64>, now_ms: u64) -> Option<Duration> {
    until_ms
        .and_then(|until| until.checked_sub(now_ms))
        .filter(|left| *left > 0)
        .map(Duration::from_millis)
}
