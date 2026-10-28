//! VT shard choice by trust class (p01-process task 142).
//!
//! Chrome never puts two sites in one renderer when one could read the
//! other's data: a process is locked to one site
//! (`content/browser/process_lock.h`), `RenderProcessHostImpl::IsSuitableHost`
//! refuses a process whose lock differs, and past the process limit
//! (`RenderProcessHostImpl::ShouldTryToUseExistingProcessHost`) Chrome reuses
//! a suitable process, or creates one over the limit when none is suitable
//! (`content/browser/renderer_host/render_process_host_impl.cc`).
//!
//! cmux does the same for VT workers. A terminal's [`TrustClass`] is its
//! site: a worker (in pool mode, a pool shard) is locked to one class and only
//! ever maps rings of that class. A class with no worker spills one worker
//! past the cap N, so a session has at most `N + classes - 1` workers.
//!
//! Unlike a renderer, a terminal can change site: a local shell runs `ssh`.
//! A site only ever gets less trusted (`ssh` exiting does not make the bytes
//! it printed local), and a move to a less trusted worker takes a fresh ring
//! segment, so no worker ever maps a segment that holds bytes of another
//! class. A segment's prologue is that segment's own: the fresh segment of a
//! class change starts from a blank screen.
//!
//! Workers are shared by load: under the budget a new terminal gets a new
//! worker; at the budget it goes to the least loaded worker of its class,
//! unless its class is so much more loaded per worker than another that
//! retiring one of the other class's workers (its rings move to that class's
//! other workers) and spawning one for this class lowers the busiest
//! worker's load by a quarter. The new worker then takes rings from its
//! class's busiest workers until loads within the class differ by at most
//! one. So the order the first terminals open in does not fix the session's
//! parse parallelism.
//! Chrome never moves a frame between processes to balance them; cmux can,
//! because a worker's screens rebuild from their segments' prologues, and its
//! terminals live as long as the session.
//!
//! [`ShardPlanner`] is the placement state of the VT worker broker
//! (`vt_worker_runtime`, keyed by `VtTerminalKey`) and of the VT pool (keyed
//! by its terminal token), owned by that one thread (no lock). Each call
//! returns the [`ShardAction`]s the broker applies in order. A ring that
//! moves is unmapped from its old worker before the new one maps it, so no
//! ring is ever mapped in two workers. [`AppliedMappings`] is the broker's
//! record of what each worker really maps; `debug.vt` lists that, not the
//! plan.

mod applied;

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::hash::Hash;
use std::num::NonZeroUsize;

use serde::Serialize;

use crate::SurfaceId;

pub use applied::{AppliedMappings, Divergence, MappedSegment, MappingError, WorkerMappings};

/// Where a terminal's bytes come from, as far as worker sharing goes. Bytes
/// of different classes are never parsed in one worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustClass {
    /// A shell on this Mac.
    Local,
    /// Output of another machine: SSH, a remote daemon, a cloud VM.
    Remote,
    /// Content an agent fetched and printed (web pages, API answers).
    AgentFetched,
}

/// The machine a terminal's program runs on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalHost {
    Local,
    Ssh,
    RemoteDaemon,
    Cloud,
}

impl TrustClass {
    /// The class of a terminal's current source. Agent-fetched content wins
    /// over the host: a terminal with several sources takes the least
    /// trusted one, so it never shares a worker with more trusted bytes.
    pub fn classify(host: TerminalHost, agent_fetched: bool) -> Self {
        if agent_fetched {
            return Self::AgentFetched;
        }
        match host {
            TerminalHost::Local => Self::Local,
            TerminalHost::Ssh | TerminalHost::RemoteDaemon | TerminalHost::Cloud => Self::Remote,
        }
    }

    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Remote => "remote",
            Self::AgentFetched => "agent_fetched",
        }
    }

    /// Higher is less trusted.
    const fn distrust(self) -> u8 {
        match self {
            Self::Local => 0,
            Self::Remote => 1,
            Self::AgentFetched => 2,
        }
    }

    pub const fn is_less_trusted_than(self, other: Self) -> bool {
        self.distrust() > other.distrust()
    }

    /// The class of bytes from both sources.
    pub const fn least_trusted(self, other: Self) -> Self {
        if other.is_less_trusted_than(self) { other } else { self }
    }
}

/// One VT worker (pool shard in thread mode). A restarted worker keeps its
/// slot and its class lock.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct WorkerSlot(pub u64);

/// The key a placement owner names its terminals by.
pub trait TerminalKey: Copy + Ord + Hash + fmt::Debug {}

impl<K: Copy + Ord + Hash + fmt::Debug> TerminalKey for K {}

