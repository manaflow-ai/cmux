//! What each VT worker really maps, as the broker applied it.
//!
//! The planner's own state cannot show a mixed worker: it sets every ring's
//! class to its worker's lock. `debug.vt`'s mapped-segment list is built
//! from this record instead (the broker updates it as it hands a worker a
//! ring or tells it to drop one, and when a worker ends), joined with the
//! class each segment was opened for. The planner is only a cross-check
//! ([`AppliedMappings::diverges_from`]).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;

use serde::Serialize;

use super::{RingSegment, ShardAction, ShardPlanner, TerminalKey, TrustClass, WorkerSlot};
use crate::SurfaceId;

/// One worker's row of `debug.vt`'s mapped-segment list.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkerMappings<K = SurfaceId> {
    pub slot: WorkerSlot,
    /// The worker's lock.
    pub class: TrustClass,
    /// A ring of another class, or of no known class, is mapped here.
    pub mixed: bool,
    pub segments: Vec<MappedSegment<K>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct MappedSegment<K = SurfaceId> {
    #[serde(flatten)]
    pub ring: RingSegment<K>,
    /// The class of the bytes in the segment; `None` when the segment holds
    /// bytes of more than one class, or its class is unknown.
    pub class: Option<TrustClass>,
}

/// An action the broker could not apply: the plan and the workers disagree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MappingError<K = SurfaceId> {
    NoWorker(WorkerSlot),
    WorkerLive(WorkerSlot),
    AlreadyMapped { ring: RingSegment<K>, slot: WorkerSlot },
    NotMapped { ring: RingSegment<K>, slot: WorkerSlot },
    RetiredWhileMapping { slot: WorkerSlot, rings: usize },
}

impl<K: fmt::Debug> fmt::Display for MappingError<K> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoWorker(slot) => write!(f, "no VT worker runs in slot {}", slot.0),
            Self::WorkerLive(slot) => write!(f, "a VT worker already runs in slot {}", slot.0),
            Self::AlreadyMapped { ring, slot } => {
                write!(f, "{ring:?} is already mapped in slot {}", slot.0)
            }
            Self::NotMapped { ring, slot } => {
                write!(f, "{ring:?} is not mapped in slot {}", slot.0)
            }
            Self::RetiredWhileMapping { slot, rings } => {
                write!(f, "slot {} retired while mapping {rings} rings", slot.0)
            }
        }
    }
}

impl<K: fmt::Debug> std::error::Error for MappingError<K> {}

/// Where the planner and the applied record differ.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Divergence<K = SurfaceId> {
    Lock { slot: WorkerSlot, planned: Option<TrustClass>, applied: Option<TrustClass> },
    Ring { ring: RingSegment<K>, planned: Option<WorkerSlot>, applied: Option<WorkerSlot> },
}

struct AppliedWorker<K> {
    lock: TrustClass,
    rings: BTreeSet<RingSegment<K>>,
}

/// The broker's record of each live worker's lock and mapped rings.
pub struct AppliedMappings<K = SurfaceId> {
    workers: BTreeMap<WorkerSlot, AppliedWorker<K>>,
    mapped_in: HashMap<RingSegment<K>, WorkerSlot>,
}

impl<K: TerminalKey> Default for AppliedMappings<K> {
    fn default() -> Self {
        Self { workers: BTreeMap::new(), mapped_in: HashMap::new() }
    }
}

impl<K: TerminalKey> AppliedMappings<K> {
    /// Record one action the broker carried out.
    pub fn apply(&mut self, action: ShardAction<K>) -> Result<(), MappingError<K>> {
        match action {
            ShardAction::Spawn { slot, class } => {
                if self.workers.contains_key(&slot) {
                    return Err(MappingError::WorkerLive(slot));
                }
                self.workers.insert(slot, AppliedWorker { lock: class, rings: BTreeSet::new() });
            }
            ShardAction::Map { slot, ring } => {
                if let Some(&other) = self.mapped_in.get(&ring) {
                    return Err(MappingError::AlreadyMapped { ring, slot: other });
                }
                let worker = self.workers.get_mut(&slot).ok_or(MappingError::NoWorker(slot))?;
                worker.rings.insert(ring);
                self.mapped_in.insert(ring, slot);
            }
            ShardAction::Unmap { slot, ring } => {
                let worker = self.workers.get_mut(&slot).ok_or(MappingError::NoWorker(slot))?;
                if !worker.rings.remove(&ring) {
                    return Err(MappingError::NotMapped { ring, slot });
                }
                self.mapped_in.remove(&ring);
            }
            ShardAction::Retire { slot } => {
                let worker = self.workers.get(&slot).ok_or(MappingError::NoWorker(slot))?;
                if !worker.rings.is_empty() {
                    return Err(MappingError::RetiredWhileMapping {
                        slot,
                        rings: worker.rings.len(),
                    });
                }
                self.workers.remove(&slot);
            }
        }
        Ok(())
    }

    pub fn apply_all(&mut self, actions: &[ShardAction<K>]) -> Result<(), MappingError<K>> {
        actions.iter().try_for_each(|&action| self.apply(action))
    }

    /// The worker's process ended; the kernel unmapped its rings.
    pub fn worker_ended(&mut self, slot: WorkerSlot) {
        if let Some(worker) = self.workers.remove(&slot) {
            for ring in worker.rings {
                self.mapped_in.remove(&ring);
            }
        }
    }

    /// `debug.vt`'s mapped-segment list, by slot. `class_of` is the class
    /// each segment's bytes have, from the terminal's origin when the holder
    /// opened the segment (`None` if mixed or unknown).
    pub fn mapped_segments(
        &self,
        class_of: impl Fn(RingSegment<K>) -> Option<TrustClass>,
    ) -> Vec<WorkerMappings<K>> {
        self.workers
            .iter()
            .map(|(&slot, worker)| {
                let segments: Vec<MappedSegment<K>> = worker
                    .rings
                    .iter()
                    .map(|&ring| MappedSegment { ring, class: class_of(ring) })
                    .collect();
                let mixed = segments.iter().any(|segment| segment.class != Some(worker.lock));
                WorkerMappings { slot, class: worker.lock, mixed, segments }
            })
            .collect()
    }

    /// Every way the planner's view differs from what the workers map.
    pub fn diverges_from(&self, planner: &ShardPlanner<K>) -> Vec<Divergence<K>> {
        let slots: BTreeSet<WorkerSlot> =
            self.workers.keys().chain(planner.workers.keys()).copied().collect();
        let mut out: Vec<Divergence<K>> = slots
            .into_iter()
            .filter_map(|slot| {
                let planned = planner.workers.get(&slot).map(|w| w.class);
                let applied = self.workers.get(&slot).map(|w| w.lock);
                (planned != applied).then_some(Divergence::Lock { slot, planned, applied })
            })
            .collect();
        let planned_rings: HashMap<RingSegment<K>, WorkerSlot> = planner
            .workers
            .iter()
            .flat_map(|(&slot, w)| w.rings.iter().map(move |&ring| (ring, slot)))
            .collect();
        let rings: BTreeSet<RingSegment<K>> =
            planned_rings.keys().chain(self.mapped_in.keys()).copied().collect();
        out.extend(rings.into_iter().filter_map(|ring| {
            let planned = planned_rings.get(&ring).copied();
            let applied = self.mapped_in.get(&ring).copied();
            (planned != applied).then_some(Divergence::Ring { ring, planned, applied })
        }));
        out
    }
}
