//! `Supervisor::run(spec)`: the loop that keeps one supervised process up by the contract. The
//! adopters that already own a process loop (acpmux under launchd or systemd, `cmux host run`'s
//! epoll agent) use the same pieces through [`Files`] and [`crate::decide`]; this loop is the
//! whole contract for a process nothing else supervises (and for the fault tests).

use cmux_process::{Child, Command};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::budget::{Budget, BudgetState, StopCause};
use crate::death::{self, Death};
use crate::decide::{self, Decision, Progress, Stall};
use crate::identity::{self, Liveness};
use crate::intent::Intent;
use crate::record::{self, OwnerRecord};

/// The files one supervised thing keeps in its state folder.
#[derive(Clone, Debug)]
pub struct Files {
    pub name: String,
    pub owner: PathBuf,
    /// The end the owner wrote for itself ([`crate::ends`]).
    pub end: PathBuf,
    pub budget: Budget,
    pub intent: Intent,
    pub deaths: PathBuf,
    pub health: PathBuf,
}

impl Files {
    /// `<dir>/<name>.owner.json`, `.end.json`, `.stops.json`, `.stop-intent.json`,
    /// `.deaths.jsonl`, `.health.json`.
    pub fn new(dir: &Path, name: &str, budget_per_day: u32) -> Self {
        let at = |suffix: &str| dir.join(format!("{name}.{suffix}"));
        Self {
            name: name.to_owned(),
            owner: at("owner.json"),
            end: at("end.json"),
            budget: Budget::new(at("stops.json"), budget_per_day),
            intent: Intent::new(at("stop-intent.json")),
            deaths: at("deaths.jsonl"),
            health: at("health.json"),
        }
    }
}

/// A probe asks the supervised thing a real request.
pub trait Probe: Send {
    /// Readiness: true once it answers. Progress: [`Progress`] since the last look.
    fn ready(&mut self) -> bool {
        true
    }
    fn progress(&mut self) -> Progress {
        Progress::Moved
    }
}

/// A command line.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cmd {
    pub program: PathBuf,
    pub args: Vec<String>,
}

impl Cmd {
    fn command(&self) -> Command {
        let mut c = Command::new(&self.program);
        c.args(&self.args);
        c
    }
}

/// What a supervised thing declares.
pub struct Spec {
    pub name: String,
    pub state_dir: PathBuf,
    pub start: Cmd,
    /// Its own restart command (`acpmux daemon restart`, `systemctl restart ...`). When set,
    /// a restart of a live process goes through it and only it: the command makes the
    /// successor, which claims its own owner record ([`record::claim_current`]), and the
    /// supervisor starts nothing beside it. Else the process is stopped by its recorded
    /// identity and started again.
    pub restart: Option<Cmd>,
    pub probe: Box<dyn Probe>,
    /// The longest real hold: progress may stall this long during real work.
    pub longest_hold: Duration,
    /// How often the progress probe looks.
    pub look_every: Duration,
    /// How long a start may take to answer readiness.
    pub ready_within: Duration,
    /// Owned state paths, named in the death event.
    pub owned: Vec<PathBuf>,
    pub budget_per_day: u32,
}

/// The health a supervised thing serves.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub name: String,
    /// `starting`, `running`, `stopped` (meant), `restart-budget-exceeded`.
    pub state: String,
    pub owner: Option<OwnerRecord>,
    pub budget: BudgetState,
    pub reason: Option<String>,
}

/// How [`Supervisor::run`] ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ended {
    /// A stop someone meant: no respawn.
    Stopped(String),
    /// Over today's restart budget.
    BudgetExceeded(Vec<StopCause>),
}

/// One supervisor of one spec.
pub struct Supervisor {
    spec: Spec,
    files: Files,
    child: Option<Child>,
    /// The child's exit was seen and it is not reaped yet.
    exited: bool,
    on_death: Option<OnDeath>,
}

/// Called once per death, after it is logged.
type OnDeath = Box<dyn FnMut(&Death) + Send>;

impl Supervisor {
    pub fn new(spec: Spec) -> Self {
        let files = Files::new(&spec.state_dir, &spec.name, spec.budget_per_day);
        Self { spec, files, child: None, exited: false, on_death: None }
    }

    pub fn files(&self) -> &Files {
        &self.files
    }

    /// Called once per death, after it is logged.
    pub fn on_death(mut self, f: impl FnMut(&Death) + Send + 'static) -> Self {
        self.on_death = Some(Box::new(f));
        self
    }

    /// Run `spec` until a meant stop or the budget ends it.
    pub fn run(spec: Spec) -> std::io::Result<Ended> {
        Self::new(spec).serve()
    }

