//! The session pool's policy, apart from processes. Per cwd at most two
//! entries are wanted: the harness used before the current one (`LastUsed`)
//! and the one the pane hints at (`Hinted`). An entry no role wants is
//! evicted, an idle entry expires at its deadline, the whole pool stays
//! under an RSS cap (the oldest entry goes first), and an entry whose key
//! changed is discarded, never served. A remote-origin key is never pooled
//! or served (REMOTE-FLOOR v3). `T` is the pooled session (a live agent host
//! in the hub, a plain value in these tests).

use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::watch;

/// Where the session that would take an entry is requested from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Origin {
    Local,
    Remote,
}

/// Everything that shapes a pooled session. A session takes an entry only
/// when every field matches.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PoolKey {
    pub origin: Origin,
    pub cwd: PathBuf,
    pub harness: String,
    pub preset: Option<String>,
    /// The final argv: profile argv, preset args, system prompt file.
    pub args: Vec<String>,
    /// The preset's system prompt file sha256.
    pub system_prompt_sha256: Option<String>,
    /// Fingerprint of the resolved spawn env and the credential env and
    /// files (`auth.rs`). Never a secret itself.
    pub auth: String,
    /// Fingerprint of the logged-in account, where a login file names one.
    pub account: Option<String>,
}

impl PoolKey {
    /// Entries in one slot compete: a new key for a slot replaces the old one.
    fn same_slot(&self, other: &PoolKey) -> bool {
        self.origin == other.origin
            && self.cwd == other.cwd
            && self.harness == other.harness
            && self.preset == other.preset
    }
}

/// Why a key is wanted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The harness used in this cwd before the current one.
    LastUsed,
    /// The harness the pane is about to switch to (`_acpmux/prewarm`).
    Hinted,
}

enum Slot<T> {
    Empty,
    Warming(u64),
    Ready(T),
}

struct Entry<T> {
    key: PoolKey,
    last_used: bool,
    hinted: bool,
    slot: Slot<T>,
    deadline: Duration,
    /// When the entry became ready (eviction order under the RSS cap).
    ready_at: Duration,
    /// Bumped when a start ends (ready, failed, evicted); a take that found
    /// the key warming waits on it.
    settled: watch::Sender<u64>,
}

impl<T> Entry<T> {
    fn wanted(&self) -> bool {
        self.last_used || self.hinted
    }

    fn settle(&self) {
        self.settled.send_modify(|n| *n += 1);
    }
}

/// What `take` found.
pub enum Take<T> {
    /// A ready session for this key, removed from the pool.
    Ready(T),
    /// A start for this key is running: wait on the receiver, then take again.
    Warming(watch::Receiver<u64>),
    /// Nothing for this key (or a remote-origin key).
    Miss,
    /// The slot held a session under another key: end it, start cold.
    Discard(Option<T>),
}

/// What `want` asks the caller to do.
pub struct Wanted<T> {
    /// Start a session for the key under this generation.
    pub start: Option<u64>,
    /// Sessions nothing wants anymore, or held under an old key: end them.
    pub evicted: Vec<T>,
}

impl<T> Default for Wanted<T> {
    fn default() -> Self {
        Self { start: None, evicted: Vec::new() }
    }
}

pub struct Pool<T> {
    entries: Vec<Entry<T>>,
    idle: Duration,
    next_generation: u64,
}

/// How one entry looks, for status replies and tests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryView {
    pub key: PoolKey,
    pub last_used: bool,
    pub hinted: bool,
    pub state: &'static str,
    pub deadline: Duration,
}

impl<T> Pool<T> {
    pub fn new(idle: Duration) -> Self {
        Self { entries: Vec::new(), idle, next_generation: 1 }
    }

