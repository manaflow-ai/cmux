//! The daemon's memory registry. The `Mux` composition root makes one
//! (`Mux::memory`) and hands it to every consumer; the kernel pressure source
//! of `cmux-memory` starts on first use, so a headless daemon that never
//! needs it starts none. Other sources (the app's `memory.limit` push) vote
//! through [`MemoryRegistry::voter`]; the level is the worst vote.
//!
//! Consumers: the standby host slot (lossless, `terminal.standby-host`), the
//! Kitty pixel maps (lossless, `terminal.kitty-pixels`, which start the
//! source with the mux) and the output store's scrollback budget (lossy,
//! `terminal.scrollback`, which starts the source with the store).

use std::sync::{Arc, OnceLock};

use cmux_memory::{MemoryRegistry, PressureWatch, WatchError};

/// Where [`DaemonMemory::watch_system_pressure`] gets the system's level.
enum SystemSource {
    /// The kernel source of `cmux-memory`.
    Kernel,
    /// None: the level stays where the registry's other voters put it.
    #[cfg(test)]
    Off,
    /// A stand-in kernel that votes this level when the watch starts.
    #[cfg(test)]
    StandIn(cmux_memory::PressureLevel),
}

/// What an owner's memory response starts with (`Mux` construction): its
/// registry, and whether the output store's scrollback budget is one of the
/// registry's consumers.
pub(crate) struct MemorySetup {
    pub(crate) memory: Arc<DaemonMemory>,
    /// The `memoryScrollbackPressure` feature
    /// (`crate::output_store::SCROLLBACK_PRESSURE_FEATURE`).
    pub(crate) scrollback_pressure: bool,
    /// The `memoryKittyShare` feature (`crate::mux::KITTY_SHARE_FEATURE`).
    pub(crate) kitty_share: bool,
}

impl MemorySetup {
    /// A registry fed by the kernel source, the feature from the process's
    /// feature lists.
    pub(crate) fn from_env() -> Self {
        Self {
            memory: Arc::new(DaemonMemory::new()),
            scrollback_pressure: cmux_features::listed_in_env(
                crate::output_store::SCROLLBACK_PRESSURE_FEATURE,
            ),
            kitty_share: cmux_features::listed_in_env(crate::mux::KITTY_SHARE_FEATURE),
        }
    }
}

/// A running system source; dropping it withdraws its vote.
enum RunningSource {
    Kernel(#[allow(dead_code)] PressureWatch),
    #[cfg(test)]
    StandIn(#[allow(dead_code)] cmux_memory::Voter),
}

pub(crate) struct DaemonMemory {
    registry: MemoryRegistry,
    system_source: SystemSource,
    watch: OnceLock<Option<RunningSource>>,
}

impl DaemonMemory {
    /// The owner's registry, fed by the kernel source once it starts.
    pub(crate) fn new() -> Self {
        Self::with_source(SystemSource::Kernel)
    }

    fn with_source(system_source: SystemSource) -> Self {
        Self { registry: MemoryRegistry::new(), system_source, watch: OnceLock::new() }
    }

    /// A registry no system source feeds; the test votes its level.
    #[cfg(test)]
    pub(crate) fn without_system_source() -> Self {
        Self::with_source(SystemSource::Off)
    }

    /// A registry whose system source reports `level` from the moment it
    /// starts, as the kernel does when it is already under pressure.
    #[cfg(test)]
    pub(crate) fn with_stand_in_system_level(level: cmux_memory::PressureLevel) -> Self {
        Self::with_source(SystemSource::StandIn(level))
    }

    pub(crate) fn registry(&self) -> &MemoryRegistry {
        &self.registry
    }

    /// Starts the system pressure source once for this owner; later calls do
    /// nothing. The source reads the current level before this returns.
    /// Without a source, or where this process may not use it, it votes
    /// nothing.
    pub(crate) fn watch_system_pressure(&self) {
        self.watch.get_or_init(|| match &self.system_source {
            SystemSource::Kernel => match self.registry.watch_system_pressure() {
                Ok(watch) => Some(RunningSource::Kernel(watch)),
                Err(WatchError::Unsupported | WatchError::NotPermitted(_)) => None,
                Err(error) => {
                    eprintln!("cmux-tui: {error}");
                    None
                }
            },
            #[cfg(test)]
            SystemSource::Off => None,
            #[cfg(test)]
            SystemSource::StandIn(level) => {
                let voter = self.registry.voter();
                voter.set_level(*level);
                Some(RunningSource::StandIn(voter))
            }
        });
    }
}