    /// Start it, or, when its recorded owner still runs, return that owner: a start of a
    /// running thing is a no-op that returns its endpoint. An owner whose liveness cannot be
    /// read ([`Liveness::Unknown`]) may still run, so it is kept too; a record that cannot be
    /// read proves nothing, so nothing starts beside it (an error names the file).
    pub fn ensure(&mut self) -> std::io::Result<OwnerRecord> {
        self.ensure_started().map(|(owner, _)| owner)
    }

    /// [`Self::ensure`], with the cause when the start it made did not answer readiness.
    fn ensure_started(&mut self) -> std::io::Result<(OwnerRecord, Option<StopCause>)> {
        match record::load(&self.files.owner) {
            record::Loaded::Record(r) => match r.liveness() {
                Liveness::Alive | Liveness::Unknown => return Ok((r, None)),
                Liveness::Dead => {}
            },
            record::Loaded::Unreadable(why) => {
                return Err(std::io::Error::other(format!(
                    "{}: an owner record that cannot be read ({why}); nothing starts beside it",
                    self.files.owner.display()
                )));
            }
            record::Loaded::Missing => {}
        }
        self.files.intent.clear()?;
        self.start()
    }

    pub fn serve(&mut self) -> std::io::Result<Ended> {
        std::fs::create_dir_all(&self.spec.state_dir)?;
        // `unready`: a start that never answered readiness, a failed start restarted like a
        // stall (one that exited instead is a death the loop sees).
        let (mut owner, mut unready) = self.ensure_started()?;
        let mut stall = Stall::default();
        let clock = Instant::now();
        loop {
            if let Some(cause) = unready.take().filter(|_| !self.wait_exit(Duration::ZERO)) {
                let state = self.files.budget.record(cause)?;
                if state.exceeded() {
                    return Ok(self.hold(&owner));
                }
                (owner, unready) = self.restart(&owner, owner.liveness())?;
                stall = Stall::default();
                continue;
            }
            self.write_health(Some(&owner), "running", None);
            let exited = self.wait_exit(self.spec.look_every);
            let liveness = if exited { Liveness::Dead } else { owner.liveness() };
            if liveness == Liveness::Alive {
                stall.look(self.spec.probe.progress(), clock.elapsed());
            }
            let intent = self.files.intent.meant(owner.epoch);
            let decision = decide::decide(decide::Facts {
                liveness,
                stall: &stall,
                bound: self.spec.longest_hold,
                now: clock.elapsed(),
                intent: intent.as_ref().map(|i| i.reason.as_str()),
                budget_exceeded: self.files.budget.state().exceeded(),
            });
            match decision {
                Decision::Keep => {}
                Decision::StayStopped(why) => {
                    self.reap();
                    self.files.budget.record(StopCause::Intentional(why.clone()))?;
                    self.write_health(Some(&owner), "stopped", Some(why.clone()));
                    return Ok(Ended::Stopped(why));
                }
                Decision::Hold => return Ok(self.hold(&owner)),
                Decision::Restart(cause) => {
                    let state = self.files.budget.record(cause.clone())?;
                    if liveness == Liveness::Dead {
                        self.reap();
                        self.died(&owner, cause);
                    }
                    if state.exceeded() {
                        return Ok(self.hold(&owner));
                    }
                    (owner, unready) = self.restart(&owner, liveness)?;
                    stall = Stall::default();
                }
            }
        }
    }

    fn hold(&mut self, owner: &OwnerRecord) -> Ended {
        let causes = match self.files.budget.state() {
            BudgetState::Exceeded { causes, .. } => causes,
            BudgetState::Within { .. } => Vec::new(),
        };
        self.write_health(Some(owner), "restart-budget-exceeded", None);
        Ended::BudgetExceeded(causes)
    }

    /// Spawn the start command and record its owner; with it, the cause when it did not answer
    /// readiness within `ready_within` (and still runs).
    fn start(&mut self) -> std::io::Result<(OwnerRecord, Option<StopCause>)> {
        let previous = record::load(&self.files.owner);
        let child = self.spec.start.command().spawn()?;
        // The record names the child before anything waits on it.
        let who = identity::of(child.id()).unwrap_or(identity::Identity {
            pid: child.id(),
            start_time: 0,
            pgid: child.id(),
            boot_id: identity::boot_id().unwrap_or_default(),
        });
        let argv = std::iter::once(self.spec.start.program.display().to_string())
            .chain(self.spec.start.args.iter().cloned())
            .collect();
        let owner = OwnerRecord::new(who, previous.record(), argv);
        record::store(&self.files.owner, &owner)?;
        self.watch(child);
        self.write_health(Some(&owner), "starting", None);
        let deadline = Instant::now() + self.spec.ready_within;
        while !self.spec.probe.ready() {
            // An exit is seen by the loop as a death.
            if self.wait_exit(Duration::from_millis(20)) {
                break;
            }
            if Instant::now() >= deadline {
                let why = format!("no readiness within {:?}", self.spec.ready_within);
                return Ok((owner, Some(StopCause::NoProgress(why))));
            }
        }
        Ok((owner, None))
    }

