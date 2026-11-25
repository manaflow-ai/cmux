//! The deterministic simulation's agent seam (feature `sim`, never in a shipped build).
//!
//! A simulated daemon runs its agents in process: `ChildAgent::spawn_with` asks [`take`] before it
//! starts a process, and a profile that carries [`ENV`] gets the pipes of an agent the simulation
//! runs as a task on the daemon's own runtime instead (`tests/sim/`). Everything after the pipes
//! is the path a real child takes: the same reader, writer, tap and exit handling, so the
//! simulation exercises the daemon's code, not a copy of it.
//!
//! The factory is per thread: a simulation runs on one thread, and tests that run beside it on
//! other threads never see its agents.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::config::HarnessProfile;

/// The profile env key that marks a harness as the simulation's in-process agent.
pub const ENV: &str = "ACPMUX_SIM_AGENT";

/// One in-process agent's ends of its stdio, as a child process would give them.
pub struct Pipes {
    /// What the daemon writes to (the agent's stdin).
    pub stdin: Box<dyn AsyncWrite + Unpin + Send>,
    /// What the daemon reads (the agent's stdout).
    pub stdout: Box<dyn AsyncRead + Unpin + Send>,
    /// The agent's stderr.
    pub stderr: Box<dyn AsyncRead + Unpin + Send>,
    /// True while the agent runs: what a child's `try_wait` answers. The daemon sets it false
    /// when it kills the agent; the agent's task ends when it reads that or its stdin closes.
    pub alive: Arc<AtomicBool>,
}

type Factory = Arc<dyn Fn(&str, &HarnessProfile) -> Pipes>;

thread_local! {
    static FACTORY: RefCell<Option<Factory>> = const { RefCell::new(None) };
}

/// Runs in-process agents for profiles that carry [`ENV`] on this thread, until [`uninstall`].
pub fn install(factory: impl Fn(&str, &HarnessProfile) -> Pipes + 'static) {
    FACTORY.with(|f| *f.borrow_mut() = Some(Arc::new(factory)));
}

/// This thread starts real processes again.
pub fn uninstall() {
    FACTORY.with(|f| *f.borrow_mut() = None);
}

/// The pipes of an in-process agent for `profile`, when it is the simulation's and a factory is
/// installed on this thread.
pub(crate) fn take(name: &str, profile: &HarnessProfile) -> Option<Pipes> {
    if !profile.env.contains_key(ENV) {
        return None;
    }
    let factory = FACTORY.with(|f| f.borrow().clone())?;
    Some(factory(name, profile))
}
