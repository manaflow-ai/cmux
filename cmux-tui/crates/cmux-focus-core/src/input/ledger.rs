//! The router's invariants over its effect stream (DESIGN.md section 4.8),
//! checked without the router's rules: the model-based fuzz runs them after
//! every call, and the app's live monitor and journal replay can too.
//!
//! - I1 no lost key: every key gets exactly one disposition in its own call,
//!   and a key that waits ends exactly once (delivered, run or dropped with a
//!   reason); [`Ledger::waiting`] lists the keys still waiting.
//! - I2 no double key: no key ends twice.
//! - I3 order kept: a sink takes its keys in typing order, and the offers to
//!   one page end in typing order (a page answers its keys in key order).
//! - I4 a key a session takes reaches no sink: while a session runs, a
//!   key-down's disposition is the session's, unless the session ended first
//!   in the key's call (a key the session does not take ends it and routes on)
//!   or a blocking dialog took the key (a dialog is above every session; the
//!   session keeps running). A later delivery of a session's key breaks I2.
//! - I5 at most one key session runs.
//! - I6 fixed target: a waiting key ends at the sink it waited for.
//! - I7 no delivery to an ended sink: a tab's sink that ended (a `Gone`
//!   event, a `SinkEnded` effect) takes no key until a `SinkNew` effect says
//!   its id names a new sink.
//! - I8 bounded: no lane holds more entries than the router's lane limit.
//!
//! A key offered to its page first is delivered there; later its action runs
//! once (the page left it unhandled) or its offer closes with no action.
//!
//! The ledger keeps only what can still change: the waiting keys, the offered
//! keys whose report may come, the newest key each sink took, and the ended
//! sinks. A key that ended is forgotten: a later effect for it is a double end
//! because its id is not newer than the last key's.

use super::key::KeyPhase;
use super::lane::LaneLimit;
use super::sink::Sink;
use super::{InputEffect, InputEvent, InputId};
use std::collections::{HashMap, HashSet, VecDeque};

/// The invariants this ledger checks, by DESIGN.md id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Invariant {
    /// I1.
    NoLostKey,
    /// I2.
    NoDoubleKey,
    /// I3.
    OrderKept,
    /// I4.
    SessionTakes,
    /// I5.
    OneSession,
    /// I6.
    FixedTarget,
    /// I7.
    NoDeliveryToEnded,
    /// I8.
    Bounded,
    /// I1, its first half: a key's first disposition comes in the key's own
    /// call, never in another call.
    OwnCall,
    /// The router gives key ids in typing order.
    IdOrder,
}

/// One broken invariant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Violation {
    /// The invariant broken.
    pub invariant: Invariant,
    /// The key it is about, if one.
    pub id: Option<InputId>,
    /// What happened.
    pub detail: String,
}

/// What the router did with the keys that can still change.
pub struct Ledger {
    limit: usize,
    /// Waiting keys and the sink each waits for.
    waiting: HashMap<InputId, Sink>,
    /// The entries waiting for each sink (no entry: none).
    lanes: HashMap<Sink, usize>,
    /// Keys offered to a page whose offer has not ended, and their page,
    /// oldest first.
    offered: VecDeque<(InputId, Sink)>,
    /// The newest key each sink took (until the sink ends).
    newest: HashMap<Sink, InputId>,
    /// Tab sinks that ended and are not new yet.
    ended: HashSet<Sink>,
    last_key: Option<InputId>,
    /// Key sessions that run: started by an event, ended by an effect.
    sessions: i64,
    violations: Vec<Violation>,
}

impl Ledger {
    /// A ledger for a router whose lanes hold at most `limit` entries.
    pub fn new(limit: LaneLimit) -> Ledger {
        Ledger {
            limit: limit.keys(),
            waiting: HashMap::new(),
            lanes: HashMap::new(),
            offered: VecDeque::new(),
            newest: HashMap::new(),
            ended: HashSet::new(),
            last_key: None,
            sessions: 0,
            violations: Vec::new(),
        }
    }

    /// Checks one router call: `event` and the effects it returned.
    pub fn call(&mut self, event: &InputEvent, effects: &[InputEffect]) {
        let is_key = matches!(event, InputEvent::Key(_));
        if let InputEvent::Gone { sink, .. } = event
            && sink.of_tab()
        {
            self.end(sink);
        }
        // I4: a key-down typed while a session runs is the session's, unless
        // the session ended first in this call.
        let down = matches!(event, InputEvent::Key(key) if key.phase == KeyPhase::Down);
        let mut session_runs = down && self.sessions == 1;
        let mut new_key: Option<InputId> = None;
        for effect in effects {
            match effect {
                InputEffect::SinkEnded { sink, .. } => self.end(sink),
                InputEffect::SinkNew { sink } => {
                    self.ended.remove(sink);
                }
                InputEffect::SessionEnded { .. } => session_runs = false,
                _ => {}
            }
            let Some(id) = effect.id() else { continue };
            if let Some(waited) = self.waiting.remove(&id) {
                self.end_waiting(id, waited, effect);
            } else if let Some(index) = self.offered.iter().position(|(offered, _)| *offered == id)
            {
                self.end_offered(id, index, effect);
            } else if is_key && new_key.is_none() {
                new_key = Some(id);
                if self.last_key.is_some_and(|last| id <= last) {
                    let detail = format!("key id {id:?} is not after the last key's");
                    self.fail(Invariant::IdOrder, Some(id), detail);
                }
                if session_runs && past_session(effect) {
                    let detail = format!("a key-down went past the running session: {effect:?}");
                    self.fail(Invariant::SessionTakes, Some(id), detail);
                }
                self.first(id, effect);
            } else if new_key == Some(id) || self.last_key.is_some_and(|last| id <= last) {
                let detail = format!("a key that has its disposition ends again: {effect:?}");
                self.fail(Invariant::NoDoubleKey, Some(id), detail);
            } else {
                let detail = format!("a key's first disposition outside its call: {effect:?}");
                self.fail(Invariant::OwnCall, Some(id), detail);
            }
        }
        if is_key {
            match new_key {
                Some(id) => self.last_key = Some(id),
                None => {
                    let detail = "a key call gave its key no disposition".to_owned();
                    self.fail(Invariant::NoLostKey, None, detail);
                }
            }
        }
        let ended =
            effects.iter().filter(|e| matches!(e, InputEffect::SessionEnded { .. })).count();
        let started = i64::from(matches!(event, InputEvent::SessionStarted { .. }));
        let ended = i64::try_from(ended).unwrap_or(i64::MAX);
        self.sessions = self.sessions.saturating_add(started).saturating_sub(ended);
        if !(0..=1).contains(&self.sessions) {
            let detail = format!("{} key sessions run after {event:?}", self.sessions);
            self.fail(Invariant::OneSession, None, detail);
        }
    }

