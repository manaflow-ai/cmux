//! The mutants the model-based fuzz must catch: each is the real router with
//! one rule broken the way a bug of the old key paths broke it, one or more
//! for each invariant I1-I8.

use super::fuzz::{FUZZ_LANE_LIMIT, Make, Real, Under, check, env, generate, real};
use cmux_focus_core::input::{
    DropReason, InputEffect, InputEvent, InputId, InputRouter, KeyRecord, LaneLimit, SessionEnd,
    Sink, Via, WaitReason,
};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

fn router() -> InputRouter {
    InputRouter::new(LaneLimit::of(FUZZ_LANE_LIMIT))
}

/// Today's replay: a key that waited goes where the focus is when it leaves
/// the lane (P0 1193, #33198).
struct RerouteAtDrain {
    router: InputRouter,
    windows: HashMap<InputId, Arc<str>>,
    queued: HashSet<InputId>,
}

/// Every third delivery happens twice (#32537 v6 "fieldfieldkeysok").
struct Twice {
    router: InputRouter,
    count: usize,
}

/// Two deliveries to one sink in one call swap places (#29693, #32409).
struct Swap {
    router: InputRouter,
}

/// A waiting key leaves after five more events, to wherever the focus is then
/// (the 2 s `holdLimit`).
struct Timer {
    router: InputRouter,
    waiting: Vec<(InputId, Arc<str>, usize)>,
    released: HashSet<InputId>,
}

/// No readiness: a key for a page that cannot take it yet goes at once
/// (REOPEN-F4's browser case, #32633).
struct NoReadiness {
    router: InputRouter,
    sent: HashSet<InputId>,
}

/// AppKit decides: a key goes where AppKit's dispatch reaches (INVERSE-KEY).
struct ResponderDecides {
    router: InputRouter,
}

/// One waiting key is lost: its delivery never happens.
struct LoseOne {
    router: InputRouter,
    lost: Option<InputId>,
}

fn key_of(event: &InputEvent) -> Option<&KeyRecord> {
    match event {
        InputEvent::Key(key) => Some(key),
        _ => None,
    }
}

impl Under for RerouteAtDrain {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut effects = self.router.handle(event).to_vec();
        if let (Some(key), Some(id)) =
            (key_of(event), effects.iter().filter_map(InputEffect::id).max())
        {
            self.windows.insert(id, key.window.clone());
        }
        for effect in &mut effects {
            match effect {
                InputEffect::Queued { id, .. } => {
                    self.queued.insert(*id);
                }
                InputEffect::Deliver { id, sink, .. } => {
                    let id = *id;
                    if self.queued.remove(&id)
                        && let Some(aim) = self.windows.get(&id).and_then(|w| self.router.aim(w))
                    {
                        *sink = aim;
                    }
                }
                _ => {}
            }
        }
        effects
    }
}

impl Under for Twice {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut out = Vec::new();
        for effect in self.router.handle(event) {
            out.push(effect.clone());
            if matches!(effect, InputEffect::Deliver { .. }) {
                self.count += 1;
                if self.count.is_multiple_of(3) {
                    out.push(effect.clone());
                }
            }
        }
        out
    }
}

impl Under for Swap {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut effects = self.router.handle(event).to_vec();
        let deliveries: Vec<usize> = effects
            .iter()
            .enumerate()
            .filter(|(_, e)| matches!(e, InputEffect::Deliver { .. }))
            .map(|(i, _)| i)
            .collect();
        for (n, first) in deliveries.iter().enumerate() {
            let same = deliveries.iter().skip(n + 1).find(|second| {
                match (&effects[*first], &effects[**second]) {
                    (
                        InputEffect::Deliver { sink: a, .. },
                        InputEffect::Deliver { sink: b, .. },
                    ) => a == b,
                    _ => false,
                }
            });
            if let Some(second) = same.copied() {
                effects.swap(*first, second);
                break;
            }
        }
        effects
    }
}

