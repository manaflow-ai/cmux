//! Memory pressure and memory consumers for cmux's Rust processes.
//!
//! Chrome's model (`base/memory_coordinator/`, `memory_consumer.h`,
//! `components/memory_pressure/`): one kernel pressure source per process
//! feeds one registry; each subsystem that holds memory it can give back
//! registers a [`MemoryConsumer`] (a name, lossless or lossy, how many bytes it
//! holds, and what it does at each level). A level change reaches every
//! consumer once, lossless consumers first and lossy ones last (Chrome releases
//! cheap, lossless memory before it discards anything). There is no thread or
//! timer per consumer: the source's own event drives the delivery.
//!
//! The sources are [`MemoryRegistry::watch_system_pressure`]: on macOS one
//! libdispatch memory-pressure source that re-reads the kernel level on each
//! event (`system_memory_pressure_evaluator_mac.cc`), on Linux one PSI trigger
//! on `/proc/pressure/memory`. Other code (the app's `memory.limit` push) can set
//! the level with [`MemoryRegistry::set_level`].
//!
//! [`DaemonBudget`] sizes the daemon's memory caps from installed RAM, as
//! `SubsystemBudget.forMemory` does for the app
//! (plans/cmux-next/chrome-parity/p07-memory.md, section B).

use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

pub use budget::DaemonBudget;

pub mod budget;
#[cfg(target_os = "linux")]
mod pressure_linux;
#[cfg(target_os = "macos")]
mod pressure_macos;

/// The memory pressure level (Chrome's `MemoryPressureLevel`: none, moderate,
/// critical).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PressureLevel {
    #[default]
    Normal,
    Warning,
    Critical,
}

/// What a consumer loses when it releases (Chrome's `InformationRetention`).
/// Lossless consumers release first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Retention {
    /// Releasing loses nothing a person can see: a cache or a spare that is
    /// rebuilt on demand.
    Lossless,
    /// Releasing drops state the person may notice (a discard).
    Lossy,
}

type BytesFn = dyn Fn() -> Option<u64> + Send + Sync;
type ReleaseFn = dyn Fn(PressureLevel) + Send + Sync;

/// One subsystem's memory, as the registry sees it.
pub struct MemoryConsumer {
    name: String,
    retention: Retention,
    bytes: Box<BytesFn>,
    release: Box<ReleaseFn>,
}

impl MemoryConsumer {
    /// `bytes` reports what the consumer holds now (`None`: unknown, or held
    /// in another process). `release` runs on each level change: at warning
    /// or critical it frees what that level asks for, back at normal it may
    /// fill again. It runs on the pressure source's thread and must not
    /// block, register a consumer or set the level.
    pub fn new(
        name: impl Into<String>,
        retention: Retention,
        bytes: impl Fn() -> Option<u64> + Send + Sync + 'static,
        release: impl Fn(PressureLevel) + Send + Sync + 'static,
    ) -> Self {
        Self { name: name.into(), retention, bytes: Box::new(bytes), release: Box::new(release) }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn retention(&self) -> Retention {
        self.retention
    }

    fn deliver(&self, level: PressureLevel) {
        // One consumer's panic must not stop the others, nor unwind into a C
        // callback (the macOS source), where it would abort the process.
        if catch_unwind(AssertUnwindSafe(|| (self.release)(level))).is_err() {
            eprintln!("cmux-memory: consumer {} panicked on {level:?}", self.name);
        }
    }
}

/// One line of [`MemoryRegistry::report`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConsumerReport {
    pub name: String,
    pub retention: Retention,
    pub bytes: Option<u64>,
}

#[derive(Default)]
struct State {
    level: PressureLevel,
    next_id: u64,
    consumers: Vec<(u64, Arc<MemoryConsumer>)>,
}

#[derive(Default)]
struct Shared {
    /// Serializes deliveries, so consumers see level changes in order. Taken
    /// before `state`, never inside a consumer callback.
    delivery: Mutex<()>,
    state: Mutex<State>,
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn delivery(&self) -> MutexGuard<'_, ()> {
        self.delivery.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_level(&self, level: PressureLevel) {
        let _delivery = self.delivery();
        let mut consumers = {
            let mut state = self.state();
            if state.level == level {
                return;
            }
            state.level = level;
            state.consumers.iter().map(|(_, consumer)| consumer.clone()).collect::<Vec<_>>()
        };
        // Lossless first, lossy last; registration order within each.
        consumers.sort_by_key(|consumer| consumer.retention);
        for consumer in consumers {
            consumer.deliver(level);
        }
    }
}

