//! The attention queue: which tabs need the person, in the order one key
//! (`next-attention`, `Ctrl-b a`) and `cmux attention next` visit them.
//!
//! Three tiers, each oldest first:
//!
//! 0. The person must act: an agent the roster shows `blocked` (approval,
//!    question, plan review).
//! 1. An unread `error` or `warning` notification.
//! 2. Any other unread notification (a finished turn, `cmux notify`).
//!
//! A tab with several reasons takes its strongest. "Next" is the entry after
//! the focused tab, wrapping to the first, so repeated presses cycle through
//! blocked agents (viewing does not clear a block) and unread tabs until
//! their notifications are cleared.
//!
//! Pure: the TUI feeds it its tree and agent roster (`app/attention_jump.rs`),
//! the CLI a daemon `session.snapshot` (`cli/attention.rs`).

/// Why a tab is in the queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum AttentionKind {
    /// The tab's agent waits on the person (approval, question, review).
    Blocked,
    /// An unread notification.
    Unread,
}

impl AttentionKind {
    /// The wire word of `cmux attention next|list` (`kind`).
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Blocked => "blocked",
            Self::Unread => "unread",
        }
    }
}

/// The severity of an unread notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum AttentionLevel {
    Info,
    Warning,
    Error,
}

impl AttentionLevel {
    /// `warning` and `error` keep their meaning; any other word is info.
    pub(crate) fn parse(level: &str) -> Self {
        match level {
            "error" => Self::Error,
            "warning" => Self::Warning,
            _ => Self::Info,
        }
    }

    /// The wire word of `cmux attention next|list` (`level`).
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}

/// One reason a tab needs the person. `key` names the tab (a TUI surface id,
/// a CLI `tab_…` id); `age` orders entries of one tier, smaller first (Unix ms,
/// or the daemon's notification number for unread entries in the TUI);
/// `position` is the tab's place in the tree and breaks ties.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AttentionCandidate<K> {
    pub key: K,
    pub kind: AttentionKind,
    pub level: AttentionLevel,
    pub age: u64,
    pub position: usize,
}

impl<K> AttentionCandidate<K> {
    /// 0 (the person must act), 1 (an unread error or warning), 2 (unread).
    pub(crate) fn tier(&self) -> u8 {
        match (self.kind, self.level) {
            (AttentionKind::Blocked, _) => 0,
            (AttentionKind::Unread, AttentionLevel::Error | AttentionLevel::Warning) => 1,
            (AttentionKind::Unread, AttentionLevel::Info) => 2,
        }
    }

    fn sort_key(&self) -> (u8, u64, usize, AttentionKind) {
        (self.tier(), self.age, self.position, self.kind)
    }
}

/// The queue: one entry per tab (its strongest reason), in visiting order.
pub(crate) fn attention_queue<K: Eq + std::hash::Hash + Clone>(
    candidates: impl IntoIterator<Item = AttentionCandidate<K>>,
) -> Vec<AttentionCandidate<K>> {
    let mut best: std::collections::HashMap<K, AttentionCandidate<K>> =
        std::collections::HashMap::new();
    for candidate in candidates {
        match best.get(&candidate.key) {
            Some(existing) if existing.sort_key() <= candidate.sort_key() => {}
            _ => {
                best.insert(candidate.key.clone(), candidate);
            }
        }
    }
    let mut queue: Vec<_> = best.into_values().collect();
    queue.sort_by_key(AttentionCandidate::sort_key);
    queue
}

/// The entry a jump goes to: the one after `current` when the focused tab is
/// in the queue (wrapping), else the first. `None` when nothing needs the
/// person.
pub(crate) fn next_attention<'a, K: Eq>(
    queue: &'a [AttentionCandidate<K>],
    current: Option<&K>,
) -> Option<&'a AttentionCandidate<K>> {
    let index = current
        .and_then(|current| queue.iter().position(|entry| &entry.key == current))
        .and_then(|index| index.saturating_add(1).checked_rem(queue.len()))
        .unwrap_or(0);
    queue.get(index)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(
        key: u64,
        kind: AttentionKind,
        level: AttentionLevel,
        age: u64,
    ) -> AttentionCandidate<u64> {
        AttentionCandidate { key, kind, level, age, position: key as usize }
    }

    fn keys(queue: &[AttentionCandidate<u64>]) -> Vec<u64> {
        queue.iter().map(|entry| entry.key).collect()
    }

    #[test]
    fn attention_queue_puts_blocked_first_then_errors_then_unread_each_oldest_first() {
        let queue = attention_queue([
            candidate(1, AttentionKind::Unread, AttentionLevel::Info, 5),
            candidate(2, AttentionKind::Blocked, AttentionLevel::Warning, 900),
            candidate(3, AttentionKind::Unread, AttentionLevel::Error, 7),
            candidate(4, AttentionKind::Blocked, AttentionLevel::Warning, 100),
            candidate(5, AttentionKind::Unread, AttentionLevel::Info, 2),
            candidate(6, AttentionKind::Unread, AttentionLevel::Warning, 6),
        ]);
        assert_eq!(keys(&queue), vec![4, 2, 6, 3, 5, 1]);
    }

    #[test]
    fn attention_queue_keeps_one_entry_per_tab_with_its_strongest_reason() {
        let queue = attention_queue([
            candidate(1, AttentionKind::Unread, AttentionLevel::Info, 1),
            candidate(1, AttentionKind::Blocked, AttentionLevel::Warning, 50),
            candidate(2, AttentionKind::Unread, AttentionLevel::Info, 3),
        ]);
        assert_eq!(keys(&queue), vec![1, 2]);
        assert_eq!(queue[0].kind, AttentionKind::Blocked);
    }

    #[test]
    fn attention_queue_breaks_age_ties_by_tree_position() {
        let mut later = candidate(9, AttentionKind::Blocked, AttentionLevel::Warning, 10);
        later.position = 0;
        let earlier = candidate(3, AttentionKind::Blocked, AttentionLevel::Warning, 10);
        assert_eq!(keys(&attention_queue([earlier, later])), vec![9, 3]);
    }

    #[test]
    fn next_attention_cycles_after_the_focused_tab_and_wraps() {
        let queue = attention_queue([
            candidate(1, AttentionKind::Blocked, AttentionLevel::Warning, 1),
            candidate(2, AttentionKind::Blocked, AttentionLevel::Warning, 2),
            candidate(3, AttentionKind::Unread, AttentionLevel::Info, 3),
        ]);
        assert_eq!(next_attention(&queue, None).map(|entry| entry.key), Some(1));
        assert_eq!(next_attention(&queue, Some(&7)).map(|entry| entry.key), Some(1));
        assert_eq!(next_attention(&queue, Some(&1)).map(|entry| entry.key), Some(2));
        assert_eq!(next_attention(&queue, Some(&2)).map(|entry| entry.key), Some(3));
        assert_eq!(next_attention(&queue, Some(&3)).map(|entry| entry.key), Some(1));
    }

    #[test]
    fn next_attention_is_none_for_an_empty_queue_and_stays_on_a_single_entry() {
        let empty: Vec<AttentionCandidate<u64>> = Vec::new();
        assert!(next_attention(&empty, Some(&1)).is_none());
        let single =
            attention_queue([candidate(4, AttentionKind::Blocked, AttentionLevel::Info, 1)]);
        assert_eq!(next_attention(&single, Some(&4)).map(|entry| entry.key), Some(4));
    }
}
