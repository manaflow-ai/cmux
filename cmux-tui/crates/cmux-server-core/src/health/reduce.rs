//! The pure health reducer (server.md 9.3).

use std::collections::BTreeMap;

use super::checks::conditions;
use super::fixes::fixes_for;
use super::{Alert, AlertKey, AlertSet, Facts, FixRef, Post};

/// `(previous alerts, facts, now) -> (alerts, posts)`.
///
/// - A delayed check (`power.onBattery` 60 s, `network.offline` 30 s) is
///   raised once its condition held for the delay; the timer starts at the
///   first `reduce` that sees the condition and is kept in the set.
/// - A raise and every severity change post `Notify`; a clear posts
///   `Resolve`. The same facts at the same `now` post nothing.
/// - A check whose facts are unknown (`None`) keeps its previous alert and
///   timer: no resolve, no raise.
/// - `wake_at_ms` is the next time the result can change without new facts
///   (a delayed check, `lock.pending` at `due - window`, a stale backup).
pub fn reduce(prev: &AlertSet, facts: &Facts, now_ms: u64) -> (AlertSet, Vec<Post>) {
    let eval = conditions(facts, now_ms, prev);
    let mut next = AlertSet::default();
    let mut wake = eval.deadline;
    // Unknown facts keep the previous state of their checks unchanged.
    for (key, alert) in &prev.alerts {
        if eval.unknown.contains(&key.check) {
            next.alerts.insert(key.clone(), alert.clone());
        }
    }
    for (key, since) in &prev.pending {
        if eval.unknown.contains(&key.check) {
            next.pending.insert(key.clone(), *since);
        }
    }
    for cond in eval.holding {
        if cond.delay_ms > 0 {
            let since = prev.pending.get(&cond.key).copied().unwrap_or(now_ms).min(now_ms);
            next.pending.insert(cond.key.clone(), since);
            let due = since.saturating_add(cond.delay_ms);
            if due > now_ms {
                wake = Some(wake.map_or(due, |w: u64| w.min(due)));
                continue;
            }
        }
        let raised_at_ms = prev.alerts.get(&cond.key).map_or(now_ms, |a| a.raised_at_ms);
        next.alerts.insert(cond.key, Alert { severity: cond.severity, raised_at_ms });
    }
    next.wake_at_ms = wake;
    let posts = diff(&prev.alerts, &next.alerts, facts);
    (next, posts)
}

fn diff(
    prev: &BTreeMap<AlertKey, Alert>,
    next: &BTreeMap<AlertKey, Alert>,
    facts: &Facts,
) -> Vec<Post> {
    let mut posts = Vec::new();
    for key in prev.keys() {
        if !next.contains_key(key) {
            posts.push(Post::Resolve { dedupe_key: key.dedupe_key(&facts.host_id) });
        }
    }
    for (key, alert) in next {
        if prev.get(key).is_some_and(|old| old.severity == alert.severity) {
            continue;
        }
        let fixes = fixes_for(key.check, facts.platform, facts.mode)
            .map(|f| FixRef { id: f.id, title_key: f.title_key, needs_admin: f.needs_admin })
            .collect();
        posts.push(Post::Notify {
            dedupe_key: key.dedupe_key(&facts.host_id),
            host_id: facts.host_id.clone(),
            check: key.check,
            subject: key.subject.clone(),
            severity: alert.severity,
            title_key: key.check.title_key(),
            fixes,
        });
    }
    posts
}