impl Under for Timer {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut effects: Vec<InputEffect> = self
            .router
            .handle(event)
            .iter()
            .filter(|e| !matches!(e, InputEffect::Deliver { id, .. } if self.released.contains(id)))
            .cloned()
            .collect();
        if let Some(key) = key_of(event) {
            for effect in &effects {
                if let InputEffect::Queued { id, .. } = effect {
                    self.waiting.push((*id, key.window.clone(), 0));
                }
            }
        }
        let mut expired = Vec::new();
        for (id, window, age) in &mut self.waiting {
            *age += 1;
            if *age > 5 && !self.released.contains(id) {
                expired.push((*id, window.clone()));
            }
        }
        for (id, window) in expired {
            if let Some(aim) = self.router.aim(&window) {
                self.released.insert(id);
                effects.push(InputEffect::Deliver { id, sink: aim, via: Via::Direct });
            }
        }
        effects
    }
}

impl Under for NoReadiness {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(event).to_vec();
        effects
            .into_iter()
            .filter_map(|effect| match effect {
                InputEffect::Queued { id, sink, reason: WaitReason::NotReady } => {
                    self.sent.insert(id);
                    Some(InputEffect::Deliver { id, sink, via: Via::Direct })
                }
                InputEffect::Deliver { id, .. } if self.sent.contains(&id) => None,
                other => Some(other),
            })
            .collect()
    }
}

impl Under for ResponderDecides {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut effects = self.router.handle(event).to_vec();
        if let Some(key) = key_of(event)
            && let Some(reaches) = &key.reaches
            && let Some(newest) = effects.iter().filter_map(InputEffect::id).max()
        {
            for effect in &mut effects {
                if let InputEffect::Deliver { id, sink, via } = effect
                    && *id == newest
                    && sink != reaches
                {
                    *sink = reaches.clone();
                    *via = Via::Responder;
                }
            }
        }
        effects
    }
}

impl Under for LoseOne {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(event).to_vec();
        for effect in &effects {
            if let InputEffect::Queued { id, .. } = effect
                && self.lost.is_none()
            {
                self.lost = Some(*id);
            }
        }
        let lost = self.lost;
        effects
            .into_iter()
            .filter(|e| !matches!(e, InputEffect::Deliver { id, .. } if Some(*id) == lost))
            .collect()
    }
}

fn reroute_at_drain() -> Box<dyn Under> {
    Box::new(RerouteAtDrain { router: router(), windows: HashMap::new(), queued: HashSet::new() })
}

fn twice() -> Box<dyn Under> {
    Box::new(Twice { router: router(), count: 0 })
}

fn swap() -> Box<dyn Under> {
    Box::new(Swap { router: router() })
}

fn timer() -> Box<dyn Under> {
    Box::new(Timer { router: router(), waiting: Vec::new(), released: HashSet::new() })
}

fn no_readiness() -> Box<dyn Under> {
    Box::new(NoReadiness { router: router(), sent: HashSet::new() })
}

fn responder_decides() -> Box<dyn Under> {
    Box::new(ResponderDecides { router: router() })
}

fn lose_one() -> Box<dyn Under> {
    Box::new(LoseOne { router: router(), lost: None })
}

/// A hint session's letter goes to the page the window's keys go to (#32537
/// round 3: hint letters reached the page): I4.
struct HintToPage {
    router: InputRouter,
}

/// A newer session leaves the older one running (two link-hint sessions, one
/// cancelled by the other's end: #32537 round 5): I5.
struct TwoSessions {
    router: InputRouter,
}

/// A page's unhandled report runs the held action twice: I2.
struct OfferTwice {
    router: InputRouter,
}

/// A key typed while a dialog blocks its target reaches the target (#31849:
/// Return under the dialog reached the terminal).
struct DialogLeak {
    router: InputRouter,
}

impl Under for HintToPage {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(event).to_vec();
        let Some(key) = key_of(event) else { return effects };
        let aim = self.router.aim(&key.window);
        effects
            .into_iter()
            .map(|effect| match (effect, &aim) {
                (InputEffect::SessionKey { id, .. }, Some(sink)) => {
                    InputEffect::Deliver { id, sink: sink.clone(), via: Via::Direct }
                }
                (effect, _) => effect,
            })
            .collect()
    }
}

impl Under for TwoSessions {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(event).to_vec();
        let replaced = |e: &InputEffect| {
            matches!(e, InputEffect::SessionEnded { reason: SessionEnd::Replaced, .. })
        };
        effects.into_iter().filter(|e| !replaced(e)).collect()
    }
}

