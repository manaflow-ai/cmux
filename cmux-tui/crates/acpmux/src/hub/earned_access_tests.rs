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
    assert_eq!(rung(&full, PermissionPolicy::ApproveAll, None, NOW), PermissionPolicy::ApproveAll);
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
    assert_eq!(rung(&[], PermissionPolicy::ApproveAll, None, NOW), PermissionPolicy::ApproveReads);
}

#[test]
fn the_same_record_gives_the_same_rung() {
    let mut events = landed(3, 4);
    events.push(Event { at: NOW - 4 * DAY_MS, kind: EventKind::Refusal { evaded: false } });
    let a = eligibility(&events, NOW);
    events.reverse();
    assert_eq!(eligibility(&events, NOW), a);
}