/// One holder ring of a terminal. A holder restart or a class change gives a
/// terminal a fresh ring, so a terminal maps one segment at a time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct RingSegment<K = SurfaceId> {
    pub terminal: K,
    pub segment: u64,
}

/// What the broker does, in the order returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShardAction<K = SurfaceId> {
    /// Start a worker in `slot`, locked to `class`.
    Spawn { slot: WorkerSlot, class: TrustClass },
    /// Pass the ring's fd to the worker, which maps it read-only.
    Map { slot: WorkerSlot, ring: RingSegment<K> },
    /// Tell the worker to unmap the ring and drop the terminal's screen.
    Unmap { slot: WorkerSlot, ring: RingSegment<K> },
    /// Stop the worker; it maps no ring.
    Retire { slot: WorkerSlot },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShardError<K = SurfaceId> {
    AlreadyPlaced(K),
    UnknownTerminal(K),
    UnknownWorker(WorkerSlot),
    /// The terminal's class got less trusted, and its current segment holds
    /// bytes of the more trusted class: the holder must open a fresh one.
    FreshRingRequired(K),
    /// The "fresh" segment is the one the terminal already maps.
    SegmentReused {
        terminal: K,
        segment: u64,
    },
}

impl<K: fmt::Debug> fmt::Display for ShardError<K> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyPlaced(id) => write!(f, "terminal {id:?} already has a VT worker"),
            Self::UnknownTerminal(id) => write!(f, "terminal {id:?} has no VT worker"),
            Self::UnknownWorker(slot) => write!(f, "no VT worker in slot {}", slot.0),
            Self::FreshRingRequired(id) => {
                write!(f, "terminal {id:?} changes trust class and needs a fresh ring")
            }
            Self::SegmentReused { terminal, segment } => {
                write!(f, "terminal {terminal:?} already maps segment {segment}")
            }
        }
    }
}

impl<K: fmt::Debug> std::error::Error for ShardError<K> {}

struct Worker<K> {
    class: TrustClass,
    rings: BTreeSet<RingSegment<K>>,
}

#[derive(Clone, Copy)]
struct Placement {
    slot: WorkerSlot,
    class: TrustClass,
    segment: u64,
}

/// Terminals per worker, compared exactly.
#[derive(Clone, Copy)]
struct Load {
    terminals: usize,
    workers: usize,
}

impl Load {
    fn cmp(self, other: Self) -> Ordering {
        (self.terminals * other.workers).cmp(&(other.terminals * self.workers))
    }

    fn max(self, other: Self) -> Self {
        if self.cmp(other) == Ordering::Less { other } else { self }
    }

    /// `self` is at most three quarters of `before`.
    fn relieves(self, before: Self) -> bool {
        4 * self.terminals * before.workers <= 3 * before.terminals * self.workers
    }
}

/// Which worker parses which terminal, by trust class.
pub struct ShardPlanner<K = SurfaceId> {
    cap: NonZeroUsize,
    workers: BTreeMap<WorkerSlot, Worker<K>>,
    terminals: HashMap<K, Placement>,
    next_slot: u64,
}

impl<K: TerminalKey> ShardPlanner<K> {
    /// `cap` is the worker count N the broker aims for; a class with no
    /// worker spills past it.
    pub fn new(cap: NonZeroUsize) -> Self {
        Self { cap, workers: BTreeMap::new(), terminals: HashMap::new(), next_slot: 0 }
    }

    /// Give a new terminal a worker of its class.
    pub fn place(
        &mut self,
        terminal: K,
        class: TrustClass,
        segment: u64,
    ) -> Result<Vec<ShardAction<K>>, ShardError<K>> {
        if self.terminals.contains_key(&terminal) {
            return Err(ShardError::AlreadyPlaced(terminal));
        }
        let mut actions = Vec::with_capacity(2);
        self.place_into(terminal, class, segment, &mut actions);
        Ok(actions)
    }

    /// Whether [`Self::reclassify`] to `source` moves the terminal, so the
    /// broker must open a fresh holder segment first.
    pub fn needs_fresh_ring(&self, terminal: K, source: TrustClass) -> Result<bool, ShardError<K>> {
        let placement =
            self.terminals.get(&terminal).ok_or(ShardError::UnknownTerminal(terminal))?;
        Ok(source.is_less_trusted_than(placement.class))
    }

