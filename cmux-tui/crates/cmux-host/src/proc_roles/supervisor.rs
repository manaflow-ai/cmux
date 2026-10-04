//! The supervisor thread: owns every process role's reducer and child.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_server_core::role_proc::{Action, Input, RoleHealth, RoleProc, RoleState};
use cmux_server_core::role_spec::{RoleSet, RoleSpec};

use super::{RolePaths, spawn};

/// A fact or a request for the supervisor thread.
pub enum Msg {
    /// The child exited (not yet reaped).
    Gone {
        name: String,
        pid: u32,
    },
    Ready {
        name: String,
        pid: u32,
    },
    Status {
        name: String,
        pid: u32,
        text: String,
    },
    /// Make the running set match (start, stop, restart changed entries).
    Apply(RoleSet),
    /// Stop every role; reply when all are down or at the deadline.
    StopAll {
        deadline: Instant,
        done: Sender<Vec<String>>,
    },
    Health(Sender<Vec<RoleHealth>>),
    /// End the thread (after `StopAll`).
    Exit,
}

/// What happens to an entry once its process is down.
#[derive(PartialEq)]
enum Next {
    Keep,
    /// Removed or disabled in config.
    Remove,
    /// Changed in config: start the new entry after the old process ends.
    Replace(RoleSpec),
}

struct Entry {
    spec: RoleSpec,
    proc: RoleProc,
    child: Option<Child>,
    wake: Option<Instant>,
    next: Next,
}

/// `<state>/roles/status.json`.
pub fn status_path(paths: &RolePaths) -> PathBuf {
    paths.state.join("roles").join("status.json")
}

/// A handle to the supervisor thread. Dropping it stops every role.
pub struct Supervisor {
    tx: Sender<Msg>,
    thread: Option<JoinHandle<()>>,
}

impl Supervisor {
    pub fn start(paths: RolePaths) -> std::io::Result<Supervisor> {
        let (tx, rx) = mpsc::channel();
        let loop_tx = tx.clone();
        let thread =
            std::thread::Builder::new().name("cmux-host-roles".to_owned()).spawn(move || {
                Loop { paths, entries: BTreeMap::new(), invalid: Vec::new() }.run(&rx, &loop_tx)
            })?;
        Ok(Supervisor { tx, thread: Some(thread) })
    }

    pub fn apply(&self, set: RoleSet) {
        let _ = self.tx.send(Msg::Apply(set));
    }

    /// Stops every role by `deadline` (SIGTERM, SIGKILL after each role's
    /// grace). Returns the roles still running at the deadline.
    pub fn stop_all(&self, deadline: Instant) -> Vec<String> {
        let (done, wait) = mpsc::channel();
        if self.tx.send(Msg::StopAll { deadline, done }).is_err() {
            return Vec::new();
        }
        let left = deadline.saturating_duration_since(Instant::now()) + Duration::from_secs(1);
        wait.recv_timeout(left).unwrap_or_else(|_| vec!["(supervisor did not answer)".to_owned()])
    }

    pub fn health(&self) -> Vec<RoleHealth> {
        let (reply, wait) = mpsc::channel();
        if self.tx.send(Msg::Health(reply)).is_err() {
            return Vec::new();
        }
        wait.recv_timeout(Duration::from_secs(5)).unwrap_or_default()
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.stop_all(Instant::now() + Duration::from_secs(15));
        let _ = self.tx.send(Msg::Exit);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Loop {
    paths: RolePaths,
    entries: BTreeMap<String, Entry>,
    invalid: Vec<RoleHealth>,
}

impl Loop {
    fn run(mut self, rx: &Receiver<Msg>, tx: &Sender<Msg>) {
        let mut stopping: Option<(Instant, Sender<Vec<String>>)> = None;
        loop {
            let next = self.entries.values().filter_map(|e| e.wake).min();
            let msg = match next {
                Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(msg) => Some(msg),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                },
                None => match rx.recv() {
                    Ok(msg) => Some(msg),
                    Err(_) => return,
                },
            };
            let now = Instant::now();
            match msg {
                None => self.fire_due(now, tx),
                Some(Msg::Gone { name, pid }) => {
                    let code = self.reap(&name, pid);
                    self.input(&name, Input::Exited { pid, code }, now, tx);
                }
                Some(Msg::Ready { name, pid }) => self.input_for(&name, pid, Input::Ready, now, tx),
                Some(Msg::Status { name, pid, text }) => {
                    self.input_for(&name, pid, Input::StatusText(text), now, tx);
                }
                Some(Msg::Apply(set)) => {
                    if stopping.is_none() {
                        self.apply(set, now, tx);
                    }
                }
                Some(Msg::StopAll { deadline, done }) => {
                    let names: Vec<String> = self.entries.keys().cloned().collect();
                    for name in names {
                        self.input(&name, Input::Stop, now, tx);
                    }
                    stopping = Some((deadline, done));
                }
                Some(Msg::Health(reply)) => {
                    let _ = reply.send(self.health());
                }
                Some(Msg::Exit) => return,
            }
            self.settle(now, tx);
            if let Some((deadline, _)) = &stopping {
                let all_down = self.entries.values().all(|e| e.proc.is_down());
                if all_down || Instant::now() >= *deadline {
                    let (_, done) = stopping.take().expect("stopping");
                    let left = self.entries.values().filter(|e| !e.proc.is_down());
                    let _ = done.send(left.map(|e| e.spec.name.clone()).collect());
                }
            }
            self.publish();
        }
    }

    fn apply(&mut self, set: RoleSet, now: Instant, tx: &Sender<Msg>) {
        self.invalid =
            set.invalid.iter().map(|bad| RoleHealth::invalid(&bad.name, &bad.reason)).collect();
        let mut wanted: BTreeMap<String, RoleSpec> =
            set.roles.into_iter().map(|spec| (spec.name.clone(), spec)).collect();
        let names: Vec<String> = self.entries.keys().cloned().collect();
        for name in names {
            let entry = self.entries.get_mut(&name).expect("entry");
            entry.next = match wanted.remove(&name) {
                Some(spec) if spec == entry.spec => Next::Keep,
                Some(spec) => Next::Replace(spec),
                None => Next::Remove,
            };
            if entry.next == Next::Keep {
                // Only a role that was stopped (park, shutdown) starts again;
                // a crash loop or a finished role waits for a config change.
                if entry.proc.health().state == RoleState::Stopped {
                    self.input(&name, Input::Start, now, tx);
                }
            } else {
                self.input(&name, Input::Stop, now, tx);
            }
        }
        for spec in wanted.into_values() {
            self.insert_and_start(spec, now, tx);
        }
    }

    fn insert_and_start(&mut self, spec: RoleSpec, now: Instant, tx: &Sender<Msg>) {
        let name = spec.name.clone();
        let proc = RoleProc::new(&name, spec.restart, spec.ready, spec.stop_grace);
        let entry = Entry { spec, proc, child: None, wake: None, next: Next::Keep };
        self.entries.insert(name.clone(), entry);
        self.input(&name, Input::Start, now, tx);
    }

    /// Drops removed entries and starts replacements once their old
    /// process is down.
    fn settle(&mut self, now: Instant, tx: &Sender<Msg>) {
        let down: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.next != Next::Keep && e.proc.is_down())
            .map(|(name, _)| name.clone())
            .collect();
        for name in down {
            let entry = self.entries.remove(&name).expect("entry");
            if let Next::Replace(spec) = entry.next {
                self.insert_and_start(spec, now, tx);
            }
        }
    }

