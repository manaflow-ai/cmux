//! The earned-access ladder (cmuxterm-hq `docs/rfd/0002-earned-access-ladder.md`): the rung an
//! agent's record earns, capped by its person. Pure: no IO, the clock comes in as `now`, and the
//! same record always gives the same rung, so any device can recompute it and tests replay it.
//!
//! Its events come from `earned_events.rs`: refusals from this machine's permission log, landed
//! and revert events from the Cloud service. Nothing consumes the rung yet: no permission
//! decision reads it, and no default changes (RFD step 3 shows it behind an experiment).

use crate::config::PermissionPolicy;

/// One rung, narrowest first. Each is one acpmux policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Rung {
    ReadOnly,
    Reads,
    Edits,
    Full,
}

impl Rung {
    pub(crate) fn policy(self) -> PermissionPolicy {
        match self {
            Self::ReadOnly => PermissionPolicy::Review,
            Self::Reads => PermissionPolicy::ApproveReads,
            Self::Edits => PermissionPolicy::ApproveEdits,
            Self::Full => PermissionPolicy::ApproveAll,
        }
    }

    /// The rung of a ladder policy; `None` for ask and deny-all, which are not on it.
    pub(crate) fn of(policy: PermissionPolicy) -> Option<Self> {
        match policy {
            PermissionPolicy::Review => Some(Self::ReadOnly),
            PermissionPolicy::ApproveReads => Some(Self::Reads),
            PermissionPolicy::ApproveEdits => Some(Self::Edits),
            PermissionPolicy::ApproveAll => Some(Self::Full),
            PermissionPolicy::Ask | PermissionPolicy::DenyAll => None,
        }
    }
}

/// What happened, from a source cmux checks itself (RFD "Only verifiable events count").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EventKind {
    /// A PR of the agent's merged with its required checks green (Cloud, trailer-checked).
    Landed,
    /// A merged PR that reverts one of the agent's merges (Cloud).
    Revert,
    /// A permission request the policy or the person denied (local log). `evaded`: a guard
    /// refusal the agent then tried to get around, which drops it to Read-only.
    Refusal { evaded: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Event {
    /// Unix milliseconds.
    pub at: u64,
    pub kind: EventKind,
}

/// The rungs that need landings: `landed` landings within `window_ms` of now, all after the
/// reset point. Widest first.
pub(crate) struct Threshold {
    pub rung: Rung,
    pub landed: usize,
    pub window_ms: u64,
}

const DAY_MS: u64 = 24 * 60 * 60 * 1000;

/// RFD "The ladder": Edits for 3 landed in 7 days, Full for 10 in 14 days. "0 reverts and 0
/// refusals" is the reset point: only landings after the latest revert or refusal count.
pub(crate) const LADDER: &[Threshold] = &[
    Threshold { rung: Rung::Full, landed: 10, window_ms: 14 * DAY_MS },
    Threshold { rung: Rung::Edits, landed: 3, window_ms: 7 * DAY_MS },
];

/// What a record earns, before the person's ceiling and cap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Eligibility {
    pub earned: Rung,
    /// The latest revert or refusal, from which landings count again.
    pub reset_at: Option<u64>,
    /// Landings after the reset point, at or before now.
    pub landed: usize,
}

/// The rung `events` earn at `now`: the widest threshold the landings after the reset point meet
/// within its window, else the rung that needs no landings (Reads, or Read-only when the reset
/// point is an evaded refusal). A revert or refusal takes effect at once; an event after `now`
/// is not counted.
pub(crate) fn eligibility(events: &[Event], now: u64) -> Eligibility {
    let past = || events.iter().filter(move |e| e.at <= now);
    let reset = past()
        .filter(|e| !matches!(e.kind, EventKind::Landed))
        // The latest one; an evaded refusal wins a tie, the narrower reading.
        .max_by_key(|e| (e.at, matches!(e.kind, EventKind::Refusal { evaded: true })));
    let reset_at = reset.map(|e| e.at);
    let floor = match reset.map(|e| e.kind) {
        Some(EventKind::Refusal { evaded: true }) => Rung::ReadOnly,
        _ => Rung::Reads,
    };
    let landings: Vec<u64> = past()
        .filter(|e| e.kind == EventKind::Landed && reset_at.is_none_or(|r| e.at > r))
        .map(|e| e.at)
        .collect();
    let earned = LADDER
        .iter()
        .find(|t| {
            landings.iter().filter(|at| now.saturating_sub(**at) <= t.window_ms).count() >= t.landed
        })
        .map_or(floor, |t| t.rung);
    Eligibility { earned, reset_at, landed: landings.len() }
}

