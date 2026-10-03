//! The bind agent's decision logic as a pure state machine
//! (vm-image.md 6.2-6.4).
//!
//! Inputs are wake events and observations (one metadata read plus the
//! bound and bake files); outputs are [`Action`]s in the order the agent
//! must run them. Nothing here reads a clock, a file or the network, so
//! every rule has a unit or property test (`tests/machine_props.rs`).
//!
//! Rules:
//! - A new instance id (not the bake id, not the bound id) binds exactly
//!   once: reseed the CRNG, mark the clone started, drop inherited remote
//!   identity, write the bound id, spawn the session host, then the
//!   off-critical-path work (announce, re-key, prompt sync, timer re-arm).
//! - A bound session host from another machine (a fork of a running
//!   machine) is stopped before its identity is dropped; the bind resumes
//!   when it has exited.
//! - The bake id parks: session host stopped, then terminal hosts stopped
//!   (the warm template terminal is kept by the agent), housekeeping timers
//!   stopped, and no spawn until a new id or an unpark.
//! - No instance id (no metadata service, or every attempt failed) never
//!   binds. An unparked machine keeps its session host running with the
//!   identity it has; a parked one stays parked.
//! - Session host exits restart it with a capped backoff
//!   ([`crate::retry::backoff_delay_ms`]); a host that lived at least
//!   [`HEALTHY_RUN_MS`] resets the backoff.

use crate::retry::backoff_delay_ms;

/// A session host that ran this long before exiting was healthy: its exit
/// restarts at once and resets the crash counter.
pub const HEALTHY_RUN_MS: u64 = 10_000;

/// A role notification. The agent adds deadlines and turns it into a
/// `cmux_server_core::role::HostEvent`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Lifecycle {
    Bound(String),
    Resumed,
    AddressesChanged,
    ChannelChanged,
    ConfigChanged,
}

/// What one wake learned about the machine.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Observation {
    /// The metadata service's instance id; `None` when it is absent or
    /// every attempt failed. Never an empty string.
    pub instance_id: Option<String>,
    /// `/etc/cmux/bake-instance-id`, trimmed; `None` when absent or empty.
    pub bake_id: Option<String>,
    /// `/etc/cmux/daemon-instance-id`, trimmed; `None` when absent or empty.
    pub bound_id: Option<String>,
}

/// One input to the machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Input {
    /// The agent started. `adopted_daemon`: a session host from a previous
    /// agent run is running and now supervised.
    Boot { adopted_daemon: bool },
    /// A wake read the metadata service and the files.
    Observed(Observation),
    /// The realtime clock was set or an address changed: a resume.
    ResumeSignal,
    /// The supervised session host exited after `lived_ms`.
    DaemonExited { lived_ms: u64 },
    /// The session host ignored SIGTERM for the stop grace period.
    StopDeadline,
    /// The restart backoff elapsed.
    BackoffElapsed,
    /// The housekeeping re-arm delay elapsed after a bind.
    RearmElapsed,
    /// Every announce helper exited.
    AnnounceDone,
    /// rtnetlink reported an interface or address change.
    AddressesChanged,
    /// The control plane moved the machine to another channel.
    ChannelChanged,
    /// `server.json` changed.
    ConfigChanged,
    /// Every role handled `Parked` and stopped (`ok`), or one refused.
    RolesParked { ok: bool },
    /// SIGTERM or SIGINT.
    Shutdown,
}