/// The consumers of one process and its current level. Cloning shares it.
#[derive(Clone, Default)]
pub struct MemoryRegistry {
    shared: Arc<Shared>,
}

impl MemoryRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// The current level.
    pub fn level(&self) -> PressureLevel {
        self.shared.state().level
    }

    /// Sets the level; on a change every consumer hears it once, lossless
    /// ones first. A repeated level does nothing.
    pub fn set_level(&self, level: PressureLevel) {
        self.shared.set_level(level);
    }

    /// Adds `consumer` until the returned [`Registration`] drops. Under
    /// pressure the consumer hears the current level before this returns
    /// (Chrome: a new registrant gets the current limit synchronously).
    pub fn register(&self, consumer: MemoryConsumer) -> Registration {
        let consumer = Arc::new(consumer);
        let _delivery = self.shared.delivery();
        let (id, level) = {
            let mut state = self.shared.state();
            let id = state.next_id;
            state.next_id += 1;
            state.consumers.push((id, consumer.clone()));
            (id, state.level)
        };
        if level != PressureLevel::Normal {
            consumer.deliver(level);
        }
        Registration { shared: Arc::downgrade(&self.shared), id }
    }

    /// Every consumer with the bytes it reports now, in registration order.
    pub fn report(&self) -> Vec<ConsumerReport> {
        let consumers: Vec<_> =
            self.shared.state().consumers.iter().map(|(_, consumer)| consumer.clone()).collect();
        consumers
            .iter()
            .map(|consumer| ConsumerReport {
                name: consumer.name.clone(),
                retention: consumer.retention,
                bytes: (consumer.bytes)(),
            })
            .collect()
    }

    /// Starts this process's kernel pressure source feeding this registry
    /// until the returned watch drops. Start one per process.
    pub fn watch_system_pressure(&self) -> Result<PressureWatch, WatchError> {
        let registry = Arc::downgrade(&self.shared);
        #[cfg(target_os = "macos")]
        {
            pressure_macos::Watch::start(WeakRegistry(registry))
                .map(|source| PressureWatch { source })
        }
        #[cfg(target_os = "linux")]
        {
            pressure_linux::Watch::start(WeakRegistry(registry))
                .map(|source| PressureWatch { source })
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            drop(registry);
            Err(WatchError::Unsupported)
        }
    }
}

/// The registry as a pressure source holds it: a source never keeps its
/// registry alive.
#[cfg_attr(not(any(target_os = "macos", target_os = "linux")), allow(dead_code))]
pub(crate) struct WeakRegistry(Weak<Shared>);

#[cfg_attr(not(any(target_os = "macos", target_os = "linux")), allow(dead_code))]
impl WeakRegistry {
    pub(crate) fn set_level(&self, level: PressureLevel) {
        if let Some(shared) = self.0.upgrade() {
            shared.set_level(level);
        }
    }
}

/// Keeps a consumer registered; dropping it unregisters the consumer.
pub struct Registration {
    shared: Weak<Shared>,
    id: u64,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let Some(shared) = self.shared.upgrade() else { return };
        let removed = {
            let mut state = shared.state();
            let index = state.consumers.iter().position(|(id, _)| *id == self.id);
            index.map(|index| state.consumers.remove(index))
        };
        // The consumer's captures drop outside the registry's lock.
        drop(removed);
    }
}

/// A running kernel pressure source; dropping it stops the source.
pub struct PressureWatch {
    #[cfg(target_os = "macos")]
    #[allow(dead_code)]
    source: pressure_macos::Watch,
    #[cfg(target_os = "linux")]
    #[allow(dead_code)]
    source: pressure_linux::Watch,
}

/// Why no kernel pressure source started.
#[derive(Debug)]
pub enum WatchError {
    /// This platform has no pressure source (or, on Linux, no PSI).
    Unsupported,
    /// The source could not start.
    Io(std::io::Error),
}

impl fmt::Display for WatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => f.write_str("no memory pressure source on this system"),
            Self::Io(error) => write!(f, "memory pressure source: {error}"),
        }
    }
}

impl std::error::Error for WatchError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Unsupported => None,
            Self::Io(error) => Some(error),
        }
    }
}

#[cfg(test)]
mod tests;
