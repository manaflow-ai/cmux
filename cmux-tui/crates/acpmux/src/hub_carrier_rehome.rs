//! Relay re-homing: the relays a carrier may use, in the order it tries them.
//!
//! The platform's answer names one relay (`relay`) and, from a platform that knows more than
//! one, the others in its order of preference (`relays`, `hub_carrier.rs` [`CarrierAnswer`]).
//! A host registers on the first. When that registration stays down past
//! `Timings::rehome_after` (the relay died, or stopped answering), it registers on the next,
//! wrapping round; a relay that comes back within the bound keeps the host, so a relay restart
//! never moves anyone. A dialer tries the relay that last carried that machine first, then the
//! rest in the platform's order: a relay with no registration for the slot answers
//! `slot-offline` at once, so following a moved host costs one fast refusal per relay passed.
//!
//! Versioned by the field alone. An older platform names no `relays`: the list is the one relay,
//! and nothing moves (today's behavior). An older carrier ignores the field (no
//! `deny_unknown_fields` on [`CarrierAnswer`]) and stays on `relay`, where a newer host
//! registers first, so the two meet until that relay dies.

use std::collections::HashMap;
use std::sync::Mutex;

use super::CarrierAnswer;

/// The relays `answer` names, `relay` first, each once, in the platform's order.
pub(crate) fn candidates(answer: &CarrierAnswer) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(1 + answer.relays.len());
    for relay in std::iter::once(&answer.relay).chain(answer.relays.iter()) {
        if !relay.is_empty() && !out.contains(relay) {
            out.push(relay.clone());
        }
    }
    out
}

/// The next relay a host moves to after `current` failed: the one after it, wrapping round.
pub(crate) fn next_home(candidates: &[String], current: &str) -> Option<String> {
    if candidates.len() < 2 {
        return None;
    }
    let at = candidates.iter().position(|c| c == current).unwrap_or(0);
    candidates.get(at.wrapping_add(1) % candidates.len()).cloned()
}

/// Which relay last carried each far machine, so the next dial tries it first.
#[derive(Default)]
pub(crate) struct Homes(Mutex<HashMap<String, String>>);

impl Homes {
    /// `candidates` with the relay that last carried `daemon` moved to the front.
    pub(crate) fn order(&self, daemon: &str, mut candidates: Vec<String>) -> Vec<String> {
        let held = self.0.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).cloned();
        if let Some(home) = held
            && let Some(at) = candidates.iter().position(|c| *c == home)
        {
            let home = candidates.remove(at);
            candidates.insert(0, home);
        }
        candidates
    }

    /// `relay` carried a circuit to `daemon`.
    pub(crate) fn carried(&self, daemon: &str, relay: &str) {
        let mut homes = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if homes.get(daemon).is_none_or(|held| held != relay) {
            homes.insert(daemon.to_owned(), relay.to_owned());
        }
    }

    /// The relay that last carried `daemon`, if any did.
    pub(crate) fn of(&self, daemon: &str) -> Option<String> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).cloned()
    }

    /// Forget every machine's relay (a rekey: the far machines register again anyway).
    pub(crate) fn clear(&self) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
}

#[cfg(test)]
#[path = "hub_carrier_rehome_tests.rs"]
mod tests;
