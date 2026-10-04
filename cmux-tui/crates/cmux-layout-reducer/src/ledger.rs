//! The replay ledger of the model ([`apply_once`], I5).

use crate::{IdempotencyKey, LayoutEvent, LayoutOp, LayoutOpKind, LayoutState, Reject, apply};

/// The keys of recently applied ops, oldest first, at most
/// [`Ledger::CAPACITY`]. The store keeps its own durable ledger; this one
/// serves the model and its tests.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Ledger {
    applied: std::collections::VecDeque<(IdempotencyKey, LayoutOpKind)>,
}

impl Ledger {
    pub const CAPACITY: usize = 1024;

    pub fn get(&self, key: &str) -> Option<&LayoutOpKind> {
        self.applied.iter().find(|(candidate, _)| candidate == key).map(|(_, kind)| kind)
    }

    fn record(&mut self, op: &LayoutOp) {
        if self.applied.len() == Self::CAPACITY {
            self.applied.pop_front();
        }
        self.applied.push_back((op.key.clone(), op.kind.clone()));
    }
}

/// [`apply`] with idempotency: an op whose key `ledger` already holds for an
/// equal kind returns the state unchanged with no events, and a key held for
/// another kind is [`Reject::IdempotencyConflict`].
pub fn apply_once(
    state: &LayoutState,
    ledger: &Ledger,
    op: &LayoutOp,
) -> Result<(LayoutState, Ledger, Vec<LayoutEvent>), Reject> {
    if let Some(previous) = ledger.get(&op.key) {
        return if *previous == op.kind {
            Ok((state.clone(), ledger.clone(), Vec::new()))
        } else {
            Err(Reject::IdempotencyConflict(op.key.clone()))
        };
    }
    let (next, events) = apply(state, op)?;
    let mut ledger = ledger.clone();
    ledger.record(op);
    Ok((next, ledger, events))
}
