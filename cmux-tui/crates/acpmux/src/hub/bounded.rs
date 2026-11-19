use std::collections::VecDeque;
use std::marker::PhantomData;

pub(super) trait SuffixMetric {
    fn len(text: &str) -> usize;
    fn tail(text: &str, max: usize) -> &str;
}

pub(super) struct Chars;

impl SuffixMetric for Chars {
    fn len(text: &str) -> usize {
        text.chars().count()
    }

    fn tail(text: &str, max: usize) -> &str {
        let len = text.chars().count();
        if len <= max {
            return text;
        }
        let skip = len - max;
        let start = text.char_indices().nth(skip).map_or(text.len(), |(at, _)| at);
        text.get(start..).unwrap_or("")
    }
}

/// A suffix with a fixed retained size and an unbounded logical length.
pub(super) struct BoundedSuffix<M> {
    parts: VecDeque<String>,
    retained: usize,
    total: usize,
    max: usize,
    metric: PhantomData<M>,
}

impl<M: SuffixMetric> BoundedSuffix<M> {
    pub(super) fn new(max: usize) -> Self {
        Self { parts: VecDeque::new(), retained: 0, total: 0, max, metric: PhantomData }
    }

    pub(super) fn push_str(&mut self, text: &str) {
        let len = M::len(text);
        self.total = self.total.saturating_add(len);
        if len == 0 || self.max == 0 {
            return;
        }
        if len > self.max {
            self.parts.clear();
            self.retained = 0;
            self.push_retained(M::tail(text, self.max));
            return;
        }
        self.push_retained(text);
        self.trim_front();
    }

    pub(super) fn push_retained(&mut self, text: &str) {
        let len = M::len(text);
        if len == 0 || self.max == 0 {
            return;
        }
        self.parts.push_back(text.to_owned());
        self.retained += len;
        self.trim_front();
    }

    pub(super) fn clear(&mut self) {
        self.parts.clear();
        self.retained = 0;
        self.total = 0;
    }

    pub(super) fn total(&self) -> usize {
        self.total
    }

    pub(super) fn add_total(&mut self, len: usize) {
        self.total = self.total.saturating_add(len);
    }

    pub(super) fn is_empty(&self) -> bool {
        self.total == 0
    }

    pub(super) fn tail_string(&self, max: usize) -> String {
        let mut text = String::new();
        for part in &self.parts {
            text.push_str(part);
        }
        M::tail(&text, max).to_owned()
    }

    pub(super) fn string(&self) -> String {
        self.tail_string(self.max)
    }

    fn trim_front(&mut self) {
        while self.retained > self.max {
            let excess = self.retained - self.max;
            let Some(part) = self.parts.pop_front() else {
                self.retained = 0;
                break;
            };
            let len = M::len(&part);
            if len <= excess {
                self.retained -= len;
            } else {
                let tail = M::tail(&part, len - excess).to_owned();
                self.retained -= excess;
                self.parts.push_front(tail);
            }
        }
    }
}

/// A bounded representation of `str::trim()` over streamed chunks.
pub(super) struct TrimmedText<M> {
    content: BoundedSuffix<M>,
    pending_whitespace: BoundedSuffix<M>,
    started: bool,
}

impl<M: SuffixMetric> TrimmedText<M> {
    pub(super) fn new(max: usize) -> Self {
        Self {
            content: BoundedSuffix::new(max),
            pending_whitespace: BoundedSuffix::new(max),
            started: false,
        }
    }

    pub(super) fn push_str(&mut self, text: &str) {
        let text = if self.started { text } else { text.trim_start() };
        let content = text.trim_end();
        if content.is_empty() {
            if self.started {
                self.pending_whitespace.push_str(text);
            }
            return;
        }
        self.started = true;
        if !self.pending_whitespace.is_empty() {
            let pending = self.pending_whitespace.string();
            let pending_total = self.pending_whitespace.total();
            self.content.push_str(&pending);
            self.content.add_total(pending_total.saturating_sub(M::len(&pending)));
            self.pending_whitespace.clear();
        }
        // Interior whitespace already belongs to the message. Borrow the whole
        // run, letting the suffix buffer copy only what can survive truncation.
        self.content.push_str(content);
        self.pending_whitespace.push_str(text.get(content.len()..).unwrap_or(""));
    }

    pub(super) fn finish(&mut self) {
        // Trailing whitespace is not part of `trim()`.
        self.pending_whitespace.clear();
    }

    pub(super) fn is_empty(&self) -> bool {
        !self.started
    }

    pub(super) fn total(&self) -> usize {
        self.content.total()
    }

    pub(super) fn string(&self) -> String {
        self.content.string()
    }
}

/// An id as an id set keeps it: 8 bytes, whatever the id's length. Two ids share one with odds
/// of 2^-64 a pair, far below anything a chat's id count reaches.
pub(crate) fn id_hash(id: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::hash::DefaultHasher::new();
    id.hash(&mut h);
    h.finish()
}

/// The ids [`RecentIds`] keeps when no bound is given: a chat's inbox's let-go and withdrawn
/// messages (`inbox.rs`).
pub(super) const RECENT_IDS: usize = 2048;

/// The newest `cap` ids seen, oldest forgotten first: a dedup window whose memory is a constant
/// (8 bytes an id, as a hash of it) however many ids go through it. What it forgot, a caller
/// reads from the log when it must: a resend asks the log whatever its age (`turns.rs`), so the
/// window only spares the log for a repeat that comes soon after (huge-blue, 2026-11-19: id sets
/// that kept every message ever sent to a chat).
pub(crate) struct RecentIds {
    cap: usize,
    order: VecDeque<u64>,
    set: std::collections::HashSet<u64>,
}

impl Default for RecentIds {
    fn default() -> Self {
        Self::new(RECENT_IDS)
    }
}

impl RecentIds {
    pub(crate) fn new(cap: usize) -> Self {
        Self { cap, order: VecDeque::new(), set: std::collections::HashSet::new() }
    }

    /// Keeps `id` as the newest; false when it was kept already.
    pub(crate) fn insert(&mut self, id: &str) -> bool {
        self.insert_hash(id_hash(id))
    }

    /// Keeps every id `other` keeps, oldest first, as the newest.
    pub(crate) fn absorb(&mut self, other: &RecentIds) {
        for key in &other.order {
            self.insert_hash(*key);
        }
    }

    fn insert_hash(&mut self, key: u64) -> bool {
        if !self.set.insert(key) {
            return false;
        }
        self.order.push_back(key);
        while self.order.len() > self.cap {
            if let Some(oldest) = self.order.pop_front() {
                self.set.remove(&oldest);
            }
        }
        true
    }

    pub(crate) fn contains(&self, id: &str) -> bool {
        self.set.contains(&id_hash(id))
    }

    pub(crate) fn len(&self) -> usize {
        self.order.len()
    }

    pub(crate) fn clear(&mut self) {
        self.order.clear();
        self.set.clear();
    }
}

#[cfg(test)]
mod recent_ids_tests {
    use super::RecentIds;

    #[test]
    fn recent_ids_keep_the_newest_window_and_forget_the_oldest() {
        let mut ids = RecentIds::new(3);
        for id in ["a", "b", "c", "d"] {
            assert!(ids.insert(id));
        }
        assert!(!ids.insert("d"), "kept already");
        assert_eq!(ids.len(), 3);
        assert!(!ids.contains("a"), "the oldest is forgotten");
        assert!(ids.contains("b") && ids.contains("d"));
    }
}
