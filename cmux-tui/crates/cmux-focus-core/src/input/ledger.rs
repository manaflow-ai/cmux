//! The router's invariants over its effect stream (DESIGN.md section 4.8),
//! checked without the router's rules: the model-based fuzz runs them after
//! every call, and the app's live monitor and journal replay can too.
//!
//! - I1 no lost key: every key gets exactly one disposition in its own call,
//!   and a key that waits ends exactly once (delivered, run or dropped with a
//!   reason); [`Ledger::waiting`] lists the keys still waiting.
//! - I2 no double key: no key ends twice.
//! - I3 order kept: a sink takes its keys in typing order.
//! - I4 a key a session takes reaches no sink: it ends there (I2 then refuses
//!   any later delivery of it).
//! - I5 at most one key session runs.
//! - I6 fixed target: a waiting key ends at the sink it waited for.
//! - I7 no delivery to an ended sink.
//! - I8 bounded: no lane holds more than [`LANE_LIMIT`] keys.
//!
//! A key offered to its page first is delivered there; its action may run
//! once later, when the page reports it unhandled.

use super::router::LANE_LIMIT;
use super::sink::Sink;
use super::{DropReason, InputEffect, InputEvent, InputId};
use std::collections::{HashMap, HashSet};

/// The invariants this ledger checks, by DESIGN.md id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Invariant {
    /// I1.
    NoLostKey,
    /// I2.
    NoDoubleKey,
    /// I3.
    OrderKept,
    /// I5.
    OneSession,
    /// I6.
    FixedTarget,
    /// I7.
    NoDeliveryToEnded,
    /// I8.
    Bounded,
}

/// One broken invariant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Violation {
    pub invariant: Invariant,
    pub id: Option<InputId>,
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Life {
    Waiting(Sink),
    /// Delivered to its page first; its action may still run once.
    Offered,
    Done,
}

/// What the router did with every key so far.
#[derive(Default)]
pub struct Ledger {
    keys: HashMap<InputId, Life>,
    /// The newest key each sink took.
    newest: HashMap<Sink, InputId>,
    waiting: HashMap<Sink, usize>,
    /// Sinks that ended: a Gone event, or a waiting key dropped because its
    /// sink ended (a failed creation's).
    ended: HashSet<Sink>,
    last_key: Option<InputId>,
    /// Key sessions that run: started by an event, ended by an effect.
    sessions: i64,
    violations: Vec<Violation>,
}

impl Ledger {
    pub fn new() -> Ledger {
        Ledger::default()
    }

    /// Checks one router call: `event` and the effects it returned.
    pub fn call(&mut self, event: &InputEvent, effects: &[InputEffect]) {
        let mut new_keys: Vec<InputId> = Vec::new();
        for effect in effects {
            self.effect(effect, &mut new_keys);
        }
        if let InputEvent::Key(_) = event {
            match new_keys.as_slice() {
                [id] => {
                    if self.last_key.is_some_and(|last| *id <= last) {
                        self.fail(
                            Invariant::OrderKept,
                            Some(*id),
                            "a key id not after the last key's".into(),
                        );
                    }
                    self.last_key = Some(*id);
                }
                _ => self.fail(
                    Invariant::NoLostKey,
                    None,
                    format!("a key call gave {} new keys a disposition, not 1", new_keys.len()),
                ),
            }
        } else if !new_keys.is_empty() {
            self.fail(
                Invariant::NoDoubleKey,
                new_keys.first().copied(),
                "a key disposition outside its key's call".into(),
            );
        }
        if let InputEvent::Gone { sink, .. } = event {
            self.ended.insert(sink.clone());
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

    fn effect(&mut self, effect: &InputEffect, new_keys: &mut Vec<InputId>) {
        let Some(id) = effect.id() else { return };
        let life = self.keys.get(&id).cloned();
        match (effect, life) {
            (InputEffect::Queued { sink, .. }, None) => {
                new_keys.push(id);
                self.keys.insert(id, Life::Waiting(sink.clone()));
                let count = self.waiting.entry(sink.clone()).or_default();
                *count = count.saturating_add(1);
                let waiting = *count;
                if waiting > LANE_LIMIT {
                    self.fail(
                        Invariant::Bounded,
                        Some(id),
                        format!("{waiting} keys wait for one sink"),
                    );
                }
            }
            (InputEffect::Queued { .. }, Some(_)) => {
                self.fail(Invariant::NoDoubleKey, Some(id), "a key queued twice".into());
            }
            (InputEffect::Offer { sink, .. }, None) => {
                new_keys.push(id);
                self.keys.insert(id, Life::Offered);
                self.took(sink, id);
            }
            (InputEffect::Run { .. }, Some(Life::Offered)) => {
                self.keys.insert(id, Life::Done);
            }
            (_, Some(Life::Offered)) => {
                let detail = format!("an offered key ends again: {effect:?}");
                self.fail(Invariant::NoDoubleKey, Some(id), detail);
            }
            (_, None) => {
                new_keys.push(id);
                self.keys.insert(id, Life::Done);
                if let InputEffect::Deliver { sink, .. } = effect {
                    self.took(sink, id);
                }
            }
            (_, Some(Life::Done)) => {
                self.fail(
                    Invariant::NoDoubleKey,
                    Some(id),
                    format!("a key that ended ends again: {effect:?}"),
                );
            }
            (_, Some(Life::Waiting(waited))) => {
                self.keys.insert(id, Life::Done);
                if let Some(count) = self.waiting.get_mut(&waited) {
                    *count = count.saturating_sub(1);
                }
                match effect {
                    InputEffect::Deliver { sink, .. } => {
                        if *sink != waited {
                            self.fail(
                                Invariant::FixedTarget,
                                Some(id),
                                format!("waited for {waited:?}, delivered to {sink:?}"),
                            );
                        }
                        self.took(sink, id);
                    }
                    InputEffect::Run { .. } => self.took(&waited, id),
                    InputEffect::Dropped { reason: DropReason::SinkGone(_), .. } => {
                        self.ended.insert(waited);
                    }
                    InputEffect::Dropped { .. } => {}
                    _ => self.fail(
                        Invariant::NoLostKey,
                        Some(id),
                        format!("a waiting key ended as {effect:?}"),
                    ),
                }
            }
        }
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
        let mut ids: Vec<InputId> = self
            .keys
            .iter()
            .filter(|(_, life)| matches!(life, Life::Waiting(_)))
            .map(|(id, _)| *id)
            .collect();
        ids.sort_unstable();
        ids
    }

    pub fn violations(&self) -> &[Violation] {
        &self.violations
    }
}
