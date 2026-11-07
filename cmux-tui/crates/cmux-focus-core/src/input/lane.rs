//! Lanes (DESIGN.md section 4.5): the one mechanism that holds keys. A sink's
//! lane keeps the keys and input actions that wait for that sink, in typing
//! order, bounded, with no timer. An entry leaves its lane only to its own
//! sink, or is dropped with a reason.

use super::router::{InputRouter, Press};
use super::sink::Sink;
use super::{DropReason, InputEffect, InputId, Via, WaitReason};
use std::sync::Arc;

/// The most entries one sink's lane holds. An entry past it is refused at key
/// time with `Dropped { LaneFull }`, a loss the platform shows (R9 R-L5).
///
/// It comes from the machine's memory (R9 R-L1), which the platform reads at
/// start ([`LaneLimit::for_memory`] with `hw.memsize`): a lane may use
/// 1/[`LANE_SHARE`] of physical memory, and a waiting key costs [`KEY_COST`]
/// bytes (the platform keeps its event to deliver it later). 16 GiB gives
/// 4096 keys a lane: about 2 minutes of a held key's auto-repeat for a page
/// that never paints.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaneLimit(usize);

impl LaneLimit {
    /// The lane limit of a machine with `memory` bytes of physical memory (at
    /// least one key).
    pub fn for_memory(memory: u64) -> LaneLimit {
        let keys = memory.checked_div(LANE_SHARE.saturating_mul(KEY_COST)).unwrap_or(0);
        LaneLimit(usize::try_from(keys).unwrap_or(usize::MAX).max(1))
    }

    /// A limit of `keys` keys (at least one), for tests and for a platform
    /// that budgets its memory another way.
    pub fn of(keys: usize) -> LaneLimit {
        LaneLimit(keys.max(1))
    }

    /// The entries a lane holds at most.
    pub fn keys(self) -> usize {
        self.0
    }
}

/// A lane's share of physical memory: 1/4096 of it.
const LANE_SHARE: u64 = 4096;
/// What one waiting key costs, in bytes: its event, kept by the platform.
const KEY_COST: u64 = 1024;

/// One waiting entry of a lane, in typing order.
pub(super) enum LaneEntry {
    /// A key; `text`: typed text (an input method may compose it).
    Key { id: InputId, text: bool },
    /// An action that edits this sink's input, typed while the sink could not
    /// take input or behind keys typed before it (a Paste before a page's
    /// first paint, a Paste behind typing): it runs when a key could go.
    Run { id: InputId, action: Arc<str>, tab: Option<Arc<str>> },
}

impl LaneEntry {
    pub(super) fn id(&self) -> InputId {
        match self {
            LaneEntry::Key { id, .. } | LaneEntry::Run { id, .. } => *id,
        }
    }
}

impl InputRouter {
    /// Puts `entry` in `sink`'s lane; false: the lane is full, and the entry
    /// is dropped.
    pub(super) fn enqueue(&mut self, sink: Sink, entry: LaneEntry, reason: WaitReason) -> bool {
        let id = entry.id();
        let limit = self.lane_limit.keys();
        let lane = self.lanes.entry(sink.clone()).or_default();
        if lane.len() >= limit {
            self.push(InputEffect::Dropped { id, reason: DropReason::LaneFull });
            return false;
        }
        lane.push_back(entry);
        self.push(InputEffect::Queued { id, sink, reason });
        true
    }

    /// A field's or an overlay's lane whose window's focus left it: its keys
    /// can never reach it (the person moved on), so they are dropped.
    pub(super) fn drop_left_lanes(&mut self) {
        let left: Vec<Sink> = self
            .lanes
            .keys()
            .filter(|sink| match sink.window() {
                Some(window) => match self.windows.get_key_value(window) {
                    Some((id, input)) => self.aim_in(id, input).sink.as_ref() != Some(*sink),
                    None => true,
                },
                None => false,
            })
            .cloned()
            .collect();
        self.drop_lanes(left, DropReason::TargetLeft);
    }

    /// Drops every entry of the lanes of `sinks`, in typing order. A press
    /// whose key-down is dropped reaches nothing more: its repeats and its
    /// release are consumed.
    pub(super) fn drop_lanes(&mut self, sinks: Vec<Sink>, reason: DropReason) {
        let mut dropped: Vec<InputId> = Vec::new();
        for sink in sinks {
            if let Some(lane) = self.lanes.remove(&sink) {
                dropped.extend(lane.iter().map(LaneEntry::id));
            }
        }
        if dropped.is_empty() {
            return;
        }
        dropped.sort_unstable();
        for press in self.presses.values_mut() {
            if let Press::Sink { down, .. } = *press
                && dropped.binary_search(&down).is_ok()
            {
                *press = Press::Nothing;
            }
        }
        for id in dropped {
            self.push(InputEffect::Dropped { id, reason });
        }
    }

    /// Delivers every waiting entry whose sink can take it now, oldest first:
    /// a lane's entries in order, each lane up to its first entry that must
    /// still wait. A waiting action runs when a key could go to its sink.
    pub(super) fn drain(&mut self) {
        loop {
            // The oldest lane front that can go now, and how.
            let mut next: Option<(InputId, &Sink, Via)> = None;
            for (sink, lane) in &self.lanes {
                let Some(front) = lane.front() else { continue };
                let text = matches!(front, LaneEntry::Key { text: true, .. });
                let Ok(via) = self.deliverable(sink, self.facts.reaches.as_ref(), text) else {
                    continue;
                };
                if next.as_ref().is_none_or(|(oldest, _, _)| front.id() < *oldest) {
                    next = Some((front.id(), sink, via));
                }
            }
            let Some((_, sink, via)) = next else { return };
            let sink = sink.clone();
            let Some(lane) = self.lanes.get_mut(&sink) else { return };
            // The effect is made from the front before it leaves the lane, so no
            // entry is ever taken without its effect.
            let effect = match lane.front() {
                Some(LaneEntry::Key { id, .. }) => {
                    InputEffect::Deliver { id: *id, sink: sink.clone(), via }
                }
                Some(LaneEntry::Run { id, action, tab }) => {
                    InputEffect::Run { id: *id, action: action.clone(), tab: tab.clone() }
                }
                None => return,
            };
            lane.pop_front();
            if lane.is_empty() {
                self.lanes.remove(&sink);
            }
            self.push(effect);
        }
    }
}
