//! The one terminal-host process started ahead of the next new tab (R81).
//!
//! Most of a new tab's launch is starting its host process. The owner keeps
//! at most one host process that has only run `exec` and waits on its
//! bootstrap pipe ([`StandbyTerminalHost`]): no identity, no PTY, no child,
//! no timers, so it uses no CPU. A `new-tab` prelaunch adopts it and sends
//! the tab's directory, command, environment and size in the Launch frame,
//! so the spare never carries a previous tab's environment. Rules:
//!
//! - Lazy: the spare exists only after the first new tab of this owner, so a
//!   headless daemon that never opens a tab never starts one.
//! - A burst of new tabs takes the spare once; the rest launch as before. The
//!   refill runs on the terminal work pool, one at a time, cap one spare.
//! - A spare that died before adoption is dropped and the tab launches as
//!   before, with no error.
//! - Memory pressure drops the spare: the slot is a lossless consumer in the
//!   daemon's memory registry (`cmux-memory`), Chrome's
//!   `SpareRenderProcessHostManager`, which keeps no spare under pressure.

use cmux_threads::sync::Mutex;
use std::sync::{Arc, MutexGuard, OnceLock, PoisonError, Weak};

use cmux_memory::{MemoryConsumer, PressureLevel, Registration, Retention};

use crate::memory::DaemonMemory;
use crate::terminal_host_runtime::StandbyTerminalHost;

#[derive(Default)]
struct StandbyState {
    /// A new tab ran on this owner; spares are worth keeping from now on.
    wanted: bool,
    /// A refill job is queued or running.
    refilling: bool,
    /// Memory pressure is warning or critical: keep no spare until normal.
    suppressed: bool,
    host: Option<StandbyTerminalHost>,
}

/// The spare host slot of one owner (cap one).
pub(crate) struct StandbyHostSlot {
    state: Mutex<StandbyState>,
    /// Starts a spare process ([`StandbyTerminalHost::spawn`]; tests start a
    /// stand-in that also waits on its stdin).
    spawn: fn() -> anyhow::Result<StandbyTerminalHost>,
    /// The owner's memory registry; its kernel source starts with the first
    /// refill.
    memory: Arc<DaemonMemory>,
    /// This slot's consumer in `memory`, set right after construction.
    consumer: OnceLock<Registration>,
}

impl StandbyHostSlot {
    /// The state; a poisoned lock still yields it (the memory-pressure
    /// handler runs on the pressure source's thread or C callback, where a
    /// panic would end the source).
    fn state(&self) -> MutexGuard<'_, StandbyState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn new(memory: Arc<DaemonMemory>) -> Arc<Self> {
        Self::with_spawner(memory, StandbyTerminalHost::spawn)
    }

    /// A slot that starts spares with `spawn`, registered in `memory`: under
    /// pressure now, it starts suppressed.
    pub(crate) fn with_spawner(
        memory: Arc<DaemonMemory>,
        spawn: fn() -> anyhow::Result<StandbyTerminalHost>,
    ) -> Arc<Self> {
        let slot =
            Arc::new(Self { state: Mutex::default(), spawn, memory, consumer: OnceLock::new() });
        let weak = Arc::downgrade(&slot);
        let consumer = MemoryConsumer::new(
            "terminal.standby-host",
            Retention::Lossless,
            // The spare's memory is its own process's, not this one's.
            || None,
            move |level| {
                if let Some(slot) = weak.upgrade() {
                    slot.set_memory_pressure(level != PressureLevel::Normal);
                }
            },
        );
        let registration = slot.memory.registry().register(consumer);
        let _ = slot.consumer.set(registration);
        slot
    }

    /// The spare for a new tab, if one is alive; marks spares as wanted.
    /// A spare killed before adoption is dropped here: the tab launches as
    /// before, with no error.
    pub(crate) fn take(&self) -> Option<StandbyTerminalHost> {
        let mut host = {
            let mut state = self.state();
            state.wanted = true;
            state.host.take()?
        };
        host.is_alive().then_some(host)
    }

    /// Whether a refill should start now; marks it started.
    fn begin_refill(&self) -> bool {
        let mut state = self.state();
        if !state.wanted || state.suppressed || state.refilling || state.host.is_some() {
            return false;
        }
        state.refilling = true;
        true
    }

    /// A refill finished with `spawned`; a spare that is no longer wanted
    /// (dropped meanwhile, or the slot filled) is killed as it drops.
    fn finish_refill(&self, spawned: Option<StandbyTerminalHost>) {
        let unused = {
            let mut state = self.state();
            state.refilling = false;
            if state.wanted && !state.suppressed && state.host.is_none() {
                state.host = spawned;
                None
            } else {
                spawned
            }
        };
        drop(unused);
    }

    /// Memory pressure changed: under warning or critical pressure the spare
    /// is dropped and no new one starts; back to normal, the next new tab
    /// refills it.
    fn set_memory_pressure(&self, pressured: bool) {
        let host = {
            let mut state = self.state();
            state.suppressed = pressured;
            if pressured { state.host.take() } else { None }
        };
        drop(host);
    }

    #[cfg(test)]
    pub(crate) fn has_spare(&self) -> bool {
        self.state().host.is_some()
    }

    #[cfg(test)]
    pub(crate) fn is_refilling(&self) -> bool {
        self.state().refilling
    }

    #[cfg(test)]
    pub(crate) fn finish_refill_for_test(&self, host: StandbyTerminalHost) {
        self.state().refilling = true;
        self.finish_refill(Some(host));
    }

    /// Starts one refill on `pool` when a spare is wanted and none exists.
    #[track_caller]
    pub(crate) fn refill(self: &Arc<Self>, pool: &super::TerminalWorkPool) {
        // The first watch reads the system's level before it returns, so a
        // daemon already under pressure suppresses the slot before it decides.
        self.memory.watch_system_pressure();
        if !self.begin_refill() {
            return;
        }
        let slot: Weak<Self> = Arc::downgrade(self);
        let spawn = self.spawn;
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            let spawned = spawn().ok();
            match slot.upgrade() {
                Some(slot) => slot.finish_refill(spawned),
                None => drop(spawned),
            }
        });
        if let Err(job) = pool.try_submit(job) {
            // A saturated pool: skip this refill rather than start a process
            // inline on the caller's thread; the next new tab tries again.
            drop(job);
            self.state().refilling = false;
        }
    }
}

#[cfg(all(test, unix))]
#[path = "standby_host_tests.rs"]
mod tests;
