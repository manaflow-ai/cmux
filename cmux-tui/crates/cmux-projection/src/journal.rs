//! What changed in a projection since a cursor (RFD 0007, prior-art move 2: a Watchman/Eden-style
//! changed-since journal with an explicit overflow detector).
//!
//! The manifest's paths never change while it is mounted, so every change a tool can see goes
//! through the overlay, which notes its path here ([`Journal::note`]). A caller keeps the
//! [`Cursor`] of its last answer and asks [`Journal::since`] for the paths changed after it: the
//! answer costs the changes, not the tree, and `git status` through the fsmonitor hook
//! ([`Since::fsmonitor`]) stats only those.
//!
//! The journal is bounded: it keeps at most [`Journal::capacity`] distinct paths, each at the
//! sequence of its latest change. When one more would not fit, the oldest goes and the journal
//! remembers how far it has forgotten. A cursor from before that point, from another daemon (a
//! restart starts a new epoch, as Watchman's fresh instance does) or from no journal at all gets
//! [`Since::Overflow`] with its reason, never a short list: the caller must scan the whole tree
//! once, as it would without a journal, and carry on from the cursor in the answer.

use std::collections::hash_map::RandomState;
use std::collections::{BTreeMap, HashMap};
use std::hash::{BuildHasher as _, Hasher as _};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// The most distinct paths a projection's journal keeps by default. One entry is a path and two
/// integers, so a full journal is a few MiB; a burst wider than this (a checkout of another
/// branch) is an overflow, which costs one full scan.
pub const DEFAULT_CAPACITY: usize = 65_536;

/// A point in one journal: the journal's epoch and the last change seen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub epoch: u64,
    pub seq: u64,
}

impl Cursor {
    /// The cursor `text` names (`c:<epoch, hex>:<seq>`, as [`Cursor`]'s `Display` writes it).
    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        let rest = text.trim().strip_prefix("c:")?;
        let (epoch, seq) = rest.split_once(':')?;
        Some(Self { epoch: u64::from_str_radix(epoch, 16).ok()?, seq: seq.parse().ok()? })
    }
}

impl std::fmt::Display for Cursor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "c:{:016x}:{}", self.epoch, self.seq)
    }
}

/// Why a cursor cannot be answered with a list of paths.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Overflow {
    /// The cursor is from another journal (a daemon before a restart, another projection), or is
    /// not a cursor at all.
    FreshInstance,
    /// The journal has let go of changes made after the cursor (more distinct paths changed
    /// since than it keeps).
    Truncated,
    /// The cursor is ahead of every change this journal has numbered.
    Future,
}

impl Overflow {
    /// The reason as one word, for logs and answers.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FreshInstance => "fresh_instance",
            Self::Truncated => "truncated",
            Self::Future => "future",
        }
    }
}

/// The answer to [`Journal::since`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Since {
    /// Every path changed after the cursor, oldest change first, each once. A path ending in `/`
    /// is a folder whose whole subtree moved (a rename).
    Changes { paths: Vec<String>, cursor: Cursor },
    /// The journal cannot say: scan everything, then ask again from `cursor`.
    Overflow { why: Overflow, cursor: Cursor },
}

impl Since {
    /// The cursor to ask from next time.
    #[must_use]
    pub fn cursor(&self) -> Cursor {
        match self {
            Self::Changes { cursor, .. } | Self::Overflow { cursor, .. } => *cursor,
        }
    }

    /// The answer as git's fsmonitor hook (protocol 2) prints it: the new token, a NUL, then each
    /// path ended by a NUL; an overflow is the one path `/`, which makes git check everything.
    #[must_use]
    pub fn fsmonitor(&self) -> Vec<u8> {
        let mut out = self.cursor().to_string().into_bytes();
        out.push(0);
        match self {
            Self::Changes { paths, .. } => {
                for path in paths {
                    out.extend_from_slice(path.as_bytes());
                    out.push(0);
                }
            }
            Self::Overflow { .. } => out.extend_from_slice(b"/\0"),
        }
        out
    }
}

#[derive(Default)]
struct Inner {
    /// The sequence of the latest change.
    seq: u64,
    /// The highest sequence let go: a cursor below it may have missed that change.
    forgotten: u64,
    /// Each kept path's latest sequence, and the paths by sequence.
    latest: HashMap<String, u64>,
    order: BTreeMap<u64, String>,
}

/// A projection's change journal.
pub struct Journal {
    epoch: u64,
    capacity: usize,
    inner: Mutex<Inner>,
}

impl Default for Journal {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

impl Journal {
    /// An empty journal keeping at most `capacity` distinct paths (at least one), in a new epoch.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u32(std::process::id());
        if let Ok(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
            hasher.write_u128(now.as_nanos());
        }
        Self { epoch: hasher.finish(), capacity: capacity.max(1), inner: Mutex::default() }
    }

    /// The most distinct paths it keeps.
    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The cursor of now: an answer from it lists only changes after this call.
    #[must_use]
    pub fn cursor(&self) -> Cursor {
        Cursor { epoch: self.epoch, seq: self.lock().seq }
    }

    /// Notes that `path` changed (made, written, deleted, renamed, or its attributes set).
    pub fn note(&self, path: &str) {
        let mut inner = self.lock();
        inner.seq += 1;
        let seq = inner.seq;
        if let Some(at) = inner.latest.get_mut(path) {
            let before = std::mem::replace(at, seq);
            if let Some(name) = inner.order.remove(&before) {
                inner.order.insert(seq, name);
            }
            return;
        }
        if inner.latest.len() >= self.capacity
            && let Some((gone, name)) = inner.order.pop_first()
        {
            inner.latest.remove(&name);
            inner.forgotten = inner.forgotten.max(gone);
        }
        inner.latest.insert(path.to_owned(), seq);
        inner.order.insert(seq, path.to_owned());
    }

    /// Notes that folder `path` and everything below it changed (it was renamed).
    pub fn note_tree(&self, path: &str) {
        self.note(&format!("{path}/"));
    }

    /// The paths changed after `cursor`, or why the journal cannot list them.
    #[must_use]
    pub fn since(&self, cursor: Option<Cursor>) -> Since {
        let inner = self.lock();
        let now = Cursor { epoch: self.epoch, seq: inner.seq };
        let why = match cursor {
            None => Some(Overflow::FreshInstance),
            Some(cursor) if cursor.epoch != self.epoch => Some(Overflow::FreshInstance),
            Some(cursor) if cursor.seq > inner.seq => Some(Overflow::Future),
            Some(cursor) if cursor.seq < inner.forgotten => Some(Overflow::Truncated),
            Some(_) => None,
        };
        if let Some(why) = why {
            return Since::Overflow { why, cursor: now };
        }
        let from = cursor.map_or(0, |cursor| cursor.seq);
        let paths = inner.order.range(from + 1..).map(|(_, path)| path.clone()).collect();
        Since::Changes { paths, cursor: now }
    }

    /// [`Self::since`] for a cursor as text (a token git's hook was handed back).
    #[must_use]
    pub fn since_text(&self, cursor: &str) -> Since {
        self.since(Cursor::parse(cursor))
    }
}

#[cfg(test)]
#[path = "journal_tests.rs"]
mod tests;
