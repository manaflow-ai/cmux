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

use cmux_server_core::role::{HostEvent, Role, RoleContext};

use crate::machine::{Action, DaemonState, Input, Machine, Observation};
use crate::status::Status;

/// One kernel event the platform woke for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wake {
    /// The realtime clock was set (`TFD_TIMER_CANCEL_ON_SET`).
    ClockSet,
    /// rtnetlink link or address event.
    Address,
    /// The driver wrote `/run/cmux/instance-id`.
    DriverFile,
    /// The bake wrote `/etc/cmux/bake-instance-id`.
    BakeFile,
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
    Daemon { lived_ms: u64 },
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
        Action::Reseed(id) | Action::WriteBound(id) | Action::Rekey(id) => format!("{} id={id}", action.name()),
        Action::ArmBackoff(ms) => format!("{} ms={ms}", action.name()),
        Action::Notify(event) => format!("{} event={}", action.name(), event_name(event)),
        Action::StartRoles(id) => format!("{} id={}", action.name(), id.as_deref().unwrap_or("-")),
        other => other.name().to_owned(),
    }
}

fn event_name(event: &HostEvent) -> &'static str {
    match event {
        HostEvent::Bound { .. } => "bound",
        HostEvent::Parked => "parked",
        HostEvent::Resumed => "resumed",
        HostEvent::Shutdown => "shutdown",
    }
}

/// The agent: machine, roles and log over one platform.
pub struct Agent<P: Platform> {
    platform: P,
    machine: Machine,
    roles: Vec<Box<dyn Role>>,
    log: ActionLog,
    last_wake: &'static str,
    wakes: u64,
}

impl<P: Platform> Agent<P> {
    pub fn new(platform: P, roles: Vec<Box<dyn Role>>, log: ActionLog) -> Self {
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
        if self.dispatch([Input::Boot { adopted_daemon: adopted.is_some() }, Input::Observed(first)]) {
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

    fn translate(&mut self, wakes: &[Wake]) -> Vec<Input> {
        let mut inputs = Vec::new();
        let mut observe = false;
        let mut resumed = false;
        let mut terminate = false;
        for wake in wakes {
            match wake {
                Wake::ClockSet | Wake::Address => {
                    resumed = true;
                    observe = true;
                }
                Wake::DriverFile | Wake::BakeFile => observe = true,
                Wake::Terminate => terminate = true,
                Wake::ProcessExit => inputs.extend(self.platform.reap().into_iter().map(|exit| match exit {
                    Exit::Daemon { lived_ms } => Input::DaemonExited { lived_ms },
                    Exit::Announce => Input::AnnounceDone,
                })),
                Wake::Rearm => inputs.push(Input::RearmElapsed),
                Wake::Backoff => inputs.push(Input::BackoffElapsed),
                Wake::StopDeadline => inputs.push(Input::StopDeadline),
            }
        }
        if let Some(first) = wakes.first() {
            self.last_wake = wake_name(*first);
        }
        if resumed {
            inputs.push(Input::ResumeSignal);
        }
        if observe {
            inputs.push(Input::Observed(self.platform.observe()));
        }
        if terminate {
            inputs.push(Input::Shutdown);
        }
        inputs
    }

    /// Runs inputs and their follow-ups; `true` when the loop must exit.
    fn dispatch(&mut self, inputs: impl IntoIterator<Item = Input>) -> bool {
        let mut queue: VecDeque<Input> = inputs.into_iter().collect();
        let mut exit = false;
        while let Some(input) = queue.pop_front() {
            for action in self.machine.step(input) {
                self.log.line(&describe(&action));
                match &action {
                    Action::Exit => exit = true,
                    Action::StartRoles(id) => self.start_roles(id.clone()),
                    Action::StopRoles => self.roles.iter_mut().for_each(|role| role.stop()),
                    Action::Notify(event) => self.notify(event),
                    _ => match self.platform.run(&action) {
                        Ok(Some(follow)) => queue.push_back(follow),
                        Ok(None) => {}
                        Err(err) => {
                            self.log.line(&format!("{} failed: {err}", action.name()));
                            if action == Action::SpawnDaemon {
                                queue.push_back(Input::DaemonExited { lived_ms: 0 });
                            }
                        }
                    },
                }
            }
        }
        if !exit {
            self.publish();
        }
        exit
    }

    fn start_roles(&mut self, instance_id: Option<String>) {
        let ctx = RoleContext { instance_id };
        for role in &mut self.roles {
            if let Err(err) = role.start(&ctx) {
                self.log.line(&format!("role {} start failed: {err}", role.name()));
            }
        }
    }

    fn notify(&mut self, event: &HostEvent) {
        for role in &mut self.roles {
            if let Err(err) = role.on_event(event) {
                self.log.line(&format!("role {} event failed: {err}", role.name()));
            }
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
            roles: self.roles.iter().map(|role| role.name().to_owned()).collect(),
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