/// One effect for the agent to run, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Mix the id into the kernel input pool and force a CRNG reseed.
    Reseed(String),
    /// Touch `/run/cmux/clone-started` (the template shell's bounded wait).
    MarkCloneStarted,
    /// Remove inherited remote identity (`sessions/*/auth`) and connections.
    DropRemoteIdentity,
    /// Write `/etc/cmux/daemon-instance-id`.
    WriteBound(String),
    /// Spawn the session host directly (setsid, work user).
    SpawnDaemon,
    /// SIGTERM the session host and arm the stop deadline.
    TerminateDaemon,
    /// SIGKILL the session host.
    KillDaemon,
    DisarmStopDeadline,
    /// Stop terminal host processes, except the warm template terminal.
    StopTerminalHosts,
    /// Gratuitous ARP from each global IPv4 address.
    Announce,
    /// Off-critical-path identity job: machine-id, random seed, SSH key.
    Rekey(String),
    /// `systemctl --no-block restart cmux-prompt-sync.service`.
    RestartPromptSync,
    /// Arm the one-shot housekeeping re-arm timer.
    ArmRearm,
    DisarmRearm,
    /// Start the housekeeping timers and service watchdogs again.
    RearmHousekeeping,
    /// Stop the housekeeping timers and service watchdogs.
    ParkHousekeeping,
    /// Arm the one-shot restart backoff.
    ArmBackoff(u64),
    DisarmBackoff,
    /// Remove `/run/cmux/instance-id` so a snapshot carries no driver id.
    RemoveDriverFile,
    /// Start every role with this instance id.
    StartRoles(Option<String>),
    /// Deliver `Parked` to every role and stop them, in reverse order, by
    /// a deadline; answers with [`Input::RolesParked`].
    ParkRoles,
    /// Deliver `Shutdown` to every role and stop them, in reverse order.
    ShutdownRoles,
    /// Deliver a lifecycle event to every role, in order.
    Notify(Lifecycle),
    /// Tell the service manager the agent is ready (once).
    Ready,
    /// Leave the event loop. The session host keeps running.
    Exit,
}

impl Action {
    /// Short stable name for the action log.
    pub fn name(&self) -> &'static str {
        match self {
            Action::Reseed(_) => "reseed",
            Action::MarkCloneStarted => "mark-clone-started",
            Action::DropRemoteIdentity => "drop-remote-identity",
            Action::WriteBound(_) => "write-bound",
            Action::SpawnDaemon => "spawn-daemon",
            Action::TerminateDaemon => "terminate-daemon",
            Action::KillDaemon => "kill-daemon",
            Action::DisarmStopDeadline => "disarm-stop-deadline",
            Action::StopTerminalHosts => "stop-terminal-hosts",
            Action::Announce => "announce",
            Action::Rekey(_) => "rekey",
            Action::RestartPromptSync => "restart-prompt-sync",
            Action::ArmRearm => "arm-rearm",
            Action::DisarmRearm => "disarm-rearm",
            Action::RearmHousekeeping => "rearm-housekeeping",
            Action::ParkHousekeeping => "park-housekeeping",
            Action::ArmBackoff(_) => "arm-backoff",
            Action::DisarmBackoff => "disarm-backoff",
            Action::RemoveDriverFile => "remove-driver-file",
            Action::StartRoles(_) => "start-roles",
            Action::ParkRoles => "park-roles",
            Action::ShutdownRoles => "shutdown-roles",
            Action::Notify(_) => "notify",
            Action::Ready => "ready",
            Action::Exit => "exit",
        }
    }
}

/// Why the session host is being stopped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StopReason {
    /// Finish binding this id once the old host has exited.
    Bind(String),
    Park,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DaemonState {
    Down,
    Running,
    Stopping(StopReason),
    /// Waiting for the restart backoff.
    Backoff,
}

/// The agent's decision state.
#[derive(Clone, Debug)]
pub struct Machine {
    daemon: DaemonState,
    parked: bool,
    /// Consecutive short-lived session host exits.
    fast_exits: u32,
    announcing: bool,
    roles_running: bool,
    /// A park waiting for the roles' answer.
    park_pending: Option<String>,
    ready_sent: bool,
    /// The last id this machine bound or found bound (for roles and status).
    current_id: Option<String>,
    /// An observation that arrived while the session host was stopping.
    deferred: Option<Observation>,
    exiting: bool,
}

impl Default for Machine {
    fn default() -> Self {
        Self::new()
    }
}

impl Machine {
    pub fn new() -> Self {
        Self {
            daemon: DaemonState::Down,
            parked: false,
            fast_exits: 0,
            announcing: false,
            roles_running: false,
            park_pending: None,
            ready_sent: false,
            current_id: None,
            deferred: None,
            exiting: false,
        }
    }

    pub fn is_parked(&self) -> bool {
        self.parked
    }

    pub fn daemon(&self) -> &DaemonState {
        &self.daemon
    }

    pub fn fast_exits(&self) -> u32 {
        self.fast_exits
    }

    pub fn current_id(&self) -> Option<&str> {
        self.current_id.as_deref()
    }

