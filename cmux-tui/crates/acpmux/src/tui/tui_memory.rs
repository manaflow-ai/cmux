//! The TUI process's memory response (`crate::memory`): its transcript layout
//! (`render::TranscriptCache`) is a lossless consumer. The pressure source's
//! thread never touches the app: at warning it posts `AppMsg::MemoryPressure`
//! and the event loop empties the cache on its own turn, with no redraw, so a
//! TUI nobody looks at keeps it empty until its next frame.

use super::AppMsg;
use super::render::TranscriptCache;
use crate::memory::AcpmuxMemory;
use cmux_memory::{MemoryConsumer, PressureLevel, Registration, Retention};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc::UnboundedSender;

/// The registry name of the TUI's transcript layout.
pub(super) const TRANSCRIPT_CACHE: &str = "tui.transcript_cache";

pub(super) struct TuiMemory {
    /// The cache's bytes as of the last frame.
    bytes: Arc<AtomicU64>,
    _registration: Registration,
    /// Declared last: the kernel source stops after the consumer is gone.
    _memory: AcpmuxMemory,
}

impl TuiMemory {
    /// Registers the transcript cache and starts this process's kernel source
    /// (with the `memoryAcpmuxPressure` feature on).
    pub(super) fn start(tx: UnboundedSender<AppMsg>) -> Self {
        let memory = AcpmuxMemory::new();
        let tui = Self::register(memory, tx);
        tui._memory.watch_if_enabled();
        tui
    }

    fn register(memory: AcpmuxMemory, tx: UnboundedSender<AppMsg>) -> Self {
        let bytes = Arc::new(AtomicU64::new(0));
        let reported = bytes.clone();
        let released = bytes.clone();
        let registration = memory.registry().register(MemoryConsumer::new(
            TRANSCRIPT_CACHE,
            Retention::Lossless,
            move || Some(reported.load(Ordering::Relaxed)),
            move |level| {
                if level >= PressureLevel::Warning && tx.send(AppMsg::MemoryPressure).is_ok() {
                    released.store(0, Ordering::Relaxed);
                }
            },
        ));
        Self { bytes, _registration: registration, _memory: memory }
    }

    /// After a frame: what the cache holds now.
    pub(super) fn drew(&self, cache: &TranscriptCache) {
        self.bytes.store(cache.approx_bytes(), Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_warning_asks_the_loop_to_empty_the_transcript_cache() {
        let memory = AcpmuxMemory::new();
        let registry = memory.registry().clone();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let tui = TuiMemory::register(memory, tx);
        tui.bytes.store(4096, Ordering::Relaxed);
        let bytes = |registry: &cmux_memory::MemoryRegistry| {
            registry.report().into_iter().find(|c| c.name == TRANSCRIPT_CACHE).and_then(|c| c.bytes)
        };
        assert_eq!(bytes(&registry), Some(4096));

        let source = registry.voter();
        source.set_level(PressureLevel::Warning);
        assert!(matches!(rx.try_recv(), Ok(AppMsg::MemoryPressure)));
        assert_eq!(bytes(&registry), Some(0));

        // Back at normal nothing more is asked.
        source.set_level(PressureLevel::Normal);
        assert!(rx.try_recv().is_err());
    }
}
