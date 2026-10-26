//! The daemon's memory registry: one per owner process (the `Mux` holds
//! it), with the kernel pressure source of `cmux-memory` started on first
//! use, so a headless daemon that never needs it starts none.
//!
//! Consumers: the standby host slot (lossless, `terminal.standby-host`) and
//! the output store's scrollback budget (lossy, `terminal.scrollback`, which
//! starts the source with the store).

use std::sync::OnceLock;

use cmux_memory::{MemoryRegistry, PressureWatch, WatchError};

pub(crate) struct DaemonMemory {
    registry: MemoryRegistry,
    /// Whether [`Self::watch_system_pressure`] starts the kernel source
    /// (tests drive the level through the registry instead).
    system_source: bool,
    watch: OnceLock<Option<PressureWatch>>,
}

impl Default for DaemonMemory {
    fn default() -> Self {
        Self { registry: MemoryRegistry::new(), system_source: true, watch: OnceLock::new() }
    }
}

impl DaemonMemory {
    /// A registry no kernel source feeds; the test sets its level.
    #[cfg(test)]
    pub(crate) fn without_system_source() -> Self {
        Self { system_source: false, ..Self::default() }
    }

    pub(crate) fn registry(&self) -> &MemoryRegistry {
        &self.registry
    }

    /// Starts the kernel pressure source once for this owner; later calls do
    /// nothing. Without a source the level stays normal.
    pub(crate) fn watch_system_pressure(&self) {
        if !self.system_source {
            return;
        }
        self.watch.get_or_init(|| match self.registry.watch_system_pressure() {
            Ok(watch) => Some(watch),
            Err(WatchError::Unsupported) => None,
            Err(error) => {
                eprintln!("cmux-tui: {error}");
                None
            }
        });
    }
}