    pub fn set_idle(&mut self, idle: Duration) {
        self.idle = idle;
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Point `role` in `key.cwd` at `key` (moving it off any other key of
    /// that cwd) and push the key's idle deadline to `now + idle`. A remote
    /// key is refused: nothing starts.
    pub fn want(&mut self, role: Role, key: PoolKey, now: Duration) -> Wanted<T> {
        if key.origin == Origin::Remote {
            return Wanted::default();
        }
        let mut evicted = Vec::new();
        // A new key for an occupied slot: the old entry is discarded.
        let mut i = 0;
        while i < self.entries.len() {
            if self.entries[i].key != key && self.entries[i].key.same_slot(&key) {
                let e = self.entries.remove(i);
                e.settle();
                if let Slot::Ready(t) = e.slot {
                    evicted.push(t);
                }
            } else {
                i += 1;
            }
        }
        for e in self.entries.iter_mut().filter(|e| e.key.cwd == key.cwd) {
            match role {
                Role::LastUsed => e.last_used = e.key == key,
                Role::Hinted => e.hinted = e.key == key,
            }
        }
        let idle = self.idle;
        let start = match self.entries.iter_mut().find(|e| e.key == key) {
            Some(e) => {
                e.deadline = now + idle;
                if matches!(e.slot, Slot::Empty) {
                    let generation = self.next_generation;
                    self.next_generation += 1;
                    e.slot = Slot::Warming(generation);
                    Some(generation)
                } else {
                    None
                }
            }
            None => {
                let generation = self.next_generation;
                self.next_generation += 1;
                self.entries.push(Entry {
                    last_used: role == Role::LastUsed,
                    hinted: role == Role::Hinted,
                    key,
                    slot: Slot::Warming(generation),
                    deadline: now + idle,
                    ready_at: now,
                    settled: watch::channel(0).0,
                });
                Some(generation)
            }
        };
        evicted.extend(self.drop_unwanted());
        Wanted { start, evicted }
    }

    fn drop_unwanted(&mut self) -> Vec<T> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.entries.len() {
            if self.entries[i].wanted() {
                i += 1;
                continue;
            }
            let e = self.entries.remove(i);
            e.settle();
            if let Slot::Ready(t) = e.slot {
                out.push(t);
            }
        }
        out
    }

    /// A start finished at `now`. Returns the session back when the pool no
    /// longer wants it (the key was evicted, expired or restarted meanwhile).
    pub fn complete(&mut self, key: &PoolKey, generation: u64, t: T, now: Duration) -> Option<T> {
        let Some(e) = self.entries.iter_mut().find(|e| &e.key == key) else {
            return Some(t);
        };
        if !matches!(e.slot, Slot::Warming(g) if g == generation) {
            return Some(t);
        }
        e.slot = Slot::Ready(t);
        e.ready_at = now;
        e.settle();
        None
    }

    /// A start failed: the key stays wanted but holds nothing.
    pub fn failed(&mut self, key: &PoolKey, generation: u64) {
        if let Some(e) = self.entries.iter_mut().find(|e| &e.key == key)
            && matches!(e.slot, Slot::Warming(g) if g == generation)
        {
            e.slot = Slot::Empty;
            e.settle();
        }
    }

    /// Take the ready session for `key`. A session in the same slot under
    /// another key is removed and handed back for ending.
    pub fn take(&mut self, key: &PoolKey) -> Take<T> {
        if key.origin == Origin::Remote {
            return Take::Miss;
        }
        if let Some(e) = self.entries.iter_mut().find(|e| &e.key == key) {
            return match std::mem::replace(&mut e.slot, Slot::Empty) {
                Slot::Empty => Take::Miss,
                Slot::Warming(generation) => {
                    e.slot = Slot::Warming(generation);
                    Take::Warming(e.settled.subscribe())
                }
                Slot::Ready(t) => Take::Ready(t),
            };
        }
        if let Some(i) = self.entries.iter().position(|e| e.key.same_slot(key)) {
            let e = self.entries.remove(i);
            e.settle();
            return Take::Discard(match e.slot {
                Slot::Ready(t) => Some(t),
                _ => None,
            });
        }
        Take::Miss
    }

    /// A taken session that no session used comes back. It returns to its
    /// entry only while that entry still wants exactly this key and holds
    /// nothing; otherwise (the key changed, the entry was evicted, expired or
    /// refilled) it is handed back for ending.
    pub fn restore(&mut self, key: &PoolKey, t: T, now: Duration) -> Option<T> {
        match self.entries.iter_mut().find(|e| &e.key == key) {
            Some(e) if matches!(e.slot, Slot::Empty) => {
                e.slot = Slot::Ready(t);
                e.ready_at = now;
                e.settle();
                None
            }
            _ => Some(t),
        }
    }

    /// Remove every entry whose idle deadline passed; returns their sessions.
    pub fn expire(&mut self, now: Duration) -> Vec<T> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.entries.len() {
            if self.entries[i].deadline > now {
                i += 1;
                continue;
            }
            let e = self.entries.remove(i);
            e.settle();
            if let Slot::Ready(t) = e.slot {
                out.push(t);
            }
        }
        out
    }

    /// Keep the ready sessions' RSS (`rss`, bytes) at or under `cap`: the
    /// entry that became ready first is evicted first. Returns the evicted.
    pub fn enforce_cap(&mut self, cap: u64, rss: impl Fn(&T) -> u64) -> Vec<T> {
        let mut out = Vec::new();
        loop {
            let total: u64 = self
                .entries
                .iter()
                .filter_map(|e| match &e.slot {
                    Slot::Ready(t) => Some(rss(t)),
                    _ => None,
                })
                .sum();
            if total <= cap {
                return out;
            }
            let Some(i) = self
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| matches!(e.slot, Slot::Ready(_)))
                .min_by_key(|(_, e)| e.ready_at)
                .map(|(i, _)| i)
            else {
                return out;
            };
            let e = self.entries.remove(i);
            e.settle();
            if let Slot::Ready(t) = e.slot {
                out.push(t);
            }
        }
    }

    /// Mutable access to every ready session (RSS updates).
    pub fn ready_mut(&mut self) -> impl Iterator<Item = &mut T> {
        self.entries.iter_mut().filter_map(|e| match &mut e.slot {
            Slot::Ready(t) => Some(t),
            _ => None,
        })
    }

    /// The earliest idle deadline, if anything is in the pool.
    pub fn next_deadline(&self) -> Option<Duration> {
        self.entries.iter().map(|e| e.deadline).min()
    }

    /// Wait handle for a key that is warming now.
    pub fn watch_warming(&self, key: &PoolKey) -> Option<watch::Receiver<u64>> {
        self.entries
            .iter()
            .find(|e| &e.key == key && matches!(e.slot, Slot::Warming(_)))
            .map(|e| e.settled.subscribe())
    }

    /// Empty the pool (config reload, shutdown); returns every ready session.
    pub fn clear(&mut self) -> Vec<T> {
        let mut out = Vec::new();
        for e in self.entries.drain(..) {
            e.settle();
            if let Slot::Ready(t) = e.slot {
                out.push(t);
            }
        }
        out
    }

    pub fn view(&self) -> Vec<EntryView> {
        self.entries
            .iter()
            .map(|e| EntryView {
                key: e.key.clone(),
                last_used: e.last_used,
                hinted: e.hinted,
                state: match e.slot {
                    Slot::Empty => "empty",
                    Slot::Warming(_) => "warming",
                    Slot::Ready(_) => "ready",
                },
                deadline: e.deadline,
            })
            .collect()
    }
}
