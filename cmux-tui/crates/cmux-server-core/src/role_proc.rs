//! One process role's lifecycle, as a pure reducer (server.md 5.1).
//!
//! The host crate feeds it facts (spawned, ready, exited, a timer fired, a
//! stop request) and performs the [`Action`]s it returns: spawn, signal,
//! arm a wake at an instant. Time is an input, so tests drive it without
//! sleeping. The reducer owns restart policy, backoff, the crash-loop rule
//! and the status that `cmux host status` and the server panel show.

use std::time::{Duration, Instant};

use serde::Serialize;

use crate::role_spec::{Readiness, RestartPolicy};

/// First backoff, doubled per failure in the window, capped.
pub const BACKOFF_FIRST: Duration = Duration::from_secs(1);
pub const BACKOFF_CAP: Duration = Duration::from_secs(300);
/// Failures counted for backoff and the crash loop.
pub const FAILURE_WINDOW: Duration = Duration::from_secs(600);
/// This many failures inside the window is a crash loop.
pub const CRASH_LOOP_FAILURES: usize = 5;

/// What the role is doing, as `cmux host status --json` spells it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RoleState {
    Stopped,
    Starting,
    Ready,
    Stopping,
    Backoff,
    CrashLoop,
    Exited,
    Invalid,
}

/// A fact the host reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Input {
    /// Start (or start again after a stop or a config change).
    Start,
    Spawned { pid: u32 },
    SpawnFailed { error: String },
    /// The role wrote `READY=1`.
    Ready,
    /// The role wrote `STATUS=<text>`.
    StatusText(String),
    /// The process ended. `code` is `None` when a signal ended it.
    Exited { pid: u32, code: Option<i32> },
    /// A wake armed by [`Action::WakeAt`] fired.
    Due,
    /// Stop the role (shutdown, park, config removal).
    Stop,
}

/// What the host must do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Spawn,
    /// SIGTERM to the role's process group.
    Terminate { pid: u32 },
    /// SIGKILL to the role's process group.
    Kill { pid: u32 },
    /// Call back with [`Input::Due`] at this instant (the latest wins).
    WakeAt(Instant),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Stopped,
    Starting { pid: Option<u32> },
    Ready { pid: u32 },
    Stopping { pid: u32, killed: bool },
    Backoff { until: Instant },
    CrashLoop,
    Exited,
}

/// The status of one role (also for refused config entries).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RoleHealth {
    pub name: String,
    pub state: RoleState,
    pub pid: Option<u32>,
    pub restarts: u32,
    /// `"code N"` or `"signal"`.
    pub last_exit: Option<String>,
    pub last_error: Option<String>,
    pub status_text: Option<String>,
}

impl RoleHealth {
    /// A config entry that was refused (server.md 5.1).
    pub fn invalid(name: &str, reason: &str) -> RoleHealth {
        RoleHealth {
            name: name.to_owned(),
            state: RoleState::Invalid,
            pid: None,
            restarts: 0,
            last_exit: None,
            last_error: Some(reason.to_owned()),
            status_text: None,
        }
    }
}

/// One role's reducer.
#[derive(Clone, Debug)]
pub struct RoleProc {
    name: String,
    restart: RestartPolicy,
    ready: Readiness,
    grace: Duration,
    phase: Phase,
    /// Start instants of failed runs inside the window.
    failures: Vec<Instant>,
    restarts: u32,
    last_exit: Option<String>,
    last_error: Option<String>,
    status_text: Option<String>,
    /// A stop was requested while a spawn was in flight.
    stop_pending: bool,
    /// A start was requested while the old process was stopping.
    start_after_stop: bool,
}

impl RoleProc {
    pub fn new(name: &str, restart: RestartPolicy, ready: Readiness, grace: Duration) -> Self {
        RoleProc {
            name: name.to_owned(),
            restart,
            ready,
            grace,
            phase: Phase::Stopped,
            failures: Vec::new(),
            restarts: 0,
            last_exit: None,
            last_error: None,
            status_text: None,
            stop_pending: false,
            start_after_stop: false,
        }
    }

    pub fn pid(&self) -> Option<u32> {
        match self.phase {
            Phase::Starting { pid } => pid,
            Phase::Ready { pid } | Phase::Stopping { pid, .. } => Some(pid),
            _ => None,
        }
    }

    /// True when no process runs and none is wanted until the next `Start`.
    pub fn is_down(&self) -> bool {
        matches!(self.phase, Phase::Stopped | Phase::CrashLoop | Phase::Exited)
    }

    pub fn health(&self) -> RoleHealth {
        let state = match self.phase {
            Phase::Stopped => RoleState::Stopped,
            Phase::Starting { .. } => RoleState::Starting,
            Phase::Ready { .. } => RoleState::Ready,
            Phase::Stopping { .. } => RoleState::Stopping,
            Phase::Backoff { .. } => RoleState::Backoff,
            Phase::CrashLoop => RoleState::CrashLoop,
            Phase::Exited => RoleState::Exited,
        };
        RoleHealth {
            name: self.name.clone(),
            state,
            pid: self.pid(),
            restarts: self.restarts,
            last_exit: self.last_exit.clone(),
            last_error: self.last_error.clone(),
            status_text: self.status_text.clone(),
        }
    }