    /// The terminal's source changed (a local shell ran `ssh`, an agent
    /// started printing fetched content). A more trusted source changes
    /// nothing: the terminal keeps its class and worker. A less trusted one
    /// moves the terminal to a worker of that class with `fresh_segment`;
    /// the old worker unmaps the old segment first.
    pub fn reclassify(
        &mut self,
        terminal: K,
        source: TrustClass,
        fresh_segment: Option<u64>,
    ) -> Result<Vec<ShardAction<K>>, ShardError<K>> {
        let placement =
            *self.terminals.get(&terminal).ok_or(ShardError::UnknownTerminal(terminal))?;
        if !source.is_less_trusted_than(placement.class) {
            return Ok(Vec::new());
        }
        let segment = fresh_segment.ok_or(ShardError::FreshRingRequired(terminal))?;
        if segment == placement.segment {
            return Err(ShardError::SegmentReused { terminal, segment });
        }
        let mut actions = Vec::with_capacity(4);
        self.unplace(terminal, placement, &mut actions);
        self.place_into(terminal, source, segment, &mut actions);
        Ok(actions)
    }

    /// The terminal got a fresh holder ring of its class: its worker swaps
    /// mappings.
    pub fn replace_segment(
        &mut self,
        terminal: K,
        segment: u64,
    ) -> Result<Vec<ShardAction<K>>, ShardError<K>> {
        let placement =
            self.terminals.get_mut(&terminal).ok_or(ShardError::UnknownTerminal(terminal))?;
        if placement.segment == segment {
            return Ok(Vec::new());
        }
        let old = RingSegment { terminal, segment: placement.segment };
        let new = RingSegment { terminal, segment };
        let slot = placement.slot;
        placement.segment = segment;
        if let Some(worker) = self.workers.get_mut(&slot) {
            worker.rings.remove(&old);
            worker.rings.insert(new);
        }
        Ok(vec![ShardAction::Unmap { slot, ring: old }, ShardAction::Map { slot, ring: new }])
    }

    /// The terminal ended: unmap its ring, retire its worker if now empty.
    pub fn remove(&mut self, terminal: K) -> Result<Vec<ShardAction<K>>, ShardError<K>> {
        let placement =
            self.terminals.get(&terminal).copied().ok_or(ShardError::UnknownTerminal(terminal))?;
        let mut actions = Vec::with_capacity(2);
        self.unplace(terminal, placement, &mut actions);
        Ok(actions)
    }

    /// The worker in `slot` died, and the kernel unmapped its rings. Its
    /// replacement keeps the slot and the class lock and maps the same
    /// rings (the broker reseeds each from its segment's prologue).
    pub fn worker_lost(&mut self, slot: WorkerSlot) -> Result<Vec<ShardAction<K>>, ShardError<K>> {
        let worker = self.workers.get(&slot).ok_or(ShardError::UnknownWorker(slot))?;
        let mut actions = Vec::with_capacity(worker.rings.len() + 1);
        actions.push(ShardAction::Spawn { slot, class: worker.class });
        actions.extend(worker.rings.iter().map(|&ring| ShardAction::Map { slot, ring }));
        Ok(actions)
    }

    pub fn slot_of(&self, terminal: K) -> Option<WorkerSlot> {
        self.terminals.get(&terminal).map(|placement| placement.slot)
    }

    pub fn class_of(&self, terminal: K) -> Option<TrustClass> {
        self.terminals.get(&terminal).map(|placement| placement.class)
    }

    pub fn worker_count(&self) -> usize {
        self.workers.len()
    }

    /// The terminal count of each live worker of `class`, by slot.
    pub fn loads(&self, class: TrustClass) -> Vec<usize> {
        self.workers.values().filter(|w| w.class == class).map(|w| w.rings.len()).collect()
    }

    fn place_into(
        &mut self,
        terminal: K,
        class: TrustClass,
        segment: u64,
        actions: &mut Vec<ShardAction<K>>,
    ) {
        let (slot, took_worker) = match self.suitable_worker(class) {
            None => (self.spawn(class, actions), false),
            Some(_) if self.workers.len() < self.budget() => (self.spawn(class, actions), false),
            Some(least) => match self.donor_for(class) {
                Some(donor) => {
                    self.consolidate(donor, actions);
                    (self.spawn(class, actions), true)
                }
                None => (least, false),
            },
        };
        let ring = RingSegment { terminal, segment };
        if let Some(worker) = self.workers.get_mut(&slot) {
            worker.rings.insert(ring);
        }
        self.terminals.insert(terminal, Placement { slot, class, segment });
        actions.push(ShardAction::Map { slot, ring });
        if took_worker {
            self.even_out(class, slot, actions);
        }
    }

    fn unplace(&mut self, terminal: K, placement: Placement, actions: &mut Vec<ShardAction<K>>) {
        self.terminals.remove(&terminal);
        let ring = RingSegment { terminal, segment: placement.segment };
        let Some(worker) = self.workers.get_mut(&placement.slot) else {
            return;
        };
        worker.rings.remove(&ring);
        actions.push(ShardAction::Unmap { slot: placement.slot, ring });
        if worker.rings.is_empty() {
            self.workers.remove(&placement.slot);
            actions.push(ShardAction::Retire { slot: placement.slot });
        }
    }

