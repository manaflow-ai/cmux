//! The event loop: turns platform wakes into [`Input`]s, runs the
//! [`Machine`], and executes its [`Action`]s through the [`Platform`]
//! trait (Linux: `crate::linux::LinuxPlatform`; tests: a fake).
//!
//! One thread, one blocking wait. Every wake is a kernel event (clock set,
//! address change, file write, signal, process exit, one-shot timer); there
//! is no tick.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

use cmux_server_core::layout::Layout;
use cmux_server_core::platform::InstallMode;
use cmux_server_core::role::Role;

use crate::machine::{Action, DaemonState, Input, Machine, Observation};
use crate::roles::{Roles, event_name};
use crate::status::Status;

/// One kernel event the platform woke for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wake {
    /// The realtime clock was set (`TFD_TIMER_CANCEL_ON_SET`).
    ClockSet,
    /// The set of global addresses changed (rtnetlink, filtered).
    Address,
    /// The driver wrote `/run/cmux/instance-id`.
    DriverFile,
    /// The bake wrote `/etc/cmux/bake-instance-id`.
    BakeFile,
    /// `server.json` was written.
    ConfigFile,
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
    /// Publishes the status file.
    fn write_status(&mut self, status: &Status) -> io::Result<()>;
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
        if self
            .dispatch([Input::Boot { adopted_daemon: adopted.is_some() }, Input::Observed(first)])
        {
            return Ok(());
        }
        loop {
            let wakes = self.platform.wait()?;
            self.wakes += 1;
            let inputs = self.translate(&wakes);
            if self.dispatch(inputs) {
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
        let mut resumed = false;
        let mut terminate = false;
        for wake in wakes {
            match wake {
                Wake::ClockSet => {
                    resumed = true;
                    observe = true;
                }
                // A change of the global address set: roles rebind and the
                // metadata is read again with a fresh retry budget. Not a
                // resume: no Resumed event, no announce.
                Wake::Address => {
                    first.push(Input::AddressesChanged);
                    observe = true;
                }
                Wake::ConfigFile => rest.push(Input::ConfigChanged),
                Wake::DriverFile | Wake::BakeFile => observe = true,
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
            first.push(Input::Observed(self.platform.observe()));
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
        Wake::ClockSet => "clock",
        Wake::Address => "net",
        Wake::DriverFile => "driver-file",
        Wake::BakeFile => "bake-file",
        Wake::ConfigFile => "config-file",
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
#[path = "agent_tests.rs"]
mod tests;