    /// The supervisor owns the child: it ends with the supervisor (`cmux_process::Child`).
    fn watch(&mut self, child: Child) {
        self.child = Some(child);
    }

    /// Whether the child has exited, waiting up to `within` for it (an exit event, not a poll).
    /// Unreaped until [`Self::reap`], so its pid is not reused while the record names it. Sticky
    /// until reaped.
    fn wait_exit(&mut self, within: Duration) -> bool {
        if !self.exited {
            self.exited = match self.child.as_mut() {
                Some(child) => child.exited_within(within).unwrap_or(false),
                None => {
                    std::thread::sleep(within);
                    false
                }
            };
        }
        self.exited
    }

    fn reap(&mut self) {
        self.exited = false;
        if let Some(mut child) = self.child.take() {
            let _ = child.wait();
        }
    }

    fn restart(
        &mut self,
        owner: &OwnerRecord,
        liveness: Liveness,
    ) -> std::io::Result<(OwnerRecord, Option<StopCause>)> {
        if liveness == Liveness::Alive {
            if let Some(cmd) = self.spec.restart.clone() {
                return self.restart_through(&cmd, owner);
            }
            self.stop_owner(owner);
            self.reap();
        }
        self.start()
    }

    /// A restart through the thing's own restart command: it must succeed, and the successor it
    /// made must claim a newer owner record and answer readiness within `ready_within`. The
    /// supervisor starts nothing itself; the old child's handle ends (and is reaped) after.
    fn restart_through(
        &mut self,
        cmd: &Cmd,
        owner: &OwnerRecord,
    ) -> std::io::Result<(OwnerRecord, Option<StopCause>)> {
        let status = cmd.command().status()?;
        if !status.success() {
            return Err(std::io::Error::other(format!(
                "the restart command {} exited {status}",
                cmd.program.display()
            )));
        }
        let deadline = Instant::now() + self.spec.ready_within;
        loop {
            if let record::Loaded::Record(r) = record::load(&self.files.owner)
                && r.epoch > owner.epoch
                && r.liveness() == Liveness::Alive
                && self.spec.probe.ready()
            {
                self.reap_or_end();
                return Ok((r, None));
            }
            if Instant::now() >= deadline {
                return Err(std::io::Error::other(format!(
                    "the restart command {} made no ready successor within {:?}",
                    cmd.program.display(),
                    self.spec.ready_within
                )));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Drop the old child's handle: reaped when it exited, else ended and reaped
    /// (`cmux_process::Child`).
    fn reap_or_end(&mut self) {
        if self.wait_exit(Duration::ZERO) {
            self.reap();
        } else {
            self.child = None;
        }
    }

    /// Stop the recorded owner, only while the record still names it: its process group when it
    /// leads one of its own (its descendants end with it), else its pid.
    fn stop_owner(&mut self, owner: &OwnerRecord) {
        #[cfg(unix)]
        if owner.liveness() == Liveness::Alive {
            // SAFETY: getpgrp has no preconditions.
            let own_group = unsafe { libc::getpgrp() } as u32;
            let target = if owner.pgid == owner.pid && owner.pgid != own_group {
                -(owner.pgid as libc::pid_t)
            } else {
                owner.pid as libc::pid_t
            };
            // SAFETY: plain signals to the pid or group the record proves is the owner's.
            unsafe { libc::kill(target, libc::SIGTERM) };
            if !self.wait_exit(Duration::from_secs(5)) && owner.liveness() == Liveness::Alive {
                unsafe { libc::kill(target, libc::SIGKILL) };
            }
        }
        #[cfg(not(unix))]
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
        }
    }

    fn died(&mut self, owner: &OwnerRecord, cause: StopCause) {
        let death = Death {
            name: self.spec.name.clone(),
            owner: owner.clone(),
            cause,
            owned: self.spec.owned.iter().map(|p| p.display().to_string()).collect(),
            at_ms: crate::budget::now_ms(),
        };
        let _ = death::append(&self.files.deaths, &death);
        if let Some(f) = self.on_death.as_mut() {
            f(&death);
        }
    }

    fn write_health(&self, owner: Option<&OwnerRecord>, state: &str, reason: Option<String>) {
        let health = Health {
            name: self.spec.name.clone(),
            state: state.to_owned(),
            owner: owner.cloned(),
            budget: self.files.budget.state(),
            reason,
        };
        if let Ok(bytes) = serde_json::to_vec(&health) {
            let _ = record::write_atomic(&self.files.health, &bytes);
        }
    }
}

/// The health a supervisor last wrote for `name` in `dir`.
pub fn read_health(dir: &Path, name: &str) -> Option<Health> {
    let files = Files::new(dir, name, 0);
    serde_json::from_slice(&std::fs::read(files.health).ok()?).ok()
}
