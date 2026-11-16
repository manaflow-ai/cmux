//! `Supervisor::run(spec)`: the loop that keeps one supervised process up by the contract. The
//! adopters that already own a process loop (acpmux under launchd or systemd, `cmux host run`'s
//! epoll agent) use the same pieces through [`Files`] and [`crate::decide`]; this loop is the
//! whole contract for a process nothing else supervises (and for the fault tests).

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::mpsc;
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
    pub owner: PathBuf,
    pub budget: Budget,
    pub intent: Intent,
    pub deaths: PathBuf,
    pub health: PathBuf,
}

impl Files {
    /// `<dir>/<name>.owner.json`, `.stops.json`, `.stop-intent.json`, `.deaths.jsonl`,
    /// `.health.json`.
    pub fn new(dir: &Path, name: &str, budget_per_day: u32) -> Self {
        let at = |suffix: &str| dir.join(format!("{name}.{suffix}"));
        Self {
            owner: at("owner.json"),
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
    /// a restart of a live process goes through it and only it; else the process is stopped
    /// by its recorded identity and started again.
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
    exits: Option<mpsc::Receiver<()>>,
    /// The child's exit was seen and it is not reaped yet.
    exited: bool,
    on_death: Option<OnDeath>,
}

/// Called once per death, after it is logged.
type OnDeath = Box<dyn FnMut(&Death) + Send>;

impl Supervisor {
    pub fn new(spec: Spec) -> Self {
        let files = Files::new(&spec.state_dir, &spec.name, spec.budget_per_day);
        Self { spec, files, child: None, exits: None, exited: false, on_death: None }
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

    /// Start it, or, when its recorded owner already runs and answers, return that owner:
    /// a start of a running thing is a no-op that returns its endpoint.
    pub fn ensure(&mut self) -> std::io::Result<OwnerRecord> {
        if let record::Loaded::Record(r) = record::load(&self.files.owner)
            && r.liveness() == Liveness::Alive
            && self.spec.probe.ready()
        {
            return Ok(r);
        }
        self.files.intent.clear()?;
        self.start()
    }

    pub fn serve(&mut self) -> std::io::Result<Ended> {
        std::fs::create_dir_all(&self.spec.state_dir)?;
        let mut owner = self.ensure()?;
        let mut stall = Stall::default();
        let clock = Instant::now();
        loop {
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
                    owner = self.restart(&owner, liveness)?;
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

    fn start(&mut self) -> std::io::Result<OwnerRecord> {
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
            if Instant::now() >= deadline {
                break;
            }
            if self.wait_exit(Duration::from_millis(20)) {
                break;
            }
        }
        Ok(owner)
    }

    /// Wait for the child's exit on its own thread, so an exit wakes the loop at once.
    fn watch(&mut self, child: Child) {
        let (tx, rx) = mpsc::channel();
        let pid = child.id();
        self.child = Some(child);
        std::thread::spawn(move || {
            #[cfg(unix)]
            {
                let mut info: libc::siginfo_t = unsafe {
                    // SAFETY: an out parameter of plain integers; zero is valid.
                    std::mem::zeroed()
                };
                // SAFETY: waits for our own child's exit without reaping it (WNOWAIT): the
                // supervisor reaps it, so its pid is not reused while the record names it.
                unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
            }
            #[cfg(not(unix))]
            let _ = pid;
            let _ = tx.send(());
        });
        self.exits = Some(rx);
    }

    /// Whether the child has exited, waiting up to `within` for it. Sticky until reaped.
    fn wait_exit(&mut self, within: Duration) -> bool {
        if !self.exited {
            self.exited = match &self.exits {
                Some(rx) => rx.recv_timeout(within).is_ok(),
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
        self.exits = None;
    }

    fn restart(&mut self, owner: &OwnerRecord, liveness: Liveness) -> std::io::Result<OwnerRecord> {
        if liveness == Liveness::Alive {
            match &self.spec.restart {
                Some(cmd) => {
                    let _ = cmd.command().status();
                }
                None => self.stop_owner(owner),
            }
            self.reap();
        }
        self.start()
    }

    /// Stop the recorded owner: its process group, only while the record still names it.
    fn stop_owner(&mut self, owner: &OwnerRecord) {
        #[cfg(unix)]
        if owner.liveness() == Liveness::Alive {
            // SAFETY: plain signals to a group the record proves is the owner's.
            unsafe { libc::kill(owner.pid as libc::pid_t, libc::SIGTERM) };
            if !self.wait_exit(Duration::from_secs(5)) && owner.liveness() == Liveness::Alive {
                unsafe { libc::kill(owner.pid as libc::pid_t, libc::SIGKILL) };
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
