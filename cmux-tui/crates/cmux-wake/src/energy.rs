//! Whether Energy Saver is on for this process, and who to tell when it
//! changes. The daemon's `energy.set` op (task 033) and its
//! own power-source reading ([`super::PowerSource`], task 137) flip it; the
//! [`super::MaintenanceClock`] and other periodic owners watch it.
//!
//! Chrome keeps the same split: `BatterySaverModeManager` owns the state and
//! child processes get one `SetBatterySaverMode` call per edge
//! (chrome/browser/performance_manager/public/user_tuning/battery_saver_mode_manager.h).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use super::{DEFAULT_ALIGNMENT, Deadline, Policy, SAVER_ALIGNMENT, Ticks, deadline_aligned};

type Notify = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
struct Watchers {
    next_id: u64,
    list: Vec<(u64, Notify)>,
}

/// Energy Saver on or off: an atomic read for every consumer and a notify
/// on each edge.
pub struct EnergyMode {
    saver: AtomicBool,
    /// Who to tell on an edge. Taken only to add, remove or copy the list:
    /// a watcher is called after the lock is released, so no other lock is
    /// ever taken under it.
    watchers: Mutex<Watchers>,
}

impl EnergyMode {
    /// A mode that starts with Energy Saver `saver`.
    pub fn new(saver: bool) -> Arc<Self> {
        Arc::new(Self { saver: AtomicBool::new(saver), watchers: Mutex::new(Watchers::default()) })
    }

    /// Whether Energy Saver is on.
    pub fn is_saver(&self) -> bool {
        self.saver.load(Ordering::Acquire)
    }

    /// Turns Energy Saver on or off. On an edge every watcher is called once
    /// on this thread, and `true` is returned; setting the current value
    /// calls nobody. A watcher reads [`EnergyMode::is_saver`] itself, so two
    /// racing edges leave every watcher with the last value.
    pub fn set_saver(&self, saver: bool) -> bool {
        if self.saver.swap(saver, Ordering::AcqRel) == saver {
            return false;
        }
        let watchers: Vec<Notify> = {
            let guard = self.watchers.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            guard.list.iter().map(|(_, notify)| Arc::clone(notify)).collect()
        };
        for notify in watchers {
            notify();
        }
        true
    }

    /// Calls `notify` on every edge until the returned watch is dropped.
    /// `notify` runs on the thread that flips the mode: it must only wake
    /// its owner (a channel send, a kqueue trigger), never do the work.
    pub fn watch(self: &Arc<Self>, notify: impl Fn() + Send + Sync + 'static) -> EnergyWatch {
        let mut guard = self.watchers.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let id = guard.next_id;
        guard.next_id += 1;
        guard.list.push((id, Arc::new(notify)));
        EnergyWatch { mode: Arc::downgrade(self), id }
    }

    /// The sub-second wake grid: 32 ms in Energy Saver, 8 ms otherwise.
    pub fn alignment(&self) -> Duration {
        if self.is_saver() { SAVER_ALIGNMENT } else { DEFAULT_ALIGNMENT }
    }

    /// [`super::deadline`] on the grid of the current mode. Delays of 1 s or
    /// more keep their whole-second grid and 10% leeway in either mode.
    pub fn deadline(&self, now: Ticks, delay: Duration, policy: Policy) -> Deadline {
        deadline_aligned(now, delay, policy, self.alignment())
    }
}

/// A registered [`EnergyMode`] watcher; dropping it removes the watcher.
pub struct EnergyWatch {
    mode: Weak<EnergyMode>,
    id: u64,
}

impl Drop for EnergyWatch {
    fn drop(&mut self) {
        let Some(mode) = self.mode.upgrade() else { return };
        let mut guard = mode.watchers.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.list.retain(|(id, _)| *id != self.id);
    }
}
