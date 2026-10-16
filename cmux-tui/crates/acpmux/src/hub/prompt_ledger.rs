//! Pending prompt identities remain owned by the session until they settle.

use super::PromptOutcome;
use std::collections::VecDeque;

/// Only completed outcomes count against the retry cache's bound. Pending senders
/// must stay discoverable, including restored prompts whose completion looks them up.
pub(super) fn prune(ledger: &mut VecDeque<(String, PromptOutcome)>) {
    const COMPLETED_OUTCOMES: usize = 64;
    let mut excess = ledger
        .iter()
        .filter(|(_, outcome)| outcome.borrow().is_some())
        .count()
        .saturating_sub(COMPLETED_OUTCOMES);
    if excess == 0 {
        return;
    }
    ledger.retain(|(_, outcome)| {
        if excess > 0 && outcome.borrow().is_some() {
            excess -= 1;
            false
        } else {
            true
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    #[test]
    fn prompt_ledger_keeps_pending_and_bounds_completed_outcomes_as_they_settle() {
        let outcomes: Vec<PromptOutcome> =
            (0..130).map(|_| Arc::new(tokio::sync::watch::channel(None).0)).collect();
        let mut ledger: VecDeque<_> = outcomes
            .iter()
            .enumerate()
            .map(|(i, outcome)| (i.to_string(), outcome.clone()))
            .collect();
        prune(&mut ledger);
        assert_eq!(ledger.len(), 130, "pending prompts were evicted");

        // Settle newer prompts first: pending entries at the front must not be evicted.
        for i in (0..130).rev() {
            outcomes[i].send_replace(Some(Ok(json!({"promptId": i}))));
            prune(&mut ledger);
            let pending = i;
            let completed = (130 - i).min(64);
            assert_eq!(ledger.len(), pending + completed, "settled prompt {i}");
            let ids: Vec<_> = ledger.iter().map(|(id, _)| id.parse::<usize>().unwrap()).collect();
            let expected: Vec<_> = (0..pending).chain((130 - completed)..130).collect();
            assert_eq!(ids, expected, "pruning changed pending or recent completed identities");
        }
    }
}
