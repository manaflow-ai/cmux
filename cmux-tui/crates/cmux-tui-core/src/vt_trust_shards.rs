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
//! site: a worker (in pool mode, a pool shard) is locked to the class of its
//! first terminal and only ever maps rings of that class. Under the cap each
//! new terminal gets a new worker; at the cap it goes to the least loaded
//! worker of its class; a class with no worker spills one extra worker past
//! the cap. So a session has at most `cap + classes - 1` workers, and none
//! mixes classes.
//!
//! [`ShardPlanner`] is the broker's placement state, owned by its one thread
//! (no lock). Each call returns the [`ShardAction`]s the broker applies in
//! order. When a terminal moves to another worker its ring is unmapped from
//! the old worker before the new one maps it, so no ring is ever mapped in
//! two workers and no worker maps a ring of a class other than its lock.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::num::NonZeroUsize;

use serde::Serialize;

use crate::SurfaceId;

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
    /// The class of a terminal. Agent-fetched content wins over the host:
    /// a terminal with several sources takes the least trusted one, so it
    /// never shares a worker with more trusted bytes.
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
}

/// One VT worker (pool shard in thread mode). A restarted worker keeps its
/// slot and its class lock.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct WorkerSlot(pub u64);

/// One holder ring of a terminal. A holder restart can give a terminal a
/// fresh ring, so a terminal maps one segment at a time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct RingSegment {
    pub terminal: SurfaceId,
    pub segment: u64,
}

/// What the broker does, in the order returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShardAction {
    /// Start a worker in `slot`, locked to `class`.
    Spawn { slot: WorkerSlot, class: TrustClass },
    /// Pass the ring's fd to the worker, which maps it read-only.
    Map { slot: WorkerSlot, ring: RingSegment },
    /// Tell the worker to unmap the ring and drop the terminal's screen.
    Unmap { slot: WorkerSlot, ring: RingSegment },
    /// Stop the worker; it maps no ring.
    Retire { slot: WorkerSlot },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShardError {
    AlreadyPlaced(SurfaceId),
    UnknownTerminal(SurfaceId),
    UnknownWorker(WorkerSlot),
}

impl fmt::Display for ShardError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyPlaced(id) => write!(f, "terminal {id} already has a VT worker"),
            Self::UnknownTerminal(id) => write!(f, "terminal {id} has no VT worker"),
            Self::UnknownWorker(slot) => write!(f, "no VT worker in slot {}", slot.0),
        }
    }
}

impl std::error::Error for ShardError {}

/// One worker's row of `debug.vt`'s mapped-segment list.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkerMappings {
    pub slot: WorkerSlot,
    /// The worker's lock.
    pub class: TrustClass,
    /// Every ring it maps, with each ring's own class.
    pub segments: Vec<MappedSegment>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct MappedSegment {
    #[serde(flatten)]
    pub ring: RingSegment,
    pub class: TrustClass,
}

struct Worker {
    class: TrustClass,
    rings: BTreeSet<RingSegment>,
}

#[derive(Clone, Copy)]
struct Placement {
    slot: WorkerSlot,
    class: TrustClass,
    segment: u64,
}

/// Which worker parses which terminal, by trust class.
pub struct ShardPlanner {
    cap: NonZeroUsize,
    workers: BTreeMap<WorkerSlot, Worker>,
    terminals: HashMap<SurfaceId, Placement>,
    next_slot: u64,
}

impl ShardPlanner {
    /// `cap` is the worker count N the broker aims for; a class with no
    /// worker spills past it.
    pub fn new(cap: NonZeroUsize) -> Self {
        Self { cap, workers: BTreeMap::new(), terminals: HashMap::new(), next_slot: 0 }
    }

    /// Give a new terminal a worker of its class.
    pub fn place(
        &mut self,
        terminal: SurfaceId,
        class: TrustClass,
        segment: u64,
    ) -> Result<Vec<ShardAction>, ShardError> {
        if self.terminals.contains_key(&terminal) {
            return Err(ShardError::AlreadyPlaced(terminal));
        }
        let mut actions = Vec::with_capacity(2);
        self.place_into(terminal, class, segment, &mut actions);
        Ok(actions)
    }