    /// Runs one input and returns the actions in execution order.
    pub fn step(&mut self, input: Input) -> Vec<Action> {
        let mut out = Vec::new();
        if self.exiting {
            return out;
        }
        match input {
            Input::Boot { adopted_daemon } => {
                if adopted_daemon {
                    self.daemon = DaemonState::Running;
                }
            }
            Input::Observed(obs) => self.observe(obs, &mut out),
            Input::ResumeSignal => self.resume(&mut out),
            Input::DaemonExited { lived_ms } => self.daemon_exited(lived_ms, &mut out),
            Input::StopDeadline => {
                if matches!(self.daemon, DaemonState::Stopping(_)) {
                    out.push(Action::KillDaemon);
                }
            }
            Input::BackoffElapsed => {
                if self.daemon == DaemonState::Backoff {
                    self.daemon = DaemonState::Down;
                    if !self.parked {
                        self.spawn(&mut out);
                    }
                }
            }
            Input::RearmElapsed => {
                if !self.parked {
                    out.push(Action::RearmHousekeeping);
                }
            }
            Input::AnnounceDone => self.announcing = false,
            Input::AddressesChanged => self.notify(Lifecycle::AddressesChanged, &mut out),
            Input::ChannelChanged => self.notify(Lifecycle::ChannelChanged, &mut out),
            Input::ConfigChanged => self.notify(Lifecycle::ConfigChanged, &mut out),
            Input::RolesParked { ok } => self.roles_parked(ok, &mut out),
            Input::Shutdown => {
                if self.roles_running {
                    self.roles_running = false;
                    out.push(Action::ShutdownRoles);
                }
                self.exiting = true;
                out.push(Action::Exit);
            }
        }
        out
    }

    fn observe(&mut self, obs: Observation, out: &mut Vec<Action>) {
        if matches!(self.daemon, DaemonState::Stopping(_)) {
            // Finish the stop first; the latest observation runs after it.
            self.deferred = Some(obs);
            return;
        }
        self.evaluate(obs, out);
        if !self.ready_sent {
            self.ready_sent = true;
            out.push(Action::Ready);
        }
    }

    fn evaluate(&mut self, obs: Observation, out: &mut Vec<Action>) {
        let id = obs.instance_id.filter(|id| !id.is_empty());
        match id {
            None => {
                if !self.parked {
                    self.ensure_running(out);
                    self.start_roles(out);
                }
            }
            Some(id) if obs.bake_id.as_deref() == Some(id.as_str()) => self.park(id, out),
            Some(id) if obs.bound_id.as_deref() != Some(id.as_str()) => self.bind(id, out),
            Some(id) => {
                self.current_id = Some(id);
                if self.parked {
                    // The bake was abandoned on this machine: run again.
                    self.parked = false;
                    out.push(Action::ArmRearm);
                }
                self.ensure_running(out);
                self.start_roles(out);
            }
        }
    }

    fn bind(&mut self, id: String, out: &mut Vec<Action>) {
        out.push(Action::Reseed(id.clone()));
        out.push(Action::MarkCloneStarted);
        match self.daemon {
            DaemonState::Running => {
                out.push(Action::TerminateDaemon);
                self.daemon = DaemonState::Stopping(StopReason::Bind(id));
                return;
            }
            DaemonState::Backoff => {
                out.push(Action::DisarmBackoff);
                self.daemon = DaemonState::Down;
            }
            DaemonState::Down | DaemonState::Stopping(_) => {}
        }
        self.finish_bind(id, out);
    }

    fn finish_bind(&mut self, id: String, out: &mut Vec<Action>) {
        out.push(Action::DropRemoteIdentity);
        out.push(Action::WriteBound(id.clone()));
        self.fast_exits = 0;
        self.spawn(out);
        if !self.announcing {
            self.announcing = true;
            out.push(Action::Announce);
        }
        out.push(Action::Rekey(id.clone()));
        out.push(Action::RestartPromptSync);
        if self.parked {
            self.parked = false;
            out.push(Action::ArmRearm);
        }
        self.current_id = Some(id.clone());
        self.start_roles(out);
        out.push(Action::Notify(Lifecycle::Bound(id)));
    }

    fn park(&mut self, id: String, out: &mut Vec<Action>) {
        if !self.parked && self.roles_running {
            // Roles park first; a refusal keeps the machine running.
            if self.park_pending.is_none() {
                self.park_pending = Some(id);
                out.push(Action::ParkRoles);
            }
            return;
        }
        self.park_now(id, out);
    }

