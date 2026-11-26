//! `ChiefBrainWatch` as `step(state, event) -> (state, effects)`.
//!
//! The Swift watch keeps one kernel exit source on the host it watches and, while
//! none is watched, two `.write` sources on the home's lock (the lock file and the
//! `state` folder that holds it). Every decision it makes on those events is here;
//! Swift keeps the sources, the lock read (`ChiefHostStop.runningHostPID`), the
//! `kill(pid, 0)` liveness check, the shutdown marker's stat, the restart and
//! `kill(pid, SIGTERM)`, and runs the effects in order.
//!
//! Reads that Swift makes *after* an arming (the re-read in `watch(_:)`, the read in
//! `lockMayHaveAHost`, the read in `lockChanged`) are an effect, `readLock`, whose
//! answer comes back as the `lockRead` event, so the arming always runs first.

use serde::{Deserialize, Serialize};

/// `ChiefBrainWatch.deathLimit`.
pub const DEATH_LIMIT: usize = 3;
/// `ChiefBrainWatch.deathWindow`, in milliseconds.
pub const DEATH_WINDOW_MS: f64 = 60_000.0;

/// What a pending `readLock` effect is for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ReadFor {
    /// `watch(_:)` armed the lock sources and reads again for the launch `pid`.
    #[serde(rename_all = "camelCase")]
    Reread { pid: i32, launcher: bool },
    /// `lockMayHaveAHost`: nothing is watched; a host the lock names is watched.
    MayHaveHost,
    /// `lockChanged` for a watched host whose lock did not name it yet.
    #[serde(rename_all = "camelCase")]
    Pending { pid: i32, launcher: bool },
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WatchState {
    pub stopped: bool,
    pub restarting: bool,
    pub has_given_up: bool,
    /// The pid the exit source is armed on (Swift `source != nil`).
    pub source_pid: Option<i32>,
    /// `watchedPID`: what `watching` was last told.
    pub watched_pid: Option<i32>,
    /// `pendingLockPID`.
    pub pending_lock_pid: Option<i32>,
    /// Whether `pendingLockPID` is the "cmux Files (dev)" launcher.
    pub pending_launcher: bool,
    /// Death times, milliseconds on the caller's monotonic clock.
    pub deaths_ms: Vec<f64>,
    /// The `readLock` effect whose `lockRead` answer is awaited.
    pub read_for: Option<ReadFor>,
}