/// RFD `effective = min(earned, person_ceiling, person_cap)`. A ceiling or cap off the ladder
/// (ask, deny-all) is the answer itself: earning never widens past what the person set.
pub(crate) fn rung(
    events: &[Event],
    ceiling: PermissionPolicy,
    cap: Option<PermissionPolicy>,
    now: u64,
) -> PermissionPolicy {
    let mut effective = eligibility(events, now).earned;
    for limit in std::iter::once(ceiling).chain(cap) {
        match Rung::of(limit) {
            Some(r) => effective = effective.min(r),
            None => return limit,
        }
    }
    effective.policy()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 100 * DAY_MS;

    fn landed(days_ago: u64, n: usize) -> Vec<Event> {
        (0..n)
            .map(|i| Event { at: NOW - days_ago * DAY_MS - i as u64, kind: EventKind::Landed })
            .collect()
    }

    #[test]
    fn a_new_agent_starts_at_reads() {
        let e = eligibility(&[], NOW);
        assert_eq!(e, Eligibility { earned: Rung::Reads, reset_at: None, landed: 0 });
    }

    #[test]
    fn three_landings_in_seven_days_earn_edits_and_ten_in_fourteen_earn_full() {
        assert_eq!(eligibility(&landed(1, 2), NOW).earned, Rung::Reads);
        assert_eq!(eligibility(&landed(1, 3), NOW).earned, Rung::Edits);
        assert_eq!(eligibility(&landed(8, 3), NOW).earned, Rung::Reads, "outside 7 days");
        assert_eq!(eligibility(&landed(10, 10), NOW).earned, Rung::Full);
        assert_eq!(eligibility(&landed(15, 10), NOW).earned, Rung::Reads, "outside 14 days");
    }

    #[test]
    fn a_revert_or_refusal_resets_and_fresh_landings_earn_it_back() {
        let mut events = landed(5, 10);
        events.push(Event { at: NOW - DAY_MS, kind: EventKind::Revert });
        let e = eligibility(&events, NOW);
        assert_eq!((e.earned, e.reset_at, e.landed), (Rung::Reads, Some(NOW - DAY_MS), 0));
        events.extend(landed(0, 3));
        assert_eq!(eligibility(&events, NOW).earned, Rung::Edits);

        let mut refused = landed(2, 3);
        refused.push(Event { at: NOW - DAY_MS, kind: EventKind::Refusal { evaded: false } });
        assert_eq!(eligibility(&refused, NOW).earned, Rung::Reads);
    }

    #[test]
    fn an_evaded_refusal_drops_to_read_only() {
        let events = [Event { at: NOW - 1, kind: EventKind::Refusal { evaded: true } }];
        assert_eq!(eligibility(&events, NOW).earned, Rung::ReadOnly);
    }

    #[test]
    fn events_after_now_do_not_count() {
        let future = [Event { at: NOW + 1, kind: EventKind::Revert }];
        assert_eq!(eligibility(&future, NOW).reset_at, None);
    }

    #[test]
    fn the_person_ceiling_and_cap_bound_the_earned_rung() {
        let full = landed(1, 10);
        assert_eq!(
            rung(&full, PermissionPolicy::ApproveAll, None, NOW),
            PermissionPolicy::ApproveAll
        );
        assert_eq!(
            rung(&full, PermissionPolicy::ApproveEdits, None, NOW),
            PermissionPolicy::ApproveEdits
        );
        assert_eq!(
            rung(&full, PermissionPolicy::ApproveAll, Some(PermissionPolicy::Review), NOW),
            PermissionPolicy::Review
        );
        assert_eq!(rung(&full, PermissionPolicy::Ask, None, NOW), PermissionPolicy::Ask);
        assert_eq!(
            rung(&full, PermissionPolicy::ApproveAll, Some(PermissionPolicy::DenyAll), NOW),
            PermissionPolicy::DenyAll
        );
        assert_eq!(
            rung(&[], PermissionPolicy::ApproveAll, None, NOW),
            PermissionPolicy::ApproveReads
        );
    }

    #[test]
    fn the_same_record_gives_the_same_rung() {
        let mut events = landed(3, 4);
        events.push(Event { at: NOW - 4 * DAY_MS, kind: EventKind::Refusal { evaded: false } });
        let a = eligibility(&events, NOW);
        events.reverse();
        assert_eq!(eligibility(&events, NOW), a);
    }
}