    /// Applies one fact at `now` and returns what to do.
    pub fn step(&mut self, input: Input, now: Instant) -> Vec<Action> {
        match input {
            Input::Start => self.start(),
            Input::Spawned { pid } => self.spawned(pid, now),
            Input::SpawnFailed { error } => {
                self.last_error = Some(error);
                if std::mem::take(&mut self.stop_pending) {
                    self.phase = Phase::Stopped;
                    return Vec::new();
                }
                self.failed_run(now)
            }
            Input::Ready => {
                if let Phase::Starting { pid: Some(pid) } = self.phase {
                    self.phase = Phase::Ready { pid };
                }
                Vec::new()
            }
            Input::StatusText(text) => {
                self.status_text = Some(text);
                Vec::new()
            }
            Input::Exited { pid, code } => self.exited(pid, code, now),
            Input::Due => self.due(now),
            Input::Stop => self.stop(now),
        }
    }

    fn start(&mut self) -> Vec<Action> {
        match self.phase {
            Phase::Stopped | Phase::CrashLoop | Phase::Exited => {
                if self.phase == Phase::CrashLoop {
                    self.failures.clear();
                }
                self.stop_pending = false;
                self.phase = Phase::Starting { pid: None };
                vec![Action::Spawn]
            }
            Phase::Stopping { .. } => {
                // Start again once the old process is gone.
                self.start_after_stop = true;
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn spawned(&mut self, pid: u32, now: Instant) -> Vec<Action> {
        if self.stop_pending {
            self.stop_pending = false;
            self.phase = Phase::Stopping { pid, killed: false };
            return vec![Action::Terminate { pid }, Action::WakeAt(now + self.grace)];
        }
        self.phase = match self.ready {
            Readiness::Started => Phase::Ready { pid },
            Readiness::Notify => Phase::Starting { pid: Some(pid) },
        };
        Vec::new()
    }

    fn exited(&mut self, pid: u32, code: Option<i32>, now: Instant) -> Vec<Action> {
        if self.pid() != Some(pid) {
            return Vec::new();
        }
        self.last_exit = Some(code.map_or_else(|| "signal".to_owned(), |c| format!("code {c}")));
        if matches!(self.phase, Phase::Stopping { .. }) {
            if std::mem::take(&mut self.start_after_stop) {
                self.phase = Phase::Starting { pid: None };
                return vec![Action::Spawn];
            }
            self.phase = Phase::Stopped;
            return Vec::new();
        }
        let clean = code == Some(0);
        match (self.restart, clean) {
            (RestartPolicy::Never, _) | (RestartPolicy::OnFailure, true) => {
                self.phase = Phase::Exited;
                Vec::new()
            }
            (RestartPolicy::Always, true) => {
                // A clean exit is not a crash: restart after the first step.
                self.restarts += 1;
                let until = now + BACKOFF_FIRST;
                self.phase = Phase::Backoff { until };
                vec![Action::WakeAt(until)]
            }
            (_, false) => self.failed_run(now),
        }
    }

    /// A run that failed (non-zero exit, signal, or no spawn).
    fn failed_run(&mut self, now: Instant) -> Vec<Action> {
        self.failures.retain(|at| now.saturating_duration_since(*at) < FAILURE_WINDOW);
        self.failures.push(now);
        if self.restart == RestartPolicy::Never {
            self.phase = Phase::Exited;
            return Vec::new();
        }
        if self.failures.len() >= CRASH_LOOP_FAILURES {
            self.phase = Phase::CrashLoop;
            self.last_error = Some(format!(
                "crash loop: {} failures in {} minutes",
                self.failures.len(),
                FAILURE_WINDOW.as_secs() / 60
            ));
            return Vec::new();
        }
        self.restarts += 1;
        let doublings = u32::try_from(self.failures.len() - 1).unwrap_or(u32::MAX).min(16);
        let delay = BACKOFF_FIRST.saturating_mul(1 << doublings).min(BACKOFF_CAP);
        let until = now + delay;
        self.phase = Phase::Backoff { until };
        vec![Action::WakeAt(until)]
    }

    fn due(&mut self, now: Instant) -> Vec<Action> {
        match self.phase {
            Phase::Backoff { until } if now >= until => {
                self.phase = Phase::Starting { pid: None };
                vec![Action::Spawn]
            }
            Phase::Backoff { until } => vec![Action::WakeAt(until)],
            Phase::Stopping { pid, killed: false } => {
                self.phase = Phase::Stopping { pid, killed: true };
                vec![Action::Kill { pid }]
            }
            _ => Vec::new(),
        }
    }

    fn stop(&mut self, now: Instant) -> Vec<Action> {
        self.start_after_stop = false;
        match self.phase {
            Phase::Starting { pid: None } => {
                self.stop_pending = true;
                Vec::new()
            }
            Phase::Starting { pid: Some(pid) } | Phase::Ready { pid } => {
                self.phase = Phase::Stopping { pid, killed: false };
                vec![Action::Terminate { pid }, Action::WakeAt(now + self.grace)]
            }
            Phase::Backoff { .. } => {
                self.phase = Phase::Stopped;
                Vec::new()
            }
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
#[path = "role_proc_tests.rs"]
mod tests;
