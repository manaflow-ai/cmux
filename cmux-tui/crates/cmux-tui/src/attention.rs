//! The attention queue: which tabs need the person, in the order one key
//! (`next-attention`, `Ctrl-b a`) and `cmux attention next` visit them.
//!
//! Four tiers, each oldest first:
//!
//! 0. The person must act: an agent's `cmux attention request` mark, an agent
//!    the roster shows `blocked` (approval, question, plan review), or a
//!    program that reports OSC 7501 `blocked`.
//! 1. An unread `error` or `warning` notification.
//! 2. An agent's finished turn nobody has viewed (`done`).
//! 3. Any other unread notification (OSC 9/777/99, a bell).
//!
//! A tab with several reasons takes its strongest. "Next" is the entry after
//! the focused tab, wrapping to the first, so repeated presses cycle through
//! blocked agents (viewing does not clear a block) while an unread tab leaves
//! the queue once it is seen and the next press starts again at the top.
//!
//! Pure: the TUI feeds it its tree and agent roster (`app/attention_jump.rs`),
//! the CLI a daemon `session.snapshot` (`cli/attention.rs`).

/// Why a tab is in the queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum AttentionKind {
    /// `cmux attention request`: an agent asked the person to act here.
    Requested,
    /// The tab's agent waits on the person (approval, question, review).
    Blocked,
    /// An agent finished a turn nobody has viewed (`done`).
    Done,
    /// An unread notification.
    Unread,
}

impl AttentionKind {
    /// The wire word of `cmux attention next|list` (`kind`).
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::Blocked => "blocked",
            Self::Done => "done",
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
    /// 0 (the person must act), 1 (an unread error or warning), 2 (a
    /// finished agent turn), 3 (unread).
    pub(crate) fn tier(&self) -> u8 {
        match (self.kind, self.level) {
            (AttentionKind::Requested | AttentionKind::Blocked, _) => 0,
            (
                AttentionKind::Unread | AttentionKind::Done,
                AttentionLevel::Error | AttentionLevel::Warning,
            ) => 1,
            (AttentionKind::Done, AttentionLevel::Info) => 2,
            (AttentionKind::Unread, AttentionLevel::Info) => 3,
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
mod tests;
