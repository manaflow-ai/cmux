//! The checks every scenario can call (the design's section 4 rule: at most a bounded, labelled
//! pause, never lost output, a doubled prompt, a wrong state or a restart loop). Each returns
//! `Err` with what a person would have seen, so a run's failure reads as the symptom.

use std::collections::BTreeMap;
use std::fmt::Debug;
use std::time::Duration;

/// No lost or doubled events: what the client recorded equals the journal, each record once and
/// in the journal's order. `journal` is the durable truth (read back from the store, ideally
/// after a restart); `client` is what the client saw.
pub fn client_equals_journal<T: Ord + Clone + Debug>(
    journal: &[T],
    client: &[T],
) -> Result<(), String> {
    let count = |records: &[T]| {
        let mut counts: BTreeMap<T, usize> = BTreeMap::new();
        for record in records {
            *counts.entry(record.clone()).or_default() += 1;
        }
        counts
    };
    let (in_journal, seen) = (count(journal), count(client));
    let doubled: Vec<&T> = seen.iter().filter(|(_, n)| **n > 1).map(|(record, _)| record).collect();
    if !doubled.is_empty() {
        return Err(format!("the client saw {} records twice: {doubled:?}", doubled.len()));
    }
    let lost: Vec<&T> = in_journal.keys().filter(|record| !seen.contains_key(*record)).collect();
    if !lost.is_empty() {
        return Err(format!("{} journal records never reached the client: {lost:?}", lost.len()));
    }
    let invented: Vec<&T> =
        seen.keys().filter(|record| !in_journal.contains_key(*record)).collect();
    if !invented.is_empty() {
        return Err(format!(
            "the client saw {} records the journal lacks: {invented:?}",
            invented.len()
        ));
    }
    if journal != client {
        return Err("the client saw the journal's records out of order".into());
    }
    Ok(())
}

/// Every one of `expected` (what the far side produced: the agent's words, the prompts sent) is
/// in `stored` exactly once.
pub fn each_once<T: PartialEq + Debug>(expected: &[T], stored: &[T]) -> Result<(), String> {
    for want in expected {
        match stored.iter().filter(|record| *record == want).count() {
            1 => {}
            0 => return Err(format!("{want:?} was lost")),
            n => return Err(format!("{want:?} was stored {n} times")),
        }
    }
    Ok(())
}

/// One reading of the state a client reports, at a time since the run started.
#[derive(Clone, Debug)]
pub struct Reading<S> {
    pub at: Duration,
    pub state: S,
}

/// The reported state matches the truth within `bound`: from `changed_at` (when the truth
/// changed) every reading after `changed_at + bound` satisfies `matches`, and at least one such
/// reading exists (a state never read is not a state shown).
pub fn state_within<S: Debug>(
    readings: &[Reading<S>],
    changed_at: Duration,
    bound: Duration,
    truth: &str,
    matches: impl Fn(&S) -> bool,
) -> Result<(), String> {
    let due = changed_at + bound;
    let after: Vec<&Reading<S>> = readings.iter().filter(|r| r.at >= due).collect();
    if after.is_empty() {
        let last = readings.last().map(|r| format!("{:?} at {:?}", r.state, r.at));
        return Err(format!(
            "no reading of the state {} ms after the truth became {truth} (last: {})",
            bound.as_millis(),
            last.unwrap_or_else(|| "none".into())
        ));
    }
    match after.iter().find(|r| !matches(&r.state)) {
        None => Ok(()),
        Some(wrong) => Err(format!(
            "the state read {:?} at {} ms, {} ms after the truth became {truth} (bound {} ms)",
            wrong.state,
            wrong.at.as_millis(),
            (wrong.at - changed_at).as_millis(),
            bound.as_millis()
        )),
    }
}

/// Restarts stayed within budget (a restart loop is the failure this catches).
pub fn restarts_within(what: &str, restarts: u64, budget: u64) -> Result<(), String> {
    if restarts <= budget {
        Ok(())
    } else {
        Err(format!("{what} restarted {restarts} times (budget {budget})"))
    }
}

/// The fault was recovered from, within `bound` of being healed.
pub fn recovered_within(what: &str, took: Option<Duration>, bound: Duration) -> Result<(), String> {
    match took {
        None => Err(format!("{what} never recovered")),
        Some(took) if took > bound => Err(format!(
            "{what} took {} ms to recover (bound {} ms)",
            took.as_millis(),
            bound.as_millis()
        )),
        Some(_) => Ok(()),
    }
}

/// All of `checks`, the first failure named.
pub fn all(checks: impl IntoIterator<Item = Result<(), String>>) -> Result<(), String> {
    checks.into_iter().collect()
}

#[cfg(test)]
#[path = "invariants_tests.rs"]
mod tests;