impl Under for OfferTwice {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let mut effects = self.router.handle(event).to_vec();
        if let InputEvent::PageUnhandled { .. } = event
            && let Some(run) =
                effects.iter().find(|e| matches!(e, InputEffect::Run { .. })).cloned()
        {
            effects.push(run);
        }
        effects
    }
}

impl Under for DialogLeak {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let window = key_of(event).map(|key| key.window.clone());
        let effects = self.router.handle(event).to_vec();
        let Some(window) = window else { return effects };
        // What the key would reach with no dialog: the window's focused target.
        let target = self.router.aim(&window).filter(|sink| !matches!(sink, Sink::Dialog(_)));
        effects
            .into_iter()
            .map(|effect| match (effect, &target) {
                (InputEffect::Deliver { id, sink: Sink::Dialog(_), via }, Some(sink)) => {
                    InputEffect::Deliver { id, sink: sink.clone(), via }
                }
                (effect, _) => effect,
            })
            .collect()
    }
}

fn hint_to_page() -> Box<dyn Under> {
    Box::new(HintToPage { router: router() })
}

fn two_sessions() -> Box<dyn Under> {
    Box::new(TwoSessions { router: router() })
}

fn offer_twice() -> Box<dyn Under> {
    Box::new(OfferTwice { router: router() })
}

fn dialog_leak() -> Box<dyn Under> {
    Box::new(DialogLeak { router: router() })
}

/// A key for a sink that ended goes to it anyway (held keys replayed into a
/// closed terminal, #32291): I7.
struct DeliverToEnded {
    router: InputRouter,
    ended: Option<Sink>,
}

impl Under for DeliverToEnded {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(event).to_vec();
        let mut out = Vec::with_capacity(effects.len());
        for effect in effects {
            if let InputEffect::SinkEnded { sink, .. } = &effect {
                self.ended = Some(sink.clone());
            }
            let changed = match (&effect, &self.ended) {
                (InputEffect::Dropped { id, reason: DropReason::SinkGone(_) }, Some(sink)) => {
                    Some(InputEffect::Deliver { id: *id, sink: sink.clone(), via: Via::Direct })
                }
                _ => None,
            };
            out.push(changed.unwrap_or(effect));
        }
        out
    }
}

fn deliver_to_ended() -> Box<dyn Under> {
    Box::new(DeliverToEnded { router: router(), ended: None })
}

/// A lane holds more than its limit (an unbounded hold queue): I8.
fn unbounded() -> Box<dyn Under> {
    Box::new(Real(InputRouter::new(LaneLimit::of(FUZZ_LANE_LIMIT.saturating_mul(8)))))
}

#[test]
fn every_mutant_is_caught() {
    let len = env("CMUX_INPUT_FUZZ_LEN", 200) as usize;
    let cases = env("CMUX_INPUT_FUZZ_MUTANT_CASES", 200);
    let mutants: [(&str, Make); 13] = [
        ("reroute at drain", reroute_at_drain),
        ("twice", twice),
        ("swap", swap),
        ("timer", timer),
        ("no readiness", no_readiness),
        ("responder decides", responder_decides),
        ("lose one", lose_one),
        ("hint to page", hint_to_page),
        ("two sessions", two_sessions),
        ("offer twice", offer_twice),
        ("dialog leak", dialog_leak),
        ("deliver to ended", deliver_to_ended),
        ("unbounded", unbounded),
    ];
    // Each case must pass on the real router first: a case the real router
    // fails would catch every mutant for nothing.
    let mut missed: Vec<(&str, Make)> = mutants.to_vec();
    for seed in 1..=cases {
        if missed.is_empty() {
            break;
        }
        let events = generate(seed, len);
        if let Err(failure) = check(&events, &mut *real()) {
            panic!("the real router fails seed {seed}: {failure:?}");
        }
        missed.retain(|(_, make)| check(&events, &mut *make()).is_ok());
    }
    let names: Vec<&str> = missed.iter().map(|(name, _)| *name).collect();
    assert!(names.is_empty(), "mutants not caught in {cases} cases: {names:?}");
}
