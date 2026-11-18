//! One emit per surface per animation frame (design, "Streaming and
//! frames"). The caller owns the clock: it passes milliseconds in and gets
//! back whether to emit now or when the deferred emit is due.

use std::collections::HashMap;
use std::hash::Hash;

pub const FRAME_MS: u64 = 16;

#[derive(Clone, Debug)]
pub struct Coalescer<K> {
    interval_ms: u64,
    last_emit: HashMap<K, u64>,
    /// Keys with an update held back, and when it is due.
    held: HashMap<K, u64>,
}

impl<K: Eq + Hash + Clone> Default for Coalescer<K> {
    fn default() -> Self {
        Self::new(FRAME_MS)
    }
}

impl<K: Eq + Hash + Clone> Coalescer<K> {
    pub fn new(interval_ms: u64) -> Self {
        Self { interval_ms, last_emit: HashMap::new(), held: HashMap::new() }
    }

    /// An update for `key` arrived at `now_ms`. True: emit it now. False: it
    /// is held; [`Self::due`] returns the key once its frame has passed.
    pub fn offer(&mut self, key: K, now_ms: u64) -> bool {
        match self.last_emit.get(&key) {
            Some(&last) if now_ms < last + self.interval_ms => {
                self.held.entry(key).or_insert(last + self.interval_ms);
                false
            }
            _ => {
                self.held.remove(&key);
                self.last_emit.insert(key, now_ms);
                true
            }
        }
    }

    /// Held keys whose frame has passed; each is marked emitted at `now_ms`.
    pub fn due(&mut self, now_ms: u64) -> Vec<K> {
        let ready: Vec<K> =
            self.held.iter().filter(|(_, due)| **due <= now_ms).map(|(k, _)| k.clone()).collect();
        for k in &ready {
            self.held.remove(k);
            self.last_emit.insert(k.clone(), now_ms);
        }
        ready
    }

    /// When the next held emit is due, for the caller's timer.
    pub fn next_due(&self) -> Option<u64> {
        self.held.values().copied().min()
    }

    /// Emit now regardless (the final state of a stream) and forget the key.
    pub fn finish(&mut self, key: &K) -> bool {
        self.last_emit.remove(key);
        self.held.remove(key).is_some()
    }
}