impl WatchState {
    /// `isWatching`.
    pub fn is_watching(&self) -> bool {
        self.source_pid.is_some() || self.restarting
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum WatchEvent {
    /// `watch(_:)`. `locked`: `runningHostPID` now. `launcher`: whether `pid` runs the
    /// "cmux Files (dev)" launcher (`ChiefHostStop.isFilesHostLauncher`).
    #[serde(rename_all = "camelCase")]
    Watch {
        pid: Option<i32>,
        locked: Option<i32>,
        #[serde(default)]
        launcher: bool,
    },
    /// The answer to a `readLock` effect.
    #[serde(rename_all = "camelCase")]
    LockRead { locked: Option<i32> },
    /// One of the lock sources fired (`folder`: the state folder's).
    #[serde(rename_all = "camelCase")]
    LockChanged { folder: bool },
    /// The exit source fired for `pid`, or the liveness check after `armExitSource` found it gone.
    #[serde(rename_all = "camelCase")]
    Exited { pid: i32, locked: Option<i32>, shutdown_marker: bool, now_ms: f64 },
    /// The `restart` effect finished: the pid to watch next. `nextIsHost`: it runs an
    /// `optchat-chief` or the launcher. `locked`/`launcher`: as for `watch`, for `next`.
    #[serde(rename_all = "camelCase")]
    Restarted {
        next: Option<i32>,
        shutdown_marker: bool,
        #[serde(default)]
        next_is_host: bool,
        locked: Option<i32>,
        #[serde(default)]
        launcher: bool,
    },
    /// `stop()`: quit.
    Stop,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum WatchEffect {
    /// Cancel the exit source.
    CancelExitSource,
    /// Arm the exit source on `pid`, then check `kill(pid, 0)`: ESRCH sends `exited`.
    #[serde(rename_all = "camelCase")]
    ArmExitSource { pid: i32 },
    /// Open the lock file's and the state folder's sources, each only when missing.
    EnsureLockSources,
    /// Cancel both lock sources.
    CancelLockSources,
    /// Read `runningHostPID` and send `lockRead`.
    ReadLock,
    /// Tell `watching` this pid (nil: none).
    #[serde(rename_all = "camelCase")]
    Report { pid: Option<i32> },
    /// Run `restart` and send `restarted` with its pid.
    Restart,
    /// `kill(pid, SIGTERM)`.
    #[serde(rename_all = "camelCase")]
    Terminate { pid: i32 },
    /// A log line (Swift logs it under category `home`).
    #[serde(rename_all = "camelCase")]
    Log { level: LogLevel, message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LogLevel {
    Info,
    Error,
}

fn info(message: String) -> WatchEffect {
    WatchEffect::Log { level: LogLevel::Info, message }
}

/// `lockedHost(startedBy:locked:)`.
fn locked_host(launched: i32, launcher: bool, locked: Option<i32>) -> Option<i32> {
    let locked = locked?;
    (locked == launched || launcher).then_some(locked)
}

struct Machine {
    s: WatchState,
    fx: Vec<WatchEffect>,
}

impl Machine {
    fn set_watched(&mut self, pid: Option<i32>) {
        if self.s.watched_pid == pid {
            return;
        }
        self.s.watched_pid = pid;
        self.fx.push(WatchEffect::Report { pid });
    }

    fn cancel_source(&mut self) {
        if self.s.source_pid.take().is_some() {
            self.fx.push(WatchEffect::CancelExitSource);
        }
    }

    fn cancel_lock_sources(&mut self) {
        self.s.pending_lock_pid = None;
        self.s.pending_launcher = false;
        self.fx.push(WatchEffect::CancelLockSources);
    }

    fn read_lock(&mut self, read_for: ReadFor) {
        self.s.read_for = Some(read_for);
        self.fx.push(WatchEffect::ReadLock);
    }

    fn watch(&mut self, pid: Option<i32>, locked: Option<i32>, launcher: bool) {
        if self.s.stopped {
            return;
        }
        self.cancel_source();
        let Some(pid) = pid.or(locked) else {
            self.fx.push(info("chief brain watch: no host process to watch".into()));
            self.s.pending_lock_pid = None;
            self.s.pending_launcher = false;
            self.set_watched(None);
            self.arm_on_lock();
            return;
        };
        self.s.has_given_up = false;
        if locked == Some(pid) {
            self.s.pending_lock_pid = None;
            self.cancel_lock_sources();
        } else if let Some(host) = locked_host(pid, launcher, locked) {
            self.watch(Some(host), locked, false);
            return;
        } else {
            // Arm before reading again (the host writes its pid a moment after the launch printed it).
            self.fx.push(WatchEffect::EnsureLockSources);
            self.read_lock(ReadFor::Reread { pid, launcher });
            return;
        }
        self.arm_exit(pid);
    }

    fn arm_exit(&mut self, pid: i32) {
        self.set_watched(Some(pid));
        self.s.source_pid = Some(pid);
        self.fx.push(WatchEffect::ArmExitSource { pid });
    }

    fn arm_on_lock(&mut self) {
        if self.s.stopped || self.s.source_pid.is_some() {
            return;
        }
        self.fx.push(WatchEffect::EnsureLockSources);
        self.lock_may_have_a_host();
    }

    fn may_have_guard(&self) -> bool {
        !self.s.stopped && !self.s.restarting && self.s.source_pid.is_none()
    }

    fn lock_may_have_a_host(&mut self) {
        if self.may_have_guard() {
            self.read_lock(ReadFor::MayHaveHost);
        }
    }

    fn lock_read(&mut self, locked: Option<i32>) {
        let Some(read_for) = self.s.read_for.take() else {
            return;
        };
        match read_for {
            ReadFor::Reread { pid, launcher } => {
                if self.s.stopped {
                    return;
                }
                if let Some(host) = locked_host(pid, launcher, locked) {
                    self.cancel_lock_sources();
                    if host != pid {
                        self.watch(Some(host), locked, false);
                        return;
                    }
                } else {
                    self.s.pending_lock_pid = Some(pid);
                    self.s.pending_launcher = launcher;
                }
                self.arm_exit(pid);
            }
            ReadFor::MayHaveHost => {
                if self.may_have_guard()
                    && let Some(pid) = locked
                {
                    self.watch(Some(pid), locked, false);
                }
            }
            ReadFor::Pending { pid, launcher } => {
                if self.s.stopped || self.s.pending_lock_pid != Some(pid) {
                    return;
                }
                let Some(host) = locked_host(pid, launcher, locked) else {
                    return;
                };
                self.cancel_lock_sources();
                if host == pid {
                    // The pid has not changed, so `setWatched` would drop it: tell the reader directly.
                    self.fx.push(WatchEffect::Report { pid: Some(pid) });
                } else {
                    self.watch(Some(host), locked, false);
                }
            }
        }
    }

    fn lock_changed(&mut self, folder: bool) {
        if self.s.stopped {
            return;
        }
        let Some(pending) = self.s.pending_lock_pid else {
            if folder {
                self.arm_on_lock();
            } else {
                self.lock_may_have_a_host();
            }
            return;
        };
        if folder {
            self.fx.push(WatchEffect::EnsureLockSources);
        }
        let launcher = self.s.pending_launcher;
        self.read_lock(ReadFor::Pending { pid: pending, launcher });
    }

    fn exited(&mut self, pid: i32, locked: Option<i32>, shutdown_marker: bool, now_ms: f64) {
        if self.s.stopped || self.s.restarting || Some(pid) != self.s.watched_pid {
            return;
        }
        self.set_watched(None);
        self.cancel_source();
        if let Some(other) = locked
            && other != pid
        {
            self.fx.push(info(format!("chief brain {pid} exited; host {other} holds the lock")));
            self.watch(Some(other), locked, false);
            return;
        }
        if shutdown_marker {
            self.fx.push(info(format!(
                "chief brain {pid} stopped by cmux chief shutdown; not restarting until asked"
            )));
            return;
        }
        self.s.deaths_ms.retain(|d| now_ms - d < DEATH_WINDOW_MS);
        self.s.deaths_ms.push(now_ms);
        if self.s.deaths_ms.len() >= DEATH_LIMIT {
            self.s.has_given_up = true;
            self.fx.push(WatchEffect::Log {
                level: LogLevel::Error,
                message: format!(
                    "chief brain exited {} times within a minute; not restarting until asked again",
                    self.s.deaths_ms.len()
                ),
            });
            return;
        }
        self.fx.push(info(format!("chief brain {pid} exited; starting it again")));
        self.s.restarting = true;
        self.fx.push(WatchEffect::Restart);
    }

    fn restarted(
        &mut self,
        next: Option<i32>,
        shutdown_marker: bool,
        next_is_host: bool,
        locked: Option<i32>,
        launcher: bool,
    ) {
        self.s.restarting = false;
        if (self.s.stopped || shutdown_marker)
            && let Some(next) = next
            && next_is_host
        {
            self.fx.push(WatchEffect::Terminate { pid: next });
            return;
        }
        self.watch(next, locked, launcher);
    }

    fn stop(&mut self) {
        self.s.stopped = true;
        self.cancel_source();
        self.cancel_lock_sources();
        self.s.read_for = None;
        self.set_watched(None);
    }
}

/// One step of the watch.
pub fn step(state: WatchState, event: WatchEvent) -> (WatchState, Vec<WatchEffect>) {
    let mut m = Machine { s: state, fx: Vec::new() };
    match event {
        WatchEvent::Watch { pid, locked, launcher } => m.watch(pid, locked, launcher),
        WatchEvent::LockRead { locked } => m.lock_read(locked),
        WatchEvent::LockChanged { folder } => m.lock_changed(folder),
        WatchEvent::Exited { pid, locked, shutdown_marker, now_ms } => {
            m.exited(pid, locked, shutdown_marker, now_ms);
        }
        WatchEvent::Restarted { next, shutdown_marker, next_is_host, locked, launcher } => {
            m.restarted(next, shutdown_marker, next_is_host, locked, launcher);
        }
        WatchEvent::Stop => m.stop(),
    }
    (m.s, m.fx)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepRequest {
    #[serde(default)]
    pub state: WatchState,
    pub event: WatchEvent,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepReply {
    pub state: WatchState,
    pub effects: Vec<WatchEffect>,
    /// `isWatching` after the step.
    pub is_watching: bool,
}

pub fn step_op(request: StepRequest) -> StepReply {
    let (state, effects) = step(request.state, request.event);
    StepReply { is_watching: state.is_watching(), state, effects }
}
