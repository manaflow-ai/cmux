//! Session-scoped executor for terminal host effects.
//!
//! A create or close request commits its durable intent, publishes the tree
//! change, and replies. The process I/O that used to sit on that request
//! thread (fork/exec of the host, its handshake, `Activate`, `Terminate` and
//! the exit wait) runs here instead, on a small pool of named threads. The
//! request thread never waits on a child process; the executor never touches
//! the request's response. `spec/interaction-lifecycle.md` names this the
//! settle stage.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use super::Mux;
use crate::surface::{Surface, SurfaceOptions};

/// Worker threads per session. Launches are dominated by the child's own
/// startup, so a handful of workers keeps eight concurrent creates from
/// queueing behind one slow shell without spawning a thread per terminal.
pub(crate) const TERMINAL_EFFECT_WORKERS: usize = 4;

/// Opened when the created terminal's public topology is durable. The launch
/// job sends `Activate` only after it opens, which keeps the terminal host
/// launch barrier (`spec/terminal-host.md`, Handshakes) intact: the first
/// exact PTY byte is observed only after the topology that names it commits.
#[derive(Default)]
pub(crate) struct LaunchActivationGate {
    open: Mutex<bool>,
    changed: Condvar,
}

impl LaunchActivationGate {
    pub(crate) fn open(&self) {
        *self.open.lock().unwrap() = true;
        self.changed.notify_all();
    }

    /// Wait for the gate. Returns `false` at the deadline; the host releases
    /// its own barrier after the `host.launch_owner` budget regardless, so a
    /// caller that times out may still activate without harm.
    pub(crate) fn wait_until(&self, deadline: Instant) -> bool {
        let mut open = self.open.lock().unwrap();
        while !*open {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            let (next, _) = self.changed.wait_timeout(open, deadline - now).unwrap();
            open = next;
        }
        true
    }
}

pub(crate) struct LaunchJob {
    pub(crate) surface: Arc<Surface>,
    pub(crate) terminal_id: String,
    pub(crate) workspace_key: String,
    pub(crate) options: SurfaceOptions,
    pub(crate) host_root: PathBuf,
    pub(crate) cell_pixels: (u16, u16),
    pub(crate) activation: Arc<LaunchActivationGate>,
    pub(crate) started: Instant,
}

pub(crate) struct TerminateJob {
    pub(crate) runtime: Arc<Surface>,
}

pub(crate) enum TerminalEffectJob {
    Launch(Box<LaunchJob>),
    Terminate(TerminateJob),
    TerminateDiscovered { terminal_id: String, incarnation: Option<String> },
}

struct QueuedEffect {
    job: TerminalEffectJob,
}

struct RunningEffect {
    token: u64,
}

#[derive(Default)]
struct Inner {
    queue: VecDeque<QueuedEffect>,
    running: Vec<RunningEffect>,
    next_token: u64,
    shutting_down: bool,
}

pub(crate) struct TerminalEffectExecutor {
    inner: Mutex<Inner>,
    wake: Condvar,
    workers: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl TerminalEffectExecutor {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Inner::default()),
            wake: Condvar::new(),
            workers: Mutex::new(Vec::new()),
        })
    }

    /// Start the worker pool. Idempotent; workers hold only a weak mux.
    pub(crate) fn start(self: &Arc<Self>, mux: Weak<Mux>) {
        let mut workers = self.workers.lock().unwrap();
        if !workers.is_empty() {
            return;
        }
        for index in 0..TERMINAL_EFFECT_WORKERS {
            let executor = self.clone();
            let mux = mux.clone();
            let spawned = std::thread::Builder::new()
                .name(format!("terminal-effect-{index}"))
                .spawn(move || executor.worker_loop(mux));
            match spawned {
                Ok(handle) => workers.push(handle),
                Err(error) => {
                    eprintln!("cmux-tui: could not start terminal effect worker {index}: {error}");
                }
            }
        }
    }

    /// Queue one effect. Returns `false` when the executor is stopping, in
    /// which case the caller runs the effect inline or drops it deliberately.
    pub(crate) fn enqueue(&self, job: TerminalEffectJob) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.shutting_down {
            return false;
        }
        inner.queue.push_back(QueuedEffect { job });
        drop(inner);
        self.wake.notify_one();
        true
    }

    /// Stop accepting work and give running effects until `deadline` to
    /// finish. Terminations in flight are bounded by their own host budgets;
    /// a launch in flight leaves an adoptable host for the next daemon.
    pub(crate) fn shutdown(&self, deadline: Instant) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.shutting_down = true;
        }
        self.wake.notify_all();
        let workers = std::mem::take(&mut *self.workers.lock().unwrap());
        for worker in workers {
            if worker.thread().id() == std::thread::current().id() {
                continue;
            }
            let mut inner = self.inner.lock().unwrap();
            while !inner.running.is_empty() || !inner.queue.is_empty() {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                let (next, _) = self.wake.wait_timeout(inner, deadline - now).unwrap();
                inner = next;
            }
            drop(inner);
            if worker.is_finished() {
                let _ = worker.join();
            }
        }
    }

    fn worker_loop(self: Arc<Self>, mux: Weak<Mux>) {
        loop {
            let (job, token) = {
                let mut inner = self.inner.lock().unwrap();
                loop {
                    if let Some(queued) = inner.queue.pop_front() {
                        let token = inner.next_token;
                        inner.next_token += 1;
                        inner.running.push(RunningEffect { token });
                        break (queued.job, token);
                    }
                    if inner.shutting_down {
                        return;
                    }
                    inner = self.wake.wait(inner).unwrap();
                }
            };
            if let Some(mux) = mux.upgrade() {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    mux.run_terminal_effect(job);
                }));
                if outcome.is_err() {
                    eprintln!("cmux-tui: terminal effect worker recovered from a panic");
                }
            }
            let mut inner = self.inner.lock().unwrap();
            inner.running.retain(|running| running.token != token);
            drop(inner);
            self.wake.notify_all();
        }
    }
}

/// Upper bound the launch job waits for the topology gate before activating
/// anyway. Mirrors the host's own `host.launch_owner` budget: after it the
/// host releases its PTY reader itself, so waiting longer buys nothing.
pub(crate) const LAUNCH_ACTIVATION_WAIT: Duration = Duration::from_secs(5);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activation_gate_wakes_waiters_and_times_out() {
        let gate = Arc::new(LaunchActivationGate::default());
        assert!(!gate.wait_until(Instant::now() + Duration::from_millis(20)));
        let waiter = {
            let gate = gate.clone();
            std::thread::spawn(move || gate.wait_until(Instant::now() + Duration::from_secs(5)))
        };
        gate.open();
        assert!(waiter.join().unwrap());
        assert!(gate.wait_until(Instant::now()));
    }
}
