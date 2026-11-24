//! The viewer's side of the three-way hub (RFD 0142 R6, ultra-connectivity
//! A2 "most truthful copy"): what the phone does with each hub frame the
//! relay delivered. Pure, no I/O, no clock.
//!
//! The relay picks which source's copy the viewer gets, but it never holds a
//! key, so the viewer checks everything the pick rests on:
//!
//! - the clear header must equal the `(session, epoch, seq, source)` the
//!   source sealed inside the body, or the frame is rejected;
//! - events are delivered in log order, each position once, whichever source
//!   carried it; a jump inside an epoch is reported as a [`TruthEvent::Gap`]
//!   the caller fills from a source directly;
//! - each source's highest position seen is kept, from delivered frames and
//!   from heads the sources report over their own direct links; when the
//!   relay delivers a copy while the other source is known to be further
//!   ahead than [`TruthConfig::stale_tolerance`], that is a stale pick
//!   ([`TruthEvent::StalePick`]) and the caller asks the other source.

use crate::hub::{HubKey, HubOpenError, HubPos, HubRole, Opened, open};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TruthConfig {
    /// How many positions a delivered copy may trail the other source's
    /// known head before it counts as a stale pick (frames in flight race
    /// the head reports, so 0 would flag healthy streams).
    pub stale_tolerance: u64,
}

impl Default for TruthConfig {
    fn default() -> Self {
        Self { stale_tolerance: 4 }
    }
}

/// What the caller does after one frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TruthEvent {
    /// Show this event: the next in log order, never shown before.
    Deliver { source: HubRole, pos: HubPos, event: Vec<u8> },
    /// Positions `from..=to` of `epoch` never arrived: ask `ask` for them
    /// directly (the source with the higher known head).
    Gap { epoch: u64, from: u64, to: u64, ask: HubRole },
    /// The relay delivered `source`'s copy at `delivered` while `ahead` is
    /// known to be at `head`: ask `ahead` directly.
    StalePick { source: HubRole, delivered: HubPos, ahead: HubRole, head: HubPos },
}

/// Why a frame was not delivered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TruthReject {
    Open(HubOpenError),
    /// The clear header and the sealed triple disagree: the relay (or
    /// someone on the path) edited the header.
    HeaderMismatch,
    /// Another session's frame.
    WrongSession,
    /// A position already delivered (the other source's copy, or a replay).
    Duplicate,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TruthStats {
    pub delivered: u64,
    pub duplicates: u64,
    pub mismatches: u64,
    pub stale_picks: u64,
    pub gaps: u64,
}

#[derive(Debug, Clone)]
pub struct TruthTracker {
    session: [u8; 16],
    config: TruthConfig,
    delivered: Option<HubPos>,
    heads: [Option<HubPos>; 2],
    /// The other source's head a stale pick was last flagged for, so one
    /// lag is flagged once rather than on every frame.
    flagged: [Option<HubPos>; 2],
    pub stats: TruthStats,
}

impl TruthTracker {
    pub fn new(session: [u8; 16], config: TruthConfig) -> Self {
        Self {
            session,
            config,
            delivered: None,
            heads: [None; 2],
            flagged: [None; 2],
            stats: TruthStats::default(),
        }
    }

    /// The last position delivered.
    pub fn delivered(&self) -> Option<HubPos> {
        self.delivered
    }

    /// The highest position known for `source`.
    pub fn head(&self, source: HubRole) -> Option<HubPos> {
        *slot(&self.heads, source)
    }

    /// A source reported its head over its own direct link.
    pub fn report_head(&mut self, source: HubRole, head: HubPos) {
        let slot = slot_mut(&mut self.heads, source);
        if slot.is_none_or(|known| head > known) {
            *slot = Some(head);
        }
    }

    /// Opens a hub payload the relay delivered and takes it.
    pub fn on_payload(
        &mut self,
        key: &HubKey,
        payload: &[u8],
    ) -> Result<Vec<TruthEvent>, TruthReject> {
        let opened = open(key, payload).map_err(TruthReject::Open)?;
        self.on_opened(opened)
    }

    /// Takes a frame already opened by [`open`].
    pub fn on_opened(&mut self, opened: Opened) -> Result<Vec<TruthEvent>, TruthReject> {
        let header = opened.header;
        if header.session != opened.inner_session
            || header.pos != opened.inner_pos
            || header.source != opened.inner_source
        {
            self.stats.mismatches += 1;
            return Err(TruthReject::HeaderMismatch);
        }
        if header.session != self.session {
            return Err(TruthReject::WrongSession);
        }
        let (source, pos) = (header.source, header.pos);
        self.report_head(source, pos);
        if self.delivered.is_some_and(|done| pos <= done) {
            self.stats.duplicates += 1;
            return Err(TruthReject::Duplicate);
        }
        let mut out = Vec::new();
        if let Some(done) = self.delivered
            && done.epoch == pos.epoch
            && pos.seq > done.seq + 1
        {
            self.stats.gaps += 1;
            let ask = match (self.head(HubRole::Mac), self.head(HubRole::Vm)) {
                (Some(mac), Some(vm)) if vm > mac => HubRole::Vm,
                (Some(_), _) => HubRole::Mac,
                _ => source,
            };
            out.push(TruthEvent::Gap {
                epoch: pos.epoch,
                from: done.seq + 1,
                to: pos.seq - 1,
                ask,
            });
        }
        let ahead = source.other();
        if let Some(head) = self.head(ahead)
            && head > pos
            && behind_by(pos, head) > self.config.stale_tolerance
            && *slot(&self.flagged, ahead) != Some(head)
        {
            *slot_mut(&mut self.flagged, ahead) = Some(head);
            self.stats.stale_picks += 1;
            out.push(TruthEvent::StalePick { source, delivered: pos, ahead, head });
        }
        self.delivered = Some(pos);
        self.stats.delivered += 1;
        out.push(TruthEvent::Deliver { source, pos, event: opened.event });
        Ok(out)
    }
}

/// How far `pos` trails `head`; a later epoch is always past any tolerance.
fn behind_by(pos: HubPos, head: HubPos) -> u64 {
    if head.epoch > pos.epoch { u64::MAX } else { head.seq.saturating_sub(pos.seq) }
}

#[cfg(test)]
#[path = "hub_truth_tests.rs"]
mod tests;

/// `role`'s entry of a per-source pair (no index, so nothing to panic on).
fn slot(pair: &[Option<HubPos>; 2], role: HubRole) -> &Option<HubPos> {
    let [mac, vm] = pair;
    match role {
        HubRole::Mac => mac,
        HubRole::Vm => vm,
    }
}

fn slot_mut(pair: &mut [Option<HubPos>; 2], role: HubRole) -> &mut Option<HubPos> {
    let [mac, vm] = pair;
    match role {
        HubRole::Mac => mac,
        HubRole::Vm => vm,
    }
}
