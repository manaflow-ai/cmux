//! The key press a PTY read echoes: the PTY's
//! reader-side owner arms a slot with the `flow` of input it writes to the
//! PTY, and its next output read takes it, once.

use std::sync::atomic::{AtomicU64, Ordering};

/// One terminal's armed key-press flow (0: none since the last read took
/// it). A newer key press replaces an older one that has no echo yet.
#[derive(Debug, Default)]
pub(crate) struct InputFlowSlot(AtomicU64);

impl InputFlowSlot {
    /// Arm `flow` (0 does nothing). Call it before the input's write: its
    /// echo can be read before the write returns.
    pub(crate) fn arm(&self, flow: u64) {
        if flow != 0 {
            self.0.store(flow, Ordering::Release);
        }
    }

    /// Disarm `flow` when its input never reached the PTY (dropped or
    /// failed), unless a newer key press armed its own since or a read
    /// already took it.
    pub(crate) fn withdraw(&self, flow: u64) {
        if flow != 0 {
            let _ = self.0.compare_exchange(flow, 0, Ordering::AcqRel, Ordering::Acquire);
        }
    }

    /// The flow the output read now echoes, once (0: none). Without a flow
    /// this is one load, no write.
    pub(crate) fn take(&self) -> u64 {
        if self.0.load(Ordering::Acquire) == 0 {
            return 0;
        }
        self.0.swap(0, Ordering::AcqRel)
    }
}

#[cfg(test)]
mod tests {
    use super::InputFlowSlot;

    #[test]
    fn echo_flow_slot_is_taken_once_and_withdrawn_only_for_its_own_flow() {
        let slot = InputFlowSlot::default();
        slot.arm(42);
        assert_eq!(slot.take(), 42);
        assert_eq!(slot.take(), 0, "only once");

        // A dropped write disarms its own flow.
        slot.arm(42);
        slot.withdraw(42);
        assert_eq!(slot.take(), 0);

        // It leaves a newer key press's flow armed.
        slot.arm(43);
        slot.withdraw(42);
        assert_eq!(slot.take(), 43);

        slot.arm(0);
        assert_eq!(slot.take(), 0, "flow 0 arms nothing");
    }
}