    fn input_for(&mut self, name: &str, pid: u32, input: Input, now: Instant, tx: &Sender<Msg>) {
        if self.entries.get(name).and_then(|e| e.proc.pid()) == Some(pid) {
            self.input(name, input, now, tx);
        }
    }

    fn fire_due(&mut self, now: Instant, tx: &Sender<Msg>) {
        let due: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.wake.is_some_and(|at| at <= now))
            .map(|(name, _)| name.clone())
            .collect();
        for name in due {
            self.entries.get_mut(&name).expect("entry").wake = None;
            self.input(&name, Input::Due, now, tx);
        }
    }

    /// Feeds one input and performs the actions (a spawn feeds its result back).
    fn input(&mut self, name: &str, input: Input, now: Instant, tx: &Sender<Msg>) {
        let mut queue = vec![input];
        while let Some(input) = queue.pop() {
            let Some(entry) = self.entries.get_mut(name) else { return };
            for action in entry.proc.step(input, now) {
                match action {
                    Action::Spawn => match spawn::start(&entry.spec, &self.paths, tx) {
                        Ok(child) => {
                            queue.push(Input::Spawned { pid: child.id() });
                            entry.child = Some(child);
                        }
                        Err(error) => queue.push(Input::SpawnFailed { error }),
                    },
                    Action::Terminate { pid } => signal_group(pid, libc_sig::TERM),
                    Action::Kill { pid } => signal_group(pid, libc_sig::KILL),
                    Action::WakeAt(at) => entry.wake = Some(at),
                }
            }
        }
    }

    /// Reaps the exited child and returns its exit code (`None`: a signal).
    fn reap(&mut self, name: &str, pid: u32) -> Option<i32> {
        let entry = self.entries.get_mut(name)?;
        let mut child = entry.child.take_if(|c| c.id() == pid)?;
        child.wait().ok().and_then(|status| status.code())
    }

    fn health(&self) -> Vec<RoleHealth> {
        let mut all: Vec<RoleHealth> = self.entries.values().map(|e| e.proc.health()).collect();
        all.extend(self.invalid.iter().cloned());
        all
    }

    fn publish(&self) {
        let path = status_path(&self.paths);
        if let Some(dir) = path.parent()
            && cmux_server::fsx::ensure_dir(dir, 0o700).is_err()
        {
            return;
        }
        let json = serde_json::json!({ "roles": self.health() });
        let mut bytes = serde_json::to_vec_pretty(&json).unwrap_or_default();
        bytes.push(b'\n');
        let _ = cmux_server::fsx::atomic_write(&path, &bytes, 0o600);
    }
}

mod libc_sig {
    #[cfg(unix)]
    pub const TERM: i32 = libc::SIGTERM;
    #[cfg(unix)]
    pub const KILL: i32 = libc::SIGKILL;
    #[cfg(not(unix))]
    pub const TERM: i32 = 15;
    #[cfg(not(unix))]
    pub const KILL: i32 = 9;
}

/// Signals the role's process group (the child leads it). The child is not
/// reaped before the supervisor handles its exit, so the id is still ours.
fn signal_group(pid: u32, signal: i32) {
    #[cfg(unix)]
    // SAFETY: kill with a negative pid signals that process group only.
    unsafe {
        libc::kill(-(pid as libc::pid_t), signal);
    }
    #[cfg(not(unix))]
    let _ = (pid, signal);
}

/// Reads `<state>/roles/status.json` (for `cmux host roles`).
pub fn read_status(path: &Path) -> Option<serde_json::Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

#[cfg(test)]
#[path = "supervisor_tests.rs"]
mod tests;