    /// The cap plus one spill worker per class past the first. Only called
    /// once the placed class has a worker, so it counts as present.
    fn budget(&self) -> usize {
        let classes: BTreeSet<TrustClass> = self.workers.values().map(|w| w.class).collect();
        self.cap.get() + classes.len().saturating_sub(1)
    }

    fn class_load(&self, class: TrustClass) -> Load {
        self.workers.values().filter(|w| w.class == class).fold(
            Load { terminals: 0, workers: 0 },
            |load, w| Load { terminals: load.terminals + w.rings.len(), workers: load.workers + 1 },
        )
    }

    /// The class that should give `class` one of its workers: moving a
    /// worker from it to `class` (with the terminal being placed) relieves
    /// the busier of the two by a quarter. The best such class, if any.
    fn donor_for(&self, class: TrustClass) -> Option<TrustClass> {
        let mut own = self.class_load(class);
        own.terminals += 1;
        let classes: BTreeSet<TrustClass> = self.workers.values().map(|w| w.class).collect();
        classes
            .into_iter()
            .filter(|&other| other != class)
            .filter_map(|other| {
                let theirs = self.class_load(other);
                if theirs.workers < 2 {
                    return None;
                }
                let before = own.max(theirs);
                let after = Load { terminals: own.terminals, workers: own.workers + 1 }
                    .max(Load { terminals: theirs.terminals, workers: theirs.workers - 1 });
                after.relieves(before).then_some((other, after))
            })
            .min_by(|(_, a), (_, b)| a.cmp(*b))
            .map(|(other, _)| other)
    }

    /// Retire `class`'s least loaded worker; each of its rings moves to the
    /// least loaded remaining worker of the same class.
    fn consolidate(&mut self, class: TrustClass, actions: &mut Vec<ShardAction<K>>) {
        let Some(from) = self.suitable_worker(class) else {
            return;
        };
        let Some(worker) = self.workers.remove(&from) else {
            return;
        };
        for ring in worker.rings {
            actions.push(ShardAction::Unmap { slot: from, ring });
            if let Some(to) = self.suitable_worker(class) {
                self.map_moved(ring, to, actions);
            }
        }
        actions.push(ShardAction::Retire { slot: from });
    }

    /// `to` is a new worker of `class`: move rings into it from the class's
    /// busiest workers until no worker of the class carries two more than it.
    fn even_out(&mut self, class: TrustClass, to: WorkerSlot, actions: &mut Vec<ShardAction<K>>) {
        loop {
            let Some(target) = self.workers.get(&to).map(|w| w.rings.len()) else {
                return;
            };
            let busiest = self
                .workers
                .iter()
                .filter(|&(&slot, worker)| slot != to && worker.class == class)
                .max_by_key(|&(&slot, worker)| (worker.rings.len(), std::cmp::Reverse(slot)))
                .map(|(&slot, worker)| (slot, worker.rings.len()));
            let Some((from, load)) = busiest else {
                return;
            };
            if load <= target + 1 {
                return;
            }
            let Some(ring) = self.workers.get_mut(&from).and_then(|w| w.rings.pop_last()) else {
                return;
            };
            actions.push(ShardAction::Unmap { slot: from, ring });
            self.map_moved(ring, to, actions);
        }
    }

    /// Map a ring its old worker already unmapped into `to`.
    fn map_moved(
        &mut self,
        ring: RingSegment<K>,
        to: WorkerSlot,
        actions: &mut Vec<ShardAction<K>>,
    ) {
        if let Some(target) = self.workers.get_mut(&to) {
            target.rings.insert(ring);
        }
        if let Some(placement) = self.terminals.get_mut(&ring.terminal) {
            placement.slot = to;
        }
        actions.push(ShardAction::Map { slot: to, ring });
    }

    fn spawn(&mut self, class: TrustClass, actions: &mut Vec<ShardAction<K>>) -> WorkerSlot {
        let slot = WorkerSlot(self.next_slot);
        self.next_slot += 1;
        self.workers.insert(slot, Worker { class, rings: BTreeSet::new() });
        actions.push(ShardAction::Spawn { slot, class });
        slot
    }

    /// The least loaded worker locked to `class` (lowest slot on a tie).
    /// Chrome picks a random suitable process; parse load wants the
    /// emptiest one.
    fn suitable_worker(&self, class: TrustClass) -> Option<WorkerSlot> {
        self.workers
            .iter()
            .filter(|(_, worker)| worker.class == class)
            .min_by_key(|&(&slot, worker)| (worker.rings.len(), slot))
            .map(|(&slot, _)| slot)
    }
}

#[cfg(test)]
#[path = "vt_trust_shards_tests.rs"]
mod tests;