    /// A key's first disposition, in its own call.
    fn first(&mut self, id: InputId, effect: &InputEffect) {
        match effect {
            InputEffect::Queued { sink, .. } => {
                let count = self.lanes.entry(sink.clone()).or_default();
                *count = count.saturating_add(1);
                let waiting = *count;
                if waiting > self.limit {
                    let detail = format!("{waiting} entries wait for {sink:?}");
                    self.fail(Invariant::Bounded, Some(id), detail);
                }
                self.waiting.insert(id, sink.clone());
            }
            InputEffect::Offer { sink, .. } => {
                self.took(sink, id);
                self.offered.push_back((id, sink.clone()));
            }
            InputEffect::Deliver { sink, .. } => self.took(sink, id),
            _ => {}
        }
    }

    /// The end of key `id`, which waited for `waited`.
    fn end_waiting(&mut self, id: InputId, waited: Sink, effect: &InputEffect) {
        if let Some(count) = self.lanes.get_mut(&waited) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.lanes.remove(&waited);
            }
        }
        match effect {
            InputEffect::Deliver { sink, .. } => {
                if *sink != waited {
                    let detail = format!("waited for {waited:?}, delivered to {sink:?}");
                    self.fail(Invariant::FixedTarget, Some(id), detail);
                }
                self.took(sink, id);
            }
            InputEffect::Run { .. } => self.took(&waited, id),
            InputEffect::Dropped { .. } => {}
            InputEffect::Queued { .. } => {
                self.fail(Invariant::NoDoubleKey, Some(id), "a key queued twice".into());
            }
            _ => {
                let detail = format!("a waiting key ended as {effect:?}");
                self.fail(Invariant::NoLostKey, Some(id), detail);
            }
        }
    }

    /// An effect for key `id`, offered to its page (`index` in `offered`): its
    /// action runs, or its offer closes, after every older offer of its page.
    fn end_offered(&mut self, id: InputId, index: usize, effect: &InputEffect) {
        let Some((_, page)) = self.offered.remove(index) else { return };
        if let Some((older, _)) = self.offered.iter().find(|(older, of)| *older < id && *of == page)
        {
            let detail = format!("{effect:?} while the older offer {older:?} to {page:?} is open");
            self.fail(Invariant::OrderKept, Some(id), detail);
        }
        if !matches!(effect, InputEffect::Run { .. } | InputEffect::OfferClosed { .. }) {
            let detail = format!("an offered key ends again: {effect:?}");
            self.fail(Invariant::NoDoubleKey, Some(id), detail);
        }
    }

    /// `sink` ended: no key reaches it until it is new.
    fn end(&mut self, sink: &Sink) {
        self.ended.insert(sink.clone());
        self.newest.remove(sink);
    }

    /// `sink` took key `id`.
    fn took(&mut self, sink: &Sink, id: InputId) {
        if self.ended.contains(sink) {
            self.fail(Invariant::NoDeliveryToEnded, Some(id), format!("{sink:?} ended"));
        }
        if let Some(newest) = self.newest.get(sink)
            && *newest >= id
        {
            let detail = format!("{sink:?} took {id:?} after {newest:?}");
            self.fail(Invariant::OrderKept, Some(id), detail);
        }
        self.newest.insert(sink.clone(), id);
    }

    fn fail(&mut self, invariant: Invariant, id: Option<InputId>, detail: String) {
        self.violations.push(Violation { invariant, id, detail });
    }

    /// The keys still waiting, oldest first.
    pub fn waiting(&self) -> Vec<InputId> {
        let mut ids: Vec<InputId> = self.waiting.keys().copied().collect();
        ids.sort_unstable();
        ids
    }

    /// Every invariant broken so far, in order.
    pub fn violations(&self) -> &[Violation] {
        &self.violations
    }
}

/// The key-down's first disposition takes it past a running session (I4): to
/// a sink other than a blocking dialog, to an action, or to AppKit.
fn past_session(effect: &InputEffect) -> bool {
    match effect {
        InputEffect::Deliver { sink, .. }
        | InputEffect::Queued { sink, .. }
        | InputEffect::Offer { sink, .. } => !matches!(sink, Sink::Dialog(_)),
        InputEffect::Run { .. } | InputEffect::Platform { .. } => true,
        _ => false,
    }
}
