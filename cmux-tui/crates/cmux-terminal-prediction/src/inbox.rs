//! Buffers PTY output between the reader thread and whoever consumes it.

use crate::config::PredictionInstant;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::sync::{Mutex, MutexGuard};

/// One chunk of PTY output, stamped when it arrived.
///
/// The instant travels with the bytes because latency is measured from it: if
/// the engine read the clock at drain time instead, queueing delay would be
/// charged to the remote and the link would look slower than it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PredictionOutputBatch {
    pub instant: PredictionInstant,
    pub bytes: Vec<u8>,
    /// Output was dropped before this point because the surface outran the
    /// drain; whatever the engine was tracking is unknowable now.
    pub follows_dropped_output: bool,
}

impl PredictionOutputBatch {
    pub fn new(instant: PredictionInstant, bytes: Vec<u8>, follows_dropped_output: bool) -> Self {
        Self { instant, bytes, follows_dropped_output }
    }
}

struct InboxState<K> {
    accepted_surfaces: HashSet<K>,
    batches: HashMap<K, Vec<PredictionOutputBatch>>,
    buffered_bytes: HashMap<K, usize>,
    is_drain_scheduled: bool,
}

/// Buffers PTY output between the reader thread and whoever consumes it.
///
/// libghostty's tee fires on the IO read thread, once per read, ahead of the
/// VT parser. Hopping to the main thread per read would put an agent's output
/// flood straight onto the UI thread, so deposits accumulate here and only
/// the first one asks for a drain. Order within a surface is preserved.
///
/// Only surfaces the host accepted are buffered. Every terminal's output
/// reaches the tee, and a local one is never predicted, so its reads are
/// dropped before any bytes are copied.
pub struct PredictionOutputInbox<K> {
    state: Mutex<InboxState<K>>,
    /// Buffered bytes per surface before older output is dropped. A remote
    /// `cat` or a build log can outrun the main thread; prediction only needs
    /// the newest output, and a drop is reported so the engine resets.
    maximum_buffered_bytes: usize,
}

impl<K: Eq + Hash + Clone> Default for PredictionOutputInbox<K> {
    fn default() -> Self {
        Self::new(1 << 20)
    }
}

impl<K: Eq + Hash + Clone> PredictionOutputInbox<K> {
    pub fn new(maximum_buffered_bytes: usize) -> Self {
        Self {
            state: Mutex::new(InboxState {
                accepted_surfaces: HashSet::new(),
                batches: HashMap::new(),
                buffered_bytes: HashMap::new(),
                is_drain_scheduled: false,
            }),
            maximum_buffered_bytes,
        }
    }

    fn lock(&self) -> MutexGuard<'_, InboxState<K>> {
        // The state stays consistent under a panic elsewhere: every write is
        // a whole-field assignment.
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Starts buffering a surface's output.
    pub fn accept(&self, surface: K) {
        self.lock().accepted_surfaces.insert(surface);
    }

    /// Adds a chunk, when the surface was accepted.
    ///
    /// Returns `true` when the caller owns scheduling the drain, which is
    /// exactly once per drain cycle no matter how many threads deposit.
    pub fn deposit(&self, surface: &K, bytes: &[u8], instant: PredictionInstant) -> bool {
        if bytes.is_empty() {
            return false;
        }
        let maximum = self.maximum_buffered_bytes;
        let mut state = self.lock();
        if !state.accepted_surfaces.contains(surface) {
            return false;
        }
        let buffered = state.buffered_bytes.get(surface).copied().unwrap_or(0) + bytes.len();
        if buffered > maximum {
            let kept = &bytes[bytes.len().saturating_sub(maximum)..];
            state
                .batches
                .insert(surface.clone(), vec![PredictionOutputBatch::new(instant, kept.to_vec(), true)]);
            state.buffered_bytes.insert(surface.clone(), bytes.len().min(maximum));
        } else {
            state
                .batches
                .entry(surface.clone())
                .or_default()
                .push(PredictionOutputBatch::new(instant, bytes.to_vec(), false));
            state.buffered_bytes.insert(surface.clone(), buffered);
        }
        if state.is_drain_scheduled {
            return false;
        }
        state.is_drain_scheduled = true;
        true
    }

    /// Takes everything buffered and re-arms scheduling.
    pub fn drain(&self) -> HashMap<K, Vec<PredictionOutputBatch>> {
        let mut state = self.lock();
        let taken = std::mem::take(&mut state.batches);
        state.buffered_bytes.clear();
        state.is_drain_scheduled = false;
        taken
    }

    /// Takes one surface's buffered output, leaving the rest and the scheduled
    /// drain alone.
    pub fn drain_surface(&self, surface: &K) -> Vec<PredictionOutputBatch> {
        let mut state = self.lock();
        state.buffered_bytes.remove(surface);
        state.batches.remove(surface).unwrap_or_default()
    }

    /// Stops buffering a surface and drops what it has buffered, without
    /// draining the rest.
    pub fn forget(&self, surface: &K) {
        let mut state = self.lock();
        state.accepted_surfaces.remove(surface);
        state.batches.remove(surface);
        state.buffered_bytes.remove(surface);
    }

    /// Stops buffering every surface and drops everything buffered.
    pub fn forget_all(&self) {
        let mut state = self.lock();
        state.accepted_surfaces.clear();
        state.batches.clear();
        state.buffered_bytes.clear();
    }
}
