//! Raw output that an exited terminal can still serve. The writable recovery tail may
//! be compacted or trimmed, so it cannot own the only copy of these bytes.

use std::collections::VecDeque;
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, PoisonError};

use memmap2::Mmap;

use super::{LogState, OutputStore, PersistenceMode, TerminalPublicId};

/// The temporary log has no retained pathname or open descriptor. Its storage lives until
/// the final mapping drops, including on daemon exit. A raw read touches only its requested range.
pub(super) struct ParkedTail {
    map: Mmap,
    total: Arc<AtomicU64>,
    disk_bytes: u64,
}

impl ParkedTail {
    fn new(directory: &Path, tail: &VecDeque<u8>, total: &Arc<AtomicU64>) -> io::Result<Self> {
        std::fs::create_dir_all(directory)?;
        let mut file = tempfile::tempfile_in(directory)?;
        let (first, second) = tail.as_slices();
        file.write_all(first)?;
        file.write_all(second)?;
        // SAFETY: the unnamed file was created for this mapping. We never expose its
        // handle, change its length or write it again. Dropping the handle leaves this
        // read-only mapping as the sole owner.
        let map = unsafe { Mmap::map(&file)? };
        #[cfg(unix)]
        let disk_bytes = {
            use std::os::unix::fs::MetadataExt;
            file.metadata()?.blocks().saturating_mul(512).max(map.len() as u64)
        };
        #[cfg(not(unix))]
        let disk_bytes = map.len() as u64;
        total.fetch_add(disk_bytes, Ordering::Relaxed);
        Ok(Self { map, total: Arc::clone(total), disk_bytes })
    }

    pub(super) fn bytes(&self) -> &[u8] {
        &self.map
    }
}

impl Drop for ParkedTail {
    fn drop(&mut self) {
        self.total.fetch_sub(self.disk_bytes, Ordering::Relaxed);
    }
}

impl LogState {
    pub(super) fn thaw_tail(&mut self) {
        if let Some(parked) = self.parked_tail.take() {
            self.tail = VecDeque::from(parked.bytes().to_vec());
        }
    }
}

impl OutputStore {
    pub(super) fn parked_tail_bytes(&self) -> u64 {
        self.parked_tail_bytes.load(Ordering::Relaxed)
    }

    fn raw_tail_budget(&self, policy: super::PersistencePolicy) -> u64 {
        if policy.mode != PersistenceMode::Snapshot {
            return 0;
        }
        policy
            .max_total_bytes
            .min(policy.parked_max_total_bytes)
            .saturating_sub(self.snapshot_file_bytes.load(Ordering::Relaxed))
    }

    /// Durable snapshots take priority. The writer has already counted them in its
    /// ordinary cap scan. Give storage back to them without dropping readable output.
    pub(super) fn fit_parked_tails(&self, policy: super::PersistencePolicy) {
        let allowed = self.raw_tail_budget(policy);
        if self.parked_tail_bytes() <= allowed {
            return;
        }
        let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        for log in logs.values() {
            log.state.lock().unwrap_or_else(PoisonError::into_inner).thaw_tail();
            if self.parked_tail_bytes() <= allowed {
                break;
            }
        }
    }

    /// The exit and reader can race. Recheck the persisted generation and cursor before
    /// moving the hot tail. All pending recovery bytes and writer obligations stay with the log.
    pub(crate) fn release_terminal_output(
        &self,
        terminal_id: &TerminalPublicId,
        generation: &str,
        covered_through: u64,
    ) -> bool {
        let Some(directory) = self.directory() else { return false };
        let _pass = self.lock_pass();
        let Some(policy) = self.cached_policy() else { return false };
        if policy.mode != PersistenceMode::Snapshot
            || self.known_privacy(terminal_id) != Some(false)
        {
            return false;
        }
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned();
        let Some(log) = log else { return false };
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.forgotten
            || state.generation.as_ref() != generation
            || state.next_offset() != covered_through
        {
            return false;
        }
        let size = state.tail.len() as u64;
        let limit = self.raw_tail_budget(policy);
        if size == 0
            || size > limit.saturating_sub(self.parked_tail_bytes())
            || super::parked_trim::low_disk(directory, policy.min_free_disk_bytes)
        {
            return false;
        }
        let Ok(parked) = ParkedTail::new(directory, &state.tail, &self.parked_tail_bytes) else {
            return false;
        };
        if self.parked_tail_bytes() > limit {
            return false;
        }
        state.parked_tail = Some(Box::new(parked));
        state.tail = VecDeque::new();
        state.pending.shrink_to_fit();
        true
    }
}