    fn roles_parked(&mut self, ok: bool, out: &mut Vec<Action>) {
        let Some(id) = self.park_pending.take() else { return };
        self.roles_running = false;
        if ok {
            self.park_now(id, out);
        } else {
            // Refused: the session host keeps running, so the bake's park
            // step fails rather than snapshot a half-stopped machine.
            self.start_roles(out);
        }
    }

    fn notify(&mut self, event: Lifecycle, out: &mut Vec<Action>) {
        if self.roles_running && !self.parked {
            out.push(Action::Notify(event));
        }
    }

    fn park_now(&mut self, id: String, out: &mut Vec<Action>) {
        let entering = !self.parked;
        if entering {
            self.parked = true;
            out.push(Action::ParkHousekeeping);
            out.push(Action::DisarmRearm);
            out.push(Action::RemoveDriverFile);
        }
        self.current_id = Some(id);
        match self.daemon {
            DaemonState::Running => {
                out.push(Action::TerminateDaemon);
                self.daemon = DaemonState::Stopping(StopReason::Park);
            }
            DaemonState::Backoff => {
                out.push(Action::DisarmBackoff);
                self.daemon = DaemonState::Down;
                out.push(Action::StopTerminalHosts);
            }
            DaemonState::Down => {
                if entering {
                    out.push(Action::StopTerminalHosts);
                }
            }
            DaemonState::Stopping(_) => {}
        }
    }

    fn resume(&mut self, out: &mut Vec<Action>) {
        if self.parked || self.current_id.is_none() {
            return;
        }
        self.notify(Lifecycle::Resumed, out);
        if !self.announcing {
            self.announcing = true;
            out.push(Action::Announce);
        }
    }

    fn daemon_exited(&mut self, lived_ms: u64, out: &mut Vec<Action>) {
        match std::mem::replace(&mut self.daemon, DaemonState::Down) {
            DaemonState::Stopping(reason) => {
                out.push(Action::DisarmStopDeadline);
                let mut deferred = self.deferred.take();
                match reason {
                    StopReason::Bind(id) => {
                        let superseded = deferred.as_ref().is_some_and(|obs| {
                            obs.instance_id.as_deref().is_some_and(|newer| {
                                !newer.is_empty()
                                    && (newer != id || obs.bake_id.as_deref() == Some(newer))
                            })
                        });
                        if !superseded {
                            // An observation taken during the stop read the
                            // bound file before this bind wrote it.
                            if let Some(obs) = deferred.as_mut() {
                                obs.bound_id = Some(id.clone());
                            }
                            self.finish_bind(id, out);
                        }
                        // Superseded: the id changed again during the stop,
                        // or the bake now names it; the deferred observation
                        // decides instead, with no spawn first.
                    }
                    StopReason::Park => out.push(Action::StopTerminalHosts),
                }
                if let Some(obs) = deferred {
                    self.evaluate(obs, out);
                }
                if !self.ready_sent {
                    self.ready_sent = true;
                    out.push(Action::Ready);
                }
            }
            DaemonState::Running => {
                if self.parked {
                    return;
                }
                if lived_ms >= HEALTHY_RUN_MS {
                    self.fast_exits = 0;
                }
                self.fast_exits = self.fast_exits.saturating_add(1);
                match backoff_delay_ms(self.fast_exits) {
                    0 => self.spawn(out),
                    delay => {
                        self.daemon = DaemonState::Backoff;
                        out.push(Action::ArmBackoff(delay));
                    }
                }
            }
            other => self.daemon = other,
        }
    }

    fn ensure_running(&mut self, out: &mut Vec<Action>) {
        if self.daemon == DaemonState::Down {
            self.spawn(out);
        }
    }

    fn spawn(&mut self, out: &mut Vec<Action>) {
        self.daemon = DaemonState::Running;
        out.push(Action::SpawnDaemon);
    }

    fn start_roles(&mut self, out: &mut Vec<Action>) {
        if !self.roles_running {
            self.roles_running = true;
            out.push(Action::StartRoles(self.current_id.clone()));
        }
    }
}

#[cfg(test)]
#[path = "machine_tests.rs"]
mod tests;