    /// The terminal's class changed (a local shell ran `ssh`, an agent
    /// started printing fetched content): move it to a worker of the new
    /// class. The old worker unmaps the ring first.
    pub fn reclassify(
        &mut self,
        terminal: SurfaceId,
        class: TrustClass,
    ) -> Result<Vec<ShardAction>, ShardError> {
        let placement =
            *self.terminals.get(&terminal).ok_or(ShardError::UnknownTerminal(terminal))?;
        if placement.class == class {
            return Ok(Vec::new());
        }
        let mut actions = Vec::with_capacity(4);
        self.unplace(terminal, placement, &mut actions);
        self.place_into(terminal, class, placement.segment, &mut actions);
        Ok(actions)
    }

    /// The terminal got a fresh holder ring: its worker swaps mappings.
    pub fn replace_segment(
        &mut self,
        terminal: SurfaceId,
        segment: u64,
    ) -> Result<Vec<ShardAction>, ShardError> {
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
    pub fn remove(&mut self, terminal: SurfaceId) -> Result<Vec<ShardAction>, ShardError> {
        let placement =
            self.terminals.get(&terminal).copied().ok_or(ShardError::UnknownTerminal(terminal))?;
        let mut actions = Vec::with_capacity(2);
        self.unplace(terminal, placement, &mut actions);
        Ok(actions)
    }

    /// The worker in `slot` died, and the kernel unmapped its rings. Its
    /// replacement keeps the slot and the class lock and maps the same
    /// rings (the broker reseeds each from its holder prologue).
    pub fn worker_lost(&mut self, slot: WorkerSlot) -> Result<Vec<ShardAction>, ShardError> {
        let worker = self.workers.get(&slot).ok_or(ShardError::UnknownWorker(slot))?;
        let mut actions = Vec::with_capacity(worker.rings.len() + 1);
        actions.push(ShardAction::Spawn { slot, class: worker.class });
        actions.extend(worker.rings.iter().map(|&ring| ShardAction::Map { slot, ring }));
        Ok(actions)
    }

    pub fn slot_of(&self, terminal: SurfaceId) -> Option<WorkerSlot> {
        self.terminals.get(&terminal).map(|placement| placement.slot)
    }

    pub fn worker_count(&self) -> usize {
        self.workers.len()
    }

    /// `debug.vt`'s mapped-segment list, by slot.
    pub fn mapped_segments(&self) -> Vec<WorkerMappings> {
        self.workers
            .iter()
            .map(|(&slot, worker)| WorkerMappings {
                slot,
                class: worker.class,
                segments: worker
                    .rings
                    .iter()
                    .map(|&ring| MappedSegment {
                        ring,
                        class: self.terminals.get(&ring.terminal).map_or(worker.class, |p| p.class),
                    })
                    .collect(),
            })
            .collect()
    }

    fn place_into(
        &mut self,
        terminal: SurfaceId,
        class: TrustClass,
        segment: u64,
        actions: &mut Vec<ShardAction>,
    ) {
        let slot = match self.suitable_worker(class) {
            Some(slot) if self.workers.len() >= self.cap.get() => slot,
            _ => {
                let slot = self.fresh_slot();
                self.workers.insert(slot, Worker { class, rings: BTreeSet::new() });
                actions.push(ShardAction::Spawn { slot, class });
                slot
            }
        };
        let ring = RingSegment { terminal, segment };
        if let Some(worker) = self.workers.get_mut(&slot) {
            worker.rings.insert(ring);
        }
        self.terminals.insert(terminal, Placement { slot, class, segment });
        actions.push(ShardAction::Map { slot, ring });
    }

    fn unplace(
        &mut self,
        terminal: SurfaceId,
        placement: Placement,
        actions: &mut Vec<ShardAction>,
    ) {
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

    fn fresh_slot(&mut self) -> WorkerSlot {
        let slot = WorkerSlot(self.next_slot);
        self.next_slot += 1;
        slot
    }
}

#[cfg(test)]
#[path = "vt_trust_shards_tests.rs"]
mod tests;
